defmodule Arbor.MCP.Server.Runtime.Lifecycle do
  @moduledoc false

  # Pure completion policy. Time and committed state are explicit inputs; the
  # scheduler owns cancellation, state mutation, task cleanup and delivery.
  def complete(%{terminal: true}, _proposal, _now), do: :ignore

  def complete(%{deadline: deadline}, _proposal, now) when now >= deadline,
    do: {:cancel, :handler_timeout}

  def complete(%{kind: :call} = context, {:reply, reply, next_state}, _now),
    do: commit(context, {:ok, reply}, next_state)

  def complete(%{kind: :cast} = context, {:noreply, next_state}, _now),
    do: commit(context, :notification, next_state)

  def complete(%{kind: :rpc} = context, {:response, response, next_state}, _now)
      when is_map(response) do
    if valid_response?(response, context.request_id) do
      result = if is_nil(context.request_id), do: :notification, else: {:ok, response}
      commit(context, result, next_state)
    else
      {:fail, :invalid_handler_result}
    end
  end

  def complete(%{kind: :rpc, request_id: nil} = context, {:notification, next_state}, _now),
    do: commit(context, :notification, next_state)

  def complete(_context, {:runtime_failure, :handler_crash}, _now),
    do: {:fail, :handler_crash}

  def complete(_context, {:output_failure, reason}, _now), do: {:fail, reason}

  def complete(_context, _invalid, _now), do: {:fail, :invalid_handler_result}

  defp commit(%{execution: :stateless, state: state}, result, next_state) do
    if state === next_state,
      do: {:commit, result, state},
      else: {:fail, :invalid_handler_state}
  end

  defp commit(_context, result, next_state), do: {:commit, result, next_state}

  defp valid_response?(response, request_id) do
    response["jsonrpc"] == "2.0" and Map.has_key?(response, "id") and
      response["id"] === request_id and
      Map.has_key?(response, "result") != Map.has_key?(response, "error")
  end
end
