defmodule Arbor.MCP.Server.Runtime.ServiceConfig do
  @moduledoc false

  alias Arbor.MCP.Server.{ReplayCache, Subscriptions}
  alias Arbor.MCP.SessionManager.RuntimeStore, as: SessionStore
  alias Arbor.MCP.SubscriptionRegistry.RuntimeStore, as: ResourceStore
  alias Arbor.MCP.Tasks.Store

  @defaults [
    tasks: Store.ETS,
    replay_cache: ReplayCache.ETS,
    subscriptions: Subscriptions,
    sessions: SessionStore,
    resource_subscriptions: ResourceStore
  ]

  def new(opts) do
    services = Keyword.get(opts, :services, [])

    if Keyword.keyword?(services) and
         Enum.all?(Keyword.keys(services), &(&1 in Keyword.keys(@defaults))) and
         length(Keyword.keys(services)) == length(Enum.uniq(Keyword.keys(services))) do
      Enum.reduce_while(@defaults, {:ok, %{}}, fn {kind, adapter}, {:ok, result} ->
        descriptor =
          Keyword.get(
            services,
            kind,
            if(kind in [:replay_cache, :sessions, :resource_subscriptions], do: nil, else: [])
          )

        case normalize(kind, adapter, descriptor, opts) do
          {:ok, value} -> {:cont, {:ok, Map.put(result, kind, value)}}
          {:error, reason} -> {:halt, {:error, {:invalid_service, kind, reason}}}
        end
      end)
    else
      {:error, :invalid_services_configuration}
    end
  end

  defp normalize(_kind, _default, value, _opts) when value in [nil, false], do: {:ok, nil}

  defp normalize(kind, default, descriptor, opts) when is_list(descriptor) do
    if Keyword.keyword?(descriptor) and
         length(Keyword.keys(descriptor)) == length(Enum.uniq(Keyword.keys(descriptor))) and
         Enum.all?(
           Keyword.keys(descriptor),
           &(&1 in [:ownership, :adapter, :options, :server, :namespace])
         ) do
      adapter = Keyword.get(descriptor, :adapter, default)
      options = Keyword.get(descriptor, :options, [])
      ownership = Keyword.get(descriptor, :ownership, :owned)

      with :ok <- validate_adapter(kind, adapter),
           true <- Keyword.keyword?(options),
           :ok <- validate_options(options),
           :ok <- validate_domain(kind, options),
           {:ok, namespace} <- namespace(ownership, descriptor, opts),
           :ok <- validate_capabilities(adapter, ownership),
           :ok <- validate_operation_capability(kind, adapter) do
        {:ok,
         %{
           kind: kind,
           adapter: adapter,
           ownership: ownership,
           options: options,
           server: Keyword.get(descriptor, :server),
           namespace: namespace
         }}
      else
        false -> {:error, :invalid_options}
        {:error, _reason} = error -> error
      end
    else
      {:error, :invalid_descriptor}
    end
  end

  defp normalize(_kind, _default, _descriptor, _opts), do: {:error, :invalid_descriptor}

  defp validate_adapter(kind, adapter) when is_atom(adapter) and not is_nil(adapter) do
    functions =
      case kind do
        :sessions ->
          [operate: 4, runtime_service_binding: 2, lease_active?: 3]

        :resource_subscriptions ->
          [operate: 4, runtime_service_binding: 2]

        :tasks ->
          [
            create: 3,
            fetch: 3,
            submit_input: 4,
            request_cancel: 3,
            transition: 4,
            take_input_responses: 3,
            cancellation_requested?: 3
          ]

        :replay_cache ->
          [consume: 3]

        :subscriptions ->
          [
            listen: 4,
            cancel: 3,
            close: 4,
            remove_transport: 2,
            publish: 3,
            publish_async: 3,
            entries: 1
          ]
      end

    if Code.ensure_loaded?(adapter) and
         Enum.all?(functions, fn {name, arity} -> function_exported?(adapter, name, arity) end),
       do: :ok,
       else: {:error, :invalid_adapter}
  end

  defp validate_adapter(_kind, _adapter), do: {:error, :invalid_adapter}

  defp validate_domain(:sessions, options) do
    if Keyword.get(options, :storage_backend, :ets) == :ets,
      do: :ok,
      else: {:error, :runtime_durable_sessions_unqualified}
  end

  defp validate_domain(_kind, _options), do: :ok

  defp validate_options(options) do
    reserved = [
      :name,
      :server,
      :namespace,
      :runtime_table,
      :init_timeout_ms,
      :listener_supervisor
    ]

    if Enum.any?(Keyword.keys(options), &(&1 in reserved)),
      do: {:error, :reserved_adapter_option},
      else: :ok
  end

  defp namespace(:owned, descriptor, _opts) do
    if Keyword.has_key?(descriptor, :server) or Keyword.has_key?(descriptor, :namespace),
      do: {:error, :owned_service_address_override},
      else: {:ok, nil}
  end

  defp namespace(:borrowed, descriptor, opts) do
    key = Keyword.get(descriptor, :namespace, Keyword.get(opts, :persistence_key))

    cond do
      not is_binary(key) or byte_size(key) not in 1..256 -> {:error, :stable_namespace_required}
      is_nil(Keyword.get(descriptor, :server)) -> {:error, :borrowed_server_required}
      true -> {:ok, key}
    end
  end

  defp namespace(_ownership, _descriptor, _opts), do: {:error, :invalid_ownership}

  defp validate_operation_capability(kind, adapter)
       when kind in [:tasks, :replay_cache, :sessions, :resource_subscriptions] do
    if adapter.runtime_service_capabilities()[:bounded_operations] == 1 and
         function_exported?(adapter, :operate, 4) and
         function_exported?(adapter, :runtime_service_binding, 2),
       do: :ok,
       else: {:error, :bounded_operations_required}
  rescue
    _error -> {:error, :invalid_capability_declaration}
  end

  defp validate_operation_capability(_kind, _adapter), do: :ok

  defp validate_capabilities(adapter, ownership) do
    capabilities =
      if function_exported?(adapter, :runtime_service_capabilities, 0),
        do: adapter.runtime_service_capabilities(),
        else: %{}

    case ownership do
      :owned ->
        if is_map(capabilities) and capabilities[:bounded_startup] == 1 and
             function_exported?(adapter, :start_link, 1),
           do: :ok,
           else: {:error, :bounded_owned_start_required}

      :borrowed ->
        if is_map(capabilities) and capabilities[:namespace] == 1,
          do: :ok,
          else: {:error, :namespaced_operations_required}
    end
  rescue
    _error -> {:error, :invalid_capability_declaration}
  catch
    _kind, _reason -> {:error, :invalid_capability_declaration}
  end
end
