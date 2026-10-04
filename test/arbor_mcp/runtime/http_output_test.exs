defmodule Arbor.MCP.Server.Runtime.HTTPOutputTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.Runtime.{
    Deadline,
    HTTPOutput,
    HTTPWriterRegistry,
    OutputController,
    OutputLedger,
    OutputTicket
  }

  test "both effects remain hidden after producer death and preserve exact SSE bytes" do
    {ledger, domain, binding, context} = pair(format: :sse)
    parent = self()

    {producer, monitor} =
      spawn_monitor(fn ->
        result =
          OutputController.prepare(context, %{"jsonrpc" => "2.0", "id" => 1, "result" => "é"})

        send(parent, {:prepared, result})
      end)

    assert_receive {:prepared, {:ok, ticket}}
    assert_receive {:DOWN, ^monitor, :process, ^producer, :normal}
    assert HTTPOutput.valid?(ticket)
    assert :empty = OutputLedger.checkout(ledger, context.scope)
    assert :empty = HTTPWriterRegistry.checkout(binding)
    assert %{frames: 1, held: 1, in_flight: 0} = HTTPWriterRegistry.stats(domain)

    assert :ok = OutputLedger.publish(ticket)
    assert :ok = HTTPOutput.publish(ticket)
    assert {:ok, checked, _term, json} = OutputLedger.checkout(ledger, context.scope)
    assert OutputTicket.same?(ticket, checked)
    assert {:ok, io_ticket, wire} = HTTPWriterRegistry.checkout(binding)
    assert wire == "data: " <> json <> "\r\n\r\n"
    assert {:error, :http_write_in_flight} = HTTPWriterRegistry.release(io_ticket)
    assert :ok = HTTPWriterRegistry.complete(io_ticket, :ok)
    assert :ok = OutputLedger.ack(ticket)
  end

  test "IO admission failure rolls back the primary claim before a proposal returns" do
    {ledger, domain, _binding, context} = pair(max_io_bytes: 32)
    assert {:error, :http_output_busy} = OutputController.prepare(context, %{"id" => 1})
    assert %{frames: 0, bytes: 0} = HTTPWriterRegistry.stats(domain)
    assert %{frames: 0, bytes: 0} = OutputLedger.stats(ledger)
  end

  test "frame admission includes HTTP framing and preserves native UTF8 byte caps" do
    {_ledger, domain, _binding, context} = pair(format: :sse, max_io_frame_bytes: 5)
    assert {:error, :http_frame_too_large} = OutputController.prepare(context, "é")
    assert %{frames: 0, bytes: 0} = HTTPWriterRegistry.stats(domain)
  end

  test "releasing a canceled proposal conserves both capacities and permits readmission" do
    {ledger, domain, _binding, context} = pair(max_io_frames: 1)
    assert {:ok, first} = OutputController.prepare(context, %{"id" => 1})
    assert {:error, :http_output_busy} = OutputController.prepare(context, %{"id" => 2})
    assert %{frames: 1} = OutputLedger.stats(ledger)
    assert :ok = HTTPOutput.release_all(first)
    assert :ok = HTTPOutput.release_all(first)
    await(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
    assert {:ok, second} = OutputController.prepare(context, %{"id" => 2})
    assert :ok = HTTPOutput.release_all(second)
  end

  test "dead IO owner invalidates a prepared effect while primary ownership stays live" do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    {_ledger, _domain, _binding, context} = pair(io_owner: owner)
    assert {:ok, ticket} = OutputController.prepare(context, %{"id" => 1})
    assert HTTPOutput.valid?(ticket)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    refute HTTPOutput.valid?(ticket)
    assert :ok = HTTPOutput.release_all(ticket)
  end

  test "unrelated readers cannot fetch prepared wire or manufacture output credit" do
    {ledger, _domain, _binding, context} = pair()
    assert {:ok, ticket} = OutputController.prepare(context, %{"id" => 1})
    parent = self()

    spawn(fn ->
      send(parent, {:wire, OutputLedger.prepared_wire(ticket)})
    end)

    assert_receive {:wire, {:error, :invalid_output_owner}}
    assert :empty = OutputLedger.checkout(ledger, context.scope)
    assert :ok = HTTPOutput.release_all(ticket)
  end

  test "concurrent producers cannot exceed combined IO claims and all denied primaries reclaim" do
    {ledger, domain, _binding, context} = pair(max_io_frames: 3)
    parent = self()

    workers =
      for id <- 1..24 do
        spawn(fn ->
          receive do
            :go -> send(parent, {:candidate, OutputController.prepare(context, %{"id" => id})})
          end
        end)
      end

    Enum.each(workers, &send(&1, :go))

    results =
      for _ <- workers do
        receive do
          {:candidate, result} -> result
        after
          1_000 -> flunk("producer did not finish within its original cutoff")
        end
      end

    accepted = for {:ok, ticket} <- results, do: ticket
    assert length(accepted) <= 3
    assert %{frames: frames} = HTTPWriterRegistry.stats(domain)
    assert frames <= 3
    Enum.each(accepted, &HTTPOutput.release_all/1)
    await(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
    await(fn -> OutputLedger.stats(ledger).frames == 0 end)
  end

  test "every prospective batch frame is charged before one atomic aggregate becomes visible" do
    {ledger, domain, binding, context} = pair(max_io_frame_bytes: 7)
    context = %{context | group: true}
    assert {:ok, first} = OutputController.prepare(context, %{})
    assert :ok = HTTPOutput.mark_committed(first)
    assert :ok = OutputLedger.hold(first)
    assert {:error, :http_group_incomplete} = HTTPOutput.publish(first)
    assert :empty = HTTPWriterRegistry.checkout(binding)
    assert {:ok, second} = OutputController.prepare(context, %{})
    assert {:error, :http_group_incomplete} = HTTPWriterRegistry.finish_group(binding, first)
    assert :ok = HTTPOutput.mark_committed(second)
    assert :ok = OutputLedger.hold(second)
    before = HTTPWriterRegistry.stats(domain)
    assert before.frames == 2
    assert {:ok, primary} = OutputLedger.finish_group(ledger, context.scope)
    assert {:ok, final} = HTTPOutput.finish_group(binding, primary)
    assert %{frames: 1, bytes: bytes, held: 1} = HTTPWriterRegistry.stats(domain)
    assert bytes == before.bytes
    assert :ok = HTTPOutput.publish(final)
    assert {:ok, effect, "[{},{}]"} = HTTPWriterRegistry.checkout(binding)
    assert :ok = HTTPWriterRegistry.complete(effect, :ok)

    assert {:ok, checked, [%{}, %{}], "[{},{}]"} =
             OutputLedger.checkout(ledger, context.scope)

    assert OutputTicket.same?(final, checked)
    assert :ok = OutputLedger.ack(final)
  end

  test "aggregate frame overflow rejects the later proposal without publishing an earlier member" do
    {ledger, domain, binding, context} = pair(max_io_frame_bytes: 6)
    context = %{context | group: true}
    assert {:ok, first} = OutputController.prepare(context, %{})
    assert :ok = HTTPOutput.mark_committed(first)
    assert :ok = OutputLedger.hold(first)
    assert {:error, :http_frame_too_large} = OutputController.prepare(context, %{})
    assert %{frames: 1} = HTTPWriterRegistry.stats(domain)
    assert %{frames: 1} = OutputLedger.stats(ledger)
    assert :empty = HTTPWriterRegistry.checkout(binding)
    assert :ok = HTTPOutput.release_all(first)
  end

  defp pair(opts \\ []) do
    root = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(root), do: send(root, :stop) end)
    {:ok, pid} = OutputLedger.start_link(owner: self(), call_timeout_ms: 50)
    {:ok, ledger} = OutputLedger.ref(pid)
    scope = make_ref()
    deadline = Deadline.now() + 1_000
    :ok = OutputLedger.open_scope(ledger, scope, deadline)
    :ok = OutputLedger.subscribe(ledger, scope, self())

    registry_options = Keyword.drop(opts, [:format, :io_owner])
    {:ok, domain} = HTTPWriterRegistry.start(root, registry_options)

    {:ok, binding} =
      HTTPWriterRegistry.register(domain, self(), %{
        invocation: make_ref(),
        generation: make_ref(),
        scope: scope,
        lease: nil,
        deadline: deadline
      })

    context = %{
      ledger: ledger,
      scope: scope,
      owner: self(),
      group: false,
      codec: :protocol,
      deadline: deadline,
      http: %{
        binding: binding,
        format: Keyword.get(opts, :format, :json),
        owner: Keyword.get(opts, :io_owner, self())
      }
    }

    {ledger, domain, binding, context}
  end

  defp await(predicate, tries \\ 100)
  defp await(predicate, 0), do: assert(predicate.())

  defp await(predicate, tries) do
    if predicate.() do
      :ok
    else
      Process.sleep(2)
      await(predicate, tries - 1)
    end
  end
end
