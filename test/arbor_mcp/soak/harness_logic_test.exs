defmodule Arbor.MCP.Soak.HarnessLogicTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Soak.{Evidence, Policy, Runner}

  test "turnover happens at either configured limit and leaves a margin below request ID capacity" do
    refute Policy.turnover?(499, 1_000, 120_999, 500, 120_000)
    assert Policy.turnover?(500, 1_000, 1_001, 500, 120_000)
    assert Policy.turnover?(2, 1_000, 121_000, 500, 120_000)

    assert_raise Mix.Error, ~r/turnover-requests/, fn ->
      Runner.parse!(["--turnover-requests", "5001"])
    end
  end

  test "leak detector needs six consecutive increasing turnover samples above threshold" do
    samples = for n <- 0..5, do: %{processes: 100 + n * 5}

    assert [%{metric: :processes, threshold: 20, values: [100, 105, 110, 115, 120, 125]}] =
             Policy.leak_violations(samples)

    assert Policy.leak_violations(Enum.take(samples, 5)) == []
    assert Policy.leak_violations(List.replace_at(samples, 3, %{processes: 110})) == []
    assert Policy.leak_violations(List.replace_at(samples, 3, %{processes: nil})) == []
    assert Policy.leak_violations(for(n <- 0..5, do: %{processes: 100 + n * 4})) == []
  end

  test "thresholds flag violations beyond, but not at, the acceptance limits" do
    assert Policy.threshold_failures(999, 1, 5_000, 6, 300_000, 300_000) == []

    failures = Policy.threshold_failures(998, 2, 5_001, 5, 299_999, 300_000)

    assert Enum.map(failures, & &1.kind) == [
             :error_rate,
             :latency_p99_ms,
             :insufficient_turnovers,
             :incomplete_duration
           ]
  end

  test "era and transport selection is explicit and validates names" do
    config = Runner.parse!(["--era", "modern", "--transports", "beam,cowboy_host"])
    assert config.eras == [:modern]
    assert config.transports == [:beam, :cowboy_host]
    refute config.exercise_known_blocked

    assert Runner.parse!(["--era", "both", "--transports", "stdio"]).eras == [
             :legacy,
             :modern
           ]

    assert_raise Mix.Error, ~r/--era/, fn -> Runner.parse!(["--era", "future"]) end
    assert_raise Mix.Error, ~r/--transports/, fn -> Runner.parse!(["--transports", "bogus"]) end
  end

  test "legacy HTTP notification coverage is blocked and can be explicitly exercised" do
    for endpoint <- [:cowboy_owned, :cowboy_host, :bandit_owned, :bandit_host],
        operation <- [:progress, :cancellation, :notification] do
      assert Policy.known_blocked(endpoint, :legacy, operation) =~ ":stream_closed"
      assert Policy.known_blocked(endpoint, :modern, operation) == nil
    end

    assert Policy.known_blocked(:beam, :legacy, :progress) == nil
    assert Policy.known_blocked(:cowboy_host, :legacy, :echo) == nil
    assert Runner.parse!(["--exercise-known-blocked"]).exercise_known_blocked
  end

  test "evidence summary reports blocked cases, provenance, percentiles, and qualification status" do
    state = %{
      config: %{output: "/tmp/soak-evidence", duration_ms: 300_000},
      summary_path: "/tmp/soak-evidence/summary.json",
      started_at: ~U[2026-10-26 00:00:00Z],
      scenarios: %{"cowboy_host/legacy" => %{}, "beam/modern" => %{}},
      results: %{
        "beam/modern/echo" => %{
          ok: 5,
          error: 0,
          skipped: 0,
          blocked: 0,
          latency_ms: [1, 2, 3, 4, 5]
        },
        "cowboy_host/legacy/progress" => %{
          ok: 0,
          error: 0,
          skipped: 0,
          blocked: 2,
          blocked_reason: Policy.known_blocked(:cowboy_host, :legacy, :progress),
          latency_ms: []
        }
      },
      failures: [],
      turnover_samples: List.duplicate(%{}, 6),
      operations: 7,
      turnovers: 6,
      samples: 30
    }

    metadata = %{
      elapsed_ms: 300_000,
      finished_at: "2026-10-26T00:05:00Z",
      source_commit: "abc123",
      mix_lock_sha256: String.duplicate("a", 64),
      elixir: "1.19.5",
      otp: "28",
      platform: "test-platform",
      os: ":unix"
    }

    summary = Evidence.build(state, metadata)
    refute summary["passed"]
    refute summary["qualification_complete"]
    assert summary["failures"] == []

    assert summary["known_blocked"] == [
             %{
               scenario: "cowboy_host/legacy",
               operation: "progress",
               attempts: 2,
               reason: Policy.known_blocked(:cowboy_host, :legacy, :progress)
             }
           ]

    assert summary["source_commit"] == "abc123"
    assert summary["mix_lock_sha256"] == String.duplicate("a", 64)
    assert summary["scenarios"] == ["beam/modern", "cowboy_host/legacy"]
    assert summary["result_totals"] == %{ok: 5, error: 0, skipped: 0, blocked: 2}
    assert summary["overall_latency_ms"] == %{p50: 3, p95: 5, p99: 5}
    assert summary["results"]["cowboy_host/legacy/progress"].blocked == 2

    clean = %{
      state
      | scenarios: %{"beam/modern" => %{}},
        results: Map.take(state.results, ["beam/modern/echo"])
    }

    assert Evidence.build(clean, metadata)["passed"]
  end
end
