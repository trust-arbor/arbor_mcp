defmodule Arbor.MCP.Server.HTTPRequestStreamCloseTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.{Context, Runtime, Transport}
  alias Arbor.MCP.Server.Runtime.{HTTPWriterProxy, HTTPWriterRegistry}

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :test_pid)}

    @impl true
    def handle_call_tool("hold", _arguments, test_pid) do
      send(test_pid, {:tool_started, self()})

      receive do
        :release -> {:ok, %{content: [%{type: "text", text: "released"}]}, test_pid}
      end
    end

    def handle_call_tool("fast", _arguments, test_pid),
      do: {:ok, %{content: [%{type: "text", text: "fast"}]}, test_pid}

    # Progress is acknowledged only after its frame was written.
    def handle_call_tool("progress", _arguments, test_pid) do
      send(test_pid, {:tool_started, self()})
      :ok = Context.report_progress(1)
      receive do: (:next -> :ok)
      :ok = Context.report_progress(2)

      receive do
        :release -> {:ok, %{content: [%{type: "text", text: "progressed"}]}, test_pid}
      end
    end

    # Reports progress each time it is told to and tells the test what each
    # report returned. After a report fails it waits for its cancellation,
    # or to be released.
    def handle_call_tool("report", _arguments, test_pid) do
      send(test_pid, {:tool_started, self()})
      report(test_pid, 1)
    end

    defp report(test_pid, progress) do
      receive do
        :report ->
          result = Context.report_progress(progress)
          send(test_pid, {:reported, progress, result})
          if result == :ok, do: report(test_pid, progress + 1), else: after_closed(test_pid)

        :release ->
          {:ok, %{content: [%{type: "text", text: "reported"}]}, test_pid}
      end
    end

    defp after_closed(test_pid) do
      receive do
        {:arbor_mcp_cancelled, _token, reason} -> send(test_pid, {:tool_cancelled, reason})
        :release -> :ok
      end

      {:ok, %{content: [%{type: "text", text: "reported"}]}, test_pid}
    end
  end

  # A borrowed adapter that reports every write to the test process and can
  # hold or fail a keepalive comment. Its callbacks run in the request process.
  defmodule StubAdapter do
    alias Plug.Adapters.Test.Conn

    defdelegate read_req_body(state, opts), to: Conn

    def send_resp(state, status, headers, body) do
      send(state.observer, {:stream_resp, self(), status})
      Conn.send_resp(state, status, headers, body)
    end

    def send_chunked(state, status, headers) do
      send(state.observer, {:stream_headers, self(), status})

      if state.raise_headers,
        do: raise(Bandit.TransportError, message: "Unrecoverable error: closed", error: :closed)

      Conn.send_chunked(state, status, headers)
    end

    def chunk(state, body) do
      wire = IO.iodata_to_binary(body)
      send(state.observer, {:stream_wire, self(), wire})

      if state.report_stack and wire == ":\r\n\r\n",
        do: send(state.observer, {:keepalive_stack, self(), Process.info(self(), :stack_size)})

      cond do
        fail?(wire, state) ->
          {:error, :closed}

        wire == ":\r\n\r\n" and state.hold_keepalive ->
          send(state.observer, {:keepalive_entered, self()})
          receive do: (:return_io -> :ok)
          Conn.chunk(%{state | hold_keepalive: false}, body)

        true ->
          Conn.chunk(state, body)
      end
    end

    defp fail?(":\r\n\r\n", state), do: state.fail_keepalive
    defp fail?("data: " <> _frame, state), do: state.fail_terminal or closed?(state.fail_frames)
    defp fail?(_wire, _state), do: false

    # fail_frames is an atomics array the test sets to close the stream.
    defp closed?(false), do: false
    defp closed?(stream), do: :atomics.get(stream, 1) == 1
  end

  # Plug.Cowboy's chunk/2 never returns an error. Cowboy notices the closed
  # connection itself and terminates the request process, and the gateway's
  # monitor on that process cancels the request, keepalive or not. Bandit has
  # no such signal: it finds the closed peer only when a keepalive write
  # fails, so the Bandit variant is the end-to-end proof of keepalive
  # detection. The StubAdapter tests below cover each keepalive outcome.
  for {adapter, detection} <- [
        cowboy: "Cowboy terminating the request process",
        bandit: "a failed keepalive write"
      ] do
    @tag :physical_http
    test "#{adapter} cancels a blocked tool after its request SSE stream closes, through #{detection}" do
      {runtime, port} = start_server(unquote(adapter))
      conn = connect(port)
      {:ok, conn, ref} = request(conn, "hold")
      assert_receive {:tool_started, worker}, 1_000
      monitor = Process.monitor(worker)
      {conn, events} = receive_until(conn, ref, &heartbeat?/1)
      assert {:status, ref, 200} in events
      assert heartbeat?(events)
      assert content_type(events, ref) == "text/event-stream"

      other_conn = connect(port)
      {:ok, other_conn, other_ref} = request(other_conn, "hold")
      assert_receive {:tool_started, other_worker}, 1_000
      {other_conn, _other_events} = receive_until(other_conn, other_ref, &heartbeat?/1)

      Mint.HTTP.close(conn)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
      assert Process.alive?(other_worker)
      send(other_worker, :release)

      {other_conn, other_tail} =
        receive_until(other_conn, other_ref, &Enum.member?(&1, {:done, other_ref}))

      assert response_body(other_tail, other_ref) =~ "\"text\":\"released\""
      Mint.HTTP.close(other_conn)
      {:ok, runtime_ref} = Runtime.ref(runtime)
      {:ok, domain} = HTTPWriterProxy.domain(runtime_ref)

      Arbor.MCP.TestHelpers.wait_until(fn ->
        Runtime.stats!(runtime).reserved == 0 and
          match?(%{frames: 0, bytes: 0}, HTTPWriterRegistry.stats(domain))
      end)
    end

    @tag :physical_http
    test "#{adapter} keeps a connected tool running across keepalives and ends with its response" do
      {_runtime, port} = start_server(unquote(adapter))
      conn = connect(port)
      {:ok, conn, ref} = request(conn, "hold")
      assert_receive {:tool_started, worker}, 1_000
      {conn, events} = receive_until(conn, ref, &heartbeat?/1)
      assert heartbeat?(events)
      assert content_type(events, ref) == "text/event-stream"
      assert Process.alive?(worker)

      send(worker, :release)
      {conn, tail} = receive_until(conn, ref, &Enum.member?(&1, {:done, ref}))
      body = response_body(events ++ tail, ref)
      assert body =~ "\"text\":\"released\""
      # Only comments precede the response frame, and nothing follows it.
      assert body =~ ~r/\A(?::\r\n\r\n)+data: [^\r\n]+\r\n\r\n\z/
      Mint.HTTP.close(conn)

      # A slow machine may write a comment before even a fast response, but
      # never one after it.
      conn = connect(port)
      {:ok, conn, ref} = request(conn, "fast")
      {conn, events} = receive_until(conn, ref, &Enum.member?(&1, {:done, ref}))
      assert response_body(events, ref) =~ "\"text\":\"fast\""
      assert response_body(events, ref) =~ ~r/\A(?::\r\n\r\n)*data: [^\r\n]+\r\n\r\n\z/
      Mint.HTTP.close(conn)

      conn = connect(port)
      {:ok, conn, ref} = request(conn, "fast", false)
      {conn, events} = receive_until(conn, ref, &Enum.member?(&1, {:done, ref}))
      assert content_type(events, ref) =~ "application/json"

      assert Jason.decode!(response_body(events, ref))["result"]["content"] == [
               %{"type" => "text", "text" => "fast"}
             ]

      Mint.HTTP.close(conn)
    end
  end

  for adapter <- [:cowboy, :bandit] do
    @tag :physical_http
    test "#{adapter} ends a stream with a JSON-RPC error when its runtime stops after a keepalive" do
      {runtime, port} = start_server(unquote(adapter))
      conn = connect(port)
      id = System.unique_integer([:positive])
      {:ok, conn, ref} = request(conn, "hold", true, id)
      assert_receive {:tool_started, _worker}, 1_000
      {conn, events} = receive_until(conn, ref, &heartbeat?/1)

      assert :ok = Runtime.stop(runtime)
      {conn, tail} = receive_until(conn, ref, &Enum.member?(&1, {:done, ref}))
      body = response_body(events ++ tail, ref)

      # The 200 and its comments are followed by one terminal error for the
      # request, and the stream then ends cleanly.
      assert [_body, frame] = Regex.run(~r/\A(?::\r\n\r\n)+data: ([^\r\n]+)\r\n\r\n\z/, body)
      assert %{"id" => ^id, "error" => %{"code" => -32_603}} = Jason.decode!(frame)
      Mint.HTTP.close(conn)
    end

    @tag :physical_http
    test "owned #{adapter} servers apply :request_keepalive_interval_ms" do
      root =
        start_supervised!(
          {Runtime,
           handler: Handler,
           handler_args: [test_pid: self()],
           transport: :http,
           protocol_mode: :modern_only,
           http: [
             adapter: unquote(adapter),
             port: 0,
             host: {127, 0, 0, 1},
             request_keepalive_interval_ms: 40
           ]}
        )

      conn = connect(owned_port(root))
      {:ok, conn, ref} = request(conn, "hold")
      assert_receive {:tool_started, worker}, 1_000
      # The 15-second default would not write a comment before this times out.
      {conn, events} = receive_until(conn, ref, &heartbeat?/1)
      assert content_type(events, ref) == "text/event-stream"

      send(worker, :release)
      {conn, tail} = receive_until(conn, ref, &Enum.member?(&1, {:done, ref}))
      assert response_body(events ++ tail, ref) =~ "\"text\":\"released\""
      Mint.HTTP.close(conn)
    end

    test "owned #{adapter} servers reject an invalid request interval like the subscription interval" do
      for key <- [:subscription_keepalive_interval_ms, :request_keepalive_interval_ms] do
        http = [{:adapter, unquote(adapter)}, {:port, 0}, {:host, {127, 0, 0, 1}}, {key, 0}]

        # The mount validates both intervals when the listener initializes it.
        assert {:error, _reason} =
                 start_supervised(
                   {Runtime,
                    handler: Handler,
                    handler_args: [test_pid: self()],
                    transport: :http,
                    protocol_mode: :modern_only,
                    http: http},
                   id: key
                 )

        assert_raise ArgumentError, ~r/#{key} must be a positive integer or :infinity/, fn ->
          Arbor.MCP.HttpPlug.init([{key, 0}, runtime: :not_started])
        end
      end
    end
  end

  test "owned and borrowed HTTP configuration keep both keepalive intervals for the mount" do
    for ownership <- [:owned, :borrowed] do
      assert {:ok, %{plug_options: plug}} =
               Arbor.MCP.Server.HTTP.Config.new(
                 [
                   transport: :http,
                   http_adapter: :bandit,
                   request_keepalive_interval_ms: 40,
                   subscription_keepalive_interval_ms: 50
                 ],
                 ownership
               )

      assert plug[:request_keepalive_interval_ms] == 40
      assert plug[:subscription_keepalive_interval_ms] == 50
    end
  end

  test "keepalives interleave with progress notifications in write order" do
    runtime = start_runtime([])
    socket = stream_request(runtime, "progress", [])
    assert_receive {:tool_started, worker}, 1_000
    first = collect_wires(socket, &(wire_shape(&1) =~ ~r/1K\z/))
    send(worker, :next)
    second = collect_wires(socket, &(wire_shape(&1) =~ ~r/2K\z/))
    send(worker, :release)
    {rest, {:returned, conn}} = finish_stream(socket)

    assert wire_shape(first ++ second ++ rest) =~ ~r/\AK*1K+2K+R\z/
    assert List.last(rest) =~ "\"text\":\"progressed\""
    assert conn.state == :chunked
    assert_released(runtime)
  end

  test "several keepalives precede a successful response and none follow it" do
    runtime = start_runtime([])
    socket = stream_request(runtime, "hold", [])
    assert_receive {:tool_started, worker}, 1_000
    keepalives = collect_wires(socket, &(length(&1) == 3))
    assert keepalives == List.duplicate(":\r\n\r\n", 3)

    send(worker, :release)
    {rest, {:returned, conn}} = finish_stream(socket)
    assert wire_shape(keepalives ++ rest) =~ ~r/\AK{3,}R\z/
    assert List.last(rest) =~ "\"text\":\"released\""

    # The request process has returned, so no later write can follow.
    assert conn.state == :chunked
    refute_received {:stream_wire, ^socket, _wire}
    assert_released(runtime)
  end

  test ":infinity sends no request keepalives" do
    runtime = start_runtime([])

    socket =
      stream_request(runtime, "progress", [], request_keepalive_interval_ms: :infinity)

    assert_receive {:tool_started, worker}, 1_000
    first = collect_wires(socket, &(length(&1) == 1))
    assert wire_shape(first) == "1"

    # Ten 20 ms intervals of quiet stream would otherwise carry comments.
    refute_receive {:stream_wire, ^socket, _wire}, 200

    send(worker, :next)
    send(worker, :release)
    {rest, {:returned, _conn}} = finish_stream(socket)
    assert wire_shape(first ++ rest) == "12R"
    assert_released(runtime)
  end

  test "a slow subscriptions/listen setup gets no request keepalive before its own stream" do
    runtime = start_runtime([])
    parent = self()

    authorize = fn filter, _context ->
      send(parent, {:authorizing_listen, self()})
      receive do: (:authorize -> {:ok, filter})
    end

    socket = stream_listen(runtime, [gate: true], authorize_subscription_filter: authorize)
    await = {Arbor.MCP.HttpPlug.RuntimeWriter, :await, 2}
    :erlang.trace_pattern(await, true, [])
    on_exit(fn -> :erlang.trace_pattern(await, false, []) end)
    :erlang.trace(socket, true, [:call, {:tracer, self()}])
    send(socket, :go)

    # The wait itself is observed, so a slow request process cannot make this
    # pass: the listen request waits with no request keepalive at all.
    assert_receive {:trace, ^socket, :call, {_writer, :await, [_conn, :infinity]}}, 1_000
    assert_receive {:authorizing_listen, authorizer}, 1_000

    # A comment here would send the headers that the subscription stream sends
    # itself, and its send_chunked would then raise Plug.Conn.AlreadySentError.
    refute_received {:stream_headers, ^socket, _status}
    refute_received {:stream_wire, ^socket, _wire}

    send(authorizer, :authorize)
    assert_receive {:stream_headers, ^socket, 200}, 1_000
    assert_receive {:stream_wire, ^socket, acknowledgment}, 1_000
    assert acknowledgment =~ "notifications/subscriptions/acknowledged"
    refute_received {:stream_result, ^socket, _result}
    assert Process.alive?(socket)
  end

  test "a legacy request's event stream gets no request keepalives" do
    runtime = start_runtime(protocol_mode: :prefer_modern)
    session = legacy_session(runtime)

    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 7,
        method: "tools/call",
        params: %{name: "hold", arguments: %{}, _meta: %{"progressToken" => "legacy"}}
      })

    headers = [{"mcp-protocol-version", "2025-11-25"}, {"mcp-session-id", session}]

    socket =
      stream_post(runtime, body, headers, [gate: true], protocol_mode: :prefer_modern)

    await = {Arbor.MCP.HttpPlug.RuntimeWriter, :await, 2}
    :erlang.trace_pattern(await, true, [])
    on_exit(fn -> :erlang.trace_pattern(await, false, []) end)
    :erlang.trace(socket, true, [:call, {:tracer, self()}])
    send(socket, :go)

    # A keepalive's failed write would cancel the request, and the legacy
    # revisions say a disconnect SHOULD NOT; so its wait sends none at all.
    assert_receive {:trace, ^socket, :call, {_writer, :await, [_conn, :infinity]}}, 1_000
    assert_receive {:tool_started, worker}, 1_000
    send(worker, :release)
    {wires, {:returned, conn}} = finish_stream(socket)
    assert wire_shape(wires) == "R"
    assert List.last(wires) =~ "\"id\":7"
    assert conn.state == :chunked
  end

  test "a streaming initialize is answered before any request keepalive can send headers" do
    runtime = start_runtime([])

    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2026-07-28",
          capabilities: %{},
          clientInfo: %{name: "close-test", version: "1"},
          _meta: %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{},
            "progressToken" => "initialize"
          }
        }
      })

    socket =
      stream_post(runtime, body, [{"mcp-method", "initialize"}], [],
        request_keepalive_interval_ms: 1
      )

    # Modern requests have no initialize, so it is rejected before the SSE
    # wait. Its initialization-error handling therefore never runs on a conn
    # that a keepalive has chunked; the plug also guards that case.
    assert_receive {:stream_result, ^socket, {:returned, conn}}, 1_000
    assert conn.state == :sent
    assert %{"error" => %{"code" => _code}} = Jason.decode!(conn.resp_body)
    refute_received {:stream_headers, ^socket, _status}
    refute_received {:stream_wire, ^socket, _wire}
  end

  test "a stream that loses its invocation after a keepalive ends with a JSON-RPC error" do
    runtime = start_runtime([])
    id = System.unique_integer([:positive])
    socket = stream_request(runtime, "hold", [], [], id)
    assert_receive {:tool_started, _worker}, 1_000
    assert_receive {:stream_wire, ^socket, ":\r\n\r\n"}, 1_000

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = Runtime.stop(runtime)
        assert_receive {:stream_wire, ^socket, "data: " <> frame}, 2_000
        assert %{"id" => ^id, "error" => %{"code" => -32_603}} = Jason.decode!(frame)
        assert_receive {:stream_result, ^socket, {:returned, conn}}, 2_000
        assert conn.state == :chunked
      end)

    # The keepalive already sent the headers, so the plug must not attempt a
    # 500 or a JSON-RPC rejection with the conn it had before the stream began.
    refute log =~ "MCP request processing failed"
    refute_received {:stream_resp, ^socket, _status}
    refute_received {:stream_wire, ^socket, _wire}
  end

  test "a terminal error for a request id that is not a string or integer uses a null id" do
    runtime = start_runtime([])

    # The suspended gateway has not yet rejected the invalid id when the
    # Runtime stops, so the request is still waiting through keepalives.
    {:ok, gateway} = Arbor.MCP.Server.Runtime.HTTPGateway.address(runtime)
    :sys.suspend(gateway)
    on_exit(fn -> if Process.alive?(gateway), do: :sys.resume(gateway) end)

    socket = stream_request(runtime, "hold", [], [], %{})
    assert_receive {:stream_wire, ^socket, ":\r\n\r\n"}, 1_000
    stop = Task.async(fn -> Runtime.stop(runtime) end)
    assert_receive {:stream_wire, ^socket, "data: " <> frame}, 10_000
    assert %{"id" => nil, "error" => %{"code" => -32_603}} = Jason.decode!(frame)
    assert_receive {:stream_result, ^socket, {:returned, conn}}, 1_000
    assert conn.state == :chunked
    # The suspended gateway can make the stop report unconfirmed cleanup.
    _stopped = Task.await(stop, 15_000)
  end

  test "a terminal error that cannot be written ends the stream without raising" do
    runtime = start_runtime([])
    socket = stream_request(runtime, "hold", fail_terminal: true)
    assert_receive {:tool_started, _worker}, 1_000
    assert_receive {:stream_wire, ^socket, ":\r\n\r\n"}, 1_000
    assert :ok = Runtime.stop(runtime)
    assert_receive {:stream_wire, ^socket, "data: " <> _frame}, 2_000
    assert_receive {:stream_result, ^socket, {:returned, conn}}, 2_000
    assert conn.state == :chunked
  end

  test "a handler timeout during an in-flight keepalive still writes the timeout error" do
    runtime = start_runtime(request_timeout_ms: 1_000)
    socket = stream_request(runtime, "hold", hold_keepalive: true)
    assert_receive {:tool_started, worker}, 1_000
    monitor = Process.monitor(worker)
    assert_receive {:keepalive_entered, ^socket}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 3_000

    # The comment is not the request's output, so the gateway still queues
    # the failure response behind it instead of abandoning the stream.
    domain = writer_domain(runtime)

    Arbor.MCP.TestHelpers.wait_until(fn ->
      match?(%{in_flight: 1, queued: 1}, HTTPWriterRegistry.stats(domain))
    end)

    send(socket, :return_io)
    assert_receive {:stream_wire, ^socket, "data: " <> frame}, 1_000
    assert %{"error" => %{"code" => _code, "message" => _message}} = Jason.decode!(frame)
    assert_receive {:stream_result, ^socket, {:returned, conn}}, 1_000
    assert conn.state == :chunked
    assert_released(runtime)
  end

  test "a failed first keepalive returns the chunked conn and cancels the request" do
    runtime = start_runtime([])
    socket = stream_request(runtime, "hold", fail_keepalive: true)
    assert_receive {:tool_started, worker}, 1_000
    monitor = Process.monitor(worker)

    # The headers went out with the first comment and only its chunk failed,
    # as when a reset arrives between the two sends on Bandit.
    assert_receive {:stream_headers, ^socket, 200}, 1_000
    assert_receive {:stream_wire, ^socket, ":\r\n\r\n"}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
    assert_receive {:stream_result, ^socket, {:returned, conn}}, 1_000

    # An :unset conn here makes Bandit raise Plug.Conn.NotSentError.
    assert conn.state == :chunked
    refute_received {:stream_wire, ^socket, _wire}
    assert_released(runtime)
  end

  test "a keepalive whose headers raise cancels the request and re-raises the adapter error" do
    runtime = start_runtime([])
    socket = stream_request(runtime, "hold", raise_headers: true)
    assert_receive {:tool_started, worker}, 1_000
    monitor = Process.monitor(worker)
    assert_receive {:stream_headers, ^socket, 200}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000

    # The adapter handles its own transport error; an unsent conn returned
    # in its place would make Bandit raise Plug.Conn.NotSentError instead.
    assert_receive {:stream_result, ^socket, {:raised, :error, %Bandit.TransportError{}}}, 1_000
    assert_released(runtime)
  end

  # Closing the stream is how a modern client cancels, so a frame that finds
  # it closed ends the response as a failed keepalive does, instead of raising
  # RuntimeWriter.AdmissionError for the adapter to log (#179).
  test "a progress frame on a closed stream cancels the request without raising" do
    runtime = start_runtime([])
    stream = :atomics.new(1, [])
    socket = report_request(runtime, stream)
    assert_receive {:tool_started, worker}, 1_000

    send(worker, :report)
    assert_receive {:reported, 1, :ok}, 1_000
    :atomics.put(stream, 1, 1)
    send(worker, :report)

    assert_receive {:reported, 2, {:error, :stream_closed}}, 1_000
    assert_receive {:tool_cancelled, _reason}, 1_000
    {wires, {:returned, conn}} = finish_stream(socket)
    assert wire_shape(wires) == "12"
    assert conn.state == :chunked
    assert_released(runtime)
  end

  test "a first frame whose chunk fails returns the chunked conn and cancels the request" do
    runtime = start_runtime([])
    stream = :atomics.new(1, [])
    :atomics.put(stream, 1, 1)
    socket = report_request(runtime, stream)
    assert_receive {:tool_started, worker}, 1_000

    send(worker, :report)
    assert_receive {:stream_headers, ^socket, 200}, 1_000
    assert_receive {:reported, 1, {:error, :stream_closed}}, 1_000
    assert_receive {:tool_cancelled, _reason}, 1_000
    {wires, {:returned, conn}} = finish_stream(socket)
    assert wire_shape(wires) == "1"

    # An :unset conn here makes Bandit raise Plug.Conn.NotSentError.
    assert conn.state == :chunked
    assert_released(runtime)
  end

  test "a response frame on a closed stream ends the response without raising" do
    runtime = start_runtime([])
    stream = :atomics.new(1, [])
    socket = report_request(runtime, stream)
    assert_receive {:tool_started, worker}, 1_000

    send(worker, :report)
    assert_receive {:reported, 1, :ok}, 1_000
    :atomics.put(stream, 1, 1)
    send(worker, :release)

    {wires, {:returned, conn}} = finish_stream(socket)
    assert wire_shape(wires) == "1R"
    assert conn.state == :chunked
    assert_released(runtime)
  end

  test "a progress frame on a closed legacy stream ends the response and the request runs on" do
    runtime = start_runtime(protocol_mode: :prefer_modern)
    session = legacy_session(runtime)
    stream = :atomics.new(1, [])

    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 7,
        method: "tools/call",
        params: %{name: "report", arguments: %{}, _meta: %{"progressToken" => "legacy"}}
      })

    headers = [{"mcp-protocol-version", "2025-11-25"}, {"mcp-session-id", session}]

    socket =
      stream_post(runtime, body, headers, [fail_frames: stream], protocol_mode: :prefer_modern)

    assert_receive {:tool_started, worker}, 1_000
    send(worker, :report)
    assert_receive {:reported, 1, :ok}, 1_000
    :atomics.put(stream, 1, 1)
    send(worker, :report)

    assert_receive {:reported, 2, {:error, :stream_closed}}, 1_000
    {wires, {:returned, conn}} = finish_stream(socket)
    assert wire_shape(wires) == "12"
    assert conn.state == :chunked

    # The legacy revisions say a disconnect SHOULD NOT be taken for a
    # cancellation, so the tool keeps running until it is released.
    refute_receive {:tool_cancelled, _reason}, 200
    send(worker, :release)
    assert_released(runtime)
  end

  @tag :physical_http
  test "bandit logs no error when a progress frame finds the request stream closed" do
    handler = {__MODULE__, make_ref()}
    events = [:bandit, :request, :start]
    :ok = :telemetry.attach(handler, events, &__MODULE__.report_bandit_request/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {runtime, port} = start_server(:bandit, request_keepalive_interval_ms: :infinity)
        conn = connect(port)
        {:ok, conn, ref} = request(conn, "report")
        assert_receive {:bandit_request, request_process}, 1_000
        monitor = Process.monitor(request_process)
        assert_receive {:tool_started, worker}, 1_000

        send(worker, :report)
        assert_receive {:reported, 1, :ok}, 1_000
        {conn, _events} = receive_until(conn, ref, &progress?/1)
        Mint.HTTP.close(conn)

        # Over TCP the first write after the client closes usually succeeds
        # and the next one fails.
        assert {:error, :stream_closed} = report_until_closed(worker, 2)
        assert_receive {:tool_cancelled, _reason}, 1_000

        # Bandit would log a raised plug error from the request process
        # before that process ends.
        assert_receive {:DOWN, ^monitor, :process, ^request_process, _reason}, 2_000
        assert_released(runtime)
      end)

    refute log =~ "AdmissionError"
    refute log =~ "[error]"
  end

  def report_bandit_request(_event, _measurements, _metadata, test_pid),
    do: send(test_pid, {:bandit_request, self()})

  test "keepalives keep the request process stack bounded" do
    runtime = start_runtime([])

    socket =
      stream_request(runtime, "hold", [report_stack: true], request_keepalive_interval_ms: 1)

    assert_receive {:tool_started, worker}, 1_000

    sizes =
      for _keepalive <- 1..200 do
        assert_receive {:keepalive_stack, ^socket, {:stack_size, size}}, 1_000
        size
      end

    # Each comment is written from the same call site, so a tail-recursive
    # wait loop reports the same stack size every time.
    assert Enum.max(sizes) == hd(sizes)

    send(worker, :release)
    assert_receive {:stream_result, ^socket, {:returned, conn}}, 1_000
    assert conn.state == :chunked
    assert_released(runtime)
  end

  defp start_runtime(opts) do
    root =
      start_supervised!(
        {Runtime,
         Keyword.merge(
           [
             handler: Handler,
             handler_args: [test_pid: self()],
             transport: :mounted_http,
             protocol_mode: :modern_only
           ],
           opts
         )},
        id: make_ref()
      )

    {:ok, runtime} = Runtime.ref(root)
    runtime
  end

  defp stream_request(runtime, name, adapter_opts, plug_opts \\ [], id \\ nil) do
    headers = [{"mcp-method", "tools/call"}, {"mcp-name", name}]
    stream_post(runtime, tool_body(name, true, id), headers, adapter_opts, plug_opts)
  end

  # A "report" tool call whose data frames fail once `stream` is set. With no
  # keepalives, each failed write is a frame.
  defp report_request(runtime, stream) do
    stream_request(runtime, "report", [fail_frames: stream],
      request_keepalive_interval_ms: :infinity
    )
  end

  # Has the tool report until a report finds the stream closed.
  defp report_until_closed(worker, progress) when progress <= 20 do
    send(worker, :report)

    receive do
      {:reported, ^progress, :ok} -> report_until_closed(worker, progress + 1)
      {:reported, ^progress, result} -> result
    after
      1_000 -> flunk("report #{progress} did not return")
    end
  end

  # A subscriptions/listen request that, with its progress token, also selects
  # the request SSE wait before its listener is set up.
  defp stream_listen(runtime, adapter_opts, plug_opts) do
    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: System.unique_integer([:positive]),
        method: "subscriptions/listen",
        params: %{
          notifications: %{toolsListChanged: true},
          _meta: %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{},
            "progressToken" => "listen"
          }
        }
      })

    stream_post(
      runtime,
      body,
      [{"mcp-method", "subscriptions/listen"}],
      adapter_opts,
      plug_opts
    )
  end

  defp stream_post(runtime, body, headers, adapter_opts, plug_opts) do
    parent = self()

    socket =
      spawn(fn ->
        headers =
          [
            {"content-type", "application/json"},
            {"accept", "application/json, text/event-stream"}
            | List.keystore(
                headers,
                "mcp-protocol-version",
                0,
                List.keyfind(headers, "mcp-protocol-version", 0) ||
                  {"mcp-protocol-version", "2026-07-28"}
              )
          ]

        conn =
          Enum.reduce(headers, Plug.Test.conn(:post, "/mcp", body), fn {name, value}, conn ->
            Plug.Conn.put_req_header(conn, name, value)
          end)

        {_adapter, state} = conn.adapter

        stub =
          Map.merge(
            state,
            Map.new(
              Keyword.merge(
                [
                  observer: parent,
                  hold_keepalive: false,
                  fail_keepalive: false,
                  raise_headers: false,
                  report_stack: false,
                  fail_terminal: false,
                  fail_frames: false
                ],
                Keyword.delete(adapter_opts, :gate)
              )
            )
          )

        # A gated request waits so the test can trace it from its first call.
        if adapter_opts[:gate], do: receive(do: (:go -> :ok))

        opts =
          Arbor.MCP.HttpPlug.init(
            Keyword.merge(
              [runtime: runtime, protocol_mode: :modern_only, request_keepalive_interval_ms: 20],
              plug_opts
            )
          )

        result =
          try do
            {:returned, Arbor.MCP.HttpPlug.call(%{conn | adapter: {StubAdapter, stub}}, opts)}
          catch
            kind, reason -> {:raised, kind, reason}
          end

        send(parent, {:stream_result, self(), result})
      end)

    on_exit(fn -> if Process.alive?(socket), do: Process.exit(socket, :kill) end)
    socket
  end

  # Collects one stream's writes in order until `done?` holds for them.
  defp collect_wires(socket, done?, wires \\ []) do
    if done?.(wires) do
      wires
    else
      receive do
        {:stream_wire, ^socket, wire} -> collect_wires(socket, done?, wires ++ [wire])
      after
        2_000 -> flunk("timed out waiting for request stream writes: #{inspect(wires)}")
      end
    end
  end

  # Collects the remaining writes; the request process sends its result last.
  defp finish_stream(socket, wires \\ []) do
    receive do
      {:stream_wire, ^socket, wire} -> finish_stream(socket, wires ++ [wire])
      {:stream_result, ^socket, result} -> {wires, result}
    after
      2_000 -> flunk("timed out waiting for the request to return: #{inspect(wires)}")
    end
  end

  defp wire_shape(wires), do: Enum.map_join(wires, &wire_kind/1)

  defp wire_kind(":\r\n\r\n"), do: "K"

  defp wire_kind("data: " <> frame) do
    case Jason.decode!(frame) do
      %{"method" => "notifications/progress", "params" => %{"progress" => progress}} ->
        Integer.to_string(progress)

      %{"result" => _result} ->
        "R"
    end
  end

  defp legacy_session(runtime) do
    opts = Arbor.MCP.HttpPlug.init(runtime: runtime, protocol_mode: :prefer_modern)

    initialize =
      %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-11-25",
          capabilities: %{},
          clientInfo: %{name: "close-test", version: "1"}
        }
      }
      |> legacy_post([])
      |> Arbor.MCP.HttpPlug.call(opts)

    assert initialize.status == 200
    [session] = Plug.Conn.get_resp_header(initialize, "mcp-session-id")

    initialized =
      %{jsonrpc: "2.0", method: "notifications/initialized"}
      |> legacy_post([{"mcp-session-id", session}])
      |> Arbor.MCP.HttpPlug.call(opts)

    assert initialized.status == 202
    session
  end

  defp legacy_post(message, headers) do
    Enum.reduce(
      [
        {"content-type", "application/json"},
        {"accept", "application/json"},
        {"mcp-protocol-version", "2025-11-25"} | headers
      ],
      Plug.Test.conn(:post, "/mcp", Jason.encode!(message)),
      fn {name, value}, conn -> Plug.Conn.put_req_header(conn, name, value) end
    )
  end

  defp writer_domain(runtime) do
    {:ok, runtime_ref} = Runtime.ref(runtime)
    {:ok, domain} = HTTPWriterProxy.domain(runtime_ref)
    domain
  end

  defp assert_released(runtime) do
    domain = writer_domain(runtime)

    Arbor.MCP.TestHelpers.wait_until(fn ->
      Runtime.stats!(runtime).reserved == 0 and
        match?(%{frames: 0, bytes: 0}, HTTPWriterRegistry.stats(domain))
    end)
  end

  defp owned_port(root) do
    case Transport.http_listener(root) do
      {:ok, %{adapter: :bandit, listener: listener}} ->
        {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
        port

      {:ok, %{adapter: :cowboy, ranch_ref: ref}} ->
        :ranch.get_port(ref)
    end
  end

  defp start_server(adapter, plug_opts \\ []) do
    runtime =
      start_supervised!(
        {Runtime,
         handler: Handler,
         handler_args: [test_pid: self()],
         transport: :mounted_http,
         protocol_mode: :modern_only}
      )

    opts =
      Keyword.merge(
        [
          runtime: runtime,
          path: "/mcp",
          protocol_mode: :modern_only,
          request_keepalive_interval_ms: 40
        ],
        plug_opts
      )

    port = free_port()

    case adapter do
      :cowboy ->
        ref = {:request_stream_close, make_ref()}
        {:ok, _listener} = Plug.Cowboy.http(Arbor.MCP.HttpPlug, opts, port: port, ref: ref)
        on_exit(fn -> Plug.Cowboy.shutdown(ref) end)

      :bandit ->
        {:ok, listener} =
          Bandit.start_link(
            plug: {Arbor.MCP.HttpPlug, opts},
            port: port,
            ip: {127, 0, 0, 1},
            startup_log: false
          )

        on_exit(fn ->
          try do
            if Process.alive?(listener), do: Supervisor.stop(listener)
          catch
            :exit, _reason -> :ok
          end
        end)
    end

    {runtime, port}
  end

  defp connect(port) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    conn
  end

  defp request(conn, name, stream? \\ true, id \\ nil) do
    Mint.HTTP.request(
      conn,
      "POST",
      "/mcp",
      [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"},
        {"mcp-protocol-version", "2026-07-28"},
        {"mcp-method", "tools/call"},
        {"mcp-name", name}
      ],
      tool_body(name, stream?, id)
    )
  end

  # A progress token makes the request own an SSE response stream.
  defp tool_body(name, stream?, id) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    meta = if stream?, do: Map.put(meta, "progressToken", "heartbeat"), else: meta

    Jason.encode!(%{
      jsonrpc: "2.0",
      id: id || System.unique_integer([:positive]),
      method: "tools/call",
      params: %{name: name, arguments: %{}, _meta: meta}
    })
  end

  defp receive_until(conn, ref, predicate, events \\ []) do
    if predicate.(events) do
      {conn, events}
    else
      receive do
        message ->
          case Mint.HTTP.stream(conn, message) do
            {:ok, conn, next} ->
              receive_until(conn, ref, predicate, events ++ next)

            :unknown ->
              receive_until(conn, ref, predicate, events)
          end
      after
        2_000 -> flunk("timed out waiting for request stream #{inspect(ref)}: #{inspect(events)}")
      end
    end
  end

  defp heartbeat?(events),
    do:
      Enum.any?(events, fn
        {:data, _ref, data} -> String.contains?(data, ":\r\n\r\n")
        _ -> false
      end)

  defp progress?(events),
    do:
      Enum.any?(events, fn
        {:data, _ref, data} -> String.contains?(data, "notifications/progress")
        _ -> false
      end)

  defp response_body(events, ref) do
    for {:data, ^ref, data} <- events, into: "", do: data
  end

  defp content_type(events, ref) do
    values =
      for {:headers, ^ref, headers} <- events,
          {name, value} <- headers,
          name == "content-type",
          do: value

    List.first(values)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
