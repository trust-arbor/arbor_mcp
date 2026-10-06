defmodule Arbor.MCP.Client do
  @moduledoc """
  Unified MCP client combining the best features of all implementations.

  This module provides a clean, consistent API for interacting with MCP servers
  while maintaining backward compatibility with existing code.

  ## Features

  - Simple connection with URL strings or transport specs
  - Automatic transport fallback via TransportManager
  - Automatic reconnection with exponential backoff after unexpected
    transport closure (see `start_link/1`)
  - Server notification delivery in both protocol eras: `listen/3` on MCP
    2026-07-28 peers and `subscribe_notifications/3` on legacy peers
  - Consistent return values with optional normalization
  - Convenience methods for common operations
  - Clean separation of concerns

  ## Examples

      # Connect with URL
      {:ok, client} = Arbor.MCP.Client.connect("http://localhost:8080/mcp")

      # Connect with transport spec
      {:ok, client} = Arbor.MCP.Client.start_link(
        transport: :stdio,
        command: "mcp-server"
      )

      # List and call tools
      {:ok, %{"tools" => tools}} = Arbor.MCP.Client.list_tools(client)
      {:ok, result} = Arbor.MCP.Client.call_tool(client, "weather", %{location: "NYC"})
  """

  alias Arbor.MCP.Error
  alias Arbor.MCP.Protocol.ErrorCodes

  use GenServer
  require Logger

  alias Arbor.MCP.Client.{
    ConnectionManager,
    ConnectionScope,
    Deadline,
    Diagnostics,
    EraCache,
    Lifetime,
    MRTR,
    NotificationListener,
    RequestHandler,
    Subscription
  }

  alias Arbor.MCP.Client.NotificationListener.Worker
  alias Arbor.MCP.Transport.HTTP.LegacySSE

  alias Arbor.MCP.Client.Operations.{Prompts, Resources, Tasks, Tools}

  alias Arbor.MCP.Internal.{
    Headers,
    Protocol,
    RequestParams,
    VersionInfo,
    VersionRegistry
  }

  alias Arbor.MCP.Reliability.Retry
  alias Arbor.MCP.Response
  alias Arbor.MCP.Server.Discover
  alias Arbor.MCP.Transport.{HTTP, ReliabilityWrapper, Stdio}
  alias Arbor.RPC.LogSummary

  # Reconnection defaults ported from the former state machine implementation:
  # exponential backoff starting at 1s, doubling per attempt, capped at 60s,
  # with up to 10 attempts before giving up.
  @default_max_reconnect_attempts 10
  @default_reconnect_backoff [initial: 1_000, max: 60_000, multiplier: 2]
  @default_max_mrtr_rounds 8

  # Client state
  defstruct [
    :transport_mod,
    :transport_state,
    :server_info,
    :transport_opts,
    :pending_requests,
    :pending_batches,
    :cancelled_requests,
    :receiver_task,
    :health_check_ref,
    :health_check_interval,
    # Request id of an in-flight health-check ping, or nil when none is
    # outstanding. Deliberately not kept in pending_requests: it has no
    # caller and must not surface via get_pending_requests/1.
    :health_check_id,
    :connection_status,
    :last_activity,
    :reconnect_attempts,
    :reconnect_enabled,
    :max_reconnect_attempts,
    :reconnect_backoff,
    :reconnect_timer,
    :manual_disconnect,
    :client_info,
    :server_capabilities,
    :initialized,
    :default_retry_policy,
    :protocol_version,
    :default_timeout,
    # Monitor refs of in-flight async POST tasks (Streamable HTTP transport),
    # mapped to the request id each task serves.
    async_post_tasks: %{},
    # Linked processes of a transport (or receiver) this client has since
    # dropped, and that were still alive when it did. Their exit signals are
    # expected and are ignored rather than read as a foreign link's exit.
    retired_links: MapSet.new(),
    # Preserve a known cleanup failure until a new connection succeeds.
    cleanup_result: :ok,
    # Memoized client handler: nil (not yet initialized), :none (no handler
    # configured) or {module, handler_state}. Initialized once; callback
    # returns update handler_state, so stateful client handlers work.
    client_handler: nil,
    # In-flight server-request handler tasks (sampling/elicitation/custom):
    # task pid => {monitor_ref, request_id, kind}. Handlers run off the
    # client loop so a slow sampling callback cannot block responses.
    server_request_tasks: %{},
    # In-flight MRTR input fulfillment tasks. Each task may perform several
    # input callbacks sequentially while the client loop remains responsive.
    mrtr_tasks: %{},
    # Modern long-lived subscription request id => Subscription process.
    subscriptions: %{},
    # Monitor ref => Subscription process. Monitors survive reconnects while
    # request ids are replaced.
    subscription_monitors: %{},
    # Ref-counted desired resource set and its currently committed immutable
    # modern subscription stream.
    resource_subscriptions: %{desired: %{}, active: nil, generation: 0},
    # Monitor ref => compatibility subscriber. Dead callers are removed from
    # the desired resource set so their references cannot retain a stream.
    resource_subscriber_monitors: %{},
    # Legacy-era notification listeners: listener id => %{ref, monitor}.
    # See Arbor.MCP.Client.NotificationListener.
    notification_listeners: %{},
    # Monitor ref => listener id, so a dead subscriber releases its listener.
    notification_listener_monitors: %{},
    # Worker that serializes legacy resources/subscribe traffic for the
    # listeners, started on the first registration, plus its monitor ref.
    notification_worker: nil,
    notification_worker_monitor: nil,
    # Bumped on every successful reconnect so a late resubscribe report from
    # an earlier connection is ignored.
    notification_listener_generation: 0
  ]

  @type t :: GenServer.server()
  @type connection_spec :: String.t() | {atom(), keyword()} | [{atom(), keyword()}]

  # Public API

  @doc """
  Starts a client process with the given options.

  ## Options

  - `:transport` - Transport type (`:stdio`, `:http`, `:sse`, `:beam`, etc.)
  - `:transports` - List of transports for fallback
  - `:name` - Optional GenServer name
  - `:handshake_timeout` - Maximum time in milliseconds for the `initialize`
    exchange during connection, sending the request (a synchronous HTTP POST
    included) and waiting for the server's response (default: 10_000).
    On expiry `start_link/1` fails with `{:error, :handshake_timeout}`.
  - `:protocol_mode` - Era policy: `:modern_only`, `:legacy_only`,
    `:prefer_modern`, or `:prefer_legacy`.
  - `:era_probe_timeout` - Dedicated timeout for the side-effect-free modern
    discovery probe exchange, send included (default: 2_000 milliseconds).
  - `:establish_timeout` - Upper bound in milliseconds (or `:infinity`) on
    establishing the connection as a whole: opening the transport, the probe,
    any legacy fallback, `initialize` and `notifications/initialized`, and
    connection retries under `:retry_policy`. Defaults to
    `:handshake_timeout` plus `:era_probe_timeout`. On expiry `start_link/1`
    fails with `{:error, :establish_timeout}`, and each reconnection attempt is
    bounded the same way. A failed attempt closes the transport it opened, so
    a spawned stdio server does not outlive it; ending an HTTP session it
    opened may take up to one more second past the deadline.
  - `:era_cache_legacy_ttl` - How long a successful legacy observation is
    reused before probing for an upgrade again (default: 300_000 milliseconds).
  - `:reset_era_cache` - Clear the observation for this exact transport,
    endpoint, and auth configuration before connecting (default: `false`).
  - `:trace_context` - Optional W3C `traceparent`, `tracestate`, and allowlisted
    `baggage` values to attach to modern requests.
  - `:health_check_interval` - Interval in milliseconds between idle health
    check pings (default: 30_000). Set to `nil` or `0` to disable.
  - `:reliability` - Reliability features configuration (optional)
  - `:retry_policy` - Default retry policy for all client operations (optional)
  - `:reconnect` - Automatically reconnect when the transport closes
    unexpectedly (default: `true`)
  - `:max_reconnect_attempts` - Consecutive failed reconnection attempts
    before giving up (default: 10)
  - `:reconnect_backoff` - Reconnection backoff policy (keyword list):
    - `:initial` - Delay before the first attempt in ms (default: 1000)
    - `:max` - Maximum delay between attempts in ms (default: 60_000)
    - `:multiplier` - Exponential backoff multiplier (default: 2)

  ## Automatic Reconnection

  When the transport closes unexpectedly while the client is connected, all
  pending requests fail with a connection error and the client transitions to
  `:reconnecting`. It then re-establishes the connection (including the MCP
  handshake) with exponential backoff and jitter. After
  `:max_reconnect_attempts` consecutive failures the client gives up and
  settles in `:disconnected`. Requests made while reconnecting return
  `{:error, :not_connected}`.

  Explicit `disconnect/1` or `stop/2` calls never trigger reconnection.
  Passing `reconnect: false` disables the behavior entirely.

  ## Health Checks

  While connected and idle, the client sends a protocol `ping` every
  `:health_check_interval` milliseconds. If a ping is still unanswered one
  full interval later, the transport is treated as closed: pending requests
  fail and the reconnection path takes over. Health checks are skipped while
  requests are in flight, since those already prove the connection is alive.

  The reconnection lifecycle emits telemetry:

  - `[:arbor_mcp, :client, :reconnect, :attempt]` - measurements
    `%{attempt: n, delay_ms: ms}`, emitted when an attempt is scheduled
  - `[:arbor_mcp, :client, :reconnect, :success]` - reconnected and re-initialized
  - `[:arbor_mcp, :client, :reconnect, :error]` - a single attempt failed
  - `[:arbor_mcp, :client, :reconnect, :timeout]` - gave up after the final attempt

  ## Reliability Options

  The `:reliability` option accepts a keyword list with the following options:

  - `:circuit_breaker` - Circuit breaker configuration or `false` to disable
    - `:failure_threshold` - Number of failures before opening (default: 5)
    - `:success_threshold` - Number of successes to close half-open circuit (default: 3)
    - `:reset_timeout` - Time before transitioning from open to half-open (default: 30_000)
    - `:timeout` - Operation timeout in milliseconds (default: 5_000)
  - `:health_check` - Health check configuration or `false` to disable
    - `:check_interval` - Interval between health checks (default: 60_000)
    - `:failure_threshold` - Health check failures before marking unhealthy (default: 3)
    - `:recovery_threshold` - Health check successes before marking healthy (default: 2)

  ## Reliability Examples

      # Client with circuit breaker protection
      {:ok, client} = Arbor.MCP.Client.start_link(
        transport: :stdio,
        command: "my-server",
        reliability: [
          circuit_breaker: [
            failure_threshold: 3,
            reset_timeout: 10_000
          ]
        ]
      )

      # Client with both circuit breaker and health monitoring
      {:ok, client} = Arbor.MCP.Client.start_link(
        transport: :http,
        url: "http://localhost:8080/mcp",
        reliability: [
          circuit_breaker: [failure_threshold: 5],
          health_check: [check_interval: 30_000]
        ]
      )

  ## Retry Policy Options

  The `:retry_policy` option accepts a keyword list with the following options:

  - `:max_attempts` - Maximum number of retry attempts (default: 3)
  - `:initial_delay` - Initial delay between retries in milliseconds (default: 200)
  - `:max_delay` - Maximum delay between retries in milliseconds (default: 5000)
  - `:backoff_factor` - Exponential backoff multiplier (default: 2)
  - `:jitter` - Add random jitter to prevent thundering herd (default: true)

  Modern HTTP response-stream recovery is deliberately separate from this
  generic policy because a broken response has ambiguous delivery semantics.
  Operations accept these options:

  - `:http_stream_retry` - `:at_least_once` (default) reissues one broken
    request stream with a new JSON-RPC id. `:safe_only` reissues only built-in
    read operations or operations explicitly marked `retry_safe: true`, and
    otherwise returns a transport error whose reason is `:outcome_unknown`.
  - `:http_stream_retry_delay` - Delay before the one reissue (default: 200ms),
    bounded by the operation's original deadline.
  - `:retry_safe` - Caller-owned safety attestation. Tool annotations such as
    `readOnlyHint` are advisory and are never used as the security decision.

  `:safe_only` is intentionally non-conforming and is rejected when the client
  is started with `conformance_mode: true`. JSON-RPC ids do not deduplicate
  application side effects; tool authors should use an application
  idempotency key and server-side deduplication where reissue is possible.

  ## Retry Policy Examples

      # Client with default retry policy for all operations
      {:ok, client} = Arbor.MCP.Client.start_link(
        transport: :stdio,
        command: "my-server",
        retry_policy: [
          max_attempts: 5,
          initial_delay: 200
        ]
      )

      # Individual operation with custom retry policy
      {:ok, tools} = Arbor.MCP.Client.list_tools(client,
        retry_policy: [max_attempts: 2, backoff_factor: 1.5])

      # Operation with no retries (override client default)
      {:ok, result} = Arbor.MCP.Client.call_tool(client, "tool", %{},
        retry_policy: false)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name_opts, start_opts} = Keyword.split(opts, [:name])

    start_opts = Keyword.put(start_opts, :_lifetime_parent, self())

    normalize_start_result(
      GenServer.start_link(__MODULE__, Diagnostics.argument(__MODULE__, start_opts), name_opts)
    )
  end

  def child_spec(opts), do: Diagnostics.child_spec(super(opts))

  defp normalize_start_result(result) do
    case result do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} when is_map(reason) ->
        {:error, reason}

      {:error, {:shutdown, reason}} when is_map(reason) ->
        {:error, reason}

      {:error, {:shutdown, {:transport_connect_failed, details}}} ->
        {:error, {:connection_error, details}}

      {:error, {:shutdown, {:initialize_error, details}}} ->
        {:error, {:initialize_error, details}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Connects to an MCP server using a URL or connection spec.

  ## Examples

      # URL string
      {:ok, client} = Arbor.MCP.Client.connect("http://localhost:8080/mcp")

      # Transport spec
      {:ok, client} = Arbor.MCP.Client.connect({:stdio, command: "mcp-server"})

      # Multiple transports with fallback
      {:ok, client} = Arbor.MCP.Client.connect([
        "http://localhost:8080/mcp",
        "stdio://mcp-server"
      ])

  Returns `{:error, {:invalid_transport_config, reason}}` when the connection
  spec cannot be normalized into a valid transport configuration.
  """
  @spec connect(connection_spec(), keyword()) :: {:ok, t()} | {:error, any()}
  def connect(connection_spec, opts \\ []) do
    transport_opts = do_parse_connection_spec(connection_spec)
    start_link(Keyword.merge(transport_opts, opts))
  catch
    :throw, {:transport_config_error, reason} ->
      {:error, {:invalid_transport_config, reason}}
  end

  @doc """
  Opens a new client for the duration of `callback`, which runs in the calling process.

  Returns `{:ok, value}` after confirmed cleanup, or
  `{:error, {:cleanup_failed, reason, value}}` when cleanup cannot be confirmed.
  Connection errors return before the callback runs. Exceptions, throws and exits
  from the callback are raised again after bounded cleanup with their original stack.

  The client is linked to a private guardian, which monitors the calling process.
  Abrupt caller exit also closes the owned client. Existing servers and listeners
  passed in a connection spec remain borrowed. This helper accepts connection
  specs, rather than existing client PIDs.

  `:establish_timeout` (default 12_000) and `:cleanup_timeout` (default 1_000)
  are positive finite milliseconds. Establishment uses one cutoff across the
  native constructor and protocol handshake. Cleanup uses a separate single
  cutoff. `:max_scope_workers` bounds owned reverse-request workers (default 256).
  Helper names must be local atoms. A stdio child requires a typed cleanup receipt;
  a legacy HTTP session DELETE remains explicitly unconfirmed even after local
  resources close. Arbitrary unregistered custom transport effects are outside
  the owned-process contract.

      Client.with_connection({:test, server: runtime}, fn client ->
        Client.list_tools(client)
      end)
  """
  @spec with_connection(connection_spec(), (t() -> value)) ::
          {:ok, value} | {:error, term()}
        when value: term()
  def with_connection(spec, callback), do: with_connection(spec, [], callback)

  @spec with_connection(connection_spec(), keyword(), (t() -> value)) ::
          {:ok, value} | {:error, term()}
        when value: term()
  def with_connection(spec, opts, callback), do: ConnectionScope.run(spec, opts, callback)

  @doc false
  def connection_options(spec, opts) when not is_pid(spec) do
    {:ok, Keyword.merge(do_parse_connection_spec(spec), opts)}
  rescue
    error in [ArgumentError, FunctionClauseError] ->
      {:error, {:invalid_transport_config, error.__struct__}}
  catch
    :throw, {:transport_config_error, reason} ->
      {:error, {:invalid_transport_config, reason}}
  end

  def connection_options(_spec, _opts), do: {:error, :existing_client_not_owned}

  @doc false
  def start_scoped(opts, scope, deadline) do
    {name_opts, start_opts} = Keyword.split(opts, [:name])
    start_opts = Keyword.put(start_opts, :_connection_scope, scope)

    normalize_start_result(
      GenServer.start_link(
        __MODULE__,
        Diagnostics.argument(__MODULE__, start_opts),
        Keyword.put(name_opts, :timeout, Deadline.remaining(deadline))
      )
    )
  end

  @doc """
  Lists available tools from the server.

  ## Options

  - `:timeout` - Request timeout (default: 5000)
  - `:format` - Return format (:map or :struct, default: :struct)
  """
  @spec list_tools(t(), keyword() | timeout()) ::
          {:ok, %{String.t() => [map()]}} | {:error, any()}
  def list_tools(client, timeout_or_opts \\ [])

  def list_tools(client, timeout) when is_integer(timeout) do
    list_tools(client, timeout: timeout)
  end

  def list_tools(client, opts) when is_list(opts) do
    {params, opts} = RequestParams.take_cursor(opts)
    make_request(client, "tools/list", params, opts, 5_000)
  end

  @doc """
  Convenience alias for list_tools/2.
  """
  @spec tools(t(), keyword()) :: {:ok, %{String.t() => [map()]}} | {:error, any()}
  def tools(client, opts \\ []), do: Tools.tools(client, opts)

  @doc """
  Calls a tool with the given arguments.

  ## Options

  - `:timeout` - Request timeout (default: 30000)
  - `:format` - Return format (:map or :struct, default: :struct)
  """
  @spec call_tool(t(), String.t(), map(), keyword() | timeout()) ::
          {:ok, any()} | {:error, any()}
  def call_tool(client, tool_name, arguments, timeout_or_opts \\ 30_000)

  def call_tool(client, tool_name, arguments, timeout) when is_integer(timeout) do
    call_tool(client, tool_name, arguments, timeout: timeout)
  end

  def call_tool(client, tool_name, arguments, opts) when is_list(opts) do
    Tools.call_tool(client, tool_name, arguments, opts)
  end

  @doc """
  Sends a batch of requests to the server.

  This function allows sending multiple requests in a single batch, which can
  be more efficient than sending them individually. The server processes the
  requests and returns a batch of responses.

  ## Parameters

  - `client` - Client process reference
  - `requests` - A list of `{method, params}` tuples for each request.
  - `timeout` - Timeout for the entire batch operation (default: 30_000).

  ## Returns

  - `{:ok, results}` - On success, where `results` is a list of `{:ok, result}`
    or `{:error, error}` tuples, in the same order as the original requests.
  - `{:error, reason}` - If the batch request fails (e.g., timeout).

  ## Example

      requests = [
        {"tools/list", %{}},
        {"prompts/list", %{}}
      ]
      {:ok, [tools_result, prompts_result]} = Arbor.MCP.Client.batch_request(client, requests)
  """
  @spec batch_request(t(), [{String.t(), map()}], timeout()) ::
          {:ok, [any()]} | {:error, any()}
  def batch_request(client, requests, timeout \\ 30_000) do
    meta = %{deadline: Deadline.after_ms(timeout), timeout: timeout}
    GenServer.call(client, {:batch_request, requests, meta}, timeout)
  end

  @doc """
  Convenience alias for batch_request/3.

  Sends a batch of JSON-RPC requests. Available in protocol version 2025-03-26 only.
  """
  @spec send_batch(t(), [map()], timeout()) :: {:ok, [any()]} | {:error, any()}
  def send_batch(client, requests, timeout \\ 30_000) do
    batch_request(client, requests, timeout)
  end

  @doc """
  Convenience alias for call_tool/4.
  """
  @spec call(t(), String.t(), map(), keyword()) :: {:ok, any()} | {:error, any()}
  def call(client, tool_name, args \\ %{}, opts \\ []) do
    call_tool(client, tool_name, args, opts)
  end

  @doc """
  Finds a tool by name or pattern.

  ## Options

  - `:fuzzy` - Enable fuzzy matching (default: false)
  - `:timeout` - Request timeout (default: 5000)
  """
  @spec find_tool(t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, :not_found} | {:error, any()}
  def find_tool(client, name_or_pattern \\ nil, opts \\ []) do
    Tools.find_tool(client, name_or_pattern, opts)
  end

  @doc """
  Lists available resources.
  """
  @spec list_resources(t(), keyword() | timeout()) ::
          {:ok, %{String.t() => [map()]}} | {:error, any()}
  def list_resources(client, timeout_or_opts \\ [])

  def list_resources(client, timeout) when is_integer(timeout) do
    list_resources(client, timeout: timeout)
  end

  def list_resources(client, opts) when is_list(opts) do
    {params, opts} = RequestParams.take_cursor(opts)
    make_request(client, "resources/list", params, opts, 5_000)
  end

  @doc """
  Lists available roots.

  Sends a `roots/list` request to the server to retrieve the list of
  available root URIs.

  MCP Roots is deprecated as of 2026-07-28 and available in
  Arbor.MCP 2.x for pinned legacy protocol revisions.
  New implementations should pass directories or files via tool parameters,
  resource URIs, or server configuration.
  """
  @spec list_roots(t(), keyword() | timeout()) ::
          {:ok, %{String.t() => [map()]}} | {:error, any()}
  def list_roots(client, timeout_or_opts \\ [])

  def list_roots(client, timeout) when is_integer(timeout) do
    list_roots(client, timeout: timeout)
  end

  def list_roots(client, opts) when is_list(opts) do
    make_request(client, "roots/list", %{}, opts, 5_000)
  end

  @doc """
  Lists available resource templates.

  Sends a `resources/templates/list` request to the server to retrieve the list of
  available resource templates.
  """
  @spec list_resource_templates(t(), keyword() | timeout()) ::
          {:ok, %{String.t() => [map()]}} | {:error, any()}
  def list_resource_templates(client, timeout_or_opts \\ [])

  def list_resource_templates(client, timeout) when is_integer(timeout) do
    list_resource_templates(client, timeout: timeout)
  end

  def list_resource_templates(client, opts) when is_list(opts) do
    {params, opts} = RequestParams.take_cursor(opts)
    make_request(client, "resources/templates/list", params, opts, 5_000)
  end

  @doc """
  Reads a resource by URI.
  """
  @spec read_resource(t(), String.t(), keyword() | timeout()) :: {:ok, any()} | {:error, any()}
  def read_resource(client, uri, timeout_or_opts \\ [])

  def read_resource(client, uri, timeout) when is_integer(timeout) do
    read_resource(client, uri, timeout: timeout)
  end

  def read_resource(client, uri, opts) when is_list(opts) do
    Resources.read_resource(client, uri, opts)
  end

  @doc """
  Subscribes to notifications for a resource.

  Sends a `resources/subscribe` request to receive notifications when the
  specified resource changes. The server will send `notifications/resources/updated`
  messages when the subscribed resource is modified.

  ## Parameters

  - `client` - Client process reference
  - `uri` - Resource URI to subscribe to (e.g., "file:///path/to/file")

  ## Options

  - `:timeout` - Request timeout (default: 5000)
  - `:format` - Return format (:map or :struct, default: :struct)

  ## Returns

  - `{:ok, result}` - Subscription successful
  - `{:error, error}` - Subscription failed with error details

  ## Examples

      {:ok, _result} = Arbor.MCP.Client.subscribe_resource(client, "file:///config.json")
  """
  @spec subscribe_resource(t(), String.t(), keyword()) ::
          {:ok, map() | Subscription.Ref.t()} | {:error, any()}
  def subscribe_resource(client, uri, opts \\ []) do
    Resources.subscribe_resource(client, uri, opts)
  end

  @doc """
  Opens a modern immutable notification subscription and waits for the
  server's acknowledgment.

  The Tasks extension adds a `"taskIds"` filter whose values receive full
  `notifications/tasks` states. The client must declare
  `io.modelcontextprotocol/tasks` in its configured capabilities.
  """
  @spec listen(t(), map(), keyword()) :: {:ok, Subscription.Ref.t()} | {:error, term()}
  def listen(client, notification_filter, opts \\ []) do
    Subscription.open(client, notification_filter, opts)
  end

  @doc """
  Registers a listener for legacy-era server notifications.

  MCP peers before 2026-07-28 deliver `notifications/tools/list_changed`,
  `notifications/prompts/list_changed`, `notifications/resources/list_changed`,
  and `notifications/resources/updated` on the connection with no correlating
  request. This function registers a local filter for those notifications and
  delivers each matching one to the subscriber process as
  `{:ex_mcp_notification, listener, method, params}`.

  This is the legacy counterpart of `listen/3`. On a modern peer it returns
  `{:error, :use_listen}`. `Arbor.MCP.Client.NotificationListener` documents the
  filter, the lifecycle, and every message a subscriber can receive.

  ## Filter

  The same keys as `listen/3`, minus `"taskIds"`:

      %{
        "toolsListChanged" => true,
        "promptsListChanged" => true,
        "resourcesListChanged" => true,
        "resourceSubscriptions" => ["file:///config.json"]
      }

  Every URI in `"resourceSubscriptions"` is subscribed on the server with
  `resources/subscribe` once, shared across listeners, and unsubscribed when
  the last listener naming it is removed. The requested filter is
  authoritative: notifications outside it are never delivered.

  ## Options

  - `:subscriber` - process that receives the messages (default: the caller).
    The client monitors it and removes the listener when it exits.
  - `:timeout` - timeout for each `resources/subscribe` request (default: 5000)

  ## Returns

  - `{:ok, listener}` - an `Arbor.MCP.Client.NotificationListener.Ref`
  - `{:error, :use_listen}` - the peer is a modern (MCP 2026-07-28) server
  - `{:error, :not_connected}` - the client is not ready
  - `{:error, :subscriber_not_alive}` - the subscriber process is not alive,
    or exited before its resource subscriptions were made
  - `{:error, {:subscribe_failed, uri, reason}}` - a `resources/subscribe`
    request failed; the registration and any earlier subscription of this
    call are rolled back
  - `{:error, reason}` - the filter is invalid, empty, or names `"taskIds"`

  ## Examples

      {:ok, listener} =
        Arbor.MCP.Client.subscribe_notifications(client, %{
          "toolsListChanged" => true,
          "resourceSubscriptions" => ["file:///config.json"]
        })

      receive do
        {:ex_mcp_notification, ^listener, "notifications/tools/list_changed", _params} ->
          {:ok, tools} = Arbor.MCP.Client.list_tools(client)

        {:ex_mcp_notification, ^listener, "notifications/resources/updated", %{"uri" => uri}} ->
          {:ok, content} = Arbor.MCP.Client.read_resource(client, uri)
      end

      :ok = Arbor.MCP.Client.unsubscribe_notifications(listener)
  """
  @spec subscribe_notifications(t(), map(), keyword()) ::
          {:ok, NotificationListener.Ref.t()} | {:error, term()}
  def subscribe_notifications(client, notification_filter, opts \\ []) do
    NotificationListener.subscribe(client, notification_filter, opts)
  end

  @doc """
  Removes a listener registered with `subscribe_notifications/3`.

  Any resource URI no longer named by another listener is unsubscribed on the
  server. Returns `{:error, :not_found}` when the listener is already gone.

  ## Options

  - `:timeout` - timeout for each `resources/unsubscribe` request (default: 5000)
  """
  @spec unsubscribe_notifications(NotificationListener.Ref.t(), keyword()) ::
          :ok | {:error, :not_found}
  def unsubscribe_notifications(%NotificationListener.Ref{} = listener, opts \\ []) do
    NotificationListener.unsubscribe(listener, opts)
  end

  @doc "Reads the current full state of a task."
  @spec get_task(t(), String.t(), keyword()) :: {:ok, map()} | {:error, any()}
  def get_task(client, task_id, opts \\ []), do: Tasks.get(client, task_id, opts)

  @doc "Submits responses to a modern task's outstanding input requests."
  @spec update_task(t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, any()}
  def update_task(client, task_id, input_responses, opts \\ []) do
    Tasks.update(client, task_id, input_responses, opts)
  end

  @doc "Requests cooperative cancellation of a task."
  @spec cancel_task(t(), String.t(), keyword()) :: {:ok, map()} | {:error, any()}
  def cancel_task(client, task_id, opts \\ []), do: Tasks.cancel(client, task_id, opts)

  @doc """
  Unsubscribes from notifications for a resource.

  Sends a `resources/unsubscribe` request to stop receiving notifications
  for the specified resource.

  ## Parameters

  - `client` - Client process reference
  - `uri` - Resource URI to unsubscribe from

  ## Options

  - `:timeout` - Request timeout (default: 5000)
  - `:format` - Return format (:map or :struct, default: :struct)

  ## Returns

  - `{:ok, result}` - Unsubscription successful
  - `{:error, error}` - Unsubscription failed with error details

  ## Examples

      {:ok, _result} = Arbor.MCP.Client.unsubscribe_resource(client, "file:///config.json")
  """
  @spec unsubscribe_resource(t(), String.t(), keyword()) :: {:ok, map()} | {:error, any()}
  def unsubscribe_resource(client, uri, opts \\ []) do
    Resources.unsubscribe_resource(client, uri, opts)
  end

  @doc """
  Lists available prompts.
  """
  @spec list_prompts(t(), keyword() | timeout()) ::
          {:ok, %{String.t() => [map()]}} | {:error, any()}
  def list_prompts(client, timeout_or_opts \\ [])

  def list_prompts(client, timeout) when is_integer(timeout) do
    list_prompts(client, timeout: timeout)
  end

  def list_prompts(client, opts) when is_list(opts) do
    Prompts.list_prompts(client, opts)
  end

  @doc """
  Gets a prompt with the given arguments.
  """
  @spec get_prompt(t(), String.t(), map(), keyword() | timeout()) ::
          {:ok, any()} | {:error, any()}
  def get_prompt(client, prompt_name, arguments \\ %{}, timeout_or_opts \\ [])

  def get_prompt(client, prompt_name, arguments, timeout) when is_integer(timeout) do
    get_prompt(client, prompt_name, arguments, timeout: timeout)
  end

  def get_prompt(client, prompt_name, arguments, opts) when is_list(opts) do
    Prompts.get_prompt(client, prompt_name, arguments, opts)
  end

  @doc """
  Gets the client status.
  """
  @spec get_status(t()) :: {:ok, map()}
  def get_status(client) do
    GenServer.call(client, :get_status)
  end

  @doc """
  Gets the client status with a caller-supplied deadline.

  `timeout` accepts a non-negative millisecond value or `:infinity`. A delayed
  client returns `{:error, :timeout}`. Invalid options return
  `{:error, :invalid_timeout}`. `get_status/1` keeps its existing behavior.
  """
  @spec get_status(t(), keyword()) :: {:ok, map()} | {:error, :timeout | :invalid_timeout}
  def get_status(client, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.get(opts, :timeout, 5_000) do
        timeout when (is_integer(timeout) and timeout >= 0) or timeout == :infinity ->
          try do
            GenServer.call(client, :get_status, timeout)
          catch
            :exit, {:timeout, _details} -> {:error, :timeout}
          end

        _invalid ->
          {:error, :invalid_timeout}
      end
    else
      {:error, :invalid_timeout}
    end
  end

  def get_status(_client, _opts), do: {:error, :invalid_timeout}

  @doc """
  Gets the list of pending request IDs.

  Returns a list of request IDs for requests that are currently in progress.
  This can be used with `send_cancelled/3` to cancel specific requests.

  ## Examples

      {:ok, client} = Arbor.MCP.Client.connect("http://localhost:8080/mcp")

      # Start a long-running request
      task = Task.async(fn ->
        Arbor.MCP.Client.call_tool(client, "slow_tool", %{})
      end)

      # Get pending requests
      pending = Arbor.MCP.Client.get_pending_requests(client)
      # => ["req_123", "req_456"]

      # Cancel a specific request
      Arbor.MCP.Client.send_cancelled(client, "req_123", "User cancelled")
  """
  @spec get_pending_requests(t()) :: [Arbor.MCP.Types.request_id()]
  def get_pending_requests(client) do
    GenServer.call(client, :get_pending_requests)
  end

  @doc """
  Gets server information.
  """
  @spec server_info(t()) :: {:ok, map()} | {:error, any()}
  def server_info(client) do
    case get_status(client) do
      {:ok, %{server_info: info}} -> {:ok, info}
      _ -> {:error, :not_connected}
    end
  end

  @doc """
  Gets server capabilities.
  """
  @spec server_capabilities(t()) :: {:ok, map()} | {:error, any()}
  def server_capabilities(client) do
    case get_status(client) do
      {:ok, %{server_capabilities: caps}} -> {:ok, caps}
      _ -> {:error, :not_connected}
    end
  end

  @doc """
  Gets the negotiated protocol version with the server.
  """
  @spec negotiated_version(t()) :: {:ok, String.t() | nil} | {:error, any()}
  def negotiated_version(client) do
    case get_status(client) do
      {:ok, %{protocol_version: version}} -> {:ok, version}
      _ -> {:error, :not_connected}
    end
  end

  @doc """
  Discovers a modern MCP server's versions, capabilities, and identity.

  A successful discovery also updates the client's protocol version,
  `server_info`, and `server_capabilities` state. Automatic discovery during
  connection establishment is handled separately by the era probe.
  """
  @spec discover(t(), keyword()) :: {:ok, map()} | {:error, any()}
  def discover(client, opts \\ []) do
    request_opts = Keyword.put(opts, :format, :map)

    with {:ok, result} <- make_request(client, "server/discover", %{}, request_opts, 5_000),
         :ok <- GenServer.call(client, {:apply_discover_result, result}) do
      {:ok, result}
    end
  end

  @doc """
  Clears all remembered protocol-era observations.

  This is an operator action intended for configuration changes or recovery
  from a previously pinned modern endpoint. To clear only the identity used by
  one new connection, pass `reset_era_cache: true` to `start_link/1`.
  """
  @spec clear_era_observations() :: :ok
  def clear_era_observations, do: EraCache.clear()

  @doc """
  Pings the server.
  """
  @spec ping(t(), keyword() | integer()) :: {:ok, map()} | {:error, any()}
  def ping(client, opts_or_timeout \\ []) do
    # Handle both ping(client, timeout) and ping(client, opts) patterns
    timeout =
      case opts_or_timeout do
        timeout when is_integer(timeout) -> timeout
        opts when is_list(opts) -> Keyword.get(opts, :timeout, 5_000)
      end

    opts = if is_list(opts_or_timeout), do: opts_or_timeout, else: []

    case negotiated_version(client) do
      {:ok, version} when is_binary(version) ->
        if VersionRegistry.modern?(version) do
          discover(client, Keyword.put(opts, :timeout, timeout))
        else
          make_request(client, "ping", %{}, opts, timeout)
        end

      {:ok, nil} ->
        # Older custom initialize handlers may omit protocolVersion. Preserve
        # the 1.x behavior by treating that connected shape as legacy.
        make_request(client, "ping", %{}, opts, timeout)

      _other ->
        {:error, :not_connected}
    end
  end

  @doc """
  Sends a notification to the server.

  Notifications are fire-and-forget messages that don't expect a response.

  ## Parameters

  - `client` - Client process reference
  - `method` - The method name to notify
  - `params` - Parameters for the notification (map)

  ## Returns

  - `:ok` - Notification sent

  ## Examples

      :ok = Arbor.MCP.Client.notify(client, "resource_updated", %{"uri" => "file://test.txt"})
  """
  @spec notify(t(), String.t(), map()) :: :ok
  def notify(client, method, params \\ %{}) do
    GenServer.cast(client, {:notification, method, params})
  end

  @doc """
  Sends a cancellation notification for a pending request.

  For modern streamable HTTP, this closes only the pending request's POST
  response stream, which is the protocol-defined cancellation signal. Other
  transports send `notifications/cancelled`. The server MAY stop processing
  the request if it hasn't completed yet.

  ## Parameters

  - `client` - Client process reference
  - `request_id` - The ID of the request to cancel
  - `reason` - Optional human-readable reason for cancellation

  ## Returns

  - `:ok` - Cancellation notification sent
  - `{:error, :cannot_cancel_initialize}` - Cannot cancel initialize request

  ## Examples

      :ok = Arbor.MCP.Client.send_cancelled(client, "req_123", "User cancelled")
      :ok = Arbor.MCP.Client.send_cancelled(client, 12345, nil)
  """
  @spec send_cancelled(t(), Arbor.MCP.Types.request_id(), String.t() | nil) ::
          :ok | {:error, :cannot_cancel_initialize}
  def send_cancelled(client, request_id, reason \\ nil) do
    case Protocol.encode_cancelled(request_id, reason) do
      {:ok, notification} ->
        # Extract method and params from the notification
        %{"method" => method, "params" => params} = notification
        GenServer.call(client, {:send_cancelled, request_id, method, params})

      {:error, :cannot_cancel_initialize} = error ->
        error
    end
  end

  @doc """
  Disconnects the client gracefully, cleaning up all resources.

  This function performs a clean shutdown by:
  - Closing the transport connection
  - Cancelling health checks
  - Stopping the receiver task
  - Replying to any pending requests with an error

  Returns `{:error, reason}` if the transport reports a cleanup failure. The
  client still becomes disconnected and settles its pending requests. Repeated
  disconnect calls preserve that failure until a new connection succeeds.

  ## Examples

      {:ok, client} = Arbor.MCP.Client.connect("http://localhost:8080/mcp")
      :ok = Arbor.MCP.Client.disconnect(client)
  """
  @spec disconnect(t()) :: :ok | {:error, term()}
  def disconnect(client) do
    deadline = Deadline.after_ms(Lifetime.client_cleanup_ms(client))
    Lifetime.request_cleanup(client, deadline)
    GenServer.call(client, {:ordinary_disconnect, deadline}, Deadline.remaining(deadline))
  catch
    :exit, {:timeout, _call} -> {:error, :client_cleanup_timeout}
  end

  @doc """
  Stops the client.
  """
  @spec stop(t(), term()) :: :ok | {:error, term()}
  def stop(client, reason \\ :normal) do
    deadline = Deadline.after_ms(Lifetime.client_cleanup_ms(client))
    Lifetime.request_cleanup(client, deadline)
    GenServer.call(client, {:ordinary_stop, reason, deadline}, Deadline.remaining(deadline))
  catch
    :exit, {:timeout, _call} -> {:error, :client_cleanup_timeout}
    :exit, {:noproc, _call} -> {:error, :client_not_alive}
  end

  @doc """
  Says whether a failed request can have reached the server.

  Takes the error a request function returned (`{:error, reason}` or the
  bare `reason`) and returns:

    * `:not_sent` - Arbor.MCP knows the request never left the client: the client
      was not connected, the request failed validation, the caller's deadline
      passed or the caller exited before it went out, or the transport
      refused it before writing anything (the connection could not be opened,
      the address could not be resolved or was not permitted, the request was
      too large, a security policy blocked it).
    * `:unknown` - the request was, or may have been, delivered, and whether
      the server acted on it is not known. This covers the caller's own
      timeout, a connection that failed after sending, a broken response
      stream, and any error the server answered with. A JSON-RPC error
      response proves delivery but not that nothing ran: a server may report
      invalid params after its tool has acted.

  Only `:not_sent` makes repeating the request safe without knowing more.
  Deciding whether to retry, and telling a server's refusal apart from a
  failure after it acted, stays with the caller.

      case Arbor.MCP.Client.call_tool(client, "charge", args, timeout: 5_000) do
        {:ok, result} -> {:ok, result}
        {:error, reason} = error ->
          if Arbor.MCP.Client.delivery_outcome(reason) == :not_sent,
            do: retry(),
            else: error
      end
  """
  @spec delivery_outcome(term()) :: :not_sent | :unknown
  def delivery_outcome({:error, reason}), do: delivery_outcome(reason)
  def delivery_outcome(:not_connected), do: :not_sent
  def delivery_outcome(%Error.ValidationError{}), do: :not_sent
  def delivery_outcome(%{type: :invalid_request_meta}), do: :not_sent
  def delivery_outcome(%Error.TransportError{reason: :not_sent}), do: :not_sent
  def delivery_outcome(%Error.TransportError{reason: reason}), do: send_outcome(reason)
  def delivery_outcome(%{type: :transport_error, reason: reason}), do: send_outcome(reason)
  # A streaming (async) HTTP POST reports its transport's reason this way.
  def delivery_outcome({:transport_error, reason}), do: send_outcome(reason)
  def delivery_outcome(_reason), do: :unknown

  # Transport reasons that are raised before a byte is written.
  @unsent_transport_reasons [
    :deadline_expired,
    :not_connected,
    :request_too_large,
    :frame_too_large,
    :invalid_http_url,
    :invalid_network_policy,
    :dns_failed,
    :dns_timeout,
    :non_public_address,
    :non_loopback_address
  ]

  defp send_outcome(reason) when reason in @unsent_transport_reasons, do: :not_sent
  # BoundedClient returns a bare Mint error only from opening the connection;
  # failures after that are wrapped as :http_request_failed/:http_receive_failed.
  defp send_outcome(%Mint.TransportError{}), do: :not_sent
  defp send_outcome(%Mint.HTTPError{}), do: :not_sent
  defp send_outcome({:security_violation, _error}), do: :not_sent
  # The OS trust store could not be loaded, so no TLS connection was opened.
  defp send_outcome({:trust_store_unavailable, _reason}), do: :not_sent
  # stdio refuses an invalid frame before writing it, and a closed port
  # before Port.command/2 writes anything.
  defp send_outcome({:validation_error, _reason}), do: :not_sent
  defp send_outcome({:transport_error, {:send_failed, _reason}}), do: :not_sent
  defp send_outcome({:transport_error, reason}), do: send_outcome(reason)
  defp send_outcome(_reason), do: :unknown

  # GenServer callbacks

  @impl GenServer
  def init(constructor) when is_function(constructor, 0), do: init(constructor.())

  def init(opts), do: Diagnostics.initialize(fn -> initialize_client(opts) end)

  defp initialize_client(opts) do
    # Set up process
    Process.flag(:trap_exit, true)
    Process.put({__MODULE__, :client}, true)

    :ok = Lifetime.install(opts)
    :ok = ConnectionScope.register_client(Keyword.get(opts, :_connection_scope))

    # Build initial state from options
    state = build_initial_state(opts)

    # Check if we should skip connection (for testing)
    if Keyword.get(opts, :_skip_connect, false) do
      {:ok, %{state | connection_status: :disconnected}}
    else
      # Start connection process
      establish_connection(state, opts)
    end
  end

  # Build initial client state from options
  defp build_initial_state(opts) do
    %__MODULE__{
      transport_opts: opts,
      pending_requests: %{},
      pending_batches: %{},
      cancelled_requests: MapSet.new(),
      health_check_interval: Keyword.get(opts, :health_check_interval, 30_000),
      health_check_id: nil,
      connection_status: :connecting,
      last_activity: System.system_time(:second),
      reconnect_attempts: 0,
      reconnect_enabled: Keyword.get(opts, :reconnect, true),
      max_reconnect_attempts:
        Keyword.get(opts, :max_reconnect_attempts, @default_max_reconnect_attempts),
      reconnect_backoff: build_reconnect_backoff(opts),
      reconnect_timer: nil,
      manual_disconnect: false,
      client_info: build_client_info(),
      server_capabilities: %{},
      initialized: false,
      default_retry_policy: Keyword.get(opts, :retry_policy, []),
      default_timeout: Keyword.get(opts, :timeout, 5_000),
      async_post_tasks: %{}
    }
  end

  defp build_reconnect_backoff(opts) do
    configured = Keyword.get(opts, :reconnect_backoff, [])

    %{
      initial: Keyword.get(configured, :initial, @default_reconnect_backoff[:initial]),
      max: Keyword.get(configured, :max, @default_reconnect_backoff[:max]),
      multiplier: Keyword.get(configured, :multiplier, @default_reconnect_backoff[:multiplier])
    }
  end

  defp select_discovered_version(server_versions, state) do
    mode = Keyword.get(state.transport_opts, :protocol_mode) || VersionRegistry.protocol_mode()
    enabled_versions = VersionRegistry.enabled_versions(mode)

    selected =
      if state.protocol_version in server_versions and state.protocol_version in enabled_versions do
        state.protocol_version
      else
        Enum.find(enabled_versions, &(&1 in server_versions))
      end

    case selected do
      nil ->
        {:error,
         {:no_mutually_supported_protocol_version,
          %{server: server_versions, client: enabled_versions}}}

      version ->
        {:ok, version}
    end
  end

  # Establish connection with the server
  defp establish_connection(state, opts) do
    connection_opts = Keyword.put(opts, :retry_policy, state.default_retry_policy)

    case ConnectionManager.establish_connection(state, connection_opts) do
      {:ok, updated_state} ->
        # Update connection status to ready after successful handshake
        :telemetry.execute(
          [:arbor_mcp, :client, :connected],
          %{},
          %{transport: updated_state.transport_mod}
        )

        final_state = %{updated_state | connection_status: :ready, initialized: true}
        {:ok, schedule_next_health_check(final_state)}

      {:error, reason} ->
        handle_connection_error(reason)
    end
  end

  # Handle connection errors with proper normalization
  defp handle_connection_error(reason) do
    Logger.error("Failed to initialize MCP client", reason: LogSummary.describe(reason))
    {:stop, normalize_connection_error(reason)}
  end

  # Normalize various error formats to consistent structure
  defp normalize_connection_error(:handshake_timeout), do: :handshake_timeout
  defp normalize_connection_error(:establish_timeout), do: :establish_timeout

  defp normalize_connection_error({:invalid_establish_timeout, _value} = reason), do: reason

  defp normalize_connection_error(:invalid_request) do
    {:initialize_error, %{"code" => ErrorCodes.invalid_request()}}
  end

  defp normalize_connection_error({:cleanup_failed, _reason, {:error, _}} = reason),
    do: {:transport_connect_failed, reason}

  defp normalize_connection_error(:connection_refused) do
    {:transport_connect_failed, :connection_refused}
  end

  defp normalize_connection_error({:transport_error, details}) do
    {:transport_connect_failed, details}
  end

  defp normalize_connection_error({:method_not_found, message}) do
    {:initialize_error, %{"code" => ErrorCodes.method_not_found(), "message" => message}}
  end

  defp normalize_connection_error({:initialize_rejected, error}) when is_map(error) do
    if error["code"] == ErrorCodes.unsupported_protocol_version() do
      {:initialize_error, error}
    else
      {:initialize_error, %{"code" => ErrorCodes.invalid_request()}}
    end
  end

  defp normalize_connection_error(error) when is_binary(error) do
    if String.contains?(error, "Handshake failed") do
      {:initialize_error, %{"code" => ErrorCodes.invalid_request()}}
    else
      {:transport_connect_failed, error}
    end
  end

  defp normalize_connection_error(reason) do
    # Handle nested errors and other formats
    normalized = extract_inner_reason(reason)
    {:transport_connect_failed, normalized}
  end

  # Extract inner reason from nested structures
  defp extract_inner_reason(%{"code" => _, "message" => _} = err_map), do: err_map
  defp extract_inner_reason({:error, inner_reason}), do: inner_reason
  defp extract_inner_reason(atom) when is_atom(atom), do: to_string(atom)
  defp extract_inner_reason(other), do: inspect(other)

  @impl GenServer
  def handle_call({:request, method, params}, from, state) do
    # Legacy request shape: the caller enforces its own GenServer.call timeout.
    :telemetry.execute(
      [:arbor_mcp, :client, :request, :sent],
      %{},
      %{method: method}
    )

    RequestHandler.handle_request(method, params, from, state)
  end

  def handle_call({:request, method, params, meta}, from, state) when is_map(meta) do
    # Request shape used by make_request/5. Default timeout and retry policy
    # are resolved from this process's own state (single GenServer.call per
    # request); explicit per-call options win and are enforced caller-side.
    :telemetry.execute(
      [:arbor_mcp, :client, :request, :sent],
      %{},
      %{method: method}
    )

    RequestHandler.handle_request(method, params, from, state, meta)
  end

  def handle_call({:fulfill_mrtr, input_requests, opts, scope_ref}, from, state)
      when is_map(input_requests) and is_list(opts) do
    RequestHandler.handle_mrtr_fulfillment(input_requests, opts, scope_ref, from, state)
  end

  def handle_call({:open_subscription, subscription_pid, filter}, _from, state) do
    RequestHandler.open_subscription(subscription_pid, filter, state)
  end

  def handle_call({:prepare_resource_subscribe, uri, subscriber}, _from, state) do
    state = ensure_resource_subscriber_monitor(state, subscriber)
    resources = resource_subscription_state(state)
    subscribers = Map.get(resources.desired, uri, %{})
    already_desired? = map_size(subscribers) > 0
    subscribers = Map.update(subscribers, subscriber, 1, &(&1 + 1))
    desired = Map.put(resources.desired, uri, subscribers)

    if already_desired? and resources.active do
      {:reply, {:retained, resources.active},
       %{state | resource_subscriptions: %{resources | desired: desired}}}
    else
      resources = %{resources | desired: desired, generation: resources.generation + 1}
      {:reply, replacement_plan(resources), %{state | resource_subscriptions: resources}}
    end
  end

  def handle_call({:prepare_resource_unsubscribe, uri, subscriber}, _from, state) do
    resources = resource_subscription_state(state)

    case decrement_subscriber(resources.desired, uri, subscriber) do
      :not_found ->
        {:reply, {:error, :not_subscribed}, state}

      {:retained, desired} ->
        state = maybe_demonitor_resource_subscriber(state, subscriber, desired)

        {:reply, {:retained, resources.active},
         %{state | resource_subscriptions: %{resources | desired: desired}}}

      {:removed, desired} ->
        state = maybe_demonitor_resource_subscriber(state, subscriber, desired)
        resources = %{resources | desired: desired, generation: resources.generation + 1}

        if map_size(desired) == 0 do
          old = resources.active
          resources = %{resources | active: nil}
          {:reply, {:cancel, old}, %{state | resource_subscriptions: resources}}
        else
          {:reply, replacement_plan(resources), %{state | resource_subscriptions: resources}}
        end
    end
  end

  def handle_call({:commit_resource_subscription, generation, subscription}, _from, state) do
    resources = resource_subscription_state(state)

    if generation == resources.generation do
      old = resources.active
      resources = %{resources | active: subscription}
      {:reply, {:committed, old}, %{state | resource_subscriptions: resources}}
    else
      {:reply, {:stale, replacement_plan(resources)}, state}
    end
  end

  def handle_call({:register_notification_listener, filter, subscriber}, _from, state) do
    cond do
      state.connection_status != :ready ->
        {:reply, {:error, :not_connected}, state}

      VersionRegistry.modern?(state.protocol_version) ->
        {:reply, {:error, :use_listen}, state}

      dead_local_process?(subscriber) ->
        {:reply, {:error, :subscriber_not_alive}, state}

      true ->
        id = make_ref()

        ref = %NotificationListener.Ref{
          id: id,
          client: self(),
          subscriber: subscriber,
          filter: filter
        }

        monitor = Process.monitor(subscriber)
        listeners = NotificationListener.register(state.notification_listeners, ref, monitor)
        monitors = Map.put(state.notification_listener_monitors, monitor, id)
        state = ensure_notification_worker(state)

        {:reply, {:ok, ref, state.notification_worker},
         %{state | notification_listeners: listeners, notification_listener_monitors: monitors}}
    end
  end

  def handle_call({:deregister_notification_listener, id}, _from, state) do
    case NotificationListener.deregister(state.notification_listeners, id) do
      {:ok, entry, listeners} ->
        Process.demonitor(entry.monitor, [:flush])
        monitors = Map.delete(state.notification_listener_monitors, entry.monitor)

        {:reply, {:ok, state.notification_worker},
         %{state | notification_listeners: listeners, notification_listener_monitors: monitors}}

      :not_found ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:get_default_retry_policy, _from, state) do
    {:reply, {:ok, state.default_retry_policy}, state}
  end

  def handle_call(:get_default_timeout, _from, state) do
    {:reply, {:ok, state.default_timeout}, state}
  end

  def handle_call(:conformance_mode?, _from, state) do
    {:reply, Keyword.get(state.transport_opts, :conformance_mode, false), state}
  end

  def handle_call({:batch_request, requests, meta}, from, state) when is_map(meta) do
    RequestHandler.handle_batch_request({requests, meta}, from, state)
  end

  def handle_call({:batch_request, requests}, from, state) do
    RequestHandler.handle_batch_request(requests, from, state)
  end

  def handle_call({:scope_disconnect, deadline}, from, state) do
    Process.put({ConnectionScope, :cleanup_deadline}, deadline)
    handle_call(:disconnect, from, state)
  end

  def handle_call({:ordinary_disconnect, deadline}, from, state) do
    Process.put({__MODULE__, :cleanup_deadline}, deadline)
    handle_call(:disconnect, from, state)
  end

  def handle_call({:ordinary_stop, reason, deadline}, from, state) do
    Process.put({__MODULE__, :cleanup_deadline}, deadline)
    {:reply, result, state} = handle_call(:disconnect, from, state)
    {:stop, reason, result, state}
  end

  def handle_call(:disconnect, _from, state) do
    deadline = cleanup_deadline()
    quiesce_result = Lifetime.quiesce(deadline)
    state = %{state | cleanup_result: remember_cleanup(state.cleanup_result, quiesce_result)}
    state = retire_callback_work(state)

    :telemetry.execute(
      [:arbor_mcp, :client, :disconnected],
      %{},
      %{}
    )

    # Cancel health check timer
    cancel_health_check_timer(state)

    # Cancel any scheduled reconnection attempt
    if state.reconnect_timer do
      Process.cancel_timer(state.reconnect_timer)
    end

    # The receiver and transport processes are about to be stopped; their
    # exits are expected, not a foreign link's.
    state = retire_links(state)

    # Stop receiver task by killing the process directly
    if state.receiver_task && is_struct(state.receiver_task, Task) do
      if Process.alive?(state.receiver_task.pid) do
        Process.exit(state.receiver_task.pid, :shutdown)
      end
    end

    notify_subscription_processes(state, {:client_subscription_shutdown, :client_disconnected})
    demonitor_subscriptions(state)
    demonitor_resource_subscribers(state)

    # Reply to all pending requests with connection error
    connection_error = Error.connection_error("Client disconnected")

    state.pending_requests
    |> Enum.each(fn
      {_id, {from, :single, _method}} ->
        GenServer.reply(from, {:error, connection_error})

      {_id, {from, :single}} ->
        GenServer.reply(from, {:error, connection_error})

      {_id, {pid, ref}} when is_pid(pid) and is_reference(ref) ->
        # Handle simple {pid, ref} tuples from older test code
        # Use consistent error format
        GenServer.reply({pid, ref}, {:error, connection_error})

      {_batch_id, {from, :batch, ordered_ids, received_responses}}
      when is_map(received_responses) ->
        # For batch requests, we need to handle them specially. The reply is
        # wrapped in {:ok, responses} to match the batch_request/3 contract;
        # each element is an individual {:ok, _} | {:error, _} result.
        missing_responses =
          ordered_ids
          |> Enum.reject(&Map.has_key?(received_responses, &1))
          |> Enum.map(fn id -> {id, {:error, connection_error}} end)
          |> Map.new()

        all_responses = Map.merge(received_responses, missing_responses)
        ordered_responses = Enum.map(ordered_ids, &Map.get(all_responses, &1))
        GenServer.reply(from, {:ok, ordered_responses})

      {_id, batch_id} when is_binary(batch_id) or is_integer(batch_id) ->
        # This is a request that's part of a batch
        :ok
    end)

    cleanup_result =
      state.cleanup_result
      |> remember_cleanup(close_transport(state))
      |> remember_cleanup(Lifetime.cleanup(deadline))

    NotificationListener.close_all(state.notification_listeners, :disconnected)
    reset_notification_worker(state)

    # Update state to disconnected. The manual_disconnect flag ensures a
    # late {:transport_closed, _} message does not trigger auto-reconnection.
    # The closed transport state is dropped so terminate/2 cannot close it a
    # second time; transport_mod stays for get_status/1.
    new_state = %{
      state
      | connection_status: :disconnected,
        cleanup_result: cleanup_result,
        transport_state: nil,
        pending_requests: %{},
        pending_batches: %{},
        cancelled_requests: MapSet.new(),
        receiver_task: nil,
        health_check_ref: nil,
        health_check_id: nil,
        reconnect_timer: nil,
        manual_disconnect: true,
        async_post_tasks: %{},
        subscriptions: %{},
        subscription_monitors: %{},
        resource_subscriptions: %{
          desired: %{},
          active: nil,
          generation: resource_subscription_state(state).generation + 1
        },
        resource_subscriber_monitors: %{},
        notification_listeners: %{},
        notification_listener_monitors: %{}
    }

    Process.delete({__MODULE__, :cleanup_deadline})
    {:reply, cleanup_result, new_state}
  end

  def handle_call(:get_status, _from, state) do
    status = %{
      connection_status: state.connection_status,
      server_info: state.server_info,
      server_capabilities: state.server_capabilities,
      protocol_version: state.protocol_version,
      transport: state.transport_mod,
      reconnect_attempts: state.reconnect_attempts,
      last_activity: state.last_activity,
      pending_requests: map_size(state.pending_requests)
    }

    {:reply, {:ok, status}, state}
  end

  def handle_call({:apply_discover_result, result}, _from, state) do
    with {:ok, discovery} <- Discover.parse_result(result),
         {:ok, version} <- select_discovered_version(discovery.supported_versions, state) do
      updated_state = %{
        state
        | protocol_version: version,
          server_capabilities: discovery.capabilities,
          server_info: discovery.server_info
      }

      {:reply, :ok, updated_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_pending_requests, _from, state) do
    # Return list of pending request IDs from the state
    pending_ids = Map.keys(state.pending_requests)
    {:reply, pending_ids, state}
  end

  def handle_call({:send_cancelled, request_id, method, params}, _from, state) do
    # Track the cancelled request
    updated_state = %{
      state
      | cancelled_requests: MapSet.put(state.cancelled_requests, request_id)
    }

    # Modern streamable HTTP cancels an ordinary request by closing only that
    # request's response stream. Other transports retain the protocol
    # cancellation notification.
    updated_state =
      case updated_state do
        %{transport_mod: HTTP, transport_state: %HTTP{protocol_era: :modern}} ->
          RequestHandler.close_request_stream(request_id, updated_state)

        %{transport_mod: LegacySSE} ->
          retired_state = RequestHandler.close_request_stream(request_id, updated_state)

          {:noreply, notified_state} =
            RequestHandler.handle_cast_notification(method, params, retired_state)

          notified_state

        _other ->
          {:noreply, notified_state} =
            RequestHandler.handle_cast_notification(method, params, updated_state)

          notified_state
      end

    # Check if this request is still pending and complete it with :cancelled error
    case Map.get(state.pending_requests, request_id) do
      nil ->
        # Request already completed or doesn't exist
        {:reply, :ok, updated_state}

      {from, :single, _method} ->
        # Reply with cancelled error and remove from pending
        GenServer.reply(from, {:error, :cancelled})
        new_pending = Map.delete(state.pending_requests, request_id)
        {:reply, :ok, prune_legacy_posts(%{updated_state | pending_requests: new_pending})}

      {from, :single} ->
        # Reply with cancelled error and remove from pending
        GenServer.reply(from, {:error, :cancelled})
        new_pending = Map.delete(state.pending_requests, request_id)
        {:reply, :ok, prune_legacy_posts(%{updated_state | pending_requests: new_pending})}

      _ ->
        # Other types of requests (batch, etc.) - just track as cancelled
        {:reply, :ok, updated_state}
    end
  end

  @impl GenServer
  def handle_cast(
        {:notification_listeners_resubscribed, results, listener_ids, generation},
        %{notification_listener_generation: generation, connection_status: :ready} = state
      )
      when is_map(results) and is_list(listener_ids) do
    NotificationListener.notify_reconnected(state.notification_listeners, listener_ids, results)
    {:noreply, state}
  end

  # A report from an earlier connection, or one that arrived after another
  # transport loss, describes subscriptions that no longer exist.
  def handle_cast({:notification_listeners_resubscribed, _results, _ids, _generation}, state),
    do: {:noreply, state}

  def handle_cast({:cancel_mrtr_scope, scope_ref}, state) when is_reference(scope_ref) do
    RequestHandler.cancel_mrtr_scope(scope_ref, state)
  end

  def handle_cast({:close_subscription, subscription_pid, request_id, reason}, state) do
    RequestHandler.close_subscription(subscription_pid, request_id, reason, state)
  end

  def handle_cast({:notification, method, params}, state) do
    RequestHandler.handle_cast_notification(method, params, state)
  end

  @impl GenServer
  def handle_info({:transport_message, message}, %{transport_mod: mod} = state)
      when mod in [Arbor.MCP.Transport.Test, Arbor.MCP.Transport.Local] do
    # These standard peers opt into an immutable lifetime event-context during
    # connect; raw frames cannot authenticate a retired/replaced connection.
    if is_nil(Lifetime.current()),
      do: RequestHandler.parse_transport_message(message, state),
      else: {:noreply, state}
  end

  def handle_info({:transport_message, message}, state) do
    RequestHandler.parse_transport_message(message, state)
  end

  def handle_info(
        {:modern_http_stream_message, stream_pid, request_id, message},
        %{
          transport_mod: HTTP,
          transport_state: %HTTP{} = transport_state
        } = state
      ) do
    result =
      if HTTP.stream_owner?(transport_state, request_id, stream_pid) do
        RequestHandler.handle_request_stream_message(request_id, message, state)
      else
        {:noreply, state}
      end

    send(stream_pid, {:modern_http_stream_ack, self(), request_id})
    result
  end

  def handle_info(
        {:modern_http_stream_auth_updated, stream_pid, request_id, changes},
        %{
          transport_mod: HTTP,
          transport_state: %HTTP{} = transport_state
        } = state
      )
      when is_map(changes) do
    if HTTP.stream_owner?(transport_state, request_id, stream_pid) do
      transport_state = merge_modern_stream_auth_state(transport_state, changes)
      {:noreply, %{state | transport_state: transport_state}}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:modern_http_stream_finished, stream_pid, request_id},
        %{
          transport_mod: HTTP,
          transport_state: %HTTP{} = transport_state
        } = state
      ) do
    transport_state = HTTP.forget_stream(transport_state, request_id, stream_pid)

    {:noreply, %{state | transport_state: transport_state}}
  end

  def handle_info(
        {:modern_http_stream_closed, stream_pid, request_id, reason},
        %{
          transport_mod: HTTP,
          transport_state: %HTTP{} = transport_state
        } = state
      ) do
    if HTTP.stream_owner?(transport_state, request_id, stream_pid) do
      transport_state = HTTP.forget_stream(transport_state, request_id, stream_pid)

      RequestHandler.handle_modern_stream_closed(
        request_id,
        reason,
        %{state | transport_state: transport_state}
      )
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:ex_mcp_subscription, %Subscription.Ref{} = subscription,
         "notifications/resources/updated", %{"uri" => uri} = params},
        state
      ) do
    resources = resource_subscription_state(state)

    if active_subscription?(resources.active, subscription) do
      resources.desired
      |> Map.get(uri, %{})
      |> Map.keys()
      |> Enum.each(&send(&1, {:ex_mcp_resource_updated, uri, params}))
    end

    {:noreply, state}
  end

  def handle_info(
        {:ex_mcp_subscription_resync, %Subscription.Ref{} = subscription, {:complete, snapshot}},
        state
      ) do
    resources = resource_subscription_state(state)

    if resources.active && resources.active.pid == subscription.pid do
      subscribers =
        resources.desired
        |> Map.values()
        |> Enum.flat_map(&Map.keys/1)
        |> Enum.uniq()

      Enum.each(subscribers, &send(&1, {:ex_mcp_resource_resync, subscription, snapshot}))
      {:noreply, %{state | resource_subscriptions: %{resources | active: subscription}}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:ex_mcp_subscription_resync, _subscription, _status}, state),
    do: {:noreply, state}

  def handle_info({:ex_mcp_subscription_closed, _subscription, _reason}, state),
    do: {:noreply, state}

  # Async POST result — the HTTP transport spawns a monitored task for POST
  # requests in SSE mode to avoid blocking the GenServer during bidirectional
  # flows. `meta` carries the request id the task served plus the durable
  # transport-state fields the POST changed (session rotation, OAuth token
  # refresh), which are merged back into our copy of the transport state.
  def handle_info({:client_lifetime_event, epoch, {:transport_message, message}}, state) do
    if Lifetime.event?(epoch),
      do: RequestHandler.parse_transport_message(message, state),
      else: {:noreply, state}
  end

  def handle_info({:client_lifetime_event, epoch, message}, state) do
    if Lifetime.event?(epoch), do: handle_info(message, state), else: {:noreply, state}
  end

  # A LegacySSE result settles once but keeps its charged worker until actual
  # DOWN. Unlike old transport metadata, its nonce and original deadline were
  # recorded synchronously before the worker was released to perform IO.
  def handle_info({:async_post_result, result, %{kind: :legacy_post} = meta}, state) do
    case current_legacy_post(state, meta) do
      {ref, %{completed?: false} = entry} ->
        entry = %{entry | completed?: true}
        state = %{state | async_post_tasks: Map.put(state.async_post_tasks, ref, entry)}

        if Deadline.expired?(entry.deadline) do
          {:noreply, fail_legacy_post_request(state, entry.request_id, :timeout)}
        else
          handle_legacy_post_result(result, entry.request_id, state)
        end

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:async_post_result, _result, _meta}, %{transport_mod: LegacySSE} = state),
    do: {:noreply, state}

  def handle_info({:async_post_result, result, meta}, state) when is_map(meta) do
    if current_async_post?(state, meta) do
      state = merge_async_transport_state(state, meta)
      state = finish_async_post(state, meta)
      handle_async_post_result(result, Map.get(meta, :request_id), state)
    else
      {:noreply, state}
    end
  end

  # Legacy 2-tuple shape (no metadata) kept for compatibility.
  def handle_info({:async_post_result, result}, state) do
    if is_nil(Lifetime.current()),
      do: handle_async_post_result(result, nil, state),
      else: {:noreply, state}
  end

  # Async POST task registration: maps the task's monitor ref to the request
  # id it serves so a crashed task can fail that request.
  def handle_info(
        {:async_post_task, _ref, _pid, _request_id},
        %{transport_mod: LegacySSE} = state
      ),
      do: {:noreply, state}

  def handle_info({:async_post_task, _ref, _request_id}, %{transport_mod: LegacySSE} = state),
    do: {:noreply, state}

  def handle_info({:async_post_task, ref, pid, request_id}, state)
      when is_reference(ref) and is_pid(pid) do
    tasks = Map.put(state.async_post_tasks || %{}, ref, {pid, request_id})
    {:noreply, %{state | async_post_tasks: tasks}}
  end

  def handle_info({:async_post_task, ref, request_id}, state) when is_reference(ref) do
    if is_nil(Lifetime.current()) do
      tasks = Map.put(state.async_post_tasks || %{}, ref, request_id)
      {:noreply, %{state | async_post_tasks: tasks}}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _subscriber, _reason},
        %{notification_listener_monitors: monitors} = state
      )
      when is_map(monitors) and is_map_key(monitors, ref) do
    {id, monitors} = Map.pop(monitors, ref)
    state = %{state | notification_listener_monitors: monitors}

    case NotificationListener.deregister(state.notification_listeners, id) do
      {:ok, _entry, listeners} ->
        if state.notification_worker do
          Worker.release_async(state.notification_worker, id, state.default_timeout || 5_000)
        end

        {:noreply, %{state | notification_listeners: listeners}}

      :not_found ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _worker, reason},
        %{notification_worker_monitor: ref} = state
      )
      when is_reference(ref) do
    state = %{state | notification_worker: nil, notification_worker_monitor: nil}
    {:noreply, close_notification_listeners(state, {:listener_worker_down, reason})}
  end

  def handle_info(
        {:DOWN, ref, :process, subscriber, _reason},
        %{resource_subscriber_monitors: monitors} = state
      )
      when is_map(monitors) and is_map_key(monitors, ref) do
    resources = resource_subscription_state(state)
    {resources, action} = drop_resource_subscriber(resources, subscriber)
    client = self()

    run_resource_subscription_action(client, action)

    {:noreply,
     %{
       state
       | resource_subscriber_monitors: Map.delete(monitors, ref),
         resource_subscriptions: resources
     }}
  end

  def handle_info(
        {:DOWN, ref, :process, subscription_pid, _reason},
        %{subscription_monitors: monitors} = state
      )
      when is_map(monitors) and is_map_key(monitors, ref) do
    state = RequestHandler.close_subscriptions_for_pid(subscription_pid, state)

    resources = resource_subscription_state(state)

    resources =
      case resources.active do
        %Subscription.Ref{pid: ^subscription_pid} -> %{resources | active: nil}
        _other -> resources
      end

    {:noreply,
     %{
       state
       | subscription_monitors: Map.delete(monitors, ref),
         resource_subscriptions: resources
     }}
  end

  # Legacy POST credit covers both actual IO worker and logical SSE outcome.
  # Physical DOWN alone cannot discard the original cutoff while an outcome
  # is still pending. Other async transports retain their existing bookkeeping.
  def handle_info({:DOWN, ref, :process, pid, reason}, %{async_post_tasks: tasks} = state)
      when is_map(tasks) and is_map_key(tasks, ref) and
             is_map(:erlang.map_get(ref, tasks)) do
    case Map.get(tasks, ref) do
      %{kind: :legacy_post, task_pid: ^pid} = entry ->
        if Process.alive?(pid) do
          # A caller-authored DOWN is not a physical outcome or a refund.
          {:noreply, state}
        else
          Process.demonitor(ref, [:flush])
          entry = %{entry | actual_down?: true}
          state = %{state | async_post_tasks: Map.put(tasks, ref, entry)}

          cond do
            Deadline.expired?(entry.deadline) ->
              {:noreply, fail_legacy_post_request(state, entry.request_id, :timeout)}

            entry.completed? ->
              {:noreply, prune_legacy_posts(state)}

            true ->
              {:noreply,
               fail_legacy_post_request(state, entry.request_id, {:transport_error, reason})}
          end
        end

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{async_post_tasks: tasks} = state)
      when is_map(tasks) and is_map_key(tasks, ref) do
    {entry, remaining} = Map.pop(tasks, ref)

    request_id =
      case entry do
        {_pid, id} -> id
        id -> id
      end

    state = %{state | async_post_tasks: remaining}

    if reason == :normal do
      {:noreply, state}
    else
      Logger.error("Async POST task exited", reason: LogSummary.describe(reason))
      {:noreply, fail_async_post_request(state, request_id, reason)}
    end
  end

  # A server-request handler task (sampling/elicitation/custom) finished.
  def handle_info({:server_request_result, task_pid, outcome}, state)
      when is_pid(task_pid) do
    RequestHandler.handle_server_request_completion(task_pid, outcome, state)
  end

  def handle_info({:mrtr_fulfillment_result, task_pid, outcome}, state)
      when is_pid(task_pid) do
    RequestHandler.handle_mrtr_fulfillment_completion(task_pid, outcome, state)
  end

  def handle_info(
        {:DOWN, _ref, :process, pid, reason},
        %{mrtr_tasks: tasks} = state
      )
      when is_map(tasks) and is_map_key(tasks, pid) do
    RequestHandler.handle_mrtr_fulfillment_down(pid, reason, state)
  end

  # A server-request handler task died before delivering a result.
  def handle_info(
        {:DOWN, _ref, :process, pid, reason},
        %{server_request_tasks: tasks} = state
      )
      when is_map(tasks) and is_map_key(tasks, pid) do
    RequestHandler.handle_server_request_down(pid, reason, state)
  end

  # Shared stdio delivery keeps its one frame of credit until protocol processing completes.
  def handle_info({:arbor_rpc, _generation, _event} = message, state) do
    case stdio_transport(state) do
      %Stdio{} = transport ->
        handle_stdio_event(Stdio.event(transport, message), transport, state)

      nil ->
        {:noreply, state}
    end
  end

  # Push model: transport sends pre-parsed messages directly
  def handle_info({:transport_event, message}, state) do
    RequestHandler.parse_transport_message(message, state)
  end

  # Push model: event ID tracking (for SSE resumability)
  def handle_info({:transport_event_id, _event_id}, state) do
    # Event IDs are tracked by the transport internally
    {:noreply, state}
  end

  # Push model: transport error
  def handle_info({:transport_error, reason}, state) do
    Logger.warning("Transport error (push)", reason: LogSummary.describe(reason))
    {:noreply, state}
  end

  def handle_info(:health_check, state) do
    {:noreply, perform_health_check(state)}
  end

  # Default-timeout enforcement for requests made without an explicit
  # :timeout option (scheduled by RequestHandler). Stale timers for requests
  # that already completed find no pending entry and are ignored.
  def handle_info({:request_timeout, request_id}, state) do
    case Map.get(state.pending_requests, request_id) do
      {from, :single, _method} ->
        GenServer.reply(from, {:error, :timeout})

        state = RequestHandler.close_request_stream(request_id, state)

        {:noreply,
         prune_legacy_posts(%{
           state
           | pending_requests: Map.delete(state.pending_requests, request_id)
         })}

      {from, :single} ->
        GenServer.reply(from, {:error, :timeout})

        state = RequestHandler.close_request_stream(request_id, state)

        {:noreply,
         prune_legacy_posts(%{
           state
           | pending_requests: Map.delete(state.pending_requests, request_id)
         })}

      {_from, :batch, _ids, _received} when state.transport_mod == LegacySSE ->
        state = RequestHandler.close_request_stream(request_id, state)
        {:noreply, fail_legacy_post_request(state, request_id, :timeout)}

      _ ->
        {:noreply, state}
    end
  end

  # The receiver reports a closed transport with {:transport_closed, _}
  # before it exits, so its exit while it is still the receiver means it
  # crashed with the connection (a stdio server, an HTTP session) possibly
  # still up: close that before moving on.
  def handle_info({:EXIT, pid, reason}, %{receiver_task: %Task{pid: task_pid}} = state)
      when pid == task_pid do
    Logger.error("Receiver task died", reason: LogSummary.describe(reason))
    state = abandon_transport(state)
    {:noreply, handle_transport_down({:receiver_task_died, reason}, state)}
  end

  # The client traps exits so it can tell its own links from everyone
  # else's. The starter's exit never reaches here: GenServer handles the
  # parent's exit itself and terminates, which closes the transport.
  def handle_info({:EXIT, from, reason}, state) do
    cond do
      MapSet.member?(state.retired_links, from) ->
        {:noreply, %{state | retired_links: MapSet.delete(state.retired_links, from)}}

      from in Arbor.MCP.Transport.linked_processes(state.transport_mod, state.transport_state) ->
        handle_transport_link_exit(from, reason, state)

      reason == :normal ->
        # A normal exit does not take down a linked process that does not
        # trap exits, so it does not take down the client either.
        {:noreply, state}

      true ->
        # Any other link: behave as a process that does not trap exits.
        {:stop, reason, state}
    end
  end

  def handle_info({:transport_closed, reason}, state) do
    Logger.error("Transport closed", reason: LogSummary.describe(reason))

    state = %{
      state
      | cleanup_result: remember_cleanup(state.cleanup_result, terminal_cleanup(reason))
    }

    {:noreply, handle_transport_down(reason, state)}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case stdio_transport(state) do
      %Stdio{monitor: {^ref, ^pid}} ->
        state = abandon_transport(state)
        {:noreply, handle_transport_down({:subprocess_down, reason}, state)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(:attempt_reconnect, %{connection_status: :reconnecting} = state) do
    {:noreply, attempt_reconnect(%{state | reconnect_timer: nil})}
  end

  def handle_info(:attempt_reconnect, state) do
    # Stale timer (e.g. the user disconnected while a reconnect was scheduled)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Async POST support (Streamable HTTP transport)

  defp handle_stdio_event({:frame, token, bytes}, transport, state) do
    outcome =
      case Stdio.frame(bytes) do
        {:ok, json} ->
          Stdio.received(json)
          RequestHandler.parse_transport_message(json, state)

        :ignore ->
          {:noreply, state}
      end

    finish_stdio_frame(outcome, transport, Stdio.ack(transport, token))
  end

  defp handle_stdio_event({:closed, reason, _unfinished}, _transport, state) do
    state = %{
      state
      | cleanup_result: remember_cleanup(state.cleanup_result, terminal_cleanup(reason))
    }

    {:noreply, handle_transport_down(Stdio.closed_reason(reason), state)}
  end

  defp handle_stdio_event(:ignore, _transport, state), do: {:noreply, state}

  defp finish_stdio_frame(outcome, _transport, :ok), do: outcome

  defp finish_stdio_frame({:noreply, state} = outcome, transport, {:error, reason}) do
    current = stdio_transport(state)

    if reason == :closed and
         (is_nil(current) or Stdio.identity(current) != Stdio.identity(transport)) do
      outcome
    else
      state = abandon_transport(state)
      {:noreply, handle_transport_down({:frame_ack_failed, reason}, state)}
    end
  end

  defp stdio_transport(%{transport_mod: Stdio, transport_state: %Stdio{} = transport}),
    do: transport

  defp stdio_transport(%{
         transport_mod: ReliabilityWrapper,
         transport_state: %ReliabilityWrapper{wrapped_module: Stdio, wrapped_state: transport}
       }),
       do: transport

  defp stdio_transport(_state), do: nil

  defp current_legacy_post(state, meta) do
    if Map.get(meta, :generation) == Lifetime.current() do
      Enum.find(state.async_post_tasks, fn
        {_ref, %{kind: :legacy_post} = entry} ->
          Map.take(entry, [:kind, :task_pid, :request_id, :nonce, :generation, :deadline]) == meta

        _other ->
          false
      end)
    end
  end

  defp handle_legacy_post_result({:ok, _transport}, _id, state), do: {:noreply, state}

  defp handle_legacy_post_result({:error, :deadline_expired}, id, state),
    do: {:noreply, fail_legacy_post_request(state, id, :timeout)}

  defp handle_legacy_post_result({:error, reason}, id, state),
    do: {:noreply, fail_legacy_post_request(state, id, {:transport_error, reason})}

  defp fail_legacy_post_request(state, id, error) do
    updated =
      case Map.get(state.pending_requests, id) do
        {from, :single, _method} ->
          GenServer.reply(from, {:error, error})
          %{state | pending_requests: Map.delete(state.pending_requests, id)}

        {from, :single} ->
          GenServer.reply(from, {:error, error})
          %{state | pending_requests: Map.delete(state.pending_requests, id)}

        {from, :batch, ordered_ids, received} when is_map(received) ->
          # Preserve responses already delivered for this exact envelope. Its
          # authenticated POST failure cannot settle a sibling pending batch.
          if map_size(received) == 0 do
            GenServer.reply(from, {:error, error})
          else
            outcomes = Enum.map(ordered_ids, &Map.get(received, &1, {:error, error}))
            GenServer.reply(from, {:ok, outcomes})
          end

          pending =
            Enum.reduce(ordered_ids, state.pending_requests, fn member, acc ->
              if Map.get(acc, member) == id, do: Map.delete(acc, member), else: acc
            end)

          %{state | pending_requests: Map.delete(pending, id)}

        _other ->
          state
      end

    prune_legacy_posts(updated)
  end

  defp prune_legacy_posts(state) do
    tasks =
      Map.reject(state.async_post_tasks, fn
        {_ref, %{kind: :legacy_post, actual_down?: true, request_id: id}} ->
          not Map.has_key?(state.pending_requests, id)

        _other ->
          false
      end)

    %{state | async_post_tasks: tasks}
  end

  defp handle_async_post_result({:ok, _new_ts, response_data}, _request_id, state) do
    # POST response contains data — parse it as a transport message
    RequestHandler.parse_transport_message(response_data, state)
  end

  defp handle_async_post_result({:ok, _new_ts}, _request_id, state) do
    # POST returned but no inline data — result will come via SSE stream
    {:noreply, state}
  end

  defp handle_async_post_result({:error, reason}, request_id, state) do
    Logger.error("Async POST failed", reason: LogSummary.describe(reason))
    {:noreply, fail_async_post_request(state, request_id, reason)}
  end

  # Merge the durable transport-state changes computed by an async POST task
  # (session id rotation, OAuth token/auth state, SSE retry metadata) into the
  # client's current transport state. Only the fields the task actually
  # changed are merged — see Arbor.MCP.Transport.HTTP.async_state_changes/2 — so
  # concurrent updates to unrelated fields are preserved. The merge is skipped
  # when the task is no longer tracked (the transport was torn down or
  # reconnected after the task started), which keeps stale results from an old
  # connection out of the new connection's state.
  defp merge_async_transport_state(state, meta) do
    changes = Map.get(meta, :state_changes) || %{}

    if map_size(changes) > 0 and is_map(state.transport_state) and
         known_async_post_request?(state, Map.get(meta, :request_id)) do
      %{state | transport_state: Map.merge(state.transport_state, changes)}
    else
      state
    end
  end

  defp merge_modern_stream_auth_state(transport_state, changes) do
    provider_state = Map.get(changes, :auth_provider_state, transport_state.auth_provider_state)

    case Map.fetch(changes, :access_token) do
      {:ok, token} when is_binary(token) ->
        headers =
          transport_state.headers
          |> Headers.delete("authorization")
          |> List.insert_at(0, {"Authorization", "Bearer #{token}"})

        %{
          transport_state
          | access_token: token,
            auth_provider_state: provider_state,
            headers: headers
        }

      _other ->
        %{transport_state | auth_provider_state: provider_state}
    end
  end

  defp current_async_post?(state, %{task_pid: pid, request_id: id}) do
    Enum.any?(state.async_post_tasks, fn {_ref, entry} -> entry == {pid, id} end)
  end

  defp current_async_post?(_state, _meta), do: is_nil(Lifetime.current())

  defp finish_async_post(state, %{task_pid: pid}) do
    tasks =
      Map.reject(state.async_post_tasks, fn
        {ref, {^pid, _id}} ->
          Process.demonitor(ref, [:flush])
          true

        _entry ->
          false
      end)

    %{state | async_post_tasks: tasks}
  end

  defp finish_async_post(state, _meta), do: state

  defp known_async_post_request?(%{async_post_tasks: tasks}, request_id) when is_map(tasks) do
    Enum.any?(tasks, fn
      {_ref, {_pid, id}} -> id == request_id
      {_ref, id} -> id == request_id
    end)
  end

  defp known_async_post_request?(_state, _request_id), do: false

  # Fail the pending request an async POST task was serving. Batch members,
  # notifications (nil id), and already-completed requests are left to the
  # normal timeout/cleanup path.
  defp fail_async_post_request(state, request_id, reason) do
    case request_id && Map.get(state.pending_requests, request_id) do
      {from, :single, _method} ->
        GenServer.reply(from, {:error, {:transport_error, reason}})
        %{state | pending_requests: Map.delete(state.pending_requests, request_id)}

      {from, :single} ->
        GenServer.reply(from, {:error, {:transport_error, reason}})
        %{state | pending_requests: Map.delete(state.pending_requests, request_id)}

      _ ->
        state
    end
  end

  # A normal exit of a transport-owned process is the transport's own
  # business: it reports a real closure through {:transport_closed, _}. An
  # abnormal one means the transport broke without saying so, and may still
  # hold its connection or child process, so it is closed before the client
  # moves on (and possibly reconnects, which would otherwise leave the old
  # server running next to the new one).
  defp handle_transport_link_exit(_from, :normal, state), do: {:noreply, state}

  defp handle_transport_link_exit(_from, reason, state) do
    Logger.error("Transport forwarder died", reason: LogSummary.describe(reason))
    state = abandon_transport(state)
    {:noreply, handle_transport_down({:transport_forwarder_died, reason}, state)}
  end

  defp abandon_transport(state) do
    state = retire_links(state)
    %{state | cleanup_result: remember_cleanup(state.cleanup_result, close_transport(state))}
  end

  # Remembers the links of the transport and receiver this client is about
  # to drop, so their exits are not taken for a foreign link's. A link that
  # is already gone is unlinked and its pending exit flushed instead, so the
  # set only holds processes whose exit is still to come.
  defp retire_links(state) do
    receiver =
      case state.receiver_task do
        %Task{pid: pid} -> [pid]
        _other -> []
      end

    links =
      receiver ++ Arbor.MCP.Transport.linked_processes(state.transport_mod, state.transport_state)

    retired =
      Enum.reduce(links, state.retired_links, fn link, retired ->
        if link_alive?(link) do
          MapSet.put(retired, link)
        else
          Process.unlink(link)

          receive do
            {:EXIT, ^link, _reason} -> :ok
          after
            0 -> :ok
          end

          MapSet.delete(retired, link)
        end
      end)

    %{state | retired_links: retired}
  end

  defp link_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp link_alive?(port) when is_port(port), do: Port.info(port) != nil

  # Closing is bounded (see Deadline.cleanup_timeout/0): a best-effort
  # session DELETE to a peer that stopped answering must not hold stop/2,
  # disconnect/1 or the client loop for the transport's request timeout.
  defp close_transport(%{transport_mod: mod, transport_state: transport_state})
       when not is_nil(mod) and not is_nil(transport_state) do
    deadline = cleanup_deadline()
    cleanup_state = Deadline.put_on_transport(mod, transport_state, deadline)

    result =
      if ConnectionScope.current() do
        # The explicit bracket already supplies an independent bounded owner;
        # retain its native close-callback caller contract.
        perform_transport_close(mod, cleanup_state)
      else
        bounded_transport_close(mod, cleanup_state, deadline)
      end

    ConnectionScope.closed(mod, transport_state, result)
    result
  end

  defp close_transport(_state), do: :ok

  defp perform_transport_close(mod, cleanup_state) do
    case mod.close(cleanup_state) do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_close_result, other}}
    end
  rescue
    error -> {:error, {:cleanup_exception, error.__struct__}}
  catch
    kind, reason -> {:error, {:cleanup_failure, kind, reason}}
  end

  defp bounded_transport_close(mod, cleanup_state, deadline) do
    task = Lifetime.close_async(fn -> perform_transport_close(mod, cleanup_state) end)
    Process.unlink(task.pid)

    case Task.yield(task, Deadline.remaining(deadline)) do
      {:ok, result} ->
        result

      _unfinished ->
        Process.exit(task.pid, :kill)
        Process.demonitor(task.ref, [:flush])
        {:error, :client_cleanup_timeout}
    end
  end

  defp cleanup_deadline do
    Deadline.earliest(
      Process.get({__MODULE__, :cleanup_deadline}),
      Process.get({ConnectionScope, :cleanup_deadline})
    ) || begin_cleanup_deadline()
  end

  defp begin_cleanup_deadline do
    deadline = Deadline.after_ms(Lifetime.cleanup_timeout())
    Process.put({__MODULE__, :cleanup_deadline}, deadline)
    deadline
  end

  defp retire_callback_work(state) do
    Enum.each(state.server_request_tasks, fn {_pid, {ref, _id, _kind}} ->
      Process.demonitor(ref, [:flush])
    end)

    Enum.each(state.mrtr_tasks, fn {_pid, {ref, from, _scope}} ->
      Process.demonitor(ref, [:flush])
      GenServer.reply(from, {:error, :client_disconnected})
    end)

    %{state | server_request_tasks: %{}, mrtr_tasks: %{}}
  end

  defp terminal_cleanup({:cleanup_failed, _reason, {:error, _} = result}), do: result
  defp terminal_cleanup({:connection_error, reason}), do: terminal_cleanup(reason)
  defp terminal_cleanup({:transport_error, reason}), do: terminal_cleanup(reason)
  defp terminal_cleanup({:transport_closed, reason}), do: terminal_cleanup(reason)
  defp terminal_cleanup(_reason), do: :ok
  defp remember_cleanup({:error, _} = previous, _result), do: previous
  defp remember_cleanup(:ok, result), do: result

  # Transport teardown and reconnection

  # Already reconnecting with an attempt scheduled — nothing left to tear down.
  defp handle_transport_down(
         _reason,
         %{connection_status: :reconnecting, reconnect_timer: timer} = state
       )
       when timer != nil do
    state
  end

  defp handle_transport_down(reason, state) do
    deadline = cleanup_deadline()
    quiesce_result = Lifetime.quiesce(deadline, :transport)
    state = %{state | cleanup_result: remember_cleanup(state.cleanup_result, quiesce_result)}
    state = retire_callback_work(state)
    state = retire_links(state)
    reply_pending_with_close_error(reason, state)
    notify_subscription_processes(state, {:client_subscription_disconnected, reason})

    :telemetry.execute(
      [:arbor_mcp, :client, :disconnected],
      %{},
      %{reason: reason, transport: state.transport_mod, pid: self()}
    )

    # Stop any lingering receiver task for the old transport so it cannot
    # deliver stale close events after a successful reconnection
    if is_struct(state.receiver_task, Task) && Process.alive?(state.receiver_task.pid) do
      Process.exit(state.receiver_task.pid, :shutdown)
    end

    cleanup_result =
      remember_cleanup(state.cleanup_result, Lifetime.cleanup(deadline, :transport))

    Process.delete({__MODULE__, :cleanup_deadline})
    previous_status = state.connection_status

    # The health check is re-armed by the reconnect success path; leaving the
    # old timer running would double up once the client is ready again.
    cancel_health_check_timer(state)

    cleared_state = %{
      state
      | connection_status: :disconnected,
        cleanup_result: cleanup_result,
        transport_mod: nil,
        transport_state: nil,
        receiver_task: nil,
        pending_requests: %{},
        pending_batches: %{},
        cancelled_requests: MapSet.new(),
        health_check_ref: nil,
        health_check_id: nil,
        async_post_tasks: %{},
        subscriptions: %{}
    }

    if reconnect_allowed?(cleared_state, previous_status) do
      schedule_reconnect(cleared_state)
    else
      close_notification_listeners(cleared_state, {:transport_closed, reason})
    end
  end

  # Reply to all pending requests with connection error or cancelled error
  defp reply_pending_with_close_error(reason, state) do
    connection_error = Error.connection_error("Transport closed: #{inspect(reason)}")

    Enum.each(state.pending_requests, fn
      {id, {from, :single, _method}} ->
        GenServer.reply(from, {:error, close_error_for(id, state, connection_error)})

      {id, {from, :single}} ->
        GenServer.reply(from, {:error, close_error_for(id, state, connection_error)})

      {id, {pid, ref}} when is_pid(pid) and is_reference(ref) ->
        # Handle simple {pid, ref} tuples from older test code
        GenServer.reply({pid, ref}, {:error, close_error_for(id, state, connection_error)})

      {_batch_id, {from, :batch, ordered_ids, received_responses}}
      when is_map(received_responses) ->
        # For batch requests, we need to handle them specially. The reply is
        # wrapped in {:ok, responses} to match the batch_request/3 contract;
        # each element is an individual {:ok, _} | {:error, _} result.
        missing_responses =
          ordered_ids
          |> Enum.reject(&Map.has_key?(received_responses, &1))
          |> Enum.map(fn id -> {id, {:error, connection_error}} end)
          |> Map.new()

        all_responses = Map.merge(received_responses, missing_responses)
        ordered_responses = Enum.map(ordered_ids, &Map.get(all_responses, &1))
        GenServer.reply(from, {:ok, ordered_responses})

      {_id, batch_id} when is_binary(batch_id) or is_integer(batch_id) ->
        # This is a request that's part of a batch
        :ok
    end)
  end

  defp close_error_for(id, state, connection_error) do
    if MapSet.member?(state.cancelled_requests, id) do
      # Use proper error map for cancelled requests
      %{
        "code" => ErrorCodes.request_cancelled(),
        "message" => "Request cancelled"
      }
    else
      connection_error
    end
  end

  defp notify_subscription_processes(state, message) do
    state.subscription_monitors
    |> Map.values()
    |> Enum.uniq()
    |> Enum.each(&send(&1, message))
  end

  defp demonitor_subscriptions(state) do
    Enum.each(state.subscription_monitors, fn {ref, _pid} ->
      Process.demonitor(ref, [:flush])
    end)
  end

  defp demonitor_resource_subscribers(state) do
    Enum.each(state.resource_subscriber_monitors, fn {ref, _pid} ->
      Process.demonitor(ref, [:flush])
    end)
  end

  defp resource_subscription_state(state) do
    case state.resource_subscriptions do
      %{desired: desired, active: active, generation: generation}
      when is_map(desired) and is_integer(generation) ->
        %{desired: desired, active: active, generation: generation}

      _legacy_shape ->
        %{desired: %{}, active: nil, generation: 0}
    end
  end

  defp replacement_plan(resources) do
    {:replace, resources.active, resources.desired |> Map.keys() |> Enum.sort(),
     resources.generation}
  end

  defp decrement_subscriber(desired, uri, subscriber) do
    with subscribers when is_map(subscribers) <- Map.get(desired, uri),
         count when is_integer(count) <- Map.get(subscribers, subscriber) do
      subscribers =
        if count > 1,
          do: Map.put(subscribers, subscriber, count - 1),
          else: Map.delete(subscribers, subscriber)

      if map_size(subscribers) == 0,
        do: {:removed, Map.delete(desired, uri)},
        else: {:retained, Map.put(desired, uri, subscribers)}
    else
      _other -> :not_found
    end
  end

  defp ensure_resource_subscriber_monitor(state, subscriber) do
    monitored? =
      Enum.any?(state.resource_subscriber_monitors, fn {_ref, pid} -> pid == subscriber end)

    if monitored? do
      state
    else
      ref = Process.monitor(subscriber)

      %{
        state
        | resource_subscriber_monitors:
            Map.put(state.resource_subscriber_monitors, ref, subscriber)
      }
    end
  end

  defp maybe_demonitor_resource_subscriber(state, subscriber, desired) do
    if resource_subscriber?(desired, subscriber) do
      state
    else
      case Enum.find(state.resource_subscriber_monitors, fn {_ref, pid} -> pid == subscriber end) do
        nil ->
          state

        {ref, _pid} ->
          Process.demonitor(ref, [:flush])

          %{
            state
            | resource_subscriber_monitors: Map.delete(state.resource_subscriber_monitors, ref)
          }
      end
    end
  end

  defp resource_subscriber?(desired, subscriber) do
    Enum.any?(desired, fn {_uri, subscribers} -> Map.has_key?(subscribers, subscriber) end)
  end

  defp drop_resource_subscriber(resources, subscriber) do
    old_uris = resources.desired |> Map.keys() |> MapSet.new()

    desired =
      resources.desired
      |> Enum.reduce(%{}, fn {uri, subscribers}, acc ->
        case Map.delete(subscribers, subscriber) do
          remaining when map_size(remaining) == 0 -> acc
          remaining -> Map.put(acc, uri, remaining)
        end
      end)

    new_uris = desired |> Map.keys() |> MapSet.new()
    resources = %{resources | desired: desired}

    cond do
      MapSet.equal?(old_uris, new_uris) ->
        {resources, :none}

      map_size(desired) == 0 ->
        old = resources.active
        {%{resources | active: nil, generation: resources.generation + 1}, {:cancel, old}}

      true ->
        resources = %{resources | generation: resources.generation + 1}
        {resources, replacement_plan(resources)}
    end
  end

  defp run_resource_subscription_action(_client, :none), do: :ok
  defp run_resource_subscription_action(_client, {:cancel, nil}), do: :ok

  defp run_resource_subscription_action(_client, {:cancel, subscription}) do
    Subscription.cancel(subscription, "resource subscriber exited")
  end

  defp run_resource_subscription_action(
         client,
         {:replace, old, uris, generation}
       ) do
    {:ok, _pid} =
      ConnectionScope.start_worker(fn ->
        Resources.replace_resource_subscription(client, old, uris, generation)
      end)

    :ok
  end

  defp active_subscription?(%Subscription.Ref{} = active, %Subscription.Ref{} = candidate) do
    active.pid == candidate.pid and active.request_id == candidate.request_id
  end

  defp active_subscription?(_active, _candidate), do: false

  # Crash reports and :sys.get_status/1 show the state with the connection's
  # credentials replaced (headers, tokens, secrets, the server's env), for
  # every log formatter, not only Elixir's Inspect.
  @impl GenServer
  def format_status(status), do: Diagnostics.format_status(status, __MODULE__)

  @impl true
  def terminate(reason, state) do
    deadline = cleanup_deadline()
    Lifetime.quiesce(deadline)
    retire_callback_work(state)

    state
    |> Map.get(:notification_listeners, %{})
    |> NotificationListener.close_all({:shutdown, reason})

    # However the client stops (stop/2, its starter's exit, a linked
    # process's crash), the connection and any child process go with it.
    close_transport(state)
    Lifetime.cleanup(deadline)
    :ok
  end

  defp close_notification_listeners(state, reason) do
    NotificationListener.close_all(state.notification_listeners, reason)
    reset_notification_worker(state)
    %{state | notification_listeners: %{}, notification_listener_monitors: %{}}
  end

  # Process.alive?/1 raises for a pid on another node; a remote subscriber is
  # left to the monitor, which reports its death like any other.
  defp dead_local_process?(pid) when is_pid(pid),
    do: node(pid) == node() and not Process.alive?(pid)

  defp ensure_notification_worker(%{notification_worker: worker} = state) when is_pid(worker),
    do: state

  defp ensure_notification_worker(state) do
    {:ok, worker} = Worker.start(self())
    monitor = Process.monitor(worker)
    %{state | notification_worker: worker, notification_worker_monitor: monitor}
  end

  defp reset_notification_worker(%{notification_worker: worker}) when is_pid(worker),
    do: Worker.reset(worker)

  defp reset_notification_worker(_state), do: :ok

  # Listeners survive a reconnect. Once the connection is ready again, the
  # server has forgotten every legacy resource subscription, so the worker
  # re-issues them and reports back for the listeners that existed at this
  # moment, tagged with this connection's generation. A peer that came back
  # modern cannot serve legacy listeners at all.
  defp resubscribe_notification_listeners(%{notification_listeners: listeners} = state)
       when map_size(listeners) == 0,
       do: state

  defp resubscribe_notification_listeners(state) do
    cond do
      VersionRegistry.modern?(state.protocol_version) ->
        close_notification_listeners(state, {:era_changed, :modern})

      is_pid(state.notification_worker) ->
        generation = state.notification_listener_generation + 1
        listener_ids = Map.keys(state.notification_listeners)

        Worker.resubscribe(
          state.notification_worker,
          listener_ids,
          generation,
          state.default_timeout || 5_000
        )

        %{state | notification_listener_generation: generation}

      true ->
        state
    end
  end

  defp reconnect_allowed?(state, previous_status) do
    state.reconnect_enabled == true and
      state.manual_disconnect != true and
      previous_status == :ready and
      state.reconnect_attempts < state.max_reconnect_attempts
  end

  defp schedule_reconnect(state) do
    attempt = state.reconnect_attempts + 1
    delay = reconnect_delay(state.reconnect_backoff, attempt)
    timer = Process.send_after(self(), :attempt_reconnect, delay)

    :telemetry.execute(
      [:arbor_mcp, :client, :reconnect, :attempt],
      %{attempt: attempt, delay_ms: delay},
      %{transport: configured_transport(state), pid: self()}
    )

    Logger.info("Scheduling MCP reconnection attempt #{attempt} in #{delay}ms")

    %{
      state
      | connection_status: :reconnecting,
        reconnect_attempts: attempt,
        reconnect_timer: timer
    }
  end

  defp attempt_reconnect(state) do
    attempt = state.reconnect_attempts

    case ConnectionManager.establish_connection(state, reconnect_opts(state)) do
      {:ok, connected_state} ->
        :telemetry.execute(
          [:arbor_mcp, :client, :reconnect, :success],
          %{attempt: attempt},
          %{transport: connected_state.transport_mod, pid: self()}
        )

        :telemetry.execute(
          [:arbor_mcp, :client, :connected],
          %{},
          %{transport: connected_state.transport_mod}
        )

        reconnected_state =
          schedule_next_health_check(%{
            connected_state
            | connection_status: :ready,
              initialized: true,
              reconnect_attempts: 0,
              cleanup_result: :ok,
              health_check_id: nil
          })

        notify_subscription_processes(reconnected_state, :client_subscription_reconnect)
        resubscribe_notification_listeners(reconnected_state)

      {:error, reason} ->
        :telemetry.execute(
          [:arbor_mcp, :client, :reconnect, :error],
          %{attempt: attempt},
          %{reason: reason, transport: configured_transport(state), pid: self()}
        )

        handle_reconnect_failure(state, reason)
    end
  end

  defp handle_reconnect_failure(state, reason) do
    if state.reconnect_attempts < state.max_reconnect_attempts do
      schedule_reconnect(state)
    else
      :telemetry.execute(
        [:arbor_mcp, :client, :reconnect, :timeout],
        %{attempt: state.reconnect_attempts},
        %{
          max_attempts: state.max_reconnect_attempts,
          reason: reason,
          transport: configured_transport(state),
          pid: self()
        }
      )

      Logger.error("Giving up on reconnection after #{state.reconnect_attempts} attempts",
        reason: LogSummary.describe(reason)
      )

      close_notification_listeners(
        %{state | connection_status: :disconnected},
        {:reconnect_exhausted, reason}
      )
    end
  end

  # Each reconnection attempt is a single try; the reconnect scheduler owns
  # retry/backoff, so disable the nested connection retry policy.
  defp reconnect_opts(state) do
    Keyword.put(state.transport_opts, :retry_policy, [])
  end

  defp reconnect_delay(%{initial: initial, max: max, multiplier: multiplier}, attempt) do
    base = min(round(initial * :math.pow(multiplier, attempt - 1)), max)
    add_reconnect_jitter(base)
  end

  # +/-25% jitter (same policy as Arbor.MCP.Reliability.Retry) to avoid
  # synchronized reconnection storms.
  defp add_reconnect_jitter(delay) do
    jitter_range = div(delay, 4)

    if jitter_range > 0 do
      delay + :rand.uniform(jitter_range * 2) - jitter_range
    else
      delay
    end
  end

  defp configured_transport(state) do
    Keyword.get(state.transport_opts, :transport) ||
      Keyword.get(state.transport_opts, :transports)
  end

  # Idle health check
  #
  # Every `:health_check_interval` a connected and *idle* client sends a
  # protocol `ping`. If the previous ping is still unanswered a full interval
  # later, the connection is treated as closed, which fails pending requests
  # and hands over to the reconnection path.
  #
  # The check is skipped while requests are in flight: those are themselves
  # proof of liveness, and a ping queued behind a long-running tool call on a
  # single-threaded server would otherwise look like a dead connection.
  defp perform_health_check(%{connection_status: :ready} = state) do
    cond do
      map_size(state.pending_requests) > 0 ->
        schedule_next_health_check(%{state | health_check_id: nil})

      state.health_check_id != nil ->
        Logger.warning("MCP health check ping unanswered; treating transport as closed")
        state = %{state | health_check_id: nil, health_check_ref: nil}
        handle_transport_down(:health_check_timeout, state)

      true ->
        state
        |> send_health_ping()
        |> schedule_next_health_check()
    end
  end

  # Not connected: drop the timer. It is re-armed once the client is ready
  # again (initial connection or successful reconnection).
  defp perform_health_check(state) do
    %{state | health_check_id: nil, health_check_ref: nil}
  end

  defp send_health_ping(state) do
    case RequestHandler.send_ping(state) do
      {:ok, request_id, new_state} ->
        %{new_state | health_check_id: request_id}

      {:error, reason} ->
        Logger.debug("MCP health check ping could not be sent",
          reason: LogSummary.describe(reason)
        )

        %{state | health_check_id: nil}
    end
  end

  # Stateless request/response transports (non-SSE HTTP) have no receiver and
  # no persistent connection to monitor — every request opens its own — so a
  # periodic ping would only add a blocking POST to the client loop.
  defp schedule_next_health_check(%{receiver_task: nil} = state) do
    %{state | health_check_ref: nil}
  end

  defp schedule_next_health_check(%{health_check_interval: interval} = state)
       when is_integer(interval) and interval > 0 do
    cancel_health_check_timer(state)
    %{state | health_check_ref: Process.send_after(self(), :health_check, interval)}
  end

  defp schedule_next_health_check(state), do: %{state | health_check_ref: nil}

  defp cancel_health_check_timer(%{health_check_ref: ref}) when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp cancel_health_check_timer(_state), do: :ok

  # Private functions (some exposed for testing)

  @doc false
  def parse_connection_spec(spec) do
    do_parse_connection_spec(spec)
  catch
    :throw, {:transport_config_error, reason} ->
      {:error, {:invalid_transport_config, reason}}
  end

  @doc false
  def prepare_transport_config(opts), do: ConnectionManager.prepare_transport_config(opts)

  # Delegate to ConnectionManager for consistent transport spec normalization
  defp normalize_transport_spec(transport_spec, opts) do
    case ConnectionManager.prepare_transport_config([transport: transport_spec] ++ opts) do
      {:ok, [transports: [normalized_spec]]} -> normalized_spec
      {:error, reason} -> throw({:transport_config_error, reason})
    end
  end

  defp do_parse_connection_spec(url) when is_binary(url) do
    uri = URI.parse(url)

    case uri.scheme do
      "http" -> [transport: :http, url: url]
      "https" -> [transport: :http, url: url]
      "stdio" -> [transport: :stdio, command: uri.path || uri.host]
      "file" -> [transport: :stdio, command: uri.path]
      _ -> [transport: :http, url: url]
    end
  end

  defp do_parse_connection_spec({transport, opts}) do
    [transport: transport] ++ opts
  end

  defp do_parse_connection_spec(specs) when is_list(specs) do
    transports =
      Enum.map(specs, fn
        url when is_binary(url) ->
          opts = do_parse_connection_spec(url)
          transport_atom = Keyword.fetch!(opts, :transport)
          normalize_transport_spec(transport_atom, opts)

        {transport, opts} ->
          normalize_transport_spec(transport, opts)
      end)

    [transports: transports]
  end

  defp build_client_info do
    VersionInfo.client_info()
  end

  defp format_response(response, :struct, opts) do
    # Use the proper Response.from_raw_response/2 constructor
    response_opts = [
      tool_name: Keyword.get(opts, :tool_name),
      request_id: Keyword.get(opts, :request_id),
      server_info: Keyword.get(opts, :server_info)
    ]

    structured_response = Response.from_raw_response(response, response_opts)
    {:ok, structured_response}
  end

  # Issues a single GenServer.call per request in the common path. Default
  # timeout and retry policy are resolved by the client process from its own
  # state instead of dedicated pre-flight calls:
  #
  # - Explicit :timeout opts are enforced caller-side via the GenServer.call
  #   timeout (explicit opts win).
  # - Without an explicit timeout, the client process schedules its own
  #   default-timeout timer for the request and replies {:error, :timeout};
  #   the call itself waits without a caller-side deadline (the call monitor
  #   still detects a dead client).
  # - The default retry policy is only fetched (one extra call) after a
  #   failed first attempt, so successful requests never pay for it.
  @doc false
  @spec make_request(t(), String.t(), map(), keyword(), pos_integer()) ::
          {:ok, any()} | {:error, any()}
  def make_request(client, method, params, opts, default_timeout) do
    stream_retry_mode = Keyword.get(opts, :http_stream_retry, :at_least_once)

    case validate_http_stream_retry_mode(client, stream_retry_mode) do
      :ok ->
        do_make_request(
          client,
          method,
          params,
          opts,
          default_timeout,
          stream_retry_mode
        )

      {:error, _reason} = error ->
        handle_request_result(error, opts)
    end
  end

  defp do_make_request(client, method, params, opts, default_timeout, stream_retry_mode) do
    started_at = System.monotonic_time(:millisecond)
    explicit_timeout = Keyword.get(opts, :timeout)
    retry_policy = Keyword.get(opts, :retry_policy, :use_default)
    scope_ref = make_ref()

    result =
      if explicit_timeout do
        deadline = started_at + explicit_timeout

        control = %{
          deadline: deadline,
          scope_ref: scope_ref,
          stream_retry_mode: stream_retry_mode
        }

        do_mrtr_request(
          client,
          method,
          params,
          params,
          opts,
          retry_policy,
          0,
          control
        )
      else
        first_operation = fn -> request_once(client, method, params, nil) end

        retry_operation = fn ->
          deadline = started_at + fetch_default_timeout(client, default_timeout)

          with {:ok, remaining} <- remaining_timeout(deadline) do
            request_once(client, method, params, remaining)
          end
        end

        case execute_with_stream_retry(
               first_operation,
               retry_operation,
               client,
               retry_policy,
               method,
               opts,
               stream_retry_mode,
               fn -> started_at + fetch_default_timeout(client, default_timeout) end
             ) do
          {:ok, result} = complete_or_extension ->
            if MRTR.input_required?(result) do
              deadline = started_at + fetch_default_timeout(client)

              control = %{
                deadline: deadline,
                scope_ref: scope_ref,
                stream_retry_mode: stream_retry_mode
              }

              continue_mrtr(
                client,
                method,
                params,
                result,
                opts,
                retry_policy,
                0,
                control
              )
            else
              complete_or_extension
            end

          other ->
            other
        end
      end

    if result == {:error, :timeout},
      do: GenServer.cast(client, {:cancel_mrtr_scope, scope_ref})

    handle_request_result(result, opts)
  end

  defp do_mrtr_request(
         client,
         method,
         original_params,
         round_params,
         opts,
         retry_policy,
         round,
         control
       ) do
    operation = fn ->
      with {:ok, remaining} <- remaining_timeout(control.deadline) do
        request_once(client, method, round_params, remaining)
      end
    end

    case execute_with_stream_retry(
           operation,
           operation,
           client,
           retry_policy,
           method,
           opts,
           control.stream_retry_mode,
           fn -> control.deadline end
         ) do
      {:ok, result} = complete_or_extension ->
        if MRTR.input_required?(result) do
          continue_mrtr(
            client,
            method,
            original_params,
            result,
            opts,
            retry_policy,
            round,
            control
          )
        else
          complete_or_extension
        end

      other ->
        other
    end
  end

  defp continue_mrtr(
         client,
         method,
         original_params,
         result,
         opts,
         retry_policy,
         round,
         control
       ) do
    maximum = Keyword.get(opts, :max_mrtr_rounds, @default_max_mrtr_rounds)

    outcome =
      if round >= maximum do
        {:error,
         Error.protocol_error(
           ErrorCodes.invalid_params(),
           "MRTR round limit exceeded",
           %{"maximum" => maximum}
         )}
      else
        with {:ok, input_requests, request_state} <- MRTR.validate_result(method, result, opts),
             {:ok, remaining} <- remaining_timeout(control.deadline),
             {:ok, input_responses} <-
               fulfill_mrtr(client, input_requests, opts, remaining, control.scope_ref) do
          next_round = round + 1

          :telemetry.execute(
            [:arbor_mcp, :client, :mrtr, :round],
            %{round: next_round, input_requests: map_size(input_requests)},
            %{method: mrtr_method_class(method)}
          )

          retry_params = MRTR.retry_params(original_params, input_responses, request_state)

          do_mrtr_request(
            client,
            method,
            original_params,
            retry_params,
            opts,
            retry_policy,
            next_round,
            control
          )
        end
      end

    case outcome do
      {:error, reason} = error ->
        :telemetry.execute(
          [:arbor_mcp, :client, :mrtr, :failure],
          %{round: round},
          %{
            method: mrtr_method_class(method),
            reason: client_mrtr_failure_class(reason, round, maximum)
          }
        )

        error

      other ->
        other
    end
  end

  defp mrtr_method_class(method) when method in ["tools/call", "resources/read", "prompts/get"],
    do: method

  defp mrtr_method_class(_method), do: :unknown

  defp client_mrtr_failure_class(_reason, round, maximum) when round >= maximum,
    do: :round_limit

  defp client_mrtr_failure_class(:timeout, _round, _maximum), do: :timeout

  defp client_mrtr_failure_class(%Error.ProtocolError{code: -32_021}, _round, _maximum),
    do: :missing_capability

  defp client_mrtr_failure_class(%Error.ProtocolError{}, _round, _maximum),
    do: :protocol_error

  defp client_mrtr_failure_class(_reason, _round, _maximum), do: :input_fulfillment_failed

  # The absolute deadline travels with the request so the client does not
  # send it after the caller has given up (see RequestHandler.handle_request/5).
  defp request_once(client, method, params, timeout) when is_integer(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    meta = %{timeout: timeout, deadline: deadline}
    GenServer.call(client, {:request, method, params, meta}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  defp request_once(client, method, params, nil) do
    GenServer.call(client, {:request, method, params, %{timeout: nil}}, :infinity)
  end

  defp fulfill_mrtr(client, input_requests, opts, timeout, scope_ref) do
    GenServer.call(client, {:fulfill_mrtr, input_requests, opts, scope_ref}, timeout)
  catch
    :exit, {:timeout, _} ->
      GenServer.cast(client, {:cancel_mrtr_scope, scope_ref})
      {:error, :timeout}
  end

  defp remaining_timeout(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> {:ok, remaining}
      _expired -> {:error, :timeout}
    end
  end

  defp execute_with_retry_policy(operation, client, retry_policy) do
    case retry_policy do
      :use_default ->
        execute_with_lazy_default_retry(operation, client)

      false ->
        operation.()

      [] ->
        operation.()

      policy when is_list(policy) ->
        Retry.with_retry(operation, Retry.mcp_defaults(policy))
    end
  end

  defp execute_with_stream_retry(
         operation,
         retry_operation,
         client,
         retry_policy,
         method,
         opts,
         stream_retry_mode,
         deadline_fun
       ) do
    operation
    |> execute_with_retry_policy(client, retry_policy)
    |> maybe_retry_broken_stream(
      retry_operation,
      method,
      opts,
      stream_retry_mode,
      deadline_fun
    )
  end

  defp maybe_retry_broken_stream(
         {:error, %Error.TransportError{reason: :response_stream_broken} = error},
         retry_operation,
         method,
         opts,
         stream_retry_mode,
         deadline_fun
       ) do
    if stream_retry_allowed?(stream_retry_mode, method, opts) do
      delay = http_stream_retry_delay(opts)
      deadline = deadline_fun.()

      case wait_for_stream_retry(delay, deadline) do
        :ok ->
          :telemetry.execute(
            [:arbor_mcp, :client, :http, :request, :retry],
            %{attempt: 2},
            %{method: method, mode: stream_retry_mode, delivery: :at_least_once}
          )

          case retry_operation.() do
            {:error, %Error.TransportError{reason: :response_stream_broken} = second_error} ->
              outcome_unknown(method, stream_retry_mode, 2, second_error)

            result ->
              result
          end

        {:error, :timeout} ->
          {:error, :timeout}
      end
    else
      outcome_unknown(method, stream_retry_mode, 1, error)
    end
  end

  defp maybe_retry_broken_stream(result, _retry, _method, _opts, _mode, _deadline),
    do: result

  defp stream_retry_allowed?(:at_least_once, _method, _opts), do: true

  defp stream_retry_allowed?(:safe_only, method, opts) do
    intrinsically_safe_method?(method) or Keyword.get(opts, :retry_safe, false) == true
  end

  defp intrinsically_safe_method?(method) do
    method in [
      "server/discover",
      "tools/list",
      "resources/list",
      "resources/templates/list",
      "resources/read",
      "prompts/list",
      "prompts/get",
      "completion/complete"
    ]
  end

  defp http_stream_retry_delay(opts) do
    case Keyword.get(opts, :http_stream_retry_delay, 200) do
      delay when is_integer(delay) and delay >= 0 -> delay
      _invalid -> 200
    end
  end

  defp wait_for_stream_retry(delay, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > delay ->
        if delay > 0, do: Process.sleep(delay)
        :ok

      _expired ->
        {:error, :timeout}
    end
  end

  defp outcome_unknown(method, mode, attempts, error) do
    {:error,
     Error.transport_error(:http, :outcome_unknown, %{
       method: method,
       retry_mode: mode,
       attempts: attempts,
       cause: error.details,
       message:
         "The response stream broke after delivery; the server may have completed the request."
     })}
  end

  defp validate_http_stream_retry_mode(_client, :at_least_once), do: :ok

  defp validate_http_stream_retry_mode(client, :safe_only) do
    if conformance_mode?(client) do
      {:error,
       Error.validation_error(
         :http_stream_retry,
         :safe_only,
         "safe_only is non-conforming and unavailable in conformance mode"
       )}
    else
      :ok
    end
  end

  defp validate_http_stream_retry_mode(_client, mode) do
    {:error,
     Error.validation_error(
       :http_stream_retry,
       mode,
       "expected :at_least_once or :safe_only"
     )}
  end

  defp conformance_mode?(client) do
    GenServer.call(client, :conformance_mode?, 5_000) == true
  catch
    :exit, _reason -> false
  end

  # First attempt runs without any pre-flight calls; the client's default
  # retry policy is only fetched when that attempt fails.
  defp execute_with_lazy_default_retry(operation, client) do
    case operation.() do
      {:error, reason} = error ->
        retry_remaining_attempts(operation, client, reason, error)

      result ->
        result
    end
  end

  defp retry_remaining_attempts(operation, client, reason, original_error) do
    case fetch_default_retry_policy(client) do
      [] ->
        original_error

      policy ->
        retry_opts = Retry.mcp_defaults(policy)
        should_retry? = Keyword.fetch!(retry_opts, :should_retry?)
        max_attempts = Keyword.get(retry_opts, :max_attempts, 0)

        if max_attempts > 1 and should_retry?.(reason) do
          # The first attempt already ran; honor its backoff delay, then run
          # the remaining attempts through the shared retry infrastructure.
          Process.sleep(Retry.calculate_delay(1, retry_opts))
          Retry.with_retry(operation, Keyword.put(retry_opts, :max_attempts, max_attempts - 1))
        else
          original_error
        end
    end
  end

  defp fetch_default_retry_policy(client) do
    case GenServer.call(client, :get_default_retry_policy, 5_000) do
      {:ok, policy} when is_list(policy) -> policy
      _ -> []
    end
  catch
    :exit, _ -> []
  end

  defp fetch_default_timeout(client, fallback \\ 5_000) do
    case GenServer.call(client, :get_default_timeout, 5_000) do
      {:ok, timeout} when is_integer(timeout) and timeout > 0 -> timeout
      _other -> fallback
    end
  catch
    :exit, _reason -> fallback
  end

  defp handle_request_result({:ok, response}, opts) do
    case Keyword.get(opts, :format, :struct) do
      :map -> {:ok, response}
      format -> format_response(response, format, opts)
    end
  end

  defp handle_request_result({:error, %{__struct__: mod}} = error, _opts)
       when mod in [
              Error.ProtocolError,
              Error.TransportError,
              Error.ToolError,
              Error.ResourceError,
              Error.ValidationError
            ] do
    # Already an Arbor.MCP.Error struct, return as-is
    error
  end

  # A failed send carries the transport's reason as a term. The :map format
  # keeps the map (with its message text); :struct gives a TransportError.
  defp handle_request_result({:error, %{type: :transport_error, reason: reason} = error}, opts) do
    case Keyword.get(opts, :format, :struct) do
      :map ->
        {:error, error}

      _struct ->
        {:error,
         Error.transport_error(Map.get(error, :transport), reason, %{
           message: Map.get(error, :message)
         })}
    end
  end

  defp handle_request_result({:error, error_data}, opts) when is_map(error_data) do
    case Keyword.get(opts, :format, :struct) do
      :map ->
        # Return error data as map when format is :map
        {:error, error_data}

      _ ->
        # Convert JSON-RPC errors to ProtocolError for client responses
        code = Map.get(error_data, "code")
        message = Map.get(error_data, "message", "Unknown error")
        data = Map.get(error_data, "data")

        # For JSON-RPC standard errors, return ProtocolError
        error_struct =
          if code && code >= -32768 && code <= -32000 do
            %Error.ProtocolError{
              code: code,
              message: message,
              data: data
            }
          else
            # For non-standard errors, use the helper function for compatibility
            Error.from_json_rpc_error(error_data, request_id: Keyword.get(opts, :request_id))
          end

        {:error, error_struct}
    end
  end

  defp handle_request_result({:error, :not_connected}, _opts) do
    # Preserve :not_connected atom for backward compatibility
    {:error, :not_connected}
  end

  defp handle_request_result({:error, :timeout}, opts) do
    case Keyword.get(opts, :format, :struct) do
      :map ->
        # Return timeout as atom when format is :map
        {:error, :timeout}

      _ ->
        # Convert timeout to proper Arbor.MCP.Error
        {:error,
         %Error.ProtocolError{
           code: -32603,
           message: "Request timeout",
           data: nil
         }}
    end
  end

  defp handle_request_result(error, _opts), do: error

  @doc """
  Requests completion suggestions from the server.

  Sends a `completion/complete` request to get completion suggestions based on
  a reference (prompt or resource) and partial input.

  ## Parameters

  - `client` - Client process reference
  - `ref` - Reference map describing what to complete:
    - For prompts: `%{"type" => "ref/prompt", "name" => "prompt_name"}`
    - For resources: `%{"type" => "ref/resource", "uri" => "resource_uri"}`
  - `argument` - Argument map with completion context:
    - `%{"name" => "argument_name", "value" => "partial_value"}`

  ## Options

  - `:timeout` - Request timeout (default: 5000)
  - `:format` - Return format (:map or :struct, default: :struct)

  ## Returns

  - `{:ok, result}` - Success with completion suggestions:
    ```
    %{
      completion: %{
        values: ["suggestion1", "suggestion2", ...],
        total: 10,
        hasMore: false
      }
    }
    ```
  - `{:error, error}` - Request failed with error details

  ## Examples

      # Complete prompt argument
      {:ok, result} = Arbor.MCP.Client.complete(
        client,
        %{"type" => "ref/prompt", "name" => "code_generator"},
        %{"name" => "language", "value" => "java"}
      )

      # Complete resource URI
      {:ok, result} = Arbor.MCP.Client.complete(
        client,
        %{"type" => "ref/resource", "uri" => "file:///"},
        %{"name" => "path", "value" => "/src"}
      )
  """
  @spec complete(t(), map(), map(), keyword()) :: {:ok, map()} | {:error, any()}
  def complete(client, ref, argument, opts \\ []) do
    params =
      ref
      |> RequestParams.completion(argument)
      |> RequestParams.with_opts_meta(opts)

    make_request(client, "completion/complete", params, opts, 5_000)
  end

  @doc """
  Sets the log level for the server.

  Sends a `logging/setLevel` request to configure the server's log verbosity.
  This is part of the MCP specification for controlling server logging behavior.

  MCP protocol Logging is deprecated as of 2026-07-28 and available in
  Arbor.MCP 2.x for pinned legacy protocol revisions. This legacy RPC remains available for compatible peers. Prefer
  stderr for stdio or OpenTelemetry for new observability integrations.

  ## Parameters

  - `client` - Client process reference
  - `level` - Log level string: "debug", "info", "warning", or "error"

  ## Returns

  - `{:ok, result}` - Success with any server response data
  - `{:error, error}` - Request failed with error details

  ## Example

      {:ok, client} = Arbor.MCP.Client.start_link(transport: :http, url: "...")
      {:ok, _} = Arbor.MCP.Client.set_log_level(client, "debug")
  """
  @spec set_log_level(GenServer.server(), String.t()) :: {:ok, map()} | {:error, any()}
  def set_log_level(client, level) when is_binary(level) do
    params = %{"level" => level}

    case make_request(client, "logging/setLevel", params, [], 30_000) do
      {:ok, response} -> {:ok, response}
      error -> error
    end
  end

  @doc """
  Sends a log message to the server as a notification.

  This function sends log messages from the client to the server for centralized
  logging and monitoring. The message is sent as a notification (fire-and-forget)
  following the MCP specification.

  MCP protocol Logging is deprecated as of 2026-07-28 and available in
  Arbor.MCP 2.x for pinned legacy protocol revisions. Prefer stderr for stdio or OpenTelemetry for new observability
  integrations.

  ## Parameters

  - `client` - Client process reference
  - `level` - Log level string (e.g., "debug", "info", "warning", "error")
  - `message` - Log message text

  ## Returns

  - `:ok` - Message sent successfully
  - `{:error, reason}` - Failed to send message

  ## Example

      {:ok, client} = Arbor.MCP.Client.start_link(transport: :http, url: "...")
      :ok = Arbor.MCP.Client.log_message(client, "info", "Operation completed")
  """
  @spec log_message(t(), String.t(), String.t()) :: :ok | {:error, any()}
  def log_message(client, level, message) when is_binary(level) and is_binary(message) do
    log_message(client, level, message, nil)
  end

  @doc """
  Sends a log message with additional data to the server as a notification.

  This function sends detailed log messages from the client to the server for
  centralized logging and monitoring. The message is sent as a notification
  (fire-and-forget) following the MCP specification.

  MCP protocol Logging is deprecated as of 2026-07-28 and available in
  Arbor.MCP 2.x for pinned legacy protocol revisions. Prefer stderr for stdio or OpenTelemetry for new observability
  integrations.

  ## Parameters

  - `client` - Client process reference
  - `level` - Log level string (e.g., "debug", "info", "warning", "error")
  - `message` - Log message text
  - `data` - Optional additional data (map or any JSON-serializable value)

  ## Supported Log Levels

  Standard RFC 5424 levels: "debug", "info", "notice", "warning", "error",
  "critical", "alert", "emergency"

  ## Returns

  - `:ok` - Message sent successfully
  - `{:error, reason}` - Failed to send message

  ## Examples

      {:ok, client} = Arbor.MCP.Client.start_link(transport: :http, url: "...")

      # Simple log message
      :ok = Arbor.MCP.Client.log_message(client, "info", "User logged in")

      # Log message with additional context
      :ok = Arbor.MCP.Client.log_message(client, "error", "Database connection failed", %{
        host: "db.example.com",
        port: 5432,
        error_code: "CONNECTION_TIMEOUT"
      })
  """
  @spec log_message(t(), String.t(), String.t(), any()) :: :ok | {:error, any()}
  def log_message(client, level, message, data) when is_binary(level) and is_binary(message) do
    GenServer.cast(
      client,
      {:notification, "notifications/message",
       %{
         "level" => level,
         "message" => message,
         "data" => data
       }}
    )
  end

  @doc """
  Finds a matching tool from a list of tools.

  ## Parameters

  - `tools` - List of tool maps
  - `name` - Tool name to find (exact match) or pattern (fuzzy match)
  - `opts` - Options including :fuzzy for fuzzy matching

  ## Examples

      tools = [%{"name" => "calculator"}, %{"name" => "weather"}]
      {:ok, tool} = Arbor.MCP.Client.find_matching_tool(tools, "calculator", [])
      {:ok, tool} = Arbor.MCP.Client.find_matching_tool(tools, "calc", fuzzy: true)
  """
  @spec find_matching_tool(list(map()), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, :not_found}
  def find_matching_tool(tools, name, opts \\ [])

  def find_matching_tool(tools, nil, _opts) when is_list(tools) do
    case List.first(tools) do
      nil -> {:error, :not_found}
      tool -> {:ok, tool}
    end
  end

  def find_matching_tool(tools, name, opts) when is_list(tools) and is_binary(name) do
    fuzzy? = Keyword.get(opts, :fuzzy, false)

    # Try exact match first
    case Enum.find(tools, fn tool -> tool["name"] == name end) do
      nil when fuzzy? ->
        # Try fuzzy match
        case Enum.find(tools, fn tool -> String.contains?(tool["name"], name) end) do
          nil -> {:error, :not_found}
          tool -> {:ok, tool}
        end

      nil ->
        {:error, :not_found}

      tool ->
        {:ok, tool}
    end
  end
end

defimpl Inspect, for: Arbor.MCP.Client do
  # The connection's credentials never print; see Arbor.MCP.Internal.Redaction.
  def inspect(client, opts),
    do: Inspect.Any.inspect(Arbor.MCP.Internal.Redaction.client(client), opts)
end
