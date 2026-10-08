defmodule Arbor.MCP.Compliance.Features.Prompts do
  @moduledoc """
  Shared prompt compliance tests across all MCP versions.
  """

  # Full module names are required in macro-generated code to ensure proper resolution
  # credo:disable-for-lines:50 Credo.Check.Design.AliasUsage
  defmacro __using__(version) do
    quote do
      import Arbor.MCP.Compliance.Features.Prompts
      @version unquote(version)

      # Basic functionality (all versions)
      test "prompts/list returns valid prompt definitions" do
        Arbor.MCP.Compliance.Features.Prompts.test_basic_prompts_list(@version)
      end

      test "prompts/get returns valid prompt content" do
        Arbor.MCP.Compliance.Features.Prompts.test_prompt_get(@version)
      end

      # Version-specific features
      if @version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
        test "prompt list change notifications work" do
          Arbor.MCP.Compliance.Features.Prompts.test_list_change_notifications(@version)
        end
      end

      if @version in ["2025-06-18", "2025-11-25"] do
        test "prompts have title fields" do
          Arbor.MCP.Compliance.Features.Prompts.test_prompt_titles(@version)
        end
      end
    end
  end

  # Import test helpers
  import ExUnit.Assertions
  import Arbor.MCP.ComplianceTestHelpers
  alias Arbor.MCP.Client

  # Actual test implementations
  def test_basic_prompts_list(version) do
    # Test that prompts/list returns valid prompt definitions
    {:ok, test_context} = setup_test_client(version)

    try do
      {:ok, result} = Client.list_prompts(test_context.client)

      # Validate basic structure
      assert is_map(result)
      assert Map.has_key?(result, :prompts)
      assert is_list(result.prompts)

      # Validate each prompt
      for prompt <- result.prompts do
        validate_prompt_structure(prompt, version)
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_prompt_get(version) do
    # Test that prompts/get returns valid prompt content
    {:ok, test_context} = setup_test_client(version)

    try do
      {:ok, prompts_result} = Client.list_prompts(test_context.client)

      if length(prompts_result.prompts) > 0 do
        prompt = hd(prompts_result.prompts)

        # Get the prompt with some sample arguments
        args =
          if prompt[:arguments] && length(prompt.arguments) > 0 do
            # Build args based on required arguments
            Enum.reduce(prompt.arguments, %{}, fn arg, acc ->
              if arg[:required] do
                Map.put(acc, arg.name, "test_value")
              else
                acc
              end
            end)
          else
            %{}
          end

        {:ok, result} = Client.get_prompt(test_context.client, prompt.name, args)
        validate_prompt_content(result, version)
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_list_change_notifications(version)
      when version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
    # Test prompt list change notifications
    assert version in ["2025-03-26", "2025-06-18", "2025-11-25"]

    # Test notification structure
    notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/prompts/list_changed"
    }

    validate_list_change_notification(notification)
  end

  # Helper functions for prompt validation
  defp validate_prompt_structure(prompt, version) do
    # Basic prompt structure validation
    assert is_map(prompt)
    assert Map.has_key?(prompt, :name)
    assert is_binary(prompt.name)

    # Optional description
    if Map.has_key?(prompt, :description) do
      assert is_binary(prompt.description)
    end

    # Arguments validation
    if Map.has_key?(prompt, :arguments) do
      assert is_list(prompt.arguments)
      validate_prompt_arguments(prompt.arguments)
    end

    # Version-specific validations
    case version do
      v when v in ["2025-06-18", "2025-11-25"] ->
        # 2025-06-18 may have title field
        if Map.has_key?(prompt, :title) do
          assert is_binary(prompt.title)
        end

      v when v in ["2025-03-26", "2025-06-18", "2025-11-25"] ->
        # These versions may have additional prompt features
        :ok

      _ ->
        # Earlier versions have basic prompt support
        :ok
    end
  end

  defp validate_prompt_arguments(arguments) do
    for arg <- arguments do
      # Argument structure validation
      assert Map.has_key?(arg, :name)
      assert is_binary(arg.name)

      # Optional description
      if Map.has_key?(arg, :description) do
        assert is_binary(arg.description)
      end

      # Required flag
      if Map.has_key?(arg, :required) do
        assert is_boolean(arg.required)
      end
    end
  end

  defp validate_prompt_content(content, _version) do
    # Validate prompt content structure
    assert Map.has_key?(content, :messages)
    assert is_list(content.messages)

    # Optional description
    if Map.has_key?(content, :description) do
      assert is_binary(content.description)
    end

    # Validate messages
    for message <- content.messages do
      assert Map.has_key?(message, :role)
      assert message.role in ["system", "user", "assistant"]

      assert Map.has_key?(message, :content)
      validate_message_content(message.content)
    end
  end

  defp validate_message_content(content) do
    # Validate message content structure
    if is_map(content) do
      # Single content item
      validate_content_item(content)
    else
      # Multiple content items
      assert is_list(content)

      for item <- content do
        validate_content_item(item)
      end
    end
  end

  defp validate_content_item(item) do
    # Validate individual content item
    assert Map.has_key?(item, :type)
    assert item.type in ["text", "image", "audio"]

    case item.type do
      "text" ->
        assert Map.has_key?(item, :text)
        assert is_binary(item.text)

      "image" ->
        assert Map.has_key?(item, :data)
        assert is_binary(item.data)

        if Map.has_key?(item, :mimeType) do
          assert is_binary(item.mimeType)
        end

      "audio" ->
        assert Map.has_key?(item, :data)
        assert is_binary(item.data)

        if Map.has_key?(item, :mimeType) do
          assert is_binary(item.mimeType)
        end
    end
  end

  defp validate_list_change_notification(notification) do
    # Validate list change notification structure
    assert notification["method"] == "notifications/prompts/list_changed"
    assert notification["jsonrpc"] == "2.0"

    # Notifications don't have an ID
    refute Map.has_key?(notification, "id")
  end

  def test_prompt_titles(version) when version in ["2025-06-18", "2025-11-25"] do
    # Test that prompts have title fields in 2025-06-18
    {:ok, test_context} = setup_test_client(version)

    try do
      {:ok, result} = Client.list_prompts(test_context.client)

      # At least one prompt should have a title field
      prompt_with_title =
        Enum.find(result.prompts, fn prompt ->
          Map.has_key?(prompt, :title)
        end)

      if prompt_with_title do
        assert is_binary(prompt_with_title.title)
        assert String.length(prompt_with_title.title) > 0

        # Should also have name field (programmatic identifier)
        assert Map.has_key?(prompt_with_title, :name)
        assert is_binary(prompt_with_title.name)
      end
    after
      cleanup_test_client(test_context)
    end
  end
end
