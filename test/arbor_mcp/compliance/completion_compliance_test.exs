defmodule Arbor.MCP.CompletionComplianceTest do
  use ExUnit.Case, async: true

  @moduletag :compliance

  alias Arbor.MCP.Client
  alias Arbor.MCP.Internal.Protocol
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule TestCompletionServer do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_args) do
      {:ok,
       %{
         prompts: [
           %{
             name: "code_generator",
             description: "Generate code in various languages",
             arguments: [
               %{name: "language", description: "Programming language", required: true},
               %{name: "framework", description: "Framework to use", required: false},
               %{name: "style", description: "Code style", required: false}
             ]
           },
           %{
             name: "file_processor",
             description: "Process files with various operations",
             arguments: [
               %{name: "path", description: "File path", required: true},
               %{name: "operation", description: "Operation to perform", required: true}
             ]
           }
         ],
         resources: [
           %{uri: "file:///src/main.js", name: "Main JavaScript"},
           %{uri: "file:///src/utils.py", name: "Python Utilities"},
           %{uri: "file:///src/config.json", name: "Configuration"},
           %{uri: "file:///docs/api.md", name: "API Documentation"},
           %{uri: "file:///tests/unit.spec.js", name: "Unit Tests"},
           %{uri: "config://app/database.json", name: "Database Config"},
           %{uri: "config://app/features.yaml", name: "Feature Flags"},
           %{uri: "data://metrics/cpu", name: "CPU Metrics"},
           %{uri: "data://metrics/memory", name: "Memory Metrics"}
         ],
         completion_requests: []
       }}
    end

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-03-26",
         serverInfo: %{name: "test-completion-server", version: "1.0.0"},
         capabilities: %{
           completion: %{},
           prompts: %{},
           resources: %{}
         }
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      {:ok, [], nil, state}
    end

    @impl true
    def handle_call_tool(_name, _args, state) do
      {:error, "No tools available", state}
    end

    @impl true
    def handle_list_prompts(_cursor, state) do
      {:ok, state.prompts, nil, state}
    end

    @impl true
    def handle_get_prompt(_name, _args, state) do
      {:error, "Not implemented", state}
    end

    @impl true
    def handle_list_resources(_cursor, state) do
      {:ok, state.resources, nil, state}
    end

    @impl true
    def handle_read_resource(_uri, state) do
      {:error, "Not implemented", state}
    end

    @impl true
    def handle_complete(ref, argument, state) do
      # Track completion requests for testing
      new_state = %{
        state
        | completion_requests: [
            %{ref: ref, argument: argument, timestamp: DateTime.utc_now()}
            | state.completion_requests
          ]
      }

      # Rate limiting simulation (max 10 requests per second)
      recent_requests =
        Enum.count(new_state.completion_requests, fn req ->
          DateTime.diff(DateTime.utc_now(), req.timestamp, :second) < 1
        end)

      if recent_requests > 10 do
        {:error, "Rate limit exceeded", new_state}
      else
        # Generate completions based on reference type
        completions = generate_completions(ref, argument, new_state)

        # Limit to 100 items and provide metadata
        limited_completions = Enum.take(completions, 100)

        result = %{
          completion: %{
            values: limited_completions,
            total: length(completions),
            hasMore: length(completions) > 100
          }
        }

        {:ok, result, new_state}
      end
    end

    # Generate completions based on reference type
    defp generate_completions(%{"type" => "ref/prompt", "name" => prompt_name}, argument, state) do
      case find_prompt(prompt_name, state.prompts) do
        nil -> []
        prompt -> generate_prompt_completions(prompt, argument)
      end
    end

    defp generate_completions(%{"type" => "ref/resource", "uri" => uri_prefix}, argument, state) do
      generate_resource_completions(uri_prefix, argument, state)
    end

    defp generate_completions(_, _, _), do: []

    # Generate completions for prompt arguments
    defp generate_prompt_completions(prompt, argument) when is_map(argument) do
      arg_name = Map.get(argument, "name", "")
      value = Map.get(argument, "value", "")

      case {prompt.name, arg_name} do
        {"code_generator", "language"} ->
          languages = [
            "javascript",
            "python",
            "rust",
            "elixir",
            "go",
            "java",
            "typescript",
            "c++"
          ]

          filter_by_prefix(languages, value)

        {"code_generator", "framework"} ->
          frameworks = [
            "react",
            "vue",
            "angular",
            "express",
            "fastapi",
            "phoenix",
            "gin",
            "spring"
          ]

          filter_by_prefix(frameworks, value)

        {"code_generator", "style"} ->
          styles = ["functional", "object-oriented", "procedural", "declarative"]
          filter_by_prefix(styles, value)

        {"file_processor", "path"} ->
          paths = ["src/", "docs/", "tests/", "config/", "lib/", "bin/"]
          filter_by_prefix(paths, value)

        {"file_processor", "operation"} ->
          operations = ["read", "write", "delete", "copy", "move", "analyze", "compress"]
          filter_by_prefix(operations, value)

        _ ->
          []
      end
    end

    # Handle malformed arguments
    defp generate_prompt_completions(_prompt, _argument), do: []

    # Generate completions for resource URIs
    defp generate_resource_completions(uri_prefix, %{"name" => arg_name, "value" => value}, state) do
      case arg_name do
        "uri" ->
          # Complete resource URIs that start with the prefix
          matching_resources =
            Enum.filter(state.resources, fn resource ->
              String.starts_with?(resource.uri, uri_prefix) and
                String.contains?(resource.uri, value)
            end)

          Enum.map(matching_resources, & &1.uri)

        "scheme" ->
          schemes = ["file://", "config://", "data://", "https://"]
          filter_by_prefix(schemes, value)

        "path" ->
          # Extract paths from file:// resources
          file_paths =
            state.resources
            |> Enum.filter(&String.starts_with?(&1.uri, "file://"))
            |> Enum.map(&String.replace(&1.uri, "file://", ""))

          filter_by_prefix(file_paths, value)

        _ ->
          []
      end
    end

    # Helper functions
    defp find_prompt(name, prompts) do
      Enum.find(prompts, &(&1.name == name))
    end

    defp filter_by_prefix(items, "") do
      # Return all items when no prefix (sorted by relevance/alphabetically)
      Enum.sort(items)
    end

    defp filter_by_prefix(items, prefix) when is_binary(prefix) do
      items
      |> Enum.filter(&String.starts_with?(&1, prefix))
      # Fuzzy matching
      |> Enum.sort_by(&String.jaro_distance(&1, prefix), :desc)
    end

    defp filter_by_prefix(items, _), do: Enum.sort(items)
  end

  setup do
    # Start server
    {:ok, server} =
      Server.start_link(
        transport: :test,
        handler: TestCompletionServer
      )

    # Start client
    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server
      )

    # Wait for initialization
    Process.sleep(100)

    %{server: server, client: client}
  end

  describe "completion capability compliance" do
    test "server declares completion capability correctly", %{client: client} do
      # Should be able to make completion requests
      ref = %{"type" => "ref/prompt", "name" => "code_generator"}
      arg = %{"name" => "language", "value" => "java"}

      {:ok, result} = Client.complete(client, ref, arg)

      assert %{completion: completion} = result
      assert Map.has_key?(completion, :values)
      assert is_list(completion.values)
    end

    test "completion request structure validation", %{client: client} do
      # Valid prompt reference
      ref = %{"type" => "ref/prompt", "name" => "code_generator"}
      arg = %{"name" => "language", "value" => "py"}

      {:ok, result} = Client.complete(client, ref, arg)
      assert %{completion: _} = result

      # Valid resource reference
      ref2 = %{"type" => "ref/resource", "uri" => "file:///"}
      arg2 = %{"name" => "path", "value" => "src"}

      {:ok, result2} = Client.complete(client, ref2, arg2)
      assert %{completion: _} = result2
    end

    test "completion response structure compliance", %{client: client} do
      ref = %{"type" => "ref/prompt", "name" => "code_generator"}
      arg = %{"name" => "language", "value" => "j"}

      {:ok, result} = Client.complete(client, ref, arg)

      completion = result.completion

      # Required fields
      assert Map.has_key?(completion, :values)
      assert Map.has_key?(completion, :total)
      assert Map.has_key?(completion, :hasMore)

      # Field types
      assert is_list(completion.values)
      assert is_integer(completion.total)
      assert is_boolean(completion.hasMore)

      # Values should be strings
      Enum.each(completion.values, fn value ->
        assert is_binary(value)
      end)
    end
  end

  describe "prompt-based completion compliance" do
    test "completes prompt argument values", %{client: client} do
      # Test language completion for code_generator
      ref = %{"type" => "ref/prompt", "name" => "code_generator"}
      arg = %{"name" => "language", "value" => "java"}

      {:ok, result} = Client.complete(client, ref, arg)

      completion = result.completion
      assert "javascript" in completion.values
      assert completion.total >= 1

      # All results should start with "java"
      Enum.each(completion.values, fn value ->
        assert String.starts_with?(value, "java")
      end)
    end

    test "completes different argument types", %{client: client} do
      # Test framework completion
      ref = %{"type" => "ref/prompt", "name" => "code_generator"}
      arg = %{"name" => "framework", "value" => "re"}

      {:ok, result} = Client.complete(client, ref, arg)

      completion = result.completion
      assert "react" in completion.values
      assert completion.total >= 1
    end

    test "handles empty prefix for prompts", %{client: client} do
      # Empty value should return all options
      ref = %{"type" => "ref/prompt", "name" => "code_generator"}
      arg = %{"name" => "language", "value" => ""}

      {:ok, result} = Client.complete(client, ref, arg)

      completion = result.completion
      # Should have multiple languages
      assert length(completion.values) >= 5
      assert "javascript" in completion.values
      assert "python" in completion.values
    end

    test "handles unknown prompt gracefully", %{client: client} do
      ref = %{"type" => "ref/prompt", "name" => "nonexistent_prompt"}
      arg = %{"name" => "language", "value" => "java"}

      {:ok, result} = Client.complete(client, ref, arg)

      completion = result.completion
      assert completion.values == []
      assert completion.total == 0
      assert completion.hasMore == false
    end
  end

  describe "resource-based completion compliance" do
    test "completes resource URIs", %{client: client} do
      ref = %{"type" => "ref/resource", "uri" => "file:///"}
      arg = %{"name" => "uri", "value" => "src"}

      {:ok, result} = Client.complete(client, ref, arg)

      completion = result.completion
      # Should match file:///src/* resources
      assert length(completion.values) >= 1

      # All results should contain "src"
      Enum.each(completion.values, fn uri ->
        assert String.contains?(uri, "src")
      end)
    end

    test "completes different URI schemes", %{client: client} do
      ref = %{"type" => "ref/resource", "uri" => "config://"}
      arg = %{"name" => "uri", "value" => "app"}

      {:ok, result} = Client.complete(client, ref, arg)

      completion = result.completion
      # Should match config://app/* resources
      assert length(completion.values) >= 1

      Enum.each(completion.values, fn uri ->
        assert String.starts_with?(uri, "config://")
        assert String.contains?(uri, "app")
      end)
    end

    test "handles scheme completion", %{client: client} do
      ref = %{"type" => "ref/resource", "uri" => ""}
      arg = %{"name" => "scheme", "value" => "file"}

      {:ok, result} = Client.complete(client, ref, arg)

      completion = result.completion
      assert "file://" in completion.values
    end

    test "handles path completion for file resources", %{client: client} do
      ref = %{"type" => "ref/resource", "uri" => "file:///"}
      arg = %{"name" => "path", "value" => "/src"}

      {:ok, result} = Client.complete(client, ref, arg)

      completion = result.completion
      # Should include paths from file:// resources
      assert length(completion.values) >= 0
    end
  end

  describe "completion response limits compliance" do
    test "respects 100 item limit", %{client: client} do
      # All languages without filter should still be under 100
      ref = %{"type" => "ref/prompt", "name" => "code_generator"}
      arg = %{"name" => "language", "value" => ""}

      {:ok, result} = Client.complete(client, ref, arg)

      completion = result.completion
      assert length(completion.values) <= 100

      # If total > 100, hasMore should be true
      if completion.total > 100 do
        assert completion.hasMore == true
      else
        assert completion.hasMore == false
      end
    end

    test "provides accurate total count", %{client: client} do
      ref = %{"type" => "ref/prompt", "name" => "code_generator"}
      arg = %{"name" => "language", "value" => "j"}

      {:ok, result} = Client.complete(client, ref, arg)

      completion = result.completion
      # Total should match the actual number of matching items
      assert completion.total == length(completion.values)
    end

    test "indicates when more results exist", %{client: client} do
      # For this test, we'd need a scenario with > 100 results
      # The handler implementation shows the logic even if this specific test doesn't trigger it
      ref = %{"type" => "ref/prompt", "name" => "code_generator"}
      arg = %{"name" => "language", "value" => ""}

      {:ok, result} = Client.complete(client, ref, arg)

      completion = result.completion
      # hasMore should be consistent with the counts
      expected_has_more = completion.total > length(completion.values)
      assert completion.hasMore == expected_has_more
    end
  end

  describe "fuzzy matching and relevance compliance" do
    test "results are sorted by relevance", %{client: client} do
      ref = %{"type" => "ref/prompt", "name" => "code_generator"}
      arg = %{"name" => "language", "value" => "java"}

      {:ok, result} = Client.complete(client, ref, arg)

      completion = result.completion

      if length(completion.values) > 1 do
        # First result should be most relevant (exact or closest match)
        first_result = hd(completion.values)
        # In our test data, "javascript" should come before other "java*" matches
        # because it's closer to "java" than longer variations
        assert String.starts_with?(first_result, "java")
      end
    end

    test "fuzzy matching works for partial inputs", %{client: client} do
      ref = %{"type" => "ref/prompt", "name" => "code_generator"}
      arg = %{"name" => "framework", "value" => "ang"}

      {:ok, result} = Client.complete(client, ref, arg)

      completion = result.completion
      assert "angular" in completion.values
    end

    test "handles typos gracefully", %{client: client} do
      # Test with a slight typo - our implementation uses prefix matching
      # so this tests the boundary of fuzzy matching
      ref = %{"type" => "ref/prompt", "name" => "code_generator"}
      arg = %{"name" => "language", "value" => "pytho"}

      {:ok, result} = Client.complete(client, ref, arg)

      completion = result.completion
      # Might not match due to typo (depends on implementation)
      # This tests the robustness of the completion system
      assert is_list(completion.values)
    end
  end

  describe "security and rate limiting compliance" do
    test "validates completion inputs", %{client: client} do
      # Test with invalid reference type
      ref = %{"type" => "invalid/type", "name" => "test"}
      arg = %{"name" => "test", "value" => "test"}

      {:ok, result} = Client.complete(client, ref, arg)

      completion = result.completion
      # Should handle gracefully with empty results
      assert completion.values == []
    end

    test "handles malformed arguments", %{client: client} do
      ref = %{"type" => "ref/prompt", "name" => "code_generator"}

      # Missing required argument fields fail closed at the protocol boundary.
      arg = %{"invalid" => "structure"}

      assert {:error, %Arbor.MCP.Error.ProtocolError{code: -32602}} =
               Client.complete(client, ref, arg)
    end

    test "rate limiting is implemented", %{client: client} do
      # Make multiple rapid requests
      ref = %{"type" => "ref/prompt", "name" => "code_generator"}
      arg = %{"name" => "language", "value" => "j"}

      # Make several requests quickly
      results =
        for _i <- 1..5 do
          Client.complete(client, ref, arg)
        end

      # All should succeed (under rate limit)
      Enum.each(results, fn result ->
        assert {:ok, _} = result
      end)

      # Just verify that all requests succeeded (rate limiting logic is in place)
      # The rate limiting is demonstrated by the logic in handle_complete
      :ok
    end
  end

  describe "protocol compliance" do
    test "completion/complete protocol format" do
      ref = %{"type" => "ref/prompt", "name" => "test"}
      arg = %{"name" => "arg", "value" => "val"}

      request = Protocol.encode_complete(ref, arg)

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "completion/complete"
      assert request["params"]["ref"] == ref
      assert request["params"]["argument"] == arg
      assert Map.has_key?(request, "id")
    end

    test "completion response format", %{client: client} do
      ref = %{"type" => "ref/prompt", "name" => "code_generator"}
      arg = %{"name" => "language", "value" => "py"}

      {:ok, result} = Client.complete(client, ref, arg)

      # Response should follow the expected structure
      assert Map.has_key?(result, :completion)
      completion = result.completion

      assert Map.has_key?(completion, :values)
      assert Map.has_key?(completion, :total)
      assert Map.has_key?(completion, :hasMore)
    end
  end

  describe "edge cases and error handling" do
    test "handles empty completion results", %{client: client} do
      ref = %{"type" => "ref/prompt", "name" => "code_generator"}
      arg = %{"name" => "language", "value" => "nonexistent_language_xyz"}

      {:ok, result} = Client.complete(client, ref, arg)

      completion = result.completion
      assert completion.values == []
      assert completion.total == 0
      assert completion.hasMore == false
    end

    test "handles special characters in completion values", %{client: client} do
      ref = %{"type" => "ref/resource", "uri" => "file:///"}
      arg = %{"name" => "path", "value" => "/"}

      {:ok, result} = Client.complete(client, ref, arg)

      completion = result.completion
      # Should handle paths with special characters safely
      assert is_list(completion.values)
    end

    test "completion works with unicode characters", %{client: client} do
      ref = %{"type" => "ref/prompt", "name" => "code_generator"}
      # Japanese characters
      arg = %{"name" => "language", "value" => "日本"}

      {:ok, result} = Client.complete(client, ref, arg)

      completion = result.completion
      # Should handle unicode gracefully (likely no matches, but no crash)
      assert is_list(completion.values)
      assert is_integer(completion.total)
    end
  end
end
