defmodule ExMCP.ACP.ClientAsyncHandlerTest do
  use ExUnit.Case, async: true
  alias ExMCP.ACP.Agent.Transport.Memory
  alias ExMCP.ACP.Client
  alias ExMCP.ACP.Client.HandlerRunner

  defmodule Handler do
    @behaviour ExMCP.ACP.Client.Handler
    def init(opts), do: {:ok, %{parent: Keyword.fetch!(opts, :parent), count: 0}}
    def handle_session_update(_, _, state), do: {:ok, state}
    def handle_permission_request(_, _, _, state), do: work(:permission, state)
    def handle_file_read(_, _, _, state), do: work(:file_read, state)
    def handle_file_write(_, _, _, state), do: work(:file_write, state)
    def handle_form_elicitation(_, state), do: work(:elicitation, state)

    def handle_terminal_request("terminal/kill", _, _, state) do
      send(state.parent, {:kill_handled, state.count})
      {:ok, %{}, state}
    end

    def handle_terminal_request(_, _, _, state), do: work(:terminal, state)

    defp work(kind, state) do
      send(state.parent, {:callback, kind, state.count})
      parent = state.parent

      {:async,
       fn ->
         send(parent, {:work, kind, self()})

         receive do
           {:finish, result} -> result
         end
       end, %{state | count: state.count + 1}}
    end
  end

  test "all supported request callbacks commit state before worker completion" do
    {:ok, runner} = HandlerRunner.start_link(Handler, [parent: self()], self())

    requests = [
      {:permission,
       fn ref -> HandlerRunner.permission_request(runner, ref, "s", %{}, [], nil) end,
       {:ok, %{"outcome" => "cancelled"}}},
      {:file_read, fn ref -> HandlerRunner.file_read(runner, ref, "s", "/tmp/file", %{}) end,
       {:ok, "contents"}},
      {:file_write,
       fn ref -> HandlerRunner.file_write(runner, ref, "s", "/tmp/file", "contents") end, :ok},
      {:terminal,
       fn ref ->
         HandlerRunner.terminal_request(runner, ref, "terminal/wait_for_exit", %{}, "id")
       end, {:ok, %{"exitCode" => 0}}},
      {:elicitation, fn ref -> HandlerRunner.elicitation_request(runner, ref, "form", %{}) end,
       {:ok, %{"action" => "cancel"}}}
    ]

    workers =
      for {{kind, dispatch, result}, count} <- Enum.with_index(requests) do
        ref = make_ref()
        dispatch.(ref)
        assert_receive {:callback, ^kind, ^count}
        assert_receive {:work, ^kind, pid}
        {ref, kind, pid, result}
      end

    assert :sys.get_state(runner).handler_state.count == 5

    for {ref, kind, pid, result} <- Enum.reverse(workers) do
      send(pid, {:finish, result})
      assert_receive {:acp_handler_result, ^ref, {^kind, ^result}}
    end

    assert :sys.get_state(runner).handler_state.count == 5
  end

  test "a pending async terminal wait does not block terminal kill" do
    {_client, transport} = start_client()
    send_raw(transport, request("wait", "terminal/wait_for_exit", %{"terminalId" => "t"}))
    assert_receive {:work, :terminal, worker}
    send_raw(transport, request("kill", "terminal/kill", %{"terminalId" => "t"}))
    assert_receive {:kill_handled, 1}
    assert %{"id" => "kill", "result" => %{}} = receive_raw(transport)
    send(worker, {:finish, {:ok, %{"exitCode" => 0}}})
    assert %{"id" => "wait", "result" => %{"exitCode" => 0}} = receive_raw(transport)
  end

  for cause <- [:timeout, :cancel, :disconnect, :runner_stop] do
    @cause cause
    test "#{cause} stops async work and settles the request once" do
      {client, transport} = start_client()
      send_raw(transport, request("read", "fs/read_text_file", %{"path" => "/tmp/file"}))
      assert_receive {:work, :file_read, worker}
      monitor = Process.monitor(worker)
      state = :sys.get_state(client)
      [{ref, _request}] = Map.to_list(state.pending_agent_requests)

      case @cause do
        :timeout ->
          send(client, {:agent_handler_timeout, ref})

        :cancel ->
          send_raw(transport, %{
            "jsonrpc" => "2.0",
            "method" => "$/cancel_request",
            "params" => %{"requestId" => "read"}
          })

        :disconnect ->
          Client.disconnect(client)

        :runner_stop ->
          Process.exit(state.handler_pid, :kill)
      end

      assert_receive {:DOWN, ^monitor, :process, ^worker, _}

      if @cause != :disconnect do
        assert %{"id" => "read", "error" => %{}} = receive_raw(transport)
        send(client, {:acp_handler_result, ref, {:file_read, {:ok, "late"}}})
        assert :sys.get_state(client).pending_agent_requests == %{}
        assert :queue.is_empty(:sys.get_state(transport.peer).queues.agent)
      else
        assert :sys.get_state(client).pending_agent_requests == %{}
      end
    end
  end

  test "a cancelled queued callback never enters" do
    {client, transport} = start_client()
    runner = :sys.get_state(client).handler_pid
    :sys.suspend(runner)
    send_raw(transport, request("read", "fs/read_text_file", %{"path" => "/tmp/file"}))

    send_raw(transport, %{
      "jsonrpc" => "2.0",
      "method" => "$/cancel_request",
      "params" => %{"requestId" => "read"}
    })

    assert %{"id" => "read", "error" => %{}} = receive_raw(transport)
    :sys.resume(runner)
    assert :sys.get_state(runner).handler_state.count == 0
    refute_receive {:callback, _, _}
  end

  test "worker exceptions answer with an error and leave the runner usable" do
    {:ok, runner} = HandlerRunner.start_link(Handler, [parent: self()], self())
    ref = make_ref()
    HandlerRunner.file_read(runner, ref, "s", "/tmp/file", %{})
    assert_receive {:work, :file_read, worker}
    Process.exit(worker, :kill)
    assert_receive {:acp_handler_result, ^ref, {:file_read, {:error, {:exit, :killed}}}}
    assert :sys.get_state(runner).handler_state.count == 1
    HandlerRunner.terminal_request(runner, make_ref(), "terminal/kill", %{}, "kill")
    assert_receive {:kill_handled, 1}
  end

  test "cancelling the prompt preserves a queued terminal kill" do
    {client, transport} = start_client()
    runner = :sys.get_state(client).handler_pid
    :sys.suspend(runner)
    send_raw(transport, request("kill", "terminal/kill", %{"terminalId" => "t"}))
    # Use the same sender so the frame is admitted before the cancel cast.
    send(
      client,
      {:transport_message, request("kill-ordered", "terminal/kill", %{"terminalId" => "t"})}
    )

    Client.cancel(client, "s")
    :sys.get_state(client)
    :sys.resume(runner)
    assert_receive {:kill_handled, 0}
    assert_receive {:kill_handled, 0}
  end

  test "expired queued async work cannot enter before timeout delivery" do
    {client, transport} = start_client()
    runner = :sys.get_state(client).handler_pid
    :sys.suspend(runner)

    send(
      client,
      {:transport_message, request("read", "fs/read_text_file", %{"path" => "/tmp/file"})}
    )

    assert map_size(:sys.get_state(client).pending_agent_requests) == 1

    :sys.replace_state(client, fn state ->
      pending =
        Map.new(state.pending_agent_requests, fn {ref, request} ->
          {ref, Map.put(request, :deadline, System.monotonic_time(:millisecond) - 1)}
        end)

      %{state | pending_agent_requests: pending}
    end)

    :sys.resume(runner)

    assert %{"id" => "read", "error" => %{"message" => "Client handler timed out"}} =
             receive_raw(transport)

    assert :sys.get_state(client).pending_agent_requests == %{}
    refute_receive {:work, :file_read, _}
  end

  test "worker rechecks an admission deadline after the reply is delayed" do
    {:ok, runner} = HandlerRunner.start_link(Handler, [parent: self()], self())
    ref = HandlerRunner.new_request_ref()
    HandlerRunner.file_read(runner, ref, "s", "/tmp/file", %{})
    assert_receive {:callback, :file_read, 0}
    assert_receive {:"$gen_call", {worker, _} = from, {:handler_worker_admit, ^ref, worker}}
    monitor = Process.monitor(worker)
    # The owner admitted the worker, but its reply became stale before use.
    GenServer.reply(from, {:ok, System.monotonic_time(:millisecond) - 1})
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    refute_receive {:work, :file_read, _}
    assert :sys.get_state(runner).handler_state.count == 1
    refute_receive {:acp_handler_result, ^ref, _}
  end

  defp start_client do
    {:ok, peer} = Memory.new_pair()
    {:ok, transport} = Memory.connect(peer: peer, role: :agent)

    handshake =
      Task.async(fn ->
        %{"id" => id} = receive_raw(transport)

        send_raw(transport, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{}, "authMethods" => []}
        })

        %{"id" => id} = receive_raw(transport)
        send_raw(transport, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"sessionId" => "s"}})
      end)

    {:ok, client} =
      Client.start_link(
        transport_mod: Memory,
        peer: peer,
        role: :client,
        handler: Handler,
        handler_opts: [parent: self()]
      )

    assert {:ok, %{"sessionId" => "s"}} = Client.new_session(client, "/tmp")
    Task.await(handshake)
    {client, transport}
  end

  defp request(id, method, params),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => Map.put(params, "sessionId", "s")
    }

  defp send_raw(transport, message),
    do: assert({:ok, _} = Memory.send_message(Jason.encode!(message), transport))

  defp receive_raw(transport) do
    assert {:ok, message, _} = Memory.receive_message(transport)
    Jason.decode!(message)
  end
end
