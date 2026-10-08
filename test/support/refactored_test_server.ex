defmodule Arbor.MCP.TestHelpers.RefactoredTestServer do
  @moduledoc """
  Test server for integration testing.

  Note: This module may generate compiler warnings about unreachable clauses
  due to the DSL generating comprehensive pattern matches. These warnings are
  benign and can be ignored.
  """
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL, name: "Refactored Test Server", version: "1.0.0"

  tool "test_tool", "Test tool" do
    input_schema(%{
      "type" => "object",
      "properties" => %{"index" => %{"type" => "number"}},
      "required" => []
    })

    run(fn _args, state ->
      # Add a delay to allow tests to observe pending state.
      Process.sleep(100)
      {:ok, %{content: [%{"type" => "text", "text" => "Tool executed"}]}, state}
    end)
  end

  resource "test://resource", "A test resource for integration testing" do
    title("Test resource")

    read(fn _params, state ->
      {:ok, %{"text" => "Resource content"}, state}
    end)
  end

  prompt "test_prompt", "A test prompt for integration testing" do
    title("Test prompt")

    render(fn _args, state ->
      {:ok, %{messages: [%{role: "user", content: "Test prompt"}]}, state}
    end)
  end
end
