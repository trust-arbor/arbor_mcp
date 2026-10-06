defmodule Arbor.MCP.TestCase do
  @moduledoc """
  Custom test case for ArborMCP with MCP-specific testing utilities.

  This module provides a comprehensive testing framework specifically designed
  for MCP (Model Context Protocol) applications, including:

  - Custom assertions for MCP protocol validation
  - Mock server and client infrastructure
  - Content testing utilities
  - DSL testing helpers
  - Performance testing tools
  - Integration testing support

  ## Usage

      defmodule MyMCPTest do
        use Arbor.MCP.TestCase, async: true

        test "tool call validation" do
          tool_result = %{
            "content" => [%{"type" => "text", "text" => "Hello"}]
          }

          assert_valid_tool_result(tool_result)
          assert_content_type(tool_result, :text)
          assert_content_contains(tool_result, "Hello")
        end

        test "server integration" do
          with_mock_server(tools: [sample_tool()]) do |client|
            result = call_tool(client, "sample_tool", %{input: "test"})
            assert_success(result)
          end
        end
      end
  """

  defmacro __using__(opts) do
    quote do
      use ExUnit.Case, unquote(opts)

      import Arbor.MCP.TestCase
      import Arbor.MCP.Testing.Assertions
      import Arbor.MCP.Testing.Builders
      import Arbor.MCP.Testing.MockServer

      alias Arbor.MCP.Content.{Builders, Protocol}
      alias Arbor.MCP.Testing.{Fixtures, Generators, TestServer}

      # Set up test environment
      setup do
        # Clean up any global state
        :ok = Arbor.MCP.Testing.cleanup_global_state()

        # Generate unique test identifiers
        test_id = generate_test_id()

        %{test_id: test_id}
      end

      # Helper for generating test data
      defp generate_test_id do
        :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      end
    end
  end

  @doc """
  Runs a test with a mock MCP server.

  ## Examples

      with_mock_server(tools: [sample_tool()], resources: [sample_resource()]) do |client|
        result = Arbor.MCP.Client.list_tools(client)
        assert {:ok, %{"tools" => tools}} = result
        assert length(tools) == 1
      end
  """
  defmacro with_mock_server(opts \\ [], do: block) do
    quote do
      MockServer.with_server(unquote(opts), fn client ->
        var!(client) = client
        unquote(block)
      end)
    end
  end

  @doc """
  Runs a test with a real MCP server process.

  ## Examples

      with_test_server(MyServer, port: 8080) do |client|
        result = Arbor.MCP.Client.list_tools(client)
        assert {:ok, %{"tools" => _}} = result
      end
  """
  defmacro with_test_server(server_module, opts \\ [], do: block) do
    quote do
      TestServer.with_server(unquote(server_module), unquote(opts), fn client ->
        var!(client) = client
        unquote(block)
      end)
    end
  end

  @doc """
  Measures execution time of a block.

  ## Examples

      {result, time_ms} = measure_time do
        heavy_computation()
      end

      assert time_ms < 1000  # Should complete in under 1 second
  """
  defmacro measure_time(do: block) do
    quote do
      start_time = System.monotonic_time(:millisecond)
      result = unquote(block)
      end_time = System.monotonic_time(:millisecond)
      {result, end_time - start_time}
    end
  end

  @doc """
  Runs a block with a timeout, failing the test if it takes too long.

  ## Examples

      with_timeout 5000 do
        slow_operation()
      end
  """
  defmacro with_timeout(timeout_ms, do: block) do
    quote do
      task = Task.async(fn -> unquote(block) end)

      case Task.yield(task, unquote(timeout_ms)) do
        {:ok, result} ->
          result

        nil ->
          Task.shutdown(task)
          flunk("Operation timed out after #{unquote(timeout_ms)}ms")
      end
    end
  end

  @doc """
  Runs a test multiple times to check for flakiness.

  ## Examples

      repeat_test 10 do
        result = potentially_flaky_operation()
        assert result == :ok
      end
  """
  defmacro repeat_test(times, do: block) do
    caller = __CALLER__

    quote do
      Enum.each(1..unquote(times), fn iteration ->
        try do
          unquote(block)
        rescue
          error ->
            # Enhance the error message and re-raise with original type
            original_message = Exception.message(error)

            enhanced_error =
              Map.put(error, :message, original_message <> " (iteration #{iteration})")

            reraise enhanced_error, [
              {__MODULE__, :"test iteration #{iteration}", 0,
               [file: unquote(caller.file), line: unquote(caller.line)]}
              | __STACKTRACE__
            ]
        end
      end)
    end
  end

  @doc """
  Creates a temporary file with content for testing.

  ## Examples

      with_temp_file("test content", ".txt") do |file_path|
        content = File.read!(file_path)
        assert content == "test content"
      end
  """
  defmacro with_temp_file(content, extension \\ "", do: block) do
    quote do
      temp_dir = System.tmp_dir!()
      file_name = "test_#{:rand.uniform(1_000_000)}#{unquote(extension)}"
      file_path = Path.join(temp_dir, file_name)

      try do
        File.write!(file_path, unquote(content))
        var!(file_path) = file_path
        unquote(block)
      after
        File.rm(file_path)
      end
    end
  end

  @doc """
  Captures log output during test execution.

  ## Examples

      logs = capture_logs do
        Logger.info("Test message")
        some_operation()
      end

      assert logs =~ "Test message"
  """
  defmacro capture_logs(do: block) do
    quote do
      ExUnit.CaptureLog.capture_log(fn ->
        unquote(block)
      end)
    end
  end

  @doc """
  Runs a test with specific configuration overrides.

  ## Examples

      with_config([timeout: 10_000, retries: 3]) do
        test_with_custom_config()
      end
  """
  defmacro with_config(config, do: block) do
    quote do
      original_config = Application.get_all_env(:arbor_mcp)

      try do
        Enum.each(unquote(config), fn {key, value} ->
          Application.put_env(:arbor_mcp, key, value)
        end)

        unquote(block)
      after
        Application.put_all_env([{:arbor_mcp, original_config}])
      end
    end
  end

  @doc """
  Creates a test that runs concurrently with other tests.

  ## Examples

      concurrent_test "parallel operation", count: 5 do |index|
        result = parallel_operation(index)
        assert result.id == index
      end
  """
  defmacro concurrent_test(description, opts \\ [], do: block) do
    count = Keyword.get(opts, :count, 3)
    timeout = Keyword.get(opts, :timeout, 5000)

    quote do
      test unquote(description) do
        tasks =
          1..unquote(count)
          |> Enum.map(fn index ->
            Task.async(fn ->
              var!(index) = index
              unquote(block)
            end)
          end)

        Task.await_many(tasks, unquote(timeout))
      end
    end
  end

  # Utility Functions

  @doc """
  Waits for a condition to become true within a timeout.

  ## Examples

      wait_until(fn -> Process.alive?(pid) end, timeout: 1000)
  """
  @spec wait_until((-> boolean()), keyword()) :: :ok | :timeout
  def wait_until(condition_fun, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    interval = Keyword.get(opts, :interval, 100)

    end_time = System.monotonic_time(:millisecond) + timeout
    do_wait_until(condition_fun, end_time, interval)
  end

  defp do_wait_until(condition_fun, end_time, interval) do
    if condition_fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= end_time do
        :timeout
      else
        Process.sleep(interval)
        do_wait_until(condition_fun, end_time, interval)
      end
    end
  end

  @doc """
  Runs tests in parallel and collects results.

  ## Examples

      results = run_parallel([
        fn -> test_operation_1() end,
        fn -> test_operation_2() end,
        fn -> test_operation_3() end
      ])

      assert length(results) == 3
      assert Enum.all?(results, &(&1 == :ok))
  """
  @spec run_parallel([(-> any())], keyword()) :: [any()]
  def run_parallel(functions, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)

    try do
      functions
      |> Enum.map(&Task.async/1)
      |> Task.await_many(timeout)
    catch
      :exit, reason -> raise RuntimeError, "Parallel execution failed: #{inspect(reason)}"
    end
  end

  @doc """
  Creates a supervision tree for testing.

  ## Examples

      {:ok, supervisor} = start_test_supervisor([
        {MyWorker, [name: :test_worker]},
        {MyServer, [port: 0]}
      ])

      # Test with supervised processes
      assert Process.alive?(Process.whereis(:test_worker))
  """
  @spec start_test_supervisor([Supervisor.child_spec()]) :: {:ok, pid()} | {:error, any()}
  def start_test_supervisor(child_specs) do
    Supervisor.start_link(child_specs, strategy: :one_for_one)
  end

  @doc """
  Flushes all messages from the test process mailbox.
  """
  @spec flush_messages() :: [any()]
  def flush_messages do
    receive do
      msg -> [msg | flush_messages()]
    after
      0 -> []
    end
  end

  @doc """
  Generates unique test data with a prefix.

  ## Examples

      id = unique_id("test")          # "test_a1b2c3d4"
      name = unique_id("user", 8)     # "user_1a2b3c4d"
  """
  @spec unique_id(String.t(), pos_integer()) :: String.t()
  def unique_id(prefix, length \\ 8) do
    suffix = :crypto.strong_rand_bytes(div(length, 2)) |> Base.encode16(case: :lower)
    "#{prefix}_#{suffix}"
  end

  @doc """
  Creates a test context with cleanup.

  ## Examples

      context = create_test_context(%{
        server_port: 8080,
        temp_dir: "/tmp/test"
      })

      # Use context in tests
      assert context.server_port == 8080

      # Cleanup is automatic
  """
  @spec create_test_context(map()) :: map()
  def create_test_context(initial_context \\ %{}) do
    test_id = unique_id("ctx")

    context =
      Map.merge(initial_context, %{
        test_id: test_id,
        created_at: DateTime.utc_now(),
        cleanup_functions: []
      })

    # Register cleanup for end of test
    ExUnit.Callbacks.on_exit(fn ->
      cleanup_test_context(context)
    end)

    context
  end

  @doc """
  Adds a cleanup function to the test context.
  """
  @spec add_cleanup(map(), (-> any())) :: map()
  def add_cleanup(context, cleanup_fun) when is_function(cleanup_fun, 0) do
    cleanup_functions = [cleanup_fun | Map.get(context, :cleanup_functions, [])]
    Map.put(context, :cleanup_functions, cleanup_functions)
  end

  defp cleanup_test_context(context) do
    cleanup_functions = Map.get(context, :cleanup_functions, [])

    Enum.each(cleanup_functions, fn cleanup_fun ->
      try do
        cleanup_fun.()
      rescue
        error ->
          # Log cleanup errors but don't fail the test
          IO.warn("Cleanup function failed: #{inspect(error)}")
      end
    end)
  end
end
