defmodule Arbor.MCP.Compliance.ProtocolVsExecutionErrorTest do
  @moduledoc """
  MCP 2026-07-28: unknown names are JSON-RPC protocol errors (-32602),
  while registered-tool execution failures stay result isError: true.
  """
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Error.ProtocolError
  alias Arbor.MCP.Protocol.ErrorCodes
  alias Arbor.MCP.Server.HandlerServer

  defmodule ProtocolServer do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "protocol-vs-error", version: "1.0.0"

    tool "echo", "Echo back the input" do
      param(:message, :string, required: true)

      run(fn %{message: message}, state ->
        {:ok, ToolResult.text(message), state}
      end)
    end

    tool "failing", "Registered tool that reports an execution error" do
      run(fn _args, state ->
        {:ok, ToolResult.error("boom"), state}
      end)
    end

    resource "config://app", "Application configuration" do
      read(fn %{uri: uri}, state ->
        {:ok, %{text: "{}"}, Map.put(state, :last_resource, uri)}
      end)
    end

    prompt "greet", "Greeting prompt" do
      render(fn _args, state ->
        {:ok,
         %{
           messages: [
             %{role: "user", content: %{type: "text", text: "hello"}}
           ]
         }, state}
      end)
    end
  end

  defmodule MigratedToolsServer do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL

    tool "echo", "Echo back the input" do
      param(:message, :string, required: true)

      run(fn %{message: message}, state ->
        {:ok, ToolResult.text(message), state}
      end)
    end
  end

  describe "DSL handle_* callbacks" do
    test "unknown tool is ProtocolError -32602" do
      assert {:error, %ProtocolError{} = error, %{}} =
               ProtocolServer.handle_call_tool("nope", %{}, %{})

      assert error.code == -32602
      assert error.message == "Unknown tool: nope"
    end

    test "unknown resource is ProtocolError with modern resource_not_found" do
      assert {:error, %ProtocolError{} = error, %{}} =
               ProtocolServer.handle_read_resource("missing://x", %{})

      assert error.code == ErrorCodes.resource_not_found(:modern)
      assert error.code == -32602
      assert error.message == "Resource not found: missing://x"
    end

    test "unknown prompt is ProtocolError -32602" do
      assert {:error, %ProtocolError{} = error, %{}} =
               ProtocolServer.handle_get_prompt("nope", %{}, %{})

      assert error.code == -32602
      assert error.message == "Prompt not found: nope"
    end

    test "registered tool Result.error stays isError" do
      assert {:ok, result, %{}} = ProtocolServer.handle_call_tool("failing", %{}, %{})
      assert result.isError == true
      assert [%{type: "text", text: "boom"}] = result.content
    end
  end

  describe "Dispatch via Client + transport: :test" do
    setup do
      {:ok, server} = ProtocolServer.start_link(transport: :test)

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      Process.sleep(50)

      {:ok, server: server, client: client}
    end

    test "unknown tool is JSON-RPC -32602, never isError", %{client: client} do
      assert {:error, error} = Client.call_tool(client, "nope", %{})
      refute match?({:ok, _}, Client.call_tool(client, "nope", %{}))
      assert error.code == -32602
      assert error.message =~ "Unknown tool: nope"
    end

    test "unknown resource is JSON-RPC -32602", %{client: client} do
      assert {:error, error} = Client.read_resource(client, "missing://x")
      assert error.code == -32602
      assert error.message =~ "Resource not found: missing://x"
    end

    test "unknown prompt is JSON-RPC -32602", %{client: client} do
      assert {:error, error} = Client.get_prompt(client, "nope", %{})
      assert error.code == -32602
      assert error.message =~ "Prompt not found: nope"
    end

    test "registered tool Result.error stays {:ok, isError: true}", %{client: client} do
      assert {:ok, result} = Client.call_tool(client, "failing", %{})
      assert result.is_error == true
    end
  end

  describe "migrated Handler + DSL consumer" do
    test "unknown tool is protocol -32602, not isError" do
      assert {:error, %ProtocolError{} = error, %{}} =
               MigratedToolsServer.handle_call_tool("nope", %{}, %{})

      assert error.code == -32602
      assert error.message == "Unknown tool: nope"
    end

    test "unknown tool through Dispatch is -32602, not isError" do
      {:ok, server} =
        HandlerServer.start_link(
          handler: MigratedToolsServer,
          transport: :test
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      Process.sleep(50)

      assert {:error, error} = Client.call_tool(client, "nope", %{})
      assert error.code == -32602
      refute match?({:ok, %{is_error: true}}, Client.call_tool(client, "nope", %{}))
    end
  end
end
