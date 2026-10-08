defmodule Arbor.MCP.Tasks.Server do
  @moduledoc """
  Server-callback adapters for `Arbor.MCP.Tasks`.

  These helpers convert the public task lifecycle API into the return tuples
  expected by `Arbor.MCP.Server.Handler`. `use Arbor.MCP.Server.Handler, tasks: :store`
  installs them as the default modern task callbacks.
  """

  alias Arbor.MCP.Server.Context
  alias Arbor.MCP.Tasks
  alias Arbor.MCP.Tasks.Extension

  @doc "Creates a stored task result suitable for returning from a request handler."
  @spec create(String.t(), map(), term(), keyword()) ::
          {:ok, map(), term()} | {:error, term(), term()}
  def create(tool_name, arguments, state, opts \\ []) do
    case tasks_request_kind() do
      :declared ->
        case Tasks.create(tool_name, arguments, opts) do
          {:ok, result} -> {:ok, result, state}
          {:error, reason} -> {:error, error_message(reason), state}
        end

      :undeclared ->
        {:error,
         Arbor.MCP.Error.missing_required_client_capability(Extension.required_capabilities()),
         state}

      :legacy ->
        {:error, "Tasks not implemented", state}
    end
  end

  @doc false
  def get(task_id, state, opts) do
    if modern_tasks_request?() do
      case Tasks.get(task_id, opts) do
        {:ok, task} -> {:ok, task, state}
        {:error, reason} -> {:error, error_message(reason), state}
      end
    else
      {:error, "Tasks not implemented", state}
    end
  end

  @doc false
  def update(task_id, input_responses, state, opts) do
    if modern_tasks_request?() do
      case Tasks.update(task_id, input_responses, opts) do
        :ok -> {:ok, %{}, state}
        {:error, reason} -> {:error, error_message(reason), state}
      end
    else
      {:error, "Tasks not implemented", state}
    end
  end

  @doc false
  def cancel(task_id, state, opts) do
    if modern_tasks_request?() do
      case Tasks.cancel(task_id, opts) do
        :ok -> {:ok, %{}, state}
        {:error, reason} -> {:error, error_message(reason), state}
      end
    else
      {:error, "Tasks not implemented", state}
    end
  end

  defp modern_tasks_request? do
    tasks_request_kind() == :declared
  end

  defp tasks_request_kind do
    case Context.current() do
      %{era: :modern, client_capabilities: capabilities} ->
        if Extension.declared?(capabilities), do: :declared, else: :undeclared

      _legacy_or_outside_request ->
        :legacy
    end
  end

  defp error_message(:not_found_or_unauthorized), do: "Task not found or not authorized"
  defp error_message(:invalid_input_responses), do: "Invalid task input responses"
  defp error_message(:invalid_transition), do: "Invalid task state transition"
  defp error_message(:task_store_unavailable), do: "Task store unavailable"
  defp error_message(_reason), do: "Task operation failed"
end
