defmodule Arbor.MCP.Integration.ServerRefactorTest do
  @moduledoc """
  Integration tests for the functional request processor and server DSL callbacks.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Protocol.RequestProcessor
  alias Arbor.MCP.TestHelpers

  @handler TestHelpers.RefactoredTestServer

  describe "request processor integration" do
    test "routes standard MCP methods through handler callbacks" do
      methods = [
        {"initialize", %{"protocolVersion" => "2025-06-18"}},
        {"tools/list", %{}},
        {"resources/list", %{}},
        {"prompts/list", %{}}
      ]

      for {method, params} <- methods do
        request = %{
          "jsonrpc" => "2.0",
          "method" => method,
          "id" => method,
          "params" => params
        }

        {:response, response, _state} = RequestProcessor.process(request, state())

        assert response["jsonrpc"] == "2.0"
        assert response["id"] == method
        assert Map.has_key?(response, "result")
        refute Map.has_key?(response, "error")
      end
    end

    test "formats tool call responses" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "id" => "tool-1",
        "params" => %{
          "name" => "test_tool",
          "arguments" => %{}
        }
      }

      {:response, response, _state} = RequestProcessor.process(request, state())

      assert response["result"]["content"] == [%{"type" => "text", "text" => "Tool executed"}]
    end

    test "formats errors for unknown methods and invalid requests" do
      state = state()

      unknown = %{"jsonrpc" => "2.0", "method" => "unknown/method", "id" => "error-1"}
      {:response, response, ^state} = RequestProcessor.process(unknown, state)

      assert response["error"]["code"] == -32601
      assert response["error"]["message"] =~ "Method not found"

      invalid = %{"jsonrpc" => "2.0", "id" => "invalid-1"}
      {:response, response, ^state} = RequestProcessor.process(invalid, state)

      assert response["error"]["code"] == -32600
      assert response["error"]["message"] == "Invalid Request"
    end

    test "notifications do not generate responses" do
      state = state()
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}

      assert {:notification, ^state} = RequestProcessor.process(notification, state)
    end
  end

  describe "server DSL callbacks" do
    test "server DSL exposes handler callbacks with expected entries" do
      Code.ensure_compiled!(@handler)

      assert function_exported?(@handler, :handle_list_tools, 2)
      assert function_exported?(@handler, :handle_list_resources, 2)
      assert function_exported?(@handler, :handle_list_prompts, 2)
      assert function_exported?(@handler, :handle_call_tool, 3)
      assert function_exported?(@handler, :handle_read_resource, 2)
      assert function_exported?(@handler, :handle_get_prompt, 3)

      assert {:ok, tools, nil, %{}} = @handler.handle_list_tools(nil, %{})
      assert Enum.any?(tools, &(&1.name == "test_tool"))

      assert {:ok, resources, nil, %{}} = @handler.handle_list_resources(nil, %{})
      assert Enum.any?(resources, &(&1.uri == "test://resource"))

      assert {:ok, prompts, nil, %{}} = @handler.handle_list_prompts(nil, %{})
      assert Enum.any?(prompts, &(&1.name == "test_prompt"))
    end

    test "initialization stores negotiated protocol version in returned state" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "id" => "init-1",
        "params" => %{"protocolVersion" => "2025-06-18"}
      }

      {:response, response, new_state} = RequestProcessor.process(request, state())

      assert response["result"]["protocolVersion"] == "2025-06-18"
      assert new_state.protocol_version == "2025-06-18"
    end
  end

  defp state do
    Code.ensure_compiled!(@handler)
    %{__module__: @handler}
  end
end
