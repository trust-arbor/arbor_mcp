defmodule Arbor.MCP.Server.HandlerBridge do
  @moduledoc """
  Normalizes `Arbor.MCP.Server.Handler` callback returns into canonical
  `c:GenServer.handle_call/3` replies.

  `use Arbor.MCP.Server.Handler` injects a thin `handle_call/3` clause per MCP
  message that delegates here. Handler authors may answer with any of the
  historical shapes (`{:ok, result, state}`, `{:ok, result}`, `{:ok, state}`,
  `{:error, reason, state}`, `{:error, reason}`); this module collapses them so
  callers such as the HTTP message processor see exactly one
  shape and handler state never leaks into a reply (audit M13):

    * `{:ok, result}` for single-result calls
    * `{:ok, entries, next_cursor}` for paginated list calls
    * `{:error, reason}` for failures

  Keeping the bodies here also keeps the generated `__using__` block small and
  makes the bridge directly testable.
  """

  @type state :: term()
  @type reply :: {:reply, term(), state()}

  @doc """
  Invokes a callback that answers with a single result.
  """
  @spec call(module(), atom(), [term()], state()) :: reply()
  def call(module, fun, args, state) do
    module
    |> invoke(fun, args, state)
    |> normalize(state)
  end

  @doc """
  Invokes a paginated list callback, replying `{:ok, entries, next_cursor}`.
  """
  @spec list(module(), atom(), [term()], state()) :: reply()
  def list(module, fun, args, state) do
    case invoke(module, fun, args, state) do
      {:ok, entries, next_cursor, new_state} when is_list(entries) ->
        {:reply, {:ok, entries, next_cursor}, new_state}

      {:ok, entries, new_state} when is_list(entries) ->
        {:reply, {:ok, entries, nil}, new_state}

      other ->
        normalize(other, state)
    end
  end

  @doc """
  Invokes a callback whose success carries no meaningful result
  (subscriptions, log level), replying `{:ok, result_or_empty_map}`.
  """
  @spec ack(module(), atom(), [term()], state()) :: reply()
  def ack(module, fun, args, state) do
    case invoke(module, fun, args, state) do
      {:ok, result, new_state} -> {:reply, {:ok, normalize_ack_result(result)}, new_state}
      {:ok, new_state} -> {:reply, {:ok, %{}}, new_state}
      other -> normalize(other, state)
    end
  end

  defp invoke(module, fun, args, state), do: apply(module, fun, args ++ [state])

  defp normalize({:ok, result, new_state}, _state), do: {:reply, {:ok, result}, new_state}
  defp normalize({:ok, result}, state), do: {:reply, {:ok, result}, state}

  defp normalize({:input_required, input_requests, new_state}, _state),
    do: {:reply, {:input_required, input_requests, nil}, new_state}

  defp normalize({:input_required, input_requests, application_state, new_state}, _state),
    do: {:reply, {:input_required, input_requests, application_state}, new_state}

  defp normalize({:error, reason, new_state}, _state), do: {:reply, {:error, reason}, new_state}
  defp normalize({:error, reason}, state), do: {:reply, {:error, reason}, state}
  defp normalize(:ok, state), do: {:reply, {:ok, %{}}, state}
  defp normalize(other, state), do: {:reply, {:error, {:invalid_handler_reply, other}}, state}

  defp normalize_ack_result(result) when is_map(result), do: result
  defp normalize_ack_result(_result), do: %{}
end
