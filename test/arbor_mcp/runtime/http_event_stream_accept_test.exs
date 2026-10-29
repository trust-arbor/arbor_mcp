defmodule Arbor.MCP.Server.Runtime.HTTPEventStreamAcceptTest do
  # A request that asks for progress is answered with an event stream only
  # when its Accept header names `text/event-stream` with a quality above
  # zero, in both eras. `q=0` refuses an event stream, and a wildcard doesn't
  # ask for one; those requests get JSON.
  use ExUnit.Case, async: true

  alias Arbor.MCP.HttpPlug
  alias Arbor.MCP.Server.Runtime

  @legacy "2025-11-25"
  @modern "2026-07-28"

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    alias Arbor.MCP.Server.Context

    def init(opts), do: {:ok, %{test: opts[:test]}}

    def handle_call_tool("progress", _args, state) do
      send(state.test, {:reported, Context.report_progress(1, 2)})
      {:ok, %{"content" => []}, state}
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
    ~S(text/event-stream;foo="a\"b";q=1, application/json),
    "application/json, text/event-stream;Q=0.5",
    "application/json, text/event-stream;q=1\t"
  ]

  @json [
    "application/json, text/event-stream;q=0",
    "application/json, text/event-stream;q=0.000",
    "application/json, text/event-stream;q=abc",
    ~S(application/json, text/event-stream;q="1"),
    "application/json, text/event-stream;q",
    "application/json, text/event-stream;q=",
    "application/json, text/event-stream;q =1",
    "application/json, text/event-stream;q= 1",
    "application/json, text/event-stream;q = 1",
    "application/json, text/event-stream;q=1.5",
    "application/json, text/event-stream;q=1.0000",
    "application/json, text/event-stream;q=.5",
    "application/json, text/event-stream;q=1;q=abc",
    "application/json, text/event-stream;q=1;q",
    "application/json, text/event-stream;q=1\u00A0",
    "application/json",
    "*/*",
    "application/json, text/*",
    ~S(application/json, text/event-stream;foo="a,b";q=0),
    ~S(application/json, text/event-stream;foo="a\",b";q=0),
    ~S(application/json, text/event-stream;foo="a;q=1";q=0),
    ~S(application/json, text/event-stream;foo="unterminated)
  ]

  for era <- [:legacy, :modern] do
    describe "#{era}" do
      @describetag era: era

      for accept <- @streams do
        test "Accept #{inspect(accept)} gets an event stream", %{era: era} do
          {conn, reported} = call_progress(era, unquote(accept))
          assert conn.status == 200
          assert content_type(conn) =~ "text/event-stream"
          assert reported == :ok

          assert [
                   %{"method" => "notifications/progress"},
                   %{"id" => 2, "result" => _result}
                 ] = sse_messages(conn.resp_body)
        end
      end

      for accept <- @json do
        test "Accept #{inspect(accept)} gets JSON", %{era: era} do
          {conn, _reported} = call_progress(era, unquote(accept))
          assert conn.status == 200
          assert content_type(conn) =~ "application/json"
          assert %{"id" => 2, "result" => _result} = Jason.decode!(conn.resp_body)
        end
      end
    end
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
        assert get_stream(unquote(accept)).status == 400
      end
    end
  end

  defp get_stream(accept) do
    root =
      start_supervised!(
        {Runtime, handler: Handler, handler_args: [test: self()], services: [sessions: []]}
      )

    {:ok, runtime} = Runtime.ref(root)
    opts = HttpPlug.init(runtime: runtime, protocol_mode: :legacy_only, sse_mode: :oneshot)
    headers = era_headers(:legacy, opts)

    headers
    |> Enum.reduce(Plug.Test.conn(:get, "/mcp"), fn {key, value}, conn ->
      Plug.Conn.put_req_header(conn, key, value)
    end)
    |> Plug.Conn.put_req_header("accept", accept)
    |> HttpPlug.call(opts)
  end

  defp call_progress(era, accept) do
    root =
      start_supervised!(
        {Runtime, handler: Handler, handler_args: [test: self()], services: [sessions: []]}
      )

    {:ok, runtime} = Runtime.ref(root)
    opts = HttpPlug.init(runtime: runtime, protocol_mode: :prefer_modern)
    headers = era_headers(era, opts)
    conn = post(progress(era), [{"accept", accept} | headers], opts)
    assert_receive {:reported, reported}
    {conn, reported}
  end

  defp era_headers(:modern, _opts),
    do: [
      {"mcp-protocol-version", @modern},
      {"mcp-method", "tools/call"},
      {"mcp-name", "progress"}
    ]

  defp era_headers(:legacy, opts) do
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

  defp progress(era) do
    meta =
      if era == :modern,
        do: %{
          "io.modelcontextprotocol/protocolVersion" => @modern,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        },
        else: %{}

    %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/call",
      "params" => %{
        "name" => "progress",
        "arguments" => %{},
        "_meta" => Map.put(meta, "progressToken", "accept")
      }
    }
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
