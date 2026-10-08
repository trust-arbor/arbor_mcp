defmodule Arbor.MCP.Protocol.RequestTracker do
  @moduledoc """
  Manages tracking of pending requests and cancellations for MCP servers.

  This module provides functionality to:
  - Track pending requests with their associated GenServer from references
  - Track cancelled request IDs
  - Handle request completion and cancellation
  - Query pending request status

  The tracker maintains two data structures:
  - `pending_requests`: Map of request_id => from (GenServer reference)
  - `cancelled_requests`: MapSet of cancelled request_ids
  """

  require Logger

  alias Arbor.RPC.LogSummary

  @type request_id :: String.t() | integer()
  @type from :: GenServer.from()
  @type state :: map()

  @doc """
  Initializes request tracker state.

  Returns a map with empty pending_requests and cancelled_requests.

  ## Examples

      iex> RequestTracker.init()
      %{pending_requests: %{}, cancelled_requests: MapSet.new()}
  """
  @spec init() :: map()
  def init do
    %{
      pending_requests: %{},
      cancelled_requests: MapSet.new()
    }
  end

  @doc """
  Merges request tracker state into existing state map.

  ## Examples

      iex> RequestTracker.init_state(%{foo: "bar"})
      %{foo: "bar", pending_requests: %{}, cancelled_requests: MapSet.new()}
  """
  @spec init_state(map()) :: map()
  def init_state(state) when is_map(state) do
    state
    |> Map.put_new(:pending_requests, %{})
    |> Map.put_new(:cancelled_requests, MapSet.new())
  end

  @doc """
  Tracks a new pending request.

  Adds the request_id and from reference to pending_requests.

  ## Examples

      iex> state = RequestTracker.init()
      iex> new_state = RequestTracker.track_request("req-123", {self(), :tag}, state)
      iex> Map.has_key?(new_state.pending_requests, "req-123")
      true
  """
  @spec track_request(request_id(), from(), state()) :: state()
  def track_request(request_id, from, state) do
    new_pending_requests = Map.put(state.pending_requests, request_id, from)
    %{state | pending_requests: new_pending_requests}
  end

  @doc """
  Completes a pending request by removing it from tracking.

  ## Examples

      iex> state = %{pending_requests: %{"req-123" => {self(), :tag}}, cancelled_requests: MapSet.new()}
      iex> new_state = RequestTracker.complete_request("req-123", state)
      iex> Map.has_key?(new_state.pending_requests, "req-123")
      false
  """
  @spec complete_request(request_id(), state()) :: state()
  def complete_request(request_id, state) do
    new_pending_requests = Map.delete(state.pending_requests, request_id)
    %{state | pending_requests: new_pending_requests}
  end

  @doc """
  Marks a request as cancelled.

  Adds the request_id to the cancelled_requests set.

  ## Examples

      iex> state = RequestTracker.init()
      iex> new_state = RequestTracker.cancel_request("req-123", state)
      iex> RequestTracker.cancelled?("req-123", new_state)
      true
  """
  @spec cancel_request(request_id(), state()) :: state()
  def cancel_request(request_id, state) do
    new_cancelled_requests = MapSet.put(state.cancelled_requests, request_id)
    %{state | cancelled_requests: new_cancelled_requests}
  end

  @doc """
  Checks if a request has been cancelled.

  ## Examples

      iex> state = %{cancelled_requests: MapSet.new(["req-123"])}
      iex> RequestTracker.cancelled?("req-123", state)
      true
      
      iex> RequestTracker.cancelled?("req-456", state)
      false
  """
  @spec cancelled?(request_id(), state()) :: boolean()
  def cancelled?(request_id, state) do
    MapSet.member?(state.cancelled_requests, request_id)
  end

  @doc """
  Gets the from reference for a pending request.

  Returns {:ok, from} if found, :error if not found.

  ## Examples

      iex> from = {self(), :tag}
      iex> state = %{pending_requests: %{"req-123" => from}}
      iex> RequestTracker.get_pending_request("req-123", state)
      {:ok, from}
      
      iex> RequestTracker.get_pending_request("req-456", state)
      :error
  """
  @spec get_pending_request(request_id(), state()) :: {:ok, from()} | :error
  def get_pending_request(request_id, state) do
    case Map.get(state.pending_requests, request_id) do
      nil -> :error
      from -> {:ok, from}
    end
  end

  @doc """
  Gets all pending request IDs.

  ## Examples

      iex> state = %{pending_requests: %{"req-123" => {self(), :tag}, "req-456" => {self(), :tag2}}}
      iex> RequestTracker.get_pending_request_ids(state) |> Enum.sort()
      ["req-123", "req-456"]
  """
  @spec get_pending_request_ids(state()) :: [request_id()]
  def get_pending_request_ids(state) do
    Map.keys(state.pending_requests)
  end

  @doc """
  Handles a cancellation notification.

  If the request is still pending:
  - Marks it as cancelled
  - Removes it from pending
  - Returns {:reply, from} to send cancellation reply

  If the request is not pending:
  - Just marks it as cancelled
  - Returns {:noreply, state}

  ## Examples

      iex> from = {self(), :tag}
      iex> state = RequestTracker.init() |> RequestTracker.track_request("req-123", from)
      iex> {action, data, new_state} = RequestTracker.handle_cancellation("req-123", state)
      iex> action
      :reply
      iex> data
      from
      iex> RequestTracker.cancelled?("req-123", new_state)
      true
  """
  @spec handle_cancellation(request_id(), state()) ::
          {:reply, from(), state()} | {:noreply, state()}
  def handle_cancellation(request_id, state) do
    # Mark as cancelled
    new_state = cancel_request(request_id, state)

    # Check if request is still pending
    case get_pending_request(request_id, new_state) do
      {:ok, from} ->
        # Remove from pending and return from for reply
        final_state = complete_request(request_id, new_state)
        {:reply, from, final_state}

      :error ->
        # Not pending, just keep the cancellation mark
        Logger.debug("Request not found in pending requests",
          request_id_hash: LogSummary.fingerprint(request_id)
        )

        {:noreply, new_state}
    end
  end

  @doc """
  Processes a request with cancellation checking.

  This is a convenience function that:
  1. Checks if the request is already cancelled
  2. If not, tracks it as pending
  3. Returns appropriate response

  ## Examples

      iex> state = RequestTracker.init() |> RequestTracker.cancel_request("req-123")
      iex> RequestTracker.process_if_not_cancelled("req-123", {self(), :tag}, state)
      {:cancelled, state}
      
      iex> state = RequestTracker.init()
      iex> {:ok, new_state} = RequestTracker.process_if_not_cancelled("req-456", {self(), :tag}, state)
      iex> Map.has_key?(new_state.pending_requests, "req-456")
      true
  """
  @spec process_if_not_cancelled(request_id(), from(), state()) ::
          {:ok, state()} | {:cancelled, state()}
  def process_if_not_cancelled(request_id, from, state) do
    if cancelled?(request_id, state) do
      {:cancelled, state}
    else
      new_state = track_request(request_id, from, state)
      {:ok, new_state}
    end
  end
end
