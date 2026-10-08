defmodule Arbor.MCP.Testing.MockLLM do
  @moduledoc """
  Mock LLM decision engine for agent simulation tests.

  Provides scripted, deterministic decisions based on conversation history
  and scenario names. No GenServer needed — pure functions with pattern matching.

  ## Usage

      conversation = [%{role: "user", content: "What's the weather in NYC?"}]
      {:tool_call, "weather", %{"city" => "NYC"}} = MockLLM.decide(conversation, :simple_weather)
  """

  @type message :: %{role: String.t(), content: any()}
  @type conversation :: [message()]
  @type scenario :: atom()

  @type decision ::
          {:tool_call, String.t(), map()}
          | {:resource_read, String.t()}
          | {:prompt_get, String.t(), map()}
          | {:text_response, String.t()}
          | {:error, term()}

  @doc """
  Given a conversation history and scenario, returns the next action.
  """
  @spec decide(conversation(), scenario()) :: decision()
  def decide(conversation, scenario \\ :default)

  # ── Scenario: simple_weather ──────────────────────────────────────────

  def decide(conversation, :simple_weather) do
    case last_role(conversation) do
      "user" ->
        {:tool_call, "weather", %{"city" => "NYC"}}

      "tool" ->
        {:text_response, "Based on the weather data, it's sunny and 72°F in NYC."}
    end
  end

  # ── Scenario: multi_step_reasoning ────────────────────────────────────
  # Read resource → use info to call tool → respond

  def decide(conversation, :multi_step_reasoning) do
    case {last_role(conversation), step_count(conversation)} do
      {"user", _} ->
        {:resource_read, "docs://api/users"}

      {"resource", _} ->
        {:tool_call, "search_docs", %{"query" => "authentication", "limit" => 5}}

      {"tool", _} ->
        {:text_response,
         "Based on the API docs and search results, here's how authentication works."}
    end
  end

  # ── Scenario: chained_tools ───────────────────────────────────────────
  # search_docs → create_report

  def decide(conversation, :chained_tools) do
    tool_calls = count_tool_calls(conversation)

    case {last_role(conversation), tool_calls} do
      {"user", _} ->
        {:tool_call, "search_docs", %{"query" => "performance metrics", "limit" => 10}}

      {"tool", 1} ->
        last_result = last_content(conversation)

        {:tool_call, "create_report",
         %{"title" => "Performance Report", "data" => last_result, "format" => "summary"}}

      {"tool", _} ->
        {:text_response, "I've created a performance report based on the search results."}
    end
  end

  # ── Scenario: prompt_workflow ─────────────────────────────────────────
  # Get prompt template → use it to structure response

  def decide(conversation, :prompt_workflow) do
    case last_role(conversation) do
      "user" ->
        {:prompt_get, "summarize", %{"style" => "concise"}}

      "prompt" ->
        {:text_response, "Using the summarization template, here's a concise summary."}
    end
  end

  # ── Scenario: resource_discovery ──────────────────────────────────────
  # List resources → read specific ones → respond

  def decide(conversation, :resource_discovery) do
    resource_reads = count_by_role(conversation, "resource")

    case {last_role(conversation), resource_reads} do
      {"user", _} ->
        {:resource_read, "config://app/settings"}

      {"resource", 1} ->
        {:resource_read, "data://metrics/latest"}

      {"resource", _} ->
        {:text_response, "Based on the config and metrics data, here's the system status."}
    end
  end

  # ── Scenario: error_recovery ──────────────────────────────────────────
  # Call nonexistent tool → get error → retry with correct tool

  def decide(conversation, :error_recovery) do
    errors = count_by_role(conversation, "error")

    case {last_role(conversation), errors} do
      {"user", _} ->
        {:tool_call, "nonexistent_tool", %{"arg" => "value"}}

      {"error", 1} ->
        {:tool_call, "weather", %{"city" => "NYC"}}

      {"tool", _} ->
        {:text_response, "After recovering from the error, the weather in NYC is sunny."}
    end
  end

  # ── Scenario: full_agent_loop ─────────────────────────────────────────
  # Multi-turn: prompt → resource → tool → tool → respond

  def decide(conversation, :full_agent_loop) do
    step = non_user_step_count(conversation)

    case {last_role(conversation), step} do
      {"user", _} ->
        {:prompt_get, "analyze", %{"focus" => "system health"}}

      {"prompt", _} ->
        {:resource_read, "config://app/settings"}

      {"resource", _} ->
        {:tool_call, "weather", %{"city" => "San Francisco"}}

      {"tool", 3} ->
        {:tool_call, "calculate", %{"operation" => "multiply", "a" => 42, "b" => 1.5}}

      {"tool", _} ->
        {:text_response,
         "Analysis complete: system is healthy, weather is clear, projected value is 63."}
    end
  end

  # ── Scenario: concurrent_operations ───────────────────────────────────
  # Multiple sequential tool calls to verify state isolation

  def decide(conversation, :concurrent_operations) do
    tool_calls = count_tool_calls(conversation)

    case {last_role(conversation), tool_calls} do
      {"user", _} ->
        {:tool_call, "calculate", %{"operation" => "add", "a" => 10, "b" => 20}}

      {"tool", 1} ->
        {:tool_call, "calculate", %{"operation" => "multiply", "a" => 5, "b" => 6}}

      {"tool", 2} ->
        {:tool_call, "weather", %{"city" => "London"}}

      {"tool", _} ->
        {:text_response, "Computed: 30, 30, and London weather retrieved."}
    end
  end

  # ── Scenario: calculate_only ──────────────────────────────────────────

  def decide(conversation, :calculate_only) do
    case last_role(conversation) do
      "user" ->
        {:tool_call, "calculate", %{"operation" => "add", "a" => 2, "b" => 3}}

      "tool" ->
        {:text_response, "The result of 2 + 3 is 5."}
    end
  end

  # ── Default scenario ─────────────────────────────────────────────────

  def decide(conversation, :default) do
    case last_role(conversation) do
      "user" -> {:text_response, "I understand your request."}
      _ -> {:text_response, "Processing complete."}
    end
  end

  # ── Helper functions ──────────────────────────────────────────────────

  defp last_role(conversation) do
    case List.last(conversation) do
      %{role: role} -> role
      nil -> "user"
    end
  end

  defp last_content(conversation) do
    case List.last(conversation) do
      %{content: content} when is_binary(content) -> content
      %{content: content} when is_list(content) -> extract_text(content)
      %{content: content} when is_map(content) -> extract_text_from_map(content)
      _ -> ""
    end
  end

  defp extract_text(content_list) when is_list(content_list) do
    Enum.map_join(content_list, "\n", fn
      %{"text" => text} -> text
      %{text: text} -> text
      text when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp extract_text_from_map(%{"text" => text}), do: text
  defp extract_text_from_map(%{text: text}), do: text
  defp extract_text_from_map(_), do: ""

  defp step_count(conversation) do
    length(conversation)
  end

  defp non_user_step_count(conversation) do
    Enum.count(conversation, fn msg -> msg.role != "user" end)
  end

  defp count_tool_calls(conversation) do
    count_by_role(conversation, "tool")
  end

  defp count_by_role(conversation, role) do
    Enum.count(conversation, fn msg -> msg.role == role end)
  end
end
