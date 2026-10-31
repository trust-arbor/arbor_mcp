defmodule ExMCP.ACP.ClientUpdateDropsTest do
  use ExUnit.Case, async: true
  alias ExMCP.ACP.Agent.Transport.Memory
  alias ExMCP.ACP.Client

  defmodule Handler do
    @behaviour ExMCP.ACP.Client.Handler
    def init(opts), do: {:ok, Keyword.fetch!(opts, :parent)}
    def handle_session_update(_sid, _update, state), do: {:ok, state}
    def handle_permission_request(_, _, _, state), do: {:ok, %{"outcome" => "cancelled"}, state}
  end

  defmodule NoticeHandler do
    @behaviour ExMCP.ACP.Client.Handler
    defdelegate init(opts), to: Handler
    defdelegate handle_session_update(sid, update, state), to: Handler
    defdelegate handle_permission_request(sid, tool, options, state), to: Handler

    def handle_session_updates_dropped(sid, count, state) do
      send(state, {:handler_notice, sid, count})
      {:ok, state}
    end
  end

  test "listeners remain opted out while each drop emits telemetry" do
    listener = held_listener()
    {client, _} = start_client(event_listener: listener, max_update_queue: 1)
    attach(client)
    for _ <- 1..3, do: send(client, {:transport_message, update()})
    state = :sys.get_state(client)
    assert_drop(:event_listener, :count)
    assert_drop(:event_listener, :count)
    assert state.update_drops == %{}
    assert state.update_drop_timer == nil
    send(listener, :drain)
    assert_receive {:delivered, {:acp_session_update, "drop-session", _}}
    refute_receive {:delivered, {:acp_session_updates_dropped, _, _}}
  end

  test "listener notices coalesce and arrive after recovery without another update" do
    listener = held_listener()

    {client, _} =
      start_client(event_listener: listener, notify_update_drops: true, max_update_queue: 2)

    attach(client)
    for _ <- 1..5, do: send(client, {:transport_message, update()})
    state = :sys.get_state(client)
    assert state.update_drops[{:event_listener, "drop-session"}] == 3
    assert {:message_queue_len, 2} = Process.info(listener, :message_queue_len)
    for _ <- 1..3, do: assert_drop(:event_listener, :count)
    send(listener, :drain)
    assert_receive {:delivered, {:acp_session_update, "drop-session", _}}
    assert_receive {:delivered, {:acp_session_update, "drop-session", _}}
    assert_receive {:delivered, {:acp_session_updates_dropped, "drop-session", 3}}, 1_000
    assert :sys.get_state(client).update_drops == %{}
    refute_receive {:delivered, {:acp_session_updates_dropped, _, _}}
  end

  test "handler notices obey queue bounds and recover when its mailbox drains" do
    {client, _} = start_client(handler: NoticeHandler, max_update_queue: 1)
    attach(client)
    runner = :sys.get_state(client).handler_pid
    :sys.suspend(runner)
    for _ <- 1..4, do: send(client, {:transport_message, update()})
    state = :sys.get_state(client)
    assert state.update_drops[{:handler, "drop-session"}] == 3
    for _ <- 1..3, do: assert_drop(:handler, :count)
    assert {:message_queue_len, 1} = Process.info(runner, :message_queue_len)
    :sys.resume(runner)
    assert_receive {:handler_notice, "drop-session", 3}, 1_000
    assert :sys.get_state(client).update_drops == %{}
  end

  test "byte overflow telemetry identifies size and the bound for each destination" do
    listener = held_listener()
    {client, _} = start_client(event_listener: listener, max_update_queue_bytes: 128)
    attach(client)
    message = update(String.duplicate("x", 300))
    send(client, {:transport_message, message})
    :sys.get_state(client)
    bytes = :erlang.external_size(message["params"]["update"])

    assert_receive {:drop, %{count: 1, bytes: ^bytes},
                    %{target: :event_listener, limit: :bytes, max_bytes: 128}}

    assert_receive {:drop, %{count: 1, bytes: ^bytes},
                    %{target: :handler, limit: :bytes, max_bytes: 128}}

    assert {:message_queue_len, 0} = Process.info(listener, :message_queue_len)
  end

  test "notices too large for the byte budget stay telemetry-only" do
    listener = held_listener()

    {client, _} =
      start_client(
        event_listener: listener,
        notify_update_drops: true,
        handler: NoticeHandler,
        max_update_queue_bytes: 1
      )

    attach(client)
    send(client, {:transport_message, update()})
    state = :sys.get_state(client)
    assert_drop(:event_listener, :bytes)
    assert_drop(:handler, :bytes)
    assert state.update_drops == %{}
    assert state.update_drop_timer == nil
    assert {:message_queue_len, 0} = Process.info(listener, :message_queue_len)
  end

  test "dead destinations report unavailable without retaining a retry" do
    listener = spawn(fn -> :ok end)
    monitor = Process.monitor(listener)
    assert_receive {:DOWN, ^monitor, :process, ^listener, _}
    {client, _} = start_client(event_listener: listener, notify_update_drops: true)
    attach(client)
    send(client, {:transport_message, update()})
    state = :sys.get_state(client)
    assert_drop(:event_listener, :unavailable)
    assert state.update_drops == %{}
    assert state.update_drop_timer == nil
  end

  test "disconnect retires pending counters and their timer" do
    listener = held_listener()

    {client, _} =
      start_client(event_listener: listener, notify_update_drops: true, max_update_queue: 1)

    for _ <- 1..3, do: send(client, {:transport_message, update()})
    state = :sys.get_state(client)
    assert state.update_drop_timer != nil
    assert state.update_drops != %{}
    Client.disconnect(client)
    state = :sys.get_state(client)
    assert state.update_drops == %{}
    assert state.update_drop_timer == nil
  end

  for kind <- [:load, :resume] do
    @kind kind
    test "drop notices survive updates while #{@kind} is pending" do
      listener = held_listener()

      {client, transport} =
        start_client(event_listener: listener, notify_update_drops: true, max_update_queue: 1)

      operation =
        Task.async(fn ->
          case @kind do
            :load -> Client.load_session(client, "pending-session", "/tmp")
            :resume -> Client.resume_session(client, "pending-session", "/tmp")
          end
        end)

      request = receive_raw(transport)
      assert request["method"] in ["session/load", "session/resume"]
      message = put_in(update(), ["params", "sessionId"], "pending-session")
      for _ <- 1..3, do: send(client, {:transport_message, message})
      state = :sys.get_state(client)
      refute Map.has_key?(state.sessions, "pending-session")
      assert state.update_drops[{:event_listener, "pending-session"}] == 2
      send(listener, :drain)
      assert_receive {:delivered, {:acp_session_update, "pending-session", _}}
      assert_receive {:delivered, {:acp_session_updates_dropped, "pending-session", 2}}, 1_000
      send_raw(transport, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{}})
      assert {:ok, _} = Task.await(operation)
    end
  end

  for {kind, failure} <- [
        {:load, :error},
        {:resume, :error},
        {:load, :timeout},
        {:resume, :caller_exit}
      ] do
    @kind kind
    @failure failure
    test "#{kind} #{@failure} retires notices before a retry for the same id" do
      listener = held_listener()

      {client, transport} =
        start_client(event_listener: listener, notify_update_drops: true, max_update_queue: 1)

      open = fn ->
        case @kind do
          :load -> Client.load_session(client, "retry-session", "/tmp")
          :resume -> Client.resume_session(client, "retry-session", "/tmp")
        end
      end

      operation = Task.async(open)
      request = receive_raw(transport)
      message = put_in(update(), ["params", "sessionId"], "retry-session")
      for _ <- 1..3, do: send(client, {:transport_message, message})
      state = :sys.get_state(client)
      assert state.update_drops[{:event_listener, "retry-session"}] == 2
      {old_token, timer} = state.update_drop_timer
      Process.cancel_timer(timer)

      case @failure do
        :error ->
          send(
            client,
            {:transport_message,
             %{
               "jsonrpc" => "2.0",
               "id" => request["id"],
               "error" => %{"code" => -32603, "message" => "open failed"}
             }}
          )

          assert {:error, _} = Task.await(operation)

        :timeout ->
          send(client, {:pending_request_timeout, request["id"]})
          assert {:error, :request_timeout} = Task.await(operation)
          assert receive_raw(transport)["method"] == "$/cancel_request"

        :caller_exit ->
          Process.unlink(operation.pid)
          Process.exit(operation.pid, :kill)
          assert receive_raw(transport)["method"] == "$/cancel_request"
      end

      assert :sys.get_state(client).update_drops == %{}
      assert :sys.get_state(client).update_drop_timer == nil
      retry = Task.async(open)
      retried = receive_raw(transport)
      send(listener, :drain)
      assert_receive {:delivered, {:acp_session_update, "retry-session", _}}
      send(client, {:flush_update_drop_notices, old_token})

      send(
        client,
        {:transport_message, %{"jsonrpc" => "2.0", "id" => retried["id"], "result" => %{}}}
      )

      assert {:ok, _} = Task.await(retry)
      refute_receive {:delivered, {:acp_session_updates_dropped, "retry-session", _}}
    end
  end

  test "one failed open preserves notices while another open for the same id remains pending" do
    listener = held_listener()

    {client, transport} =
      start_client(event_listener: listener, notify_update_drops: true, max_update_queue: 1)

    first = Task.async(fn -> Client.load_session(client, "overlap", "/tmp") end)
    first_request = receive_raw(transport)
    second = Task.async(fn -> Client.resume_session(client, "overlap", "/tmp") end)
    second_request = receive_raw(transport)
    message = put_in(update(), ["params", "sessionId"], "overlap")
    for _ <- 1..3, do: send(client, {:transport_message, message})
    assert :sys.get_state(client).update_drops[{:event_listener, "overlap"}] == 2

    send(
      client,
      {:transport_message,
       %{
         "jsonrpc" => "2.0",
         "id" => first_request["id"],
         "error" => %{"code" => -32603, "message" => "failed"}
       }}
    )

    assert {:error, _} = Task.await(first)
    assert :sys.get_state(client).update_drops[{:event_listener, "overlap"}] == 2
    send(listener, :drain)
    assert_receive {:delivered, {:acp_session_update, "overlap", _}}
    assert_receive {:delivered, {:acp_session_updates_dropped, "overlap", 2}}, 1_000

    send(
      client,
      {:transport_message, %{"jsonrpc" => "2.0", "id" => second_request["id"], "result" => %{}}}
    )

    assert {:ok, _} = Task.await(second)
  end

  test "end_session without agent close support retires its notices immediately" do
    listener = held_listener()

    {client, _transport} =
      start_client(event_listener: listener, notify_update_drops: true, max_update_queue: 1)

    for _ <- 1..3, do: send(client, {:transport_message, update()})
    assert :sys.get_state(client).update_drops != %{}
    assert :ok = Client.end_session(client, "drop-session")
    state = :sys.get_state(client)
    assert state.update_drops == %{}
    assert state.update_drop_timer == nil
  end

  def capture(_event, measurements, metadata, {parent, client}) do
    if self() == client, do: send(parent, {:drop, measurements, metadata})
  end

  defp attach(client) do
    id = make_ref()

    :ok =
      :telemetry.attach(
        id,
        [:ex_mcp, :acp, :session, :update_dropped],
        &__MODULE__.capture/4,
        {self(), client}
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp assert_drop(target, limit) do
    assert_receive {:drop, %{count: 1, bytes: bytes},
                    %{session_id: "drop-session", target: ^target, limit: ^limit}}

    assert bytes > 0
  end

  defp held_listener do
    parent = self()

    listener =
      spawn_link(fn ->
        receive do
          :drain -> deliver(parent)
        end
      end)

    on_exit(fn -> Process.exit(listener, :kill) end)
    listener
  end

  defp deliver(parent) do
    receive do
      message ->
        send(parent, {:delivered, message})
        deliver(parent)
    end
  end

  defp update(text \\ "chunk") do
    %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => "drop-session",
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => text}
        }
      }
    }
  end

  defp start_client(opts) do
    {:ok, peer} = Memory.new_pair()
    {:ok, transport} = Memory.connect(peer: peer, role: :agent)

    handshake =
      Task.async(fn ->
        %{"id" => id} = receive_raw(transport)

        send_raw(transport, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "protocolVersion" => 1,
            "agentCapabilities" => %{
              "loadSession" => true,
              "sessionCapabilities" => %{"resume" => %{}}
            },
            "authMethods" => []
          }
        })

        %{"id" => id} = receive_raw(transport)

        send_raw(transport, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{"sessionId" => "drop-session"}
        })
      end)

    {:ok, client} =
      Client.start_link(
        Keyword.merge(
          [
            transport_mod: Memory,
            peer: peer,
            role: :client,
            handler: Handler,
            handler_opts: [parent: self()]
          ],
          opts
        )
      )

    assert {:ok, %{"sessionId" => "drop-session"}} = Client.new_session(client, "/tmp")
    Task.await(handshake)
    {client, transport}
  end

  defp send_raw(transport, message),
    do: assert({:ok, _} = Memory.send_message(Jason.encode!(message), transport))

  defp receive_raw(transport) do
    assert {:ok, message, _} = Memory.receive_message(transport)
    Jason.decode!(message)
  end
end
