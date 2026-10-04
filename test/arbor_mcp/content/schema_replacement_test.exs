defmodule Arbor.MCP.Content.SchemaReplacementTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Content.SchemaPolicy
  alias Arbor.MCP.Server.DSL

  alias Arbor.MCP.Testing.SchemaEncoderProbe, as: EncoderProbe

  defmodule BoundaryHandler do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL

    tool "reject" do
      output_schema(%{not: %{}})

      run(fn _args, state ->
        {:ok, ToolResult.structured("value", %{count: 1}), %{state | count: state.count + 1}}
      end)
    end

    tool "bypass" do
      output_schema(nil)
      run(fn _args, state -> {:ok, ToolResult.structured("value", %{anything: true}), state} end)
    end

    tool "default" do
      param(:count, :integer, default: 7)

      run(fn args, state ->
        {:ok, ToolResult.structured("value", %{count: args.count}), state}
      end)
    end
  end

  test "tagged compilation and optional nil are distinct from boolean false" do
    assert {:error, {:invalid_schema, "schema must be an object or boolean"}} =
             SchemaPolicy.compile(nil)

    assert {:error, _} = SchemaPolicy.validate(%{}, nil)
    assert {:ok, nil} = SchemaPolicy.compile_optional(nil)
    assert :ok = SchemaPolicy.validate_optional(self(), nil)
    assert {:ok, false_schema} = SchemaPolicy.compile_optional(false)
    refute is_nil(false_schema)
    assert {:error, _} = SchemaPolicy.validate_optional(%{}, false_schema)
    assert {:error, _} = SchemaPolicy.validate_optional(%{}, false)
    assert {:ok, true_schema} = SchemaPolicy.compile(true)
    assert :ok = SchemaPolicy.validate(%{}, true_schema)
  end

  test "compiled roots keep valid schema and validation has no transformation semantics" do
    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      type: :object,
      properties: %{count: %{type: :integer, default: 7}}
    }

    assert {:ok, compiled} = SchemaPolicy.compile(schema)
    assert compiled.schema["properties"]["count"]["default"] == 7
    args = %{}
    assert :ok = SchemaPolicy.validate(args, compiled)
    assert args == %{}
    assert {:error, _} = SchemaPolicy.validate(%{"count" => "7"}, compiled)
    assert :ok = SchemaPolicy.validate(%{"count" => 7}, compiled)
  end

  test "local references retain normal tagged compile and validation behavior" do
    schema = %{
      definitions: %{value: %{type: "integer"}},
      type: "object",
      properties: %{value: %{"$ref" => "#/definitions/value"}}
    }

    assert {:ok, root} = SchemaPolicy.compile(schema)
    assert :ok = SchemaPolicy.validate(%{"value" => 1}, root)
    assert {:error, _} = SchemaPolicy.validate(%{"value" => "1"}, root)
  end

  test "opt-in remote policy remains pinned and default policy never calls callbacks" do
    test_pid = self()

    dns = fn host, _timeout ->
      send(test_pid, {:schema_dns, host})
      {:ok, [{93, 184, 216, 34}]}
    end

    fetch = fn uri, address, _opts ->
      send(test_pid, {:schema_fetch, to_string(uri), address})
      {:ok, %{status: 200, headers: [], body: ~s({"type":"integer"})}}
    end

    schema = %{"$ref" => "https://schemas.example.com/value.json"}
    network = [allowed_hosts: ["schemas.example.com"], dns_resolver: dns, http_client: fetch]
    assert {:error, :network_ref_forbidden} = SchemaPolicy.compile(schema, network_refs: network)
    refute_receive {:schema_dns, _}
    refute_receive {:schema_fetch, _, _}
    assert {:ok, root} = SchemaPolicy.compile(schema, network_refs: [enabled: true] ++ network)
    assert_receive {:schema_dns, "schemas.example.com"}
    assert_receive {:schema_fetch, "https://schemas.example.com/value.json", {93, 184, 216, 34}}
    assert :ok = SchemaPolicy.validate(1, root)
    assert {:error, _} = SchemaPolicy.validate("1", root)
  end

  test "fetched schemas cannot skip meta-validation using a schema-looking identifier" do
    fetch = fn _uri, _address, _opts ->
      {:ok,
       %{
         status: 200,
         headers: [],
         body: ~s({"$id":"http://json-schema.org/pretend-meta","type":"not-a-type"})
       }}
    end

    opts = [
      network_refs: [
        enabled: true,
        allowed_hosts: ["schemas.example.com"],
        dns_resolver: fn _, _ -> {:ok, [{93, 184, 216, 34}]} end,
        http_client: fetch
      ]
    ]

    assert {:error, {:invalid_schema, "schema declaration is invalid or unsupported"}} =
             SchemaPolicy.compile(%{"$ref" => "https://schemas.example.com/invalid.json"}, opts)
  end

  test "invalid declarations cannot use a meta-schema identifier to skip validation" do
    for schema <- [
          %{type: "not-a-type"},
          %{properties: []},
          %{"$id" => "http://json-schema.org/pretend-meta", "type" => "not-a-type"},
          %{"id" => "http://json-schema.org/pretend-meta", "required" => "not-a-list"}
        ] do
      assert {:error, {:invalid_schema, "schema declaration is invalid or unsupported"}} =
               SchemaPolicy.compile(schema)
    end
  end

  test "unsupported dialect fails explicitly without fallback" do
    assert {:error, {:invalid_schema, "schema declaration is invalid or unsupported"}} =
             SchemaPolicy.compile(%{"$schema" => "https://json-schema.org/draft/2019-09/schema"})

    for draft <- ["04", "06", "07"] do
      assert {:ok, _} =
               SchemaPolicy.compile(%{
                 "$schema" => "http://json-schema.org/draft-#{draft}/schema#",
                 "type" => "object"
               })
    end
  end

  test "schema normalization rejects wire-key collisions recursively with fixed text" do
    for schema <- [
          %{:type => "object", "type" => "string"},
          %{
            type: "object",
            properties: %{:secret => %{type: "string"}, "secret" => %{type: "integer"}}
          },
          %{enum: [%{:token => "PRIVATE", "token" => "OTHER"}]}
        ] do
      assert {:error, {:invalid_schema, "conflicting normalized schema keys"}} =
               SchemaPolicy.compile(schema)
    end
  end

  test "non-JSON schema values reject before invoking a custom encoder" do
    assert {:ok, "{}"} = Jason.encode(%EncoderProbe{})
    assert_receive :schema_encoder_invoked

    for value <- [
          %EncoderProbe{value: "private"},
          self(),
          make_ref(),
          fn -> :secret end,
          [1 | 2],
          <<255>>
        ] do
      assert {:error, {:invalid_schema, "schema is not JSON-compatible"}} =
               SchemaPolicy.compile(%{default: value})
    end

    refute_receive :schema_encoder_invoked
  end

  test "optional bypass still validates options and malformed options are tagged" do
    assert {:error, {:invalid_schema_policy_option, :resolve_timeout_ms}} =
             SchemaPolicy.compile_optional(nil, resolve_timeout_ms: -1)

    assert {:error, {:invalid_schema_policy_option, :validation_timeout_ms}} =
             SchemaPolicy.validate_optional(%{}, nil, validation_timeout_ms: -1)

    assert {:error, {:invalid_schema_policy_option, :options}} = SchemaPolicy.compile(%{}, :wrong)

    assert {:error, {:invalid_schema_policy_option, :network_refs}} =
             SchemaPolicy.compile(%{}, network_refs: [:wrong])
  end

  test "pre-normalization resource limits reject large literal instance data" do
    schema = %{default: Enum.reduce(1..20, %{}, fn _, acc -> %{nested: acc} end)}

    assert {:error, {:schema_limit_exceeded, :max_schema_depth, _}} =
             SchemaPolicy.compile(schema, max_schema_depth: 5)

    assert {:error, {:schema_limit_exceeded, :max_schema_bytes, _}} =
             SchemaPolicy.compile(%{default: String.duplicate("x", 100)}, max_schema_bytes: 20)

    assert {:ok, _} = SchemaPolicy.compile(true, max_schema_bytes: 4)
    assert {:ok, _} = SchemaPolicy.compile(false, max_schema_bytes: 5)
  end

  test "oversized schema binaries and keys reject before whole-input UTF8 scanning" do
    oversized = :binary.copy(<<255>>, 1_000_000)

    for schema <- [%{default: oversized}, %{oversized => true}] do
      assert {:error, {:schema_limit_exceeded, :max_schema_bytes, _}} =
               SchemaPolicy.preflight(schema, max_schema_bytes: 100)
    end
  end

  test "literal false remains meaningful at standalone output validation boundary" do
    response = %{content: [], structuredContent: %{value: 1}}
    assert {:ok, ^response} = DSL.validate_tool_response(response, nil)
    assert {:error, _} = DSL.validate_tool_response(response, false)
  end

  test "real DSL compiler rejects invalid input and output declarations before callbacks" do
    for {kind, schema} <- [
          {:input, %{type: "object", properties: []}},
          {:input, %{type: "string"}},
          {:input, false},
          {:output, false},
          {:output, %{type: "not-a-type"}},
          {:output, %{:type => "object", "type" => "string"}},
          {:output, %{default: %EncoderProbe{value: "private"}}}
        ] do
      assert_raise ArgumentError, ~r/invalid (input|output)_schema\/1:/, fn ->
        compile_handler(kind, schema)
      end
    end

    refute_receive :schema_encoder_invoked
  end

  test "Builder preserves false so it is rejected rather than silently replaced" do
    descriptor = Arbor.MCP.Server.DSL.Builder.tool("test", nil, input_schema: false)
    assert descriptor.inputSchema == false
  end

  test "actual handler returns tool errors for schema failure and preserves existing state semantics" do
    assert {:ok, error, %{count: 1}} =
             BoundaryHandler.handle_call_tool("reject", %{}, %{count: 0})

    assert error.isError
    assert hd(error.content).text =~ "Output validation failed"

    assert {:ok, valid, %{count: 0}} =
             BoundaryHandler.handle_call_tool("bypass", %{}, %{count: 0})

    assert valid.structuredContent == %{anything: true}
  end

  test "DSL param defaults and string-key convenience do not imply type coercion" do
    assert {:ok, missing, _} = BoundaryHandler.handle_call_tool("default", %{}, %{count: 0})
    assert missing.structuredContent == %{count: 7}

    assert {:ok, string, _} =
             BoundaryHandler.handle_call_tool("default", %{"count" => "7"}, %{count: 0})

    assert string.structuredContent == %{count: "7"}
  end

  defp compile_handler(kind, schema) do
    name = Module.concat(__MODULE__, "Declaration#{System.unique_integer([:positive])}")
    declaration = if kind == :input, do: :input_schema, else: :output_schema

    quoted =
      quote do
        defmodule unquote(name) do
          use Arbor.MCP.Server.Handler
          use Arbor.MCP.Server.DSL

          tool "test" do
            unquote(declaration)(unquote(Macro.escape(schema)))
            run(fn _, state -> {:ok, ToolResult.text("value"), state} end)
          end
        end
      end

    Code.compile_quoted(quoted)
  end
end
