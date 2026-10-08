defmodule Arbor.MCP.Server.HTTP.ListenerAdapter do
  @moduledoc """
  Lifecycle boundary for an explicitly selected standalone HTTP listener.

  `Arbor.MCP.HttpPlug` can also be mounted in an existing Plug/Phoenix host;
  that host owns its listener and does not use this adapter. A listener adapter
  owns no MCP handler, session, replay or runtime state.
  """

  @callback available?() :: boolean()
  @callback start(module(), keyword(), keyword()) :: {:ok, pid()} | {:error, term()}
  @callback stop(term(), pos_integer()) :: :ok | {:error, term()}

  @doc false
  def bounded(backend, operation, timeout, fun)
      when is_integer(timeout) and timeout > 0 and timeout <= 4_294_967_295 do
    task =
      Task.async(fn ->
        try do
          fun.()
        catch
          :exit, {:timeout, _call} ->
            {:error, {:http_listener_operation_timeout, backend, operation}}

          kind, reason ->
            {:error, {:http_listener_operation_failed, backend, operation, {kind, reason}}}
        end
      end)

    case Task.yield(task, timeout) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:http_listener_operation_timeout, backend, operation}}
    end
  end

  def bounded(_backend, _operation, _timeout, _fun),
    do: {:error, :invalid_http_shutdown_timeout}

  @doc false
  def ensure_started(module, backend, application) do
    if Code.ensure_loaded?(module) do
      case Application.ensure_all_started(application) do
        {:ok, _started} -> :ok
        {:error, reason} -> {:error, {:http_listener_application_start_failed, backend, reason}}
      end
    else
      {:error, {:missing_http_listener_dependency, backend, application}}
    end
  end
end
