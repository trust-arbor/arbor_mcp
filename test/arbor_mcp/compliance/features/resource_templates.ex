defmodule Arbor.MCP.Compliance.Features.ResourceTemplates do
  @moduledoc """
  Resource template compliance tests for MCP versions.
  Resource templates were introduced in 2024-11-05.
  """

  # Full module names are required in macro-generated code to ensure proper resolution
  # credo:disable-for-lines:50 Credo.Check.Design.AliasUsage
  defmacro __using__(version) do
    quote do
      import Arbor.MCP.Compliance.Features.ResourceTemplates
      @version unquote(version)

      # Resource templates (2024-11-05+)
      if @version in ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"] do
        test "resources/templates/list returns valid templates" do
          Arbor.MCP.Compliance.Features.ResourceTemplates.test_list_templates(@version)
        end

        test "resource templates support URI template syntax" do
          Arbor.MCP.Compliance.Features.ResourceTemplates.test_uri_template_syntax(@version)
        end

        test "resource templates have proper metadata" do
          Arbor.MCP.Compliance.Features.ResourceTemplates.test_template_metadata(@version)
        end
      end
    end
  end

  # Import test helpers
  import ExUnit.Assertions
  import Arbor.MCP.ComplianceTestHelpers

  # Actual test implementations
  def test_list_templates(version)
      when version in ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"] do
    {:ok, test_context} = setup_test_client(version)

    try do
      # Handler should provide resource templates
      handler = test_context.handler
      {:ok, state} = handler.init([])
      {:ok, templates, cursor, _state} = handler.handle_list_resource_templates(nil, state)

      # Validate we got templates
      assert is_list(templates)
      assert length(templates) > 0
      assert cursor == nil

      # Validate each template structure
      for template <- templates do
        validate_resource_template(template, version)
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_uri_template_syntax(version)
      when version in ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"] do
    {:ok, test_context} = setup_test_client(version)

    try do
      handler = test_context.handler
      {:ok, state} = handler.init([])
      {:ok, templates, _cursor, _state} = handler.handle_list_resource_templates(nil, state)

      # Find a template with URI template syntax
      template_with_params =
        Enum.find(templates, fn t ->
          String.contains?(t.uriTemplate, "{")
        end)

      assert template_with_params != nil, "Expected at least one template with parameters"

      # Validate URI template format
      assert String.contains?(template_with_params.uriTemplate, "{")
      assert String.contains?(template_with_params.uriTemplate, "}")

      # Common patterns
      _valid_patterns = [
        # {param}
        ~r/\{[a-zA-Z_][a-zA-Z0-9_]*\}/,
        # {param*}
        ~r/\{[a-zA-Z_][a-zA-Z0-9_]*\*\}/,
        # {param:3}
        ~r/\{[a-zA-Z_][a-zA-Z0-9_]*:\d+\}/
      ]

      # Extract parameter from template
      params = Regex.scan(~r/\{([^}]+)\}/, template_with_params.uriTemplate)
      assert length(params) > 0, "Template should have extractable parameters"
    after
      cleanup_test_client(test_context)
    end
  end

  def test_template_metadata(version)
      when version in ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"] do
    {:ok, test_context} = setup_test_client(version)

    try do
      handler = test_context.handler
      {:ok, state} = handler.init([])
      {:ok, templates, _cursor, _state} = handler.handle_list_resource_templates(nil, state)

      # Each template should have proper metadata
      for template <- templates do
        # Required fields
        assert Map.has_key?(template, :uriTemplate)
        assert is_binary(template.uriTemplate)

        # Optional but recommended fields
        if Map.has_key?(template, :name) do
          assert is_binary(template.name)
        end

        if Map.has_key?(template, :description) do
          assert is_binary(template.description)
        end

        if Map.has_key?(template, :mimeType) do
          assert is_binary(template.mimeType)
        end
      end
    after
      cleanup_test_client(test_context)
    end
  end

  # Helper functions
  defp validate_resource_template(template, _version) do
    # Required field: uriTemplate
    assert Map.has_key?(template, :uriTemplate)
    assert is_binary(template.uriTemplate)

    # Validate it's a proper URI template
    assert String.starts_with?(template.uriTemplate, "file://") or
             String.starts_with?(template.uriTemplate, "https://") or
             String.starts_with?(template.uriTemplate, "http://")

    # Optional fields
    if Map.has_key?(template, :name) do
      assert is_binary(template.name)
      assert String.length(template.name) > 0
    end

    if Map.has_key?(template, :description) do
      assert is_binary(template.description)
    end

    if Map.has_key?(template, :mimeType) do
      assert is_binary(template.mimeType)
      # Should be a valid MIME type format
      assert template.mimeType =~
               ~r/^[a-zA-Z0-9][a-zA-Z0-9!#$&\-\^_+.]+\/[a-zA-Z0-9][a-zA-Z0-9!#$&\-\^_+.]+$/
    end
  end
end
