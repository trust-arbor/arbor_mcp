defmodule McpAppsHost.ConnectionTest do
  use ExUnit.Case, async: true
  alias McpAppsHost.Connection
  alias Arbor.MCP.Apps

  test "host configuration accepts literal loopback URLs only" do
    assert :ok = Connection.validate_url("http://127.0.0.1:8080/mcp")

    for url <- [
          "http://localhost:8080/mcp",
          "https://example.com/mcp",
          "http://user@127.0.0.1/mcp",
          "http://127.0.0.1/mcp#fragment"
        ] do
      assert {:error, _reason} = Connection.validate_url(url)
    end
  end

  test "the local profile accepts self-contained text/blob and rejects unsupported policy" do
    uri = "ui://arbor/plan.html"
    html = "<!doctype html><title>Local app</title>"
    {:ok, text} = Apps.html(uri, html)
    assert {:ok, %{html: ^html}} = Connection.document(%{"contents" => [text]}, uri)
    {:ok, blob} = Apps.blob(uri, Base.encode64(html))
    assert {:ok, %{html: ^html}} = Connection.document(%{"contents" => [blob]}, uri)

    for ui <- [
          %{"csp" => %{"connectDomains" => ["https://example.com"]}},
          %{"csp" => %{"resourceDomains" => ["https://example.com"]}},
          %{"csp" => %{"frameDomains" => ["https://example.com"]}},
          %{"csp" => %{"baseUriDomains" => ["https://example.com"]}},
          %{"permissions" => %{"camera" => %{}}},
          %{"domain" => "example.com"},
          %{"csp" => %{"newDirective" => []}}
        ] do
      assert {:error, _reason} = Connection.local_policy(ui)
      {:ok, item} = Apps.html(uri, html, ui)
      assert {:error, _reason} = Connection.document(%{"contents" => [item]}, uri)
    end

    for item <- [
          Map.put(text, "blob", Base.encode64(html)),
          Map.put(text, "uri", "ui://other/view"),
          Map.put(text, "mimeType", "text/html"),
          Map.put(text, "_meta", "invalid"),
          Map.put(text, "text", String.duplicate("x", 1_048_577))
        ] do
      assert {:error, _reason} = Connection.document(%{"contents" => [item]}, uri)
    end
  end

  test "model text selection excludes private and structured fields" do
    assert Connection.text(%{
             "content" => [%{"type" => "text", "text" => "Public text"}],
             "structuredContent" => %{"secret" => "UI data"},
             "_meta" => %{"secret" => "UI metadata"}
           }) == "Public text"
  end
end
