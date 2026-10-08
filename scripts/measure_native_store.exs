# Run in a fresh VM with `MIX_ENV=test mix run --no-start scripts/measure_native_store.exs`.
# Qualification runners can load an explicit compiled tree without starting Mix.
if build = System.get_env("ARBOR_V2_BUILD") do
  Path.wildcard(Path.join(build, "test/lib/*/ebin")) |> Enum.each(&Code.append_path/1)
end

Application.ensure_all_started(:crypto)
Application.ensure_all_started(:telemetry)
Application.ensure_all_started(:logger)
Logger.configure(level: :error)

defmodule NativeStoreMeasurement do
  alias Arbor.MCP.Tasks
  alias Arbor.MCP.Tasks.Store.ETS, as: TasksStore
  alias Arbor.MCP.Server.ReplayCache.ETS, as: ReplayStore
  alias Arbor.MCP.Server.Runtime.ServiceOperation

  def run do
    # Limits are production defaults; the optional Tasks clock only advances
    # TTL after the full pressure wave. Operation cutoffs use actual time.
    tasks_clock = :atomics.new(1, signed: false)
    :atomics.put(tasks_clock, 1, 1_000)
    task_options = [name: nil, now_fun: fn -> :atomics.get(tasks_clock, 1) end]
    {:ok, tasks_count} = TasksStore.start_link(task_options)
    {:ok, tasks_bytes} = TasksStore.start_link(task_options)
    {:ok, replay_count} = ReplayStore.start_link(name: nil)
    {:ok, replay_bytes} = ReplayStore.start_link(name: nil)
    stores = [tasks_count, tasks_bytes, replay_count, replay_bytes]
    owner = %{principal_id: "measurement", tenant_id: "local"}
    expires = System.system_time(:second) + 60
    rows = []

    rows =
      wave(rows, :tasks_count, tasks_count, 10_000, fn n ->
        Tasks.create("measure", %{"sequence" => n},
          store: TasksStore,
          server: tasks_count,
          owner: owner,
          notify: false
        )
      end)

    rows =
      wave(rows, :tasks_bytes, tasks_bytes, 256, fn n ->
        body = String.pad_leading(Integer.to_string(n), 32_768, "x")

        Tasks.create("measure", %{"body" => body},
          store: TasksStore,
          server: tasks_bytes,
          owner: owner,
          notify: false
        )
      end)

    rows =
      wave(rows, :replay_count, replay_count, 10_000, fn n ->
        ReplayStore.consume("id-#{n}", expires, server: replay_count)
      end)

    rows =
      wave(rows, :replay_bytes, replay_bytes, 2_000, fn n ->
        id = String.pad_leading(Integer.to_string(n), 4_000, "x")
        ReplayStore.consume(id, expires, server: replay_bytes)
      end)

    :atomics.put(tasks_clock, 1, 4_000_000)
    wait(fn -> Enum.all?(stores, &(snapshot(&1).entries == 0)) end, 75_000)
    idle = Enum.map(stores, &sample(:idle, &1))
    Enum.each(stores, &GenServer.stop/1)
    true = Enum.all?(stores, &(not Process.alive?(&1)))
    :erlang.garbage_collect()

    %{
      waves: rows,
      idle: idle,
      after_stop: vm(),
      scope:
        "One fresh VM; production count/byte defaults; Tasks TTL uses supplied clock, Replay expiry uses actual wall time. Supporting steady samples afterGC, not transient peaks or a VM/RSS guarantee."
    }
  end

  defp wave(rows, name, pid, unit, action) do
    baseline = sample(:baseline, pid)
    {first, next} = load(1, 2 * unit, action)
    two = sample(:pressure_2x, pid)
    {second, _next} = load(next, 8 * unit, action)
    eight = sample(:pressure_8x, pid)
    true = two.entries <= 10_000 and eight.entries <= 10_000
    true = two.retained_bytes <= 8_000_000 and eight.retained_bytes <= 8_000_000
    true = first.accepted > 0 and second.accepted == 0
    true = first.accepted == two.entries and two.entries == eight.entries
    true = two.retained_bytes == eight.retained_bytes
    true = two.expiry_index == two.entries and eight.expiry_index == eight.entries
    true = two.operations.pending_operations == 0 and eight.operations.pending_operations == 0

    true =
      two.operations.pending_operation_bytes == 0 and
        eight.operations.pending_operation_bytes == 0

    expected_error =
      if name in [:tasks_count, :tasks_bytes], do: ":store_full", else: ":replay_cache_full"

    true = Map.keys(first.rejected) == [expected_error]
    true = Map.keys(second.rejected) == [expected_error]
    if name in [:tasks_count, :replay_count], do: true = two.entries == 10_000
    if name in [:tasks_bytes, :replay_bytes], do: true = two.retained_bytes > 7_900_000

    IO.puts(
      "#{name}:2x=#{two.entries}/#{two.retained_bytes} 8x=#{eight.entries}/#{eight.retained_bytes}"
    )

    rows ++
      [
        %{
          store: name,
          baseline: baseline,
          accepted_rejected_2x: first,
          pressure_2x: two,
          accepted_rejected_8x: second,
          pressure_8x: eight
        }
      ]
  end

  defp load(start, count, action) do
    result =
      Enum.reduce(start..(start + count - 1), %{accepted: 0, rejected: %{}}, fn n, acc ->
        case action.(n) do
          :ok ->
            %{acc | accepted: acc.accepted + 1}

          {:ok, _} ->
            %{acc | accepted: acc.accepted + 1}

          {:error, reason} ->
            %{acc | rejected: Map.update(acc.rejected, inspect(reason), 1, &(&1 + 1))}
        end
      end)

    {result, start + count}
  end

  defp snapshot(pid) do
    state = :sys.get_state(pid)

    %{
      entries: map_size(Map.get(state, :entries)),
      retained_bytes: state.retained_bytes,
      expiry_index: :gb_sets.size(state.expiry_queue),
      operations: ServiceOperation.stats(state.address),
      owned_ets_bytes:
        Enum.reduce(:ets.all(), 0, fn table, bytes ->
          if :ets.info(table, :owner) == pid,
            do: bytes + :ets.info(table, :memory) * :erlang.system_info(:wordsize),
            else: bytes
        end)
    }
  end

  defp sample(stage, pid) do
    counts = snapshot(pid)
    :erlang.garbage_collect(pid)
    :erlang.garbage_collect()
    {:memory, memory} = Process.info(pid, :memory)
    {:message_queue_len, mailbox} = Process.info(pid, :message_queue_len)
    {:binary, references} = Process.info(pid, :binary)

    Map.merge(counts, %{
      stage: stage,
      owner_memory_bytes: memory,
      owner_mailbox_count: mailbox,
      owner_binary_reference_bytes:
        Enum.reduce(references, 0, fn {_, size, _}, sum -> sum + size end),
      vm: vm()
    })
  end

  defp vm do
    {rss, 0} = System.cmd("/bin/ps", ["-o", "rss=", "-p", System.pid()])

    %{
      vm_total_bytes: :erlang.memory(:total),
      vm_binary_bytes: :erlang.memory(:binary),
      vm_ets_bytes: :erlang.memory(:ets),
      process_count: :erlang.system_info(:process_count),
      os_rss_bytes: String.to_integer(String.trim(rss)) * 1_024
    }
  end

  defp wait(fun, ms), do: wait_until(fun, System.monotonic_time(:millisecond) + ms)

  defp wait_until(fun, cutoff) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= cutoff ->
        raise "default retention did not expire"

      true ->
        Process.sleep(100)
        wait_until(fun, cutoff)
    end
  end
end

report = NativeStoreMeasurement.run()

report_path =
  System.get_env("ARBOR_STORE_MEASUREMENT_REPORT", "tmp/native-store-default-measurement.json")

File.mkdir_p!(Path.dirname(report_path))
File.write!(report_path, Jason.encode!(report, pretty: true))
IO.puts("Report: #{report_path}")
