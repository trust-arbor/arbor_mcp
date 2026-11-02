defmodule Arbor.MCP.AppsTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Apps

  @uri "ui://quote/view.html"
  @tool %{"name" => "quote", "inputSchema" => %{"type" => "object"}}

  @tag assurance: ["apps.capability"]
  test "advertises the required MIME settings explicitly, preserving other capabilities" do
    capabilities = %{
      "roots" => %{},
      "extensions" => %{
        "example/other" => %{},
        Apps.identifier() => %{"future" => true, "mimeTypes" => ["application/example"]}
      }
    }

    actual = Apps.put_capability(capabilities)
    assert Apps.supported?(actual)
    assert actual["roots"] == %{}
    assert actual["extensions"]["example/other"] == %{}

    assert actual["extensions"][Apps.identifier()] == %{
             "future" => true,
             "mimeTypes" => ["application/example", Apps.mime_type()]
           }

    assert Apps.put_capability(actual) == actual

    for settings <- [
          nil,
          true,
          %{},
          %{"mimeTypes" => "text/html"},
          %{"mimeTypes" => [Apps.mime_type(), 42]}
        ] do
      refute Apps.supported?(%{"extensions" => %{Apps.identifier() => settings}})
    end

    refute Apps.supported?(%{})
    refute Apps.supported?(nil)
  end

  @tag assurance: ["apps.tool.metadata"]
  test "links a tool using nested metadata and the compatibility alias without losing data" do
    definition =
      Map.put(@tool, "_meta", %{"example/data" => %{"n" => 1}, "ui" => %{"future" => "kept"}})

    assert {:ok, tool} = Apps.tool(definition, %{"resourceUri" => @uri})

    assert tool["_meta"] == %{
             "example/data" => %{"n" => 1},
             "ui" => %{"future" => "kept", "resourceUri" => @uri},
             "ui/resourceUri" => @uri
           }

    assert Apps.visible_to?(tool, :model)
    assert Apps.visible_to?(tool, :app)
    assert tool["inputSchema"] == @tool["inputSchema"]
    legacy = Map.put(@tool, "_meta", %{"ui/resourceUri" => @uri})
    assert {:ok, upgraded} = Apps.tool(legacy, %{})
    assert upgraded["_meta"]["ui"]["resourceUri"] == @uri
  end

  @tag assurance: ["apps.tool.invalid"]
  test "rejects malformed URI/visibility metadata and conflicting resource aliases" do
    for ui <- [
          %{"resourceUri" => "https://example.test/ui"},
          %{"resourceUri" => "ui://"},
          %{"resourceUri" => nil},
          %{"visibility" => ["admin"]},
          %{"visibility" => "app"},
          %{"visibility" => nil},
          %{"csp" => %{}}
        ] do
      assert {:error, {:invalid_app_field, _field}} = Apps.tool(@tool, ui)
    end

    legacy = Map.put(@tool, "_meta", %{"ui/resourceUri" => "ui://other/view.html"})

    assert {:error, {:invalid_app_field, "ui/resourceUri"}} =
             Apps.tool(legacy, %{"resourceUri" => @uri})

    assert {:error, _} = Apps.tool(Map.put(@tool, "_meta", nil), %{})
    assert {:error, _} = Apps.tool(@tool, nil)
  end

  @tag assurance: ["apps.visibility"]
  test "default, model-only, app-only and empty visibility retain their distinct meanings" do
    for {visibility, model?, app?} <- [
          {["model"], true, false},
          {["app"], false, true},
          {[], false, false},
          {["app", "app"], false, true}
        ] do
      assert {:ok, tool} = Apps.tool(@tool, %{"visibility" => visibility})
      assert Apps.visible_to?(tool, :model) == model?
      assert Apps.visible_to?(tool, :app) == app?
    end

    assert Apps.visible_to?(@tool, :model)
    assert Apps.visible_to?(@tool, :app)
    refute Apps.visible_to?(%{"_meta" => %{"ui" => %{"visibility" => "model"}}}, :model)
    refute Apps.visible_to?(@tool, :unknown)
  end

  @tag assurance: ["apps.fallback"]
  test "non-Apps hosts get model tools without UI metadata; Apps hosts get the complete catalog" do
    base = Map.put(@tool, "_meta", %{"example/data" => true})
    assert {:ok, tool} = Apps.tool(base, %{"resourceUri" => @uri})
    assert {:ok, private} = Apps.tool(%{@tool | "name" => "refresh"}, %{"visibility" => ["app"]})
    assert {:ok, [^base]} = Apps.tools_for_client([tool, private], %{})

    assert {:ok, [^base]} =
             Apps.tools_for_client([tool, private], %{"extensions" => %{Apps.identifier() => %{}}})

    assert {:ok, [^tool, ^private]} =
             Apps.tools_for_client([tool, private], Apps.put_capability())

    assert {:error, _} = Apps.tools_for_client([%{"_meta" => %{"ui" => false}}], %{})
  end

  @tag assurance: ["apps.resource"]
  test "UI declarations and text/blob read contents carry the exact MIME type" do
    assert {:ok, resource} = Apps.resource(%{"uri" => @uri, "name" => "Quote"})
    assert resource["mimeType"] == Apps.mime_type()
    html = "<!doctype html><html><title>Quote</title><body>42</body></html>"
    assert {:ok, text} = Apps.html(@uri, html)
    assert text == %{"uri" => @uri, "mimeType" => Apps.mime_type(), "text" => html}
    assert {:ok, blob} = Apps.blob(@uri, Base.encode64(html))
    assert blob == %{"uri" => @uri, "mimeType" => Apps.mime_type(), "blob" => Base.encode64(html)}

    for bad <- ["", nil, 42, "not base64"] do
      assert {:error, _} = Apps.blob(@uri, bad)
    end

    assert {:error, _} = Apps.html(@uri, <<255>>)

    assert {:error, _} =
             Apps.resource(%{"uri" => @uri, "name" => "Quote", "mimeType" => "text/html"})

    assert {:error, _} = Apps.resource(%{"uri" => "file:///quote", "name" => "Quote"})
  end

  @tag assurance: ["apps.resource.metadata"]
  test "resource CSP, permissions and presentation fields live on UI resource metadata" do
    ui = %{
      "csp" => %{
        "connectDomains" => [],
        "resourceDomains" => [],
        "frameDomains" => [],
        "baseUriDomains" => []
      },
      "permissions" => %{"clipboardWrite" => %{}},
      "domain" => "host-defined.example",
      "prefersBorder" => false
    }

    assert {:ok, resource} =
             Apps.resource(
               %{"uri" => @uri, "name" => "Quote", "_meta" => %{"example/other" => 1}},
               ui
             )

    assert resource["_meta"] == %{"example/other" => 1, "ui" => ui}
    assert {:ok, content} = Apps.html(@uri, "<!doctype html><title>Quote</title>", ui)
    assert content["_meta"]["ui"] == ui

    for bad <- [
          %{"csp" => []},
          %{"csp" => %{"connectDomains" => "*"}},
          %{"permissions" => %{"camera" => true}},
          %{"prefersBorder" => "yes"},
          %{"domain" => nil}
        ] do
      assert {:error, _} = Apps.html(@uri, "<!doctype html><title>Quote</title>", bad)
    end
  end

  @tag assurance: ["apps.catalog"]
  test "linked UI resources must exist in the registered catalog, including hidden resources" do
    assert {:ok, tool} = Apps.tool(@tool, %{"resourceUri" => @uri})
    assert {:ok, resource} = Apps.resource(%{"uri" => @uri, "name" => "Quote"})
    assert :ok = Apps.validate_catalog([tool, @tool], [resource])
    assert {:error, {:missing_ui_resource, @uri}} = Apps.validate_catalog([tool], [])
    assert {:error, _} = Apps.validate_catalog([%{"_meta" => %{"ui" => false}}], [resource])
  end
end
