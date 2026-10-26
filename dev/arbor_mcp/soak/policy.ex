defmodule Arbor.MCP.Soak.Policy do
  @moduledoc false

  @leak_thresholds %{
    memory_bytes: 32 * 1_048_576,
    processes: 20,
    ets_tables: 10,
    ets_words: 100_000,
    ports: 10,
    file_descriptors: 20
  }

  @legacy_http_notification_operations [:progress, :cancellation, :notification]
  @legacy_http_reason "legacy Streamable HTTP server notifications return :stream_closed despite a connected GET SSE stream"
  @default_mix [
    echo: 40,
    list: 12,
    resource: 8,
    template: 8,
    prompt: 8,
    progress: 8,
    cancellation: 4,
    notification: 4,
    mrtr: 4,
    ping: 4,
    restart: 4
  ]
  @baseline_size 8
  @recent_size 16

  def turnover?(requests, opened_ms, now_ms, request_limit, age_limit_ms) do
    requests >= request_limit or now_ms - opened_ms >= age_limit_ms
  end

  def default_mix, do: @default_mix

  def applicable_operations(endpoint, era, mix) do
    mix
    |> Keyword.keys()
    |> Enum.reject(fn operation ->
      (era == :legacy and operation == :mrtr) or
        (endpoint != :stdio and operation == :restart)
    end)
  end

  def new_series, do: %{count: 0, baseline: [], recent: []}

  def add_sample(series, sample) do
    count = series.count + 1
    baseline = if count in 3..10, do: [sample | series.baseline], else: series.baseline

    %{
      count: count,
      baseline: baseline,
      recent: Enum.take([sample | series.recent], @recent_size)
    }
  end

  def leak_violations(%{count: count} = series) when count >= 18 do
    recent = Enum.take(series.recent, @baseline_size)

    for {metric, threshold} <- @leak_thresholds,
        baseline_values = Enum.map(series.baseline, &Map.get(&1, metric)),
        recent_values = Enum.map(recent, &Map.get(&1, metric)),
        length(baseline_values) == @baseline_size,
        length(recent_values) == @baseline_size,
        Enum.all?(baseline_values ++ recent_values, &is_integer/1),
        baseline = median(baseline_values),
        current = median(recent_values),
        current - baseline > threshold do
      %{metric: metric, baseline: baseline, recent: current, threshold: threshold, samples: count}
    end
  end

  def leak_violations(_series), do: []

  def request_budget(endpoint, :legacy, requested)
      when endpoint in [:cowboy_owned, :cowboy_host, :bandit_owned, :bandit_host],
      do: min(requested, 96)

  def request_budget(_endpoint, _era, requested), do: requested

  def ets_words(tables, info_fun \\ &:ets.info/2) do
    Enum.reduce(tables, 0, fn table, total ->
      case info_fun.(table, :memory) do
        words when is_integer(words) -> total + words
        _deleted -> total
      end
    end)
  end

  def next_operation(mix, counts) do
    mix
    |> Enum.with_index()
    |> Enum.min_by(fn {{operation, weight}, index} ->
      {Map.get(counts, operation, 0) / weight, index}
    end)
    |> elem(0)
    |> elem(0)
  end

  def carry_operation_counts(previous, replacement) do
    %{replacement | operation_counts: previous.operation_counts}
  end

  def reconnect_complete?(%{disconnected: 1, attempt: 1, success: 1}), do: true
  def reconnect_complete?(_counts), do: false

  def unexpected_client_event?(event, owned_client?, planned_failure? \\ false) do
    owned_client? and not planned_failure? and
      event in [
        [:arbor_mcp, :client, :disconnected],
        [:arbor_mcp, :client, :reconnect, :attempt],
        [:arbor_mcp, :client, :reconnect, :success],
        [:arbor_mcp, :client, :reconnect, :error],
        [:arbor_mcp, :client, :reconnect, :timeout]
      ]
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

  defp median(values) do
    sorted = Enum.sort(values)
    half = div(length(sorted), 2)
    (Enum.at(sorted, half - 1) + Enum.at(sorted, half)) / 2
  end

  defp maybe_threshold(failures, true, kind, value),
    do: failures ++ [%{kind: kind, value: value}]

  defp maybe_threshold(failures, false, _kind, _value), do: failures
end
