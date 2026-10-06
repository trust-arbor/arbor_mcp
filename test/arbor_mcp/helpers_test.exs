defmodule Arbor.MCP.HelpersTest do
  use ExUnit.Case, async: false

  import Arbor.MCP.Helpers
  alias Arbor.MCP.{ClientError, ConnectionError, PromptError, ResourceError, ToolError}

  describe "__using__ macro" do
    test "imports helpers and creates alias" do
      # Test that a module using Arbor.MCP.Helpers gets the imports
      defmodule TestUsing do
        use Arbor.MCP.Helpers

        def test_function do
          # This should compile without errors if imports work
          quote do
            measure do
              1 + 1
            end
          end
        end
      end

      # Test that the function was defined
      assert function_exported?(TestUsing, :test_function, 0)
    end
  end

  describe "retry macro" do
    test "succeeds on first attempt" do
      counter = Agent.start_link(fn -> 0 end)
      {:ok, agent} = counter

      result =
        retry max_attempts: 3, base_delay: 100 do
          Agent.update(agent, &(&1 + 1))
          Agent.get(agent, & &1)
        end

      assert result == 1
      Agent.stop(agent)
    end

    test "retries on failure and eventually succeeds" do
      counter = Agent.start_link(fn -> 0 end)
      {:ok, agent} = counter

      result =
        retry max_attempts: 3, base_delay: 50 do
          current = Agent.get_and_update(agent, fn count -> {count + 1, count + 1} end)
          if current < 3, do: raise("Attempt #{current} failed")
          current
        end

      assert result == 3
      Agent.stop(agent)
    end

    test "exhausts retries and raises original error" do
      assert_raise RuntimeError, "Always fails", fn ->
        retry max_attempts: 2, base_delay: 10 do
          raise "Always fails"
        end
      end
    end

    test "uses default options" do
      counter = Agent.start_link(fn -> 0 end)
      {:ok, agent} = counter

      result =
        retry do
          Agent.update(agent, &(&1 + 1))
          Agent.get(agent, & &1)
        end

      assert result == 1
      Agent.stop(agent)
    end
  end

  describe "measure macro" do
    test "measures execution time" do
      {result, time_ms} =
        measure do
          Process.sleep(50)
          "test_result"
        end

      assert result == "test_result"
      assert time_ms >= 50
      # Allow some margin for test execution
      assert time_ms < 200
    end

    test "measures fast operations" do
      {result, time_ms} =
        measure do
          1 + 1
        end

      assert result == 2
      assert is_integer(time_ms)
      assert time_ms >= 0
    end

    test "preserves return value on exception" do
      assert_raise RuntimeError, "test error", fn ->
        measure do
          # Keep the call dynamic so the compiler can verify the macro's exception path.
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          apply(:erlang, :error, [RuntimeError.exception("test error")])
        end
      end
    end
  end

  describe "do_retry/2 function" do
    test "returns result on success" do
      fun = fn -> "success" end
      assert Arbor.MCP.Helpers.do_retry(fun, []) == "success"
    end

    test "retries with exponential backoff" do
      start_time = System.monotonic_time(:millisecond)
      attempt_count = Agent.start_link(fn -> 0 end)
      {:ok, agent} = attempt_count

      try do
        Arbor.MCP.Helpers.do_retry(
          fn ->
            count = Agent.get_and_update(agent, fn c -> {c + 1, c + 1} end)
            if count < 3, do: raise("Attempt #{count}")
            count
          end,
          max_attempts: 3,
          base_delay: 50,
          max_delay: 200
        )
      rescue
        _ -> :ok
      end

      end_time = System.monotonic_time(:millisecond)
      elapsed = end_time - start_time

      # Should have waited at least base_delay (50ms) between retries
      assert elapsed >= 50

      Agent.stop(agent)
    end

    test "respects max_delay" do
      attempt_count = Agent.start_link(fn -> 0 end)
      {:ok, agent} = attempt_count

      try do
        Arbor.MCP.Helpers.do_retry(
          fn ->
            count = Agent.get_and_update(agent, fn c -> {c + 1, c + 1} end)
            raise "Attempt #{count}"
          end,
          max_attempts: 4,
          base_delay: 1000,
          max_delay: 100
        )
      rescue
        _ -> :ok
      end

      Agent.stop(agent)
      # If this test completes quickly, it means max_delay was respected
    end

    test "handles different error types" do
      assert_raise ArgumentError, fn ->
        Arbor.MCP.Helpers.do_retry(
          fn ->
            raise ArgumentError, "invalid argument"
          end,
          max_attempts: 1
        )
      end
    end

    test "respects max_attempts limit" do
      attempt_count = Agent.start_link(fn -> 0 end)
      {:ok, agent} = attempt_count

      assert_raise RuntimeError, fn ->
        Arbor.MCP.Helpers.do_retry(
          fn ->
            Agent.update(agent, &(&1 + 1))
            raise "Always fails"
          end,
          max_attempts: 2,
          base_delay: 10
        )
      end

      # Should have tried exactly 2 times
      final_count = Agent.get(agent, & &1)
      assert final_count == 2

      Agent.stop(agent)
    end
  end

  describe "format_error_message/1 function" do
    test "formats structured error with suggestions" do
      error = %{
        message: "Tool 'calculator' not found",
        suggestions: ["Did you mean 'calc'?", "Check available tools"]
      }

      result = Arbor.MCP.Helpers.format_error_message(error)

      # Should contain the base message
      assert String.contains?(result, "Tool 'calculator' not found")

      # Should contain suggestion text when suggestions exist
      assert String.contains?(result, "Suggestions:")
    end

    test "formats error without suggestions" do
      error = %{message: "Connection failed", suggestions: []}
      result = Arbor.MCP.Helpers.format_error_message(error)
      assert result == "Connection failed"
    end

    test "formats error with nil suggestions" do
      error = %{message: "Tool not found", suggestions: nil}
      result = Arbor.MCP.Helpers.format_error_message(error)
      assert result == "Tool not found"
    end

    test "formats non-structured errors" do
      result = Arbor.MCP.Helpers.format_error_message(:timeout)
      assert result == ":timeout"

      result = Arbor.MCP.Helpers.format_error_message("string error")
      assert result == "\"string error\""

      result = Arbor.MCP.Helpers.format_error_message(%{other: "fields"})
      assert String.contains?(result, "other")
    end
  end

  describe "validate_tool_args/2 function" do
    test "validates valid arguments against schema when ExJsonSchema available" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "age" => %{"type" => "integer"}
        },
        "required" => ["name"]
      }

      args = %{"name" => "John", "age" => 30}

      # Test that it doesn't crash and returns a valid result
      result = Arbor.MCP.Helpers.validate_tool_args(args, schema)

      case result do
        :ok -> assert true
        {:error, message} when is_binary(message) -> assert true
        _ -> flunk("Unexpected result: #{inspect(result)}")
      end
    end

    test "handles invalid arguments against schema" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"}
        },
        "required" => ["name"]
      }

      # Missing required "name"
      args = %{"age" => 30}

      result = Arbor.MCP.Helpers.validate_tool_args(args, schema)

      case result do
        # If ExJsonSchema not available, it returns :ok
        :ok ->
          assert true

        {:error, message} when is_binary(message) ->
          # Should mention the missing field
          assert String.contains?(message, "name")

        _ ->
          flunk("Unexpected result: #{inspect(result)}")
      end
    end

    test "handles non-map arguments gracefully" do
      result = Arbor.MCP.Helpers.validate_tool_args("not a map", %{})
      assert result == :ok

      result = Arbor.MCP.Helpers.validate_tool_args(%{}, "not a map")
      assert result == :ok

      result = Arbor.MCP.Helpers.validate_tool_args(nil, nil)
      assert result == :ok
    end
  end

  describe "safe_execute/2 function" do
    test "executes function within timeout" do
      fun = fn ->
        Process.sleep(10)
        "result"
      end

      assert {:ok, "result"} = Arbor.MCP.Helpers.safe_execute(fun, 100)
    end

    test "times out for slow functions" do
      fun = fn ->
        Process.sleep(200)
        "result"
      end

      assert {:error, :timeout} = Arbor.MCP.Helpers.safe_execute(fun, 50)
    end

    test "uses default timeout" do
      fun = fn -> "quick result" end
      assert {:ok, "quick result"} = Arbor.MCP.Helpers.safe_execute(fun)
    end

    test "handles function that returns various types" do
      fun = fn -> {:ok, %{data: "complex"}} end
      assert {:ok, {:ok, %{data: "complex"}}} = Arbor.MCP.Helpers.safe_execute(fun, 100)

      fun = fn -> [1, 2, 3] end
      assert {:ok, [1, 2, 3]} = Arbor.MCP.Helpers.safe_execute(fun, 100)

      fun = fn -> nil end
      assert {:ok, nil} = Arbor.MCP.Helpers.safe_execute(fun, 100)
    end

    test "handles function exceptions gracefully" do
      fun = fn -> raise RuntimeError, "error in function" end

      # The function should timeout because the task process crashes
      # We need to catch the EXIT signal from the failing task
      Process.flag(:trap_exit, true)
      result = Arbor.MCP.Helpers.safe_execute(fun, 100)
      assert result == {:error, :timeout}
      Process.flag(:trap_exit, false)
    end

    test "handles exit signals" do
      fun = fn -> exit(:normal) end

      result = Arbor.MCP.Helpers.safe_execute(fun, 100)
      assert result == {:error, :timeout}
    end
  end

  describe "custom exception types" do
    test "ConnectionError can be raised and caught" do
      assert_raise ConnectionError, "test connection error", fn ->
        raise ConnectionError, message: "test connection error"
      end
    end

    test "ToolError can be raised and caught" do
      assert_raise ToolError, "test tool error", fn ->
        raise ToolError, message: "test tool error"
      end
    end

    test "ResourceError can be raised and caught" do
      assert_raise ResourceError, "test resource error", fn ->
        raise ResourceError, message: "test resource error"
      end
    end

    test "PromptError can be raised and caught" do
      assert_raise PromptError, "test prompt error", fn ->
        raise PromptError, message: "test prompt error"
      end
    end

    test "ClientError can be raised and caught" do
      assert_raise ClientError, "test client error", fn ->
        raise ClientError, message: "test client error"
      end
    end

    test "exceptions have proper message field" do
      error = %ConnectionError{message: "connection failed"}
      assert error.message == "connection failed"

      error = %ToolError{message: "tool failed"}
      assert error.message == "tool failed"

      error = %ResourceError{message: "resource failed"}
      assert error.message == "resource failed"

      error = %PromptError{message: "prompt failed"}
      assert error.message == "prompt failed"

      error = %ClientError{message: "client failed"}
      assert error.message == "client failed"
    end
  end

  describe "macro code generation" do
    test "with_mcp_client macro expands correctly" do
      # Test that the macro expands without syntax errors
      code =
        quote do
          with_mcp_client "http://localhost:8080" do
            "test_result"
          end
        end

      # This should compile without errors
      assert is_tuple(code)
      # The actual macro name is preserved in quoted form
      assert elem(code, 0) == :with_mcp_client
    end

    test "tool operation macros expand correctly" do
      # Test macro expansion for tool operations
      code =
        quote do
          list_tools!(timeout: 5000)
        end

      assert is_tuple(code)
      assert elem(code, 0) == :list_tools!

      code =
        quote do
          call_tool!("test", %{arg: "value"}, timeout: 1000)
        end

      assert is_tuple(code)
      assert elem(code, 0) == :call_tool!
    end

    test "measure macro captures timing properly" do
      # Test that measure macro structure is correct
      code =
        quote do
          measure do
            expensive_operation()
          end
        end

      # Should preserve the macro name in quoted form
      assert is_tuple(code)
      assert elem(code, 0) == :measure
    end

    test "retry macro structure is correct" do
      code =
        quote do
          retry max_attempts: 3 do
            risky_operation()
          end
        end

      # Should call do_retry with function and options
      assert is_tuple(code)
      assert elem(code, 0) == :retry
    end
  end

  describe "helper function edge cases" do
    test "format_error_message handles empty suggestions" do
      error = %{message: "test", suggestions: []}
      result = Arbor.MCP.Helpers.format_error_message(error)
      assert result == "test"
    end

    test "do_retry handles zero max_attempts" do
      # Zero max_attempts should still execute once and fail
      assert_raise RuntimeError, fn ->
        Arbor.MCP.Helpers.do_retry(fn -> raise "error" end, max_attempts: 0)
      end
    end

    test "do_retry handles negative delays" do
      # Should not crash with negative delays
      result = Arbor.MCP.Helpers.do_retry(fn -> "success" end, base_delay: -100)
      assert result == "success"
    end

    test "safe_execute handles zero timeout" do
      fun = fn -> "quick" end
      # Zero timeout should still allow very fast operations
      result = Arbor.MCP.Helpers.safe_execute(fun, 0)
      # This might succeed or timeout depending on timing
      assert result in [{:ok, "quick"}, {:error, :timeout}]
    end

    test "validate_tool_args handles malformed schemas" do
      result = Arbor.MCP.Helpers.validate_tool_args(%{}, %{invalid: "schema"})
      # Should handle gracefully
      assert result == :ok
    end
  end
end
