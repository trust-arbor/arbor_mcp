defmodule Arbor.MCP.Testing.PerformanceProfiler do
  @moduledoc """
  Performance profiling utilities for Arbor.MCP integration tests.

  This module provides comprehensive performance measurement and analysis
  tools for MCP operations across different transports and scenarios.

  ## Features

  - **Operation Timing**: Precise timing measurements for MCP operations
  - **Memory Profiling**: Memory usage tracking during operations
  - **Throughput Analysis**: Request/response throughput measurements
  - **Latency Distribution**: Statistical analysis of operation latencies
  - **Transport Comparison**: Performance comparison across transports
  - **Resource Monitoring**: System resource usage during tests
  - **Performance Regression Detection**: Baseline comparison and alerts

  ## Usage

      alias Arbor.MCP.Testing.PerformanceProfiler
      
      # Profile a single operation
      {result, metrics} = PerformanceProfiler.profile_operation(fn ->
        Client.call_tool(client, "test_tool", %{})
      end)
      
      # Profile with context
      metrics = PerformanceProfiler.profile_context("tool_execution", fn ->
        Client.call_tool(client, "expensive_tool", %{})
      end)
      
      # Batch profiling
      results = PerformanceProfiler.profile_batch([
        {"list_tools", fn -> Client.list_tools(client) end},
        {"call_tool", fn -> Client.call_tool(client, "test", %{}) end}
      ])
      
      # Generate performance report
      report = PerformanceProfiler.generate_report(results)
  """

  require Logger

  @type operation_metrics :: %{
          execution_time_ms: float(),
          memory_before_mb: float(),
          memory_after_mb: float(),
          memory_delta_mb: float(),
          gc_before: map(),
          gc_after: map(),
          gc_collections: integer(),
          reductions_used: integer(),
          message_queue_len: integer(),
          process_count: integer(),
          timestamp: DateTime.t(),
          operation_name: String.t(),
          transport_type: atom() | nil,
          payload_size_bytes: integer() | nil,
          success: boolean(),
          error: any() | nil
        }

  @type batch_results :: %{
          operations: [operation_metrics()],
          summary: %{
            total_time_ms: float(),
            avg_time_ms: float(),
            min_time_ms: float(),
            max_time_ms: float(),
            std_dev_ms: float(),
            throughput_ops_per_sec: float(),
            success_rate: float(),
            total_memory_delta_mb: float()
          }
        }

  @doc """
  Profiles a single operation with comprehensive metrics collection.

  ## Examples

      {result, metrics} = PerformanceProfiler.profile_operation(fn ->
        Client.call_tool(client, "test_tool", %{})
      end, operation_name: "tool_call", transport_type: :test)
  """
  @dialyzer {:nowarn_function, profile_operation: 1, profile_operation: 2}
  @spec profile_operation((... -> any()), keyword()) :: {any(), operation_metrics()}
  def profile_operation(operation_fn, opts \\ []) do
    operation_name = Keyword.get(opts, :operation_name, "unknown_operation")
    transport_type = Keyword.get(opts, :transport_type)
    payload_size = Keyword.get(opts, :payload_size_bytes)

    # Collect pre-operation metrics
    {memory_before, gc_before} = collect_memory_metrics()
    reductions_before = :erlang.statistics(:reductions) |> elem(0)
    process_count_before = :erlang.system_info(:process_count)
    start_time = System.monotonic_time(:microsecond)

    # Execute operation
    {result, success, error} =
      try do
        result = operation_fn.()
        {result, true, nil}
      rescue
        e -> {nil, false, e}
      catch
        :exit, reason -> {nil, false, {:exit, reason}}
        :throw, value -> {nil, false, {:throw, value}}
      end

    # Collect post-operation metrics
    end_time = System.monotonic_time(:microsecond)
    {memory_after, gc_after} = collect_memory_metrics()
    reductions_after = :erlang.statistics(:reductions) |> elem(0)
    process_count_after = :erlang.system_info(:process_count)

    # Calculate metrics
    execution_time_ms = (end_time - start_time) / 1000
    memory_delta_mb = memory_after - memory_before
    reductions_used = reductions_after - reductions_before
    gc_collections = calculate_gc_delta(gc_before, gc_after)

    metrics = %{
      execution_time_ms: execution_time_ms,
      memory_before_mb: memory_before,
      memory_after_mb: memory_after,
      memory_delta_mb: memory_delta_mb,
      gc_before: gc_before,
      gc_after: gc_after,
      gc_collections: gc_collections,
      reductions_used: reductions_used,
      message_queue_len: get_message_queue_length(),
      process_count: process_count_after - process_count_before,
      timestamp: DateTime.utc_now(),
      operation_name: operation_name,
      transport_type: transport_type,
      payload_size_bytes: payload_size,
      success: success,
      error: error
    }

    {result, metrics}
  end

  @doc """
  Profiles an operation within a named context for easier reporting.

  ## Examples

      metrics = PerformanceProfiler.profile_context("batch_tool_calls", fn ->
        Enum.map(tools, fn tool ->
          Client.call_tool(client, tool, %{})
        end)
      end)
  """
  @dialyzer {:nowarn_function, profile_context: 2, profile_context: 3}
  @spec profile_context(String.t(), (... -> any()), keyword()) :: operation_metrics()
  def profile_context(context_name, operation_fn, opts \\ []) when is_function(operation_fn) do
    {_result, metrics} =
      profile_operation(
        operation_fn,
        Keyword.put(opts, :operation_name, context_name)
      )

    metrics
  end

  @doc """
  Profiles multiple operations in batch and provides statistical analysis.

  ## Examples

      results = PerformanceProfiler.profile_batch([
        {"list_tools", fn -> Client.list_tools(client) end},
        {"list_resources", fn -> Client.list_resources(client) end},
        {"tool_call_small", fn -> Client.call_tool(client, "echo", %{"msg" => "hi"}) end},
        {"tool_call_large", fn -> Client.call_tool(client, "echo", %{"msg" => large_text}) end}
      ], transport_type: :test)
  """
  @spec profile_batch([{String.t(), function()}], keyword()) :: batch_results()
  def profile_batch(operations, opts \\ []) do
    transport_type = Keyword.get(opts, :transport_type)

    Logger.info("Starting batch performance profiling with #{length(operations)} operations")

    batch_start = System.monotonic_time(:microsecond)

    operation_results =
      Enum.map(operations, fn {name, operation_fn} ->
        {_result, metrics} =
          profile_operation(operation_fn,
            operation_name: name,
            transport_type: transport_type
          )

        metrics
      end)

    batch_end = System.monotonic_time(:microsecond)
    total_time_ms = (batch_end - batch_start) / 1000

    summary = calculate_batch_summary(operation_results, total_time_ms)

    %{
      operations: operation_results,
      summary: summary
    }
  end

  @doc """
  Runs performance comparison across multiple transports.

  ## Examples

      comparison = PerformanceProfiler.compare_transports([
        {:test, test_client},
        {:http, http_client}
      ], [
        {"list_tools", fn client -> Client.list_tools(client) end},
        {"call_tool", fn client -> Client.call_tool(client, "ping", %{}) end}
      ])
  """
  @spec compare_transports([{atom(), pid()}], [{String.t(), function()}]) :: map()
  def compare_transports(transport_clients, operations) do
    Logger.info("Starting transport performance comparison")

    results =
      Enum.map(transport_clients, fn {transport_type, client} ->
        Logger.info("Profiling #{transport_type} transport")

        transport_operations =
          Enum.map(operations, fn {name, operation_fn} ->
            {name, fn -> operation_fn.(client) end}
          end)

        batch_results = profile_batch(transport_operations, transport_type: transport_type)
        {transport_type, batch_results}
      end)

    %{
      transport_results: results,
      comparison_summary: generate_transport_comparison(results)
    }
  end

  @doc """
  Generates a comprehensive performance report from profiling results.

  ## Examples

      report = PerformanceProfiler.generate_report(batch_results, 
        format: :detailed, 
        include_recommendations: true)
      IO.puts(report)
  """
  @spec generate_report(batch_results() | map(), keyword()) :: String.t()
  def generate_report(results, opts \\ []) do
    format = Keyword.get(opts, :format, :summary)
    include_recommendations = Keyword.get(opts, :include_recommendations, false)

    case format do
      :summary -> generate_summary_report(results)
      :detailed -> generate_detailed_report(results, include_recommendations)
      :csv -> generate_csv_report(results)
      :json -> Jason.encode!(results, pretty: true)
    end
  end

  @doc """
  Establishes performance baselines and detects regressions.

  ## Examples

      # Store baseline
      PerformanceProfiler.store_baseline("v1.0.0", batch_results)
      
      # Check for regressions
      regression_report = PerformanceProfiler.check_regression("v1.0.0", current_results)
  """
  @spec store_baseline(String.t(), batch_results()) :: :ok
  def store_baseline(version, results) do
    baseline_file = "test/support/performance_baselines.json"

    baselines =
      case File.read(baseline_file) do
        {:ok, content} -> Jason.decode!(content)
        {:error, :enoent} -> %{}
      end

    # Clean results to ensure JSON serialization compatibility
    clean_results = clean_for_json(results)
    updated_baselines = Map.put(baselines, version, clean_results)

    File.mkdir_p!("test/support")
    File.write!(baseline_file, Jason.encode!(updated_baselines, pretty: true))

    Logger.info("Stored performance baseline for version #{version}")
    :ok
  end

  @spec check_regression(String.t(), batch_results()) :: map()
  def check_regression(baseline_version, current_results) do
    baseline_file = "test/support/performance_baselines.json"

    case File.read(baseline_file) do
      {:ok, content} ->
        baselines = Jason.decode!(content, keys: :atoms)
        baseline = Map.get(baselines, String.to_atom(baseline_version))

        if baseline do
          analyze_regression(baseline, current_results)
        else
          %{error: "Baseline version #{baseline_version} not found"}
        end

      {:error, :enoent} ->
        %{error: "No baseline file found"}
    end
  end

  # Private helper functions

  defp collect_memory_metrics do
    memory_mb = :erlang.memory(:total) / (1024 * 1024)
    gc_info = :erlang.statistics(:garbage_collection)
    {memory_mb, gc_info}
  end

  defp calculate_gc_delta({gc_count_before, _, _}, {gc_count_after, _, _}) do
    gc_count_after - gc_count_before
  end

  defp get_message_queue_length do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)
    len
  end

  defp calculate_batch_summary(operations, total_time_ms) do
    execution_times = Enum.map(operations, & &1.execution_time_ms)
    successful_ops = Enum.filter(operations, & &1.success)

    %{
      total_time_ms: total_time_ms,
      avg_time_ms: Enum.sum(execution_times) / length(execution_times),
      min_time_ms: Enum.min(execution_times),
      max_time_ms: Enum.max(execution_times),
      std_dev_ms: calculate_std_dev(execution_times),
      throughput_ops_per_sec: length(operations) / (total_time_ms / 1000),
      success_rate: length(successful_ops) / length(operations),
      total_memory_delta_mb: Enum.sum(Enum.map(operations, & &1.memory_delta_mb))
    }
  end

  defp calculate_std_dev(values) do
    mean = Enum.sum(values) / length(values)
    variance = Enum.sum(Enum.map(values, fn x -> :math.pow(x - mean, 2) end)) / length(values)
    :math.sqrt(variance)
  end

  defp generate_transport_comparison(transport_results) do
    Enum.map(transport_results, fn {transport, results} ->
      summary = results.summary

      %{
        transport: transport,
        avg_time_ms: summary.avg_time_ms,
        throughput_ops_per_sec: summary.throughput_ops_per_sec,
        success_rate: summary.success_rate,
        memory_usage_mb: summary.total_memory_delta_mb
      }
    end)
  end

  defp generate_summary_report(%{summary: summary}) do
    """
    ## Performance Summary Report

    **Overall Statistics:**
    - Total Time: #{Float.round(summary.total_time_ms, 2)}ms
    - Average Time: #{Float.round(summary.avg_time_ms, 2)}ms
    - Min/Max Time: #{Float.round(summary.min_time_ms, 2)}ms / #{Float.round(summary.max_time_ms, 2)}ms
    - Standard Deviation: #{Float.round(summary.std_dev_ms, 2)}ms
    - Throughput: #{Float.round(summary.throughput_ops_per_sec, 2)} ops/sec
    - Success Rate: #{Float.round(summary.success_rate * 100, 1)}%
    - Total Memory Delta: #{Float.round(summary.total_memory_delta_mb, 3)}MB
    """
  end

  defp generate_detailed_report(
         %{operations: operations, summary: summary},
         include_recommendations
       ) do
    operation_details =
      Enum.map_join(operations, "\n", fn op ->
        """
        **#{op.operation_name}** (#{op.transport_type || "unknown"}):
        - Execution Time: #{Float.round(op.execution_time_ms, 2)}ms
        - Memory Delta: #{Float.round(op.memory_delta_mb, 3)}MB
        - GC Collections: #{op.gc_collections}
        - Reductions: #{op.reductions_used}
        - Success: #{op.success}
        """
      end)

    recommendations =
      if include_recommendations do
        generate_recommendations(operations, summary)
      else
        ""
      end

    generate_summary_report(%{summary: summary}) <>
      "\n" <>
      "## Operation Details\n\n" <> operation_details <> "\n" <> recommendations
  end

  defp generate_csv_report(%{operations: operations}) do
    header = "operation_name,transport_type,execution_time_ms,memory_delta_mb,success,timestamp\n"

    rows =
      Enum.map_join(operations, "\n", fn op ->
        "#{op.operation_name},#{op.transport_type},#{op.execution_time_ms},#{op.memory_delta_mb},#{op.success},#{op.timestamp}"
      end)

    header <> rows
  end

  defp generate_recommendations(_operations, summary) do
    recommendations = []

    # Performance recommendations
    recommendations =
      if summary.avg_time_ms > 100 do
        [
          "Consider optimizing operations - average response time is #{Float.round(summary.avg_time_ms, 1)}ms"
          | recommendations
        ]
      else
        recommendations
      end

    # Memory recommendations
    recommendations =
      if summary.total_memory_delta_mb > 10 do
        [
          "High memory usage detected - total delta is #{Float.round(summary.total_memory_delta_mb, 1)}MB"
          | recommendations
        ]
      else
        recommendations
      end

    # Success rate recommendations
    recommendations =
      if summary.success_rate < 1.0 do
        [
          "Error rate is #{Float.round((1 - summary.success_rate) * 100, 1)}% - investigate failures"
          | recommendations
        ]
      else
        recommendations
      end

    if recommendations == [] do
      "\n## Recommendations\n\nPerformance looks good! No specific recommendations at this time.\n"
    else
      "\n## Recommendations\n\n" <> Enum.map_join(recommendations, "\n", &("- " <> &1)) <> "\n"
    end
  end

  # Clean data structure for JSON serialization
  defp clean_for_json(%{operations: operations, summary: summary}) do
    %{
      operations: Enum.map(operations, &clean_operation_for_json/1),
      summary: clean_summary_for_json(summary)
    }
  end

  defp clean_operation_for_json(operation) do
    operation
    # Remove complex GC tuples
    |> Map.drop([:gc_before, :gc_after])
    # Convert DateTime to string
    |> Map.update(:timestamp, nil, &DateTime.to_iso8601/1)
    # Convert any errors to strings
    |> Map.update(:error, nil, &inspect/1)
  end

  defp clean_summary_for_json(summary) do
    # Summary should already be JSON-safe
    summary
  end

  defp analyze_regression(baseline, current) do
    baseline_summary = baseline[:summary] || baseline["summary"]
    current_summary = current.summary

    avg_time_change =
      (current_summary.avg_time_ms - baseline_summary[:avg_time_ms]) /
        baseline_summary[:avg_time_ms] * 100

    throughput_change =
      (current_summary.throughput_ops_per_sec - baseline_summary[:throughput_ops_per_sec]) /
        baseline_summary[:throughput_ops_per_sec] * 100

    regressions = []

    regressions =
      if avg_time_change > 20 do
        ["Average response time increased by #{Float.round(avg_time_change, 1)}%" | regressions]
      else
        regressions
      end

    regressions =
      if throughput_change < -20 do
        ["Throughput decreased by #{Float.round(abs(throughput_change), 1)}%" | regressions]
      else
        regressions
      end

    %{
      baseline_avg_time_ms: baseline_summary[:avg_time_ms],
      current_avg_time_ms: current_summary.avg_time_ms,
      avg_time_change_percent: avg_time_change,
      baseline_throughput: baseline_summary[:throughput_ops_per_sec],
      current_throughput: current_summary.throughput_ops_per_sec,
      throughput_change_percent: throughput_change,
      regressions: regressions,
      has_regression: length(regressions) > 0
    }
  end
end
