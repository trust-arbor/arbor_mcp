defmodule Arbor.MCP.Server.Runtime.HTTPSessionStreamEndTest do
  # A legacy session's GET stream that ends while it writes a page of its
  # replay: the session is deleted between two of the page's events. The
  # stream ends the response normally, with what it wrote so far, instead of
  # raising, so the server closes the response cleanly and logs nothing.
  use ExUnit.Case, async: false

  import Arbor.MCP.TestHelpers, only: [wait_until: 2]
  import ExUnit.CaptureLog

  alias Arbor.MCP.{HttpPlug, SessionManager}
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{Deadline, OutputCodec}

  @version "2025-11-25"

  defmodule Handler do
    use Arbor.MCP.Server.Handler
  end

  # Plug's test adapter, except that the first chunk carrying the payload's
  # marker waits, before it is written, until the test lets it go.
  defmodule HoldingAdapter do
    @behaviour Plug.Conn.Adapter

    alias Plug.Adapters.Test.Conn, as: Inner

    defdelegate send_resp(payload, status, headers, body), to: Inner
    defdelegate send_file(payload, status, headers, path, offset, length), to: Inner
    defdelegate send_chunked(payload, status, headers), to: Inner
    defdelegate read_req_body(payload, options), to: Inner
    defdelegate inform(payload, status, headers), to: Inner
    defdelegate upgrade(payload, protocol, options), to: Inner
    defdelegate push(payload, path, headers), to: Inner
    defdelegate get_peer_data(payload), to: Inner
    defdelegate get_sock_data(payload), to: Inner
    defdelegate get_ssl_data(payload), to: Inner
    defdelegate get_http_protocol(payload), to: Inner

    def chunk(%{hold: {marker, test}} = payload, body) do
      if marker && String.contains?(IO.iodata_to_binary(body), marker) do
        send(test, {:writing, self()})

        receive do
          :continue -> :ok
        end

        Inner.chunk(%{payload | hold: {nil, test}}, body)
      else
        Inner.chunk(payload, body)
      end
    end
  end

  for mode <- [:stream, :oneshot] do
    test "a #{mode} GET stream whose session is deleted mid-page ends cleanly" do
      opts =
        HttpPlug.init(runtime: runtime(), protocol_mode: :legacy_only, sse_mode: unquote(mode))

      session = initialize(opts)
      {:ok, service} = Runtime.service(opts.runtime, :sessions)
      {:ok, lease} = SessionManager.ensure_session(service, session, %{}, [])
      {:ok, cursor} = append(service, lease, "replay-zero")

      for text <- ["replay-one", "replay-two", "replay-three"],
          do: assert({:ok, _event} = append(service, lease, text))

      test = self()

      log =
        capture_log(fn ->
          # The stream resumes after the first event, so its first page holds
          # the other three, and the session is deleted while it writes one.
          stream =
            Task.async(fn ->
              :get
              |> request(session, cursor.id)
              |> hold_at("replay-one", test)
              |> HttpPlug.call(opts)
            end)

          assert_receive {:writing, writer}, 2_000
          assert HttpPlug.call(request(:delete, session), opts).status == 204
          send(writer, :continue)

          conn = Task.await(stream, 5_000)
          assert conn.status == 200
          assert conn.resp_body =~ "replay-one"
          refute conn.resp_body =~ "replay-two"
        end)

      refute log =~ "[error]"
    end
  end

  # The stream's deadline (the Runtime's request timeout) passes after its
  # proof was checked, while the next event is encoded under it. The stream
  # is suspended inside `OutputCodec.prepare/2` on that event, which is large
  # enough to still be walking its term, until the deadline it is encoding
  # under has passed.
  for mode <- [:stream, :oneshot] do
    test "a #{mode} GET stream whose deadline passes while it encodes an event ends cleanly" do
      runtime = runtime(request_timeout_ms: 1_000)

      opts =
        HttpPlug.init(runtime: runtime, protocol_mode: :legacy_only, sse_mode: unquote(mode))

      session = initialize(opts)
      {:ok, service} = Runtime.service(runtime, :sessions)
      {:ok, lease} = SessionManager.ensure_session(service, session, %{}, [])
      {:ok, cursor} = append(service, lease, "replay-zero")
      # As many JSON values as one replay append may carry, so encoding it
      # takes a while.
      assert {:ok, _event} = append(service, lease, %{"bulk" => List.duplicate(0, 30_000)})

      # The stream runs at low priority and the test at high priority while
      # it waits, so the stream is still encoding when the test suspends it.
      # It is unlinked and monitored, so a crash fails the test through
      # await_stream/2 rather than killing it.
      test = self()

      {stream, monitor} =
        spawn_monitor(fn ->
          Process.flag(:priority, :low)

          receive do
            :go ->
              send(
                test,
                {:stream_done, self(), HttpPlug.call(request(:get, session, cursor.id), opts)}
              )
          end
        end)

      # Runs however the test ends. The test process's own exit releases the
      # suspension it holds, so a stream still alive here is only stopped.
      on_exit(fn ->
        :erlang.trace_pattern({OutputCodec, :prepare, 2}, false, [:global])
        Process.exit(stream, :kill)
      end)

      log =
        capture_log(fn ->
          :erlang.trace_pattern({OutputCodec, :prepare, 2}, true, [:global])
          :erlang.trace(stream, true, [:call])

          try do
            previous = Process.flag(:priority, :high)
            send(stream, :go)
            deadline = suspend_encoding_bulk(stream)
            Process.flag(:priority, previous)
            wait_until(fn -> Deadline.now() > deadline end, timeout: 2_000, interval: 10)
            :erlang.trace(stream, false, [:call])
            true = :erlang.resume_process(stream)

            conn = await_stream(stream, monitor)
            assert conn.status == 200
            assert conn.resp_body =~ "event: connected"
            refute conn.resp_body =~ "bulk"
          after
            :erlang.trace_pattern({OutputCodec, :prepare, 2}, false, [:global])
          end
        end)

      refute log =~ "[error]"
    end
  end

  defp await_stream(stream, monitor) do
    receive do
      {:stream_done, ^stream, conn} ->
        Process.demonitor(monitor, [:flush])
        conn

      {:DOWN, ^monitor, :process, ^stream, reason} ->
        flunk("the GET stream crashed instead of ending: #{inspect(reason)}")
    after
      5_000 -> flunk("the GET stream did not end")
    end
  end

  # Suspends the stream as it starts encoding the bulk event, and returns the
  # deadline it encodes under.
  defp suspend_encoding_bulk(pid) do
    receive do
      {:trace, ^pid, :call,
       {OutputCodec, :prepare, [%{"params" => %{"data" => %{"bulk" => _}}}, options]}} ->
        true = :erlang.suspend_process(pid)
        Keyword.fetch!(options, :deadline)

      {:trace, ^pid, :call, _other} ->
        suspend_encoding_bulk(pid)
    after
      2_000 -> flunk("the stream never encoded the bulk event")
    end
  end

  defp runtime(opts \\ []) do
    root =
      start_supervised!({Runtime, [handler: Handler, services: [sessions: []]] ++ opts})

    {:ok, runtime} = Runtime.ref(root)
    runtime
  end

  defp initialize(opts) do
    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "stream-end", "version" => "1"}
      }
    }

    conn = :post |> request(nil, nil, initialize) |> HttpPlug.call(opts)
    assert conn.status == 200, conn.resp_body
    [session] = Plug.Conn.get_resp_header(conn, "mcp-session-id")
    initialized = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    assert (:post |> request(session, nil, initialized) |> HttpPlug.call(opts)).status == 202
    session
  end

  defp append(service, lease, text) do
    message = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/message",
      "params" => %{"level" => "info", "data" => text}
    }

    SessionManager.append_event(service, lease, "message", message, [])
  end

  defp request(method, session, cursor \\ nil, body \\ nil) do
    conn =
      if body,
        do:
          Plug.Test.conn(method, "/mcp", Jason.encode!(body))
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Plug.Conn.put_req_header("accept", "application/json"),
        else:
          Plug.Test.conn(method, "/mcp")
          |> Plug.Conn.put_req_header("accept", "text/event-stream")

    conn = Plug.Conn.put_req_header(conn, "mcp-protocol-version", @version)
    conn = if session, do: Plug.Conn.put_req_header(conn, "mcp-session-id", session), else: conn
    if cursor, do: Plug.Conn.put_req_header(conn, "last-event-id", cursor), else: conn
  end

  defp hold_at(%Plug.Conn{adapter: {Plug.Adapters.Test.Conn, payload}} = conn, marker, test),
    do: %{conn | adapter: {HoldingAdapter, Map.put(payload, :hold, {marker, test})}}
end
