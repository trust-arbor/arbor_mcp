defmodule Arbor.MCP.Soak.Histogram do
  @moduledoc false

  # Bucket ceilings bound the evidence size regardless of run duration.
  @ceilings [0, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 10_001]

  def new, do: %{count: 0, buckets: %{}}

  def add(histogram, milliseconds) when is_integer(milliseconds) and milliseconds >= 0 do
    ceiling = Enum.find(@ceilings, &(milliseconds <= &1)) || 10_001

    %{
      count: histogram.count + 1,
      buckets: Map.update(histogram.buckets, ceiling, 1, &(&1 + 1))
    }
  end

  def merge(histograms) do
    Enum.reduce(histograms, new(), fn histogram, acc ->
      %{
        count: acc.count + histogram.count,
        buckets:
          Map.merge(acc.buckets, histogram.buckets, fn _ceiling, left, right -> left + right end)
      }
    end)
  end

  def percentiles(%{count: 0}), do: %{p50: 0, p95: 0, p99: 0}

  def percentiles(histogram) do
    %{
      p50: percentile(histogram, 0.50),
      p95: percentile(histogram, 0.95),
      p99: percentile(histogram, 0.99)
    }
  end

  defp percentile(histogram, fraction) do
    target = ceil(histogram.count * fraction)

    {ceiling, _count} =
      histogram.buckets
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while(0, fn {ceiling, count}, seen ->
        total = seen + count
        if total >= target, do: {:halt, {ceiling, total}}, else: {:cont, total}
      end)

    ceiling
  end
end
