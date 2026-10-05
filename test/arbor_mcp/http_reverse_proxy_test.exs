defmodule Arbor.MCP.HttpReverseProxyTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.Runtime

  defmodule DispatchTrackingHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_list_tools(_cursor, state) do
      send(state.test_pid, {:handler_dispatched, self()})
      {:ok, [], nil, state}
    end
  end

  # A deliberately buffering HTTP/1.1 hop. It preserves the incoming header
  # list when forwarding, like a correctly configured reverse proxy, but
  # collects the upstream body before replying so response-header behavior is
  # also exercised through a buffering intermediary.
  defmodule BufferingProxy do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      upstream_port = Keyword.fetch!(opts, :upstream_port)

      headers =
        conn.req_headers
        |> Enum.reject(fn {name, _value} ->
          name in ["connection", "content-length", "content-type", "host", "transfer-encoding"]
        end)
        |> Enum.map(fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)

      request =
        {~c"http://127.0.0.1:#{upstream_port}/mcp", headers, ~c"application/json", body}

      case :httpc.request(:post, request, [timeout: 5_000], body_format: :binary) do
        {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
          conn
          |> copy_response_headers(response_headers)
          |> send_resp(status, response_body)

        {:error, _reason} ->
          send_resp(conn, 502, "Bad gateway")
      end
    end

    defp copy_response_headers(conn, headers) do
      headers
      |> Enum.reject(fn {name, _value} ->
        String.downcase(to_string(name)) in ["connection", "content-length", "transfer-encoding"]
      end)
      |> Enum.reduce(conn, fn {name, value}, acc ->
        put_resp_header(acc, String.downcase(to_string(name)), to_string(value))
      end)
    end
  end

  setup do
    runtime =
      start_supervised!(
        {Runtime,
         handler: DispatchTrackingHandler,
         handler_args: [test_pid: self()],
         transport: :mounted_http}
      )

    upstream_port = free_port()
    proxy_port = free_port()
    upstream_ref = {:proxy_test_upstream, System.unique_integer([:positive])}
    proxy_ref = {:proxy_test_front, System.unique_integer([:positive])}

    {:ok, _pid} =
      Plug.Cowboy.http(
        Arbor.MCP.HttpPlug,
        [
          runtime: runtime,
          path: "/mcp",
          protocol_mode: :modern_only
        ],
        ip: {127, 0, 0, 1},
        port: upstream_port,
        ref: upstream_ref
      )

    {:ok, _pid} =
      Plug.Cowboy.http(
        BufferingProxy,
        [upstream_port: upstream_port],
        ip: {127, 0, 0, 1},
        port: proxy_port,
        ref: proxy_ref
      )

    on_exit(fn ->
      shutdown(proxy_ref)
      shutdown(upstream_ref)
    end)

    %{proxy_port: proxy_port}
  end

  test "a valid modern request survives a normalizing and buffering proxy hop", %{
    proxy_port: port
  } do
    response = raw_request(port, standard_headers(), request_body(progress?: true))

    assert status(response) == 200
    assert String.contains?(String.downcase(response), "x-accel-buffering: no")
    assert_receive {:handler_dispatched, _handler}
  end

  test "duplicate and conflicting case-variant required headers fail before dispatch", %{
    proxy_port: port
  } do
    headers =
      standard_headers() ++
        [
          {"mcp-protocol-version", "2026-07-28"},
          {"MCP-METHOD", "prompts/list"}
        ]

    response = raw_request(port, headers, request_body())

    assert status(response) == 400
    refute_receive {:handler_dispatched, _handler}, 100
  end

  test "oversized header names and values fail closed before dispatch", %{proxy_port: port} do
    cases = [
      standard_headers() ++ [{String.duplicate("x", 257), "value"}],
      standard_headers() ++ [{"x-oversized", String.duplicate("v", 8_193)}]
    ]

    for headers <- cases do
      response = raw_request(port, headers, request_body())
      assert response == "" or status(response) in [400, 413, 414, 431, 502]
      refute_receive {:handler_dispatched, _handler}, 100
    end
  end

  test "obsolete folded or injected header lines fail closed before dispatch", %{proxy_port: port} do
    request =
      request_bytes(
        standard_headers(),
        request_body(),
        "Mcp-Method: tools/list\r\n injected-continuation"
      )

    response = send_raw(port, request)

    assert response == "" or status(response) in [400, 431, 502]
    refute_receive {:handler_dispatched, _handler}, 100
  end

  defp standard_headers do
    [
      {"Accept", "application/json, text/event-stream"},
      {"MCP-Protocol-Version", "2026-07-28"},
      {"Mcp-Method", "tools/list"}
    ]
  end

  defp request_body(opts \\ []) do
    meta =
      %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{}
      }
      |> maybe_put_progress(opts[:progress?])

    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/list",
      "params" => %{
        "_meta" => meta
      }
    })
  end

  defp maybe_put_progress(meta, true), do: Map.put(meta, "progressToken", "proxy-test")
  defp maybe_put_progress(meta, _false), do: meta

  defp raw_request(port, headers, body) do
    port
    |> send_raw(request_bytes(headers, body))
  end

  defp request_bytes(headers, body, extra_line \\ nil) do
    header_lines =
      headers
      |> Enum.map_join("\r\n", fn {name, value} -> "#{name}: #{value}" end)

    extra = if extra_line, do: "\r\n#{extra_line}", else: ""

    "POST /mcp HTTP/1.1\r\n" <>
      "Host: 127.0.0.1\r\n" <>
      "Content-Type: application/json\r\n" <>
      "Content-Length: #{byte_size(body)}\r\n" <>
      "Connection: close\r\n" <>
      header_lines <> extra <> "\r\n\r\n" <> body
  end

  defp send_raw(port, request) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)

    :ok = :gen_tcp.send(socket, request)
    response = recv_all(socket, [])
    :ok = :gen_tcp.close(socket)
    response
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> recv_all(socket, [data | acc])
      {:error, :closed} -> acc |> Enum.reverse() |> IO.iodata_to_binary()
      {:error, _reason} -> acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp status(response) do
    case Regex.run(~r/^HTTP\/1\.1 (\d{3})/, response) do
      [_, status] -> String.to_integer(status)
      _missing -> nil
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp shutdown(ref) do
    Plug.Cowboy.shutdown(ref)
  catch
    :exit, _reason -> :ok
  end
end
