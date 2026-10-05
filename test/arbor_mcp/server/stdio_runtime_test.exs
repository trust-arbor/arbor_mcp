defmodule Arbor.MCP.Server.StdioRuntimeTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.{HandlerServer, Runtime, StdioServer}
  alias Arbor.MCP.Server.Runtime.{Admission, OutputController, OutputTicket, Ref, ShutdownGuard}

  alias Arbor.MCP.Test.StdioRuntimeFixture.{Device, Handler}

  defp pair(opts \\ []) do
    input = start_supervised!({Device, [owner: self()]}, id: make_ref())

    output =
      start_supervised!({Device, [owner: self(), hold: Keyword.get(opts, :hold, false)]},
        id: make_ref()
      )

    {:ok, root} =
      StdioServer.start_link(
        Keyword.merge(
          [
            module: Handler,
            handler_args: [test_pid: self()],
            stdio_input: input,
            stdio_output: output,
            stdio_startup_delay: 0,
            request_timeout_ms: 2_000,
            output_timeout_ms: 1_000,
            stdio_eof_timeout_ms: 3_000,
            shutdown_timeout_ms: 100
          ],
          Keyword.delete(opts, :hold)
        )
      )

    Process.unlink(root)
    on_exit(fn -> if Process.alive?(root), do: Runtime.stop(root) end)
    {:ok, runtime} = Runtime.ref(root)
    {root, runtime, input, output}
  end

  defp request(id, name),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => %{}}
    }

  defp line(request), do: Jason.encode!(request) <> "\n"
  defp input(device, bytes, eof \\ false), do: GenServer.call(device, {:input, bytes, eof})
  defp eventually(fun, n \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, n) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(fun, n - 1)
        )
  end

  test "EOF fences future input and drains a previously admitted callback and final frame" do
    {root, runtime, input_device, _output} = pair()
    monitor = Process.monitor(root)
    input(input_device, line(request(1, "hold")), true)
    assert_receive {:holding, worker}
    eventually(fn -> :ets.member(Ref.table(runtime), :input_sealed) end)

    assert {:error, :runtime_input_sealed} =
             Runtime.submit(runtime, %{"payload" => :new}, kind: :call)

    send(worker, :release)
    assert_receive {:written, bytes}

    assert %{"id" => 1, "result" => %{"structuredContent" => %{"count" => 1}}} =
             Jason.decode!(String.trim(bytes))

    assert_receive {:DOWN, ^monitor, :process, ^root, :normal}, 2_000
  end

  test "one actual IO completion ACK holds stateful output and input credit" do
    {_root, runtime, input_device, output} = pair(hold: true)
    input(input_device, line(request(1, "inc")) <> line(request(2, "inc")))
    assert_receive {:invoked, 1}
    assert_receive {:write_attempt, writer, first}
    refute_receive {:invoked, 2}, 50
    assert %{writing: true, frames: 1} = OutputController.stats(Ref.table(runtime))
    assert %{reserved: 2} = Admission.stats(Ref.table(runtime))
    assert {:message_queue_len, 0} = Process.info(writer, :message_queue_len)
    :ok = GenServer.call(output, :release_write)
    assert_receive {:written, ^first}
    assert_receive {:invoked, 2}
    assert_receive {:write_attempt, second_sender, second}
    refute second_sender == writer
    refute Process.alive?(writer)
    :ok = GenServer.call(output, :release_write)
    assert_receive {:written, ^second}
    eventually(fn -> Admission.stats(Ref.table(runtime)).reserved == 0 end)
  end

  test "a timed-out write is terminal uncertain and never retries a committed callback" do
    {root, runtime, input_device, output} = pair(hold: true, output_timeout_ms: 80)
    monitor = Process.monitor(root)
    input(input_device, line(request(1, "inc")) <> line(request(2, "inc")))
    assert_receive {:invoked, 1}
    assert_receive {:write_attempt, writer, bytes}
    [{:stdio_writer, proxy}] = :ets.lookup(Ref.table(runtime), :stdio_writer)
    writer_monitor = Process.monitor(proxy)
    assert_receive {:DOWN, ^writer_monitor, :process, ^proxy, :killed}, 1_000
    assert Process.alive?(writer)
    assert_receive {:DOWN, ^monitor, :process, ^root, _reason}, 1_000
    refute_receive {:invoked, 2}, 30
    assert Process.alive?(output)
    # The borrowed device can complete an irreversible old request later. That
    # uncertainty is reported honestly; the endpoint sender retains its credit
    # through Runtime loss and cannot start another physical write.
    :ok = GenServer.call(output, :release_write)
    assert_receive {:written, ^bytes}
    eventually(fn -> not Process.alive?(writer) end)
    refute_receive {:write_attempt, _, _}, 30
  end

  test "the EOF cutoff survives an unresponsive edge and does not reset per poll" do
    {root, runtime, input_device, _output} = pair(stdio_eof_timeout_ms: 80)
    {:ok, edge} = Runtime.edge(runtime)
    :ok = :sys.suspend(edge)
    monitor = Process.monitor(root)
    started = System.monotonic_time(:millisecond)
    input(input_device, "", true)
    assert_receive {:DOWN, ^monitor, :process, ^root, _}, 800
    assert System.monotonic_time(:millisecond) - started < 600
  end

  test "raw framing rejects an overlong newline-free input without executing it" do
    {root, _runtime, input_device, _output} = pair(max_request_bytes: 512)
    monitor = Process.monitor(root)
    input(input_device, String.duplicate("x", 10_000))
    assert_receive {:DOWN, ^monitor, :process, ^root, _}, 1_000
    assert byte_size(GenServer.call(input_device, :state).input) > 9_000
    refute_receive {:invoked, _}
  end

  test "BOM, ignored banners, CRLF and final unterminated JSON preserve byte framing" do
    {root, _runtime, input_device, _output} = pair()
    monitor = Process.monitor(root)

    request = %{
      "jsonrpc" => "2.0",
      "id" => "unicode",
      "method" => "extension/echo",
      "params" => %{"text" => "héλ🙂"}
    }

    input(input_device, "\uFEFFstartup banner\r\n\r\n" <> Jason.encode!(request), true)
    assert_receive {:written, bytes}, 1_000

    assert %{"id" => "unicode", "result" => %{"text" => "héλ🙂"}} =
             Jason.decode!(String.trim(bytes))

    assert String.ends_with?(bytes, "\n")
    assert_receive {:DOWN, ^monitor, :process, ^root, :normal}, 2_000
  end

  test "startup leaves all Logger and application configuration unchanged" do
    level = Logger.level()
    otp = :logger.get_primary_config()
    app = Application.get_env(:arbor_mcp, :stdio_mode)
    {_root, _runtime, _input, _output} = pair()
    assert Logger.level() == level
    assert :logger.get_primary_config() == otp
    assert Application.get_env(:arbor_mcp, :stdio_mode) == app
  end

  test "notification-only batch releases its envelope barrier without producing output" do
    request_budget = 2_000
    {root, _runtime, input_device, _output} = pair(request_timeout_ms: request_budget)
    monitor = Process.monitor(root)
    notification = %{"jsonrpc" => "2.0", "method" => "notifications/silent", "params" => %{}}
    deadline = System.monotonic_time(:millisecond) + request_budget
    input(input_device, line([notification, notification]) <> line(request(3, "inc")), true)
    # Both observations share the original request budget; neither renews it.
    assert_receive {:invoked, 3}, max(0, deadline - System.monotonic_time(:millisecond))
    assert_receive {:written, bytes}, max(0, deadline - System.monotonic_time(:millisecond))

    assert %{"id" => 3, "result" => %{"structuredContent" => %{"count" => 3}}} =
             Jason.decode!(String.trim(bytes))

    assert_receive {:DOWN, ^monitor, :process, ^root, :normal}, 2_000
    refute_receive {:written, _}
  end

  test "duplicate-ID validation output waits behind the earlier callback response" do
    {_root, _runtime, input_device, _output} = pair()
    input(input_device, line(request("same", "hold")) <> line(request("same", "inc")))
    assert_receive {:holding, worker}
    refute_receive {:write_attempt, _, _}, 40
    send(worker, :release)
    assert_receive {:written, first}
    assert %{"id" => "same", "result" => _} = Jason.decode!(String.trim(first))
    assert_receive {:written, duplicate}

    assert %{"id" => "same", "error" => %{"data" => %{"type" => "duplicate_request_id"}}} =
             Jason.decode!(String.trim(duplicate))

    refute_receive {:invoked, _}
  end

  test "reverse response bypasses the stdio envelope barrier and the stateful slot" do
    {_root, _runtime, input_device, _output} = pair()
    input(input_device, line(request(1, "reverse")))
    assert_receive {:written, reverse}
    assert %{"id" => id, "method" => "ping"} = Jason.decode!(String.trim(reverse))
    input(input_device, line(%{"jsonrpc" => "2.0", "id" => id, "result" => %{}}))
    assert_receive {:written, response}
    assert %{"id" => 1, "result" => _} = Jason.decode!(String.trim(response))
  end

  test "a stale EOF observer cannot stop a replacement peer or another runtime" do
    {:ok, root} =
      HandlerServer.start_link(
        handler: Handler,
        handler_args: [test_pid: self()],
        transport: :test
      )

    Process.unlink(root)
    on_exit(fn -> if Process.alive?(root), do: Runtime.stop(root) end)
    {:ok, edge, runtime, old_connection} = HandlerServer.connect(root, self())

    ShutdownGuard.begin_drain(
      Ref.table(runtime),
      edge,
      old_connection,
      System.monotonic_time(:millisecond) + 40
    )

    {:ok, ^edge, ^runtime, new_connection} = HandlerServer.connect(root, self())
    refute new_connection == old_connection
    Process.sleep(70)
    assert Process.alive?(root)

    assert {:error, :connection_closed} =
             Admission.seal_input(Ref.table(runtime), edge, old_connection)

    refute :ets.member(Ref.table(runtime), :input_sealed)
  end

  defp scheduler_state(runtime) do
    {:ok, %{scheduler: scheduler}} = Admission.route(Ref.table(runtime))
    :sys.get_state(scheduler).handler_state
  end

  defp block_output(root, output) do
    :ok = Arbor.MCP.Server.notify_progress(root, "outside", 0)
    assert_receive {:write_attempt, _writer, first}
    assert %{"params" => %{"progressToken" => "outside"}} = Jason.decode!(String.trim(first))
    assert GenServer.call(output, :state).write != nil
    first
  end

  test "active-source cancellation suppresses queued control output before writer claim" do
    {root, runtime, input_device, output} = pair(hold: true)
    first = block_output(root, output)
    input(input_device, line(request(1, "progress_hold")))
    assert_receive {:progress_source, _worker}
    eventually(fn -> OutputController.stats(Ref.table(runtime)).frames == 2 end)

    input(
      input_device,
      line(%{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => 1}
      })
    )

    # Stdin enqueue alone does not fence the Reader/Scheduler. Wait for the
    # callback to observe accepted cancellation before releasing write credit.
    assert_receive {:source_cancelled, _worker}
    :ok = GenServer.call(output, :release_write)
    assert_receive {:written, ^first}
    assert_receive {:write_attempt, _writer, failure}
    assert %{"id" => 1, "error" => _} = Jason.decode!(String.trim(failure))
    :ok = GenServer.call(output, :release_write)
    assert_receive {:written, ^failure}
    refute_receive {:write_attempt, _, _}, 40
    assert scheduler_state(runtime).count == 0
    eventually(fn -> OutputController.stats(Ref.table(runtime)).frames == 0 end)
  end

  test "successful source completion keeps admitted controls and late cancel cannot undo commit" do
    {root, runtime, input_device, output} = pair(hold: true)
    first = block_output(root, output)
    input(input_device, line(request(1, "progress_finish")))

    eventually(fn ->
      scheduler_state(runtime).count == 1 and
        OutputController.stats(Ref.table(runtime)).frames == 3
    end)

    input(
      input_device,
      line(%{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => 1}
      })
    )

    :ok = GenServer.call(output, :release_write)
    assert_receive {:written, ^first}
    assert_receive {:write_attempt, _writer, progress}

    assert %{"method" => "notifications/progress", "params" => %{"progressToken" => "source"}} =
             Jason.decode!(String.trim(progress))

    :ok = GenServer.call(output, :release_write)
    assert_receive {:written, ^progress}
    assert_receive {:write_attempt, _writer, response}
    assert %{"id" => 1, "result" => _} = Jason.decode!(String.trim(response))
    :ok = GenServer.call(output, :release_write)
    assert_receive {:written, ^response}
    assert scheduler_state(runtime).count == 1
    refute_receive {:write_attempt, _, _}, 30
  end

  test "the source cutoff suppresses queued controls even with a longer output lease" do
    {root, runtime, input_device, output} =
      pair(hold: true, request_timeout_ms: 100, output_timeout_ms: 1_000)

    first = block_output(root, output)
    input(input_device, line(request(1, "progress_hold")))
    assert_receive {:progress_source, _worker}
    eventually(fn -> OutputController.stats(Ref.table(runtime)).frames == 2 end)
    Process.sleep(140)
    :ok = GenServer.call(output, :release_write)
    assert_receive {:written, ^first}
    assert_receive {:write_attempt, _, failure}
    assert %{"id" => 1, "error" => _} = Jason.decode!(String.trim(failure))
    :ok = GenServer.call(output, :release_write)
    assert_receive {:written, ^failure}
    refute_receive {:write_attempt, _, _}, 30
    assert scheduler_state(runtime).count == 0
  end

  test "peer retirement discards queued successful controls without affecting committed state" do
    {root, runtime, input_device, _output} = pair()
    [{:stdio_writer, writer}] = :ets.lookup(Ref.table(runtime), :stdio_writer)
    :ok = :sys.suspend(writer)
    :ok = Arbor.MCP.Server.notify_progress(root, "outside", 0)
    eventually(fn -> OutputController.stats(Ref.table(runtime)).writing end)
    input(input_device, line(request(1, "progress_finish")))

    eventually(fn ->
      scheduler_state(runtime).count == 1 and
        OutputController.stats(Ref.table(runtime)).frames == 3
    end)

    old = :ets.lookup(Ref.table(runtime), :edge_connection)

    assert {:ok, _edge, ^runtime, _new_connection} =
             HandlerServer.connect(root, writer)

    refute :ets.lookup(Ref.table(runtime), :edge_connection) == old
    :ok = :sys.resume(writer)
    refute_receive {:write_attempt, _, _}, 40
    assert scheduler_state(runtime).count == 1
    eventually(fn -> OutputController.stats(Ref.table(runtime)).frames == 0 end)
    assert Process.alive?(writer)
  end

  test "stdio cannot adopt a borrowed process as its owned writer" do
    {root, runtime, _input, output} = pair()
    assert {:error, :invalid_stdio_peer} = HandlerServer.connect(root, output)
    {:ok, edge} = Runtime.edge(runtime)
    send(edge, {:test_transport_connect, output})
    :sys.get_state(edge)
    assert Process.alive?(output)
    assert {:stdio_writer, writer} = hd(:ets.lookup(Ref.table(runtime), :stdio_writer))
    assert :sys.get_state(edge).transport_state.writer == writer
  end

  test "modern discovery releases its output barrier before the next request" do
    {_root, runtime, input_device, _output} = pair(protocol_mode: :modern_only)

    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientInfo" => %{"name" => "modern", "version" => "2.0.0"},
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    input(
      input_device,
      line(%{
        "jsonrpc" => "2.0",
        "id" => "probe",
        "method" => "server/discover",
        "params" => %{"_meta" => meta}
      })
    )

    assert_receive {:written, discovery}, 1_000
    assert %{"id" => "probe", "result" => _} = Jason.decode!(String.trim(discovery))

    input(
      input_device,
      line(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{"_meta" => meta}
      })
    )

    assert_receive {:written, tools}, 500
    assert %{"id" => 1, "result" => %{"tools" => _}} = Jason.decode!(String.trim(tools))
    eventually(fn -> Admission.stats(Ref.table(runtime)).reserved == 0 end)
  end

  test "a later batch member cancellation cannot invalidate an earlier successful source" do
    {root, runtime, input_device, output} = pair(hold: true)
    first = block_output(root, output)
    input(input_device, line([request(1, "progress_finish"), request(2, "hold")]))
    assert_receive {:holding, _worker}
    eventually(fn -> OutputController.stats(Ref.table(runtime)).frames >= 3 end)

    input(
      input_device,
      line(%{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => 2}
      })
    )

    eventually(fn -> OutputController.stats(Ref.table(runtime)).writes == 2 end)
    :ok = GenServer.call(output, :release_write)
    assert_receive {:written, ^first}
    assert_receive {:write_attempt, _, progress}
    assert %{"method" => "notifications/progress"} = Jason.decode!(String.trim(progress))
    :ok = GenServer.call(output, :release_write)
    assert_receive {:written, ^progress}
    assert_receive {:write_attempt, _, batch}

    assert [%{"id" => 1, "result" => _}, %{"id" => 2, "error" => _}] =
             Jason.decode!(String.trim(batch))

    :ok = GenServer.call(output, :release_write)
    assert_receive {:written, ^batch}
    assert scheduler_state(runtime).count == 1
    eventually(fn -> OutputController.stats(Ref.table(runtime)).frames == 0 end)
  end

  test "a known ledger ACK failure cannot release the next callback or claim delivery success" do
    {root, runtime, input_device, output} = pair(hold: true, output_timeout_ms: 200)
    monitor = Process.monitor(root)
    input(input_device, line(request(1, "inc")) <> line(request(2, "inc")))
    assert_receive {:invoked, 1}
    assert_receive {:write_attempt, writer, bytes}
    [{:output_controller, controller}] = :ets.lookup(Ref.table(runtime), :output_controller)
    ticket = :sys.get_state(controller).writing.ticket
    {:ok, {ledger, _token}} = OutputTicket.address(ticket)
    :ok = :sys.suspend(ledger)
    assert scheduler_state(runtime).count == 1
    :ok = GenServer.call(output, :release_write)
    assert_receive {:written, ^bytes}
    assert_receive {:DOWN, ^monitor, :process, ^root, _}, 1_000
    refute Process.alive?(writer)
    refute_receive {:invoked, 2}, 30
    refute_receive {:write_attempt, _, _}, 30
    assert Process.alive?(output)
  end
end
