defmodule Arbor.MCP.Server.Runtime.Config do
  @moduledoc false

  alias Arbor.MCP.Server.HTTP.Config, as: HTTPConfig
  alias Arbor.MCP.Server.RequestState
  alias Arbor.MCP.Server.Runtime.{OwnedChildConfig, ServiceConfig}
  @timer_limit 4_294_967_295

  defstruct transport: nil,
            http: nil,
            handler: nil,
            handler_args: [],
            dispatcher: Arbor.MCP.Server.Dispatch,
            cancellation_tracker: nil,
            dispatch_opts: [],
            mrtr: false,
            request_state: nil,
            middleware: [],
            cache_hints: %{},
            services: nil,
            store_children: [],
            # Concurrent by default, like the other MCP SDKs. :stateful runs one
            # callback at a time so each can return the next handler state.
            execution: :stateless,
            max_concurrency: nil,
            # Data permits include every batch member, retained until settlement.
            max_queue: 128,
            max_request_bytes: 1_000_000,
            max_pending_bytes: 8_000_000,
            max_control_queue: 32,
            max_control_bytes: 65_536,
            max_output_frame_bytes: 1_048_576,
            max_output_term_bytes: 1_048_576,
            max_output_bytes: 4_194_304,
            max_output_frames: 128,
            max_output_scope_bytes: 65_536,
            max_http_writers: 128,
            max_http_writer_metadata_bytes: 65_536,
            max_http_io_frames: 128,
            max_http_io_bytes: 4_194_304,
            max_http_io_frame_bytes: 1_048_576,
            output_timeout_ms: 5_000,
            # A safety net, not the normal limit: callers end work with their
            # own timeout and notifications/cancelled.
            request_timeout_ms: 3_600_000,
            cancel_grace_ms: 100,
            init_timeout_ms: 10_000,
            shutdown_timeout_ms: 5_000

  def new(opts) when is_list(opts) do
    with :ok <- validate_options(opts),
         opts = http_service_defaults(opts),
         keys = Map.keys(Map.from_struct(%__MODULE__{})),
         config = opts |> Keyword.take(keys) |> then(&struct(__MODULE__, &1)) |> put_concurrency(),
         {:ok, http} <- http_config(opts),
         {:ok, config} <- put_mrtr(config, opts),
         :ok <- validate_name(Keyword.get(opts, :name)),
         :ok <- validate_legacy_services(opts),
         :ok <- validate_handler(config),
         {:ok, config} <- put_middleware(config),
         {:ok, config} <- put_cache_hints(config),
         config = put_execution(config),
         :ok <- validate_execution(config),
         :ok <- validate_limits(config),
         :ok <- validate_timers(config),
         {:ok, services} <- ServiceConfig.new(opts),
         {:ok, stores} <- OwnedChildConfig.new(Keyword.get(opts, :store_children, [])),
         :ok <- validate_replay_requirement(opts, services) do
      {:ok, %{config | http: http, services: services, store_children: stores}}
    end
  end

  def option_keys do
    Map.keys(Map.from_struct(%__MODULE__{})) ++
      [:name, :id, :edge, :persistence_key, :require_replay_protection] ++
      HTTPConfig.option_keys()
  end

  defp validate_options(opts) do
    if Keyword.keyword?(opts) do
      case Enum.uniq(Keyword.keys(opts)) -- option_keys() do
        [] -> :ok
        unknown -> {:error, {:unknown_runtime_options, Enum.uniq(unknown)}}
      end
    else
      {:error, :invalid_runtime_options}
    end
  end

  defp put_mrtr(config, opts) do
    http_opts =
      if config.transport in [:http, :mounted_http], do: Keyword.get(opts, :http, []), else: []

    if Keyword.keyword?(http_opts) do
      opts = Keyword.merge(opts, http_opts)
      mrtr = Keyword.get(opts, :mrtr, false)
      request_state = Keyword.get(opts, :request_state, config.dispatch_opts[:request_state])
      validate_mrtr(config, mrtr, request_state)
    else
      {:error, :invalid_http_options}
    end
  end

  defp validate_mrtr(config, mrtr, request_state) when mrtr in [true, false] do
    result =
      if mrtr, do: RequestState.validate_configuration(request_state: request_state), else: :ok

    case result do
      :ok ->
        dispatch_opts =
          if is_nil(request_state),
            do: config.dispatch_opts,
            else: Keyword.put(config.dispatch_opts, :request_state, request_state)

        {:ok, %{config | mrtr: mrtr, request_state: request_state, dispatch_opts: dispatch_opts}}

      {:error, reason} ->
        {:error, {:mrtr_configuration_error, reason}}
    end
  end

  defp validate_mrtr(_config, _mrtr, _request_state), do: {:error, :invalid_mrtr_option}

  defp http_service_defaults(opts) do
    if Keyword.get(opts, :transport) in [:http, :mounted_http],
      do: HTTPConfig.service_defaults(opts),
      else: opts
  end

  defp http_config(opts) do
    if Keyword.get(opts, :transport) == :http, do: HTTPConfig.new(opts), else: {:ok, nil}
  end

  @doc false
  def validate_name(nil), do: :ok
  def validate_name(name) when is_atom(name), do: :ok
  def validate_name({:global, _name}), do: :ok
  def validate_name({:via, Registry, _name}), do: :ok

  def validate_name({:via, module, _name}) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :runtime_name_capabilities, 0) and
         match?(%{finite_lookup: 1}, module.runtime_name_capabilities()) do
      :ok
    else
      {:error, {:invalid_runtime_name, :finite_lookup_required}}
    end
  end

  def validate_name(_invalid), do: {:error, {:invalid_runtime_name, :unsupported_shape}}

  defp validate_legacy_services(opts) do
    cond do
      Keyword.get(opts, :subscription_registry) ->
        {:error,
         {:subscription_registry_requires_service_descriptor,
          :configure_owned_subscriptions_or_namespaced_borrowed_service}}

      Keyword.get(opts, :replay_cache) ->
        {:error, :replay_cache_requires_service_descriptor}

      true ->
        :ok
    end
  end

  defp validate_replay_requirement(opts, services) do
    if Keyword.get(opts, :require_replay_protection, false) and is_nil(services.replay_cache),
      do: {:error, :replay_cache_required},
      else: :ok
  end

  defp validate_handler(%{handler: handler, dispatcher: dispatcher})
       when is_atom(handler) and not is_nil(handler) and is_atom(dispatcher),
       do: :ok

  defp validate_handler(_config), do: {:error, :handler_required}

  # The legacy input bridge runs a callback several times and must hold a
  # stateless one to its snapshot between runs.
  defp put_execution(config),
    do: %{config | dispatch_opts: Keyword.put(config.dispatch_opts, :execution, config.execution)}

  # Dispatch reads the chain from its options, on every transport.
  defp put_middleware(%{middleware: []} = config), do: {:ok, config}

  defp put_middleware(config) do
    with {:ok, middleware} <- Arbor.MCP.Server.Middleware.normalize(config.middleware) do
      {:ok,
       %{
         config
         | middleware: middleware,
           dispatch_opts: Keyword.put(config.dispatch_opts, :middleware, middleware)
       }}
    end
  end

  # `ttlMs` / `cacheScope` for the cacheable results a handler leaves them off,
  # by method, as the TypeScript SDK's `cacheHints` server option: mostly the
  # list results, which the server builds itself. Checked here, at start.
  defp put_cache_hints(%{cache_hints: hints} = config) when hints in [%{}, []], do: {:ok, config}

  defp put_cache_hints(%{cache_hints: hints} = config) when is_map(hints) or is_list(hints) do
    hints
    |> Enum.reduce_while({:ok, %{}}, fn {method, hint}, {:ok, acc} ->
      case cache_hint(to_string(method), hint) do
        {:ok, wire} -> {:cont, {:ok, Map.put(acc, to_string(method), wire)}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, wire} ->
        {:ok,
         %{
           config
           | cache_hints: wire,
             dispatch_opts: Keyword.put(config.dispatch_opts, :cache_hints, wire)
         }}

      error ->
        error
    end
  end

  defp put_cache_hints(_config), do: {:error, {:invalid_cache_hints, :not_a_map}}

  defp cache_hint(method, hint) when is_list(hint) or is_map(hint) do
    with true <- Arbor.MCP.Protocol.CacheableResult.cacheable_method?(method),
         {:ok, wire} <- cache_hint_fields(Map.new(hint)) do
      {:ok, wire}
    else
      false -> {:error, {:invalid_cache_hints, {:not_cacheable, method}}}
      {:error, field} -> {:error, {:invalid_cache_hints, {method, field}}}
    end
  end

  defp cache_hint(method, _hint), do: {:error, {:invalid_cache_hints, {method, :not_a_map}}}

  defp cache_hint_fields(hint) do
    Enum.reduce_while(hint, {:ok, %{}}, fn
      {:ttl_ms, ms}, {:ok, acc} when is_integer(ms) and ms >= 0 ->
        {:cont, {:ok, Map.put(acc, "ttlMs", ms)}}

      {:cache_scope, scope}, {:ok, acc} when scope in [:public, :private] ->
        {:cont, {:ok, Map.put(acc, "cacheScope", Atom.to_string(scope))}}

      {:cache_scope, scope}, {:ok, acc} when scope in ["public", "private"] ->
        {:cont, {:ok, Map.put(acc, "cacheScope", scope)}}

      {field, _invalid}, _acc ->
        {:halt, {:error, field}}
    end)
  end

  @default_max_concurrency 64

  defp put_concurrency(%{max_concurrency: nil, execution: :stateful} = config),
    do: %{config | max_concurrency: 1}

  defp put_concurrency(%{max_concurrency: nil} = config),
    do: %{config | max_concurrency: @default_max_concurrency}

  defp put_concurrency(config), do: config

  defp validate_execution(%{execution: :stateful, max_concurrency: 1}), do: :ok

  defp validate_execution(%{execution: :stateless, max_concurrency: count})
       when is_integer(count) and count > 0,
       do: :ok

  defp validate_execution(_config), do: {:error, :invalid_execution_configuration}

  defp validate_limits(config) do
    positive = [
      :max_request_bytes,
      :max_pending_bytes,
      :max_control_bytes,
      :max_output_frame_bytes,
      :max_output_term_bytes,
      :max_output_bytes,
      :max_output_frames,
      :max_output_scope_bytes,
      :max_http_writers,
      :max_http_writer_metadata_bytes,
      :max_http_io_frames,
      :max_http_io_bytes,
      :max_http_io_frame_bytes,
      :output_timeout_ms,
      :request_timeout_ms,
      :init_timeout_ms,
      :shutdown_timeout_ms
    ]

    nonnegative = [:max_queue, :max_control_queue, :cancel_grace_ms]

    case Enum.find(positive, &(not positive_integer?(Map.fetch!(config, &1)))) ||
           Enum.find(nonnegative, &(not nonnegative_integer?(Map.fetch!(config, &1)))) do
      nil -> :ok
      key -> {:error, {:invalid_limit, key}}
    end
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp nonnegative_integer?(value), do: is_integer(value) and value >= 0

  defp validate_timers(config) do
    keys = [
      :request_timeout_ms,
      :init_timeout_ms,
      :shutdown_timeout_ms,
      :cancel_grace_ms,
      :output_timeout_ms,
      :max_http_writers,
      :max_http_writer_metadata_bytes,
      :max_http_io_frames,
      :max_http_io_bytes,
      :max_http_io_frame_bytes
    ]

    case Enum.find(keys, &(Map.fetch!(config, &1) > @timer_limit)) do
      nil -> :ok
      key -> {:error, {:invalid_limit, key}}
    end
  end
end
