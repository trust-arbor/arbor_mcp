defmodule ExMCP.HttpPlugEventStreamAcceptTest do
  # A request that asks for progress is answered with an event stream only
  # when its Accept header names `text/event-stream` with a quality above
  # zero, in any case. `q=0` refuses an event stream, and a wildcard doesn't
  # ask for one; those requests get JSON. The legacy standalone GET stream
  # follows the same rule (backport of the 2.x Accept matrix, commits 4462ba3
  # and a887ff2, adapted to the 1.x plug: the POST decision point is the
  # modern request stream — a 1.x legacy POST is always answered with JSON,
  # whatever the Accept header says — and the GET stream is exercised through
  # the plug's own session machinery rather than a 2.x Runtime).
  use ExUnit.Case, async: true

  alias ExMCP.HttpPlug
  alias ExMCP.Server.Context

  @modern "2026-07-28"
  @legacy "2025-11-25"

  defmodule Handler do
    @moduledoc false
    use ExMCP.Server.Handler

    @impl true
    def init(opts), do: {:ok, %{test: Keyword.get(opts, :test)}}

    @impl true
    def handle_call_tool("progress", _args, state) do
      send(state.test, {:reported, Context.report_progress(1, 2)})
      {:ok, %{content: []}, state}
    end
  end

  # A quoted parameter value may hold commas, semicolons and escaped quotes
  # (RFC 9110 section 5.6.4). None of them separates ranges or parameters, so
  # the q-value after one still belongs to its range.
  @streams [
    "application/json, text/event-stream",
    "application/json;q=0.5, Text/Event-Stream;q=0.2",
    "text/event-stream;charset=utf-8;q=1, application/json",
    ~S(text/event-stream;foo="x;y,z";q=0.5, application/json),
    ~S(text/event-stream;foo="a\"b";q=1, application/json)
  ]

  @json [
    "application/json, text/event-stream;q=0",
    "application/json, text/event-stream;q=0.000",
    "application/json, text/event-stream;q=abc",
    ~S(application/json, text/event-stream;q="1"),
    "application/json, text/event-stream;q",
    "application/json, text/event-stream;q=",
    "application/json",
    "*/*",
    "application/json, text/*",
    ~S(application/json, text/event-stream;foo="a,b";q=0),
    ~S(application/json, text/event-stream;foo="a\",b";q=0),
    ~S(application/json, text/event-stream;foo="a;q=1";q=0),
    ~S(application/json, text/event-stream;foo="unterminated)
  ]

  describe "modern POST that asks for progress" do
    for accept <- @streams do
      test "Accept #{inspect(accept)} gets an event stream" do
        {conn, reported} = call_progress(unquote(accept))
        assert conn.status == 200
        assert content_type(conn) =~ "text/event-stream"
        assert reported == :ok

        assert [
                 %{"method" => "notifications/progress"},
                 %{"id" => id, "result" => _result}
               ] = sse_messages(conn.resp_body)

        assert id == progress_request_id()
      end
    end

    for accept <- @json do
      test "Accept #{inspect(accept)} gets JSON" do
        {conn, reported} = call_progress(unquote(accept))
        assert conn.status == 200
        assert content_type(conn) =~ "application/json"
        assert reported == {:error, :request_not_streaming}
        assert %{"id" => id, "result" => _result} = Jason.decode!(conn.resp_body)
        assert id == progress_request_id()
      end
    end
  end

  # A 1.x legacy POST has no request-owned stream whatever the Accept header
  # says: the header decides nothing there.
  test "a legacy POST that asks for progress gets JSON whatever it accepts" do
    opts =
      HttpPlug.init(handler: Handler, handler_opts: [test: self()], protocol_mode: :legacy_only)

    headers = legacy_session_headers(opts)

    conn =
      progress_request(@legacy, %{})
      |> post([{"accept", "application/json, text/event-stream"} | headers], opts)

    assert conn.status == 200
    assert content_type(conn) =~ "application/json"
    assert %{"id" => id, "result" => _result} = Jason.decode!(conn.resp_body)
    assert id == progress_request_id()
  end

  # The legacy session GET stream follows the same rule: a header that
  # refuses an event stream is turned away rather than served one.
  describe "legacy GET stream" do
    for accept <- @streams do
      test "Accept #{inspect(accept)} opens it" do
        conn = get_stream(unquote(accept))
        assert conn.status == 200
        assert content_type(conn) =~ "text/event-stream"
      end
    end

    for accept <- @json do
      test "Accept #{inspect(accept)} is refused" do
        assert get_stream(unquote(accept)).status == 404
      end
    end
  end

  defp progress_request_id, do: 2

  # The modern request stream writes its events into the test connection's
  # body; the process that called the plug owns it and acknowledges the
  # progress notification, so no test-process handling is needed.
  defp call_progress(accept) do
    opts = HttpPlug.init(handler: Handler, handler_opts: [test: self()])

    conn =
      post(
        progress_request(@modern, modern_meta()),
        [{"accept", accept} | modern_headers()],
        opts
      )

    assert_receive {:reported, reported}
    {conn, reported}
  end

  defp modern_meta do
    %{
      "io.modelcontextprotocol/protocolVersion" => @modern,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }
  end

  defp modern_headers,
    do: [
      {"mcp-protocol-version", @modern},
      {"mcp-method", "tools/call"},
      {"mcp-name", "progress"}
    ]

  defp progress_request(_version, meta) do
    %{
      "jsonrpc" => "2.0",
      "id" => progress_request_id(),
      "method" => "tools/call",
      "params" => %{
        "name" => "progress",
        "arguments" => %{},
        "_meta" => Map.put(meta, "progressToken", "accept")
      }
    }
  end

  # A session the GET stream can attach to: initialize, then initialized.
  defp legacy_session_headers(opts) do
    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @legacy,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "accept", "version" => "1"}
      }
    }

    conn = post(initialize, [{"accept", "application/json"}], opts)
    assert conn.status == 200, conn.resp_body
    [session] = Plug.Conn.get_resp_header(conn, "mcp-session-id")
    headers = [{"mcp-session-id", session}, {"mcp-protocol-version", @legacy}]

    initialized = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    assert post(initialized, [{"accept", "application/json"} | headers], opts).status == 202
    headers
  end

  defp get_stream(accept) do
    opts =
      HttpPlug.init(
        handler: Handler,
        handler_opts: [test: self()],
        protocol_mode: :legacy_only,
        legacy_http_sse: true,
        sse_mode: :oneshot
      )

    headers = legacy_session_headers(opts)

    headers
    |> Enum.reduce(Plug.Test.conn(:get, "/mcp"), fn {key, value}, conn ->
      Plug.Conn.put_req_header(conn, key, value)
    end)
    |> Plug.Conn.put_req_header("accept", accept)
    |> HttpPlug.call(opts)
  end

  defp post(request, headers, opts) do
    headers
    |> Enum.reduce(
      Plug.Test.conn(:post, "/mcp", Jason.encode!(request))
      |> Plug.Conn.put_req_header("content-type", "application/json"),
      fn {key, value}, conn -> Plug.Conn.put_req_header(conn, key, value) end
    )
    |> HttpPlug.call(opts)
  end

  defp content_type(conn), do: conn |> Plug.Conn.get_resp_header("content-type") |> Enum.join()

  defp sse_messages(body) do
    body
    |> String.split(["\r\n\r\n", "\n\n"], trim: true)
    |> Enum.flat_map(fn event ->
      for "data: " <> json <- String.split(event, ["\r\n", "\n"]), do: Jason.decode!(json)
    end)
  end
end
