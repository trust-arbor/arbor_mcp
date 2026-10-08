defmodule Arbor.MCP.Server.DSLTest do
  use ExUnit.Case, async: true

  defmodule ModernServer do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL

    tool "echo", "Echo back the input" do
      title("Echo Tool")
      param(:message, :string, required: true, description: "Message to echo")
      param(:tags, {:array, :string}, default: [])
      annotations(readOnlyHint: true)

      output_schema(%{
        type: "object",
        properties: %{echo: %{type: "string"}},
        required: ["echo"]
      })

      run(fn %{message: message}, state ->
        {:ok, ToolResult.structured(message, %{echo: message}),
         Map.put(state, :last_tool, message)}
      end)
    end

    tool "invalid_output", "Returns invalid structured content" do
      output_schema(%{
        type: "object",
        properties: %{count: %{type: "integer"}},
        required: ["count"]
      })

      run(fn _args, state ->
        {:ok, %{content: [], structuredContent: %{count: "not an integer"}}, state}
      end)
    end

    resource "config://app", "Application configuration" do
      title("App Config")
      mime_type("application/json")

      read(fn %{uri: uri}, state ->
        {:ok, %{text: ~s({"enabled":true})}, Map.put(state, :last_resource, uri)}
      end)
    end

    resource_template "file:///{path}", "File contents" do
      title("File Contents")
      mime_type("text/plain")
      param(:path, :string)

      read(fn %{path: path, uri: uri}, state ->
        {:ok, "contents for #{path} at #{uri}", state}
      end)
    end

    prompt "code_review", "Review code" do
      title("Code Review")
      arg(:code, required: true, description: "Code to review")

      render(fn %{code: code}, state ->
        {:ok,
         %{
           messages: [
             %{role: "user", content: %{type: "text", text: "Review this code:\n#{code}"}}
           ]
         }, state}
      end)
    end
  end

  test "lists tools with generated schemas and spec-aligned metadata" do
    assert {:ok, tools, nil, %{}} = ModernServer.handle_list_tools(nil, %{})

    echo = Enum.find(tools, &(&1.name == "echo"))

    assert echo.title == "Echo Tool"
    assert echo.description == "Echo back the input"
    assert echo.annotations == %{readOnlyHint: true}

    assert echo.inputSchema == %{
             type: "object",
             properties: %{
               message: %{type: "string", description: "Message to echo"},
               tags: %{type: "array", items: %{type: "string"}, default: []}
             },
             required: ["message"]
           }

    assert echo.outputSchema == %{
             type: "object",
             properties: %{echo: %{type: "string"}},
             required: ["echo"]
           }
  end

  test "dispatches tools with normalized arguments and preserves structuredContent" do
    assert {:ok, result, state} =
             ModernServer.handle_call_tool("echo", %{"message" => "hello"}, %{})

    assert result == %{
             content: [%{type: "text", text: "hello"}],
             structuredContent: %{echo: "hello"}
           }

    assert state.last_tool == "hello"
    refute Map.has_key?(result, :structuredOutput)
  end

  test "turns tool output schema failures into MCP tool errors" do
    assert {:ok, result, %{}} = ModernServer.handle_call_tool("invalid_output", %{}, %{})

    assert result.isError == true
    assert [%{type: "text", text: message}] = result.content
    assert message =~ "Output validation failed"
  end

  test "unknown tool names are a JSON-RPC invalid-params protocol error" do
    assert {:error, %Arbor.MCP.Error.ProtocolError{} = error, %{}} =
             ModernServer.handle_call_tool("nope", %{}, %{})

    assert error.code == -32602
    assert error.message == "Unknown tool: nope"
  end

  test "unknown resource names are a JSON-RPC invalid-params protocol error" do
    assert {:error, %Arbor.MCP.Error.ProtocolError{} = error, %{}} =
             ModernServer.handle_read_resource("missing://x", %{})

    assert error.code == Arbor.MCP.Protocol.ErrorCodes.resource_not_found(:modern)
    assert error.message == "Resource not found: missing://x"
  end

  test "unknown prompt names are a JSON-RPC invalid-params protocol error" do
    assert {:error, %Arbor.MCP.Error.ProtocolError{} = error, %{}} =
             ModernServer.handle_get_prompt("nope", %{}, %{})

    assert error.code == -32602
    assert error.message == "Prompt not found: nope"
  end

  test "lists and reads static resources" do
    assert {:ok, resources, nil, %{}} = ModernServer.handle_list_resources(nil, %{})
    assert [%{uri: "config://app", title: "App Config", mimeType: "application/json"}] = resources

    assert {:ok, content, state} = ModernServer.handle_read_resource("config://app", %{})

    assert content == %{
             uri: "config://app",
             text: ~s({"enabled":true}),
             mimeType: "application/json"
           }

    assert state.last_resource == "config://app"
  end

  test "lists and reads resource templates with extracted variables" do
    assert {:ok, templates, nil, %{}} = ModernServer.handle_list_resource_templates(nil, %{})

    assert [
             %{
               uriTemplate: "file:///{path}",
               title: "File Contents",
               mimeType: "text/plain"
             }
           ] = templates

    assert {:ok, content, %{}} = ModernServer.handle_read_resource("file:///notes.txt", %{})

    assert content == %{
             uri: "file:///notes.txt",
             text: "contents for notes.txt at file:///notes.txt",
             mimeType: "text/plain"
           }
  end

  test "lists and renders prompts with normalized arguments" do
    assert {:ok, prompts, nil, %{}} = ModernServer.handle_list_prompts(nil, %{})

    assert [
             %{
               name: "code_review",
               title: "Code Review",
               arguments: [
                 %{name: "code", description: "Code to review", required: true}
               ]
             }
           ] = prompts

    assert {:ok, result, %{}} =
             ModernServer.handle_get_prompt("code_review", %{"code" => "IO.puts(:ok)"}, %{})

    assert result == %{
             messages: [
               %{
                 role: "user",
                 content: %{type: "text", text: "Review this code:\nIO.puts(:ok)"}
               }
             ]
           }
  end
end
