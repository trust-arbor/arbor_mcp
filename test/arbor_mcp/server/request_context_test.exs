defmodule Arbor.MCP.Server.RequestContextTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.RequestContext

  test "extracts a complete modern request context" do
    request = modern_request()

    assert {:ok, context} = RequestContext.from_message(request)
    assert context.era == :modern
    assert context.method == "tools/call"
    assert context.request_id == 12
    assert context.protocol_version == "2026-07-28"
    assert context.client_capabilities == %{"elicitation" => %{}}
    assert context.client_info["name"] == "client"
    assert context.progress_token == "progress-1"
    assert context.input_responses == %{"sample" => %{"model" => "example"}}
    assert context.request_state == "opaque-state"
  end

  test "keeps legacy metadata source-compatible" do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => "example",
        "_meta" => %{"progressToken" => 99, "legacy key" => true}
      }
    }

    assert {:ok, context} = RequestContext.from_message(request)
    assert context.era == :legacy
    assert context.progress_token == 99
    assert context.meta["legacy key"]
  end

  test "requires both modern metadata fields" do
    request =
      put_in(modern_request(), ["params", "_meta"], %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28"
      })

    assert {:error, {:missing_meta_field, "io.modelcontextprotocol/clientCapabilities"}} =
             RequestContext.from_message(request)
  end

  test "rejects stateless requests that select a legacy or unknown version" do
    for version <- ["2025-11-25", "2099-01-01"] do
      request =
        put_in(
          modern_request(),
          ["params", "_meta", "io.modelcontextprotocol/protocolVersion"],
          version
        )

      assert {:error, {:unsupported_protocol_version, ^version}} =
               RequestContext.from_message(request)
    end
  end

  test "parses subscription correlation on notifications" do
    notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/tools/list_changed",
      "params" => %{
        "_meta" => %{"io.modelcontextprotocol/subscriptionId" => "sub-1"}
      }
    }

    assert {:ok, context} = RequestContext.from_message(notification)
    refute context.request?
    assert context.meta["io.modelcontextprotocol/subscriptionId"] == "sub-1"
  end

  test "builds stable JSON-RPC errors without echoing arbitrary invalid terms" do
    invalid = RequestContext.error_response({:invalid_meta_key, self()}, 1)

    assert invalid["error"]["code"] == -32602
    assert invalid["error"]["data"] == %{"reason" => "invalid_key"}

    unsupported =
      RequestContext.error_response({:unsupported_protocol_version, "2099-01-01"}, 2)

    assert unsupported["error"]["code"] == -32022
    assert unsupported["error"]["data"]["requested"] == "2099-01-01"
    assert is_list(unsupported["error"]["data"]["supported"])

    modern_only =
      RequestContext.error_response(
        {:unsupported_protocol_version, "2099-01-01"},
        3,
        :modern_only
      )

    assert modern_only["error"]["data"]["supported"] == ["2026-07-28"]
    assert RequestContext.http_status({:invalid_meta, :not_an_object}) == 400
  end

  test "checks nested required client capabilities" do
    assert {:ok, context} = RequestContext.from_message(modern_request())

    assert :ok =
             RequestContext.require_client_capabilities(context, %{"elicitation" => %{}})

    assert {:error, error} =
             RequestContext.require_client_capabilities(context, %{
               "sampling" => %{"tools" => %{}}
             })

    assert error.code == -32021

    assert error.data == %{
             "requiredCapabilities" => %{"sampling" => %{"tools" => %{}}}
           }
  end

  test "validates the era-specific method surface" do
    assert {:ok, modern} = RequestContext.from_message(modern_request())
    assert :ok = RequestContext.validate_method(modern)

    removed = %{modern | method: "ping"}

    assert {:error, {:method_not_available, "ping", "2026-07-28"}} =
             RequestContext.validate_method(removed)
  end

  test "requires the official extension on every modern task request" do
    assert {:ok, context} = RequestContext.from_message(modern_request())

    for method <- ["tasks/get", "tasks/update", "tasks/cancel"] do
      assert {:error, error} = RequestContext.validate_method(%{context | method: method})
      assert error.code == -32021
    end

    capabilities = %{
      "extensions" => %{"io.modelcontextprotocol/tasks" => %{}}
    }

    context = %{context | method: "tasks/get", client_capabilities: capabilities}
    assert :ok = RequestContext.validate_method(context)

    assert {:error, {:method_not_available, "tasks/list", "2026-07-28"}} =
             RequestContext.validate_method(%{context | method: "tasks/list"})

    assert {:error, {:method_not_available, "tasks/result", "2026-07-28"}} =
             RequestContext.validate_method(%{context | method: "tasks/result"})
  end

  defp modern_request do
    %{
      "jsonrpc" => "2.0",
      "id" => 12,
      "method" => "tools/call",
      "params" => %{
        "name" => "example",
        "arguments" => %{},
        "inputResponses" => %{"sample" => %{"model" => "example"}},
        "requestState" => "opaque-state",
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}},
          "io.modelcontextprotocol/clientInfo" => %{
            "name" => "client",
            "version" => "1"
          },
          "progressToken" => "progress-1"
        }
      }
    }
  end
end
