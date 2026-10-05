defmodule Arbor.MCP.Server.SubscriptionListener do
  @moduledoc false

  use GenServer

  @impl true
  def format_status(status),
    do: Arbor.MCP.Server.Runtime.Diagnostics.format_status(status, __MODULE__)

  alias Arbor.MCP.Server.Runtime.{Deadline, ShutdownGuard}
  alias Arbor.MCP.Server.Subscriptions.{Delivery, Mailbox, Origin}

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

  defstruct [
    :registry,
    :token,
    :subscription_id,
    :transport_ref,
    :owner_monitor,
    :filter,
    :principal_id,
    :tenant_id,
    :publication_authorizer,
    :authorization_required,
    :max_queue,
    :max_message_bytes,
    :max_queue_bytes,
    :runtime_delivery,
    :http_listener,
    :in_flight_kind,
    active?: false,
    closing?: false,
    queue: [],
    queue_bytes: 0
  ]

  @type notification_kind :: :acknowledged | :notification | :complete

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :token)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @spec activate(pid()) :: :ok
  def activate(listener), do: GenServer.cast(listener, :activate)

  @spec enqueue(pid(), String.t(), map()) :: :ok | :coalesced | {:closed, atom()}
  def enqueue(listener, method, params), do: enqueue(listener, method, params, nil, nil)

  @doc false
  def enqueue(listener, method, params, origin, deadline) do
    deadline = Origin.deadline(origin, deadline || Deadline.after_ms(5_000))

    case GenServer.call(listener, :delivery_reference, Deadline.remaining(deadline)) do
      :legacy when is_nil(origin) ->
        GenServer.call(listener, {:enqueue, method, params}, Deadline.remaining(deadline))

      :legacy ->
        {:closed, :source_retired}

      {:ok, reference} ->
        offer_runtime(listener, reference, method, params, origin, deadline)

      other ->
        other
    end
  catch
    :exit, _reason -> {:closed, :listener_unavailable}
  end

  defp offer_runtime(listener, ref, method, params, origin, deadline) do
    case Delivery.offer(ref, method, params, origin, deadline) do
      {:ok, id} ->
        try do
          GenServer.call(listener, {:enqueue_token, id}, Deadline.remaining(deadline))
        catch
          :exit, _ ->
            Mailbox.abort(ref.mailbox, id)
            {:closed, :listener_unavailable}
        end

      {:error, reason} when reason in [:subscription_expired, :subscription_origin_retired] ->
        {:closed, :source_retired}

      {:error, reason} ->
        reason = rejection_reason(reason)
        GenServer.cast(listener, {:publication_rejected, self(), reason})
        {:closed, reason}
    end
  end

  defp rejection_reason(:subscription_busy), do: :slow_consumer

  defp rejection_reason(reason) when reason in [:output_frame_too_large, :output_term_too_large],
    do: :message_too_large

  defp rejection_reason(_reason), do: :invalid_message

  @spec delivered(pid()) :: :ok
  def delivered(listener), do: GenServer.cast(listener, :delivered)

  @doc false
  def delivered(listener, delivery),
    do: GenServer.cast(listener, {:delivered, self(), delivery})

  @doc false
  def checkout(listener, delivery, deadline) do
    if Deadline.remaining(deadline) == 0 do
      discard(listener, delivery)
      {:error, :source_retired}
    else
      result =
        GenServer.call(listener, {:checkout, delivery}, min(5_000, Deadline.remaining(deadline)))

      if Deadline.remaining(deadline) == 0 do
        discard(listener, delivery)
        {:error, :source_retired}
      else
        result
      end
    end
  catch
    :exit, _ ->
      discard(listener, delivery)
      {:error, :subscription_unavailable}
  end

  @doc false
  def checkout_http(listener, delivery, binding, deadline) do
    if Deadline.remaining(deadline) == 0 do
      {:error, :source_retired}
    else
      GenServer.call(
        listener,
        {:checkout_http, delivery, binding},
        min(5_000, Deadline.remaining(deadline))
      )
    end
  catch
    :exit, _reason -> {:error, :subscription_unavailable}
  end

  @doc false
  def delivered_http(listener, delivery, binding),
    do: GenServer.cast(listener, {:delivered_http, self(), delivery, binding})

  @doc false
  def cancel_http(listener, binding, registration),
    do: GenServer.cast(listener, {:cancel_http, self(), binding, registration})

  @doc false
  def discard(listener, delivery), do: GenServer.cast(listener, {:discarded, self(), delivery})

  @spec cancel(pid()) :: :ok
  def cancel(listener), do: GenServer.cast(listener, :cancel)

  @spec close(pid(), atom()) :: :ok
  def close(listener, reason \\ :server_closed), do: GenServer.cast(listener, {:close, reason})

  @impl true
  def init(opts) do
    if table = Keyword.get(opts, :runtime_table), do: :ok = ShutdownGuard.watch(table, self())
    transport_ref = Keyword.fetch!(opts, :transport_ref)
    lifetime = Keyword.fetch!(opts, :max_lifetime_ms)
    Process.send_after(self(), :expire, lifetime)

    state = %__MODULE__{
      registry: Keyword.fetch!(opts, :registry),
      token: Keyword.fetch!(opts, :token),
      subscription_id: Keyword.fetch!(opts, :subscription_id),
      transport_ref: transport_ref,
      owner_monitor: Process.monitor(transport_ref),
      filter: Keyword.fetch!(opts, :filter),
      principal_id: Keyword.get(opts, :principal_id),
      tenant_id: Keyword.get(opts, :tenant_id),
      publication_authorizer: Keyword.get(opts, :publication_authorizer),
      authorization_required: Keyword.get(opts, :authorization_required, false),
      max_queue: Keyword.fetch!(opts, :max_queue),
      max_message_bytes: Keyword.fetch!(opts, :max_message_bytes),
      max_queue_bytes: Keyword.fetch!(opts, :max_queue_bytes),
      http_listener: Keyword.get(opts, :http_listener)
    }

    with {:ok, acknowledgment_bytes} <-
           encoded_size(acknowledgment(state.subscription_id, state.filter)),
         true <- acknowledgment_bytes <= state.max_message_bytes,
         {:ok, completion_bytes} <- encoded_size(completion(state.subscription_id)),
         true <- completion_bytes <= state.max_message_bytes,
         true <- completion_bytes <= state.max_queue_bytes do
      if Keyword.get(opts, :runtime_table) do
        case Delivery.new(opts) do
          {:ok, delivery} ->
            Process.send_after(self(), :delivery_reap, 20)
            {:ok, %{state | runtime_delivery: delivery}}

          {:error, reason} ->
            {:stop, reason}
        end
      else
        {:ok, state}
      end
    else
      _invalid_limits -> {:stop, :subscription_message_limit_too_small}
    end
  end

  @impl true
  def handle_cast(:activate, %{runtime_delivery: delivery} = state) when not is_nil(delivery) do
    {:noreply, %{state | active?: true, runtime_delivery: Delivery.activate(delivery)}}
  end

  def handle_cast(:activate, %{active?: false} = state) do
    message = acknowledgment(state.subscription_id, state.filter)
    {:noreply, deliver(:acknowledged, message, %{state | active?: true})}
  end

  def handle_cast(:activate, state), do: {:noreply, state}

  def handle_cast({:delivered_http, owner, id, binding}, %{http_listener: binding} = state)
      when owner == state.transport_ref and not is_nil(binding) do
    case Delivery.delivered(state.runtime_delivery, id) do
      {:stop, delivery} -> {:stop, :normal, %{state | runtime_delivery: delivery}}
      {:ok, delivery} -> {:noreply, %{state | runtime_delivery: delivery}}
    end
  end

  def handle_cast({:delivered_http, _owner, _id, _binding}, state), do: {:noreply, state}

  def handle_cast(
        {:cancel_http, owner, binding, registration},
        %{http_listener: binding, token: registration} = state
      )
      when owner == state.transport_ref and not is_nil(binding) do
    {:stop, :normal, state}
  end

  def handle_cast({:cancel_http, _owner, _binding, _registration}, state), do: {:noreply, state}

  def handle_cast({:delivered, owner, id}, %{runtime_delivery: delivery} = state)
      when not is_nil(delivery) and owner == state.transport_ref do
    case Delivery.delivered(delivery, id) do
      {:stop, delivery} -> {:stop, :normal, %{state | runtime_delivery: delivery}}
      {:ok, delivery} -> {:noreply, %{state | runtime_delivery: delivery}}
    end
  end

  def handle_cast({:delivered, _owner, _id}, state), do: {:noreply, state}

  def handle_cast({:discarded, owner, id}, %{runtime_delivery: delivery} = state)
      when not is_nil(delivery) and owner == state.transport_ref do
    case Delivery.delivered(delivery, id) do
      {:stop, delivery} ->
        {:stop, :subscription_delivery_expired, %{state | runtime_delivery: delivery}}

      {:ok, delivery} ->
        {:noreply, %{state | runtime_delivery: delivery}}
    end
  end

  def handle_cast({:discarded, _owner, _id}, state), do: {:noreply, state}

  def handle_cast(:delivered, %{runtime_delivery: delivery} = state) when not is_nil(delivery),
    do: {:noreply, state}

  def handle_cast(:delivered, %{in_flight_kind: :complete} = state) do
    {:stop, :normal, %{state | in_flight_kind: nil}}
  end

  def handle_cast(:delivered, state) do
    {:noreply, deliver_next(%{state | in_flight_kind: nil})}
  end

  def handle_cast(:cancel, state), do: {:stop, :normal, state}

  def handle_cast({:close, reason}, state) do
    {:noreply, initiate_close(state, reason)}
  end

  def handle_cast({:publication_rejected, registry, reason}, state)
      when registry == state.registry,
      do: {:noreply, initiate_close(state, reason)}

  def handle_cast({:publication_rejected, _registry, _reason}, state), do: {:noreply, state}

  @impl true
  def handle_call(:delivery_reference, _from, %{runtime_delivery: nil} = state),
    do: {:reply, :legacy, state}

  def handle_call(:delivery_reference, {owner, _}, state) do
    if owner == state.registry,
      do: {:reply, {:ok, Delivery.reference(state.runtime_delivery)}, state},
      else: {:reply, {:closed, :invalid_subscription_owner}, state}
  end

  def handle_call({:enqueue_token, id}, {owner, _}, state) when owner == state.registry do
    {result, delivery} =
      Delivery.accept(state.runtime_delivery, id, fn method, params ->
        publication_authorized?(state, method, params)
      end)

    {:reply, result, %{state | runtime_delivery: delivery, closing?: delivery.closing?}}
  end

  def handle_call({:enqueue_token, _id}, _from, state),
    do: {:reply, {:closed, :invalid_subscription_owner}, state}

  def handle_call({:checkout_http, id, binding}, {owner, _}, %{http_listener: binding} = state)
      when owner == state.transport_ref and not is_nil(binding) do
    {result, delivery} = Delivery.checkout(state.runtime_delivery, id)
    {:reply, result, %{state | runtime_delivery: delivery}}
  end

  def handle_call({:checkout_http, _id, _binding}, _from, state),
    do: {:reply, {:error, :invalid_subscription_owner}, state}

  def handle_call({:checkout, id}, {owner, _}, state)
      when owner == state.transport_ref and not is_nil(state.runtime_delivery) do
    {result, delivery} = Delivery.checkout(state.runtime_delivery, id)
    {:reply, result, %{state | runtime_delivery: delivery}}
  end

  def handle_call({:checkout, _id}, _from, state),
    do: {:reply, {:error, :invalid_subscription_owner}, state}

  def handle_call({:enqueue, _method, _params}, _from, %{runtime_delivery: delivery} = state)
      when not is_nil(delivery),
      do: {:reply, {:closed, :unmanaged_publication}, state}

  def handle_call({:enqueue, _method, _params}, _from, %{closing?: true} = state) do
    {:reply, {:closed, :closing}, state}
  end

  def handle_call({:enqueue, method, params}, _from, state) do
    if publication_authorized?(state, method, params) do
      message = notification(state.subscription_id, method, params)
      key = coalescing_key(method, params)

      case queue_item(:notification, message, key, state.max_message_bytes) do
        {:ok, item} ->
          case enqueue_message(state, item) do
            {:ok, new_state} -> {:reply, :ok, deliver_next(new_state)}
            {:coalesced, new_state} -> {:reply, :coalesced, new_state}
            {:overflow, new_state} -> {:reply, {:closed, :slow_consumer}, new_state}
          end

        {:error, reason} ->
          emit_queue_pressure(:closed)
          {:reply, {:closed, reason}, initiate_close(state, reason)}
      end
    else
      {:reply, {:closed, :authorization_revoked}, initiate_close(state, :authorization_revoked)}
    end
  end

  @impl true
  def handle_info(:delivery_reap, state) do
    delivery = Delivery.reap(state.runtime_delivery)

    if Delivery.settled?(delivery) do
      {:stop, :subscription_delivery_expired, %{state | runtime_delivery: delivery}}
    else
      Process.send_after(self(), :delivery_reap, 20)
      {:noreply, %{state | runtime_delivery: delivery}}
    end
  end

  def handle_info(:expire, state) do
    {:noreply, initiate_close(state, :maximum_lifetime)}
  end

  def handle_info({:DOWN, ref, :process, owner, _reason}, state)
      when ref == state.owner_monitor and owner == state.transport_ref do
    {:stop, :normal, state}
  end

  @impl true
  def terminate(reason, state) do
    send(
      state.registry,
      {:subscription_listener_closed, self(), state.token, state.transport_ref, reason}
    )

    :ok
  end

  defp enqueue_message(%{active?: false} = state, item) do
    if queue_has_capacity?(state, item) do
      {:ok, append_item(state, item)}
    else
      emit_queue_pressure(:closed)
      {:overflow, initiate_close(state, :slow_consumer)}
    end
  end

  defp enqueue_message(
         %{in_flight_kind: nil, queue: []} = state,
         {kind, message, _key, _bytes}
       ) do
    {:ok, deliver(kind, message, state)}
  end

  defp enqueue_message(state, {_kind, _message, key, _bytes} = item) do
    case replace_coalesced(state.queue, key, item) do
      {:ok, queue, replaced_bytes} ->
        new_queue_bytes = state.queue_bytes - replaced_bytes + item_bytes(item)

        if new_queue_bytes <= state.max_queue_bytes do
          emit_queue_pressure(:coalesced)
          {:coalesced, %{state | queue: queue, queue_bytes: new_queue_bytes}}
        else
          emit_queue_pressure(:closed)
          {:overflow, initiate_close(state, :slow_consumer)}
        end

      :not_found ->
        if queue_has_capacity?(state, item) do
          {:ok, append_item(state, item)}
        else
          emit_queue_pressure(:closed)
          {:overflow, initiate_close(state, :slow_consumer)}
        end
    end
  end

  defp queue_has_capacity?(state, item) do
    length(state.queue) < state.max_queue and
      state.queue_bytes + item_bytes(item) <= state.max_queue_bytes
  end

  defp append_item(state, item) do
    %{
      state
      | queue: state.queue ++ [item],
        queue_bytes: state.queue_bytes + item_bytes(item)
    }
  end

  defp queue_item(kind, message, key, max_message_bytes) do
    case encoded_size(message) do
      {:ok, bytes} when bytes <= max_message_bytes ->
        {:ok, {kind, message, key, bytes}}

      {:ok, _bytes} ->
        {:error, :message_too_large}

      {:error, _reason} ->
        {:error, :invalid_message}
    end
  end

  defp encoded_size(message) do
    case Jason.encode_to_iodata(message) do
      {:ok, encoded} -> {:ok, IO.iodata_length(encoded)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp replace_coalesced(_queue, nil, _item), do: :not_found

  defp replace_coalesced(queue, key, item) do
    if Enum.any?(queue, fn {_kind, _message, queued_key, _bytes} -> queued_key == key end) do
      {queue, replaced_bytes} =
        Enum.map_reduce(queue, 0, fn
          {_kind, _message, ^key, bytes}, _replaced_bytes -> {item, bytes}
          queued, replaced_bytes -> {queued, replaced_bytes}
        end)

      {:ok, queue, replaced_bytes}
    else
      :not_found
    end
  end

  defp deliver_next(%{active?: false} = state), do: state

  defp deliver_next(%{in_flight_kind: nil, queue: [{kind, message, _key, bytes} | rest]} = state) do
    deliver(kind, message, %{state | queue: rest, queue_bytes: state.queue_bytes - bytes})
  end

  defp deliver_next(state), do: state

  defp deliver(kind, message, state) do
    send(
      state.transport_ref,
      {:ex_mcp_subscription_message, self(), kind, message}
    )

    %{state | in_flight_kind: kind}
  end

  defp initiate_close(%{closing?: true} = state, _reason), do: state

  defp initiate_close(%{runtime_delivery: delivery} = state, reason) when not is_nil(delivery) do
    emit_closed(reason)
    %{state | closing?: true, runtime_delivery: Delivery.close(delivery)}
  end

  defp initiate_close(state, reason) do
    emit_closed(reason)
    message = completion(state.subscription_id)
    {:ok, item} = queue_item(:complete, message, nil, state.max_message_bytes)
    state = %{state | closing?: true, queue: [item], queue_bytes: item_bytes(item)}
    deliver_next(state)
  end

  defp item_bytes({_kind, _message, _key, bytes}), do: bytes

  defp publication_authorized?(
         %{publication_authorizer: nil, authorization_required: true},
         _method,
         _params
       ),
       do: false

  defp publication_authorized?(%{publication_authorizer: nil}, _method, _params), do: true

  defp publication_authorized?(state, method, params) do
    context = %{
      filter: state.filter,
      principal_id: state.principal_id,
      tenant_id: state.tenant_id,
      subscription_id: state.subscription_id
    }

    case state.publication_authorizer.(method, params, context) do
      true -> true
      :ok -> true
      {:ok, true} -> true
      _other -> false
    end
  rescue
    _error -> false
  catch
    _kind, _value -> false
  end

  defp acknowledgment(subscription_id, filter) do
    %{
      "jsonrpc" => "2.0",
      "method" => "notifications/subscriptions/acknowledged",
      "params" => %{
        "_meta" => %{@subscription_id_key => subscription_id},
        "notifications" => filter
      }
    }
  end

  defp notification(subscription_id, method, params) do
    meta =
      params
      |> Map.get("_meta", %{})
      |> Map.put(@subscription_id_key, subscription_id)

    %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }
  end

  defp completion(subscription_id) do
    %{
      "jsonrpc" => "2.0",
      "id" => subscription_id,
      "result" => %{
        "resultType" => "complete",
        "_meta" => %{@subscription_id_key => subscription_id}
      }
    }
  end

  defp coalescing_key("notifications/tools/list_changed", _params), do: :tools_list_changed

  defp coalescing_key("notifications/prompts/list_changed", _params),
    do: :prompts_list_changed

  defp coalescing_key("notifications/resources/list_changed", _params),
    do: :resources_list_changed

  defp coalescing_key("notifications/resources/updated", %{"uri" => uri}),
    do: {:resource_updated, uri}

  defp coalescing_key("notifications/tasks", %{"taskId" => task_id}),
    do: {:task, task_id}

  defp coalescing_key(_method, _params), do: nil

  defp emit_closed(reason) do
    :telemetry.execute(
      [:arbor_mcp, :server, :subscription, :closed],
      %{count: 1},
      %{reason: reason}
    )
  end

  defp emit_queue_pressure(action) do
    :telemetry.execute(
      [:arbor_mcp, :server, :subscription, :queue_pressure],
      %{count: 1},
      %{action: action}
    )
  end
end
