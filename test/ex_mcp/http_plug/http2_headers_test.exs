defmodule ExMCP.HttpPlug.HTTP2HeadersTest do
  @moduledoc """
  HTTP/2 forbids connection-specific header fields, and a client treats a
  response that carries one as malformed (RFC 9113, section 8.2.2): curl over
  h2c got no `endpoint` event from the legacy SSE GET stream, which sent
  `connection: keep-alive` (#182). The GET streams of both legacy transports
  are read here over h2c, as Cowboy serves them.
  """

  use ExUnit.Case, async: true

  alias ExMCP.HttpPlug

  # RFC 9113, section 8.2.2, and RFC 9110, section 7.6.1.
  @connection_specific ~w(connection keep-alive proxy-connection transfer-encoding upgrade)

  defmodule Handler do
    use ExMCP.Server.Handler
  end

  defp post(request, headers, opts) do
    headers
    |> Enum.reduce(Plug.Test.conn(:post, "/mcp", Jason.encode!(request)), fn {name, value},
                                                                             conn ->
      Plug.Conn.put_req_header(conn, name, value)
    end)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> HttpPlug.call(opts)
  end

  setup do
    ranch_ref = make_ref()

    opts = [
      handler: Handler,
      path: "/mcp",
      protocol_mode: :legacy_only,
      legacy_http_sse: true,
      sse_mode: :oneshot,
      allowed_origins: :any
    ]

    start_supervised!(
      {Plug.Cowboy,
       scheme: :http,
       plug: {HttpPlug, opts},
       options: [ip: {127, 0, 0, 1}, port: 0, ref: ranch_ref]},
      id: make_ref()
    )

    %{port: :ranch.get_port(ranch_ref), opts: HttpPlug.init(opts)}
  end

  test "the 2024-11-05 SSE stream sends its endpoint event over h2c", %{port: port} do
    {status, headers, body} = get(port, "/sse", [])

    assert status == 200
    assert connection_specific(headers) == []
    assert {"content-type", "text/event-stream"} in headers
    assert body =~ "event: endpoint"
    assert body =~ "/message?sessionId="
  end

  test "a session's GET stream sends no connection-specific header over h2c", %{
    port: port,
    opts: opts
  } do
    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 90,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test", "version" => "1"}
      }
    }

    initialized = post(initialize, [], opts)
    [session] = Plug.Conn.get_resp_header(initialized, "mcp-session-id")

    post(
      %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}},
      [{"mcp-session-id", session}, {"mcp-protocol-version", "2025-06-18"}],
      opts
    )

    {status, headers, _body} =
      get(port, "/mcp", [{"mcp-session-id", session}, {"mcp-protocol-version", "2025-06-18"}])

    assert status == 200
    assert connection_specific(headers) == []
  end

  test "the deprecated example server also omits connection-specific response headers" do
    init = Function.capture(ExMCP.Transport.HTTPServer, :init, 1)
    handle = Function.capture(ExMCP.Transport.HTTPServer, :call, 2)
    config = init.(handler: Handler, security: %{validate_origin: false, enforce_https: false})
    conn = handle.(Plug.Test.conn(:get, "/sse"), config)
    assert conn.status == 200
    assert connection_specific(conn.resp_headers) == []
    assert conn.resp_body =~ "event: connect"
    assert conn.resp_body =~ "event: ping"
  end

  defp connection_specific(headers),
    do: for({name, _value} = header <- headers, name in @connection_specific, do: header)

  defp get(port, path, headers) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http2])
    assert Mint.HTTP.protocol(conn) == :http2

    {:ok, conn, ref} =
      Mint.HTTP.request(conn, "GET", path, [{"accept", "text/event-stream"} | headers], nil)

    response = collect(conn, ref, %{status: nil, headers: [], body: ""})
    {response.status, response.headers, response.body}
  end

  defp collect(conn, ref, response) do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          :unknown ->
            collect(conn, ref, response)

          {:ok, conn, events} ->
            response =
              Enum.reduce(events, response, fn
                {:status, ^ref, status}, acc -> %{acc | status: status}
                {:headers, ^ref, headers}, acc -> %{acc | headers: acc.headers ++ headers}
                {:data, ^ref, data}, acc -> %{acc | body: acc.body <> data}
                {:done, ^ref}, acc -> Map.put(acc, :done, true)
                {:error, ^ref, reason}, _acc -> flunk("HTTP/2 stream failed: #{inspect(reason)}")
                _other, acc -> acc
              end)

            if Map.get(response, :done) do
              Mint.HTTP.close(conn)
              response
            else
              collect(conn, ref, response)
            end
        end
    after
      5_000 -> flunk("no complete response: #{inspect(response)}")
    end
  end
end
