defmodule Arbor.MCP.ClientConfig do
  @moduledoc """
  Configuration builder for ArborMCP clients.

  This module provides a fluent interface for building client configurations,
  ensuring type safety and validation at compile time.

  ## Usage

      config = Arbor.MCP.ClientConfig.new()
               |> Arbor.MCP.ClientConfig.put_transport(:http)
               |> Arbor.MCP.ClientConfig.put_url("https://api.example.com")
               |> Arbor.MCP.ClientConfig.put_transport_options(
                 timeout: 30_000,
                 pool_size: 10
               )

      {:ok, client} = Arbor.MCP.Client.connect(config)

  ## Transport Configuration

  ### stdio Transport

      config = Arbor.MCP.ClientConfig.new()
               |> Arbor.MCP.ClientConfig.put_transport(:stdio)
               |> Arbor.MCP.ClientConfig.put_command(["python", "server.py"])
               |> Arbor.MCP.ClientConfig.put_args(["--verbose"])
               |> Arbor.MCP.ClientConfig.put_env([{"DEBUG", "1"}])

  ### HTTP Transport

      config = Arbor.MCP.ClientConfig.new()
               |> Arbor.MCP.ClientConfig.put_transport(:http)
               |> Arbor.MCP.ClientConfig.put_url("https://api.example.com")
               |> Arbor.MCP.ClientConfig.put_headers([{"Authorization", "Bearer token"}])
               |> Arbor.MCP.ClientConfig.put_transport_options(
                 use_sse: true,
                 timeout: 10_000
               )

  ## Advanced Options

      config = Arbor.MCP.ClientConfig.new()
               |> Arbor.MCP.ClientConfig.put_name(:my_client)
               |> Arbor.MCP.ClientConfig.put_handler(MyClientHandler)
               |> Arbor.MCP.ClientConfig.put_retry_policy(
                 max_attempts: 3,
                 backoff: :exponential
               )

  ## Basic Usage

      # Create a simple HTTP configuration
      config = Arbor.MCP.ClientConfig.new(:http, url: "http://localhost:8080")
      {:ok, client} = Arbor.MCP.Client.connect(config)

  ## Advanced Usage

      # Create a production configuration with full settings
      config = Arbor.MCP.ClientConfig.new(:production)
      |> Arbor.MCP.ClientConfig.put_transport(:http, url: "https://api.example.com")
      |> Arbor.MCP.ClientConfig.put_retry_policy(max_attempts: 5, base_interval: 1000)
      |> Arbor.MCP.ClientConfig.put_timeout(connect: 10_000, request: 30_000)
      |> Arbor.MCP.ClientConfig.put_auth(:bearer, token: "...")

      {:ok, client} = Arbor.MCP.Client.connect(config)

  ## Configuration Profiles

  Built-in profiles:
  - `:development` - For local development with debugging
  - `:test` - For testing with fast timeouts
  - `:production` - For production with robust retry policies
  - `:http` - HTTP transport with sensible defaults
  - `:stdio` - Stdio transport configuration
  - `:beam` - BEAM-local transport configuration
  """

  alias Arbor.MCP.Internal.VersionInfo

  @type profile :: atom()
  @type transport_type :: :http | :stdio | :beam
  @type auth_type :: :none | :bearer | :basic | :oauth | :custom
  @type log_level :: :debug | :info | :warn | :error | :none

  @type transport_config :: %{
          type: transport_type(),
          url: String.t() | nil,
          command: String.t() | [String.t()] | nil,
          host: String.t(),
          port: integer(),
          path: String.t(),
          ssl: boolean(),
          headers: %{String.t() => String.t()},
          options: keyword()
        }

  @type retry_policy :: %{
          enabled: boolean(),
          max_attempts: pos_integer(),
          base_interval: pos_integer(),
          max_interval: pos_integer(),
          backoff_type: :linear | :exponential | :fixed,
          jitter: boolean()
        }

  @doc """
  Timeout configuration for ArborMCP operations.

  - `total`: Maximum time for an entire logical operation, including all retries (ms)
  - `connect`: Time to establish initial TCP/TLS connection (ms)
  - `request`: Time for a single request-response cycle (ms)
  - `stream`: Timeouts specific to persistent streams like SSE
    - `handshake`: Time to wait for stream handshake after connection (ms)
    - `idle`: Time a stream can be idle before being considered dead (ms)
  - `pool`: Connection pool related timeouts
    - `checkout`: Time to wait for a connection from the pool (ms)
    - `idle`: Time a connection can sit idle in the pool (ms)
  """
  @type timeout_config :: %{
          total: pos_integer(),
          connect: pos_integer(),
          request: pos_integer(),
          stream: %{
            handshake: pos_integer(),
            idle: pos_integer()
          },
          pool: %{
            checkout: pos_integer(),
            idle: pos_integer()
          }
        }

  @type auth_config :: %{
          type: auth_type(),
          token: String.t() | nil,
          username: String.t() | nil,
          password: String.t() | nil,
          headers: %{String.t() => String.t()},
          refresh_token: String.t() | nil,
          client_id: String.t() | nil,
          client_secret: String.t() | nil,
          custom_handler: {module(), atom(), [any()]} | nil
        }

  # Connection pool configuration.
  # Note: `checkout_timeout` and `idle_timeout` are deprecated in favor of
  # `timeouts.pool.checkout` and `timeouts.pool.idle` respectively.
  @type pool_config :: %{
          enabled: boolean(),
          size: pos_integer(),
          max_overflow: non_neg_integer(),
          checkout_timeout: pos_integer(),
          idle_timeout: pos_integer()
        }

  @type observability_config :: %{
          logging: %{
            enabled: boolean(),
            level: log_level(),
            format: :text | :json,
            include_request_id: boolean(),
            include_metadata: boolean()
          },
          telemetry: %{
            enabled: boolean(),
            prefix: [atom()],
            include_system_metrics: boolean()
          },
          tracing: %{
            enabled: boolean(),
            sampler: atom() | {module(), atom(), [any()]},
            propagators: [atom()]
          }
        }

  @type t :: %__MODULE__{
          profile: profile() | nil,
          transport: transport_config(),
          retry_policy: retry_policy(),
          timeouts: timeout_config(),
          auth: auth_config(),
          pool: pool_config(),
          observability: observability_config(),
          client_info: %{
            name: String.t(),
            version: String.t(),
            user_agent: String.t()
          },
          fallback_transports: [transport_config()],
          custom_options: %{atom() => any()}
        }

  defstruct [
    :profile,
    :transport,
    :retry_policy,
    :timeouts,
    :auth,
    :pool,
    :observability,
    :client_info,
    :fallback_transports,
    :custom_options
  ]

  # Public API

  @doc """
  Creates a new client configuration.

  ## Examples

      # Use a predefined profile
      config = Arbor.MCP.ClientConfig.new(:production)

      # Create HTTP configuration with custom options
      config = Arbor.MCP.ClientConfig.new(:http, url: "http://localhost:8080")

      # Create stdio configuration
      config = Arbor.MCP.ClientConfig.new(:stdio, command: ["python", "server.py"])

      # Start with empty configuration
      config = Arbor.MCP.ClientConfig.new()
  """
  @spec new() :: t()
  def new do
    base_new()
    |> apply_profile(:development)
  end

  @spec new(profile() | transport_type()) :: t()
  def new(profile_or_transport) when is_atom(profile_or_transport) do
    case transport_type?(profile_or_transport) do
      true ->
        # It's a transport type, create config for that transport
        base_new()
        |> apply_profile(:development)
        |> put_transport(profile_or_transport, [])

      false ->
        # It's a profile name
        base_new()
        |> apply_profile(profile_or_transport)
    end
  end

  @spec new(transport_type(), keyword()) :: t()
  def new(transport_type, opts) when is_atom(transport_type) and is_list(opts) do
    if transport_type?(transport_type) do
      base_new()
      |> apply_profile(:development)
      |> put_transport(transport_type, opts)
    else
      # It's a profile with custom options
      base_new()
      |> apply_profile(transport_type)
      |> apply_custom_options(opts)
    end
  end

  defp base_new do
    %__MODULE__{
      profile: nil,
      transport: default_transport_config(),
      retry_policy: default_retry_policy(),
      timeouts: default_timeout_config(),
      auth: default_auth_config(),
      pool: default_pool_config(),
      observability: default_observability_config(),
      client_info: default_client_info(),
      fallback_transports: [],
      custom_options: %{}
    }
  end

  @doc """
  Configures the transport settings.

  ## Examples

      config = Arbor.MCP.ClientConfig.new()
      |> Arbor.MCP.ClientConfig.put_transport(:http, url: "http://localhost:8080")

      config = Arbor.MCP.ClientConfig.new()
      |> Arbor.MCP.ClientConfig.put_transport(:stdio, command: ["python", "server.py"])
  """
  @spec put_transport(t(), transport_type(), keyword()) :: t()
  def put_transport(config, transport_type, opts \\ []) do
    transport_config = build_transport_config(transport_type, opts)
    %{config | transport: transport_config}
  end

  @doc """
  Adds a fallback transport configuration.

  ## Examples

      config = Arbor.MCP.ClientConfig.new(:http, url: "http://primary:8080")
      |> Arbor.MCP.ClientConfig.add_fallback(:http, url: "http://backup:8080")
      |> Arbor.MCP.ClientConfig.add_fallback(:stdio, command: "local-server")
  """
  @spec add_fallback(t(), transport_type(), keyword()) :: t()
  def add_fallback(config, transport_type, opts \\ []) do
    fallback_config = build_transport_config(transport_type, opts)
    fallbacks = config.fallback_transports ++ [fallback_config]
    %{config | fallback_transports: fallbacks}
  end

  @doc """
  Configures retry policy settings.

  ## Examples

      config = Arbor.MCP.ClientConfig.new()
      |> Arbor.MCP.ClientConfig.put_retry_policy(
        max_attempts: 5,
        base_interval: 1000,
        backoff_type: :exponential
      )
  """
  @spec put_retry_policy(t(), keyword()) :: t()
  def put_retry_policy(config, opts) do
    retry_policy = Map.merge(config.retry_policy, Map.new(opts))
    %{config | retry_policy: retry_policy}
  end

  @doc """
  Configures timeout settings.

  ## Examples

      # Basic timeouts
      config = Arbor.MCP.ClientConfig.new()
      |> Arbor.MCP.ClientConfig.put_timeout(
        total: 120_000,
        connect: 10_000,
        request: 30_000
      )

      # Advanced timeouts with stream and pool settings
      config = Arbor.MCP.ClientConfig.new()
      |> Arbor.MCP.ClientConfig.put_timeout(
        total: 120_000,
        connect: 10_000,
        request: 30_000,
        stream: [handshake: 15_000, idle: 60_000],
        pool: [checkout: 5_000, idle: 300_000]
      )

  ## Timeout Types

  - `total`: Maximum time for entire operation including retries (ms)
  - `connect`: Time to establish TCP/TLS connection (ms)
  - `request`: Time for single request-response cycle (ms)
  - `stream.handshake`: Time to wait for SSE handshake completion (ms)
  - `stream.idle`: Time stream can be idle before considered dead (ms)
  - `pool.checkout`: Time to wait for connection from pool (ms)
  - `pool.idle`: Time connection can idle in pool before cleanup (ms)
  """
  @spec put_timeout(t(), keyword()) :: t()
  def put_timeout(config, opts) do
    timeouts = deep_merge_timeouts(config.timeouts, Map.new(opts))
    %{config | timeouts: timeouts}
  end

  # Helper to merge nested timeout configuration
  defp deep_merge_timeouts(base, updates) do
    # Normalize keyword lists to maps for nested structures
    normalized_updates = normalize_timeout_updates(updates)

    Map.merge(base, normalized_updates, fn
      _key, base_value, update_value when is_map(base_value) and is_map(update_value) ->
        Map.merge(base_value, update_value)

      _key, _base_value, update_value ->
        update_value
    end)
  end

  # Convert keyword lists to maps for nested timeout structures
  defp normalize_timeout_updates(updates) do
    Enum.reduce(updates, %{}, fn
      {key, value}, acc when key in [:stream, :pool] and is_list(value) ->
        Map.put(acc, key, Map.new(value))

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  @doc """
  Configures authentication settings.

  ## Examples

      # Bearer token
      config = Arbor.MCP.ClientConfig.new()
      |> Arbor.MCP.ClientConfig.put_auth(:bearer, token: "your-token")

      # Basic auth
      config = Arbor.MCP.ClientConfig.new()
      |> Arbor.MCP.ClientConfig.put_auth(:basic, username: "user", password: "pass")

      # Custom headers
      config = Arbor.MCP.ClientConfig.new()
      |> Arbor.MCP.ClientConfig.put_auth(:custom, headers: %{"X-API-Key" => "key"})
  """
  @spec put_auth(t(), auth_type(), keyword()) :: t()
  def put_auth(config, auth_type, opts \\ []) do
    auth_config = build_auth_config(auth_type, opts)
    %{config | auth: auth_config}
  end

  @doc """
  Configures connection pooling settings.

  ## Examples

      config = Arbor.MCP.ClientConfig.new()
      |> Arbor.MCP.ClientConfig.put_pool(
        enabled: true,
        size: 10,
        max_overflow: 5
      )
  """
  @spec put_pool(t(), keyword()) :: t()
  def put_pool(config, opts) do
    pool_config = Map.merge(config.pool, Map.new(opts))
    %{config | pool: pool_config}
  end

  @doc """
  Configures observability settings.

  ## Examples

      config = Arbor.MCP.ClientConfig.new()
      |> Arbor.MCP.ClientConfig.put_observability(
        logging: [enabled: true, level: :info],
        telemetry: [enabled: true, prefix: [:my_app, :mcp]]
      )
  """
  @spec put_observability(t(), keyword()) :: t()
  def put_observability(config, opts) do
    observability_config = deep_merge_observability(config.observability, opts)
    %{config | observability: observability_config}
  end

  @doc """
  Sets client information.

  ## Examples

      config = Arbor.MCP.ClientConfig.new()
      |> Arbor.MCP.ClientConfig.put_client_info(
        name: "MyApp MCP Client",
        version: "1.0.0"
      )
  """
  @spec put_client_info(t(), keyword()) :: t()
  def put_client_info(config, opts) do
    client_info = Map.merge(config.client_info, Map.new(opts))

    # Update user_agent if name or version changed
    client_info =
      if Map.has_key?(client_info, :name) or Map.has_key?(client_info, :version) do
        user_agent =
          "#{client_info.name}/#{client_info.version} Arbor.MCP/#{VersionInfo.version()}"

        Map.put(client_info, :user_agent, user_agent)
      else
        client_info
      end

    %{config | client_info: client_info}
  end

  @doc """
  Adds custom configuration options.

  ## Examples

      config = Arbor.MCP.ClientConfig.new()
      |> Arbor.MCP.ClientConfig.put_custom(:my_option, "value")
      |> Arbor.MCP.ClientConfig.put_custom(:another_option, %{key: "value"})
  """
  @spec put_custom(t(), atom(), any()) :: t()
  def put_custom(config, key, value) when is_atom(key) do
    custom_options = Map.put(config.custom_options, key, value)
    %{config | custom_options: custom_options}
  end

  @doc """
  Validates the configuration and returns errors if any.

  ## Examples

      case Arbor.MCP.ClientConfig.validate(config) do
        :ok -> {:ok, client} = Arbor.MCP.Client.connect(config)
        {:error, errors} -> handle_config_errors(errors)
      end
  """
  @spec validate(t()) :: :ok | {:error, [String.t()]}
  def validate(config) do
    errors = []

    errors = validate_transport(config.transport, errors)
    errors = validate_retry_policy(config.retry_policy, errors)
    errors = validate_timeouts(config.timeouts, errors)
    errors = validate_auth(config.auth, errors)
    errors = validate_pool(config.pool, errors)

    case errors do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  Converts the configuration to a keyword list suitable for client APIs.

  ## Examples

      config = Arbor.MCP.ClientConfig.new(:http, url: "http://localhost:8080")
      opts = Arbor.MCP.ClientConfig.to_client_opts(config)
      {:ok, client} = Arbor.MCP.Client.start_link(opts)
  """
  @spec to_client_opts(t()) :: keyword()
  def to_client_opts(config) do
    base_opts = [
      transport: config.transport.type,
      url: config.transport.url,
      command: config.transport.command,
      host: config.transport.host,
      port: config.transport.port,
      # Connection timeouts
      timeout: config.timeouts.connect,
      request_timeout: config.timeouts.request,
      total_timeout: config.timeouts.total,
      # Stream timeouts
      stream_handshake_timeout: config.timeouts.stream.handshake,
      stream_idle_timeout: config.timeouts.stream.idle,
      # Pool timeouts
      pool_checkout_timeout: config.timeouts.pool.checkout,
      pool_idle_timeout: config.timeouts.pool.idle,
      # Retry settings
      retry_attempts: config.retry_policy.max_attempts,
      retry_interval: config.retry_policy.base_interval
    ]

    base_opts
    |> add_auth_opts(config.auth)
    |> add_pool_opts(config.pool)
    |> add_observability_opts(config.observability)
    |> add_transport_opts(config.transport)
    |> add_custom_opts(config.custom_options)
    |> Enum.filter(fn {_k, v} -> not is_nil(v) end)
  end

  @doc """
  Gets the list of all transport configurations (primary + fallbacks).

  ## Examples

      transports = Arbor.MCP.ClientConfig.get_all_transports(config)
      # Try connecting to each transport in order
  """
  @spec get_all_transports(t()) :: [transport_config()]
  def get_all_transports(config) do
    [config.transport | config.fallback_transports]
  end

  # Private Implementation

  defp transport_type?(atom) do
    atom in [:http, :stdio, :beam]
  end

  defp apply_profile(config, profile) do
    case profile do
      :development -> apply_development_profile(config)
      :test -> apply_test_profile(config)
      :production -> apply_production_profile(config)
      :http -> apply_http_profile(config)
      :stdio -> apply_stdio_profile(config)
      :beam -> apply_beam_profile(config)
      _ -> config
    end
    |> Map.put(:profile, profile)
  end

  defp apply_development_profile(config) do
    config
    |> put_timeout(
      total: 60_000,
      connect: 5_000,
      request: 10_000,
      stream: [handshake: 10_000, idle: 30_000],
      pool: [checkout: 3_000, idle: 30_000]
    )
    |> put_retry_policy(enabled: true, max_attempts: 3, base_interval: 500, backoff_type: :linear)
    |> put_observability(
      logging: [enabled: true, level: :debug, include_metadata: true],
      telemetry: [enabled: true, include_system_metrics: true]
    )
    |> put_pool(enabled: false)
  end

  defp apply_test_profile(config) do
    config
    |> put_timeout(
      total: 15_000,
      connect: 1_000,
      request: 5_000,
      stream: [handshake: 3_000, idle: 10_000],
      pool: [checkout: 1_000, idle: 10_000]
    )
    |> put_retry_policy(enabled: false)
    |> put_observability(
      logging: [enabled: false],
      telemetry: [enabled: false],
      tracing: [enabled: false]
    )
    |> put_pool(enabled: false)
  end

  defp apply_production_profile(config) do
    config
    |> put_timeout(
      total: 600_000,
      connect: 10_000,
      request: 30_000,
      stream: [handshake: 20_000, idle: 300_000],
      pool: [checkout: 5_000, idle: 300_000]
    )
    |> put_retry_policy(
      enabled: true,
      max_attempts: 5,
      base_interval: 1000,
      max_interval: 30_000,
      backoff_type: :exponential,
      jitter: true
    )
    |> put_observability(
      logging: [enabled: true, level: :info, format: :json, include_request_id: true],
      telemetry: [enabled: true, include_system_metrics: false],
      tracing: [enabled: true]
    )
    |> put_pool(enabled: true, size: 10, max_overflow: 5)
  end

  defp apply_http_profile(config) do
    config
    |> put_transport(:http, url: "http://localhost:8080")
  end

  defp apply_stdio_profile(config) do
    config
    |> put_transport(:stdio, command: "mcp-server")
  end

  defp apply_beam_profile(config) do
    config
    |> put_transport(:beam)
  end

  defp apply_custom_options(config, opts) do
    Enum.reduce(opts, config, fn {key, value}, acc ->
      put_custom(acc, key, value)
    end)
  end

  # Default configurations

  defp default_transport_config do
    %{
      type: :http,
      url: nil,
      command: nil,
      host: "localhost",
      port: 8080,
      path: "/mcp/v1",
      ssl: false,
      headers: %{},
      options: []
    }
  end

  defp default_retry_policy do
    %{
      enabled: true,
      max_attempts: 3,
      base_interval: 1000,
      max_interval: 30_000,
      backoff_type: :exponential,
      jitter: false
    }
  end

  defp default_timeout_config do
    %{
      total: 300_000,
      connect: 5_000,
      request: 30_000,
      stream: %{
        # 15 seconds for SSE handshake
        handshake: 15_000,
        # 60 seconds for stream idle
        idle: 60_000
      },
      pool: %{
        # 5 seconds to get connection from pool
        checkout: 5_000,
        # 60 seconds for connection to idle in pool
        idle: 60_000
      }
    }
  end

  defp default_auth_config do
    %{
      type: :none,
      token: nil,
      username: nil,
      password: nil,
      headers: %{},
      refresh_token: nil,
      client_id: nil,
      client_secret: nil,
      custom_handler: nil
    }
  end

  defp default_pool_config do
    %{
      enabled: false,
      size: 5,
      max_overflow: 10,
      checkout_timeout: 5_000,
      idle_timeout: 60_000
    }
  end

  defp default_observability_config do
    %{
      logging: %{
        enabled: true,
        level: :info,
        format: :text,
        include_request_id: false,
        include_metadata: false
      },
      telemetry: %{
        enabled: false,
        prefix: [:arbor_mcp],
        include_system_metrics: false
      },
      tracing: %{
        enabled: false,
        sampler: :always_off,
        propagators: []
      }
    }
  end

  defp default_client_info do
    %{
      name: "Arbor.MCP Client",
      version: VersionInfo.version(),
      user_agent: "Arbor.MCP Client/#{VersionInfo.version()} Arbor.MCP/#{VersionInfo.version()}"
    }
  end

  # Configuration builders

  defp build_transport_config(transport_type, opts) do
    base_config = default_transport_config()
    custom_config = Map.new(opts)

    base_config
    |> Map.put(:type, transport_type)
    |> Map.merge(custom_config)
    |> normalize_transport_config(transport_type)
  end

  defp normalize_transport_config(config, :http) do
    config
    |> ensure_url_or_host_port()
  end

  defp normalize_transport_config(config, :stdio) do
    config
    |> ensure_command()
  end

  defp normalize_transport_config(config, _transport_type) do
    config
  end

  defp ensure_url_or_host_port(config) do
    if is_nil(config.url) do
      protocol = if config.ssl, do: "https", else: "http"
      url = "#{protocol}://#{config.host}:#{config.port}#{config.path}"
      Map.put(config, :url, url)
    else
      config
    end
  end

  defp ensure_command(config) do
    if is_nil(config.command) do
      Map.put(config, :command, "mcp-server")
    else
      config
    end
  end

  defp build_auth_config(auth_type, opts) do
    base_config = default_auth_config()
    custom_config = Map.new(opts)

    base_config
    |> Map.put(:type, auth_type)
    |> Map.merge(custom_config)
  end

  # Helper functions for conversion

  defp add_auth_opts(opts, %{type: :none}), do: opts

  defp add_auth_opts(opts, %{type: :bearer, token: token}) when not is_nil(token) do
    headers = [{"Authorization", "Bearer #{token}"}]
    Keyword.put(opts, :headers, headers)
  end

  defp add_auth_opts(opts, %{type: :basic, username: user, password: pass})
       when not is_nil(user) and not is_nil(pass) do
    auth = Base.encode64("#{user}:#{pass}")
    headers = [{"Authorization", "Basic #{auth}"}]
    Keyword.put(opts, :headers, headers)
  end

  defp add_auth_opts(opts, %{type: :custom, headers: headers}) when map_size(headers) > 0 do
    header_list = Enum.to_list(headers)
    Keyword.put(opts, :headers, header_list)
  end

  defp add_auth_opts(opts, _auth), do: opts

  defp add_pool_opts(opts, %{enabled: false}), do: opts

  defp add_pool_opts(opts, pool_config) do
    opts
    |> Keyword.put(:pool_size, pool_config.size)
    |> Keyword.put(:pool_max_overflow, pool_config.max_overflow)
    |> Keyword.put(:pool_checkout_timeout, pool_config.checkout_timeout)
  end

  defp add_observability_opts(opts, observability) do
    opts
    |> add_logging_opts(observability.logging)
    |> add_telemetry_opts(observability.telemetry)
  end

  defp add_logging_opts(opts, %{enabled: false}), do: opts

  defp add_logging_opts(opts, logging) do
    opts
    |> Keyword.put(:log_level, logging.level)
    |> Keyword.put(:log_format, logging.format)
  end

  defp add_telemetry_opts(opts, %{enabled: false}), do: opts

  defp add_telemetry_opts(opts, telemetry) do
    Keyword.put(opts, :telemetry_prefix, telemetry.prefix)
  end

  defp add_transport_opts(opts, transport) do
    # Merge transport headers with existing headers (like auth headers)
    existing_headers = Keyword.get(opts, :headers, [])
    transport_headers = Map.to_list(transport.headers)
    merged_headers = existing_headers ++ transport_headers

    # Forward transport-specific constructor options (for example :server for
    # BEAM), without replacing the profile's canonical timeouts/auth options.
    transport_opts =
      transport
      |> Map.drop([:type, :url, :command, :host, :port, :headers, :options, :ssl, :path])
      |> Map.to_list()
      |> then(&Keyword.merge(transport.options, &1))

    transport_opts
    |> Keyword.merge(opts)
    |> Keyword.put(:transport_options, transport.options)
    |> Keyword.put(:headers, merged_headers)
  end

  defp add_custom_opts(opts, custom_options) do
    Map.to_list(custom_options) ++ opts
  end

  # Validation functions

  defp validate_transport(%{type: type, url: url, command: command}, errors) do
    errors =
      if type == :http and is_nil(url),
        do: ["HTTP transport requires URL" | errors],
        else: errors

    errors =
      if type == :stdio and is_nil(command),
        do: ["Stdio transport requires command" | errors],
        else: errors

    errors
  end

  defp validate_retry_policy(%{max_attempts: attempts, base_interval: interval}, errors) do
    errors = if attempts < 1, do: ["Retry max_attempts must be positive" | errors], else: errors

    errors =
      if interval < 0, do: ["Retry base_interval must be non-negative" | errors], else: errors

    errors
  end

  defp validate_timeouts(%{connect: connect, request: request}, errors) do
    errors = if connect < 0, do: ["Connect timeout must be non-negative" | errors], else: errors
    errors = if request < 0, do: ["Request timeout must be non-negative" | errors], else: errors
    errors
  end

  defp validate_auth(%{type: :bearer, token: token}, errors) do
    if is_nil(token), do: ["Bearer auth requires token" | errors], else: errors
  end

  defp validate_auth(%{type: :basic, username: user, password: pass}, errors) do
    errors = if is_nil(user), do: ["Basic auth requires username" | errors], else: errors
    errors = if is_nil(pass), do: ["Basic auth requires password" | errors], else: errors
    errors
  end

  defp validate_auth(_auth, errors), do: errors

  defp validate_pool(%{size: size, max_overflow: overflow}, errors) do
    errors = if size < 1, do: ["Pool size must be positive" | errors], else: errors

    errors =
      if overflow < 0, do: ["Pool max_overflow must be non-negative" | errors], else: errors

    errors
  end

  # Deep merge for nested observability config
  defp deep_merge_observability(current, updates) do
    Enum.reduce(updates, current, fn {key, value}, acc ->
      case {Map.get(acc, key), value} do
        {existing, new_value} when is_map(existing) and is_list(new_value) ->
          Map.put(acc, key, Map.merge(existing, Map.new(new_value)))

        {_existing, new_value} ->
          Map.put(acc, key, new_value)
      end
    end)
  end
end
