Arbor.MCP.Test.DynamicToolsExample.ensure_loaded()

defmodule Arbor.MCP.Content.SchemaDialectTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Content.{SchemaPolicy, SchemaValidator}
  alias Arbor.MCP.Testing.SchemaInstanceProbe

  @modern "https://json-schema.org/draft/2020-12/schema"
  @legacy "http://json-schema.org/draft-07/schema#"

  defmodule CastProbe do
    def __jsv__({:cast, _args, schema}, builder) do
      schema["observer"] |> String.to_charlist() |> :erlang.list_to_pid() |> send(:unsafe_cast)
      {:nocast, builder}
    end
  end

  defmodule CachedDSL do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL

    tool "pattern" do
      output_schema(%{type: "string", pattern: "^[a-z]+$"})
      run(fn _, state -> {:ok, %{content: [], structuredContent: "ok"}, state} end)
    end

    tool "tuple" do
      output_schema(%{type: "array", prefixItems: [%{type: "integer"}], items: false})
      run(fn _, state -> {:ok, %{content: [], structuredContent: [7]}, state} end)
    end
  end

  test "default dialect enforces 2020-12 prefixItems and items rather than ignoring them" do
    for schema <- [
          %{type: "array", prefixItems: [%{type: "integer"}], items: false},
          %{
            "$schema" => @modern,
            "type" => "array",
            "prefixItems" => [%{type: "integer"}],
            "items" => false
          }
        ] do
      assert {:ok, compiled} = SchemaPolicy.compile(schema)
      assert :ok = SchemaPolicy.validate([7], compiled)
      assert {:error, _} = SchemaPolicy.validate(["7"], compiled)
      assert {:error, _} = SchemaPolicy.validate([7, 8], compiled)
    end
  end

  test "unevaluatedProperties combines successful applicators" do
    schema = %{allOf: [%{properties: %{name: %{type: "string"}}}], unevaluatedProperties: false}
    assert :ok = SchemaPolicy.validate(%{"name" => "ok"}, schema)
    assert {:error, _} = SchemaPolicy.validate(%{"name" => "ok", "extra" => true}, schema)
  end

  test "dependentRequired and dependentSchemas are assertions" do
    assert {:error, _} = SchemaPolicy.validate(%{"a" => true}, %{dependentRequired: %{a: ["b"]}})

    assert :ok =
             SchemaPolicy.validate(%{"a" => true, "b" => false}, %{dependentRequired: %{a: ["b"]}})

    assert {:error, _} =
             SchemaPolicy.validate(%{"a" => true}, %{dependentSchemas: %{a: %{required: ["b"]}}})
  end

  test "minContains and maxContains constrain matching elements" do
    schema = %{contains: %{type: "integer"}, minContains: 2, maxContains: 2}
    assert :ok = SchemaPolicy.validate([1, "other", 2], schema)
    assert {:error, _} = SchemaPolicy.validate([1, "other"], schema)
    assert {:error, _} = SchemaPolicy.validate([1, 2, 3], schema)
  end

  test "local anchor and dynamicRef retain modern semantics" do
    schema = %{
      "$defs" => %{"integer" => %{"$anchor" => "integer", "type" => "integer"}},
      "$ref" => "#integer"
    }

    assert :ok = SchemaPolicy.validate(7, schema)
    assert {:error, _} = SchemaPolicy.validate("7", schema)

    schema = %{
      "$dynamicAnchor" => "node",
      "type" => "object",
      "properties" => %{"next" => %{"$dynamicRef" => "#node"}}
    }

    assert :ok = SchemaPolicy.validate(%{"next" => %{}}, schema)
    assert {:error, _} = SchemaPolicy.validate(%{"next" => 7}, schema)
  end

  test "explicit draft4 draft6 draft7 and unchanged ExJsonSchema Roots retain legacy behavior" do
    for draft <- ["04", "06", "07"] do
      schema = %{
        "$schema" => "http://json-schema.org/draft-#{draft}/schema#",
        "type" => "array",
        "items" => [%{"type" => "integer"}]
      }

      assert {:ok, %ExJsonSchema.Schema.Root{} = root} = SchemaPolicy.compile(schema)
      assert :ok = SchemaPolicy.validate([7], root)
      assert {:error, _} = SchemaPolicy.validate(["7"], root)
    end

    root = ExJsonSchema.Schema.resolve(%{"type" => "integer"})
    assert :ok = SchemaPolicy.validate(7, root)
    assert {:error, _} = SchemaPolicy.validate("7", root)
  end

  test "application-owned Handler stores modern output caches for single and bulk registration" do
    alias Arbor.MCP.Examples.DynamicTools
    alias Arbor.MCP.Examples.DynamicTools.Actions
    alias Arbor.MCP.Server
    alias Arbor.MCP.Server.HandlerServer
    alias Arbor.MCP.Transport.Test

    root = start_supervised!({HandlerServer, handler: DynamicTools, transport: :test})
    {:ok, transport} = Test.connect(server: root)
    schema = %{"type" => "array", "prefixItems" => [%{"type" => "integer"}], "items" => false}

    single = %{
      "name" => "single",
      "inputSchema" => %{"type" => "object"},
      "outputSchema" => schema
    }

    bulk = %{single | "name" => "bulk"}

    for entries <- [[{single, {Actions, :value}, %{}}], [{bulk, {Actions, :value}, %{}}]] do
      assert {:ok, :ok} = Server.call(root, {:register, entries, :reject})
      assert_receive {:transport_message, _changed}
    end

    for name <- ["single", "bulk"], value <- [[7], [7, 8]] do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "#{name}-#{length(value)}",
        "method" => "tools/call",
        "params" => %{
          "name" => name,
          "arguments" => %{"value" => value},
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{},
            "io.modelcontextprotocol/clientInfo" => %{
              "name" => "dynamic-schema",
              "version" => "2"
            }
          }
        }
      }

      assert {:ok, _transport} = Test.send_message(request, transport)
      assert_receive {:transport_message, response}
      result = if is_binary(response), do: Jason.decode!(response), else: response

      if value == [7],
        do: assert(result["result"]["structuredContent"] == [7]),
        else: assert(result["result"]["isError"] == true)
    end
  end

  test "unknown dialects and required vocabularies fail explicitly" do
    for uri <- [
          "https://json-schema.org/draft/2019-09/schema",
          "https://example.com/dialect",
          @modern <> "-pretend"
        ] do
      assert {:error, {:invalid_schema, _fixed}} = SchemaPolicy.compile(%{"$schema" => uri})
    end

    assert {:error, {:invalid_schema, _}} =
             SchemaPolicy.compile(%{"$vocabulary" => %{"https://example.com/vocab" => true}})

    assert {:ok, _} =
             SchemaPolicy.compile(%{"$vocabulary" => %{"https://example.com/vocab" => false}})
  end

  test "invalid descriptors and schema-looking IDs cannot bypass modern meta-validation" do
    for schema <- [
          %{prefixItems: "bad"},
          %{dependentRequired: %{a: true}},
          %{minContains: -1},
          %{"$id" => @modern, "type" => "bad"}
        ] do
      assert {:error, {:invalid_schema, _}} = SchemaPolicy.compile(schema)
    end
  end

  test "normal annotations and format annotation retain standard behavior without default insertion" do
    schema = %{
      type: "object",
      properties: %{
        value: %{
          "x-mcp-header" => "X-Value",
          type: "string",
          default: "fallback",
          format: "email"
        }
      }
    }

    assert :ok = SchemaPolicy.validate(%{}, schema)
    assert :ok = SchemaPolicy.validate(%{"value" => "not an email"}, schema)
    assert {:error, _} = SchemaPolicy.validate(%{"value" => 7}, schema)

    assert :ok =
             SchemaPolicy.validate(%{"x-mcp-header" => "literal"}, %{
               const: %{"x-mcp-header" => "literal"}
             })
  end

  test "reserved cast keys reject before build including local refs into otherwise literal objects" do
    target = %{
      "x-jsv-cast" => [[Atom.to_string(CastProbe), "probe"]],
      "observer" => :erlang.pid_to_list(self()) |> List.to_string()
    }

    assert {:ok, _} = JSV.build(target, atoms: false, warnings: :silence)
    assert_receive :unsafe_cast

    for key <- ["const", "default", "x-annotation"] do
      assert {:error, {:invalid_schema, _}} =
               SchemaPolicy.compile(%{key => target, "$ref" => "#/" <> key})

      refute_receive :unsafe_cast
    end

    assert {:error, {:invalid_schema, _}} =
             SchemaPolicy.compile(%{"jsv-cast" => [Atom.to_string(CastProbe), "probe"]})

    refute_receive :unsafe_cast
  end

  test "JSV application module file and local resolver references never gain access" do
    for uri <- [
          "jsv:module:Elixir.Arbor.MCP.Content.SchemaDialectTest.CastProbe",
          "file:///private/schema.json",
          "local:/schema.json"
        ] do
      assert {:error, _} = SchemaPolicy.compile(%{"$ref" => uri})

      assert {:error, _} =
               SchemaPolicy.compile(%{"default" => %{"$ref" => uri}, "$ref" => "#/default"})

      assert {:error, _} = SchemaPolicy.compile(%{"$id" => uri, "$ref" => "#missing"})
    end
  end

  test "modern and legacy instance validation rejects arbitrary objects without custom encoding" do
    probe = %SchemaInstanceProbe{observer: self()}
    assert Jason.encode!(probe) == "{}"
    assert inspect(probe) == "private probe"
    assert Enumerable.count(probe) == {:ok, 0}
    assert_receive :instance_encoder_invoked
    assert_receive :instance_inspect_invoked
    assert_receive :instance_enumerable_invoked

    for schema <- [%{}, %{"$schema" => @legacy}] do
      assert {:ok, root} = SchemaPolicy.compile(schema)

      for value <- [
            %SchemaInstanceProbe{observer: self()},
            self(),
            make_ref(),
            fn -> :private end,
            [1 | self()],
            %{nested: %SchemaInstanceProbe{observer: self()}}
          ] do
        assert {:error, {:schema_validation_failed, "instance must contain plain JSON values"}} =
                 SchemaPolicy.validate(value, root)

        refute_receive :instance_encoder_invoked
        refute_receive :instance_inspect_invoked
        refute_receive :instance_enumerable_invoked
      end

      assert {:error, _} = SchemaPolicy.validate(%{:value => 1, "value" => 2}, root)
    end
  end

  test "instance byte and depth limits apply to permissive schemas" do
    assert {:error, {:schema_limit_exceeded, :max_instance_bytes, _}} =
             SchemaPolicy.validate(String.duplicate("x", 20), %{}, max_instance_bytes: 10)

    assert {:error, {:schema_limit_exceeded, :max_instance_depth, _}} =
             SchemaPolicy.validate([[[1]]], %{}, max_instance_depth: 1)

    assert {:error, {:schema_validation_timeout, 0}} =
             SchemaPolicy.validate(%{}, %{}, validation_timeout_ms: 0)
  end

  test "content helper handles generic JSON and bounded atom convenience without backend gates" do
    assert :ok = SchemaValidator.validate_schema(false, %{type: "boolean"})
    assert :ok = SchemaValidator.validate_schema(nil, %{type: "null"})
    assert :ok = SchemaValidator.validate_schema([1], %{type: "array"})

    assert :ok =
             SchemaValidator.validate_schema(%{type: :text}, %{
               type: "object",
               properties: %{type: %{const: "text"}}
             })

    assert {:error, _} =
             SchemaValidator.validate_schema(%{:type => :text, "type" => "other"}, %{})
  end

  test "DSL compiled modern schema survives generated-module cache embedding" do
    assert {:ok, %{structuredContent: "ok"}, :state} =
             CachedDSL.handle_call_tool("pattern", %{}, :state)

    assert {:ok, %{structuredContent: [7]}, :state} =
             CachedDSL.handle_call_tool("tuple", %{}, :state)
  end

  test "allowlisted dynamic references and remote boolean documents use the pinned resolver" do
    observer = self()

    opts =
      network_options(fn uri, address, _opts ->
        send(observer, {:pinned, to_string(uri), address})
        body = if uri.path == "/true", do: "true", else: "false"
        {:ok, %{status: 200, headers: [], body: body}}
      end)

    assert {:ok, root} =
             SchemaPolicy.compile(%{"$dynamicRef" => "https://schemas.example.com/true"}, opts)

    assert :ok = SchemaPolicy.validate(nil, root)
    assert_receive {:pinned, "https://schemas.example.com/true", {93, 184, 216, 34}}

    assert {:ok, root} =
             SchemaPolicy.compile(%{"$ref" => "https://schemas.example.com/false"}, opts)

    assert {:error, _} = SchemaPolicy.validate(nil, root)
  end

  test "fetched extension documents cannot execute callbacks or advertise unknown required vocabularies" do
    observer = self()

    for document <- [
          %{
            "x-jsv-cast" => [[Atom.to_string(CastProbe), "probe"]],
            "observer" => :erlang.pid_to_list(observer) |> List.to_string()
          },
          %{"$vocabulary" => %{"https://example.com/vocab" => true}},
          %{
            "$schema" => "http://json-schema.org/draft-07/schema#",
            "const" => %{
              "x-jsv-cast" => [[Atom.to_string(CastProbe), "probe"]],
              "observer" => :erlang.pid_to_list(observer) |> List.to_string()
            },
            "$ref" => "#/const"
          }
        ] do
      opts =
        network_options(fn _, _, _ ->
          {:ok, %{status: 200, headers: [], body: Jason.encode!(document)}}
        end)

      assert {:error, {:invalid_schema, _}} =
               SchemaPolicy.compile(%{"$ref" => "https://schemas.example.com/unsafe"}, opts)

      refute_receive :unsafe_cast
    end
  end

  defp network_options(fetch) do
    [
      network_refs: [
        enabled: true,
        allowed_hosts: ["schemas.example.com"],
        dns_resolver: fn _, _ -> {:ok, [{93, 184, 216, 34}]} end,
        http_client: fetch
      ]
    ]
  end
end
