defmodule Arbor.MCP.Server.HTTP.Config do
  @moduledoc false

  alias Arbor.MCP.HttpPlug.Configuration
  alias Arbor.MCP.Server.HTTP.{Bandit, Cowboy, CowboyClaims}
  alias Arbor.MCP.Server.HTTP.Bandit.Options
  alias Arbor.MCP.Server.HTTP.Bandit.Owned, as: OwnedBandit
  alias Arbor.MCP.Server.HTTP.Cowboy.Owned

  @plug_keys [
    :handler_opts,
    :server_info,
    :legacy_http_sse,
    :cors_enabled,
    :allowed_hosts,
    :allowed_origins,
    :principal_id,
    :tenant_id,
    :authorize_subscription_filter,
    :authorize_subscription_publication,
    :subscription_max_queue,
    :subscription_max_message_bytes,
    :subscription_max_queue_bytes,
    :subscription_max_lifetime_ms,
    :subscription_keepalive_interval_ms,
    :sse_mode,
    :validate_origin,
    :body_limit,
    :oauth_enabled,
    :auth_config,
    :scope_mapper,
    :resource,
    :authorization_servers,
    :scopes_supported,
    :bearer_methods_supported,
    :request_state,
    :mrtr,
    :path,
    :endpoint,
    :legacy_http_sse_path,
    :legacy_http_sse_post_path,
    :protocol_mode,
    :instructions,
    :server_capabilities,
    :max_input_requests,
    :max_mrtr_bytes,
    :require_replay_protection
  ]
  @retired [
    :sse_enabled,
    :use_sse,
    :handler_call_timeout,
    :session_manager,
    :session_store,
    :subscription_registry,
    :replay_cache,
    :server
  ]

  def new(opts, ownership \\ :owned) do
    with {:ok, opts} <- options(opts),
         :ok <- validate_retired(opts),
         :ok <- Configuration.subscription_options(opts),
         {:ok, backend, adapter} <- adapter(opts),
         :ok <- available(adapter, backend),
         :ok <- owned_abi(backend, ownership),
         :ok <- validate_binding(opts),
         {:ok, listener} <- listener_options(opts, backend, ownership) do
      host = Keyword.get(opts, :host, "localhost")
      port = Keyword.get(opts, :port, 4000)

      plug =
        opts
        |> Keyword.take(@plug_keys)
        |> Keyword.put_new(:allowed_hosts, default_allowed_hosts(host))
        |> Keyword.put_new(:allowed_origins, default_allowed_origins(host, port))
        |> Keyword.put_new(:legacy_http_sse, false)
        |> Keyword.put_new(:cors_enabled, false)

      {:ok,
       %{
         backend: backend,
         adapter: adapter,
         listener_options: listener,
         plug_options: plug,
         ranch_ref: Keyword.get(listener, :ref)
       }}
    end
  end

  def acquire(nil, _deadline), do: {:ok, nil}
  def acquire(%{backend: :bandit} = config, _deadline), do: {:ok, config}

  def acquire(%{lease: lease} = config, _deadline),
    do: with(:ok <- CowboyClaims.validate(lease), do: {:ok, config})

  def acquire(%{backend: :cowboy} = config, deadline) do
    with {:ok, lease} <- CowboyClaims.acquire(config.ranch_ref, deadline),
         do: {:ok, Map.put(config, :lease, lease)}
  end

  defp owned_abi(:cowboy, :owned) do
    if Owned.compatible?(), do: :ok, else: {:error, :unsupported_owned_ranch_constructor}
  end

  defp owned_abi(:bandit, :owned) do
    if OwnedBandit.compatible?(), do: :ok, else: {:error, :unsupported_owned_bandit_constructor}
  end

  defp owned_abi(_backend, _ownership), do: :ok

  def service_defaults(opts) do
    case options(opts) do
      {:ok, http} -> service_defaults(opts, http)
      _invalid -> opts
    end
  end

  defp service_defaults(opts, http) do
    services = Keyword.get(opts, :services, [])

    if Keyword.keyword?(services) and Keyword.get(http, :protocol_mode) != :modern_only do
      Keyword.put(
        opts,
        :services,
        services |> Keyword.put_new(:sessions, []) |> Keyword.put_new(:resource_subscriptions, [])
      )
    else
      opts
    end
  end

  defp options(opts) do
    http = Keyword.get(opts, :http, [])

    if Keyword.keyword?(http) and
         not Enum.any?(
           Keyword.keys(http),
           &(&1 in [:handler, :handler_args, :runtime, :services, :request_timeout_ms])
         ) do
      http =
        http
        |> rename(:adapter, :http_adapter)
        |> rename(:listener_options, :http_listener_options)

      {:ok, Keyword.merge(opts, http)}
    else
      {:error, :invalid_http_options}
    end
  end

  defp rename(opts, from, to) do
    case Keyword.pop(opts, from) do
      {nil, opts} -> opts
      {value, opts} -> Keyword.put(opts, to, value)
    end
  end

  defp validate_retired(opts) do
    case Enum.find(@retired, &Keyword.has_key?(opts, &1)) do
      nil -> :ok
      key -> {:error, {:retired_http_option, key}}
    end
  end

  defp adapter(opts) do
    case Keyword.get(opts, :http_adapter, :cowboy) do
      :cowboy -> {:ok, :cowboy, Cowboy}
      :bandit -> {:ok, :bandit, Bandit}
      value -> {:error, {:unsupported_http_adapter, value}}
    end
  end

  defp available(adapter, backend) do
    if adapter.available?() do
      :ok
    else
      package = if backend == :cowboy, do: :plug_cowboy, else: :bandit
      {:error, {:missing_http_listener_dependency, backend, package}}
    end
  end

  defp validate_binding(opts) do
    host = Keyword.get(opts, :host, "localhost")
    port = Keyword.get(opts, :port, 4000)

    cond do
      not is_integer(port) or port not in 0..65_535 -> {:error, :invalid_http_port}
      not valid_host?(host) -> {:error, :invalid_http_host}
      Keyword.has_key?(opts, :edge) -> {:error, :http_edge_override_not_supported}
      true -> :ok
    end
  end

  defp listener_options(opts, backend, ownership) do
    listener = Keyword.get(opts, :http_listener_options, [])

    with :ok <- validate_listener_shape(listener, opts, backend),
         :ok <- validate_listener_ownership(listener, backend, ownership) do
      bind_listener(listener, opts, backend, ownership)
    end
  end

  defp validate_listener_shape(listener, opts, backend) do
    cond do
      not Keyword.keyword?(listener) ->
        {:error, :invalid_http_listener_options}

      backend == :bandit and Keyword.get(opts, :ranch_ref) not in [nil, false] ->
        {:error, {:unsupported_http_option, :bandit, :ranch_ref}}

      backend == :cowboy and not Keyword.keyword?(Keyword.get(listener, :transport_options, [])) ->
        {:error, :invalid_http_listener_options}

      true ->
        :ok
    end
  end

  defp validate_listener_ownership(listener, backend, ownership) do
    cond do
      owned_socket?(listener, backend, ownership) ->
        {:error, :http_listener_ownership_override}

      Enum.any?(listener, fn {key, _} ->
        key in [:plug, :dispatch, :handler_module, :handler_options, :transport_module]
      end) ->
        {:error, :http_listener_ownership_override}

      true ->
        :ok
    end
  end

  defp owned_socket?(listener, :cowboy, :owned),
    do: Keyword.has_key?(Keyword.get(listener, :transport_options, []), :socket)

  defp owned_socket?(_listener, _backend, _ownership), do: false

  defp bind_listener(listener, opts, backend, ownership) do
    listener =
      Keyword.merge(listener,
        port: Keyword.get(opts, :port, 4000),
        ip: parse_host(Keyword.get(opts, :host, "localhost"))
      )

    if backend == :cowboy do
      ref = Keyword.get(opts, :ranch_ref)
      ref = if ref in [nil, false], do: default_ref(ownership), else: ref
      {:ok, Keyword.put(listener, :ref, ref)}
    else
      with :ok <- validate_thousand_island(listener),
           :ok <- validate_bandit_options(listener, ownership),
           do: {:ok, Keyword.put(listener, :scheme, :http)}
    end
  end

  defp validate_bandit_options(listener, :owned), do: Options.validate(listener)
  defp validate_bandit_options(_listener, :borrowed), do: :ok

  defp validate_thousand_island(listener) do
    options = Keyword.get(listener, :thousand_island_options, [])

    if Keyword.keyword?(options) and
         not Enum.any?(options, fn {key, _} ->
           key in [:handler_module, :handler_options, :transport_module, :supervisor_options]
         end) do
      :ok
    else
      {:error, :http_listener_ownership_override}
    end
  end

  defp default_ref(:owned), do: make_ref()
  defp default_ref(:borrowed), do: Arbor.MCP.HttpPlug.HTTP

  defp valid_host?(host) when is_tuple(host) do
    limit = if tuple_size(host) == 4, do: 255, else: 65_535

    tuple_size(host) in [4, 8] and
      Enum.all?(Tuple.to_list(host), &(is_integer(&1) and &1 in 0..limit))
  end

  defp valid_host?(host) when is_binary(host), do: byte_size(host) in 1..253
  defp valid_host?(_), do: false
  defp parse_host(host) when is_tuple(host), do: host
  defp parse_host("localhost"), do: {127, 0, 0, 1}

  defp parse_host(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} ->
        address

      _invalid ->
        case :inet.getaddr(String.to_charlist(host), :inet) do
          {:ok, address} -> address
          _unresolved -> {127, 0, 0, 1}
        end
    end
  end

  defp default_allowed_hosts(host)
       when host in ["localhost", "127.0.0.1", "::1", {127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}],
       do: ["localhost", "127.0.0.1", "::1", "[::1]"]

  defp default_allowed_hosts(_), do: :any

  defp default_allowed_origins(host, port) do
    if default_allowed_hosts(host) == :any,
      do: [],
      else:
        for(
          name <- ["localhost", "127.0.0.1", "[::1]"],
          origin <- ["http://#{name}", "http://#{name}:#{port}"],
          do: origin
        )
  end
end
