defmodule Arbor.MCP.Server.DSL.ParamConstraintsTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Content.SchemaPolicy
  alias Arbor.MCP.Server.DSL.Builder

  defmodule Constrained do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL

    tool "bounded" do
      param(:count, :integer, required: true, minimum: 1, maximum: 5, multiple_of: 1)
      param(:name, :string, min_length: 2, max_length: 4, pattern: "^[a-z]+$", default: "ok")
      param(:tags, {:array, :string}, max_items: 2, unique_items: true, default: [])
      param(:mode, :string, enum: ["fast", "safe"], default: "safe")

      run(fn args, state ->
        {:ok, ToolResult.structured("accepted", Map.take(args, [:count, :name, :tags, :mode])),
         Map.put(state, :invoked, true)}
      end)
    end

    tool "nullable" do
      param(:value, :object, schema: %{type: ["object", "null"]}, default: nil)
      param(:enabled, :boolean, default: false)

      run(fn args, state ->
        {:ok, ToolResult.structured("defaults", Map.take(args, [:value, :enabled])), state}
      end)
    end

    tool "nested" do
      param(:rows, {:array, :object},
        required: true,
        schema: %{
          type: "array",
          minItems: 1,
          items: %{
            type: "object",
            properties: %{name: %{type: "string", minLength: 1}},
            required: ["name"],
            additionalProperties: false
          }
        }
      )

      run(fn args, state -> {:ok, ToolResult.structured("nested", %{rows: args.rows}), state} end)
    end

    tool "literal" do
      input_schema(%{
        type: "object",
        properties: %{count: %{type: "integer", minimum: 1, default: 9}},
        required: ["count"],
        additionalProperties: false
      })

      run(fn args, state ->
        {:ok, ToolResult.structured("literal", %{count: Map.fetch!(args, "count")}),
         Map.put(state, :invoked, true)}
      end)
    end
  end

  test "generated numeric, string, array and enum constraints validate actual arguments" do
    {:ok, tools, nil, %{}} = Constrained.handle_list_tools(nil, %{})
    definition = Enum.find(tools, &(&1.name == "bounded"))
    assert definition.inputSchema.properties.count.minimum == 1
    assert definition.inputSchema.properties.count.maximum == 5
    assert definition.inputSchema.properties.name.minLength == 2
    assert definition.inputSchema.properties.tags.uniqueItems

    assert {:ok, %{structuredContent: accepted}, %{invoked: true}} =
             Constrained.handle_call_tool("bounded", %{"count" => 2}, %{})

    assert accepted.count == 2
    assert accepted.name == "ok"
    assert accepted.tags == []
    assert accepted.mode == "safe"

    for invalid <- [
          %{},
          %{"count" => 0},
          %{"count" => 6},
          %{"count" => 1.5},
          %{"count" => 2, "name" => "UP"},
          %{"count" => 2, "name" => "a"},
          %{"count" => 2, "name" => "longer"},
          %{"count" => 2, "tags" => ["same", "same"]},
          %{"count" => 2, "tags" => ["a", "b", "c"]},
          %{"count" => 2, "mode" => "unknown"}
        ] do
      assert {:error, %Arbor.MCP.Error.ProtocolError{code: -32602}, %{}} =
               Constrained.handle_call_tool("bounded", invalid, %{})
    end
  end

  test "explicit null and false defaults remain visible and reach callbacks" do
    {:ok, tools, nil, %{}} = Constrained.handle_list_tools(nil, %{})
    definition = Enum.find(tools, &(&1.name == "nullable"))
    assert Map.fetch(definition.inputSchema.properties.value, :default) == {:ok, nil}
    assert Map.fetch(definition.inputSchema.properties.enabled, :default) == {:ok, false}

    assert {:ok, %{structuredContent: %{value: nil, enabled: false}}, %{}} =
             Constrained.handle_call_tool("nullable", %{}, %{})

    assert {:ok, %{structuredContent: %{enabled: true}}, %{}} =
             Constrained.handle_call_tool("nullable", %{"enabled" => true}, %{})
  end

  test "nested literal array/object schemas enforce their inner constraints" do
    assert {:ok, _result, %{}} =
             Constrained.handle_call_tool("nested", %{"rows" => [%{"name" => "ok"}]}, %{})

    for rows <- [[], [%{}], [%{"name" => ""}], [%{"name" => "ok", "extra" => 1}]] do
      assert {:error, _reason, %{}} =
               Constrained.handle_call_tool("nested", %{"rows" => rows}, %{})
    end
  end

  test "object bounds, exclusive bounds and boolean literal schemas are valid schemas" do
    params = [
      Builder.param(:number, :number, exclusive_minimum: 1, exclusive_maximum: 3),
      Builder.param(:object, :object,
        min_properties: 1,
        max_properties: 2,
        additional_properties: false
      ),
      Builder.param(:anything, :object, schema: true, default: nil)
    ]

    {:ok, schema} = params |> Builder.schema_from_params() |> SchemaPolicy.compile()
    assert :ok = SchemaPolicy.validate(%{"number" => 2, "anything" => nil}, schema)
    assert {:error, _} = SchemaPolicy.validate(%{"number" => 1}, schema)
    assert {:error, _} = SchemaPolicy.validate(%{"object" => %{}}, schema)
    assert {:error, _} = SchemaPolicy.validate(%{"object" => %{"undeclared" => 1}}, schema)
  end

  test "literal input schemas validate without coercion or schema-default insertion" do
    for invalid <- [%{}, %{"count" => "2"}, %{"count" => 2, "extra" => true}] do
      assert {:error, %Arbor.MCP.Error.ProtocolError{code: -32602}, %{}} =
               Constrained.handle_call_tool("literal", invalid, %{})
    end

    assert {:ok, %{structuredContent: %{count: 2}}, %{invoked: true}} =
             Constrained.handle_call_tool("literal", %{"count" => 2, "_meta" => %{}}, %{})

    assert {:error, %Arbor.MCP.Error.ProtocolError{code: -32602}, %{}} =
             Constrained.handle_call_tool("literal", %{:count => 2, "count" => 3}, %{})
  end

  test "invalid, duplicate and inapplicable options fail at the declaration line" do
    for declaration <- [
          "param :value, :string, minimum: 1",
          "param :value, :integer, multiple_of: 0",
          "param :value, :string, min_length: -1",
          "param :value, :string, enum: []",
          "param :value, :string, pattern: 12",
          "param :value, :string, max_length: 2, max_length: 3",
          "param :value, :string, max_lenght: 2",
          "param :value, :string, schema: %{type: \"string\"}, min_length: 1",
          "param :value, :string, required: :yes"
        ] do
      module = "InvalidParam#{System.unique_integer([:positive])}"

      source = """
      defmodule #{module} do
        use Arbor.MCP.Server.Handler
        use Arbor.MCP.Server.DSL
        tool "bad" do
          #{declaration}
          run fn _args, state -> {:ok, "unused", state} end
        end
      end
      """

      error = assert_raise CompileError, fn -> Code.compile_string(source, "param_fixture.ex") end
      assert error.file == "param_fixture.ex"
      assert error.line == 5
      assert error.description =~ "param" or error.description =~ ":schema"
    end
  end
end
