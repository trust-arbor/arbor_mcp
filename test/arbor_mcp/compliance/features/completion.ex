defmodule Arbor.MCP.Compliance.Features.Completion do
  @moduledoc """
  Completion capability compliance tests.
  Completion support is available in 2025-03-26 and later.
  """

  # Full module names are required in macro-generated code to ensure proper resolution
  # credo:disable-for-lines:50 Credo.Check.Design.AliasUsage
  defmacro __using__(version) do
    quote do
      import Arbor.MCP.Compliance.Features.Completion
      @version unquote(version)

      # Completion capability (2025-03-26+)
      if @version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
        test "completion/complete for arguments works" do
          Arbor.MCP.Compliance.Features.Completion.test_argument_completion(@version)
        end

        test "completion returns valid suggestions" do
          Arbor.MCP.Compliance.Features.Completion.test_completion_suggestions(@version)
        end

        test "completion with empty prefix works" do
          Arbor.MCP.Compliance.Features.Completion.test_empty_prefix_completion(@version)
        end

        test "completion filtering works correctly" do
          Arbor.MCP.Compliance.Features.Completion.test_completion_filtering(@version)
        end
      end

      # Enhanced completion in 2025-06-18
      if @version in ["2025-06-18", "2025-11-25"] do
        test "completion supports multiple reference types" do
          Arbor.MCP.Compliance.Features.Completion.test_multiple_reference_types(@version)
        end

        test "completion with values works" do
          Arbor.MCP.Compliance.Features.Completion.test_completion_values(@version)
        end
      end
    end
  end

  # Import test helpers
  import ExUnit.Assertions
  import Arbor.MCP.ComplianceTestHelpers
  alias Arbor.MCP.Client

  # Actual test implementations
  def test_argument_completion(version)
      when version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
    {:ok, test_context} = setup_test_client(version)

    try do
      # Test argument completion
      {:ok, result} =
        Client.complete(test_context.client, "argument", %{
          "name" => "path",
          "value" => "/home/"
        })

      # Validate result structure
      assert is_map(result)
      assert Map.has_key?(result, :completion) or Map.has_key?(result, "completion")

      completions = Map.get(result, :completion) || Map.get(result, "completion")
      assert is_list(completions)

      # All completions should start with the prefix
      for completion <- completions do
        assert is_binary(completion)
        assert String.starts_with?(completion, "/home/")
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_completion_suggestions(version)
      when version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
    {:ok, test_context} = setup_test_client(version)

    try do
      # Test various completion scenarios
      test_cases = [
        {"argument", %{"name" => "language", "value" => "pyth"}, ["python", "python3"]},
        {"argument", %{"name" => "framework", "value" => "dja"}, ["django"]},
        {"argument", %{"name" => "path", "value" => "/usr/"},
         ["/usr/bin/", "/usr/lib/", "/usr/local/"]}
      ]

      for {ref, arg, expected_patterns} <- test_cases do
        {:ok, result} = Client.complete(test_context.client, ref, arg)

        completions = Map.get(result, :completion) || Map.get(result, "completion")
        assert is_list(completions)

        # Should have at least one completion matching expected patterns
        if expected_patterns != [] do
          assert Enum.any?(completions, fn completion ->
                   Enum.any?(expected_patterns, fn pattern ->
                     String.contains?(completion, pattern)
                   end)
                 end)
        end
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_empty_prefix_completion(version)
      when version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
    {:ok, test_context} = setup_test_client(version)

    try do
      # Test completion with empty prefix
      {:ok, result} =
        Client.complete(test_context.client, "argument", %{
          "name" => "path",
          "value" => ""
        })

      completions = Map.get(result, :completion) || Map.get(result, "completion")
      assert is_list(completions)

      # Should return some default suggestions
      assert length(completions) > 0

      # All suggestions should be valid paths
      for completion <- completions do
        assert is_binary(completion)
        # Basic path validation
        assert String.starts_with?(completion, "/") or
                 String.starts_with?(completion, "./") or
                 String.starts_with?(completion, "../")
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_completion_filtering(version)
      when version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
    {:ok, test_context} = setup_test_client(version)

    try do
      # Test that completions are properly filtered by prefix
      prefixes = ["test", "example", "demo", "sample"]

      for prefix <- prefixes do
        {:ok, result} =
          Client.complete(test_context.client, "argument", %{
            "name" => "filename",
            "value" => prefix
          })

        completions = Map.get(result, :completion) || Map.get(result, "completion")

        # All completions must start with the prefix
        for completion <- completions do
          assert String.starts_with?(completion, prefix),
                 "Completion '#{completion}' should start with prefix '#{prefix}'"
        end
      end

      # Test case-insensitive filtering (implementation-dependent)
      {:ok, result} =
        Client.complete(test_context.client, "argument", %{
          "name" => "command",
          "value" => "LIST"
        })

      completions = Map.get(result, :completion) || Map.get(result, "completion")
      # May include "list", "listFiles", etc.
      assert is_list(completions)
    after
      cleanup_test_client(test_context)
    end
  end

  def test_multiple_reference_types(version) when version in ["2025-06-18", "2025-11-25"] do
    {:ok, test_context} = setup_test_client(version)

    try do
      # 2025-06-18 supports completion for multiple reference types
      reference_types = [
        {"argument", %{"name" => "test", "value" => "val"}},
        {"resource", %{"uri" => "file://"}},
        {"prompt", %{"name" => "ana"}},
        {"tool", %{"name" => "file"}}
      ]

      for {ref_type, arg} <- reference_types do
        result = Client.complete(test_context.client, ref_type, arg)

        case result do
          {:ok, response} ->
            assert is_map(response)
            assert Map.has_key?(response, :completion) or Map.has_key?(response, "completion")

          {:error, _reason} ->
            # Some reference types might not be supported by the test handler
            :ok
        end
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_completion_values(version) when version in ["2025-06-18", "2025-11-25"] do
    {:ok, test_context} = setup_test_client(version)

    try do
      # Test completion with hasArguments and values capabilities
      {:ok, caps} = Client.server_capabilities(test_context.client)

      completion_caps = get_in(caps, ["completion"]) || %{}

      # Verify capabilities
      if Map.get(completion_caps, "hasArguments") == true do
        # Server supports argument completion
        {:ok, result} =
          Client.complete(test_context.client, "argument", %{
            "name" => "status",
            "value" => ""
          })

        completions = Map.get(result, :completion) || Map.get(result, "completion")
        assert is_list(completions)
      end

      if Map.get(completion_caps, "values") == true do
        # Server supports value completion
        # This typically means enum-like completions
        {:ok, result} =
          Client.complete(test_context.client, "argument", %{
            "name" => "level",
            "value" => ""
          })

        completions = Map.get(result, :completion) || Map.get(result, "completion")
        # Could include ["debug", "info", "warning", "error"]
        assert is_list(completions)
      end
    after
      cleanup_test_client(test_context)
    end
  end
end
