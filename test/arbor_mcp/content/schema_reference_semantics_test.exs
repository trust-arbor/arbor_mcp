defmodule Arbor.MCP.Content.SchemaReferenceSemanticsTest do
  use ExUnit.Case, async: false
  alias Arbor.MCP.Content.SchemaPolicy

  test "relative schema identifiers remain valid without any remote references" do
    for id <- ["local.json", "#local"] do
      schema = %{
        "$schema" => "http://json-schema.org/draft-07/schema#",
        "$id" => id,
        "type" => "integer"
      }

      assert {:ok, compiled} = SchemaPolicy.compile(schema)
      assert :ok = SchemaPolicy.validate(1, compiled)
      assert {:error, _} = SchemaPolicy.validate("str", compiled)
    end
  end

  test "a fragment identifier stays within its containing resource" do
    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "definitions" => %{"word" => %{"$id" => "#word", "type" => "integer"}},
      "$ref" => "#word"
    }

    assert {:ok, compiled} = SchemaPolicy.compile(schema)
    assert :ok = SchemaPolicy.validate(1, compiled)
    assert {:error, _} = SchemaPolicy.validate("str", compiled)
  end

  test "nested resource identifiers and their anchors resolve locally" do
    for reference <- ["child.json#word", "child.json#/definitions/word"] do
      schema = %{
        "$schema" => "http://json-schema.org/draft-07/schema#",
        "$id" => "https://schemas.example.com/root.json",
        "definitions" => %{
          "child" => %{
            "$id" => "child.json#word",
            "type" => "integer",
            "definitions" => %{"word" => %{"type" => "integer"}}
          }
        },
        "$ref" => reference
      }

      assert {:ok, compiled} = SchemaPolicy.compile(schema, resolver_options(%{}))
      assert :ok = SchemaPolicy.validate(1, compiled)
      assert {:error, _} = SchemaPolicy.validate("str", compiled)
    end
  end

  test "a targeted literal descendant leaves its unrelated siblings as data" do
    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "const" => %{
        "unused" => %{"$ref" => "https://schemas.example.test/data.json"},
        "nested" => %{"type" => "integer"}
      },
      "$ref" => "#/const/nested"
    }

    assert {:ok, compiled} = SchemaPolicy.compile(schema)
    assert :ok = SchemaPolicy.validate(1, compiled)
    assert {:error, _} = SchemaPolicy.validate("str", compiled)
  end

  test "a literal can be referenced as a schema while retaining its instance value" do
    literal = %{"type" => "object"}

    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "const" => literal,
      "allOf" => [%{"$ref" => "#/const"}]
    }

    assert {:ok, compiled} = SchemaPolicy.compile(schema)
    assert :ok = SchemaPolicy.validate(literal, compiled)
    assert {:error, _} = SchemaPolicy.validate(%{}, compiled)
  end

  test "a referenced boolean literal retains boolean schema semantics" do
    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "const" => false,
      "$ref" => "#/const"
    }

    assert {:ok, compiled} = SchemaPolicy.compile(schema)
    assert {:error, _} = SchemaPolicy.validate(false, compiled)
    assert {:error, _} = SchemaPolicy.validate(%{}, compiled)
  end

  test "reference-shaped literal instance data does not activate another literal" do
    literal = %{"$ref" => "#/default"}

    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "const" => literal,
      "default" => %{"$ref" => "https://schemas.example.test/data.json"}
    }

    assert {:ok, compiled} = SchemaPolicy.compile(schema)
    assert :ok = SchemaPolicy.validate(literal, compiled)
    assert {:error, _} = SchemaPolicy.validate(%{}, compiled)
  end

  test "inlining preserves a const structurally equal to a referenced definition" do
    url = "https://schemas.example.com/true.json"
    literal = %{"$ref" => url}

    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "definitions" => %{"remote" => literal},
      "allOf" => [%{"$ref" => "#/definitions/remote"}, %{"const" => literal}]
    }

    assert {:ok, compiled} = SchemaPolicy.compile(schema, resolver_options(%{}))
    assert :ok = SchemaPolicy.validate(literal, compiled)
    assert {:error, _} = SchemaPolicy.validate(%{"$ref" => "#/definitions/__remote_0"}, compiled)
  end

  test "a remote document's declared id may differ from its retrieval URL" do
    document = %{
      "$id" => "https://schemas.example.com/canonical.json",
      "definitions" => %{"word" => %{"type" => "string"}},
      "$ref" => "#/definitions/word"
    }

    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "$ref" => "https://schemas.example.com/retrieved.json"
    }

    assert {:ok, compiled} = SchemaPolicy.compile(schema, resolver_options(document))
    assert :ok = SchemaPolicy.validate("str", compiled)
    assert {:error, _} = SchemaPolicy.validate(1, compiled)
  end

  test "an anchor in a nested id resource does not belong to the root resource" do
    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "$id" => "https://schemas.example.com/root.json",
      "definitions" => %{"child" => %{"$id" => "child.json#word", "type" => "integer"}},
      "$ref" => "#word"
    }

    case SchemaPolicy.compile(schema) do
      {:ok, compiled} -> assert {:error, _} = SchemaPolicy.validate(1, compiled)
      {:error, _} -> :ok
    end
  end

  test "a dynamic-reference-shaped key in remote literal data is ordinary data" do
    literal = %{"$dynamicRef" => "just-data"}
    document = %{"type" => "object", "const" => literal}

    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "$ref" => "https://schemas.example.com/literal.json"
    }

    assert {:ok, compiled} = SchemaPolicy.compile(schema, resolver_options(document))
    assert :ok = SchemaPolicy.validate(literal, compiled)
  end

  test "a declared identifier from an earlier document does not trigger another fetch" do
    a = "https://schemas.example.com/a.json"
    z = "https://schemas.example.com/z.json"
    canonical = "https://canonical.example/number.json"
    documents = %{a => %{"$id" => canonical, "type" => "integer"}, z => %{"$ref" => canonical}}

    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "allOf" => [%{"$ref" => a}, %{"$ref" => z}]
    }

    assert {:ok, compiled} = SchemaPolicy.compile(schema, documents_options(documents))
    assert :ok = SchemaPolicy.validate(1, compiled)
    assert {:error, _} = SchemaPolicy.validate("str", compiled)
  end

  test "declared identifier aliases preserve cross-document cycle checks" do
    a = "https://schemas.example.com/a.json"
    z = "https://schemas.example.com/z.json"
    canonical = "https://canonical.example/number.json"
    documents = %{a => %{"$id" => canonical, "$ref" => z}, z => %{"$ref" => canonical}}
    schema = %{"$schema" => "http://json-schema.org/draft-07/schema#", "$ref" => a}

    assert {:error, {:network_schema_error, :reference_cycle}} =
             SchemaPolicy.compile(schema, documents_options(documents))
  end

  test "unknown annotation dynamic-reference text remains data in a fetched schema" do
    document = %{"type" => "string", "x-meta" => %{"$dynamicRef" => "just-data"}}

    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "$ref" => "https://schemas.example.com/annotations.json"
    }

    assert {:ok, compiled} = SchemaPolicy.compile(schema, resolver_options(document))
    assert :ok = SchemaPolicy.validate("str", compiled)
    assert {:error, _} = SchemaPolicy.validate(1, compiled)
  end

  test "a fetched property named dynamicRef retains its property schema" do
    document = %{"type" => "object", "properties" => %{"$dynamicRef" => %{"type" => "string"}}}

    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "$ref" => "https://schemas.example.com/properties.json"
    }

    assert {:ok, compiled} = SchemaPolicy.compile(schema, resolver_options(document))
    assert :ok = SchemaPolicy.validate(%{"$dynamicRef" => "str"}, compiled)
    assert {:error, _} = SchemaPolicy.validate(%{"$dynamicRef" => 1}, compiled)
  end

  test "an annotation selected as a schema is checked for actual dynamic keywords" do
    document = %{"$ref" => "#/x-meta", "x-meta" => %{"$dynamicRef" => "#node"}}

    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "$ref" => "https://schemas.example.com/targeted.json"
    }

    assert {:error, :network_ref_forbidden} =
             SchemaPolicy.compile(schema, resolver_options(document))
  end

  test "a root can select a fetched literal schema and discover its remote dependency" do
    a = "https://schemas.example.com/a.json"
    b = "https://schemas.example.com/b.json"
    documents = %{a => %{"const" => %{"$ref" => b}}, b => %{"type" => "integer"}}
    schema = %{"$schema" => "http://json-schema.org/draft-07/schema#", "$ref" => a <> "#/const"}
    assert {:ok, compiled} = SchemaPolicy.compile(schema, documents_options(documents))
    assert :ok = SchemaPolicy.validate(1, compiled)
    assert {:error, _} = SchemaPolicy.validate("str", compiled)
  end

  test "a foreign pointer promotes annotation context for the fetched keyword guard" do
    a = "https://schemas.example.com/a.json"

    document = %{
      "x-meta" => %{"$dynamicRef" => "#/definitions/int"},
      "definitions" => %{"int" => %{"type" => "integer"}}
    }

    schema = %{"$schema" => "http://json-schema.org/draft-07/schema#", "$ref" => a <> "#/x-meta"}

    assert {:error, :network_ref_forbidden} =
             SchemaPolicy.compile(schema, documents_options(%{a => document}))
  end

  test "cycles through foreign literal targets are rejected" do
    a = "https://schemas.example.com/a.json"
    b = "https://schemas.example.com/b.json"
    documents = %{a => %{"const" => %{"$ref" => b}}, b => %{"$ref" => a <> "#/const"}}
    schema = %{"$schema" => "http://json-schema.org/draft-07/schema#", "$ref" => a <> "#/const"}

    assert {:error, {:network_schema_error, :reference_cycle}} =
             SchemaPolicy.compile(schema, documents_options(documents))
  end

  test "foreign literal dependencies obey reference depth before another fetch" do
    a = "https://schemas.example.com/a.json"
    b = "https://schemas.example.com/b.json"
    documents = %{a => %{"const" => %{"$ref" => b}}, b => %{"type" => "integer"}}
    counter = start_supervised!({Agent, fn -> [] end})

    opts =
      resolver_options(fn uri ->
        Agent.update(counter, &[to_string(uri) | &1])
        Map.fetch!(documents, to_string(uri))
      end)

    opts = Keyword.update!(opts, :network_refs, &Keyword.put(&1, :max_reference_depth, 0))
    schema = %{"$schema" => "http://json-schema.org/draft-07/schema#", "$ref" => a <> "#/const"}

    assert {:error, {:network_schema_error, :reference_depth}} =
             SchemaPolicy.compile(schema, opts)

    assert Agent.get(counter, & &1) == [a]
  end

  test "foreign literal targets obey per-document schema limits" do
    a = "https://schemas.example.com/a.json"
    document = %{"const" => %{"allOf" => [%{"type" => "integer"}]}}
    schema = %{"$schema" => "http://json-schema.org/draft-07/schema#", "$ref" => a <> "#/const"}
    opts = documents_options(%{a => document})

    assert {:error, {:schema_limit_exceeded, :max_subschemas, 3}} =
             SchemaPolicy.compile(schema, Keyword.put(opts, :max_subschemas, 2))

    assert {:error, {:schema_limit_exceeded, :max_composition_depth, 1}} =
             SchemaPolicy.compile(schema, Keyword.put(opts, :max_composition_depth, 0))
  end

  test "a permitted retrieval supplies its declared alias before an outside-host fetch" do
    a = "https://schemas.example.com/a.json"
    canonical = "https://aaa.example/number.json"
    documents = %{a => %{"$id" => canonical, "type" => "integer"}}

    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "allOf" => [%{"$ref" => canonical}, %{"$ref" => a}]
    }

    assert {:ok, compiled} = SchemaPolicy.compile(schema, documents_options(documents))
    assert :ok = SchemaPolicy.validate(1, compiled)
    assert {:error, _} = SchemaPolicy.validate("str", compiled)
  end

  test "the input resource is available to fetched documents without refetching it" do
    root = "https://schemas.example.com/root.json"
    b = "https://schemas.example.com/b.json"
    schema = %{"$schema" => "http://json-schema.org/draft-07/schema#", "$id" => root, "$ref" => b}

    assert {:error, {:network_schema_error, :reference_cycle}} =
             SchemaPolicy.compile(schema, documents_options(%{b => %{"$ref" => root}}))
  end

  test "equivalent HTTP document locations share one admission" do
    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "allOf" => [
        %{"$ref" => "https://schemas.example.com"},
        %{"$ref" => "https://schemas.example.com/"},
        %{"$ref" => "https://SCHEMAS.example.com:443/"},
        %{"$ref" => "https://schemas.example.com./"}
      ]
    }

    opts = resolver_options(%{"type" => "integer"})
    opts = Keyword.update!(opts, :network_refs, &Keyword.put(&1, :max_documents, 1))

    assert {:ok, compiled} = SchemaPolicy.compile(schema, opts)
    assert :ok = SchemaPolicy.validate(1, compiled)
    assert {:error, _} = SchemaPolicy.validate("str", compiled)
  end

  defp documents_options(documents) do
    resolver_options(fn uri -> Map.fetch!(documents, to_string(uri)) end)
  end

  test "the existing default fragment-only policy also covers annotation ref strings" do
    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "type" => "integer",
      "x-meta" => %{"$ref" => "https://outside.example/schema"}
    }

    assert {:error, :network_ref_forbidden} = SchemaPolicy.compile(schema)
  end

  test "annotation identifiers cannot supply a schema for a remote reference" do
    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "$ref" => "https://ghost.example/id",
      "x-meta" => %{"$id" => "https://ghost.example/id", "type" => "integer"}
    }

    assert {:error, {:network_schema_error, :host_not_allowed}} =
             SchemaPolicy.compile(schema, resolver_options(%{}))
  end

  test "an explicitly selected annotation registers its actual schema identifier" do
    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "allOf" => [%{"$ref" => "#/x-meta"}, %{"$ref" => "https://ghost.example/id"}],
      "x-meta" => %{"$id" => "https://ghost.example/id", "type" => "integer"}
    }

    assert {:ok, compiled} = SchemaPolicy.compile(schema, resolver_options(%{}))
    assert :ok = SchemaPolicy.validate(1, compiled)
    assert {:error, _} = SchemaPolicy.validate("str", compiled)
  end

  test "selected descendants do not inherit identifiers from annotation ancestors" do
    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "$id" => "https://schemas.example.com/root.json",
      "$ref" => "#/x-meta/child",
      "definitions" => %{"word" => %{"type" => "integer"}},
      "x-meta" => %{
        "$id" => "https://ghost.example/id",
        "child" => %{"$ref" => "#/definitions/word"}
      }
    }

    assert {:ok, compiled} = SchemaPolicy.compile(schema)
    assert :ok = SchemaPolicy.validate(1, compiled)
    assert {:error, _} = SchemaPolicy.validate("str", compiled)
  end

  test "promoted annotations also promote named containers and property schemas" do
    document = %{
      "$ref" => "#/x-meta",
      "x-meta" => %{
        "properties" => %{
          "foo" => %{"$dynamicRef" => "#node"}
        }
      }
    }

    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "$ref" => "https://schemas.example.com/promoted.json"
    }

    assert {:error, :network_ref_forbidden} =
             SchemaPolicy.compile(schema, resolver_options(document))
  end

  test "annotation refs do not activate literal data or register annotation IDs" do
    literal = %{"$ref" => "https://unused.example/data.json"}

    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "type" => "integer",
      "default" => literal,
      "x-meta" => %{"$ref" => "#/default"}
    }

    assert {:ok, compiled} = SchemaPolicy.compile(schema)
    assert :ok = SchemaPolicy.validate(1, compiled)
    assert {:error, _} = SchemaPolicy.validate("str", compiled)
  end

  test "fetched legacy documents retain their own meta-schema during compilation" do
    for {root_draft, remote_draft, bounds} <- [
          {"07", "04", %{"maximum" => 5, "exclusiveMaximum" => true}},
          {"04", "07", %{"exclusiveMaximum" => 5}}
        ] do
      schema = %{
        "$schema" => "http://json-schema.org/draft-#{root_draft}/schema#",
        "$ref" => "https://schemas.example.com/bounds.json"
      }

      remote = Map.put(bounds, "$schema", "http://json-schema.org/draft-#{remote_draft}/schema#")
      assert {:ok, _compiled} = SchemaPolicy.compile(schema, resolver_options(remote))
    end
  end

  test "referenced literal copies retain their existing validation context" do
    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "$ref" => "https://schemas.example.com/bounds.json#/default"
    }

    remote = %{
      "$schema" => "http://json-schema.org/draft-04/schema#",
      "default" => %{"exclusiveMaximum" => 5}
    }

    assert {:ok, compiled} = SchemaPolicy.compile(schema, resolver_options(remote))
    assert :ok = SchemaPolicy.validate(4, compiled)
    assert {:error, _} = SchemaPolicy.validate(6, compiled)
  end

  test "draft4 boolean literal targets do not acquire a definitions meta-schema check" do
    schema = %{
      "$schema" => "http://json-schema.org/draft-04/schema#",
      "default" => false,
      "$ref" => "#/default"
    }

    assert {:ok, compiled} = SchemaPolicy.compile(schema)
    assert {:error, _} = SchemaPolicy.validate(1, compiled)
  end

  defp resolver_options(document) do
    [
      network_refs: [
        enabled: true,
        allowed_hosts: ["schemas.example.com"],
        dns_resolver: fn _, _ -> {:ok, [{93, 184, 216, 34}]} end,
        http_client: fn uri, _, _ ->
          document = if is_function(document, 1), do: document.(uri), else: document
          {:ok, %{status: 200, headers: [], body: Jason.encode!(document)}}
        end
      ]
    ]
  end
end
