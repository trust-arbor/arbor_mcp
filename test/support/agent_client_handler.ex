defmodule Arbor.MCP.Testing.AgentClientHandler do
  @moduledoc """
  Client handler for agent simulation tests.

  Implements `Arbor.MCP.Client.Handler` to handle server-initiated requests
  like roots listing, sampling (create_message), and elicitation.

  Configurable via init args to customize responses per test scenario.
  """

  @behaviour Arbor.MCP.Client.Handler

  @impl true
  def init(args) do
    state = %{
      scenario: Keyword.get(args, :scenario, :default),
      roots:
        Keyword.get(args, :roots, [
          %{uri: "file:///home/testuser/project", name: "Test Project"},
          %{uri: "file:///home/testuser/docs", name: "Documentation"}
        ]),
      sampling_responses: Keyword.get(args, :sampling_responses, %{}),
      elicitation_responses: Keyword.get(args, :elicitation_responses, %{})
    }

    {:ok, state}
  end

  @impl true
  def handle_ping(state) do
    {:ok, %{}, state}
  end

  @impl true
  def handle_list_roots(state) do
    {:ok, state.roots, state}
  end

  @impl true
  def handle_create_message(params, state) do
    # In a real implementation, this would show to user for approval
    # and then call an actual LLM. For testing, we return scripted responses.
    messages = Map.get(params, "messages", [])
    last_message_text = extract_last_message_text(messages)

    response =
      case Map.get(state.sampling_responses, last_message_text) do
        nil ->
          # Default: echo-style response
          %{
            "role" => "assistant",
            "content" => %{
              "type" => "text",
              "text" => "Mock LLM response to: #{last_message_text}"
            },
            "model" => "mock-llm-1.0"
          }

        custom_response ->
          custom_response
      end

    {:ok, response, state}
  end

  @impl true
  def handle_elicitation_create(message, _requested_schema, state) do
    response =
      case Map.get(state.elicitation_responses, message) do
        nil ->
          # Default: accept with generic data
          %{action: "accept", content: %{"confirmed" => true}}

        custom_response ->
          custom_response
      end

    {:ok, response, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  # ── Helpers ────────────────────────────────────────────────────────────

  defp extract_last_message_text(messages) when is_list(messages) do
    case List.last(messages) do
      %{"content" => %{"text" => text}} -> text
      %{"content" => content} when is_binary(content) -> content
      _ -> ""
    end
  end

  defp extract_last_message_text(_), do: ""
end
