defmodule Arbor.MCP.Server.Runtime.HTTPWriterRegistryTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.Runtime.{
    Deadline,
    HTTPWriterBinding,
    HTTPWriterRegistry,
    HTTPWriteTicket
  }

  test "hidden preparation is invisible and delivery carries only a token until checkout" do
    domain = domain()
    binding = writer_binding(domain)
    wire = "data: {\"result\":1}\r\n\r\n"
    {:ok, ticket} = HTTPWriterRegistry.prepare(binding, wire)
    assert :empty = HTTPWriterRegistry.checkout(binding)
    refute_receive {:mcp_http_output_wake, _, _}, 20
    assert :ok = HTTPWriterRegistry.publish(ticket)
    assert_receive {:mcp_http_output_wake, ^domain, nonce}
    assert :ok = HTTPWriterRegistry.acknowledge_wake(domain, nonce)
    assert {:ok, checked, ^wire} = HTTPWriterRegistry.checkout(binding)
    assert :ok = HTTPWriterRegistry.complete(checked, :ok)
    eventually(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
  end

  test "prepared queued and checked-out frames share the exact count limit" do
    domain = domain(max_io_frames: 2)
    binding = writer_binding(domain)
    {:ok, first} = HTTPWriterRegistry.prepare(binding, "first")
    {:ok, second} = HTTPWriterRegistry.prepare(binding, "second")
    assert :ok = HTTPWriterRegistry.publish(first)
    assert :ok = HTTPWriterRegistry.publish(second)
    assert {:error, :http_output_busy} = HTTPWriterRegistry.prepare(binding, "third")
    {:ok, first, "first"} = HTTPWriterRegistry.checkout(binding)
    assert {:error, :http_write_in_flight} = HTTPWriterRegistry.checkout(binding)
    assert %{frames: 2, queued: 1, in_flight: 1} = HTTPWriterRegistry.stats(domain)
    assert :ok = HTTPWriterRegistry.complete(first, :ok)
    eventually(fn -> HTTPWriterRegistry.stats(domain).frames == 1 end)
    assert {:ok, _third} = HTTPWriterRegistry.prepare(binding, "third")
  end

  test "the byte cap includes wire, retained binary term and fixed bookkeeping" do
    sample = domain()
    sample_binding = writer_binding(sample)
    {:ok, ticket} = HTTPWriterRegistry.prepare(sample_binding, "abc")
    charged = HTTPWriterRegistry.stats(sample).bytes
    assert charged > 6
    assert :ok = HTTPWriterRegistry.release(ticket)
    exact = domain(max_io_bytes: charged)
    exact_binding = writer_binding(exact)
    assert {:ok, _} = HTTPWriterRegistry.prepare(exact_binding, "abc")
    assert HTTPWriterRegistry.stats(exact).bytes == charged
    assert {:error, :http_output_busy} = HTTPWriterRegistry.prepare(exact_binding, "")
    below = domain(max_io_bytes: charged - 1)
    assert {:error, :http_output_busy} = HTTPWriterRegistry.prepare(writer_binding(below), "abc")
    assert HTTPWriterRegistry.stats(below).frames == 0
  end

  test "frame maximum includes all framing bytes and empty wire is accounted" do
    domain = domain(max_io_frame_bytes: 10)
    binding = writer_binding(domain)
    assert {:ok, _} = HTTPWriterRegistry.prepare(binding, String.duplicate("x", 10))

    assert {:error, :http_frame_too_large} =
             HTTPWriterRegistry.prepare(binding, String.duplicate("x", 11))

    assert {:ok, _} = HTTPWriterRegistry.prepare(binding, "")
    assert {:error, :invalid_http_wire} = HTTPWriterRegistry.prepare(binding, ["x"])
  end

  test "writer count and metadata are independently bounded before registration" do
    domain = domain(max_writers: 1)
    writer_binding(domain)
    second = owned_process()
    assert {:error, :http_writer_busy} = HTTPWriterRegistry.register(domain, second, proof())
    assert HTTPWriterRegistry.stats(domain).writers == 1
    low = domain(max_writer_metadata_bytes: 1)
    assert {:error, :http_writer_busy} = HTTPWriterRegistry.register(low, self(), proof())
    assert HTTPWriterRegistry.stats(low).writers == 0
  end

  test "an owner handoff preserves hidden output after producer exit" do
    domain = domain()
    binding = writer_binding(domain)
    parent = self()

    producer =
      spawn(fn ->
        {:ok, ticket} = HTTPWriterRegistry.prepare(binding, "retained", owner: parent)
        send(parent, {:prepared, ticket})

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {:prepared, ticket}
    assert :ok = HTTPWriterRegistry.handoff(ticket)
    monitor = Process.monitor(producer)
    send(producer, :exit)
    assert_receive {:DOWN, ^monitor, :process, ^producer, :normal}
    Process.sleep(30)
    assert %{held: 1, frames: 1} = HTTPWriterRegistry.stats(domain)
    assert :ok = HTTPWriterRegistry.publish(ticket)
    {:ok, checked, "retained"} = HTTPWriterRegistry.checkout(binding)
    assert :ok = HTTPWriterRegistry.complete(checked, :ok)
  end

  test "a producer transfers before Task return without waiting for its persistent owner" do
    domain = domain()
    binding = writer_binding(domain)
    owner = self()

    task =
      Task.async(fn ->
        {:ok, ticket} = HTTPWriterRegistry.prepare(binding, "task-result", owner: owner)
        :ok = HTTPWriterRegistry.handoff(ticket)
        ticket
      end)

    ticket = Task.await(task)
    eventually(fn -> not Process.alive?(task.pid) end)
    Process.sleep(20)
    assert %{held: 1} = HTTPWriterRegistry.stats(domain)
    assert :ok = HTTPWriterRegistry.publish(ticket)
    {:ok, ticket, "task-result"} = HTTPWriterRegistry.checkout(binding)
    assert :ok = HTTPWriterRegistry.complete(ticket, :ok)
  end

  test "dead hidden producers are reaped even if guardian monitoring was paused" do
    domain = domain(max_io_frames: 1)
    binding = writer_binding(domain)
    :sys.suspend(domain_pid(domain))
    parent = self()

    producer =
      spawn(fn ->
        send(parent, {:prepared, HTTPWriterRegistry.prepare(binding, "hidden", owner: parent)})
      end)

    monitor = Process.monitor(producer)
    assert_receive {:prepared, {:ok, _}}
    assert_receive {:DOWN, ^monitor, :process, ^producer, :normal}
    assert {:error, :http_output_busy} = HTTPWriterRegistry.prepare(binding, "replacement")
    :sys.resume(domain_pid(domain))
    eventually(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
    assert {:ok, _} = HTTPWriterRegistry.prepare(binding, "replacement")
  end

  test "real concurrent producers cannot exceed count while guardian is paused" do
    domain = domain(max_io_frames: 8)
    binding = writer_binding(domain)
    :sys.suspend(domain_pid(domain))
    parent = self()

    producers =
      for _ <- 1..40 do
        spawn(fn ->
          receive do
            :go -> :ok
          end

          send(
            parent,
            {:admitted, self(), HTTPWriterRegistry.prepare(binding, "payload", owner: parent)}
          )

          receive do
            :exit -> :ok
          end
        end)
      end

    Enum.each(producers, &send(&1, :go))

    results =
      for _ <- producers do
        receive do
          {:admitted, pid, result} -> {pid, result}
        after
          1_000 -> flunk("producer did not finish")
        end
      end

    assert Enum.count(results, &match?({_, {:ok, _}}, &1)) == 8
    assert HTTPWriterRegistry.stats(domain).frames == 8
    {:messages, messages} = Process.info(domain_pid(domain), :messages)
    assert Enum.count(messages, &(&1 == :wake)) <= 1
    refute Enum.any?(messages, &is_binary/1)
    Enum.each(producers, &send(&1, :exit))
    :sys.resume(domain_pid(domain))
    eventually(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
    assert {:ok, _} = HTTPWriterRegistry.prepare(binding, "readmitted")
  end

  test "original deadline cannot be extended by a preparation option" do
    domain = domain()
    binding = writer_binding(domain, self(), proof(Deadline.now() + 40))
    {:ok, ticket} = HTTPWriterRegistry.prepare(binding, "late", deadline: Deadline.now() + 10_000)
    Process.sleep(50)
    assert {:error, _} = HTTPWriterRegistry.publish(ticket)
    assert {:error, :http_invocation_closed} = HTTPWriterRegistry.proof(binding)
    eventually(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
  end

  test "expired borrowed IO keeps credits until the actual write returns" do
    domain = domain(max_io_frames: 1)
    writer = writer()
    binding = writer_binding(domain, writer, proof(Deadline.now() + 80))
    {:ok, ticket} = HTTPWriterRegistry.prepare(binding, "started")
    :ok = HTTPWriterRegistry.publish(ticket)
    checked = checkout(writer, binding)
    bytes = HTTPWriterRegistry.stats(domain).bytes
    Process.sleep(100)
    assert Process.alive?(writer)
    assert %{in_flight: 1, frames: 1, bytes: ^bytes} = HTTPWriterRegistry.stats(domain)
    other_binding = writer_binding(domain)
    assert {:error, :http_output_busy} = HTTPWriterRegistry.prepare(other_binding, "other")
    assert {:error, :invalid_http_writer} = HTTPWriterRegistry.complete(checked, :ok)
    assert {:error, :invalid_http_writer} = HTTPWriteTicket.record_return(checked, 1)
    assert {:error, :http_write_in_flight} = HTTPWriterRegistry.release(ticket)
    assert {:error, :http_write_uncertain} = complete(writer, checked, :ok)
    eventually(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
    assert {:ok, _} = HTTPWriterRegistry.prepare(other_binding, "other")
  end

  test "retirement cannot release checked-out IO or kill its borrowed writer" do
    domain = domain(max_io_frames: 1)
    writer = writer()
    binding = writer_binding(domain, writer)
    {:ok, ticket} = HTTPWriterRegistry.prepare(binding, "started")
    :ok = HTTPWriterRegistry.publish(ticket)
    checked = checkout(writer, binding)
    assert :ok = HTTPWriterRegistry.retire(binding)
    assert Process.alive?(writer)
    Process.sleep(25)
    assert HTTPWriterRegistry.stats(domain).in_flight == 1
    assert {:error, :http_write_uncertain} = complete(writer, checked, :ok)
    eventually(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
  end

  test "writer DOWN is conclusive release and only retires its own invocation" do
    domain = domain()
    first_writer = writer()
    first = writer_binding(domain, first_writer)
    {:ok, ticket} = HTTPWriterRegistry.prepare(first, "first")
    :ok = HTTPWriterRegistry.publish(ticket)
    checkout(first_writer, first)
    second = writer_binding(domain)
    {:ok, second_ticket} = HTTPWriterRegistry.prepare(second, "second")
    :ok = HTTPWriterRegistry.publish(second_ticket)
    Process.exit(first_writer, :kill)
    eventually(fn -> HTTPWriterRegistry.stats(domain).frames == 1 end)
    assert {:ok, second_ticket, "second"} = HTTPWriterRegistry.checkout(second)
    assert :ok = HTTPWriterRegistry.complete(second_ticket, :ok)
    refute HTTPWriterRegistry.stats(domain).sealed
  end

  test "execution-owner death retains borrowed liability and does not reset the domain" do
    domain = domain()
    owner = owned_process()
    writer = writer()
    {:ok, binding} = HTTPWriterRegistry.register(domain, writer, proof(), owner: owner)
    {:ok, ticket} = HTTPWriterRegistry.prepare(binding, "started")
    :ok = HTTPWriterRegistry.publish(ticket)
    checked = checkout(writer, binding)
    identity = HTTPWriterRegistry.stats(domain).identity
    Process.exit(owner, :kill)

    eventually(fn ->
      match?({:error, :http_invocation_closed}, HTTPWriterRegistry.proof(binding))
    end)

    assert %{in_flight: 1, identity: ^identity} = HTTPWriterRegistry.stats(domain)
    assert Process.alive?(writer)
    assert {:ok, same_domain} = HTTPWriterRegistry.ref(domain_pid(domain))
    assert HTTPWriterRegistry.stats(same_domain).identity == identity
    assert {:error, :http_write_uncertain} = complete(writer, checked, :ok)
  end

  test "root shutdown seals admission but guardian survives until actual IO settlement" do
    root = owned_process()
    {:ok, domain} = HTTPWriterRegistry.start(root, idle_exit_ms: 20)
    writer = writer()
    binding = writer_binding(domain, writer)
    {:ok, ticket} = HTTPWriterRegistry.prepare(binding, "started")
    :ok = HTTPWriterRegistry.publish(ticket)
    checked = checkout(writer, binding)
    guardian = domain_pid(domain)
    monitor = Process.monitor(guardian)
    Process.exit(root, :kill)
    eventually(fn -> HTTPWriterRegistry.stats(domain).sealed end)
    Process.sleep(40)
    assert Process.alive?(guardian)
    assert Process.alive?(writer)
    assert HTTPWriterRegistry.stats(domain).in_flight == 1
    assert {:error, :http_write_uncertain} = complete(writer, checked, :ok)
    assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}, 500
    assert Process.alive?(writer)
  end

  test "unexpected guardian death invalidates the old domain without fresh capacity" do
    domain = domain()
    writer = writer()
    binding = writer_binding(domain, writer)
    {:ok, ticket} = HTTPWriterRegistry.prepare(binding, "started")
    :ok = HTTPWriterRegistry.publish(ticket)
    checked = checkout(writer, binding)
    Process.exit(domain_pid(domain), :kill)
    eventually(fn -> not Process.alive?(domain_pid(domain)) end)
    assert {:error, :http_writer_unavailable} = HTTPWriterRegistry.stats(domain)
    assert {:error, :http_writer_unavailable} = HTTPWriterRegistry.prepare(binding, "again")
    assert {:error, :http_writer_unavailable} = complete(writer, checked, :ok)
    assert Process.alive?(writer)
  end

  test "completion is idempotent and cannot release a newly admitted token" do
    domain = domain(max_io_frames: 1)
    binding = writer_binding(domain)
    {:ok, old} = HTTPWriterRegistry.prepare(binding, "old")
    :ok = HTTPWriterRegistry.publish(old)
    {:ok, old, "old"} = HTTPWriterRegistry.checkout(binding)
    assert :ok = HTTPWriterRegistry.complete(old, :ok)
    eventually(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
    {:ok, fresh} = HTTPWriterRegistry.prepare(binding, "fresh")
    assert :ok = HTTPWriterRegistry.complete(old, :ok)
    assert HTTPWriterRegistry.stats(domain).frames == 1
    assert :ok = HTTPWriterRegistry.release(fresh)
    assert :ok = HTTPWriterRegistry.release(fresh)
    eventually(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
  end

  test "actual IO errors stay fixed and are never retried or overwritten by later ACK" do
    domain = domain()
    binding = writer_binding(domain)
    {:ok, ticket} = HTTPWriterRegistry.prepare(binding, "started")
    :ok = HTTPWriterRegistry.publish(ticket)
    {:ok, ticket, _} = HTTPWriterRegistry.checkout(binding)
    assert {:error, :http_write_failed} = HTTPWriterRegistry.complete(ticket, {:error, self()})
    assert {:error, :http_write_failed} = HTTPWriterRegistry.complete(ticket, :ok)
    eventually(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
  end

  test "finite concurrent registration churn does not leave scope tombstones" do
    domain = domain(max_writers: 2)

    for _ <- 1..140 do
      binding = writer_binding(domain)
      assert :ok = HTTPWriterRegistry.retire(binding)
      eventually(fn -> HTTPWriterRegistry.stats(domain).writers == 0 end)
      assert {:error, :http_invocation_closed} = HTTPWriterRegistry.prepare(binding, "late")
    end

    assert %{writers: 0, writer_metadata_bytes: 0, frames: 0, bytes: 0} =
             HTTPWriterRegistry.stats(domain)
  end

  test "metadata and malformed deadlines reject before any retained row or mailbox payload" do
    domain = domain()

    assert {:error, :invalid_http_invocation_proof} =
             HTTPWriterRegistry.register(domain, self(), proof() |> Map.put(:deadline, :infinity))

    assert {:error, :invalid_http_invocation_proof} =
             HTTPWriterRegistry.register(
               domain,
               self(),
               proof() |> Map.put(:deadline, Integer.pow(2, 100))
             )

    assert {:error, :invalid_http_invocation_proof} =
             HTTPWriterRegistry.register(
               domain,
               self(),
               proof() |> Map.put(:lease, String.duplicate("private", 2_000))
             )

    assert %{writers: 0, frames: 0, bytes: 0} = HTTPWriterRegistry.stats(domain)
    binding = writer_binding(domain)

    assert {:error, :invalid_http_output_deadline} =
             HTTPWriterRegistry.prepare(binding, "x", deadline: :infinity)

    {:messages, messages} = Process.info(domain_pid(domain), :messages)
    refute Enum.any?(messages, &is_binary/1)
    assert {:error, :http_invocation_closed} = HTTPWriterBinding.validate(binding, :not_a_runtime)
    assert {:error, :invalid_http_write_ticket} = HTTPWriteTicket.address(:not_a_ticket)
  end

  test "guardian suspension cannot make producer calls wait beyond the original deadline" do
    domain = domain()
    binding = writer_binding(domain, self(), proof(Deadline.now() + 100))
    :sys.suspend(domain_pid(domain))
    start = Deadline.now()
    assert {:ok, ticket} = HTTPWriterRegistry.prepare(binding, "bounded")
    assert :ok = HTTPWriterRegistry.publish(ticket)
    assert Deadline.now() - start < 80
    Process.sleep(110)
    assert {:error, _} = HTTPWriterRegistry.checkout(binding)
    assert {:error, _} = HTTPWriterRegistry.publish(ticket)
    :sys.resume(domain_pid(domain))
    eventually(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
  end

  test "actual blocking IO return retains liability across cutoff and root shutdown" do
    root = owned_process()
    {:ok, domain} = HTTPWriterRegistry.start(root, idle_exit_ms: 20)
    writer = writer()
    device = blocked_device()
    binding = writer_binding(domain, writer, proof(Deadline.now() + 80))
    {:ok, ticket} = HTTPWriterRegistry.prepare(binding, "data: {}\r\n\r\n")
    :ok = HTTPWriterRegistry.publish(ticket)
    send(writer, {:write_io, binding, device})
    assert_receive {:io_checked, ^writer, _checked}
    assert_receive {:io_blocked, ^device}
    Process.exit(root, :kill)
    Process.sleep(100)
    assert HTTPWriterRegistry.stats(domain).in_flight == 1
    assert Process.alive?(writer)
    assert Process.alive?(domain_pid(domain))
    refute_receive {:io_returned, ^writer, _}, 20
    guardian = domain_pid(domain)
    monitor = Process.monitor(guardian)
    send(device, :release_io)
    assert_receive {:io_returned, ^writer, {:error, :http_write_uncertain}}
    assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}, 500
    assert Process.alive?(writer)
  end

  test "same PID churn preserves one outstanding late wake under paused notifier" do
    domain = domain(max_writers: 1)
    old_binding = writer_binding(domain)
    {:ok, old} = HTTPWriterRegistry.prepare(old_binding, "old")
    :ok = HTTPWriterRegistry.publish(old)

    eventually(fn ->
      Enum.any?(
        elem(Process.info(self(), :messages), 1),
        &match?({:mcp_http_output_wake, ^domain, _}, &1)
      )
    end)

    :sys.suspend(domain_pid(domain))
    assert :ok = HTTPWriterRegistry.retire(old_binding)

    for _ <- 1..140 do
      binding = writer_binding(domain)
      {:ok, ticket} = HTTPWriterRegistry.prepare(binding, "intermediate")
      :ok = HTTPWriterRegistry.publish(ticket)
      :ok = HTTPWriterRegistry.retire(binding)
    end

    final_binding = writer_binding(domain)
    {:ok, final} = HTTPWriterRegistry.prepare(final_binding, "final")
    :ok = HTTPWriterRegistry.publish(final)
    {:messages, messages} = Process.info(self(), :messages)
    assert Enum.count(messages, &match?({:mcp_http_output_wake, ^domain, _}, &1)) == 1
    assert %{writers: 1, bindings: 1, frames: 1} = HTTPWriterRegistry.stats(domain)
    :sys.resume(domain_pid(domain))
    Process.sleep(20)
    assert_receive {:mcp_http_output_wake, ^domain, old_nonce}
    refute_receive {:mcp_http_output_wake, ^domain, _}, 20
    :ok = HTTPWriterRegistry.acknowledge_wake(domain, old_nonce)
    {:ok, final, "final"} = HTTPWriterRegistry.checkout(final_binding)
    :ok = HTTPWriterRegistry.complete(final, :ok)
    eventually(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
    {:ok, fresh} = HTTPWriterRegistry.prepare(final_binding, "fresh")
    :ok = HTTPWriterRegistry.publish(fresh)
    assert_receive {:mcp_http_output_wake, ^domain, fresh_nonce}
    assert fresh_nonce != old_nonce
    assert {:error, :invalid_http_wake} = HTTPWriterRegistry.acknowledge_wake(domain, old_nonce)
    :ok = HTTPWriterRegistry.acknowledge_wake(domain, fresh_nonce)
  end

  test "generation retirement keeps checked-out debt and rejects late queued publication" do
    domain = domain()
    generation = make_ref()
    writer = writer()
    first = writer_binding(domain, writer, Map.put(proof(), :generation, generation))
    {:ok, ticket} = HTTPWriterRegistry.prepare(first, "old")
    :ok = HTTPWriterRegistry.publish(ticket)
    checked = checkout(writer, first)
    queued_binding = writer_binding(domain, self(), Map.put(proof(), :generation, generation))
    {:ok, hidden} = HTTPWriterRegistry.prepare(queued_binding, "hidden")
    assert :ok = HTTPWriterRegistry.retire_generation(domain, generation)
    assert HTTPWriterRegistry.stats(domain).in_flight == 1
    assert {:error, _} = HTTPWriterRegistry.publish(hidden)
    assert {:error, :http_write_uncertain} = complete(writer, checked, :ok)
    eventually(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
    fresh = writer_binding(domain)
    assert {:ok, _} = HTTPWriterRegistry.prepare(fresh, "fresh")
  end

  test "root DOWN is honored before paused guardian processes its monitor" do
    root = owned_process()
    {:ok, domain} = HTTPWriterRegistry.start(root)
    writer = writer()
    binding = writer_binding(domain, writer)
    {:ok, ticket} = HTTPWriterRegistry.prepare(binding, "started")
    :ok = HTTPWriterRegistry.publish(ticket)
    checked = checkout(writer, binding)
    :sys.suspend(domain_pid(domain))
    Process.exit(root, :kill)
    eventually(fn -> not Process.alive?(root) end)
    assert {:error, :http_writer_closed} = HTTPWriterRegistry.prepare(binding, "after")
    assert {:error, :http_write_uncertain} = complete(writer, checked, :ok)
    assert HTTPWriterRegistry.stats(domain).in_flight == 1
    :sys.resume(domain_pid(domain))
    eventually(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
  end

  test "gateway owner DOWN makes a returned write uncertain before its monitor is handled" do
    domain = domain()
    owner = owned_process()
    writer = writer()
    {:ok, binding} = HTTPWriterRegistry.register(domain, writer, proof(), owner: owner)
    {:ok, ticket} = HTTPWriterRegistry.prepare(binding, "started")
    :ok = HTTPWriterRegistry.publish(ticket)
    checked = checkout(writer, binding)
    :sys.suspend(domain_pid(domain))
    Process.exit(owner, :kill)
    eventually(fn -> not Process.alive?(owner) end)
    assert {:error, :http_write_uncertain} = complete(writer, checked, :ok)
    assert HTTPWriterRegistry.stats(domain).in_flight == 1
    assert Process.alive?(writer)
    :sys.resume(domain_pid(domain))
    eventually(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
  end

  defp blocked_device do
    parent = self()

    pid =
      spawn(fn ->
        receive do
          {:io_request, from, tag, _request} ->
            send(parent, {:io_blocked, self()})

            receive do
              :release_io -> send(from, {:io_reply, tag, :ok})
            end
        end
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp domain(opts \\ []) do
    {:ok, domain} = HTTPWriterRegistry.start(self(), opts)
    domain
  end

  defp writer_binding(domain, writer \\ self(), proof \\ proof()) do
    {:ok, binding} = HTTPWriterRegistry.register(domain, writer, proof)
    binding
  end

  defp proof(deadline \\ Deadline.now() + 10_000),
    do: %{
      invocation: make_ref(),
      generation: make_ref(),
      scope: make_ref(),
      lease: nil,
      deadline: deadline
    }

  defp domain_pid(domain), do: HTTPWriterRegistry.guardian(domain)

  defp owned_process do
    pid =
      spawn(fn ->
        receive do
          :exit -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp writer do
    parent = self()
    pid = spawn(fn -> writer_loop(parent) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp writer_loop(parent, binding \\ nil) do
    receive do
      {:checkout, next_binding} ->
        send(parent, {:checked, self(), HTTPWriterRegistry.checkout(next_binding)})
        writer_loop(parent, next_binding)

      {:complete, ticket, result} ->
        send(parent, {:completed, self(), HTTPWriterRegistry.complete(ticket, result)})
        writer_loop(parent, binding)

      {:write_io, next_binding, device} ->
        {:ok, ticket, wire} = HTTPWriterRegistry.checkout(next_binding)
        send(parent, {:io_checked, self(), ticket})
        result = IO.binwrite(device, wire)
        send(parent, {:io_returned, self(), HTTPWriterRegistry.complete(ticket, result)})
        writer_loop(parent, next_binding)

      {:mcp_http_output_wake, domain, nonce} ->
        HTTPWriterRegistry.acknowledge_wake(domain, nonce)

        if binding && match?({:error, _}, HTTPWriterRegistry.proof(binding)),
          do: HTTPWriterRegistry.acknowledge_retirement(binding)

        writer_loop(parent, binding)

      _ ->
        writer_loop(parent, binding)
    end
  end

  defp checkout(writer, binding) do
    send(writer, {:checkout, binding})
    assert_receive {:checked, ^writer, {:ok, ticket, _wire}}, 500
    ticket
  end

  defp complete(writer, ticket, result) do
    send(writer, {:complete, ticket, result})
    assert_receive {:completed, ^writer, reply}, 500
    reply
  end

  defp eventually(predicate, attempts \\ 100)
  defp eventually(predicate, 0), do: assert(predicate.())

  defp eventually(predicate, attempts) do
    if predicate.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(predicate, attempts - 1)
        )
  end
end
