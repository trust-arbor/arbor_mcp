defmodule Arbor.MCP.SubscriptionRegistry.RuntimeStore do
  @moduledoc false
  alias Arbor.MCP.Server.Runtime.{ServiceOperation, ServiceStore}
  alias Arbor.MCP.SessionManager.SessionLease

  def start_link(opts), do: ServiceStore.start_link(__MODULE__, opts)

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 1_000}

  def runtime_service_capabilities, do: %{bounded_startup: 1, namespace: 1, bounded_operations: 1}
  def runtime_service_binding(server, timeout), do: ServiceStore.binding(server, timeout)

  def operate(operation, args, context, opts),
    do:
      ServiceOperation.submit(
        opts[:service_address],
        operation,
        [opts[:namespace] | args],
        context
      )

  def open(opts) do
    limits = %{
      count: Keyword.get(opts, :max_subscriptions, 1_024),
      bytes: Keyword.get(opts, :max_subscription_bytes, 262_144),
      uri: Keyword.get(opts, :max_uri_bytes, 4_096),
      page: Keyword.get(opts, :max_lookup_results, 128),
      page_bytes: Keyword.get(opts, :max_lookup_bytes, 65_536)
    }

    if Enum.all?(Map.values(limits), &(is_integer(&1) and &1 > 0)),
      do: {:ok, %{entries: %{}, limits: limits, expiry_offset: 0}},
      else: {:error, :invalid_resource_subscription_limits}
  end

  def read_address(_model), do: nil
  def close(_model), do: :ok
  def info(_message, model), do: model

  def apply(:subscribe, [namespace, service, lease, uri], context, model) do
    model = expire(model)

    with {:ok, {id, epoch}} <- SessionLease.validate(lease, service, :resource_subscriptions),
         true <- is_binary(uri) and byte_size(uri) in 1..model.limits.uri do
      key = {namespace, id, epoch, uri}
      bytes = :erlang.external_size({key, %{lease: lease, service: service, bytes: 0}}) + 8

      cond do
        Map.has_key?(model.entries, key) ->
          {:ok, model}

        map_size(model.entries) >= model.limits.count ->
          {{:error, :subscription_capacity_exhausted}, model}

        used(model) + bytes > model.limits.bytes ->
          {{:error, :subscription_capacity_exhausted}, model}

        not ServiceOperation.context_current?(context) ->
          {{:error, :operation_timeout}, model}

        true ->
          {:ok,
           %{
             model
             | entries:
                 Map.put(model.entries, key, %{lease: lease, service: service, bytes: bytes})
           }}
      end
    else
      false -> {{:error, :invalid_resource_uri}, model}
      error -> {error, model}
    end
  end

  def apply(:unsubscribe, [namespace, service, lease, uri], context, model) do
    case SessionLease.validate(lease, service, :resource_subscriptions) do
      {:ok, {id, epoch}} ->
        if ServiceOperation.context_current?(context),
          do: {:ok, %{model | entries: Map.delete(model.entries, {namespace, id, epoch, uri})}},
          else: {{:error, :operation_timeout}, model}

      error ->
        {error, model}
    end
  end

  def apply(:remove_session, [namespace, {id, epoch}], context, model) do
    entries =
      Map.reject(model.entries, fn {{ns, sid, ep, _uri}, _entry} ->
        {ns, sid, ep} == {namespace, id, epoch}
      end)

    if ServiceOperation.context_current?(context),
      do: {:ok, %{model | entries: entries}},
      else: {{:error, :operation_timeout}, model}
  end

  def apply(:subscriptions, [namespace, service, lease], _context, model) do
    model = expire(model)

    case SessionLease.validate(lease, service, :resource_subscriptions) do
      {:ok, {id, epoch}} ->
        result =
          for {{^namespace, ^id, ^epoch, uri}, entry} <- model.entries,
              match?(
                {:ok, {^id, ^epoch}},
                SessionLease.validate(entry.lease, service, :resource_subscriptions)
              ),
              do: uri

        {bounded(result, model), model}

      error ->
        {error, model}
    end
  end

  def apply(:sessions, [namespace, uri], _context, model) do
    model = expire(model)
    result = for {{^namespace, id, epoch, ^uri}, _entry} <- model.entries, do: {id, epoch}
    {bounded(result, model), model}
  end

  def apply(:stats, [_namespace], _context, model),
    do: {{:ok, %{subscriptions: map_size(model.entries), subscription_bytes: used(model)}}, model}

  def apply(_operation, _args, _context, model),
    do: {{:error, :unsupported_subscription_operation}, model}

  def expire(model) do
    entries =
      Map.filter(model.entries, fn {_key, entry} ->
        match?(
          {:ok, _key},
          SessionLease.validate(entry.lease, entry.service, :resource_subscriptions)
        )
      end)

    %{model | entries: entries}
  end

  def expire(model, deadline) do
    count = map_size(model.entries)
    offset = if count == 0, do: 0, else: rem(model.expiry_offset, count)

    {entries, processed} =
      model.entries
      |> Enum.drop(offset)
      |> Enum.take(32)
      |> Enum.reduce_while({model.entries, 0}, fn {key, entry}, {entries, processed} ->
        if ServiceOperation.now() < deadline do
          entries =
            if match?(
                 {:ok, _key},
                 SessionLease.validate(entry.lease, entry.service, :resource_subscriptions)
               ) do
              entries
            else
              Map.delete(entries, key)
            end

          {:cont, {entries, processed + 1}}
        else
          {:halt, {entries, processed}}
        end
      end)

    %{model | entries: entries, expiry_offset: offset + processed}
  end

  defp used(model), do: Enum.sum(Enum.map(model.entries, fn {_key, entry} -> entry.bytes end))

  defp bounded(result, model) do
    if length(result) <= model.limits.page and
         :erlang.external_size(result) <= model.limits.page_bytes,
       do: {:ok, Enum.sort(result)},
       else: {:error, :lookup_page_required}
  end
end
