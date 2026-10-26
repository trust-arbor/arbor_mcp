defmodule Arbor.MCP.Soak.Evidence do
  @moduledoc false

  alias Arbor.MCP.Soak.Policy

  def build(state, metadata) do
    results =
      for {key, entry} <- state.results, into: %{} do
        {key, Map.put(Map.drop(entry, [:latency_ms]), :latency_ms, percentiles(entry.latency_ms))}
      end

    successes = Enum.reduce(state.results, 0, fn {_key, entry}, total -> total + entry.ok end)
    errors = Enum.reduce(state.results, 0, fn {_key, entry}, total -> total + entry.error end)
    skipped = Enum.reduce(state.results, 0, fn {_key, entry}, total -> total + entry.skipped end)

    blocked =
      Enum.reduce(state.results, 0, fn {_key, entry}, total ->
        total + Map.get(entry, :blocked, 0)
      end)

    latencies = state.results |> Map.values() |> Enum.flat_map(& &1.latency_ms)
    overall = percentiles(latencies)

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
        length(state.turnover_samples),
        metadata.elapsed_ms,
        state.config.duration_ms
      )

    failures = Enum.reverse(state.failures) ++ threshold_failures

    %{
      "passed" => failures == [] and known_blocked == [],
      "qualification_complete" => known_blocked == [],
      "summary_path" => state.summary_path,
      "events_path" => Path.join(state.config.output, "events.jsonl"),
      "started_at" => DateTime.to_iso8601(state.started_at),
      "finished_at" => metadata.finished_at,
      "elapsed_ms" => metadata.elapsed_ms,
      "source_commit" => metadata.source_commit,
      "mix_lock_sha256" => metadata.mix_lock_sha256,
      "elixir" => metadata.elixir,
      "otp" => metadata.otp,
      "platform" => metadata.platform,
      "os" => metadata.os,
      "config" => state.config,
      "scenarios" => Map.keys(state.scenarios) |> Enum.sort(),
      "operations" => state.operations,
      "result_totals" => %{ok: successes, error: errors, skipped: skipped, blocked: blocked},
      "turnovers" => state.turnovers,
      "samples" => state.samples,
      "overall_latency_ms" => overall,
      "results" => results,
      "known_blocked" => known_blocked,
      "failures" => failures
    }
  end

  def percentiles([]), do: %{p50: 0, p95: 0, p99: 0}

  def percentiles(values) do
    sorted = Enum.sort(values)
    n = length(sorted)

    %{
      p50: Enum.at(sorted, ceil(n * 0.5) - 1),
      p95: Enum.at(sorted, ceil(n * 0.95) - 1),
      p99: Enum.at(sorted, ceil(n * 0.99) - 1)
    }
  end
end
