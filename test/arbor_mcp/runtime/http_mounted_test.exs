defmodule Arbor.MCP.Server.Runtime.HTTPMountedTest do
  use ExUnit.Case, async: true
  alias Arbor.MCP.HttpPlug
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{HTTPWriterProxy, HTTPWriterRegistry}

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    alias Arbor.MCP.Protocol.Initialize
    alias Arbor.MCP.Server.Context

    def init(opts) do
      send(opts[:test], :mounted_init)
      {:ok, %{test: opts[:test], count: 0}}
    end

    def handle_initialize(params, state) do
      {:ok,
       Initialize.build_initialize_result(params, %{
         "serverInfo" => %{"name" => "mounted", "version" => "2"},
         "capabilities" => %{"tools" => %{}}
       }), state}
    end

    def handle_call_tool("progress", _args, state) do
      :ok = Context.report_progress(1, 2, "working")
      :ok = Context.send_log_message(:info, "fixture log")

      {:ok, %{"content" => [%{"type" => "text", "text" => "complete"}]},
       %{state | count: state.count + 1}}
    end

    def handle_call_tool("count", _args, state) do
      context = Context.current()
      send(state.test, {:mounted_context, context.application_context})

      {:ok, %{"content" => [], "structuredContent" => %{"count" => state.count}},
       %{state | count: state.count + 1}}
    end
  end

  defmodule UnsafeParsedInput do
    defstruct [:owner]
  end

  defimpl Jason.Encoder, for: UnsafeParsedInput do
    def encode(value, opts) do
      send(value.owner, :unsafe_parsed_encoder_called)
      Jason.Encode.map(%{}, opts)
    end
  end

  test "mounted modern POST shares root state and resolves request context without reinitialization" do
    runtime = runtime()
    assert_receive :mounted_init

    opts =
      HttpPlug.init(
        runtime: runtime,
        protocol_mode: :modern_only,
        handler_opts: fn _conn, request -> %{id: request["id"]} end
      )

    for id <- [1, 2] do
      conn = post(modern(id), opts)
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["result"]["structuredContent"]["count"] == id - 1
      assert [] == Plug.Conn.get_resp_header(conn, "mcp-session-id")
      assert_receive {:mounted_context, %{id: ^id}}
    end

    refute_receive :mounted_init, 5
    {:ok, domain} = HTTPWriterProxy.domain(runtime)
    wait(fn -> match?(%{frames: 0, bytes: 0}, HTTPWriterRegistry.stats(domain)) end)
  end

  test "all mounted validation responses retain original host and origin guards" do
    runtime = runtime()

    opts =
      HttpPlug.init(
        runtime: runtime,
        protocol_mode: :modern_only,
        allowed_hosts: ["trusted.example"],
        allowed_origins: ["https://trusted.example"]
      )

    denied = post(modern(1), opts)
    assert denied.status == 421

    origin =
      Plug.Test.conn(:post, "http://trusted.example/mcp", Jason.encode!(modern(2)))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("origin", "https://untrusted.example")
      |> HttpPlug.call(opts)

    assert origin.status == 403
    refute_receive {:mounted_context, _}, 5
  end

  test "same socket PID reuses only settled IO credit while guardian notifications are paused" do
    runtime = runtime()
    {:ok, domain} = HTTPWriterProxy.domain(runtime)
    guardian = HTTPWriterRegistry.guardian(domain)
    opts = HttpPlug.init(runtime: runtime, protocol_mode: :modern_only)
    :sys.suspend(guardian)

    try do
      assert post(modern(1), opts).status == 200
      conn = post(modern(2), opts)
      assert Jason.decode!(conn.resp_body)["result"]["structuredContent"]["count"] == 1
    after
      :sys.resume(guardian)
    end

    wait(fn -> match?(%{frames: 0}, HTTPWriterRegistry.stats(domain)) end)
  end

  test "upstream parsed data never invokes arbitrary application JSON encoders" do
    runtime = runtime()
    opts = HttpPlug.init(runtime: runtime, protocol_mode: :modern_only)

    parsed =
      put_in(modern(1), ["params", "arguments", "private"], %UnsafeParsedInput{owner: self()})

    conn =
      Plug.Test.conn(:post, "/mcp", "")
      |> Map.put(:body_params, parsed)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> modern_headers(modern(1))
      |> HttpPlug.call(opts)

    assert conn.status == 400
    refute_receive :unsafe_parsed_encoder_called, 5
    refute_receive {:mounted_context, _}, 5
    assert %{reserved: 0} = Runtime.stats(runtime)
  end

  test "mounted legacy GET and DELETE cannot fall back to process-global session state" do
    runtime = runtime(services: [sessions: []])
    opts = HttpPlug.init(runtime: runtime, protocol_mode: :legacy_only, legacy_http_sse: true)

    for method <- [:get, :delete] do
      conn = Plug.Test.conn(method, "/mcp") |> HttpPlug.call(opts)
      assert conn.status == 501
    end

    {:ok, service} = Runtime.service(runtime, :sessions)
    assert {:ok, %{sessions: 0}} = Arbor.MCP.SessionManager.get_stats(service, [])
  end

  test "mounted request-owned SSE writes its prepared frame with a real adapter return" do
    runtime = runtime()
    opts = HttpPlug.init(runtime: runtime, protocol_mode: :modern_only)
    request = put_in(modern(3), ["params", "_meta", "progressToken"], "progress")

    conn =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(request))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "text/event-stream")
      |> modern_headers(request)
      |> HttpPlug.call(opts)

    assert conn.status == 200
    assert conn.state == :chunked
    assert conn.resp_body =~ "data: "
    assert conn.resp_body =~ "\r\n\r\n"
  end

  test "request SSE delivers charged progress and log before the final committed reply" do
    runtime = runtime()
    opts = HttpPlug.init(runtime: runtime, protocol_mode: :modern_only)

    request =
      modern(9)
      |> put_in(["params", "name"], "progress")
      |> put_in(["params", "_meta", "progressToken"], "progress")
      |> put_in(["params", "_meta", "io.modelcontextprotocol/logLevel"], "info")

    conn =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(request))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "text/event-stream")
      |> modern_headers(request)
      |> HttpPlug.call(opts)

    assert conn.status == 200

    frames =
      conn.resp_body
      |> String.split("\r\n\r\n", trim: true)
      |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)

    assert [
             %{"method" => "notifications/progress"},
             %{"method" => "notifications/message"},
             %{"id" => 9, "result" => _}
           ] = frames

    next = post(modern(10), opts)
    assert Jason.decode!(next.resp_body)["result"]["structuredContent"]["count"] == 1
  end

  test "mounted legacy initialize retains a root-addressed lease and negotiated version" do
    runtime = runtime(services: [sessions: []])
    opts = HttpPlug.init(runtime: runtime, protocol_mode: :legacy_only)

    init = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "fixture", "version" => "1"}
      }
    }

    conn = post(init, opts)
    assert conn.status == 200, conn.resp_body
    assert [%{} | _] = [Jason.decode!(conn.resp_body)]
    [id] = Plug.Conn.get_resp_header(conn, "mcp-session-id")

    request = %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/call",
      "params" => %{"name" => "count", "arguments" => %{}}
    }

    next =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(request))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("mcp-session-id", id)
      |> Plug.Conn.put_req_header("mcp-protocol-version", "2025-11-25")
      |> HttpPlug.call(opts)

    assert next.status == 200
    assert Jason.decode!(next.resp_body)["result"]["structuredContent"]["count"] == 0
    {:ok, service} = Runtime.service(runtime, :sessions)
    assert {:ok, %{sessions: 1}} = Arbor.MCP.SessionManager.get_stats(service, [])
  end

  test "late dynamic request context causes no callback or state mutation" do
    runtime = runtime(request_timeout_ms: 20)

    opts =
      HttpPlug.init(
        runtime: runtime,
        protocol_mode: :modern_only,
        handler_opts: fn _conn ->
          Process.sleep(30)
          :late
        end
      )

    assert_raise Arbor.MCP.HttpPlug.RuntimeWriter.AdmissionError, fn -> post(modern(4), opts) end
    refute_receive {:mounted_context, _}, 5
    assert %{reserved: 0} = Runtime.stats(runtime)
  end

  defp runtime(extra \\ []) do
    root =
      start_supervised!(
        {Runtime,
         Keyword.merge(
           [handler: Handler, handler_args: [test: self()], request_timeout_ms: 2000],
           extra
         )}
      )

    {:ok, runtime} = Runtime.ref(root)
    runtime
  end

  defp modern(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{
        "name" => "count",
        "arguments" => %{},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }
  end

  defp post(request, opts) do
    Plug.Test.conn(:post, "/mcp", Jason.encode!(request))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> modern_headers(request)
    |> HttpPlug.call(opts)
  end

  defp modern_headers(
         conn,
         %{"params" => %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => version}}} =
           request
       ) do
    conn
    |> Plug.Conn.put_req_header("mcp-protocol-version", version)
    |> Plug.Conn.put_req_header("mcp-method", request["method"])
    |> Plug.Conn.put_req_header("mcp-name", request["params"]["name"])
  end

  defp modern_headers(conn, _legacy), do: conn
  defp wait(fun, remaining \\ 200)
  defp wait(_fun, 0), do: flunk("mounted IO state not reached")

  defp wait(fun, remaining) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          wait(fun, remaining - 1)
        )
  end
end
