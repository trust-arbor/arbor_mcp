defmodule Arbor.MCP.Content.SchemaPolicyTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Content.{SchemaPolicy, SchemaValidator, Validation}

  @legacy_drafts [
    "http://json-schema.org/draft-04/schema#",
    "http://json-schema.org/draft-06/schema#",
    "http://json-schema.org/draft-07/schema#"
  ]

  @pointer_drafts [
    "http://json-schema.org/draft-04/schema#",
    "http://json-schema.org/draft-06/schema#",
    "http://json-schema.org/draft-07/schema#",
    "https://json-schema.org/draft/2019-09/schema",
    "https://json-schema.org/draft/2020-12/schema"
  ]

  @unrelated_allowlist [network_refs: [enabled: true, allowed_hosts: ["schemas.example.com"]]]
  @private_ref "http://127.0.0.1:4000/private.json"

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

    test "resolves a local anchor nested under an absolute root identifier" do
      schema = %{
        "$schema" => "http://json-schema.org/draft-07/schema#",
        "$id" => "https://schemas.example.com/root.json",
        "definitions" => %{"inner" => %{"$anchor" => "word", "type" => "integer"}},
        "$ref" => "#word"
      }

      assert {:ok, resolved} = SchemaPolicy.compile(schema)
      assert :ok = SchemaPolicy.validate(42, resolved)
      assert {:error, _errors} = SchemaPolicy.validate("BAD", resolved)
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

    test "rejects a remote ref nested under a targeted literal keyword" do
      remote = "https://evil.example/secret.json"

      for schema <- [
            %{
              "const" => %{"nested" => %{"$ref" => remote}},
              "$ref" => "#/const/nested"
            },
            %{
              "examples" => [%{"$ref" => remote}],
              "$ref" => "#/examples/0"
            },
            %{
              "enum" => [%{"$ref" => remote}],
              "$ref" => "#/enum/0"
            },
            %{
              "default" => %{"nested" => %{"$ref" => remote}},
              "$ref" => "#/default/nested"
            }
          ] do
        assert {:error, :network_ref_forbidden} = SchemaPolicy.preflight(schema)
        assert {:error, :network_ref_forbidden} = SchemaPolicy.compile(schema)
      end
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

    test "walks a $ref under a property named default" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "default" => %{"$ref" => "https://evil.example/schema"}
        }
      }

      assert {:error, :network_ref_forbidden} = SchemaPolicy.preflight(schema)
      assert {:error, :network_ref_forbidden} = SchemaPolicy.compile(schema)
    end

    test "walks $ref values under properties named enum and examples" do
      for name <- ["enum", "examples"] do
        schema = %{
          "type" => "object",
          "properties" => %{
            name => %{"$ref" => "https://evil.example/#{name}"}
          }
        }

        assert {:error, :network_ref_forbidden} = SchemaPolicy.preflight(schema)
      end
    end

    test "walks $ref schemas under draft-7 dependencies names" do
      for name <- ~w(id $id default enum examples const $ref properties) do
        schema = %{
          "type" => "object",
          "properties" => %{
            "default" => %{
              "dependencies" => %{
                name => %{"$ref" => "https://evil.example/#{name}"}
              }
            }
          }
        }

        assert SchemaPolicy.preflight(schema) == {:error, :network_ref_forbidden},
               "dependencies $ref child #{inspect(name)}"
      end
    end

    test "walks dependentRequired on drafts that do not define it" do
      previous = Application.get_env(:ex_json_schema, :remote_schema_resolver)
      caller = self()

      Application.put_env(:ex_json_schema, :remote_schema_resolver, fn uri ->
        send(caller, {:global_resolver_called, uri})
        %{}
      end)

      on_exit(fn -> restore_env(:ex_json_schema, :remote_schema_resolver, previous) end)

      for uri <- @legacy_drafts do
        schema = %{
          "$schema" => uri,
          "dependentRequired" => %{
            "payload" => %{"$ref" => "http://127.0.0.1:4000/private.json"}
          },
          "$ref" => "#/dependentRequired/payload"
        }

        assert SchemaPolicy.preflight(schema) == {:error, :network_ref_forbidden},
               "#{uri} preflight"

        assert SchemaPolicy.compile(schema) == {:error, :network_ref_forbidden},
               "#{uri} compile"

        refute_receive {:global_resolver_called, _requested}

        assert {:error, {:network_schema_error, _reason}} =
                 SchemaPolicy.compile(schema, @unrelated_allowlist)

        refute_receive {:global_resolver_called, _requested}
      end
    end

    test "compile never calls the global remote resolver for hidden or spoofed refs" do
      with_global_resolver_spy(fn ->
        for {label, schema} <- hidden_or_spoofed_ref_schemas() do
          refute match?({:ok, _}, SchemaPolicy.compile(schema)),
                 "#{label} compile with network refs off"

          refute_receive {:global_resolver_called, _requested},
                         50,
                         "#{label} reached the global resolver with network refs off"

          refute match?({:ok, _}, SchemaPolicy.compile(schema, @unrelated_allowlist)),
                 "#{label} compile with an unrelated allowlist"

          refute_receive {:global_resolver_called, _requested},
                         50,
                         "#{label} reached the global resolver with an unrelated allowlist"
        end
      end)
    end

    test "compile never calls the global resolver for $id-scoped fragment refs" do
      with_global_resolver_spy(fn ->
        for {label, schema} <- id_scoped_fragment_schemas() do
          _result = SchemaPolicy.compile(schema)

          refute_receive {:global_resolver_called, _requested},
                         50,
                         "#{label} reached the global resolver with network refs off"

          _allowed = SchemaPolicy.compile(schema, @unrelated_allowlist)

          refute_receive {:global_resolver_called, _requested},
                         50,
                         "#{label} reached the global resolver with an unrelated allowlist"
        end
      end)
    end

    test "extension identifiers cannot scope a fragment ref into the global resolver" do
      with_global_resolver_spy(fn ->
        for {draft, identifier} <- [
              {"http://json-schema.org/draft-04/schema#", "id"},
              {"http://json-schema.org/draft-07/schema#", "$id"}
            ] do
          schema = %{
            "$schema" => draft,
            "extension" => %{
              identifier => "ftp://127.0.0.1:4000/private.json#anchor",
              "x" => %{"$ref" => "#"}
            }
          }

          assert {:error, :network_ref_forbidden} = SchemaPolicy.compile(schema)
          refute_receive {:global_resolver_called, _requested}
        end
      end)
    end

    test "overlapping compiles never call the global resolver or change app env" do
      previous = Application.get_env(:ex_json_schema, :remote_schema_resolver)
      caller = self()

      spy = fn uri ->
        send(caller, {:global_resolver_called, uri})
        %{}
      end

      Application.put_env(:ex_json_schema, :remote_schema_resolver, spy)
      on_exit(fn -> restore_env(:ex_json_schema, :remote_schema_resolver, previous) end)

      hidden = Enum.map(hidden_or_spoofed_ref_schemas(), fn {_label, schema} -> schema end)
      id_scoped = Enum.map(id_scoped_fragment_schemas(), fn {_label, schema} -> schema end)
      barrier = make_ref()

      hidden_tasks =
        for schema <- hidden do
          Task.async(fn ->
            send(caller, {:ready, self()})
            receive do: (^barrier -> :ok)
            SchemaPolicy.compile(schema)
          end)
        end

      id_tasks =
        for schema <- id_scoped, _n <- 1..3 do
          Task.async(fn ->
            send(caller, {:ready, self()})
            receive do: (^barrier -> :ok)
            SchemaPolicy.compile(schema)
          end)
        end

      tasks = hidden_tasks ++ id_tasks
      for _task <- tasks, do: assert_receive({:ready, _pid}, 5_000)
      Enum.each(tasks, fn task -> send(task.pid, barrier) end)

      hidden_results = Enum.map(hidden_tasks, &Task.await(&1, 15_000))
      _id_results = Enum.map(id_tasks, &Task.await(&1, 15_000))

      Enum.each(hidden_results, fn result ->
        refute match?({:ok, _}, result)
      end)

      refute_receive {:global_resolver_called, _requested}
      assert Application.get_env(:ex_json_schema, :remote_schema_resolver) == spy
    end

    test "stress: many overlapping compiles leave the global resolver env untouched" do
      previous = Application.get_env(:ex_json_schema, :remote_schema_resolver)
      caller = self()

      spy = fn uri ->
        send(caller, {:global_resolver_called, uri})
        %{}
      end

      Application.put_env(:ex_json_schema, :remote_schema_resolver, spy)
      on_exit(fn -> restore_env(:ex_json_schema, :remote_schema_resolver, previous) end)

      schema = id_anchor_schema()

      1..40
      |> Enum.map(fn _n -> Task.async(fn -> SchemaPolicy.compile(schema) end) end)
      |> Enum.each(&Task.await(&1, 15_000))

      refute_receive {:global_resolver_called, _requested}
      assert Application.get_env(:ex_json_schema, :remote_schema_resolver) == spy
    end

    test "a timed-out compile leaves the global resolver env unchanged" do
      previous = Application.get_env(:ex_json_schema, :remote_schema_resolver)
      caller = self()

      spy = fn uri ->
        send(caller, {:global_resolver_called, uri})
        %{}
      end

      Application.put_env(:ex_json_schema, :remote_schema_resolver, spy)
      on_exit(fn -> restore_env(:ex_json_schema, :remote_schema_resolver, previous) end)

      http_client = fn _uri, _address, _opts ->
        Process.sleep(5_000)
        {:ok, %{status: 200, headers: [], body: ~s({"type":"string"})}}
      end

      opts = [
        resolve_timeout_ms: 30,
        network_refs: [
          enabled: true,
          allowed_hosts: ["schemas.example.com"],
          allow_http: true,
          dns_resolver: fn _host, _timeout -> {:ok, [{93, 184, 216, 34}]} end,
          http_client: http_client
        ]
      ]

      schema = %{
        "$schema" => "http://json-schema.org/draft-07/schema#",
        "$ref" => "https://schemas.example.com/slow.json"
      }

      assert {:error, {:schema_resolution_timeout, 30}} = SchemaPolicy.compile(schema, opts)
      refute_receive {:global_resolver_called, _requested}
      assert Application.get_env(:ex_json_schema, :remote_schema_resolver) == spy

      assert {:error, :network_ref_forbidden} =
               SchemaPolicy.compile(%{
                 "$schema" => "http://json-schema.org/draft-07/schema#",
                 "$ref" => "https://schemas.example.com/after-timeout.json"
               })

      refute_receive {:global_resolver_called, _requested}
      assert Application.get_env(:ex_json_schema, :remote_schema_resolver) == spy
    end

    test "walks mixed dependencies lists that hold schemas" do
      previous = Application.get_env(:ex_json_schema, :remote_schema_resolver)
      caller = self()

      Application.put_env(:ex_json_schema, :remote_schema_resolver, fn uri ->
        send(caller, {:global_resolver_called, uri})
        %{}
      end)

      on_exit(fn -> restore_env(:ex_json_schema, :remote_schema_resolver, previous) end)

      for uri <- @pointer_drafts do
        schema = %{
          "$schema" => uri,
          "extension" => %{
            "dependencies" => %{
              "payload" => ["name", %{"$ref" => "http://127.0.0.1:4000/private.json"}]
            }
          },
          "$ref" => "#/extension/dependencies/payload/1"
        }

        assert SchemaPolicy.preflight(schema) == {:error, :network_ref_forbidden},
               "#{uri} preflight"

        assert SchemaPolicy.compile(schema) == {:error, :network_ref_forbidden},
               "#{uri} compile"

        refute_receive {:global_resolver_called, _requested}

        assert {:error, _reason} = SchemaPolicy.compile(schema, @unrelated_allowlist)
        refute_receive {:global_resolver_called, _requested}
      end
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

  defp with_global_resolver_spy(fun) when is_function(fun, 0) do
    previous = Application.get_env(:ex_json_schema, :remote_schema_resolver)
    caller = self()

    Application.put_env(:ex_json_schema, :remote_schema_resolver, fn uri ->
      send(caller, {:global_resolver_called, uri})
      %{}
    end)

    try do
      fun.()
    after
      restore_env(:ex_json_schema, :remote_schema_resolver, previous)
    end
  end

  defp id_anchor_schema do
    %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "$id" => "http://127.0.0.1:4000/private.json#anchor",
      "properties" => %{"x" => %{"$ref" => "#"}}
    }
  end

  defp id_scoped_fragment_schemas do
    [
      {"draft-7 $id-anchor $ref #", id_anchor_schema()},
      {"draft-4 id-anchor $ref #",
       %{
         "$schema" => "http://json-schema.org/draft-04/schema#",
         "id" => "http://127.0.0.1:4000/private.json#anchor",
         "properties" => %{"x" => %{"$ref" => "#"}}
       }}
    ]
  end

  defp hidden_or_spoofed_ref_schemas do
    private = @private_ref
    modern = "https://json-schema.org/draft/2020-12/schema"

    named_containers =
      ~w(properties patternProperties $defs definitions dependentSchemas dependencies)

    for uri <- @pointer_drafts, {label, schema} <- hidden_ref_shapes(uri, private, modern) do
      {"#{uri} #{label}", schema}
    end ++
      for uri <- @legacy_drafts, container <- named_containers do
        {"#{uri} extension.#{container} $ref name",
         %{
           "$schema" => uri,
           "extension" => %{container => %{"$ref" => private}},
           "$ref" => "#/extension/#{container}"
         }}
      end
  end

  defp hidden_ref_shapes(uri, private, modern) do
    [
      {"root $defs $ref name", %{"$schema" => uri, "$defs" => %{"$ref" => private}}},
      {"root dependentSchemas $ref name",
       %{"$schema" => uri, "dependentSchemas" => %{"$ref" => private}}},
      {"extension.dependencies $ref name",
       %{"$schema" => uri, "extension" => %{"dependencies" => %{"$ref" => private}}}},
      {"nested $schema spoof",
       %{
         "$schema" => uri,
         "extension" => %{
           "$schema" => modern,
           "dependentRequired" => %{"p" => %{"$ref" => private}}
         },
         "$ref" => "#/extension/dependentRequired/p"
       }},
      {"object $dynamicRef", %{"$schema" => uri, "$dynamicRef" => %{"$ref" => private}}},
      {"dependentRequired payload",
       %{
         "$schema" => uri,
         "dependentRequired" => %{"payload" => %{"$ref" => private}},
         "$ref" => "#/dependentRequired/payload"
       }},
      {"mixed dependencies list",
       %{
         "$schema" => uri,
         "extension" => %{
           "dependencies" => %{
             "payload" => ["name", %{"$ref" => private}]
           }
         },
         "$ref" => "#/extension/dependencies/payload/1"
       }}
    ]
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
