defmodule Arbor.MCP.Soak.Policy do
  @moduledoc false

  @leak_thresholds %{
    memory_bytes: 32 * 1_048_576,
    processes: 20,
    ets_words: 100_000,
    ports: 10,
    file_descriptors: 20
  }

  @legacy_http_notification_operations [:progress, :cancellation, :notification]
  @legacy_http_reason "legacy Streamable HTTP server notifications return :stream_closed despite a connected GET SSE stream"

  def turnover?(requests, opened_ms, now_ms, request_limit, age_limit_ms) do
    requests >= request_limit or now_ms - opened_ms >= age_limit_ms
  end

  def leak_violations(samples) do
    samples = Enum.take(samples, -6)

    for {metric, threshold} <- @leak_thresholds,
        values = Enum.map(samples, &Map.get(&1, metric)),
        length(values) == 6,
        Enum.all?(values, &is_integer/1),
        increasing?(values),
        List.last(values) - hd(values) > threshold do
      %{metric: metric, values: values, threshold: threshold}
    end
  end

  def threshold_failures(successes, errors, p99_ms, turnover_samples, elapsed_ms, duration_ms) do
    error_rate = if successes + errors == 0, do: 1.0, else: errors / (successes + errors)

    []
    |> maybe_threshold(error_rate > 0.001, :error_rate, error_rate)
    |> maybe_threshold(p99_ms > 5_000, :latency_p99_ms, p99_ms)
    |> maybe_threshold(turnover_samples < 6, :insufficient_turnovers, turnover_samples)
    |> maybe_threshold(elapsed_ms < duration_ms, :incomplete_duration, elapsed_ms)
  end

  def known_blocked(endpoint, :legacy, operation)
      when endpoint in [:cowboy_owned, :cowboy_host, :bandit_owned, :bandit_host] and
             operation in @legacy_http_notification_operations,
      do: @legacy_http_reason

  def known_blocked(_endpoint, _era, _operation), do: nil

  defp increasing?(values) do
    values
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> b > a end)
  end

  defp maybe_threshold(failures, true, kind, value),
    do: failures ++ [%{kind: kind, value: value}]

  defp maybe_threshold(failures, false, _kind, _value), do: failures
end
