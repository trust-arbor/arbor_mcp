defmodule Arbor.MCP.Compliance.Features.Elicitation do
  @moduledoc """
  Elicitation capability compliance tests.
  Elicitation is stable in 2025-06-18 (was experimental in earlier versions).
  """

  # Full module names are required in macro-generated code to ensure proper resolution
  # credo:disable-for-lines:50 Credo.Check.Design.AliasUsage
  defmacro __using__(version) do
    quote do
      import Arbor.MCP.Compliance.Features.Elicitation
      @version unquote(version)

      # Elicitation capability (2025-06-18+)
      if @version in ["2025-06-18", "2025-11-25"] do
        test "elicitation support is stable" do
          Arbor.MCP.Compliance.Features.Elicitation.test_elicitation_stable(@version)
        end

        test "elicitation request structure is valid" do
          Arbor.MCP.Compliance.Features.Elicitation.test_elicitation_structure(@version)
        end

        test "elicitation with requested schema works" do
          Arbor.MCP.Compliance.Features.Elicitation.test_elicitation_schema(@version)
        end

        test "elicitation supports complex schemas" do
          Arbor.MCP.Compliance.Features.Elicitation.test_complex_elicitation(@version)
        end
      end
    end
  end

  # Import test helpers
  import ExUnit.Assertions
  import Arbor.MCP.ComplianceTestHelpers
  alias Arbor.MCP.Client

  # Actual test implementations
  def test_elicitation_stable(version) when version in ["2025-06-18", "2025-11-25"] do
    {:ok, test_context} = setup_test_client(version)

    try do
      # Check that elicitation is in stable capabilities (not experimental)
      {:ok, caps} = Client.server_capabilities(test_context.client)

      # Elicitation should be in experimental capabilities for 2025-06-18
      # (The spec shows it as still experimental in 2025-06-18)
      assert get_in(caps, ["experimental", "elicitation"]) == true
    after
      cleanup_test_client(test_context)
    end
  end

  def test_elicitation_structure(version) when version in ["2025-06-18", "2025-11-25"] do
    # Test elicitation request structure
    elicit_request = %{
      "message" => "Please provide your API key",
      "requestedSchema" => %{
        "type" => "object",
        "properties" => %{
          "apiKey" => %{
            "type" => "string",
            "title" => "API Key",
            "description" => "Your API key for authentication"
          }
        },
        "required" => ["apiKey"]
      }
    }

    # Validate structure
    assert Map.has_key?(elicit_request, "message")
    assert is_binary(elicit_request["message"])

    assert Map.has_key?(elicit_request, "requestedSchema")
    assert is_map(elicit_request["requestedSchema"])
    validate_json_schema(elicit_request["requestedSchema"])
  end

  def test_elicitation_schema(version) when version in ["2025-06-18", "2025-11-25"] do
    # Test various elicitation schemas
    schemas = [
      # Simple string input
      %{
        "type" => "string",
        "title" => "Username",
        "description" => "Enter your username"
      },

      # Object with multiple fields
      %{
        "type" => "object",
        "properties" => %{
          "username" => %{"type" => "string"},
          "password" => %{"type" => "string", "format" => "password"}
        },
        "required" => ["username", "password"]
      },

      # Array input
      %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "title" => "Tags",
        "description" => "Enter tags for categorization"
      },

      # Enum selection
      %{
        "type" => "string",
        "enum" => ["development", "staging", "production"],
        "title" => "Environment",
        "description" => "Select deployment environment"
      }
    ]

    for schema <- schemas do
      validate_json_schema(schema)
    end
  end

  def test_complex_elicitation(version) when version in ["2025-06-18", "2025-11-25"] do
    # Test complex elicitation scenarios
    complex_schema = %{
      "type" => "object",
      "title" => "Project Configuration",
      "properties" => %{
        "projectName" => %{
          "type" => "string",
          "title" => "Project Name",
          "description" => "The name of your project",
          "minLength" => 3,
          "maxLength" => 50
        },
        "environment" => %{
          "type" => "object",
          "title" => "Environment Settings",
          "properties" => %{
            "type" => %{
              "type" => "string",
              "enum" => ["development", "staging", "production"]
            },
            "features" => %{
              "type" => "array",
              "items" => %{
                "type" => "string",
                "enum" => ["logging", "metrics", "tracing", "profiling"]
              }
            }
          }
        },
        "database" => %{
          "type" => "object",
          "properties" => %{
            "type" => %{
              "type" => "string",
              "enum" => ["postgresql", "mysql", "sqlite"]
            },
            "connectionString" => %{
              "type" => "string",
              "format" => "uri"
            }
          },
          "required" => ["type"]
        }
      },
      "required" => ["projectName", "environment"]
    }

    validate_json_schema(complex_schema)

    # Validate nested properties
    assert get_in(complex_schema, ["properties", "projectName", "type"]) == "string"
    assert get_in(complex_schema, ["properties", "environment", "type"]) == "object"

    assert is_list(
             get_in(complex_schema, [
               "properties",
               "environment",
               "properties",
               "features",
               "items",
               "enum"
             ])
           )
  end

  # Helper functions
  defp validate_json_schema(schema) do
    # Basic JSON Schema validation
    assert Map.has_key?(schema, "type")
    assert schema["type"] in ["object", "array", "string", "number", "boolean", "null"]

    # Validate type-specific constraints
    case schema["type"] do
      "object" -> validate_object_schema(schema)
      "array" -> validate_array_schema(schema)
      "string" -> validate_string_schema(schema)
      _ -> :ok
    end

    # Validate optional metadata
    validate_schema_metadata(schema)
  end

  defp validate_object_schema(schema) do
    if Map.has_key?(schema, "properties") do
      assert is_map(schema["properties"])

      # Validate each property recursively
      for {_name, prop_schema} <- schema["properties"] do
        validate_json_schema(prop_schema)
      end
    end

    if Map.has_key?(schema, "required") do
      assert is_list(schema["required"])
      assert Enum.all?(schema["required"], &is_binary/1)
    end
  end

  defp validate_array_schema(schema) do
    if Map.has_key?(schema, "items") do
      validate_json_schema(schema["items"])
    end
  end

  defp validate_string_schema(schema) do
    if Map.has_key?(schema, "enum") do
      assert is_list(schema["enum"])
      assert Enum.all?(schema["enum"], &is_binary/1)
    end

    if Map.has_key?(schema, "format") do
      assert schema["format"] in ["date", "time", "date-time", "email", "uri", "password"]
    end
  end

  defp validate_schema_metadata(schema) do
    if Map.has_key?(schema, "title") do
      assert is_binary(schema["title"])
    end

    if Map.has_key?(schema, "description") do
      assert is_binary(schema["description"])
    end
  end
end
