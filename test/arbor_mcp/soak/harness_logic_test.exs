defmodule Arbor.MCP.Soak.HarnessLogicTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Soak.{Evidence, Execution, Histogram, Policy, Provenance, Runner}

  test "turnover uses the lower legacy HTTP session budget" do
    refute Policy.turnover?(95, 1_000, 120_999, 96, 120_000)
    assert Policy.turnover?(96, 1_000, 1_001, 96, 120_000)
    assert Policy.turnover?(2, 1_000, 121_000, 96, 120_000)
    assert Policy.request_budget(:cowboy_owned, :legacy, 500) == 96
    assert Policy.request_budget(:bandit_host, :legacy, 80) == 80
    assert Policy.request_budget(:cowboy_owned, :modern, 500) == 500
    assert Policy.request_budget(:beam, :legacy, 500) == 500

    assert_raise Mix.Error, ~r/turnover-requests/, fn ->
      Runner.parse!(["--turnover-requests", "5001"])
    end
  end

  test "late versus post-warm-up baseline detects one scenario leak with bounded history" do
    series =
      Enum.reduce(1..10, Policy.new_series(), fn _, acc ->
        Policy.add_sample(acc, %{processes: 100})
      end)

    assert Policy.leak_violations(series) == []

    series = Enum.reduce(1..8, series, fn _, acc -> Policy.add_sample(acc, %{processes: 125}) end)

    assert [%{metric: :processes, baseline: 100.0, recent: 125.0}] =
             Policy.leak_violations(series)

    slow_leak =
      Enum.reduce(1..40, Policy.new_series(), fn n, acc ->
        Policy.add_sample(acc, %{processes: 100 + n})
      end)

    assert [%{metric: :processes}] = Policy.leak_violations(slow_leak)

    stable =
      Enum.reduce(1..100, Policy.new_series(), fn _, acc ->
        Policy.add_sample(acc, %{processes: 100})
      end)

    assert Policy.leak_violations(stable) == []
    assert length(stable.baseline) == 8
    assert length(stable.recent) == 16

    table_series =
      Enum.reduce(1..18, Policy.new_series(), fn n, acc ->
        Policy.add_sample(acc, %{ets_tables: if(n <= 10, do: 50, else: 61)})
      end)

    assert [%{metric: :ets_tables}] = Policy.leak_violations(table_series)

    missing =
      Enum.reduce(1..18, Policy.new_series(), fn _, acc ->
        Policy.add_sample(acc, %{file_descriptors: nil})
      end)

    assert Policy.leak_violations(missing) == []
  end

  test "ETS sampling ignores tables deleted after enumeration" do
    assert Policy.ets_words([:live, :deleted], fn
             :live, :memory -> 12
             :deleted, :memory -> :undefined
           end) == 12
  end

  test "fixed latency histogram bounds storage and conservatively rounds percentiles" do
    histogram = Enum.reduce([1, 2, 3, 4, 5, 50_000], Histogram.new(), &Histogram.add(&2, &1))
    assert histogram.count == 6
    assert map_size(histogram.buckets) <= 15
    assert Histogram.percentiles(histogram) == %{p50: 5, p95: 10_001, p99: 10_001}
    assert Histogram.merge([histogram, histogram]).count == 12
  end

  test "weighted chooser gives every operation a turn per scenario" do
    mix = Policy.default_mix()

    {picked, _counts} =
      Enum.map_reduce(1..length(mix), %{}, fn _, counts ->
        operation = Policy.next_operation(mix, counts)
        {operation, Map.update(counts, operation, 1, &(&1 + 1))}
      end)

    assert Enum.sort(picked) == mix |> Keyword.keys() |> Enum.sort()
    assert Policy.next_operation(mix, %{}) == :echo
    assert Policy.next_operation(mix, %{echo: 1}) == :list

    old = %{operation_counts: %{echo: 4, restart: 1}, requests: 80}
    replacement = %{operation_counts: %{}, requests: 2}

    assert Policy.carry_operation_counts(old, replacement) ==
             %{replacement | operation_counts: old.operation_counts}
  end

  test "disconnect telemetry fails unless one planned reconnect consumes it" do
    event = [:arbor_mcp, :client, :reconnect, :attempt]
    assert Policy.unexpected_client_event?(event, true)
    refute Policy.unexpected_client_event?(event, false)
    refute Policy.unexpected_client_event?(event, true, true)
    assert Policy.unexpected_client_event?([:arbor_mcp, :client, :reconnect, :success], true)
    assert Policy.reconnect_complete?(%{disconnected: 1, attempt: 1, success: 1})
    refute Policy.reconnect_complete?(%{disconnected: 1, attempt: 2, success: 1})
  end

  test "operation exceptions and exits become failures without losing scenario state" do
    scenario = %{client: self(), requests: 42}
    assert {:ok, ^scenario} = Execution.protected(fn -> :ok end, scenario)

    assert {{:error, {:exception, message}}, ^scenario} =
             Execution.protected(fn -> raise "operation exploded" end, scenario)

    assert message =~ "operation exploded"

    assert {{:error, {:exit, :gone}}, ^scenario} =
             Execution.protected(fn -> exit(:gone) end, scenario)
  end

  test "thresholds reject only values beyond the acceptance limits" do
    assert Policy.threshold_failures(999, 1, 5_000, 6, 300_000, 300_000) == []
    failures = Policy.threshold_failures(998, 2, 5_001, 5, 299_999, 300_000)

    assert Enum.map(failures, & &1.kind) == [
             :error_rate,
             :latency_p99_ms,
             :insufficient_turnovers,
             :incomplete_duration
           ]
  end

  test "provenance rejects dirty trees, changes, and environment overrides" do
    clean = snapshot()
    assert Provenance.violations(clean, clean) == []

    assert Enum.map(
             Provenance.violations(%{clean | git_status_porcelain: " M file"}, clean),
             & &1.kind
           ) == [:dirty_tree, :provenance_changed]

    assert Enum.map(Provenance.violations(clean, %{clean | git_head: "def"}), & &1.kind) == [
             :provenance_changed
           ]

    override = %{clean | overrides: %{"ARBOR_RPC_PATH" => true, "ARBOR_V2_DEPS" => false}}

    assert Enum.map(Provenance.violations(override, override), & &1.kind) == [
             :environment_override
           ]

    assert Enum.map(Provenance.violations(clean, override), & &1.kind) == [
             :provenance_changed,
             :environment_override
           ]
  end

  test "era and transport selection validates names and blocked coverage" do
    config = Runner.parse!(["--era", "modern", "--transports", "beam,cowboy_host"])
    assert config.eras == [:modern]
    assert config.transports == [:beam, :cowboy_host]

    for endpoint <- [:cowboy_owned, :cowboy_host, :bandit_owned, :bandit_host],
        operation <- [:progress, :cancellation, :notification] do
      assert Policy.known_blocked(endpoint, :legacy, operation) =~ ":stream_closed"
      assert Policy.known_blocked(endpoint, :modern, operation) == nil
    end

    assert Policy.known_blocked(:beam, :legacy, :progress) == nil
    assert Runner.parse!(["--exercise-known-blocked"]).exercise_known_blocked
    assert_raise Mix.Error, ~r/--era/, fn -> Runner.parse!(["--era", "future"]) end
    assert_raise Mix.Error, ~r/--transports/, fn -> Runner.parse!(["--transports", "bogus"]) end
  end

  test "output directory must be empty before evidence creation" do
    dir = Path.join(System.tmp_dir!(), "soak-output-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    assert :ok == Runner.ensure_output!(dir)
    File.write!(Path.join(dir, "events.jsonl"), "existing evidence")
    assert_raise Mix.Error, ~r/must be empty/, fn -> Runner.ensure_output!(dir) end
  end

  test "evidence needs full clean 48-hour coverage for qualification" do
    config = %{
      output: "/tmp/soak-evidence",
      duration_ms: 172_800_000,
      eras: [:legacy, :modern],
      transports: [:beam, :stdio, :cowboy_owned, :cowboy_host, :bandit_owned, :bandit_host],
      only: nil,
      mix: Policy.default_mix()
    }

    histogram = Enum.reduce([1, 2, 3, 4, 5], Histogram.new(), &Histogram.add(&2, &1))

    state = %{
      config: config,
      summary_path: "/tmp/soak-evidence/summary.json",
      started_at: ~U[2026-10-26 00:00:00Z],
      scenarios:
        Map.new(
          for transport <- config.transports, era <- config.eras, do: {"#{transport}/#{era}", %{}}
        ),
      results:
        Map.new(
          for transport <- config.transports,
              era <- config.eras,
              operation <- Policy.applicable_operations(transport, era, config.mix) do
            {"#{transport}/#{era}/#{operation}",
             %{ok: 5, error: 0, skipped: 0, blocked: 0, latency_hist: histogram}}
          end
        ),
      timed_counts:
        Map.new(
          for transport <- config.transports,
              era <- config.eras,
              operation <- Policy.applicable_operations(transport, era, config.mix),
              do: {"#{transport}/#{era}/#{operation}", 1}
        ),
      failures: [],
      operations: 5,
      turnovers: 6,
      samples: 30,
      sample_series: %{Policy.new_series() | count: 30},
      turnover_series: %{"stdio/legacy" => %{Policy.new_series() | count: 6}}
    }

    metadata = %{
      elapsed_ms: 172_800_000,
      finished_at: "2026-10-28T00:00:00Z",
      provenance_start: snapshot(),
      provenance_end: snapshot()
    }

    summary = Evidence.build(state, metadata)
    assert summary["passed"]
    assert summary["qualification_complete"]
    assert summary["source_commit"] == "abc123"

    assert summary["leak_sample_counts"] == %{
             periodic: 30,
             by_scenario: %{"stdio/legacy" => 6}
           }

    assert summary["overall_latency_ms"] == %{p50: 5, p95: 5, p99: 5}
    refute Evidence.build(state, %{metadata | elapsed_ms: 300_000})["qualification_complete"]

    short_config = %{state | config: %{config | duration_ms: 300_000}}
    refute Evidence.build(short_config, metadata)["qualification_complete"]

    missing = %{state | results: Map.delete(state.results, "stdio/legacy/restart")}
    refute Evidence.build(missing, metadata)["qualification_complete"]

    startup_only = %{state | timed_counts: Map.delete(state.timed_counts, "stdio/legacy/restart")}
    refute Evidence.build(startup_only, metadata)["qualification_complete"]

    refute Evidence.build(%{state | config: %{config | only: "beam/modern"}}, metadata)[
             "qualification_complete"
           ]

    dirty = %{snapshot() | git_status_porcelain: " M dev/file.ex"}
    failed = Evidence.build(state, %{metadata | provenance_start: dirty, provenance_end: dirty})
    refute failed["passed"]
    refute failed["qualification_complete"]
    assert Enum.any?(failed["failures"], &(&1.kind == :dirty_tree))
  end

  defp snapshot do
    %{
      git_head: "abc123",
      git_status_porcelain: "",
      mix_lock_sha256: "sha",
      overrides: %{"ARBOR_RPC_PATH" => false, "ARBOR_V2_DEPS" => false}
    }
  end
end
