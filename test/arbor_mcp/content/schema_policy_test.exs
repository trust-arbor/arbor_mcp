defmodule Arbor.MCP.Content.SchemaPolicyTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Content.{SchemaPolicy, SchemaValidator, Validation}

  describe "local and external references" do
    test "supports local fragment references" do
      schema = %{
        "definitions" => %{"word" => %{"type" => "string"}},
        "type" => "object",
        "properties" => %{"name" => %{"$ref" => "#/definitions/word"}},
        "required" => ["name"]
      }

      assert {:ok, resolved} = SchemaPolicy.compile(schema)
      assert :ok = SchemaPolicy.validate(%{"name" => "Ada"}, resolved)
      assert {:error, _errors} = SchemaPolicy.validate(%{"name" => 42}, resolved)
    end

    test "rejects network, file, and relative references without revealing their values" do
      references = [
        "https://schemas.example.test/secret.json",
        "http://127.0.0.1/internal.json",
        "file:///etc/passwd",
        "other.json#/definitions/value"
      ]

      Enum.each(references, fn reference ->
        schema = %{"properties" => %{"value" => %{"$ref" => reference}}}

        assert {:error, :network_ref_forbidden} = SchemaPolicy.compile(schema)

        message = SchemaPolicy.format_error(:network_ref_forbidden)
        refute String.contains?(message, reference)
      end)
    end

    test "rejects recursive and dynamic cross-document references" do
      assert {:error, :network_ref_forbidden} =
               SchemaPolicy.preflight(%{"$recursiveRef" => "recursive.json#"})

      assert {:error, :network_ref_forbidden} =
               SchemaPolicy.preflight(%{"$dynamicRef" => "https://example.test/schema#node"})
    end

    test "does not invoke ExJsonSchema's global remote resolver" do
      previous = Application.get_env(:ex_json_schema, :remote_schema_resolver)
      caller = self()

      Application.put_env(:ex_json_schema, :remote_schema_resolver, fn uri ->
        send(caller, {:remote_schema_requested, uri})
        %{}
      end)

      on_exit(fn -> restore_env(:ex_json_schema, :remote_schema_resolver, previous) end)

      schema = %{"$ref" => "https://schemas.example.test/should-not-be-fetched.json"}

      assert {:error, :network_ref_forbidden} = SchemaPolicy.compile(schema)
      refute_receive {:remote_schema_requested, _uri}
    end

    test "allows a draft metadata URI because it is not a reference" do
      schema = %{
        "$schema" => "http://json-schema.org/draft-07/schema#",
        "type" => "string"
      }

      assert {:ok, _resolved} = SchemaPolicy.compile(schema)
    end

    test "does not treat reference-shaped literal instance data as a schema reference" do
      schema = %{
        "type" => "object",
        "default" => %{"$ref" => "https://example.test/literal-default"},
        "examples" => [%{"$ref" => "file:///literal-example"}],
        "const" => %{"$ref" => "relative-literal.json"}
      }

      assert :ok = SchemaPolicy.preflight(schema)
    end
  end

  describe "resource bounds" do
    test "bounds encoded schema size" do
      assert {:error, {:schema_limit_exceeded, :max_schema_bytes, observed}} =
               SchemaPolicy.preflight(%{"type" => "string"}, max_schema_bytes: 4)

      assert observed > 4
    end

    test "bounds structural depth" do
      schema = %{"properties" => %{"outer" => %{"properties" => %{}}}}

      assert {:error, {:schema_limit_exceeded, :max_schema_depth, observed}} =
               SchemaPolicy.preflight(schema, max_schema_depth: 2)

      assert observed > 2
    end

    test "bounds the number of subschemas" do
      schema = %{"properties" => %{"one" => %{}, "two" => %{}}}

      assert {:error, {:schema_limit_exceeded, :max_subschemas, observed}} =
               SchemaPolicy.preflight(schema, max_subschemas: 3)

      assert observed > 3
    end

    test "bounds composition-keyword depth" do
      schema = %{"allOf" => [%{"anyOf" => [%{"oneOf" => [%{}]}]}]}

      assert {:error, {:schema_limit_exceeded, :max_composition_depth, observed}} =
               SchemaPolicy.preflight(schema, max_composition_depth: 2)

      assert observed > 2
    end

    test "rejects invalid policy options" do
      assert {:error, {:invalid_schema_policy_option, :validation_timeout_ms}} =
               SchemaPolicy.preflight(%{}, validation_timeout_ms: -1)
    end

    test "rejects non-JSON schema keys without raising" do
      schema = %{{:not, :a_json_key} => %{}}

      assert {:error, {:invalid_schema, "schema is not JSON-compatible"}} =
               SchemaPolicy.preflight(schema)
    end

    test "enforces the validation deadline" do
      schema = %{
        "allOf" =>
          Enum.map(1..250, fn value ->
            %{"properties" => %{"value" => %{"minimum" => value - 1_000}}}
          end)
      }

      assert {:ok, resolved} = SchemaPolicy.compile(schema)

      assert {:error, {:schema_validation_timeout, 0}} =
               SchemaPolicy.validate(%{"value" => 1}, resolved, validation_timeout_ms: 0)
    end
  end

  describe "public validation paths" do
    test "supports boolean JSON Schemas without bypassing false schemas" do
      assert :ok = SchemaValidator.validate_schema(%{value: true}, true)

      assert {:error, [%{rule: :json_schema} | _errors]} =
               SchemaValidator.validate_schema(%{value: true}, false)

      assert {:error, _message} = Arbor.MCP.Helpers.validate_tool_args(%{}, false)
    end

    test "SchemaValidator returns a policy error for a remote reference" do
      schema = %{"$ref" => "https://schemas.example.test/private.json"}

      assert {:error, [error]} = SchemaValidator.validate_schema(%{value: true}, schema)
      assert error.rule == :json_schema_policy
      assert error.message =~ "cross-document"
      refute error.message =~ "schemas.example.test"
    end

    test "Validation forwards per-call policy limits" do
      schema = %{"properties" => %{"value" => %{}}}

      assert {:error, [message]} =
               Validation.validate_schema(%{value: true}, schema, max_subschemas: 1)

      assert message =~ "max_subschemas"
    end

    test "tool argument validation rejects remote references" do
      schema = %{"$ref" => "https://schemas.example.test/tool.json"}

      assert {:error, message} = Arbor.MCP.Helpers.validate_tool_args(%{}, schema)
      assert message =~ "cross-document"
    end

    test "tool output schema compilation fails closed" do
      schema = %{"$ref" => "https://schemas.example.test/tool-output.json"}

      module = "FailClosedTool#{System.unique_integer([:positive])}"

      source = """
      defmodule #{module} do
        use Arbor.MCP.Server.Handler
        use Arbor.MCP.Server.DSL
        tool "invalid_output" do
          output_schema #{inspect(schema)}
          run fn _args, state -> {:ok, "unused", state} end
        end
      end
      """

      assert_raise ArgumentError, ~r/cross-document/, fn -> Code.compile_string(source) end
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
