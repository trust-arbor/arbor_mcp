defmodule Arbor.MCP.Integration.AgentSimulationTest do
  @moduledoc """
  Agent simulation integration tests for Arbor.MCP.

  Tests realistic AI agent workflows: receive user message → mock LLM decides
  to call tools/read resources/get prompts → execute via MCP → feed results
  back → LLM produces final answer. All LLM responses are scripted via MockLLM.
  """

  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Testing.{AgentClientHandler, AgentTestServer, MockLLM}

  @moduletag :integration
  @moduletag :agent_simulation
  @moduletag timeout: 60_000

  # ── Setup ────────────────────────────────────────────────────────────────

  setup do
    {:ok, server} = AgentTestServer.start_link(transport: :test)
    Process.sleep(10)

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        handler: AgentClientHandler,
        handler_state: [scenario: :default]
      )

    on_exit(fn ->
      try do
        if Process.alive?(client), do: Client.stop(client)
      catch
        :exit, _ -> :ok
      end

      try do
        if Process.alive?(server), do: GenServer.stop(server, :shutdown, 500)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, %{client: client, server: server}}
  end

  # ── Agent Loop Helper ──────────────────────────────────────────────────

  defp run_agent_loop(client, user_message, scenario, opts \\ []) do
    max_steps = Keyword.get(opts, :max_steps, 10)
    conversation = [%{role: "user", content: user_message}]

    do_agent_loop(client, conversation, scenario, 0, max_steps)
  end

  defp do_agent_loop(_client, conversation, _scenario, step, max_steps)
       when step >= max_steps do
    {:error, :max_steps_exceeded, conversation}
  end

  defp do_agent_loop(client, conversation, scenario, step, max_steps) do
    case MockLLM.decide(conversation, scenario) do
      {:tool_call, name, args} ->
        msg = execute_mcp_action(client, :tool, name, args)
        do_agent_loop(client, conversation ++ [msg], scenario, step + 1, max_steps)

      {:resource_read, uri} ->
        msg = execute_mcp_action(client, :resource, uri, nil)
        do_agent_loop(client, conversation ++ [msg], scenario, step + 1, max_steps)

      {:prompt_get, name, args} ->
        msg = execute_mcp_action(client, :prompt, name, args)
        do_agent_loop(client, conversation ++ [msg], scenario, step + 1, max_steps)

      {:text_response, text} ->
        {:ok, conversation ++ [%{role: "assistant", content: text}]}
    end
  end

  defp execute_mcp_action(client, :tool, name, args) do
    case Client.call_tool(client, name, args) do
      {:ok, %Arbor.MCP.Response{is_error: true} = result} ->
        %{role: "error", tool: name, content: extract_tool_text(result)}

      {:ok, result} ->
        %{role: "tool", tool: name, content: extract_tool_text(result)}

      {:error, error} ->
        %{role: "error", tool: name, content: extract_error_message(error)}
    end
  end

  defp execute_mcp_action(client, :resource, uri, _args) do
    case Client.read_resource(client, uri) do
      {:ok, result} -> %{role: "resource", uri: uri, content: extract_resource_text(result)}
      {:error, error} -> %{role: "error", uri: uri, content: extract_error_message(error)}
    end
  end

  defp execute_mcp_action(client, :prompt, name, args) do
    case Client.get_prompt(client, name, args) do
      {:ok, result} -> %{role: "prompt", name: name, content: extract_prompt_text(result)}
      {:error, error} -> %{role: "error", name: name, content: extract_error_message(error)}
    end
  end

  # ── Response Extraction Helpers ────────────────────────────────────────

  defp extract_tool_text(%Arbor.MCP.Response{content: content}) when is_list(content) do
    content
    |> Enum.map(& &1.text)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp extract_tool_text(%{content: content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} -> text
      %{text: text} -> text
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp extract_tool_text(_), do: ""

  defp extract_resource_text(%Arbor.MCP.Response{contents: contents}) when is_list(contents) do
    contents
    |> Enum.map(fn
      %{text: text} -> text
      %{"text" => text} -> text
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp extract_resource_text(%{text: text}) when is_binary(text), do: text
  defp extract_resource_text(%{"text" => text}) when is_binary(text), do: text
  defp extract_resource_text(_), do: ""

  defp extract_prompt_text(%Arbor.MCP.Response{messages: messages}) when is_list(messages) do
    messages
    |> Enum.map(fn
      %{content: %{text: text}} -> text
      %{content: %{"text" => text}} -> text
      %{"content" => %{"text" => text}} -> text
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp extract_prompt_text(_), do: ""

  defp extract_error_message(%Arbor.MCP.Error.ProtocolError{message: msg}), do: msg
  defp extract_error_message(%{message: msg}), do: msg
  defp extract_error_message(%{"message" => msg}), do: msg
  defp extract_error_message(error) when is_binary(error), do: error
  defp extract_error_message(error), do: inspect(error)

  # ── Conversation Inspection Helpers ────────────────────────────────────

  defp find_messages(conversation, role) do
    Enum.filter(conversation, fn msg -> msg.role == role end)
  end

  defp last_message(conversation) do
    List.last(conversation)
  end

  # ── Test Scenarios ─────────────────────────────────────────────────────

  describe "simple tool use" do
    test "agent calls weather tool and responds", %{client: client} do
      {:ok, conversation} =
        run_agent_loop(client, "What's the weather in NYC?", :simple_weather)

      # Verify the conversation structure
      assert length(conversation) == 3
      assert hd(conversation).role == "user"

      # Verify tool was called
      tool_msgs = find_messages(conversation, "tool")
      assert length(tool_msgs) == 1
      assert hd(tool_msgs).tool == "weather"

      # Verify tool result contains weather data
      tool_content = hd(tool_msgs).content
      assert tool_content =~ "NYC"
      assert tool_content =~ "72"
      assert tool_content =~ "sunny"

      # Verify final response
      assistant_msg = last_message(conversation)
      assert assistant_msg.role == "assistant"
      assert assistant_msg.content =~ "sunny"
    end
  end

  describe "multi-step reasoning" do
    test "agent reads resource then calls tool", %{client: client} do
      {:ok, conversation} =
        run_agent_loop(
          client,
          "How does authentication work in the API?",
          :multi_step_reasoning
        )

      # Should have: user → resource → tool → assistant
      assert length(conversation) == 4

      # Verify resource was read
      resource_msgs = find_messages(conversation, "resource")
      assert length(resource_msgs) == 1
      assert hd(resource_msgs).uri == "docs://api/users"
      assert hd(resource_msgs).content =~ "Authentication"

      # Verify tool was called with search
      tool_msgs = find_messages(conversation, "tool")
      assert length(tool_msgs) == 1
      assert hd(tool_msgs).tool == "search_docs"

      # Verify final response
      assert last_message(conversation).role == "assistant"
    end
  end

  describe "chained tool calls" do
    test "agent chains search_docs then create_report", %{client: client} do
      {:ok, conversation} =
        run_agent_loop(
          client,
          "Create a performance report from the docs",
          :chained_tools
        )

      # Should have: user → tool(search) → tool(report) → assistant
      assert length(conversation) == 4

      tool_msgs = find_messages(conversation, "tool")
      assert length(tool_msgs) == 2

      # First tool call: search_docs
      assert Enum.at(tool_msgs, 0).tool == "search_docs"
      search_result = Enum.at(tool_msgs, 0).content
      assert search_result =~ "performance metrics"

      # Second tool call: create_report
      assert Enum.at(tool_msgs, 1).tool == "create_report"
      report_result = Enum.at(tool_msgs, 1).content
      assert report_result =~ "Performance Report"

      # Final response
      assert last_message(conversation).role == "assistant"
      assert last_message(conversation).content =~ "performance report"
    end
  end

  describe "prompt-informed workflow" do
    test "agent gets prompt template then responds", %{client: client} do
      {:ok, conversation} =
        run_agent_loop(
          client,
          "Summarize the project status",
          :prompt_workflow
        )

      # Should have: user → prompt → assistant
      assert length(conversation) == 3

      # Verify prompt was retrieved
      prompt_msgs = find_messages(conversation, "prompt")
      assert length(prompt_msgs) == 1
      assert hd(prompt_msgs).name == "summarize"
      assert hd(prompt_msgs).content =~ "concise"

      # Verify final response
      assert last_message(conversation).role == "assistant"
    end
  end

  describe "resource discovery and read" do
    test "agent reads multiple resources and responds", %{client: client} do
      {:ok, conversation} =
        run_agent_loop(
          client,
          "What's the current system status?",
          :resource_discovery
        )

      # Should have: user → resource(config) → resource(metrics) → assistant
      assert length(conversation) == 4

      resource_msgs = find_messages(conversation, "resource")
      assert length(resource_msgs) == 2

      # First resource: config
      config_msg = Enum.at(resource_msgs, 0)
      assert config_msg.uri == "config://app/settings"
      assert config_msg.content =~ "database"

      # Second resource: metrics
      metrics_msg = Enum.at(resource_msgs, 1)
      assert metrics_msg.uri == "data://metrics/latest"
      assert metrics_msg.content =~ "cpu_usage"

      # Final response
      assert last_message(conversation).role == "assistant"
      assert last_message(conversation).content =~ "system status"
    end
  end

  describe "error recovery" do
    test "agent recovers from calling nonexistent tool", %{client: client} do
      {:ok, conversation} =
        run_agent_loop(
          client,
          "Get the weather, but I might make a mistake first",
          :error_recovery
        )

      # Should have: user → error → tool(weather) → assistant
      assert length(conversation) == 4

      # Verify the error occurred
      error_msgs = find_messages(conversation, "error")
      assert length(error_msgs) == 1

      # Verify recovery with correct tool
      tool_msgs = find_messages(conversation, "tool")
      assert length(tool_msgs) == 1
      assert hd(tool_msgs).tool == "weather"

      # Verify final response acknowledges recovery
      assert last_message(conversation).role == "assistant"
      assert last_message(conversation).content =~ "sunny"
    end
  end

  describe "full agent loop" do
    test "agent uses prompt, resource, and multiple tools", %{client: client} do
      {:ok, conversation} =
        run_agent_loop(
          client,
          "Give me a full system health analysis",
          :full_agent_loop
        )

      # Should have: user → prompt → resource → tool(weather) → tool(calculate) → assistant
      assert length(conversation) == 6

      # Verify prompt
      prompt_msgs = find_messages(conversation, "prompt")
      assert length(prompt_msgs) == 1
      assert hd(prompt_msgs).name == "analyze"

      # Verify resource
      resource_msgs = find_messages(conversation, "resource")
      assert length(resource_msgs) == 1

      # Verify tools
      tool_msgs = find_messages(conversation, "tool")
      assert length(tool_msgs) == 2
      tool_names = Enum.map(tool_msgs, & &1.tool)
      assert "weather" in tool_names
      assert "calculate" in tool_names

      # Verify final response
      assert last_message(conversation).role == "assistant"
      assert last_message(conversation).content =~ "Analysis complete"
    end
  end

  describe "concurrent operations" do
    test "multiple sequential tool calls maintain state isolation", %{client: client} do
      {:ok, conversation} =
        run_agent_loop(
          client,
          "Run several calculations and check weather",
          :concurrent_operations
        )

      # Should have: user → tool × 3 → assistant
      assert length(conversation) == 5

      tool_msgs = find_messages(conversation, "tool")
      assert length(tool_msgs) == 3

      # Verify each calculation returned correctly
      calc1 = Enum.at(tool_msgs, 0)
      assert calc1.tool == "calculate"
      assert calc1.content =~ "30"

      calc2 = Enum.at(tool_msgs, 1)
      assert calc2.tool == "calculate"
      assert calc2.content =~ "30"

      weather = Enum.at(tool_msgs, 2)
      assert weather.tool == "weather"
      assert weather.content =~ "London"

      # Final response
      assert last_message(conversation).role == "assistant"
    end
  end

  describe "tool capability discovery" do
    test "agent can discover available tools", %{client: client} do
      {:ok, tools_response} = Client.list_tools(client)

      tool_names =
        tools_response.tools
        |> Enum.map(& &1["name"])
        |> Enum.sort()

      assert "weather" in tool_names
      assert "calculate" in tool_names
      assert "search_docs" in tool_names
      assert "create_report" in tool_names
    end

    test "agent can discover available resources", %{client: client} do
      {:ok, resources_response} = Client.list_resources(client)

      resource_uris =
        resources_response.resources
        |> Enum.map(& &1["uri"])

      assert "docs://api/users" in resource_uris
      assert "config://app/settings" in resource_uris
      assert "data://metrics/latest" in resource_uris
    end

    test "agent can discover available prompts", %{client: client} do
      {:ok, prompts_response} = Client.list_prompts(client)

      prompt_names =
        prompts_response.prompts
        |> Enum.map(& &1["name"])

      assert "summarize" in prompt_names
      assert "analyze" in prompt_names
    end
  end

  describe "direct tool operations" do
    test "weather tool returns structured JSON", %{client: client} do
      {:ok, result} = Client.call_tool(client, "weather", %{"city" => "Tokyo"})

      text = Enum.at(result.content, 0).text
      data = Jason.decode!(text)

      assert data["city"] == "Tokyo"
      assert is_number(data["temperature"])
      assert is_binary(data["condition"])
    end

    test "calculate tool performs arithmetic", %{client: client} do
      {:ok, add_result} =
        Client.call_tool(client, "calculate", %{
          "operation" => "add",
          "a" => 10,
          "b" => 20
        })

      assert Enum.at(add_result.content, 0).text == "30"

      {:ok, mul_result} =
        Client.call_tool(client, "calculate", %{
          "operation" => "multiply",
          "a" => 7,
          "b" => 6
        })

      assert Enum.at(mul_result.content, 0).text == "42"
    end

    test "calculate tool handles division by zero", %{client: client} do
      {:ok, result} =
        Client.call_tool(client, "calculate", %{
          "operation" => "divide",
          "a" => 10,
          "b" => 0
        })

      assert result.is_error
      assert Enum.at(result.content, 0).text == "Division by zero"
    end

    test "search_docs returns results", %{client: client} do
      {:ok, result} =
        Client.call_tool(client, "search_docs", %{
          "query" => "authentication",
          "limit" => 3
        })

      text = Enum.at(result.content, 0).text
      results = Jason.decode!(text)

      assert is_list(results)
      assert length(results) == 3
      assert hd(results)["title"] =~ "authentication"
    end

    test "create_report generates formatted output", %{client: client} do
      {:ok, result} =
        Client.call_tool(client, "create_report", %{
          "title" => "Test Report",
          "data" => "Some test data here",
          "format" => "summary"
        })

      text = Enum.at(result.content, 0).text
      assert text =~ "# Test Report"
      assert text =~ "Summary:"
    end

    test "unknown tool returns error", %{client: client} do
      {:error, error} = Client.call_tool(client, "nonexistent", %{})

      assert error.code == -32602
      assert error.message == "Unknown tool: nonexistent"
    end
  end

  describe "direct resource operations" do
    test "reads API documentation resource", %{client: client} do
      {:ok, result} = Client.read_resource(client, "docs://api/users")

      text = Arbor.MCP.Response.resource_content(result) || extract_resource_text(result)
      assert text =~ "Users API"
      assert text =~ "Authentication"
    end

    test "reads config resource as JSON", %{client: client} do
      {:ok, result} = Client.read_resource(client, "config://app/settings")

      text = Arbor.MCP.Response.resource_content(result) || extract_resource_text(result)
      config = Jason.decode!(text)

      assert config["database"]["host"] == "localhost"
      assert config["cache"]["ttl"] == 3600
    end

    test "reads metrics resource with dynamic data", %{client: client} do
      {:ok, result} = Client.read_resource(client, "data://metrics/latest")

      text = Arbor.MCP.Response.resource_content(result) || extract_resource_text(result)
      metrics = Jason.decode!(text)

      assert is_number(metrics["cpu_usage"])
      assert is_number(metrics["memory_usage"])
      assert is_binary(metrics["timestamp"])
    end

    test "returns error for unknown resource", %{client: client} do
      {:error, error} = Client.read_resource(client, "unknown://resource")
      assert error.code == -32602
      assert error.message =~ "Resource not found"
    end
  end

  describe "direct prompt operations" do
    test "gets summarize prompt with style", %{client: client} do
      {:ok, result} = Client.get_prompt(client, "summarize", %{"style" => "bullet"})

      assert result.description =~ "bullet"
      assert length(result.messages) == 1

      msg = hd(result.messages)
      text = get_in(msg, [:content, :text]) || get_in(msg, ["content", "text"])
      assert text =~ "bullet"
    end

    test "gets analyze prompt with focus", %{client: client} do
      {:ok, result} = Client.get_prompt(client, "analyze", %{"focus" => "security"})

      assert result.description =~ "security"
      assert length(result.messages) == 1
    end

    test "returns error for unknown prompt", %{client: client} do
      {:error, error} = Client.get_prompt(client, "nonexistent", %{})
      assert error.code == -32602
      assert error.message =~ "Prompt not found"
    end
  end

  describe "client handler configuration" do
    test "client handler is properly initialized" do
      # Verify the AgentClientHandler initializes correctly
      {:ok, state} = AgentClientHandler.init(scenario: :default)
      assert state.scenario == :default
      assert is_list(state.roots)
      assert length(state.roots) == 2
    end

    test "client handler responds to root listing" do
      {:ok, state} = AgentClientHandler.init(scenario: :default)
      {:ok, roots, _new_state} = AgentClientHandler.handle_list_roots(state)
      assert length(roots) == 2
      assert hd(roots).uri =~ "file://"
    end

    test "client handler responds to sampling request" do
      {:ok, state} = AgentClientHandler.init(scenario: :default)

      params = %{
        "messages" => [
          %{"role" => "user", "content" => %{"type" => "text", "text" => "Hello"}}
        ]
      }

      {:ok, response, _new_state} =
        AgentClientHandler.handle_create_message(params, state)

      assert response["role"] == "assistant"
      assert response["model"] == "mock-llm-1.0"
    end

    test "client handler responds to elicitation" do
      {:ok, state} = AgentClientHandler.init(scenario: :default)

      {:ok, response, _new_state} =
        AgentClientHandler.handle_elicitation_create(
          "Please confirm",
          %{},
          state
        )

      assert response.action == "accept"
    end
  end

  describe "max steps protection" do
    test "agent loop stops at max steps", %{client: client} do
      # Use a scenario that would loop forever (concurrent_operations has 3+ steps)
      result =
        run_agent_loop(client, "Run calculations", :concurrent_operations, max_steps: 1)

      assert {:error, :max_steps_exceeded, _conversation} = result
    end
  end

  describe "connectivity" do
    test "client can get server info", %{client: client} do
      {:ok, info} = Client.server_info(client)
      assert info["name"] == "agent-test-server"
    end

    test "client has negotiated protocol version", %{client: client} do
      {:ok, version} = Client.negotiated_version(client)
      assert is_binary(version)
    end
  end
end
