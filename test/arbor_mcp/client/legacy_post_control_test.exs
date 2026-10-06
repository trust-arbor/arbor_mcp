defmodule Arbor.MCP.Client.LegacyPostControlTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.{ConnectionScope, Deadline, Lifetime}
  alias Arbor.MCP.Internal.Protocol
  alias Arbor.MCP.Transport.HTTP.LegacySSE

  test "copied identities cannot register, settle or refund a Legacy worker" do
    client = native_client()
    held = held_post(client, self())

    borrowed =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(borrowed), do: Process.exit(borrowed, :kill) end)
    before_state = :sys.get_state(client)

    for changes <- [
          %{nonce: make_ref()},
          %{generation: nil},
          %{deadline: held.entry.deadline + 1},
          %{request_id: "copied"},
          %{task_pid: borrowed}
        ] do
      send(client, {:async_post_result, {:error, :forged}, Map.merge(held.meta, changes)})
    end

    send(client, {:async_post_task, held.monitor, borrowed, held.id})

    send(
      client,
      {:async_post_result, {:error, :forged}, %{task_pid: borrowed, request_id: held.id}}
    )

    send(client, {:DOWN, held.monitor, :process, held.pid, :forged})
    assert :sys.get_state(client) == before_state
    assert Process.alive?(held.pid)
    assert Process.alive?(borrowed)
    reply = held.reply
    refute_receive {^reply, _outcome}, 0
  end

  test "a genuine result settles once but capacity stays charged until actual worker DOWN" do
    client = native_client(max_client_workers: 1)
    held = held_post(client, self())
    send(held.pid, :deliver)
    assert_receive {reply, {:error, {:transport_error, :fixture_result}}}, 1_000
    assert reply == held.reply
    state = :sys.get_state(client)
    assert state.async_post_tasks[held.monitor].completed?
    assert Process.alive?(held.pid)
    assert Map.has_key?(:sys.get_state(held.observer).workers, held.pid)

    send(client, {:async_post_result, {:error, :duplicate}, held.meta})
    assert :sys.get_state(client).async_post_tasks == state.async_post_tasks
    refute_receive {^reply, _duplicate}, 0

    assert {:error, %{reason: :client_worker_limit}} =
             GenServer.call(client, {:request, "ping", %{}, %{timeout: nil}})

    assert map_size(:sys.get_state(client).async_post_tasks) == 1
    send(held.pid, :release)
    assert_down(held.pid)
    await_empty(client, held.observer, Deadline.after_ms(1_000))
  end

  test "caller death independently stops only the registered worker" do
    client = native_client()

    caller =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    held = held_post(client, caller)
    Process.exit(caller, :kill)
    assert_down(held.pid)
    await_empty(client, held.observer, Deadline.after_ms(1_000))
    assert Process.alive?(client)
    assert Process.alive?(held.observer)
  end

  test "public cancellation retires its owned worker and preserves a borrowed process" do
    client = native_client()
    held = held_post(client, self())

    borrowed =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(borrowed), do: Process.exit(borrowed, :kill) end)
    send(client, {:async_post_task, make_ref(), borrowed, held.id})
    assert :ok = Client.send_cancelled(client, held.id, "test cancellation")
    assert_receive {reply, {:error, :cancelled}}, 1_000
    assert reply == held.reply
    assert_down(held.pid)
    await_empty(client, held.observer, Deadline.after_ms(1_000))
    assert Process.alive?(borrowed)
  end

  for deliver? <- [false, true] do
    test "queued #{if deliver?, do: "result and DOWN", else: "DOWN"} preserve original timeout" do
      client = native_client()
      held = held_post(client, self(), 500)
      assert Deadline.remaining(held.entry.deadline) > 0
      assert :ok = :sys.suspend(client)

      try do
        if unquote(deliver?), do: send(held.pid, :deliver)
        assert_down(held.pid)
        assert Deadline.expired?(held.entry.deadline)
      after
        :ok = :sys.resume(client)
      end

      assert_receive {reply, {:error, :timeout}}, 1_000
      assert reply == held.reply
      assert :sys.get_state(client).pending_requests == %{}
      await_empty(client, held.observer, Deadline.after_ms(1_000))
    end
  end

  test "oversized frame is rejected before any POST worker or DNS effect" do
    client = native_client()
    {observer, _token, _epoch} = Lifetime.from_client(client)
    test = self()

    :sys.replace_state(client, fn state ->
      transport = %{
        state.transport_state
        | max_request_bytes: 128,
          post_url: "http://never-resolve.invalid/message",
          dns_resolver: fn _host, _timeout ->
            send(test, :unexpected_dns)
            {:error, :fixture_refusal}
          end
      }

      %{state | transport_state: transport}
    end)

    assert {:error, %{reason: :request_too_large}} =
             GenServer.call(
               client,
               {:request, "ping", %{"data" => String.duplicate("x", 256)}, %{timeout: nil}}
             )

    assert :sys.get_state(client).async_post_tasks == %{}
    assert :sys.get_state(observer).workers == %{}
    refute_receive :unexpected_dns, 0
  end

  test "authenticated batch failure keeps ordered completed outcomes and sibling state" do
    client = native_client()
    held = held_post(client, self())
    other_reply = make_ref()
    test = self()
    completed = {:ok, %{"kept" => true}}

    sibling = %{
      "sibling-batch" => {{test, other_reply}, :batch, ["sibling-member"], %{}},
      "sibling-member" => "sibling-batch"
    }

    :sys.replace_state(client, fn state ->
      batch = %{
        held.id =>
          {{test, held.reply}, :batch, ["member-a", "member-b"], %{"member-a" => completed}},
        "member-a" => held.id,
        "member-b" => held.id
      }

      %{state | pending_requests: Map.merge(sibling, batch)}
    end)

    send(held.pid, :deliver)
    reply = held.reply

    assert_receive {^reply, {:ok, [^completed, {:error, {:transport_error, :fixture_result}}]}},
                   1_000

    assert :sys.get_state(client).pending_requests == sibling
    assert map_size(:sys.get_state(client).async_post_tasks) == 1
    send(client, {:async_post_result, {:error, :duplicate}, held.meta})
    assert :sys.get_state(client).pending_requests == sibling
    refute_receive {^other_reply, _response}, 0
    send(held.pid, :release)
    assert_down(held.pid)
    await_empty(client, held.observer, Deadline.after_ms(1_000))
  end

  test "public member cancellation keeps the batch POST charged and other members pending" do
    client = native_client()
    held = held_post(client, self())
    test = self()

    pending = %{
      held.id => {{test, held.reply}, :batch, ["member-a", "member-b"], %{}},
      "member-a" => held.id,
      "member-b" => held.id
    }

    :sys.replace_state(client, &%{&1 | pending_requests: pending})

    assert :ok = Client.send_cancelled(client, "member-a", "member-only cancellation")
    state = :sys.get_state(client)
    assert state.pending_requests == pending
    assert MapSet.member?(state.cancelled_requests, "member-a")
    refute MapSet.member?(state.cancelled_requests, "member-b")
    assert state.async_post_tasks == %{held.monitor => held.entry}

    assert Process.alive?(held.pid) and
             Map.has_key?(:sys.get_state(held.observer).workers, held.pid)

    reply = held.reply
    refute_receive {^reply, _premature}, 0

    send(held.pid, :deliver)
    assert_receive {^reply, {:error, {:transport_error, :fixture_result}}}, 1_000
    assert :sys.get_state(client).pending_requests == %{}
    assert map_size(:sys.get_state(client).async_post_tasks) == 1
    assert Process.alive?(held.pid)
    send(held.pid, :release)
    assert_down(held.pid)
    await_empty(client, held.observer, Deadline.after_ms(1_000))
  end

  test "batch DOWN after the original cutoff preserves its timeout and member outcomes" do
    client = native_client()
    held = held_post(client, self(), 500)
    test = self()

    :sys.replace_state(client, fn state ->
      pending = %{
        held.id => {{test, held.reply}, :batch, ["member-a", "member-b"], %{}},
        "member-a" => held.id,
        "member-b" => held.id
      }

      %{state | pending_requests: pending}
    end)

    assert :ok = :sys.suspend(client)

    try do
      assert_down(held.pid)
      assert Deadline.expired?(held.entry.deadline)
    after
      :ok = :sys.resume(client)
    end

    reply = held.reply
    assert_receive {^reply, {:error, :timeout}}, 1_000
    assert :sys.get_state(client).pending_requests == %{}
    await_empty(client, held.observer, Deadline.after_ms(1_000))
  end

  test "public batch captures its cutoff before a queued Client call and never sends after it" do
    client = native_client()
    {observer, _token, _epoch} = Lifetime.from_client(client)
    test = self()

    :sys.replace_state(client, fn state ->
      transport = %{
        state.transport_state
        | post_url: "http://never-resolve.invalid/message",
          dns_resolver: fn _host, _timeout ->
            send(test, :unexpected_dns)
            {:error, :fixture_refusal}
          end
      }

      %{state | transport_state: transport}
    end)

    assert :ok = :sys.suspend(client)

    caller =
      spawn(fn ->
        outcome =
          try do
            Client.batch_request(client, [{"ping", %{}}], 80)
          catch
            :exit, reason -> {:exit, reason}
          end

        send(test, {:public_batch_outcome, self(), outcome})

        receive do
          :done -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)

    try do
      meta = queued_batch(client, caller, Deadline.after_ms(1_000))
      assert meta.timeout == 80 and is_integer(meta.deadline)
      assert_receive {:public_batch_outcome, ^caller, {:exit, {:timeout, _call}}}, 1_000
      assert Process.alive?(caller) and Deadline.expired?(meta.deadline)
    after
      :ok = :sys.resume(client)
    end

    assert :sys.get_state(client).pending_requests == %{}
    await_empty(client, observer, Deadline.after_ms(1_000))
    refute_receive :unexpected_dns, 0
    send(caller, :done)
    assert_down(caller)
  end

  for batch? <- [false, true] do
    test "queued genuine late SSE #{if batch?, do: "batch member", else: "single final"} cannot beat its original cutoff" do
      client = native_client()
      held = held_post(client, self(), 500)
      test = self()
      response_id = if unquote(batch?), do: "member-b", else: held.id
      completed = {:ok, %{"kept" => true}}

      if unquote(batch?) do
        :sys.replace_state(client, fn state ->
          pending = %{
            held.id =>
              {{test, held.reply}, :batch, ["member-a", "member-b"], %{"member-a" => completed}},
            "member-a" => held.id,
            "member-b" => held.id
          }

          %{state | pending_requests: pending}
        end)
      end

      assert :ok = :sys.suspend(client)

      try do
        send(
          held.pid,
          {:late_response,
           %{"jsonrpc" => "2.0", "id" => response_id, "result" => %{"late" => true}}}
        )

        pid = held.pid
        assert_receive {:held_response_queued, ^pid}, 1_000
        assert_down(held.pid)
        assert Deadline.expired?(held.entry.deadline)
      after
        :ok = :sys.resume(client)
      end

      reply = held.reply

      if unquote(batch?) do
        assert_receive {^reply, {:ok, [^completed, {:error, :timeout}]}}, 1_000
      else
        assert_receive {^reply, {:error, :timeout}}, 1_000
      end

      refute_receive {^reply, _duplicate}, 0
      assert :sys.get_state(client).pending_requests == %{}
      await_empty(client, held.observer, Deadline.after_ms(1_000))
    end
  end

  test "successful POST DOWN retains bounded original cutoff until its delayed SSE outcome" do
    client = native_client(max_client_workers: 1)
    held = held_post(client, self(), 500)
    send(held.pid, :success_release)
    assert_down(held.pid)
    state = await_post_down(client, held.monitor, Deadline.after_ms(1_000))
    assert state.async_post_tasks[held.monitor].actual_down?
    assert state.async_post_tasks[held.monitor].completed?
    assert state.async_post_tasks[held.monitor].deadline == held.entry.deadline
    assert Map.has_key?(state.pending_requests, held.id)

    assert {:error, %{reason: :client_worker_limit}} =
             GenServer.call(client, {:request, "ping", %{}, %{timeout: nil}})

    reply = held.reply
    assert_receive {^reply, {:error, :timeout}}, 1_000
    assert Deadline.expired?(held.entry.deadline)
    await_empty(client, held.observer, Deadline.after_ms(1_000))
  end

  test "timely authentic SSE can settle after the successful POST worker is already DOWN" do
    client = native_client(max_client_workers: 1)
    held = held_post(client, self(), 1_000)
    send(held.pid, :success_release)
    assert_down(held.pid)
    state = await_post_down(client, held.monitor, held.entry.deadline)
    assert state.async_post_tasks[held.monitor].actual_down?
    await_workers_empty(held.observer, held.entry.deadline)
    producer = sse_producer(client, held.entry.deadline)

    send(
      producer,
      {:response, %{"jsonrpc" => "2.0", "id" => held.id, "result" => %{"timely" => true}}}
    )

    assert_receive {:sse_response_queued, ^producer}, 1_000
    reply = held.reply
    assert_receive {^reply, {:ok, %{"timely" => true}}}, 1_000
    assert not Deadline.expired?(held.entry.deadline)
    assert :sys.get_state(client).pending_requests == %{}
    assert :sys.get_state(client).async_post_tasks == %{}
    send(producer, :release)
    assert_down(producer)
    await_empty(client, held.observer, held.entry.deadline)
    refute_receive {^reply, _duplicate}, 0
  end

  test "late authentic SSE remains fenced after a successful POST worker has already gone DOWN" do
    client = native_client(max_client_workers: 1)
    held = held_post(client, self(), 500)
    send(held.pid, :success_release)
    assert_down(held.pid)
    state = await_post_down(client, held.monitor, Deadline.after_ms(1_000))
    assert state.async_post_tasks[held.monitor].deadline == held.entry.deadline
    await_workers_empty(held.observer, held.entry.deadline)
    producer = sse_producer(client, held.entry.deadline)
    assert :ok = :sys.suspend(client)

    try do
      send(
        producer,
        {:response, %{"jsonrpc" => "2.0", "id" => held.id, "result" => %{"late" => true}}}
      )

      assert_receive {:sse_response_queued, ^producer}, 1_000
      assert_down(producer)
      assert Deadline.expired?(held.entry.deadline)
    after
      :ok = :sys.resume(client)
    end

    reply = held.reply
    assert_receive {^reply, {:error, :timeout}}, 1_000
    refute_receive {^reply, _duplicate}, 0
    assert :sys.get_state(client).pending_requests == %{}
    await_empty(client, held.observer, Deadline.after_ms(1_000))
  end

  for operation <- [:disconnect, :transport_close] do
    test "#{operation} settles actual integer batch identity without losing partial ordered outcomes" do
      client = native_client()
      held = held_post(client, self())
      assert is_integer(held.id)
      test = self()
      completed = {:ok, %{"kept" => true}}

      :sys.replace_state(client, fn state ->
        pending = %{
          held.id =>
            {{test, held.reply}, :batch, ["member-a", "member-b"], %{"member-a" => completed}},
          "member-a" => held.id,
          "member-b" => held.id
        }

        # This control has no physical SSE transport; only the actual native
        # Lifetime-owned POST worker and public pending-batch cleanup are under test.
        %{state | pending_requests: pending, transport_state: nil}
      end)

      case unquote(operation) do
        :disconnect -> assert :ok = Client.disconnect(client)
        :transport_close -> send(held.pid, :transport_close)
      end

      reply = held.reply
      assert_receive {^reply, {:ok, [^completed, {:error, _connection_error}]}}, 1_000
      assert_down(held.pid)
      assert :sys.get_state(client).pending_requests == %{}
      assert :sys.get_state(client).async_post_tasks == %{}
      assert :sys.get_state(client).connection_status == :disconnected
      refute_receive {^reply, _duplicate}, 0
      assert Process.alive?(client)
    end
  end

  defp sse_producer(client, cutoff) do
    test = self()

    :sys.replace_state(client, fn state ->
      owner = self()

      {pid, _monitor} =
        ConnectionScope.spawn_monitor(
          fn ->
            :ok = Lifetime.watch_caller(test, cutoff)
            send(test, {:sse_producer_ready, self()})

            receive do
              {:response, response} ->
                Lifetime.deliver(owner, {:transport_message, Jason.encode!(response)})
                send(test, {:sse_response_queued, self()})

                receive do
                  :release -> :ok
                end
            end
          end,
          Deadline.earliest(cutoff, Deadline.after_ms(1_000))
        )

      send(test, {:sse_producer_identity, pid})
      state
    end)

    assert_receive {:sse_producer_identity, pid}, 1_000
    assert_receive {:sse_producer_ready, ^pid}, 1_000
    pid
  end

  defp await_workers_empty(observer, cutoff) do
    if :sys.get_state(observer).workers != %{} do
      assert not Deadline.expired?(cutoff)
      Process.sleep(5)
      await_workers_empty(observer, cutoff)
    end
  end

  defp await_post_down(client, monitor, cutoff) do
    state = :sys.get_state(client)

    if state.async_post_tasks[monitor].actual_down? do
      state
    else
      assert not Deadline.expired?(cutoff)
      Process.sleep(5)
      await_post_down(client, monitor, cutoff)
    end
  end

  defp queued_batch(client, caller, cutoff) do
    {:messages, messages} = Process.info(client, :messages)

    case Enum.find(messages, fn
           {:"$gen_call", {^caller, _tag}, {:batch_request, _requests, _meta}} -> true
           _other -> false
         end) do
      {:"$gen_call", {^caller, _tag}, {:batch_request, _requests, meta}} ->
        meta

      nil ->
        assert not Deadline.expired?(cutoff)
        Process.sleep(5)
        queued_batch(client, caller, cutoff)
    end
  end

  defp native_client(opts \\ []) do
    {:ok, client} =
      Client.start_link(
        Keyword.merge([_skip_connect: true, reconnect: false, health_check_interval: nil], opts)
      )

    Process.unlink(client)
    {observer, _token, _epoch} = Lifetime.from_client(client)

    on_exit(fn ->
      if Process.alive?(client), do: Process.exit(client, :kill)
      assert_down(client)
      assert_down(observer)
    end)

    :sys.replace_state(client, fn state ->
      transport = %LegacySSE{
        post_url: "file:///not-a-network-endpoint",
        headers: [],
        timeouts: %{connect: 1_000, request: 5_000},
        max_request_bytes: 1_024,
        max_response_bytes: 1_024,
        dns_timeout_ms: 1_000,
        allowed_private_hosts: []
      }

      %{
        state
        | transport_mod: LegacySSE,
          transport_state: transport,
          initialized: true,
          connection_status: :ready,
          protocol_version: "2024-11-05"
      }
    end)

    client
  end

  # Install the control through the actual native Client, using its real
  # Lifetime worker registration. No borrowed PID is adopted or registered.
  # Physical original-POST/reverse behavior is covered by the separate wire
  # fixture; these controls isolate authentication, credit and cutoff races.
  defp held_post(client, caller, budget \\ 5_000) do
    test = self()
    reply = make_ref()
    id = Protocol.generate_id()

    :sys.replace_state(client, fn state ->
      context = Lifetime.current()
      cutoff = Deadline.after_ms(budget)
      nonce = make_ref()

      meta = %{
        kind: :legacy_post,
        request_id: id,
        nonce: nonce,
        generation: context,
        deadline: cutoff
      }

      owner = self()

      {pid, monitor} =
        ConnectionScope.spawn_monitor(
          fn ->
            :ok = Lifetime.watch_caller(caller, cutoff)
            send(test, {:held_post_ready, self(), cutoff})

            receive do
              :deliver ->
                Lifetime.deliver(
                  owner,
                  {:async_post_result, {:error, :fixture_result},
                   Map.put(meta, :task_pid, self())}
                )

                receive do
                  :release -> :ok
                end

              :success_release ->
                Lifetime.deliver(
                  owner,
                  {:async_post_result, {:ok, :fixture_transport},
                   Map.put(meta, :task_pid, self())}
                )

              {:late_response, response} ->
                Lifetime.deliver(
                  owner,
                  {:async_post_result, {:ok, :fixture_transport},
                   Map.put(meta, :task_pid, self())}
                )

                Lifetime.deliver(owner, {:transport_message, Jason.encode!(response)})
                send(test, {:held_response_queued, self()})

                receive do
                  :release -> :ok
                end

              :transport_close ->
                Lifetime.deliver(owner, {:transport_closed, :fixture_closed})

                receive do
                  :release -> :ok
                end

              :release ->
                :ok
            end
          end,
          Deadline.earliest(cutoff, Deadline.after_ms(1_000))
        )

      entry =
        meta
        |> Map.put(:task_pid, pid)
        |> Map.put(:completed?, false)
        |> Map.put(:actual_down?, false)

      Process.send_after(self(), {:request_timeout, id}, Deadline.remaining(cutoff))
      send(test, {:held_post_identity, pid, monitor, entry})

      %{
        state
        | async_post_tasks: Map.put(state.async_post_tasks, monitor, entry),
          pending_requests: Map.put(state.pending_requests, id, {{test, reply}, :single, "ping"})
      }
    end)

    assert_receive {:held_post_identity, pid, monitor, entry}, 1_000
    assert_receive {:held_post_ready, ^pid, cutoff}, 1_000
    assert cutoff == entry.deadline and not Deadline.expired?(cutoff)
    {observer, _token, _epoch} = Lifetime.from_client(client)
    assert Map.has_key?(:sys.get_state(observer).workers, pid)

    %{
      pid: pid,
      monitor: monitor,
      entry: entry,
      meta: Map.take(entry, [:kind, :task_pid, :request_id, :nonce, :generation, :deadline]),
      id: id,
      reply: reply,
      observer: observer
    }
  end

  defp await_empty(client, observer, cutoff) do
    if :sys.get_state(client).async_post_tasks != %{} or :sys.get_state(observer).workers != %{} do
      assert not Deadline.expired?(cutoff)
      Process.sleep(5)
      await_empty(client, observer, cutoff)
    end
  end

  defp assert_down(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
  end
end
