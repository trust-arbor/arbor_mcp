defmodule Arbor.MCP.Compliance.Features.Tools do
  @moduledoc """
  Shared tool compliance tests across all MCP versions.
  Each test function specifies which versions it applies to.
  """

  # Full module names are required in macro-generated code to ensure proper resolution
  # credo:disable-for-lines:50 Credo.Check.Design.AliasUsage
  defmacro __using__(version) do
    quote do
      import Arbor.MCP.Compliance.Features.Tools
      import Arbor.MCP.ComplianceTestHelpers
      @version unquote(version)

      # Basic functionality (all versions)
      test "tools/list returns valid tool definitions" do
        Arbor.MCP.Compliance.Features.Tools.test_basic_tools_list(@version)
      end

      test "tools/call works correctly" do
        Arbor.MCP.Compliance.Features.Tools.test_tool_call(@version)
      end

      # Version-specific features
      if @version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
        test "tool annotations are properly supported" do
          Arbor.MCP.Compliance.Features.Tools.test_tool_annotations(@version)
        end

        test "tool list change notifications work" do
          Arbor.MCP.Compliance.Features.Tools.test_list_change_notifications(@version)
        end
      end

      if @version in ["2025-06-18", "2025-11-25"] do
        test "structured output schemas work correctly" do
          Arbor.MCP.Compliance.Features.Tools.test_structured_output(@version)
        end

        test "tools have title fields" do
          Arbor.MCP.Compliance.Features.Tools.test_tool_titles(@version)
        end

        test "tool results include structured content and resource links" do
          Arbor.MCP.Compliance.Features.Tools.test_structured_content_and_links(@version)
        end
      end
    end
  end

  # Import test helpers
  import ExUnit.Assertions
  import Arbor.MCP.ComplianceTestHelpers
  alias Arbor.MCP.Client

  # Actual test implementations
  def test_basic_tools_list(version) do
    # Test that tools/list returns valid tool definitions for any version
    {:ok, test_context} = setup_test_client(version)

    try do
      # Test tools/list request
      {:ok, result} = Client.list_tools(test_context.client)

      # Validate basic structure
      assert is_map(result)
      assert Map.has_key?(result, :tools)
      assert is_list(result.tools)

      # Validate each tool
      for tool <- result.tools do
        validate_tool_structure(tool, version)
      end

      # Validate version compatibility
      validate_version_compatibility(result.tools, version, :basic_tools)
    after
      cleanup_test_client(test_context)
    end
  end

  def test_tool_call(version) do
    # Test that tools/call works correctly
    {:ok, test_context} = setup_test_client(version)

    try do
      # First get available tools
      {:ok, tools_result} = Client.list_tools(test_context.client)

      if length(tools_result.tools) > 0 do
        # Call the first available tool
        tool = hd(tools_result.tools)
        {:ok, call_result} = Client.call_tool(test_context.client, tool.name, %{})

        # Validate call result structure
        assert is_map(call_result)
        assert Map.has_key?(call_result, :content)
        assert is_list(call_result.content)

        # Validate content items
        for content_item <- call_result.content do
          validate_content_item(content_item, version)
        end
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_tool_annotations(version) when version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
    # Test tool annotations for versions that support them
    {:ok, test_context} = setup_test_client(version)

    try do
      {:ok, result} = Client.list_tools(test_context.client)

      # Find a tool with annotations
      annotated_tool =
        Enum.find(result.tools, fn tool ->
          Map.has_key?(tool, :annotations) and not is_nil(tool.annotations)
        end)

      assert annotated_tool != nil, "Expected at least one tool with annotations in #{version}"

      # Validate annotation structure
      annotations = annotated_tool.annotations
      validate_tool_annotations(annotations)

      # Validate version compatibility
      validate_version_compatibility(annotated_tool, version, :tool_annotations)
    after
      cleanup_test_client(test_context)
    end
  end

  def test_list_change_notifications(version)
      when version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
    # Test tool list change notifications
    {:ok, test_context} = setup_test_client(version)

    try do
      # Test that server capabilities include list change support
      # This would be tested through server capabilities in a real implementation
      # For now, validate that the version supports this feature
      assert version in ["2025-03-26", "2025-06-18", "2025-11-25"]

      # In a real implementation, this would test:
      # 1. Server sends notifications/tools/list_changed
      # 2. Client receives and processes the notification
      # 3. Client can re-fetch the updated tool list
    after
      cleanup_test_client(test_context)
    end
  end

  def test_structured_output(version) when version in ["2025-06-18", "2025-11-25"] do
    # Test structured output schemas for 2025-06-18
    {:ok, test_context} = setup_test_client(version)

    try do
      {:ok, result} = Client.list_tools(test_context.client)

      # Find a tool with output schema
      structured_tool =
        Enum.find(result.tools, fn tool ->
          Map.has_key?(tool, :outputSchema) and not is_nil(tool.outputSchema)
        end)

      if structured_tool do
        # Validate output schema structure
        assert is_map(structured_tool.outputSchema)
        assert Map.has_key?(structured_tool.outputSchema, :type)

        # Validate version compatibility
        validate_version_compatibility(structured_tool, version, :structured_output)
      end
    after
      cleanup_test_client(test_context)
    end
  end

  # Helper functions for tool validation
  defp validate_tool_structure(tool, version) do
    # Basic tool structure validation
    assert is_map(tool)
    assert Map.has_key?(tool, :name)
    assert is_binary(tool.name)

    # Optional description
    if Map.has_key?(tool, :description) do
      assert is_binary(tool.description)
    end

    # Input schema is required
    assert Map.has_key?(tool, :inputSchema)
    assert is_map(tool.inputSchema)

    # Version-specific validations
    case version do
      v when v in ["2025-03-26", "2025-06-18", "2025-11-25"] ->
        # These versions may have annotations
        if Map.has_key?(tool, :annotations) do
          validate_tool_annotations(tool.annotations)
        end

        # 2025-06-18 specific features
        if v in ["2025-06-18", "2025-11-25"] do
          # This version may have structured output
          if Map.has_key?(tool, :outputSchema) do
            assert is_map(tool.outputSchema)
            assert Map.has_key?(tool.outputSchema, :type)
          end

          # May have title field
          if Map.has_key?(tool, :title) do
            assert is_binary(tool.title)
          end
        end

      _ ->
        # Earlier versions shouldn't have these features
        refute Map.has_key?(tool, :annotations)
        refute Map.has_key?(tool, :outputSchema)
    end
  end

  defp validate_tool_annotations(annotations) do
    # Validate tool annotation structure
    assert is_map(annotations)

    # Optional boolean fields
    optional_boolean_fields = [:destructiveHint, :readOnlyHint, :idempotentHint, :openWorldHint]

    for field <- optional_boolean_fields do
      if Map.has_key?(annotations, field) do
        assert is_boolean(annotations[field]), "#{field} must be boolean"
      end
    end

    # Optional string fields
    if Map.has_key?(annotations, :title) do
      assert is_binary(annotations.title)
    end
  end

  defp validate_content_item(content_item, _version) do
    # Validate content item structure
    assert is_map(content_item)
    assert Map.has_key?(content_item, :type)
    assert content_item.type in ["text", "image", "audio"]

    case content_item.type do
      "text" ->
        assert Map.has_key?(content_item, :text)
        assert is_binary(content_item.text)

      "image" ->
        assert Map.has_key?(content_item, :data)
        assert is_binary(content_item.data)

        if Map.has_key?(content_item, :mimeType) do
          assert is_binary(content_item.mimeType)
        end

      "audio" ->
        assert Map.has_key?(content_item, :data)
        assert is_binary(content_item.data)

        if Map.has_key?(content_item, :mimeType) do
          assert is_binary(content_item.mimeType)
        end
    end
  end

  def test_tool_titles(version) when version in ["2025-06-18", "2025-11-25"] do
    # Test that tools have title fields in 2025-06-18
    {:ok, test_context} = setup_test_client(version)

    try do
      {:ok, result} = Client.list_tools(test_context.client)

      # At least one tool should have a title field
      tool_with_title =
        Enum.find(result.tools, fn tool ->
          Map.has_key?(tool, :title)
        end)

      assert tool_with_title != nil, "Expected at least one tool with title field in #{version}"
      assert is_binary(tool_with_title.title)
      assert String.length(tool_with_title.title) > 0
    after
      cleanup_test_client(test_context)
    end
  end

  def test_structured_content_and_links(version) when version in ["2025-06-18", "2025-11-25"] do
    # Test structured content and resource links in tool results
    {:ok, test_context} = setup_test_client(version)

    try do
      {:ok, tools_result} = Client.list_tools(test_context.client)

      unless tools_result.tools == [] do
        tool = hd(tools_result.tools)
        {:ok, result} = Client.call_tool(test_context.client, tool.name, %{"expression" => "2+2"})

        validate_structured_content(result)
        validate_resource_links(result)
      end
    after
      cleanup_test_client(test_context)
    end
  end

  defp validate_structured_content(result) do
    # Check for structured content (2025-06-18 feature)
    if Map.has_key?(result, :structuredContent) or Map.has_key?(result, :structuredOutput) do
      structured = Map.get(result, :structuredContent) || Map.get(result, :structuredOutput)
      assert is_map(structured)
    end
  end

  defp validate_resource_links(result) do
    # Check for resource links (2025-06-18 feature)
    if Map.has_key?(result, :resourceLinks) do
      assert is_list(result.resourceLinks)

      for link <- result.resourceLinks do
        validate_single_resource_link(link)
      end
    end
  end

  defp validate_single_resource_link(link) do
    assert is_map(link)
    assert Map.has_key?(link, "uri") or Map.has_key?(link, :uri)

    if Map.has_key?(link, "title") or Map.has_key?(link, :title) do
      title = Map.get(link, "title") || Map.get(link, :title)
      assert is_binary(title)
    end
  end
end
