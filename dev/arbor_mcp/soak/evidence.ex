defmodule Arbor.MCP.Soak.Evidence do
  @moduledoc false

  alias Arbor.MCP.Soak.{Histogram, Policy, Provenance}

  def build(state, metadata) do
    results =
      for {key, entry} <- state.results, into: %{} do
        {key,
         Map.put(
           Map.drop(entry, [:latency_hist]),
           :latency_ms,
           Histogram.percentiles(entry.latency_hist)
         )}
      end

    successes = Enum.reduce(state.results, 0, fn {_key, entry}, total -> total + entry.ok end)
    errors = Enum.reduce(state.results, 0, fn {_key, entry}, total -> total + entry.error end)
    skipped = Enum.reduce(state.results, 0, fn {_key, entry}, total -> total + entry.skipped end)

    blocked =
      Enum.reduce(state.results, 0, fn {_key, entry}, total ->
        total + Map.get(entry, :blocked, 0)
      end)

    latency_histogram =
      state.results |> Map.values() |> Enum.map(& &1.latency_hist) |> Histogram.merge()

    overall = Histogram.percentiles(latency_histogram)

    known_blocked =
      for {key, entry} <- state.results,
          Map.get(entry, :blocked, 0) > 0 do
        [endpoint, era, operation] = String.split(key, "/")

        %{
          scenario: "#{endpoint}/#{era}",
          operation: operation,
          attempts: entry.blocked,
          reason: entry.blocked_reason
        }
      end
      |> Enum.sort_by(&{&1.scenario, &1.operation})

    threshold_failures =
      Policy.threshold_failures(
        successes,
        errors,
        overall.p99,
        state.turnovers,
        metadata.elapsed_ms,
        state.config.duration_ms
      )

    provenance_failures =
      Provenance.violations(metadata.provenance_start, metadata.provenance_end)

    failures = Enum.reverse(state.failures) ++ threshold_failures ++ provenance_failures
    passed = failures == [] and known_blocked == []
    qualification_complete = qualification_complete?(passed, state, metadata.elapsed_ms)

    %{
      "passed" => passed,
      "qualification_complete" => qualification_complete,
      "summary_path" => state.summary_path,
      "events_path" => Path.join(state.config.output, "events.jsonl"),
      "started_at" => DateTime.to_iso8601(state.started_at),
      "finished_at" => metadata.finished_at,
      "elapsed_ms" => metadata.elapsed_ms,
      "source_commit" => metadata.provenance_start.git_head,
      "mix_lock_sha256" => metadata.provenance_start.mix_lock_sha256,
      "provenance" => %{start: metadata.provenance_start, finish: metadata.provenance_end},
      "config" => state.config,
      "scenarios" => Map.keys(state.scenarios) |> Enum.sort(),
      "operations" => state.operations,
      "timed_counts" => state.timed_counts,
      "result_totals" => %{ok: successes, error: errors, skipped: skipped, blocked: blocked},
      "turnovers" => state.turnovers,
      "samples" => state.samples,
      "leak_sample_counts" => %{
        periodic: state.sample_series.count,
        by_scenario:
          Map.new(state.turnover_series, fn {scenario, series} -> {scenario, series.count} end)
      },
      "overall_latency_ms" => overall,
      "results" => results,
      "known_blocked" => known_blocked,
      "failures" => failures
    }
  end

  defp qualification_complete?(passed, state, elapsed_ms) do
    config = state.config

    passed and config.duration_ms >= 172_800_000 and elapsed_ms >= 172_800_000 and
      Enum.sort(config.eras) == [:legacy, :modern] and
      Enum.sort(config.transports) ==
        Enum.sort([:beam, :stdio, :cowboy_owned, :cowboy_host, :bandit_owned, :bandit_host]) and
      config.only == nil and config.mix == Policy.default_mix() and
      full_scenario_coverage?(state)
  end

  defp full_scenario_coverage?(state) do
    config = state.config
    expected = for endpoint <- config.transports, era <- config.eras, do: "#{endpoint}/#{era}"

    Enum.sort(Map.keys(state.scenarios)) == Enum.sort(expected) and
      Enum.all?(state.scenarios, fn {scenario, _value} ->
        [endpoint, era] = String.split(scenario, "/")

        Enum.all?(
          Policy.applicable_operations(
            String.to_existing_atom(endpoint),
            String.to_existing_atom(era),
            config.mix
          ),
          fn operation ->
            key = "#{scenario}/#{operation}"

            Map.get(state.results, key, %{ok: 0}).ok > 0 and
              Map.get(state.timed_counts, key, 0) > 0
          end
        )
      end)
  end
end
