defmodule Arbor.MCP.HTTPUnsupportedVersionListTest do
  @moduledoc """
  A mount's unsupported-version error (`-32022`) lists exactly the revisions
  that mount accepts: each listed version is served, and no other is. A
  legacy `initialize` naming a version the server lacks is negotiated, as the
  legacy revisions specify, the same way over HTTP as over stdio.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Arbor.MCP.HttpPlug
  alias Arbor.MCP.Internal.VersionRegistry
  alias Arbor.MCP.Server.{RequestContext, Runtime, Transport}
  alias Arbor.MCP.Test.RuntimeHTTPFixture
  alias Arbor.MCP.Transport.Stdio

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "version-list", version: "1.0.0"
  end

  @moduletag :capture_log

  @fixture Path.expand("../../priv/test/protocol_mode_stdio_server.exs", __DIR__)
  @project_root Path.expand("../..", __DIR__)

  @modes [:legacy_only, :prefer_legacy, :prefer_modern, :modern_only]
  @adapters [:plug, :cowboy, :bandit]

  # The TypeScript SDK v2 client's legacy handshake for
  # `supportedProtocolVersions: ["2024-10-07", "2025-11-25"]`: it offers the
  # first, a revision this server does not implement, with no
  # MCP-Protocol-Version header.
  @ts_initialize Jason.encode!(%{
                   "jsonrpc" => "2.0",
                   "id" => 0,
                   "method" => "initialize",
                   "params" => %{
                     "protocolVersion" => "2024-10-07",
                     "capabilities" => %{},
                     "clientInfo" => %{"name" => "ts-sdk-client", "version" => "2.4.0"}
                   }
                 })

  for adapter <- @adapters, mode <- @modes do
    test "#{adapter} #{mode} lists exactly the versions it accepts" do
      server = start_server(unquote(adapter), unquote(mode))
      {status, body} = modern_request(server, "tools/list", "2099-01-01")

      assert_unsupported(status, body, "2099-01-01")
      listed = body["error"]["data"]["supported"]
      assert listed == RequestContext.accepted_versions(unquote(mode))
      assert_lists_what_it_accepts(server, listed)
    end
  end

  test "a mount without protocol_mode lists what it accepts under every application mode" do
    previous = Application.fetch_env(:arbor_mcp, :protocol_mode)

    on_exit(fn ->
      case previous do
        {:ok, mode} -> Application.put_env(:arbor_mcp, :protocol_mode, mode)
        :error -> Application.delete_env(:arbor_mcp, :protocol_mode)
      end
    end)

    for app_mode <- @modes, adapter <- @adapters do
      Application.put_env(:arbor_mcp, :protocol_mode, app_mode)
      server = start_server(adapter, nil)
      {status, body} = modern_request(server, "tools/list", "2099-01-01")

      assert_unsupported(status, body, "2099-01-01")

      assert_lists_what_it_accepts(
        server,
        body["error"]["data"]["supported"],
        {adapter, app_mode}
      )
    end
  end

  test "HTTP answers the TypeScript SDK's initialize exactly as stdio does" do
    for mode <- @modes do
      stdio = stdio_initialize(mode)
      assert_ts_initialize_outcome(mode, stdio)

      for adapter <- @adapters do
        {_status, body} = request(start_server(adapter, mode), @ts_initialize, [])

        assert outcome(body) == outcome(stdio),
               "#{adapter} #{mode} answered #{inspect(body)}, stdio #{inspect(stdio)}"
      end
    end
  end

  # What an initialize answer agreed or refused, whatever the server's name.
  defp outcome(%{"result" => result}), do: {:negotiated, result["protocolVersion"]}
  defp outcome(%{"error" => error}), do: {:rejected, error["code"], error["data"]}

  # A legacy server answers an initialize for a revision it lacks with one it
  # supports; only a mount that serves no legacy revision rejects it.
  defp assert_ts_initialize_outcome(:modern_only, response) do
    assert %{"code" => -32022, "data" => %{"supported" => ["2026-07-28"]}} = response["error"]
  end

  defp assert_ts_initialize_outcome(_mode, response) do
    assert response["result"]["protocolVersion"] == "2025-11-25", inspect(response)
  end

  defp assert_unsupported(status, body, requested) do
    assert status == 400, inspect(body)
    assert body["error"]["code"] == -32022
    assert body["error"]["message"] == "Unsupported protocol version"
    assert body["error"]["data"]["requested"] == requested
  end

  # Every revision the library knows is served by the mount exactly when the
  # error listed it.
  defp assert_lists_what_it_accepts(server, listed, label \\ nil) do
    for version <- VersionRegistry.known_versions() do
      accepted = accepts?(server, version)

      assert accepted == version in listed,
             "#{inspect(label)}: #{version} accepted: #{accepted}, listed: #{inspect(listed)}"
    end
  end

  defp accepts?(server, version) do
    if VersionRegistry.modern?(version) do
      {status, body} = modern_request(server, "server/discover", version)
      status == 200 and is_map(body["result"])
    else
      {status, body} = initialize(server, version)
      status == 200 and body["result"]["protocolVersion"] == version
    end
  end

  defp modern_request(server, method, version) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => next_id(),
        "method" => method,
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => version,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
      })

    request(server, body, [
      {"mcp-protocol-version", version},
      {"mcp-method", method}
    ])
  end

  defp initialize(server, version) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => next_id(),
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => version,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "version-list", "version" => "1.0.0"}
        }
      })

    request(server, body, [])
  end

  defp request({:plug, opts}, body, headers) do
    conn =
      conn(:post, "/mcp", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")

    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)

    conn = HttpPlug.call(conn, opts)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp request({:http, port}, body, headers) do
    url = ~c"http://127.0.0.1:#{port}/mcp"

    header_chars =
      [{"accept", "application/json, text/event-stream"} | headers]
      |> Enum.map(fn {name, value} -> {to_charlist(name), to_charlist(value)} end)

    assert {:ok, {{_version, status, _reason}, _response_headers, response}} =
             :httpc.request(
               :post,
               {url, header_chars, ~c"application/json", body},
               [timeout: 5_000],
               []
             )

    {status, Jason.decode!(to_string(response))}
  end

  defp start_server(:plug, mode) do
    runtime = RuntimeHTTPFixture.start(Handler)
    opts = HttpPlug.init(runtime: runtime, protocol_mode: mode, legacy_http_sse: false)
    {:plug, opts}
  end

  defp start_server(adapter, mode) when adapter in [:cowboy, :bandit] do
    assert {:ok, root} =
             Handler.start_link(
               transport: :http,
               http_adapter: adapter,
               port: 0,
               host: {127, 0, 0, 1},
               protocol_mode: mode,
               legacy_http_sse: false
             )

    on_exit(fn -> if Process.alive?(root), do: Runtime.stop(root) end)
    {:http, listener_port(root, adapter)}
  end

  defp listener_port(root, :cowboy) do
    assert {:ok, %{ranch_ref: ref}} = Transport.http_listener(root)
    :ranch.get_port(ref)
  end

  defp listener_port(root, :bandit) do
    assert {:ok, %{listener: listener}} = Transport.http_listener(root)
    assert {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
    port
  end

  # The same initialize, sent to a stdio server running `mode`.
  defp stdio_initialize(mode) do
    mix = System.find_executable("mix") || flunk("mix executable is required")

    {:ok, stdio} =
      Stdio.connect(
        command: [mix, "run", "--no-compile", "--no-start", @fixture, to_string(mode)],
        cd: @project_root,
        env: mix_child_env()
      )

    try do
      {:ok, stdio} = Stdio.send_message(@ts_initialize, stdio)
      assert {:ok, response, _stdio} = Stdio.receive_message(stdio, 30_000)
      Jason.decode!(response)
    after
      Stdio.close(stdio)
    end
  end

  # As in Arbor.MCP.Client.ModernStdioTest: the stdio transport isolates the
  # child's environment, so pass on the Mix paths the child BEAM needs.
  defp mix_child_env do
    [{"MIX_ENV", "test"}] ++
      for name <- [
            "MIX_HOME",
            "MIX_ARCHIVES",
            "MIX_DEPS_PATH",
            "ARBOR_RPC_PATH",
            "ARBOR_V2_DEPS",
            "ARBOR_V2_BUILD",
            "ARBOR_V2_LOCK"
          ],
          value = System.get_env(name),
          do: {name, value}
  end

  defp next_id do
    Process.put(:version_list_request_id, Process.get(:version_list_request_id, 0) + 1)
  end
end
