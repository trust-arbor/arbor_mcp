defmodule Arbor.MCP.Server.Runtime.Config do
  @moduledoc false

  alias Arbor.MCP.Server.HTTP.Config, as: HTTPConfig
  alias Arbor.MCP.Server.Runtime.{OwnedChildConfig, ServiceConfig}
  @timer_limit 4_294_967_295

  defstruct transport: nil,
            http: nil,
            handler: nil,
            handler_args: [],
            dispatcher: Arbor.MCP.Server.Dispatch,
            cancellation_tracker: nil,
            dispatch_opts: [],
            services: nil,
            store_children: [],
            execution: :stateful,
            max_concurrency: 1,
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
            request_timeout_ms: 10_000,
            cancel_grace_ms: 100,
            init_timeout_ms: 10_000,
            shutdown_timeout_ms: 5_000

  def new(opts) when is_list(opts) do
    opts = http_service_defaults(opts)
    keys = Map.keys(Map.from_struct(%__MODULE__{}))
    config = struct(__MODULE__, Keyword.take(opts, keys))

    with {:ok, http} <- http_config(opts),
         :ok <- validate_name(Keyword.get(opts, :name)),
         :ok <- validate_legacy_services(opts),
         :ok <- validate_handler(config),
         :ok <- validate_execution(config),
         :ok <- validate_limits(config),
         :ok <- validate_timers(config),
         {:ok, services} <- ServiceConfig.new(opts),
         {:ok, stores} <- OwnedChildConfig.new(Keyword.get(opts, :store_children, [])),
         :ok <- validate_replay_requirement(opts, services) do
      {:ok, %{config | http: http, services: services, store_children: stores}}
    end
  end

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
