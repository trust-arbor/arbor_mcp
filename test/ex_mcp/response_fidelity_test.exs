defmodule ExMCP.ResponseFidelityTest do
  use ExUnit.Case, async: true
  alias ExMCP.Response

  test "wire conversion preserves envelopes, extensions, media and schema field presence" do
    raw = %{
      "content" => [
        %{"type" => "image", "data" => "AAAA", "mimeType" => "image/png", "annotations" => nil},
        %{
          "type" => "resource",
          "resource" => %{"uri" => "file:///a", "text" => "hello"},
          "_meta" => %{"x" => false}
        }
      ],
      "isError" => false,
      "_meta" => nil,
      "structuredContent" => false,
      "tools" => [
        %{
          "name" => "echo",
          "inputSchema" => %{"type" => "object", "properties" => %{"a" => %{"type" => "string"}}}
        }
      ],
      "resources" => [%{"uri" => "file:///a", "mimeType" => nil}],
      "resourceTemplates" => [%{"uriTemplate" => "file:///{path}"}],
      "prompts" => [%{"name" => "ask", "arguments" => [%{"name" => "a", "required" => false}]}],
      "messages" => [
        %{
          "role" => "assistant",
          "content" => %{"type" => "text", "text" => "hello", "_meta" => %{}}
        }
      ],
      "contents" => [%{"uri" => "file:///a", "text" => "hello"}],
      "roots" => [%{"uri" => "file:///"}],
      "nextCursor" => nil,
      "description" => "prompt",
      "completion" => %{"values" => ["a"], "total" => 1, "hasMore" => false},
      "resultType" => "mixed",
      "ttlMs" => 0,
      "cacheScope" => "session",
      "resourceLinks" => [],
      "extension" => %{"enabled" => false}
    }

    assert raw |> Response.from_raw_response() |> Response.to_raw() == raw

    for value <- [nil, false, [], %{}] do
      input = %{"structuredContent" => value}
      assert input |> Response.from_raw_response() |> Response.to_raw() == input
    end

    aliases = %{
      "_meta" => nil,
      "meta" => %{"legacy" => true},
      "isError" => false,
      "is_error" => true,
      "structuredContent" => false,
      "structuredOutput" => %{"legacy" => true}
    }

    response = Response.from_raw_response(aliases)
    assert response.is_error == false
    assert Response.to_raw(response) == aliases
    assert %{} |> Response.from_raw_response() |> Response.to_raw() == %{}
  end

  test "1.x compatibility helper retains pagination and local wire conventions" do
    response = Response.from_raw_response(%{"tools" => [], "nextCursor" => "next"})
    assert Response.to_test_map(response).nextCursor == "next"
    refute Map.has_key?(Response.to_test_map(Response.text("hello")), :nextCursor)

    assert Response.to_raw(Response.text("hello", nil, meta: %{"trace" => true})) == %{
             "content" => [%{"type" => "text", "text" => "hello"}],
             "meta" => %{"trace" => true}
           }
  end
end
