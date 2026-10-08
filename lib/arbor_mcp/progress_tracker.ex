defmodule Arbor.MCP.ProgressTracker do
  @moduledoc """
  Progress tracking for MCP 2025-06-18 specification compliance.

  This module manages progress tokens and sends progress notifications
  for long-running operations according to the MCP specification.

  ## Features

  - Progress token uniqueness validation
  - Monotonic progress value enforcement
  - Rate limiting to prevent notification flooding
  - Automatic cleanup of completed operations
  - Support for both string and integer progress tokens

  ## Usage

      # Start tracking a new operation
      {:ok, tracker} = ProgressTracker.start_progress("abc123", sender_pid)

      # Send progress updates
      ProgressTracker.update_progress("abc123", 25, 100, "Processing...")
      ProgressTracker.update_progress("abc123", 50, 100, "Half way there...")
      ProgressTracker.update_progress("abc123", 100, 100, "Complete!")

      # Clean up when operation completes
      ProgressTracker.complete_progress("abc123")

  ## MCP Specification Compliance

  This implementation follows the MCP 2025-06-18 specification:

  - Progress tokens must be string or integer values
  - Progress tokens must be unique across all active requests
  - Progress values must increase with each notification
  - Rate limiting prevents notification flooding
  - Supports optional total and message fields
  """

  use GenServer
  require Logger

  alias Arbor.MCP.Types
  alias Arbor.RPC.LogSummary

  # Rate limiting: max 10 notifications per second per token
  @max_notifications_per_second 10
  @rate_limit_window_ms 1000

  defstruct [
    :owner,
    :progress_token,
    :sender_pid,
    :current_progress,
    :total,
    :last_message,
    :start_time,
    :notification_count,
    :last_notification_time
  ]

  @type progress_state :: %__MODULE__{
          owner: term(),
          progress_token: Types.progress_token(),
          sender_pid: pid(),
          current_progress: number(),
          total: number() | nil,
          last_message: String.t() | nil,
          start_time: integer(),
          notification_count: non_neg_integer(),
          last_notification_time: integer()
        }

  # ETS table for tracking active progress operations
  @table_name :progress_tracker_state

  ## Public API

  @doc """
  Starts the ProgressTracker GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts tracking progress for a new operation.

  ## Parameters

  - `progress_token` - Unique token for this operation (string or integer)
  - `sender_pid` - Process that will receive progress notifications

  ## Returns

  - `{:ok, progress_state}` - Successfully started tracking
  - `{:error, :token_exists}` - Progress token is already in use
  - `{:error, :invalid_token}` - Progress token is not string or integer
  """
  @spec start_progress(Types.progress_token(), pid(), keyword()) ::
          {:ok, progress_state()} | {:error, :token_exists | :invalid_token}
  def start_progress(progress_token, sender_pid, opts \\ []) do
    GenServer.call(
      __MODULE__,
      {:start_progress, progress_namespace(opts), progress_token, sender_pid}
    )
  end

  @doc """
  Updates progress for an active operation.

  ## Parameters

  - `progress_token` - Token for the operation
  - `progress` - Current progress value (must be > previous value)
  - `total` - Optional total value for the operation
  - `message` - Optional human-readable progress message

  ## Returns

  - `:ok` - Progress updated and notification sent
  - `{:error, :not_found}` - Progress token not found
  - `{:error, :not_increasing}` - Progress value must increase
  - `{:error, :rate_limited}` - Too many notifications too quickly
  """
  @spec update_progress(
          Types.progress_token(),
          number(),
          number() | nil,
          String.t() | nil,
          keyword()
        ) ::
          :ok | {:error, :not_found | :not_increasing | :rate_limited}
  def update_progress(progress_token, progress),
    do: update_progress(progress_token, progress, nil, nil, [])

  def update_progress(progress_token, progress, total),
    do: update_progress(progress_token, progress, total, nil, [])

  def update_progress(progress_token, progress, total, message),
    do: update_progress(progress_token, progress, total, message, [])

  def update_progress(progress_token, progress, total, message, opts) do
    GenServer.call(
      __MODULE__,
      {:update_progress, progress_namespace(opts), progress_token, progress, total, message}
    )
  end

  @doc """
  Marks a progress operation as complete and cleans up tracking state.

  ## Parameters

  - `progress_token` - Token for the operation to complete

  ## Returns

  - `:ok` - Operation completed and cleaned up
  - `{:error, :not_found}` - Progress token not found
  """
  @spec complete_progress(Types.progress_token(), keyword()) :: :ok | {:error, :not_found}
  def complete_progress(progress_token, opts \\ []) do
    GenServer.call(__MODULE__, {:complete_progress, progress_namespace(opts), progress_token})
  end

  @doc """
  Gets the current state of a progress operation.

  ## Parameters

  - `progress_token` - Token for the operation

  ## Returns

  - `{:ok, progress_state}` - Current state of the operation
  - `{:error, :not_found}` - Progress token not found
  """
  @spec get_progress_state(Types.progress_token(), keyword()) ::
          {:ok, progress_state()} | {:error, :not_found}
  def get_progress_state(progress_token, opts \\ []) do
    GenServer.call(__MODULE__, {:get_progress_state, progress_namespace(opts), progress_token})
  end

  @doc """
  Lists all active progress tokens.

  ## Returns

  List of all currently active progress tokens.
  """
  @spec list_active_tokens(keyword()) :: [Types.progress_token()]
  def list_active_tokens(opts \\ []) do
    GenServer.call(__MODULE__, {:list_active_tokens, progress_namespace(opts)})
  end

  @doc """
  Clears all progress tracking state.

  This is primarily useful for testing and cleanup.
  """
  @spec clear_all() :: :ok
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  ## GenServer Implementation

  @impl true
  def init(_opts) do
    # Create ETS table for progress state storage
    table = :ets.new(@table_name, [:set, :protected, :named_table])

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:start_progress, owner, progress_token, sender_pid}, _from, state) do
    key = {owner, progress_token}

    cond do
      not valid_progress_token?(progress_token) ->
        {:reply, {:error, :invalid_token}, state}

      :ets.member(@table_name, key) ->
        {:reply, {:error, :token_exists}, state}

      true ->
        now = System.monotonic_time(:millisecond)

        progress_state = %__MODULE__{
          owner: owner,
          progress_token: progress_token,
          sender_pid: sender_pid,
          current_progress: 0,
          total: nil,
          last_message: nil,
          start_time: now,
          notification_count: 0,
          last_notification_time: now
        }

        :ets.insert(@table_name, {key, progress_state})
        {:reply, {:ok, progress_state}, state}
    end
  end

  @impl true
  def handle_call(
        {:update_progress, owner, progress_token, progress, total, message},
        _from,
        state
      ) do
    key = {owner, progress_token}

    case :ets.lookup(@table_name, key) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [{^key, current_state}] ->
        cond do
          progress <= current_state.current_progress ->
            {:reply, {:error, :not_increasing}, state}

          rate_limited?(current_state) ->
            {:reply, {:error, :rate_limited}, state}

          true ->
            now = System.monotonic_time(:millisecond)

            new_state = %{
              current_state
              | current_progress: progress,
                total: total || current_state.total,
                last_message: message,
                notification_count: current_state.notification_count + 1,
                last_notification_time: now
            }

            :ets.insert(@table_name, {key, new_state})

            # Send progress notification
            send_progress_notification(new_state)

            {:reply, :ok, state}
        end
    end
  end

  @impl true
  def handle_call({:complete_progress, owner, progress_token}, _from, state) do
    key = {owner, progress_token}

    case :ets.lookup(@table_name, key) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [{^key, _progress_state}] ->
        :ets.delete(@table_name, key)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:get_progress_state, owner, progress_token}, _from, state) do
    key = {owner, progress_token}

    case :ets.lookup(@table_name, key) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [{^key, progress_state}] ->
        {:reply, {:ok, progress_state}, state}
    end
  end

  @impl true
  def handle_call({:list_active_tokens, owner}, _from, state) do
    tokens =
      @table_name
      |> :ets.tab2list()
      |> Enum.flat_map(fn
        {{^owner, token}, _state} -> [token]
        {_other_key, _state} -> []
      end)

    {:reply, tokens, state}
  end

  @impl true
  def handle_call(:clear_all, _from, state) do
    :ets.delete_all_objects(@table_name)
    {:reply, :ok, state}
  end

  ## Private Functions

  defp progress_namespace(opts), do: Keyword.get(opts, :owner, {:process, self()})

  @spec valid_progress_token?(any()) :: boolean()
  defp valid_progress_token?(token) when is_binary(token) or is_integer(token), do: true
  defp valid_progress_token?(_), do: false

  @spec rate_limited?(progress_state()) :: boolean()
  defp rate_limited?(state) do
    now = System.monotonic_time(:millisecond)
    time_since_last = now - state.last_notification_time

    # If it's been more than the rate limit window, reset the counter
    if time_since_last >= @rate_limit_window_ms do
      false
    else
      # Check if we've exceeded the rate limit
      state.notification_count >= @max_notifications_per_second
    end
  end

  @spec send_progress_notification(progress_state()) :: :ok
  defp send_progress_notification(state) do
    notification = build_progress_notification(state)

    if Process.alive?(state.sender_pid) do
      send(state.sender_pid, {:progress_notification, notification})
    else
      Logger.warning("Progress notification sender process is dead",
        progress_id: LogSummary.fingerprint(state.progress_token)
      )
    end

    :ok
  end

  @spec build_progress_notification(progress_state()) :: Types.progress_notification()
  defp build_progress_notification(state) do
    base_notification = %{
      progressToken: state.progress_token,
      progress: state.current_progress
    }

    base_notification
    |> maybe_add_total(state.total)
    |> maybe_add_message(state.last_message)
  end

  @spec maybe_add_total(map(), number() | nil) :: map()
  defp maybe_add_total(notification, nil), do: notification
  defp maybe_add_total(notification, total), do: Map.put(notification, :total, total)

  @spec maybe_add_message(map(), String.t() | nil) :: map()
  defp maybe_add_message(notification, nil), do: notification
  defp maybe_add_message(notification, message), do: Map.put(notification, :message, message)
end
