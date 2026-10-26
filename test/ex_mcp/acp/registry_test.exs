defmodule ExMCP.ACP.RegistryTest do
  use ExUnit.Case, async: true

  alias ExMCP.ACP.Registry

  @registry %{
    "version" => "1.0.0",
    "agents" => [
      %{
        "id" => "codex-acp",
        "name" => "Codex CLI",
        "description" => "ACP adapter for OpenAI's coding assistant",
        "distribution" => %{
          "npx" => %{"package" => "@zed-industries/codex-acp@0.15.0"}
        }
      },
      %{
        "id" => "gemini-cli",
        "name" => "Gemini CLI",
        "description" => "Google's official CLI for Gemini",
        "distribution" => %{
          "npx" => %{"package" => "@google/gemini-cli@0.44.1", "args" => ["--acp"]}
        }
      }
    ]
  }

  describe "default_url/0" do
    test "points at the public latest registry" do
      assert Registry.default_url() ==
               "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json"
    end
  end

  describe "parse/1" do
    test "decodes registry JSON" do
      assert {:ok, registry} = Registry.parse(Jason.encode!(@registry))
      assert registry["version"] == "1.0.0"
      assert length(registry["agents"]) == 2
    end
  end

  describe "agents/1" do
    test "returns agents or an empty list" do
      assert length(Registry.agents(@registry)) == 2
      assert Registry.agents(%{}) == []
    end
  end

  describe "get_agent/2" do
    test "finds by id, name, and case-insensitive fallback" do
      assert Registry.get_agent(@registry, "codex-acp")["name"] == "Codex CLI"
      assert Registry.get_agent(@registry, "Gemini CLI")["id"] == "gemini-cli"
      assert Registry.get_agent(@registry, "codex cli")["id"] == "codex-acp"
    end
  end

  describe "find_agents/2" do
    test "searches id, name, and description" do
      assert [%{"id" => "codex-acp"}] = Registry.find_agents(@registry, "openai")
      assert [%{"id" => "gemini-cli"}] = Registry.find_agents(@registry, "google")
    end
  end

  describe "npx_command/1" do
    test "builds an npx command and preserves registry args" do
      agent = Registry.get_agent(@registry, "gemini-cli")

      assert Registry.npx_command(agent) ==
               {:ok, ["npx", "-y", "--", "@google/gemini-cli@0.44.1", "--acp"]}
    end

    test "returns an error when npx distribution is unavailable" do
      assert Registry.npx_command(%{"distribution" => %{}}) ==
               {:error, :npx_distribution_not_found}
    end

    test "rejects a package name that looks like a flag" do
      agent = %{"distribution" => %{"npx" => %{"package" => "-x"}}}
      assert {:error, :invalid_npx_package} = Registry.npx_command(agent)
    end

    test "rejects an empty package name" do
      agent = %{"distribution" => %{"npx" => %{"package" => ""}}}
      assert {:error, :invalid_npx_package} = Registry.npx_command(agent)
    end
  end

  describe "fetch/1" do
    test "uses the configured http client and parses the response body" do
      http_client = fn url, _headers, timeout ->
        assert url == "https://example.test/registry.json"
        assert timeout == 123
        {:ok, Jason.encode!(@registry)}
      end

      assert {:ok, registry} =
               Registry.fetch(
                 url: "https://example.test/registry.json",
                 timeout: 123,
                 http_client: http_client
               )

      assert Registry.get_agent(registry, "codex-acp")["name"] == "Codex CLI"
    end

    test "refuses a cross-origin redirect so request headers are not forwarded" do
      parent = self()
      secret = "registry-redirect-secret-#{System.unique_integer([:positive])}"

      {_target_pid, target_port} =
        start_http_stub(fn request ->
          send(parent, {:target_request, request.headers})
          http_response(200, [{"content-type", "application/json"}], Jason.encode!(@registry))
        end)

      location = "http://127.0.0.1:#{target_port}/leaked.json"

      {_origin_pid, origin_port} =
        start_http_stub(fn _request ->
          http_response(302, [{"location", location}], "")
        end)

      result =
        Registry.fetch(
          url: "http://127.0.0.1:#{origin_port}/registry.json",
          headers: [
            {"authorization", "Bearer #{secret}"},
            {"x-registry-token", secret}
          ],
          timeout: 2_000
        )

      # :httpc autoredirects by default and re-sends the original headers to
      # every hop, including a different origin. Refuse that hop.
      assert {:error, {:redirect_refused, 302, ^location}} = result

      refute_received {:target_request, _headers}
    end

    test "a refused redirect's location drops its userinfo, query and fragment" do
      {_pid, port} =
        start_http_stub(fn _request ->
          location = "https://user:pass@cdn.example/registry.json?sig=signed-secret#frag"
          http_response(302, [{"location", location}], "")
        end)

      assert {:error, {:redirect_refused, 302, "https://cdn.example/registry.json"}} =
               Registry.fetch(url: "http://127.0.0.1:#{port}/registry.json", timeout: 2_000)
    end
  end

  defp start_http_stub(handler) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1},
        backlog: 16
      ])

    {:ok, port} = :inet.port(listen)

    pid =
      spawn_link(fn ->
        http_stub_loop(listen, handler)
      end)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :gen_tcp.close(listen)
    end)

    {pid, port}
  end

  defp http_stub_loop(listen, handler) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, socket} ->
        _ = serve_http_stub(socket, handler)
        :gen_tcp.close(socket)
        http_stub_loop(listen, handler)

      {:error, :timeout} ->
        http_stub_loop(listen, handler)

      {:error, _reason} ->
        :ok
    end
  end

  defp serve_http_stub(socket, handler) do
    with {:ok, request} <- recv_http_request(socket) do
      :gen_tcp.send(socket, handler.(request))
    end
  end

  defp recv_http_request(socket) do
    recv_http_request(socket, "")
  end

  defp recv_http_request(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} ->
        acc = acc <> data

        case String.split(acc, "\r\n\r\n", parts: 2) do
          [header_block, _body] -> {:ok, parse_http_request(header_block)}
          _ -> recv_http_request(socket, acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_http_request(header_block) do
    [request_line | header_lines] = String.split(header_block, "\r\n")
    [method, path | _] = String.split(request_line, " ")

    headers =
      Enum.map(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(String.trim(name)), String.trim(value)}
      end)

    %{method: method, path: path, headers: headers}
  end

  defp http_response(status, headers, body) when is_binary(body) do
    status_line =
      case status do
        200 -> "HTTP/1.1 200 OK"
        302 -> "HTTP/1.1 302 Found"
        _ -> "HTTP/1.1 #{status} X"
      end

    header_lines =
      [
        {"content-length", Integer.to_string(byte_size(body))},
        {"connection", "close"}
        | headers
      ]
      |> Enum.map_join("\r\n", fn {name, value} -> "#{name}: #{value}" end)

    "#{status_line}\r\n#{header_lines}\r\n\r\n#{body}"
  end
end
