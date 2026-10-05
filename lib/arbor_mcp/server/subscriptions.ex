defmodule Arbor.MCP.Server.Subscriptions do
  @moduledoc """
  Registry and publication coordinator for MCP 2026-07-28 subscriptions.

  Registrations contain no credential material. Each listener is isolated in a
  monitored process with an acknowledgment-first, bounded queue. The default
  adapter is node-local; clustered deployments can configure another adapter.
  """

  use GenServer

  @impl true
  def format_status(status),
    do: Arbor.MCP.Server.Runtime.Diagnostics.format_status(status, __MODULE__)

  alias Arbor.MCP.Server.SubscriptionListener

  alias Arbor.MCP.Server.Runtime.{
    Deadline,
    HTTPListenerBinding,
    ServiceAdapter,
    Services
  }

  alias Arbor.MCP.Server.Subscriptions.{Entry, ETS, Mailbox, Origin}
  alias Arbor.MCP.SubscriptionFilter
  alias Arbor.MCP.Tasks.Extension, as: TasksExtension
  alias Arbor.MCP.Tasks.StoreCall

  @default_supported Map.new(SubscriptionFilter.keys(), &{&1, true})

  defstruct [
    :adapter,
    :adapter_state,
    :runtime_table,
    :publication_mailbox,
    :publication_timeout_ms,
    :listener_supervisor,
    :filter_authorizer,
    :publication_authorizer,
    :max_global,
    :max_per_principal,
    :max_per_tenant,
    :max_queue,
    :max_message_bytes,
    :max_queue_bytes,
    :max_lifetime_ms,
    :max_filter_uris,
    :max_filter_task_ids,
    :max_filter_bytes,
    :supported_notifications,
    monitors: %{}
  ]

  @type registry :: GenServer.server()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    server_opts = [timeout: Keyword.get(opts, :init_timeout_ms, :infinity)]

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts, server_opts)
      name -> GenServer.start_link(__MODULE__, opts, Keyword.put(server_opts, :name, name))
    end
  end

  @doc false
  def runtime_service_capabilities, do: %{bounded_startup: 1}

  @spec listen(Arbor.MCP.Types.request_id(), map(), pid(), keyword()) ::
          {:ok, Entry.t()} | {:error, term()}
  def listen(subscription_id, requested_filter, transport_ref, opts \\ []) do
    call_service(opts, :listen, [subscription_id, requested_filter, transport_ref], fn opts ->
      registry = Keyword.get(opts, :registry, __MODULE__)
      GenServer.call(registry, {:listen, subscription_id, requested_filter, transport_ref, opts})
    end)
  end

  @doc false
  def listen_http(binding, subscription_id, requested_filter, opts \\ []) do
    with {:ok, proof} <- HTTPListenerBinding.validate(binding),
         true <- proof.gateway == self(),
         {:ok, __MODULE__, resolved} <-
           Services.subscription_options(Keyword.put(opts, :runtime, proof.runtime)),
         true <- Deadline.remaining(proof.source_deadline) > 0 do
      resolved =
        resolved |> Keyword.put(:http_listener, binding) |> Keyword.put(:runtime, proof.runtime)

      GenServer.call(
        resolved[:registry],
        {:listen, subscription_id, requested_filter, proof.writer, resolved},
        min(1_000, Deadline.remaining(proof.source_deadline))
      )
    else
      _invalid -> {:error, :subscription_origin_retired}
    end
  catch
    :exit, _reason -> {:error, :subscription_origin_retired}
  end

  @spec cancel(pid(), Arbor.MCP.Types.request_id(), keyword()) :: :ok | {:error, term()}
  def cancel(transport_ref, subscription_id, opts \\ []) do
    call_service(opts, :cancel, [transport_ref, subscription_id], fn opts ->
      registry = Keyword.get(opts, :registry, __MODULE__)
      GenServer.call(registry, {:cancel, transport_ref, subscription_id})
    end)
  end

  @spec close(pid(), Arbor.MCP.Types.request_id(), atom(), keyword()) ::
          :ok | {:error, term()}
  def close(transport_ref, subscription_id, reason \\ :server_closed, opts \\ []) do
    call_service(opts, :close, [transport_ref, subscription_id, reason], fn opts ->
      registry = Keyword.get(opts, :registry, __MODULE__)
      GenServer.call(registry, {:close, transport_ref, subscription_id, reason})
    end)
  end

  @spec remove_transport(pid(), keyword()) :: :ok | {:error, term()}
  def remove_transport(transport_ref, opts \\ []) do
    call_service(opts, :remove_transport, [transport_ref], fn opts ->
      registry = Keyword.get(opts, :registry, __MODULE__)
      GenServer.call(registry, {:remove_transport, transport_ref})
    end)
  catch
    :exit, _reason -> :ok
  end

  @spec publish(String.t(), map(), keyword()) ::
          %{
            subscribers: non_neg_integer(),
            enqueued: non_neg_integer(),
            coalesced: non_neg_integer(),
            closed: non_neg_integer()
          }
          | {:error, term()}
  def publish(method, params \\ %{}, opts \\ []) do
    publication(method, params, opts, :sync)
  end

  @doc false
  @spec publish_async(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def publish_async(method, params \\ %{}, opts \\ []) do
    publication(method, params, opts, :async)
  end

  defp publication(method, params, opts, mode) when is_binary(method) and is_map(params) do
    started = Deadline.now()

    with {:ok, origin} <- Origin.capture(opts),
         {:ok, adapter, resolved} <- Services.subscription_options(opts) do
      cond do
        adapter == __MODULE__ ->
          bounded_publication(method, params, resolved, origin, mode, started)

        is_nil(origin) ->
          adapter_publication(adapter, method, params, resolved, mode)

        true ->
          {:error, :bounded_publication_required}
      end
    end
  end

  defp publication(_method, _params, _opts, _mode),
    do: {:error, :invalid_subscription_publication}

  defp adapter_publication(adapter, method, params, opts, mode) do
    operation = if mode == :async, do: :publish_async, else: :publish
    apply(adapter, operation, [method, params, opts])
  end

  defp bounded_publication(method, params, opts, origin, mode, started) do
    registry = Keyword.get(opts, :registry, __MODULE__)
    deadline = Origin.deadline(origin, started + 5_000)

    with true <- Deadline.remaining(deadline) > 0,
         {:ok, mailbox, timeout} <-
           GenServer.call(registry, :publication_mailbox, Deadline.remaining(deadline)),
         deadline = min(deadline, Origin.deadline(origin, started + timeout)),
         payload = %{"method" => method, "params" => params},
         target = Keyword.get(opts, :transport_ref),
         {:ok, id} <- Mailbox.offer(mailbox, payload, origin, deadline, {mode, target}) do
      complete_publication(registry, mailbox, id, deadline, mode)
    else
      false -> {:error, :subscription_expired}
      error -> error
    end
  catch
    :exit, _ -> {:error, :subscription_unavailable}
  end

  defp complete_publication(_registry, mailbox, _id, _deadline, :async),
    do: Mailbox.wake(mailbox)

  defp complete_publication(registry, mailbox, id, deadline, :sync) do
    result = GenServer.call(registry, {:publication, id}, Deadline.remaining(deadline))

    if Deadline.remaining(deadline) > 0,
      do: result,
      else: {:error, :subscription_expired}
  catch
    :exit, _ ->
      Mailbox.abort(mailbox, id)
      {:error, :subscription_expired}
  end

  @spec entries(keyword()) :: [Entry.t()] | {:error, term()}
  def entries(opts \\ []) do
    call_service(opts, :entries, [], fn opts ->
      registry = Keyword.get(opts, :registry, __MODULE__)
      GenServer.call(registry, :entries)
    end)
  end

  defp call_service(opts, operation, args, local) do
    with {:ok, adapter, resolved} <- Services.subscription_options(opts) do
      if adapter == __MODULE__,
        do: local.(resolved),
        else: apply(adapter, operation, args ++ [resolved])
    end
  end

  @spec delivered(pid()) :: :ok
  def delivered(listener), do: SubscriptionListener.delivered(listener)

  @doc false
  @spec runtime_options(keyword()) :: keyword()
  def runtime_options(opts) do
    opts
    |> Keyword.take([
      :subscription_registry,
      :runtime,
      :authorize_subscription_filter,
      :authorize_subscription_publication,
      :subscription_max_queue,
      :subscription_max_message_bytes,
      :subscription_max_queue_bytes,
      :subscription_max_lifetime_ms,
      :task_store_opts,
      :client_capabilities
    ])
    |> Enum.map(fn
      {:subscription_registry, value} -> {:registry, value}
      {:runtime, value} -> {:runtime, value}
      {:authorize_subscription_filter, value} -> {:authorize_filter, value}
      {:authorize_subscription_publication, value} -> {:authorize_publication, value}
      {:subscription_max_queue, value} -> {:max_queue, value}
      {:subscription_max_message_bytes, value} -> {:max_message_bytes, value}
      {:subscription_max_queue_bytes, value} -> {:max_queue_bytes, value}
      {:subscription_max_lifetime_ms, value} -> {:max_lifetime_ms, value}
      {:task_store_opts, value} -> {:task_store_opts, value}
      {:client_capabilities, value} -> {:client_capabilities, value}
    end)
    |> Keyword.put(:principal_id, Keyword.get(opts, :principal_id))
    |> Keyword.put(:tenant_id, Keyword.get(opts, :tenant_id))
    |> Keyword.put(:audience, Keyword.get(opts, :audience, Keyword.get(opts, :endpoint)))
    |> Keyword.put(
      :authorization_required,
      Keyword.get(opts, :oauth_enabled, false) or
        not is_nil(Keyword.get(opts, :principal_id)) or
        not is_nil(Keyword.get(opts, :tenant_id))
    )
  end

  @doc false
  @spec runtime_options(keyword(), module() | term()) :: keyword()
  def runtime_options(opts, handler) when is_list(opts) do
    opts
    |> put_handler_task_store(handler)
    |> runtime_options()
  end

  defp put_handler_task_store(opts, handler) when is_atom(handler) do
    if Code.ensure_loaded?(handler) and
         function_exported?(handler, :__task_store_enabled__, 0) and
         handler.__task_store_enabled__() do
      Keyword.put_new(opts, :task_store_opts, handler.__task_store_options__())
    else
      opts
    end
  end

  defp put_handler_task_store(opts, _handler), do: opts

  @impl true
  def init(opts) do
    {adapter, adapter_opts} = adapter_spec(Keyword.get(opts, :adapter, ETS))

    with :ok <- ServiceAdapter.watch_owned(opts),
         {:ok, adapter_state} <- adapter.init(adapter_opts),
         {:ok, limits} <- validate_limits(opts),
         :ok <- validate_filter_authorizer(Keyword.get(opts, :authorize_filter)),
         :ok <- validate_publication_authorizer(Keyword.get(opts, :authorize_publication)) do
      mailbox =
        Mailbox.new(
          max_count: limits.max_publications,
          max_bytes: limits.max_publication_bytes,
          max_message_bytes: limits.max_publication_message_bytes
        )

      Process.send_after(self(), :publication_reap, 20)

      {:ok,
       struct!(__MODULE__,
         adapter: adapter,
         adapter_state: adapter_state,
         listener_supervisor:
           Keyword.get(opts, :listener_supervisor, Arbor.MCP.DynamicSupervisor),
         runtime_table: Keyword.get(opts, :runtime_table),
         publication_mailbox: mailbox,
         publication_timeout_ms: limits.publication_timeout_ms,
         filter_authorizer: Keyword.get(opts, :authorize_filter),
         publication_authorizer: Keyword.get(opts, :authorize_publication),
         supported_notifications: Keyword.get(opts, :supported_notifications, @default_supported),
         max_global: limits.max_global,
         max_per_principal: limits.max_per_principal,
         max_per_tenant: limits.max_per_tenant,
         max_queue: limits.max_queue,
         max_message_bytes: limits.max_message_bytes,
         max_queue_bytes: limits.max_queue_bytes,
         max_lifetime_ms: limits.max_lifetime_ms,
         max_filter_uris: limits.max_filter_uris,
         max_filter_task_ids: limits.max_filter_task_ids,
         max_filter_bytes: limits.max_filter_bytes
       )}
    end
  end

  @impl true
  def handle_call(:publication_mailbox, _from, state) do
    {:reply, {:ok, state.publication_mailbox, state.publication_timeout_ms}, state}
  end

  def handle_call({:publication, id}, {caller, _}, state) do
    case Mailbox.entry(state.publication_mailbox, id) do
      {:ok, %{producer: ^caller, mode: {:sync, _target}}} ->
        {result, state} = consume_publication(id, state)
        {:reply, result, state}

      _ ->
        {:reply, {:error, :subscription_expired}, state}
    end
  end

  def handle_call(
        {:listen, subscription_id, requested, transport_ref, opts},
        {caller, _tag},
        state
      ) do
    opts = ensure_authorization_context(opts)
    {entries, state} = all_entries(state)

    with :ok <- http_listener_current(opts, transport_ref, caller),
         :ok <- validate_subscription_id(subscription_id),
         :ok <- validate_transport_ref(transport_ref),
         :ok <- validate_identity(opts),
         :ok <-
           validate_filter_authorizer(
             Keyword.get(opts, :authorize_filter, state.filter_authorizer)
           ),
         :ok <-
           validate_publication_authorizer(
             Keyword.get(opts, :authorize_publication, state.publication_authorizer)
           ),
         :ok <- require_identity_authorizers(opts, state),
         {:ok, requested} <- normalize_filter(requested, state),
         :ok <- validate_task_capability(requested, opts),
         supported = honour_supported(requested, state.supported_notifications),
         {:ok, task_authorized} <- authorize_task_filter(supported, transport_ref, opts, state),
         {:ok, honoured} <- authorize_filter(task_authorized, transport_ref, opts, state),
         :ok <- ensure_not_registered(entries, transport_ref, subscription_id),
         :ok <- enforce_limits(entries, transport_ref, opts, state),
         :ok <- http_listener_current(opts, transport_ref, caller),
         {:ok, entry, state} <-
           start_listener(subscription_id, honoured, transport_ref, opts, state) do
      {:reply, {:ok, entry}, state}
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel, transport_ref, subscription_id}, _from, state) do
    {entries, state} = all_entries(state)

    case find_entry(entries, transport_ref, subscription_id) do
      nil ->
        {:reply, :ok, state}

      entry ->
        SubscriptionListener.cancel(entry.listener_pid)
        {:reply, :ok, delete_entry(entry.token, state)}
    end
  end

  def handle_call({:close, transport_ref, subscription_id, reason}, _from, state) do
    {entries, state} = all_entries(state)

    case find_entry(entries, transport_ref, subscription_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        SubscriptionListener.close(entry.listener_pid, reason)
        {:reply, :ok, state}
    end
  end

  def handle_call({:remove_transport, transport_ref}, _from, state) do
    {entries, state} = all_entries(state)

    state =
      entries
      |> Enum.filter(&(&1.transport_ref == transport_ref))
      |> Enum.reduce(state, fn entry, acc ->
        SubscriptionListener.cancel(entry.listener_pid)
        delete_entry(entry.token, acc)
      end)

    {:reply, :ok, state}
  end

  def handle_call(:entries, _from, state) do
    {entries, state} = all_entries(state)
    {:reply, entries, state}
  end

  defp publish_to_matching(method, params, transport_ref, state, origin \\ nil, deadline \\ nil) do
    deadline = deadline || Deadline.after_ms(state.publication_timeout_ms)
    {entries, state} = all_entries(state)

    matching =
      Enum.filter(entries, fn entry ->
        (is_nil(transport_ref) or entry.transport_ref == transport_ref) and
          filter_matches?(entry.filter, method, params)
      end)

    result =
      Enum.reduce(
        matching,
        %{subscribers: length(matching), enqueued: 0, coalesced: 0, closed: 0},
        fn entry, counts ->
          case SubscriptionListener.enqueue(entry.listener_pid, method, params, origin, deadline) do
            :ok -> Map.update!(counts, :enqueued, &(&1 + 1))
            :coalesced -> Map.update!(counts, :coalesced, &(&1 + 1))
            {:closed, _reason} -> Map.update!(counts, :closed, &(&1 + 1))
          end
        end
      )

    {result, state}
  end

  defp consume_publication(id, state) do
    mailbox = state.publication_mailbox

    result =
      with {:ok, entry} <- Mailbox.take(mailbox, id),
           true <- Mailbox.active?(mailbox, id) and Origin.valid?(entry.origin) do
        %{"method" => method, "params" => params} = entry.payload
        {_mode, target} = entry.mode
        target = Origin.target(entry.origin, target)

        {counts, state} =
          publish_to_matching(method, params, target, state, entry.origin, entry.deadline)

        {counts, broadcast(method, params, target, state)}
      else
        false -> {{:error, :subscription_origin_retired}, state}
        error -> {error, state}
      end

    Mailbox.finish(mailbox, id)
    result
  end

  @impl true
  def handle_info({:subscription_mailbox_ready, identity}, state) do
    if identity == Mailbox.identity(state.publication_mailbox) do
      Mailbox.clear_wake(state.publication_mailbox)

      state =
        Enum.reduce(Mailbox.pending(state.publication_mailbox, :async), state, fn id, state ->
          {_result, state} = consume_publication(id, state)
          state
        end)

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:publication_reap, state) do
    Mailbox.reap(state.publication_mailbox)
    Process.send_after(self(), :publication_reap, 20)
    {:noreply, state}
  end

  def handle_info(
        {:subscription_listener_closed, listener, token, _transport_ref, _reason},
        state
      ) do
    {:noreply, remove_monitor(listener, token, state)}
  end

  def handle_info({:DOWN, ref, :process, listener, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {{^listener, token}, monitors} ->
        {:noreply, delete_entry(token, %{state | monitors: monitors})}
    end
  end

  def handle_info(message, state) do
    if function_exported?(state.adapter, :handle_info, 2) do
      case state.adapter.handle_info(message, state.adapter_state) do
        {:publish, method, params, transport_ref, adapter_state} ->
          {_result, state} =
            publish_to_matching(
              method,
              params,
              transport_ref,
              %{state | adapter_state: adapter_state}
            )

          {:noreply, state}

        {:noreply, adapter_state} ->
          {:noreply, %{state | adapter_state: adapter_state}}

        :unhandled ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  defp start_listener(subscription_id, filter, transport_ref, opts, state) do
    token = random_token()

    max_lifetime_ms =
      min(option(opts, :max_lifetime_ms, state.max_lifetime_ms), state.max_lifetime_ms)

    max_queue = min(option(opts, :max_queue, state.max_queue), state.max_queue)

    max_message_bytes =
      min(option(opts, :max_message_bytes, state.max_message_bytes), state.max_message_bytes)

    max_queue_bytes =
      min(option(opts, :max_queue_bytes, state.max_queue_bytes), state.max_queue_bytes)

    listener_deadline = http_listener_deadline(opts)

    max_lifetime_ms =
      if listener_deadline,
        do: min(max_lifetime_ms, Deadline.remaining(listener_deadline)),
        else: max_lifetime_ms

    expires_at = System.system_time(:millisecond) + max_lifetime_ms

    listener_opts = [
      registry: self(),
      runtime_table: state.runtime_table,
      runtime: Keyword.get(opts, :runtime),
      token: token,
      subscription_id: subscription_id,
      transport_ref: transport_ref,
      filter: filter,
      principal_id: Keyword.get(opts, :principal_id),
      tenant_id: Keyword.get(opts, :tenant_id),
      publication_authorizer:
        Keyword.get(opts, :authorize_publication, state.publication_authorizer),
      authorization_required: Keyword.get(opts, :authorization_required, false),
      max_queue: max_queue,
      max_message_bytes: max_message_bytes,
      max_queue_bytes: max_queue_bytes,
      publication_timeout_ms: state.publication_timeout_ms,
      max_lifetime_ms: max_lifetime_ms,
      http_listener: Keyword.get(opts, :http_listener),
      listener_deadline: listener_deadline
    ]

    case DynamicSupervisor.start_child(
           state.listener_supervisor,
           {SubscriptionListener, listener_opts}
         ) do
      {:ok, listener} ->
        entry = %Entry{
          token: token,
          subscription_id: subscription_id,
          listener_pid: listener,
          transport_ref: transport_ref,
          filter: filter,
          principal_id: Keyword.get(opts, :principal_id),
          tenant_id: Keyword.get(opts, :tenant_id),
          http_listener: Keyword.get(opts, :http_listener),
          expires_at: expires_at
        }

        register_listener(listener, entry, state)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp register_listener(listener, entry, state) do
    case listener_entry_current(entry) && put_entry(entry, state) do
      {:ok, state} ->
        ref = Process.monitor(listener)
        SubscriptionListener.activate(listener)

        {:ok, entry, %{state | monitors: Map.put(state.monitors, ref, {listener, entry.token})}}

      false ->
        _result = DynamicSupervisor.terminate_child(state.listener_supervisor, listener)
        {:error, :subscription_origin_retired}

      {:error, reason, state} ->
        _result = DynamicSupervisor.terminate_child(state.listener_supervisor, listener)
        {:error, reason, state}
    end
  end

  defp http_listener_current(opts, transport, caller) do
    case Keyword.get(opts, :http_listener) do
      nil ->
        :ok

      binding ->
        with {:ok, proof} <- HTTPListenerBinding.validate(binding, opts[:runtime]),
             true <- proof.writer == transport and proof.gateway == caller,
             true <- Deadline.remaining(proof.source_deadline) > 0,
             do: :ok,
             else: (_invalid -> {:error, :subscription_origin_retired})
    end
  end

  defp http_listener_deadline(opts) do
    case Keyword.get(opts, :http_listener) do
      nil ->
        nil

      binding ->
        case HTTPListenerBinding.validate(binding, opts[:runtime]) do
          {:ok, proof} -> proof.deadline
          _retired -> Deadline.now()
        end
    end
  end

  defp listener_entry_current(%{http_listener: nil}), do: true

  defp listener_entry_current(%{http_listener: binding}) do
    match?({:ok, _proof}, HTTPListenerBinding.validate(binding))
  end

  defp authorize_filter(requested, transport_ref, opts, state) do
    authorizer = Keyword.get(opts, :authorize_filter, state.filter_authorizer)
    context = identity_context(transport_ref, opts)

    result =
      case authorizer do
        nil ->
          if Keyword.get(opts, :authorization_required, false),
            do: {:error, :subscription_filter_authorizer_required},
            else: {:ok, requested}

        callback when is_function(callback, 2) ->
          callback.(requested, context)

        _invalid ->
          {:error, :invalid_filter_authorizer}
      end

    with {:ok, authorised} <- normalize_authorization_result(result),
         {:ok, authorised} <- normalize_filter(authorised, state),
         true <- SubscriptionFilter.subset?(authorised, requested) do
      {:ok, authorised}
    else
      false -> {:error, :authorizer_broadened_filter}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :filter_authorization_failed}
  catch
    _kind, _value -> {:error, :filter_authorization_failed}
  end

  defp validate_task_capability(filter, opts) do
    if Map.has_key?(filter, "taskIds") and
         not TasksExtension.declared?(Keyword.get(opts, :client_capabilities, %{})) do
      {:error,
       Arbor.MCP.Error.missing_required_client_capability(TasksExtension.required_capabilities())}
    else
      :ok
    end
  end

  defp authorize_task_filter(filter, transport_ref, opts, state) do
    case Map.fetch(filter, "taskIds") do
      :error ->
        {:ok, filter}

      {:ok, task_ids} ->
        authorize_task_ids(filter, task_ids, transport_ref, opts, state)
    end
  end

  defp authorize_task_ids(filter, task_ids, transport_ref, opts, state) do
    cond do
      Keyword.has_key?(opts, :task_store_opts) ->
        task_opts = task_authorization_options(transport_ref, opts)
        owner = Keyword.fetch!(task_opts, :owner)

        # Equivalent to `Arbor.MCP.Tasks.get/2` succeeding for this owner, invoked
        # through the shared store primitive so this registry does not depend
        # on the Tasks facade that publishes through it.
        authorized =
          Enum.filter(task_ids, fn task_id ->
            is_binary(task_id) and
              match?({:ok, _task}, StoreCall.call(:fetch, [task_id, owner], task_opts))
          end)

        {:ok, put_nonempty_ids(filter, "taskIds", authorized)}

      not is_nil(Keyword.get(opts, :authorize_filter, state.filter_authorizer)) ->
        {:ok, filter}

      true ->
        {:error, :task_subscription_authorizer_required}
    end
  end

  defp task_authorization_options(transport_ref, opts) do
    owner = %{
      principal_id: Keyword.get(opts, :principal_id),
      tenant_id: Keyword.get(opts, :tenant_id),
      audience: Keyword.get(opts, :audience)
    }

    opts
    |> Keyword.fetch!(:task_store_opts)
    |> Keyword.put(:owner, owner)
    |> Keyword.put(:transport_ref, transport_ref)
  end

  defp put_nonempty_ids(filter, key, []), do: Map.delete(filter, key)
  defp put_nonempty_ids(filter, key, ids), do: Map.put(filter, key, ids)

  defp normalize_authorization_result({:ok, filter}) when is_map(filter), do: {:ok, filter}
  defp normalize_authorization_result(true), do: {:error, :filter_authorizer_must_return_filter}
  defp normalize_authorization_result(false), do: {:error, :subscription_not_authorized}
  defp normalize_authorization_result({:error, reason}), do: {:error, reason}
  defp normalize_authorization_result(_other), do: {:error, :invalid_filter_authorizer_result}

  defp normalize_filter(filter, state) do
    with {:ok, normalized} <- SubscriptionFilter.normalize(filter),
         :ok <- validate_filter_size(normalized, state) do
      {:ok, normalized}
    end
  end

  defp validate_filter_size(filter, state) do
    uris = Map.get(filter, "resourceSubscriptions", [])
    task_ids = Map.get(filter, "taskIds", [])

    cond do
      length(uris) > state.max_filter_uris ->
        {:error, :subscription_filter_uri_limit}

      length(task_ids) > state.max_filter_task_ids ->
        {:error, :subscription_filter_task_id_limit}

      byte_size(Jason.encode!(filter)) > state.max_filter_bytes ->
        {:error, :subscription_filter_too_large}

      true ->
        :ok
    end
  end

  defp honour_supported(filter, supported) do
    Map.new(filter, fn {key, value} -> {key, value} end)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      if supported?(supported, key), do: Map.put(acc, key, value), else: acc
    end)
  end

  defp supported?(supported, key) when is_map(supported) do
    Map.get(supported, key, Map.get(supported, String.to_atom(key), false)) == true
  rescue
    ArgumentError -> Map.get(supported, key, false) == true
  end

  defp supported?(_supported, _key), do: false

  defp filter_matches?(filter, "notifications/tools/list_changed", _params),
    do: Map.get(filter, "toolsListChanged") == true

  defp filter_matches?(filter, "notifications/prompts/list_changed", _params),
    do: Map.get(filter, "promptsListChanged") == true

  defp filter_matches?(filter, "notifications/resources/list_changed", _params),
    do: Map.get(filter, "resourcesListChanged") == true

  defp filter_matches?(filter, "notifications/resources/updated", %{"uri" => uri}) do
    uri in Map.get(filter, "resourceSubscriptions", [])
  end

  defp filter_matches?(filter, "notifications/tasks", %{"taskId" => task_id}) do
    task_id in Map.get(filter, "taskIds", [])
  end

  defp filter_matches?(_filter, _method, _params), do: false

  defp enforce_limits(entries, transport_ref, opts, state) do
    principal = Keyword.get(opts, :principal_id)
    tenant = Keyword.get(opts, :tenant_id)
    principal_scope = principal || {:transport, transport_ref}
    tenant_scope = tenant || {:transport, transport_ref}

    cond do
      length(entries) >= state.max_global ->
        {:error, {:subscription_limit_exceeded, :global}}

      Enum.count(entries, &(identity_scope(&1.principal_id, &1.transport_ref) == principal_scope)) >=
          state.max_per_principal ->
        {:error, {:subscription_limit_exceeded, :principal}}

      Enum.count(entries, &(identity_scope(&1.tenant_id, &1.transport_ref) == tenant_scope)) >=
          state.max_per_tenant ->
        {:error, {:subscription_limit_exceeded, :tenant}}

      true ->
        :ok
    end
  end

  defp identity_scope(nil, transport_ref), do: {:transport, transport_ref}
  defp identity_scope(identity, _transport_ref), do: identity

  defp ensure_not_registered(entries, transport_ref, subscription_id) do
    if find_entry(entries, transport_ref, subscription_id),
      do: {:error, :subscription_already_registered},
      else: :ok
  end

  defp find_entry(entries, transport_ref, subscription_id) do
    Enum.find(entries, fn entry ->
      entry.transport_ref == transport_ref and entry.subscription_id == subscription_id
    end)
  end

  defp validate_subscription_id(id) when is_binary(id) and byte_size(id) > 0, do: :ok
  defp validate_subscription_id(id) when is_integer(id), do: :ok
  defp validate_subscription_id(_id), do: {:error, :invalid_subscription_id}

  defp validate_transport_ref(pid) when is_pid(pid), do: :ok
  defp validate_transport_ref(_other), do: {:error, :invalid_subscription_transport}

  defp validate_identity(opts) do
    if valid_identity?(Keyword.get(opts, :principal_id)) and
         valid_identity?(Keyword.get(opts, :tenant_id)) do
      :ok
    else
      {:error, :invalid_subscription_identity}
    end
  end

  defp valid_identity?(nil), do: true
  defp valid_identity?(identity), do: is_binary(identity) and byte_size(identity) > 0

  defp validate_filter_authorizer(nil), do: :ok
  defp validate_filter_authorizer(callback) when is_function(callback, 2), do: :ok
  defp validate_filter_authorizer(_invalid), do: {:error, :invalid_filter_authorizer}

  defp validate_publication_authorizer(nil), do: :ok
  defp validate_publication_authorizer(callback) when is_function(callback, 3), do: :ok

  defp validate_publication_authorizer(_invalid),
    do: {:error, :invalid_publication_authorizer}

  defp require_identity_authorizers(opts, state) do
    if Keyword.get(opts, :authorization_required, false) do
      filter_authorizer = Keyword.get(opts, :authorize_filter, state.filter_authorizer)

      publication_authorizer =
        Keyword.get(opts, :authorize_publication, state.publication_authorizer)

      cond do
        is_nil(filter_authorizer) -> {:error, :subscription_filter_authorizer_required}
        is_nil(publication_authorizer) -> {:error, :subscription_publication_authorizer_required}
        true -> :ok
      end
    else
      :ok
    end
  end

  defp ensure_authorization_context(opts) do
    required =
      Keyword.get(opts, :authorization_required, false) or
        not is_nil(Keyword.get(opts, :principal_id)) or
        not is_nil(Keyword.get(opts, :tenant_id))

    Keyword.put(opts, :authorization_required, required)
  end

  defp identity_context(transport_ref, opts) do
    %{
      principal_id: Keyword.get(opts, :principal_id),
      tenant_id: Keyword.get(opts, :tenant_id),
      audience: Keyword.get(opts, :audience),
      transport_ref: transport_ref
    }
  end

  defp validate_limits(opts) do
    limits = %{
      max_global: Keyword.get(opts, :max_global, 1_000),
      max_per_principal: Keyword.get(opts, :max_per_principal, 100),
      max_per_tenant: Keyword.get(opts, :max_per_tenant, 500),
      max_queue: Keyword.get(opts, :max_queue, 100),
      max_message_bytes: Keyword.get(opts, :max_message_bytes, 1_048_576),
      max_queue_bytes: Keyword.get(opts, :max_queue_bytes, 8_388_608),
      max_lifetime_ms: Keyword.get(opts, :max_lifetime_ms, 3_600_000),
      max_filter_uris: Keyword.get(opts, :max_filter_uris, 256),
      max_filter_task_ids: Keyword.get(opts, :max_filter_task_ids, 256),
      max_filter_bytes: Keyword.get(opts, :max_filter_bytes, 65_536),
      max_publications: Keyword.get(opts, :max_publications, 128),
      max_publication_bytes: Keyword.get(opts, :max_publication_bytes, 8_388_608),
      max_publication_message_bytes: Keyword.get(opts, :max_publication_message_bytes, 2_097_152),
      publication_timeout_ms: Keyword.get(opts, :publication_timeout_ms, 5_000)
    }

    if Enum.all?(limits, fn {_key, value} -> is_integer(value) and value > 0 end) and
         limits.max_lifetime_ms <= 4_294_967_295 and
         limits.publication_timeout_ms <= 4_294_967_295,
       do: {:ok, limits},
       else: {:error, :invalid_subscription_limits}
  end

  defp adapter_spec({adapter, opts}) when is_atom(adapter) and is_list(opts), do: {adapter, opts}
  defp adapter_spec(adapter) when is_atom(adapter), do: {adapter, []}

  defp all_entries(state) do
    {entries, adapter_state} = state.adapter.all(state.adapter_state)
    {entries, %{state | adapter_state: adapter_state}}
  end

  defp put_entry(entry, state) do
    case state.adapter.put(entry, state.adapter_state) do
      {:ok, adapter_state} -> {:ok, %{state | adapter_state: adapter_state}}
      {:error, reason, adapter_state} -> {:error, reason, %{state | adapter_state: adapter_state}}
    end
  end

  defp delete_entry(token, state) do
    {:ok, adapter_state} = state.adapter.delete(token, state.adapter_state)
    %{state | adapter_state: adapter_state}
  end

  defp broadcast(method, params, transport_ref, state) do
    if function_exported?(state.adapter, :broadcast, 4) do
      case state.adapter.broadcast(method, params, transport_ref, state.adapter_state) do
        {:ok, adapter_state} ->
          %{state | adapter_state: adapter_state}

        {:error, reason, adapter_state} ->
          :telemetry.execute(
            [:arbor_mcp, :server, :subscription, :fanout],
            %{count: 1},
            %{result: :error, reason: fanout_failure_class(reason)}
          )

          %{state | adapter_state: adapter_state}
      end
    else
      state
    end
  end

  defp fanout_failure_class({kind, _detail})
       when kind in [:pubsub_exception, :unexpected_pubsub_result],
       do: kind

  defp fanout_failure_class({:pubsub_failure, _kind, _reason}), do: :pubsub_failure
  defp fanout_failure_class(_reason), do: :broadcast_failed

  defp remove_monitor(listener, token, state) do
    {ref, _value} =
      Enum.find(state.monitors, fn {_ref, {pid, _token}} -> pid == listener end) || {nil, nil}

    if ref, do: Process.demonitor(ref, [:flush])
    monitors = if ref, do: Map.delete(state.monitors, ref), else: state.monitors
    delete_entry(token, %{state | monitors: monitors})
  end

  defp option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end

  defp random_token do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
