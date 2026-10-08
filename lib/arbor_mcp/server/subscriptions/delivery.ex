defmodule Arbor.MCP.Server.Subscriptions.Delivery do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime.Deadline
  alias Arbor.MCP.Server.Subscriptions.{Mailbox, Origin}

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"
  @metadata_allowance 8_192

  defstruct [
    :mailbox,
    :registration,
    :transport,
    :subscription_id,
    :filter,
    :max_queue,
    :max_queue_bytes,
    :timeout,
    :in_flight,
    queue: [],
    queue_bytes: 0,
    active?: false,
    closing?: false
  ]

  def new(opts) do
    timeout = Keyword.fetch!(opts, :publication_timeout_ms)
    lifetime = Keyword.fetch!(opts, :max_lifetime_ms)
    transport = Keyword.fetch!(opts, :transport_ref)
    count = Keyword.fetch!(opts, :max_queue) + 2
    message_bytes = Keyword.fetch!(opts, :max_message_bytes)
    term_bytes = message_bytes * 2 + 1_024

    with {:ok, registration} <- registration(opts, transport, lifetime) do
      mailbox =
        Mailbox.new(
          max_count: count,
          max_bytes:
            Keyword.fetch!(opts, :max_queue_bytes) * 2 + 2 * term_bytes +
              count * @metadata_allowance,
          max_message_bytes: message_bytes + 1,
          max_term_bytes: term_bytes
        )

      {:ok,
       %__MODULE__{
         mailbox: mailbox,
         registration: registration,
         transport: transport,
         subscription_id: Keyword.fetch!(opts, :subscription_id),
         filter: Keyword.fetch!(opts, :filter),
         max_queue: Keyword.fetch!(opts, :max_queue),
         max_queue_bytes: Keyword.fetch!(opts, :max_queue_bytes),
         timeout: timeout
       }}
    end
  end

  defp registration(opts, transport, lifetime) do
    case Keyword.get(opts, :http_listener) do
      nil ->
        Origin.for_listener(
          Keyword.fetch!(opts, :runtime_table),
          transport,
          Deadline.after_ms(lifetime)
        )

      binding ->
        Origin.for_http_listener(
          binding,
          Keyword.fetch!(opts, :runtime),
          is_function(Keyword.get(opts, :publication_authorizer), 3)
        )
    end
  end

  def reference(state),
    do: %{mailbox: state.mailbox, registration: state.registration, id: state.subscription_id}

  def settled?(state), do: state.closing? and is_nil(state.in_flight) and state.queue == []

  def offer(ref, method, params, origin, deadline) do
    origin = if is_nil(origin), do: ref.registration, else: origin
    origin = Origin.limit(origin, deadline)
    deadline = Origin.deadline(origin, deadline)

    if Origin.compatible?(origin, ref.registration) do
      message = notification(ref.id, method, params)

      Mailbox.offer(ref.mailbox, message, origin, deadline, %{
        kind: :notification,
        key: source_key(coalescing_key(method, params), origin),
        params: params
      })
    else
      {:error, :subscription_origin_retired}
    end
  rescue
    ArgumentError -> {:error, :invalid_message}
    BadMapError -> {:error, :invalid_message}
  end

  def accept(state, id, authorize) do
    case Mailbox.take(state.mailbox, id) do
      {:ok, entry} -> accept_entry(state, entry, authorize)
      _ -> {{:closed, :source_retired}, state}
    end
  end

  defp accept_entry(state, entry, authorize) do
    method = entry.payload["method"]
    authorized? = authorize.(method, entry.mode.params)

    cond do
      not Mailbox.active?(state.mailbox, entry.id) or not Origin.valid?(entry.origin) ->
        Mailbox.finish(state.mailbox, entry.id)
        {{:closed, :source_retired}, state}

      not authorized? ->
        Mailbox.finish(state.mailbox, entry.id)
        {{:closed, :authorization_revoked}, close(state)}

      state.closing? ->
        Mailbox.finish(state.mailbox, entry.id)
        {{:closed, :closing}, state}

      true ->
        admit_queue(state, entry)
    end
  end

  def activate(%{active?: false} = state) do
    state = %{state | active?: true}
    control(state, :acknowledged, acknowledgment(state.subscription_id, state.filter))
  end

  def activate(state), do: state

  def delivered(%{in_flight: %{id: id, kind: kind}} = state, id) do
    Mailbox.finish(state.mailbox, id)
    state = %{state | in_flight: nil}
    if kind == :complete, do: {:stop, state}, else: {:ok, next(state)}
  end

  def delivered(state, _stale), do: {:ok, state}

  def checkout(%{in_flight: %{id: id, kind: kind}} = state, id) do
    with {:ok, entry} <- Mailbox.checkout(state.mailbox, id),
         true <- Origin.valid?(entry.origin) do
      {{:ok, kind, entry.payload, entry.origin}, state}
    else
      _ ->
        Mailbox.finish(state.mailbox, id)
        {{:error, :source_retired}, next(%{state | in_flight: nil})}
    end
  end

  def checkout(state, _id), do: {{:error, :invalid_subscription_delivery}, state}

  def reap(state) do
    Mailbox.reap(state.mailbox)

    case state.in_flight do
      %{id: id} ->
        case Mailbox.entry(state.mailbox, id) do
          {:ok, _entry} -> state
          _ -> next(%{state | in_flight: nil})
        end

      nil ->
        next(state)
    end
  end

  def close(%{closing?: true} = state), do: state

  def close(state) do
    Enum.each(state.queue, fn {id, _key, _bytes} -> Mailbox.finish(state.mailbox, id) end)
    state = %{state | closing?: true, queue: [], queue_bytes: 0}
    control(state, :complete, completion(state.subscription_id))
  end

  defp control(state, kind, message) do
    deadline = Deadline.after_ms(state.timeout)

    with {:ok, origin} <- control_origin(state.registration, kind, deadline),
         {:ok, id} <-
           Mailbox.offer(state.mailbox, message, origin, deadline, %{
             kind: kind,
             key: nil,
             params: %{}
           }),
         {:ok, entry} <- Mailbox.take(state.mailbox, id) do
      {_result, state} = append(state, entry)
      next(state)
    else
      _ -> %{state | closing?: true}
    end
  end

  defp control_origin(registration, :complete, deadline),
    do: Origin.terminal(registration, deadline)

  defp control_origin(registration, _kind, deadline),
    do: {:ok, Origin.limit(registration, deadline)}

  defp admit_queue(state, entry) do
    key = entry.mode.key
    bytes = wire_bytes(entry.payload)
    old = if key, do: Enum.find(state.queue, fn {_id, old_key, _bytes} -> old_key == key end)

    cond do
      old ->
        coalesce(state, entry, old, bytes)

      length(state.queue) >= state.max_queue or state.queue_bytes + bytes > state.max_queue_bytes ->
        Mailbox.finish(state.mailbox, entry.id)
        {{:closed, :slow_consumer}, close(state)}

      true ->
        {result, state} = append(state, entry)
        {result, next(state)}
    end
  end

  defp coalesce(state, entry, {old_id, key, old_bytes}, bytes) do
    if state.queue_bytes - old_bytes + bytes <= state.max_queue_bytes do
      case Mailbox.queue(state.mailbox, entry.id) do
        {:ok, _} ->
          queue =
            Enum.map(state.queue, fn {id, old_key, old_size} ->
              if id == old_id, do: {entry.id, key, bytes}, else: {id, old_key, old_size}
            end)

          Mailbox.finish(state.mailbox, old_id)

          {:coalesced,
           %{state | queue: queue, queue_bytes: state.queue_bytes - old_bytes + bytes}}

        _ ->
          Mailbox.finish(state.mailbox, entry.id)
          {{:closed, :source_retired}, state}
      end
    else
      Mailbox.finish(state.mailbox, entry.id)
      {{:closed, :slow_consumer}, close(state)}
    end
  end

  defp append(state, entry) do
    case Mailbox.queue(state.mailbox, entry.id) do
      {:ok, _} ->
        bytes = wire_bytes(entry.payload)

        {:ok,
         %{
           state
           | queue: state.queue ++ [{entry.id, entry.mode.key, bytes}],
             queue_bytes: state.queue_bytes + bytes
         }}

      _ ->
        Mailbox.finish(state.mailbox, entry.id)
        {{:closed, :source_retired}, state}
    end
  end

  defp next(%{active?: true, in_flight: nil, queue: [{id, _key, bytes} | rest]} = state) do
    state = %{state | queue: rest, queue_bytes: state.queue_bytes - bytes}

    with {:ok, entry} <- Mailbox.offer_delivery(state.mailbox, id),
         true <- Origin.valid?(entry.origin) do
      send(state.transport, {:ex_mcp_subscription_ready, self(), id, entry.deadline})
      %{state | in_flight: %{id: id, kind: entry.mode.kind}}
    else
      _ ->
        Mailbox.finish(state.mailbox, id)
        next(state)
    end
  end

  defp next(state), do: state

  defp wire_bytes(message), do: byte_size(Jason.encode!(message))

  defp acknowledgment(id, filter),
    do: %{
      "jsonrpc" => "2.0",
      "method" => "notifications/subscriptions/acknowledged",
      "params" => %{
        "_meta" => %{@subscription_id_key => id},
        "notifications" => filter
      }
    }

  defp notification(id, method, params) do
    meta = params |> Map.get("_meta", %{}) |> Map.put(@subscription_id_key, id)
    %{"jsonrpc" => "2.0", "method" => method, "params" => Map.put(params, "_meta", meta)}
  end

  defp completion(id),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"resultType" => "complete", "_meta" => %{@subscription_id_key => id}}
    }

  defp coalescing_key("notifications/tools/list_changed", _), do: :tools_list_changed
  defp coalescing_key("notifications/prompts/list_changed", _), do: :prompts_list_changed
  defp coalescing_key("notifications/resources/list_changed", _), do: :resources_list_changed
  defp coalescing_key("notifications/resources/updated", %{"uri" => uri}), do: {:resource, uri}
  defp coalescing_key("notifications/tasks", %{"taskId" => id}), do: {:task, id}
  defp coalescing_key(_method, _params), do: nil

  # A later, still-active source cannot replace an earlier completed source's
  # effect: cancellation of the later callback must not erase the former one.
  defp source_key(nil, _origin), do: nil

  defp source_key(key, origin) do
    case Origin.proof(origin) do
      %{phase: phase} -> {key, phase}
      nil -> {key, nil}
    end
  end
end
