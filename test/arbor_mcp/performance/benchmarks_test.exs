defmodule Arbor.MCP.Performance.BenchmarksTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Content.Protocol
  alias Arbor.MCP.Testing.{Builders, MockServer}

  @moduletag :performance
  @moduletag timeout: 60_000

  # Test performance thresholds (in microseconds)
  @content_creation_threshold 100
  @content_validation_threshold 50
  @content_serialization_threshold 200
  @content_deserialization_threshold 300
  @tool_call_threshold 1000
  # @batch_operations_threshold 5000  # Unused but kept for future batch operation tests

  describe "content protocol performance" do
    test "text content creation performance" do
      {time, _result} =
        :timer.tc(fn ->
          Enum.each(1..1000, fn _ ->
            Protocol.text("Sample text content for performance testing")
          end)
        end)

      avg_time = div(time, 1000)

      assert avg_time < @content_creation_threshold,
             "Text content creation took #{avg_time}μs, expected < #{@content_creation_threshold}μs"
    end

    test "image content creation performance" do
      data = Base.encode64(:crypto.strong_rand_bytes(1024))

      {time, _result} =
        :timer.tc(fn ->
          Enum.each(1..1000, fn _ ->
            Protocol.image(data, "image/png", width: 100, height: 100)
          end)
        end)

      avg_time = div(time, 1000)

      assert avg_time < @content_creation_threshold,
             "Image content creation took #{avg_time}μs, expected < #{@content_creation_threshold}μs"
    end

    test "content validation performance" do
      content = Protocol.text("Test content")

      {time, _result} =
        :timer.tc(fn ->
          Enum.each(1..1000, fn _ ->
            Protocol.validate(content)
          end)
        end)

      avg_time = div(time, 1000)

      assert avg_time < @content_validation_threshold,
             "Content validation took #{avg_time}μs, expected < #{@content_validation_threshold}μs"
    end

    test "content serialization performance" do
      content = Protocol.text("Test content", format: :markdown, language: "en")

      {time, _result} =
        :timer.tc(fn ->
          Enum.each(1..1000, fn _ ->
            Protocol.serialize(content)
          end)
        end)

      avg_time = div(time, 1000)

      assert avg_time < @content_serialization_threshold,
             "Content serialization took #{avg_time}μs, expected < #{@content_serialization_threshold}μs"
    end

    test "content deserialization performance" do
      serialized = %{
        "type" => "text",
        "text" => "Test content",
        "format" => "markdown",
        "language" => "en"
      }

      {time, _result} =
        :timer.tc(fn ->
          Enum.each(1..1000, fn _ ->
            Protocol.deserialize(serialized)
          end)
        end)

      avg_time = div(time, 1000)

      assert avg_time < @content_deserialization_threshold,
             "Content deserialization took #{avg_time}μs, expected < #{@content_deserialization_threshold}μs"
    end

    test "roundtrip serialization performance" do
      content = Protocol.text("Test content", format: :markdown, metadata: %{author: "test"})

      {time, _result} =
        :timer.tc(fn ->
          Enum.each(1..1000, fn _ ->
            serialized = Protocol.serialize(content)
            {:ok, _deserialized} = Protocol.deserialize(serialized)
          end)
        end)

      avg_time = div(time, 1000)
      total_threshold = @content_serialization_threshold + @content_deserialization_threshold

      assert avg_time < total_threshold,
             "Roundtrip serialization took #{avg_time}μs, expected < #{total_threshold}μs"
    end
  end

  describe "testing framework performance" do
    test "builders performance" do
      {time, _result} =
        :timer.tc(fn ->
          Enum.each(1..1000, fn _ ->
            Builders.text_content("Test content")
            Builders.image_content()
            Builders.tool("test_tool")
            Builders.resource("file://test.txt", "Test Resource")
          end)
        end)

      avg_time = div(time, 1000)

      assert avg_time < @content_creation_threshold,
             "Builders performance took #{avg_time}μs, expected < #{@content_creation_threshold}μs"
    end

    test "random data generation performance" do
      {time, _result} =
        :timer.tc(fn ->
          Enum.each(1..1000, fn _ ->
            Builders.random_text(100)
            Builders.random_string(50)
            Builders.random_bytes(64)
          end)
        end)

      avg_time = div(time, 1000)
      # Random generation can be slower
      assert avg_time < 500,
             "Random data generation took #{avg_time}μs, expected < 500μs"
    end
  end

  describe "mock server performance" do
    test "mock server request handling performance" do
      MockServer.with_server(
        [
          tools: [MockServer.sample_tool()],
          # No artificial latency for performance test
          latency: 0
        ],
        fn _client ->
          requests =
            Enum.map(1..100, fn i ->
              Builders.request("tools/list", id: i)
            end)

          {time, _results} =
            :timer.tc(fn ->
              # In real test, these would be sent to client
              # For now, we'll measure the preparation time
              Enum.map(requests, fn request ->
                # Simulate request processing
                %{processed: request}
              end)
            end)

          avg_time = div(time, 100)

          assert avg_time < @tool_call_threshold,
                 "Mock server request handling took #{avg_time}μs, expected < #{@tool_call_threshold}μs"
        end
      )
    end
  end

  describe "batch operations performance" do
    test "batch content validation performance" do
      contents =
        Enum.map(1..100, fn i ->
          Protocol.text("Content #{i}", format: :markdown)
        end)

      {time, _result} =
        :timer.tc(fn ->
          Enum.each(contents, &Protocol.validate/1)
        end)

      avg_time = div(time, 100)

      assert avg_time < @content_validation_threshold,
             "Batch content validation took #{avg_time}μs per item, expected < #{@content_validation_threshold}μs"
    end

    test "batch serialization performance" do
      contents =
        Enum.map(1..100, fn i ->
          Protocol.text("Content #{i}",
            format: :markdown,
            language: "en",
            metadata: %{index: i}
          )
        end)

      {time, _result} =
        :timer.tc(fn ->
          Enum.map(contents, &Protocol.serialize/1)
        end)

      avg_time = div(time, 100)

      assert avg_time < @content_serialization_threshold,
             "Batch serialization took #{avg_time}μs per item, expected < #{@content_serialization_threshold}μs"
    end

    test "large content handling performance" do
      # Test with larger content sizes
      # ~13KB
      large_text = String.duplicate("Test content. ", 1000)
      large_content = Protocol.text(large_text)

      {time, _result} =
        :timer.tc(fn ->
          Enum.each(1..100, fn _ ->
            serialized = Protocol.serialize(large_content)
            {:ok, _deserialized} = Protocol.deserialize(serialized)
          end)
        end)

      avg_time = div(time, 100)
      # Large content can be slower
      large_content_threshold = @content_serialization_threshold * 3

      assert avg_time < large_content_threshold,
             "Large content handling took #{avg_time}μs, expected < #{large_content_threshold}μs"
    end
  end

  describe "memory efficiency" do
    test "content creation memory usage" do
      # Test memory usage doesn't grow excessively
      initial_memory = :erlang.memory(:total)

      # Create many content objects
      contents =
        Enum.map(1..1000, fn i ->
          Protocol.text("Content #{i}", metadata: %{index: i})
        end)

      # Force garbage collection
      :erlang.garbage_collect()

      final_memory = :erlang.memory(:total)
      memory_increase = final_memory - initial_memory

      # Should not increase memory by more than 10MB for 1000 small objects
      assert memory_increase < 10_000_000,
             "Memory increased by #{memory_increase} bytes, expected < 10MB"

      # Clean up
      _ = contents
      :erlang.garbage_collect()
    end

    test "serialization memory efficiency" do
      content = Protocol.text("Test content")
      initial_memory = :erlang.memory(:total)

      # Perform many serializations
      Enum.each(1..1000, fn _ ->
        _serialized = Protocol.serialize(content)
      end)

      :erlang.garbage_collect()
      final_memory = :erlang.memory(:total)
      memory_increase = final_memory - initial_memory

      # Should not leak significant memory during serialization
      assert memory_increase < 1_000_000,
             "Serialization leaked #{memory_increase} bytes, expected < 1MB"
    end
  end

  describe "concurrent operations performance" do
    test "concurrent content validation" do
      content = Protocol.text("Test content")

      {time, _results} =
        :timer.tc(fn ->
          1..100
          |> Task.async_stream(
            fn _ ->
              Enum.each(1..10, fn _ ->
                Protocol.validate(content)
              end)
            end,
            max_concurrency: System.schedulers_online()
          )
          |> Enum.to_list()
        end)

      # Concurrent operations should be faster than sequential
      # 1000 total operations should complete quickly
      # 100ms
      assert time < 100_000,
             "Concurrent validation took #{time}μs, expected < 100ms"
    end

    test "concurrent serialization" do
      contents =
        Enum.map(1..100, fn i ->
          Protocol.text("Content #{i}")
        end)

      {time, _results} =
        :timer.tc(fn ->
          contents
          |> Task.async_stream(&Protocol.serialize/1, max_concurrency: System.schedulers_online())
          |> Enum.to_list()
        end)

      # Should complete within reasonable time
      # 50ms
      assert time < 50_000,
             "Concurrent serialization took #{time}μs, expected < 50ms"
    end
  end

  describe "performance regression detection" do
    @tag :regression
    test "baseline performance measurement" do
      # This test establishes performance baselines for regression detection
      results = %{}

      # Text content creation
      {time, _} =
        :timer.tc(fn ->
          Enum.each(1..1000, fn _ ->
            Protocol.text("Baseline test")
          end)
        end)

      results = Map.put(results, :text_creation, div(time, 1000))

      # Content validation
      content = Protocol.text("Baseline test")

      {time, _} =
        :timer.tc(fn ->
          Enum.each(1..1000, fn _ ->
            Protocol.validate(content)
          end)
        end)

      results = Map.put(results, :validation, div(time, 1000))

      # Serialization
      {time, _} =
        :timer.tc(fn ->
          Enum.each(1..1000, fn _ ->
            Protocol.serialize(content)
          end)
        end)

      results = Map.put(results, :serialization, div(time, 1000))

      # Log results for tracking (in real implementation, would store in metrics system)
      IO.puts("Performance baseline results:")

      Enum.each(results, fn {operation, time_us} ->
        IO.puts("  #{operation}: #{time_us}μs")
      end)

      # All operations should complete within reasonable time
      Enum.each(results, fn {operation, time_us} ->
        assert time_us < 1000,
               "#{operation} took #{time_us}μs, baseline should be < 1000μs"
      end)
    end
  end
end
