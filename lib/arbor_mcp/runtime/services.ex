defmodule Arbor.MCP.Server.Runtime.Services do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    CallbackContext,
    Ref,
    ServiceOperation,
    ServiceRef,
    ShutdownGuard
  }

  def reference(server, kind) do
    with {:ok, runtime} <- runtime(server, kind),
         {:ok, _binding} <- resolve(runtime, kind),
         do: {:ok, ServiceRef.new(runtime, kind)}
  end

  def resolve(server, kind) do
    with {:ok, runtime} <- runtime(server, kind),
         table = Ref.table(runtime),
         false <- ShutdownGuard.closing?(table),
         :ok <- configured(table, kind),
         :ok <- invocation_current(runtime),
         [{:services_generation, generation, supervisor}] <-
           :ets.lookup(table, :services_generation),
         true <- Process.alive?(supervisor),
         [{{:service, ^kind}, %{generation: ^generation} = binding}] <-
           :ets.lookup(table, {:service, kind}),
         true <- Process.alive?(binding.server) do
      {:ok, Map.put(binding, :runtime, runtime)}
    else
      {:error, _reason} = error -> error
      _unavailable -> {:error, :service_unavailable}
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  end

  defp configured(table, kind) do
    case :ets.lookup(table, {:service_configured, kind}) do
      [{{:service_configured, ^kind}, true}] ->
        :ok

      [{{:service_configured, ^kind}, false}] ->
        {:error, :service_not_configured}

      _missing
      when kind in [:tasks, :replay_cache, :subscriptions, :sessions, :resource_subscriptions] ->
        {:error, :service_unavailable}

      _invalid ->
        {:error, :service_not_configured}
    end
  end

  def task_options(opts) do
    case address(opts) do
      nil ->
        {:ok, opts}

      server ->
        with {:ok, tasks} <- resolve(server, :tasks),
             {:ok, publication} <- publication_options(tasks.runtime) do
          {:ok,
           opts
           |> Keyword.delete(:service)
           |> Keyword.merge(adapter_options(tasks))
           |> Keyword.put(:store, tasks.adapter)
           |> Keyword.put(:runtime, tasks.runtime)
           |> Keyword.merge(publication)}
        end
    end
  end

  def subscription_options(opts) do
    case address(opts) do
      nil ->
        {:ok, Arbor.MCP.Server.Subscriptions, opts}

      server ->
        with {:ok, binding} <- resolve(server, :subscriptions) do
          task_opts =
            Keyword.put(Keyword.get(opts, :task_store_opts, []), :runtime, binding.runtime)

          {:ok, binding.adapter,
           opts
           |> Keyword.drop([:runtime, :service])
           |> Keyword.merge(adapter_options(binding))
           |> Keyword.put(:registry, binding.server)
           |> Keyword.put(:task_store_opts, task_opts)}
        end
    end
  end

  def dispatch_options(runtime, opts) do
    case resolve(runtime, :replay_cache) do
      {:ok, binding} ->
        {:ok,
         Keyword.put(
           opts,
           :replay_cache,
           {Arbor.MCP.Server.ReplayCache.Runtime, [runtime: binding.runtime]}
         )}

      {:error, :service_not_configured} ->
        {:ok, opts}

      {:error, _reason} = error ->
        error
    end
  end

  def consume(service, jti, expires_at) do
    ServiceOperation.call(service, :replay_cache, :consume, [jti, expires_at], [])
  end

  defp publication_options(runtime) do
    case resolve(runtime, :subscriptions) do
      {:ok, binding} -> {:ok, [subscription_registry: binding.server]}
      {:error, :service_not_configured} -> {:ok, [notify: false]}
      {:error, _reason} = error -> error
    end
  end

  defp adapter_options(binding) do
    opts = Keyword.put(binding.options, :server, binding.server)
    if binding.namespace, do: Keyword.put(opts, :namespace, binding.namespace), else: opts
  end

  defp address(opts) do
    Keyword.get(opts, :service) || Keyword.get(opts, :runtime) ||
      case CallbackContext.current() do
        %{runtime: runtime} -> runtime
        nil -> nil
      end
  end

  defp runtime(%ServiceRef{} = service, kind), do: ServiceRef.validate(service, kind)
  defp runtime(server, _kind), do: Runtime.ref(server)

  defp invocation_current(runtime) do
    case CallbackContext.current() do
      %{runtime: ^runtime, generation: generation} = invocation ->
        with {:ok, %{generation: ^generation}} <- Admission.route(Ref.table(runtime)),
             true <- Admission.origin_active?(Ref.table(runtime), invocation),
             do: :ok,
             else: (_stale -> {:error, :service_unavailable})

      _outside ->
        :ok
    end
  end
end
