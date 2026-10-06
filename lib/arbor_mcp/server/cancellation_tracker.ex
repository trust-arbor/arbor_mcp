defmodule Arbor.MCP.Server.CancellationTracker do
  @moduledoc """
  Strategy for propagating `notifications/cancelled` into handler state.

  The runtime marks an active invocation cancelled, then invokes a tracker as
  ordered callback work against the latest committed handler state. The module is chosen
  at start-up with the `:cancellation_tracker` option:

      Arbor.MCP.Server.HandlerServer.start_link(
        handler: MyHandler,
        cancellation_tracker: MyApp.CancellationTracker
      )

  This keeps `HandlerServer` free of handler-shape-specific branches: it just
  calls the configured module.

  The default implementation is `Arbor.MCP.Server.CancellationTracker.Default`.
  """

  @doc """
  Records `request_id` as cancelled and returns the (possibly updated) handler
  state.

  Implementations run in supervised callback tasks. They can inspect the
  invocation's opaque scope with `Arbor.MCP.Server.Context.scope/0`.
  Prefer `Arbor.MCP.Server.Context.cancelled?/0` for active callback polling.
  """
  @callback mark_cancelled(request_id :: term(), handler_state :: term()) ::
              handler_state :: term()

  defmodule Default do
    @moduledoc """
    Default cancellation tracker.

    Supports the two conventions ArborMCP handlers use to observe cancellation:

    * a `:cancelled_requests` `MapSet` in the handler state, which stores
      `{scope, request_id}` for runtime callbacks, and
    * an `:active_requests` map of `{scope, request_id} => pid`, whose worker process is
      sent `{:cancelled, request_id}` so long-running work can stop early.

    Handler states that use neither are returned untouched.
    """

    @behaviour Arbor.MCP.Server.CancellationTracker
    alias Arbor.MCP.Server.Runtime.CallbackContext

    @impl true
    def mark_cancelled(request_id, handler_state) when is_map(handler_state) do
      request_id =
        case CallbackContext.current() do
          %{scope: scope} -> {scope, request_id}
          nil -> request_id
        end

      handler_state
      |> update_cancelled_requests(request_id)
      |> notify_worker(request_id)
    end

    def mark_cancelled(_request_id, handler_state), do: handler_state

    defp update_cancelled_requests(%{cancelled_requests: set} = handler_state, request_id) do
      %{handler_state | cancelled_requests: MapSet.put(set, request_id)}
    end

    defp update_cancelled_requests(handler_state, _request_id), do: handler_state

    defp notify_worker(%{active_requests: active} = handler_state, request_id) do
      case Map.get(active, request_id) do
        pid when is_pid(pid) ->
          send(pid, {:cancelled, request_id})
          handler_state

        _other ->
          handler_state
      end
    end

    defp notify_worker(handler_state, _request_id), do: handler_state
  end
end
