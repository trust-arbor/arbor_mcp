defmodule Arbor.MCP.Client.Subscription do
  @moduledoc """
  A client-owned MCP 2026-07-28 subscription stream.

  Use `open/3` with an immutable notification filter. The call returns only
  after the server's `notifications/subscriptions/acknowledged` message. Events
  are delivered to the subscribing process as:

      {:ex_mcp_subscription, subscription, method, params}

  If a transport reconnects, the process re-opens the desired filter with a
  fresh JSON-RPC request ID and emits a resynchronization notification.
  """

  use GenServer

  alias Arbor.MCP.Client.{ConnectionScope, Deadline, Diagnostics, Lifetime}
  alias Arbor.MCP.SubscriptionFilter

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

  defmodule Ref do
    @moduledoc "A reference to an active subscription process."

    @enforce_keys [:pid, :client, :request_id, :requested_filter, :acknowledged_filter]
    defstruct [:pid, :client, :request_id, :requested_filter, :acknowledged_filter]

    @type t :: %__MODULE__{
            pid: pid(),
            client: GenServer.server(),
            request_id: Arbor.MCP.Types.request_id(),
            requested_filter: map(),
            acknowledged_filter: map()
          }
  end

  defstruct [
    :client,
    :owner,
    :owner_monitor,
    :request_id,
    :requested_filter,
    :acknowledged_filter,
    :open_timeout,
    :open_error,
    reconnect_attempts: 0,
    resync?: false,
    pending_events: [],
    status: :opening,
    waiters: []
  ]

  @type t :: Ref.t()

  @spec open(GenServer.server(), map(), keyword()) :: {:ok, Ref.t()} | {:error, term()}
  def open(client, filter, opts \\ []) when is_map(filter) do
    owner = Keyword.get(opts, :subscriber, self())
    timeout = Keyword.get(opts, :timeout, 5_000)

    with {:ok, pid} <-
           ConnectionScope.start_process(
             __MODULE__,
             [
               client: client,
               owner: owner,
               filter: filter,
               open_timeout: timeout
             ],
             :unlinked
           ) do
      try do
        case GenServer.call(pid, :await_acknowledgment, timeout) do
          {:ok, _subscription} = ok ->
            ok

          {:error, _reason} = error ->
            GenServer.stop(pid, :normal)
            error
        end
      catch
        :exit, {:timeout, _call} ->
          GenServer.stop(pid, :normal)
          {:error, :subscription_acknowledgment_timeout}

        :exit, reason ->
          {:error, {:subscription_process_exit, reason}}
      end
    end
  end

  @spec cancel(Ref.t(), String.t() | nil) :: :ok
  def cancel(%Ref{pid: pid}, reason \\ nil) do
    GenServer.call(pid, {:cancel, reason})
  catch
    :exit, _reason -> :ok
  end

  @spec status(Ref.t()) :: map()
  def status(%Ref{pid: pid}), do: GenServer.call(pid, :status)

  @spec current(Ref.t()) :: {:ok, Ref.t()} | {:error, atom()}
  def current(%Ref{pid: pid}) do
    GenServer.call(pid, :reference)
  catch
    :exit, _reason -> {:error, :subscription_closed}
  end

  @impl true
  def format_status(status), do: Diagnostics.format_status(status, __MODULE__)

  def child_spec(opts), do: Diagnostics.child_spec(super(opts))

  @impl true
  def init(constructor) when is_function(constructor, 0), do: init(constructor.())

  def init(opts), do: Diagnostics.initialize(fn -> initialize_owner(opts) end)

  defp initialize_owner(opts) do
    :ok =
      ConnectionScope.register_process(
        Keyword.get(opts, :_connection_scope),
        Keyword.get(opts, :_client_lifetime),
        Keyword.get(opts, :_client_lifetime_deadline, Deadline.after_ms(1_000))
      )

    owner = Keyword.fetch!(opts, :owner)

    state = %__MODULE__{
      client: Keyword.fetch!(opts, :client),
      owner: owner,
      owner_monitor: Process.monitor(owner),
      requested_filter: Keyword.fetch!(opts, :filter),
      open_timeout: Keyword.fetch!(opts, :open_timeout)
    }

    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state) do
    {:noreply, open_on_client(state)}
  end

  @impl true
  def handle_call(:await_acknowledgment, _from, %{status: :active} = state) do
    {:reply, {:ok, reference(state)}, state}
  end

  def handle_call(:await_acknowledgment, _from, %{status: :failed} = state) do
    {:reply, {:error, state.open_error}, state}
  end

  def handle_call(:await_acknowledgment, from, state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call({:cancel, reason}, _from, state) do
    close_on_client(state, reason)
    {:stop, :normal, :ok, %{state | status: :cancelled}}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       status: state.status,
       request_id: state.request_id,
       requested_filter: state.requested_filter,
       acknowledged_filter: state.acknowledged_filter
     }, state}
  end

  def handle_call(:reference, _from, %{status: :active} = state) do
    {:reply, {:ok, reference(state)}, state}
  end

  def handle_call(:reference, _from, state),
    do: {:reply, {:error, :subscription_not_active}, state}

  @impl true
  def handle_info({:client_subscription_acknowledged, request_id, params}, state)
      when request_id == state.request_id do
    with ^request_id <- get_in(params, ["_meta", @subscription_id_key]),
         filter when is_map(filter) <- Map.get(params, "notifications"),
         {:ok, requested} <- SubscriptionFilter.normalize(state.requested_filter),
         {:ok, acknowledged} <- SubscriptionFilter.normalize(filter),
         true <- SubscriptionFilter.subset?(acknowledged, requested) do
      if state.resync? do
        send(self(), :resync)

        {:noreply,
         %{state | status: :resyncing, acknowledged_filter: acknowledged, open_error: nil}}
      else
        case Lifetime.persist_subscription() do
          :ok -> activate_acknowledged(state, acknowledged)
          {:error, reason} -> fail_open(state, reason)
        end
      end
    else
      _invalid -> fail_open(state, :invalid_subscription_acknowledgment)
    end
  end

  def handle_info({:client_subscription_event, request_id, method, params}, state)
      when request_id == state.request_id and state.status == :active do
    if event_allowed?(method, params, state.acknowledged_filter) do
      send(state.owner, {:ex_mcp_subscription, reference(state), method, params})
    end

    {:noreply, state}
  end

  def handle_info({:client_subscription_event, request_id, method, params}, state)
      when request_id == state.request_id and state.status == :resyncing do
    events =
      if event_allowed?(method, params, state.acknowledged_filter) do
        [{method, params} | state.pending_events] |> Enum.take(100)
      else
        state.pending_events
      end

    {:noreply, %{state | pending_events: events}}
  end

  def handle_info({:client_subscription_complete, request_id, result}, state)
      when request_id == state.request_id do
    send(state.owner, {:ex_mcp_subscription_closed, reference(state), {:complete, result}})
    {:stop, :normal, %{state | status: :complete}}
  end

  def handle_info({:client_subscription_error, request_id, error}, state)
      when request_id == state.request_id do
    if state.status == :opening do
      fail_open(state, error)
    else
      send(state.owner, {:ex_mcp_subscription_closed, reference(state), {:error, error}})
      {:stop, :normal, %{state | status: :failed, open_error: error}}
    end
  end

  def handle_info({:client_subscription_disconnected, _reason}, state) do
    send(state.owner, {:ex_mcp_subscription_resync, self(), :started})
    reconnect_attempts = state.reconnect_attempts + 1

    :telemetry.execute(
      [:arbor_mcp, :client, :subscription, :reconnect],
      %{attempt: reconnect_attempts},
      %{phase: :scheduled}
    )

    Process.send_after(
      self(),
      :client_subscription_reconnect,
      reconnect_delay(reconnect_attempts)
    )

    {:noreply,
     %{
       state
       | status: :reconnecting,
         request_id: nil,
         acknowledged_filter: nil,
         reconnect_attempts: reconnect_attempts,
         resync?: true,
         pending_events: []
     }}
  end

  def handle_info(:client_subscription_reconnect, %{status: :reconnecting} = state) do
    {:noreply, open_on_client(%{state | status: :opening})}
  end

  def handle_info(:client_subscription_reconnect, state), do: {:noreply, state}

  def handle_info(:resync, %{status: :resyncing} = state) do
    snapshot = resynchronize(state.client, state.acknowledged_filter, state.open_timeout)

    :telemetry.execute(
      [:arbor_mcp, :client, :subscription, :reconnect],
      %{attempt: max(state.reconnect_attempts, 1)},
      %{phase: :complete}
    )

    state = %{state | status: :active, resync?: false, reconnect_attempts: 0}
    subscription = reference(state)
    send(state.owner, {:ex_mcp_subscription_resync, subscription, {:complete, snapshot}})

    state.pending_events
    |> Enum.reverse()
    |> Enum.each(fn {method, params} ->
      send(state.owner, {:ex_mcp_subscription, subscription, method, params})
    end)

    {:noreply, %{state | pending_events: []}}
  end

  def handle_info({:client_subscription_shutdown, reason}, state) do
    send(state.owner, {:ex_mcp_subscription_closed, self(), {:error, reason}})
    {:stop, :normal, %{state | status: :failed, open_error: reason}}
  end

  def handle_info({:DOWN, ref, :process, owner, _reason}, state)
      when ref == state.owner_monitor and owner == state.owner do
    close_on_client(state, "subscription owner exited")
    {:stop, :normal, %{state | status: :cancelled}}
  end

  @impl true
  def terminate(_reason, %{status: status} = state)
      when status not in [:cancelled, :complete, :failed] do
    close_on_client(state, "subscription process stopped")
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp activate_acknowledged(state, acknowledged) do
    state = %{
      state
      | status: :active,
        acknowledged_filter: acknowledged,
        open_error: nil,
        reconnect_attempts: 0
    }

    reply_waiters(state.waiters, {:ok, reference(state)})
    {:noreply, %{state | waiters: []}}
  end

  defp open_on_client(state) do
    case GenServer.call(
           state.client,
           {:open_subscription, self(), state.requested_filter},
           state.open_timeout
         ) do
      {:ok, request_id} ->
        %{state | request_id: request_id, status: :opening}

      {:error, reason} ->
        reply_waiters(state.waiters, {:error, reason})
        maybe_notify_resync_failure(state, reason)
        %{state | status: :failed, open_error: reason, waiters: []}
    end
  catch
    :exit, reason ->
      error = {:client_unavailable, reason}
      reply_waiters(state.waiters, {:error, error})
      maybe_notify_resync_failure(state, error)
      %{state | status: :failed, open_error: error, waiters: []}
  end

  defp close_on_client(%{request_id: nil}, _reason), do: :ok

  defp close_on_client(state, reason) do
    GenServer.cast(
      state.client,
      {:close_subscription, self(), state.request_id, reason}
    )
  catch
    :exit, _reason -> :ok
  end

  defp fail_open(state, reason) do
    close_on_client(state, "subscription opening failed")
    reply_waiters(state.waiters, {:error, reason})
    maybe_notify_resync_failure(state, reason)
    state = %{state | status: :failed, open_error: reason, waiters: []}

    if state.resync?, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  defp reply_waiters(waiters, reply), do: Enum.each(waiters, &GenServer.reply(&1, reply))

  defp reference(state) do
    %Ref{
      pid: self(),
      client: state.client,
      request_id: state.request_id,
      requested_filter: state.requested_filter,
      acknowledged_filter: state.acknowledged_filter
    }
  end

  defp resynchronize(client, filter, timeout) do
    %{}
    |> maybe_resync(
      Map.get(filter, "toolsListChanged") == true,
      "tools",
      fn -> Arbor.MCP.Client.list_tools(client, format: :map, timeout: timeout) end
    )
    |> maybe_resync(
      Map.get(filter, "promptsListChanged") == true,
      "prompts",
      fn -> Arbor.MCP.Client.list_prompts(client, format: :map, timeout: timeout) end
    )
    |> maybe_resync(
      Map.get(filter, "resourcesListChanged") == true,
      "resourcesList",
      fn -> Arbor.MCP.Client.list_resources(client, format: :map, timeout: timeout) end
    )
    |> resync_resources(client, Map.get(filter, "resourceSubscriptions", []), timeout)
    |> resync_tasks(client, Map.get(filter, "taskIds", []), timeout)
  end

  defp maybe_resync(snapshot, false, _key, _operation), do: snapshot

  defp maybe_resync(snapshot, true, key, operation) do
    Map.put(snapshot, key, safe_resync(operation))
  end

  defp resync_resources(snapshot, _client, [], _timeout), do: snapshot

  defp resync_resources(snapshot, client, uris, timeout) do
    resources =
      Map.new(uris, fn uri ->
        {uri,
         safe_resync(fn ->
           Arbor.MCP.Client.read_resource(client, uri, format: :map, timeout: timeout)
         end)}
      end)

    Map.put(snapshot, "resources", resources)
  end

  defp resync_tasks(snapshot, _client, [], _timeout), do: snapshot

  defp resync_tasks(snapshot, client, task_ids, timeout) do
    tasks =
      Map.new(task_ids, fn task_id ->
        {task_id,
         safe_resync(fn ->
           Arbor.MCP.Client.get_task(client, task_id, format: :map, timeout: timeout)
         end)}
      end)

    Map.put(snapshot, "tasks", tasks)
  end

  defp event_allowed?(method, params, filter),
    do: SubscriptionFilter.event_allowed?(method, params, filter)

  defp safe_resync(operation) do
    case operation.() do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp maybe_notify_resync_failure(%{resync?: true} = state, reason) do
    send(state.owner, {:ex_mcp_subscription_resync, self(), {:failed, reason}})
  end

  defp maybe_notify_resync_failure(_state, _reason), do: :ok

  defp reconnect_delay(attempt) do
    exponent = min(attempt - 1, 6)
    min(100 * Integer.pow(2, exponent), 5_000)
  end
end
