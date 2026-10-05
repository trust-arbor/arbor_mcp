defmodule Arbor.MCP.HttpPlug do
  @moduledoc """
  HTTP Plug for MCP (Model Context Protocol) requests.
  Compatible with Phoenix and Cowboy servers.

  This plug provides Streamable HTTP transport for MCP servers, allowing
  integration with standard Elixir web applications. Modern SSE responses are
  owned by the POST request that opened them and require no transport flag.

  The deprecated MCP 2024-11-05 HTTP+SSE transport remains available throughout
  Arbor.MCP 1.x by explicitly setting `legacy_http_sse: true`. The rc.5
  `sse_enabled: true` option remains an alias for compatibility. New servers do
  not enable this deprecated transport by default.

  ## Runtime mounts and request context

  Start one `Arbor.MCP.Server.Runtime` under the application's supervision tree
  and mount this plug with `runtime: MyApp.MCPRuntime`. The runtime initializes
  its handler once from `Runtime.handler_args`; every POST uses that same
  scheduler and handler state.

  On a runtime mount, `:handler_opts` supplies per-request application context,
  available as `Arbor.MCP.Server.Context.current().application_context`. It may
  be a static term, a one-arity function called with the `Plug.Conn`, a two-arity
  function called with the connection and decoded JSON-RPC request, or an
  `{module, function, extra_args}` tuple called with `[conn, request | extra_args]`.
  The context is charged before dispatch. Resolution and validation cannot
  extend the original HTTP entry deadline. Configure the runtime's
  `:request_timeout_ms` for work lifetime.

  ## Usage

      # In the host application's supervision tree
      {Arbor.MCP.Server.Runtime,
       name: MyApp.MCPRuntime, handler: MyApp.MCPServer, handler_args: []}

      # Borrow the host listener and mount the existing runtime
      {:ok, _} = Plug.Cowboy.http(Arbor.MCP.HttpPlug,
        [runtime: MyApp.MCPRuntime, path: "/mcp"], port: 4000)

      # With Phoenix (router)
      scope "/api" do
        forward "/mcp", Arbor.MCP.HttpPlug,
          runtime: MyApp.MCPRuntime, path: "/mcp"
      end

  The plug answers every request it receives and halts the connection
  afterwards, so mount it with `forward` (or behind your own path match when
  placing it directly in an endpoint) rather than as an unconditional endpoint
  plug. Routing is relative to the mount point: the MCP endpoint is the mount
  root, and the RFC 9728 `/.well-known/oauth-protected-resource` metadata is
  served under the mount. A router forward at `/api/mcp` therefore never sees
  the host-root form that clients fetch
  (`/.well-known/oauth-protected-resource/api/mcp`); mount
  `Arbor.MCP.Plugs.ProtectedResourceMetadata` at the host root to serve it.

  ## OAuth 2.1 Integration

  To enable OAuth 2.1 bearer token validation:

      plug Arbor.MCP.HttpPlug,
        runtime: MyApp.MCPRuntime,
        oauth_enabled: true,
        resource: "https://mcp.example.com/mcp",
        authorization_servers: ["https://auth.example.com"],
        auth_config: %{
          introspection_endpoint: "https://auth.example.com/introspect",
          realm: "my-mcp-server" # Optional, defaults to server_info.name
        }

  ## Security

  ### Origin validation (`:validate_origin`, `:allowed_origins`)

  With `validate_origin: true` (the default), any request carrying an
  `Origin` header is rejected with `403` unless the origin is listed in
  `:allowed_origins` (or `:allowed_origins` is `:any`). There is no
  "same origin as the Host header" fallback: in a DNS rebinding attack the
  Host header is attacker-controlled, so such a comparison would always pass.

  Requests **without** an `Origin` header are allowed. Non-browser clients
  (CLIs, SDKs, server-to-server callers) do not send the header; use
  `:allowed_hosts` to protect them against DNS rebinding.

  ### Host validation (`:allowed_hosts`)

  `:allowed_hosts` is either `:any` (default, no restriction) or a list of
  hostnames. When a list is given, requests whose `Host` header does not
  match an entry are rejected with `421` before any processing. Ports are
  ignored and IPv6 hosts match with or without brackets, so
  `allowed_hosts: ["localhost", "127.0.0.1", "[::1]", "::1"]` accepts
  `localhost:4000` and `[::1]:8080`. Servers started via
  `Arbor.MCP.Server.Transport` with a localhost bind get this allow-list by
  default.

  ### Deprecated HTTP+SSE (`:legacy_http_sse`, `:sse_mode`)

  `:legacy_http_sse` explicitly enables the standalone GET transport used by
  legacy MCP revisions. It defaults to `false`. `:sse_enabled` is a retained
  1.x alias and is planned for removal in Arbor.MCP 2.0.

  `:sse_mode` is `:stream` (default) or `:oneshot`. `:stream` starts an
  `Arbor.MCP.HttpPlug.SSEHandler` and holds the request open for the lifetime of
  the stream; `:oneshot` writes a single `connected` event and returns, which
  suits test harnesses and health checks.

  MCP 2026-07-28 does not use that GET stream. A modern
  `subscriptions/listen` POST owns its SSE response directly. The response
  process closes its registry entry when the client disconnects and emits SSE
  comment keepalives every `:subscription_keepalive_interval_ms` milliseconds
  (default: `15_000`; set `:infinity` to disable).

  An ordinary modern request that opts into progress or request logs also owns
  its POST response stream. `notifications/progress` and
  `notifications/message` are written only there, followed by one final
  JSON-RPC response that closes the stream. A disconnect or chunk failure
  cancels that request's worker without affecting other
  requests or subscriptions.

  ### Session ids

  Session IDs are issued by the server. Client-supplied `mcp-session-id` (and
  legacy `x-session-id`) header values are validated and must identify an
  existing session bound to the same authorization identity. Values are at
  most 128 bytes from the character set
  `A-Z a-z 0-9 . _ ~ + / = -` (covering UUIDs and base64/base64url tokens).
  Invalid values are rejected with a `400` JSON-RPC error and are never
  echoed back.
  """

  @behaviour Plug

  import Plug.Conn, except: [send_resp: 3, send_chunked: 2, chunk: 2]
  require Logger

  alias Arbor.MCP.Authorization.AuthorizationServerMetadata
  alias Arbor.MCP.Authorization.ScopeValidator
  alias Arbor.MCP.Authorization.ServerGuard
  alias Arbor.MCP.Error.ProtocolError
  alias Arbor.MCP.FeatureFlags
  alias Arbor.MCP.HttpPlug.Core
  alias Arbor.MCP.HttpPlug.ModernStream
  alias Arbor.MCP.HttpPlug.RequestStream
  alias Arbor.MCP.HttpPlug.RuntimeSession
  alias Arbor.MCP.HttpPlug.RuntimeSessionStream
  alias Arbor.MCP.HttpPlug.RuntimeWriter
  alias Arbor.MCP.HttpPlug.SessionRegistry
  alias Arbor.MCP.HttpPlug.SSEHandler
  alias Arbor.MCP.Internal.{MessageValidator, VersionRegistry}
  alias Arbor.MCP.Plugs.ProtectedResourceMetadata
  alias Arbor.MCP.Protocol.{ErrorCodes, Methods}
  alias Arbor.MCP.Server.{RequestContext, Subscriptions}
  alias Arbor.MCP.Server.Runtime.{HTTPGateway, HTTPWriterBinding, HTTPWriterRegistry, OutputCodec}
  alias Arbor.MCP.Transport.HTTP.RequestHeaders
  alias Arbor.RPC.{JSONRPC, LogSummary}

  @session_id_max_bytes 128

  @deprecated "The session table is owned by Arbor.MCP.HttpPlug.SessionRegistry, started with the :arbor_mcp application"
  def start_link(opts \\ []) do
    case SessionRegistry.start_link(opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc """
  Initializes the plug with configuration options.
  """
  @impl Plug
  def init(opts) do
    validate_mrtr_configuration!(opts)
    protected_resource_metadata = protected_resource_metadata!(opts)

    legacy_http_sse =
      Keyword.get(opts, :legacy_http_sse, Keyword.get(opts, :sse_enabled, false))

    %{
      runtime: Keyword.get(opts, :runtime),
      handler: Keyword.get(opts, :handler),
      handler_opts: Keyword.get(opts, :handler_opts, []),
      handler_call_timeout: Keyword.get(opts, :handler_call_timeout, 10_000),
      server_info: Keyword.get(opts, :server_info, %{name: "ex_mcp_server", version: "1.0.0"}),
      server_capabilities: Keyword.get(opts, :server_capabilities),
      protocol_mode: Keyword.get(opts, :protocol_mode),
      instructions: Keyword.get(opts, :instructions),
      request_state: Keyword.get(opts, :request_state),
      endpoint: Keyword.get(opts, :path, "/mcp"),
      max_input_requests: Keyword.get(opts, :max_input_requests, 16),
      max_mrtr_bytes: Keyword.get(opts, :max_mrtr_bytes, 1_048_576),
      replay_cache: Keyword.get(opts, :replay_cache),
      require_replay_protection: Keyword.get(opts, :require_replay_protection, false),
      principal_id: Keyword.get(opts, :principal_id),
      tenant_id: Keyword.get(opts, :tenant_id),
      subscription_registry: Keyword.get(opts, :subscription_registry),
      authorize_subscription_filter: Keyword.get(opts, :authorize_subscription_filter),
      authorize_subscription_publication: Keyword.get(opts, :authorize_subscription_publication),
      subscription_max_queue: Keyword.get(opts, :subscription_max_queue),
      subscription_max_message_bytes: Keyword.get(opts, :subscription_max_message_bytes),
      subscription_max_queue_bytes: Keyword.get(opts, :subscription_max_queue_bytes),
      subscription_max_lifetime_ms: Keyword.get(opts, :subscription_max_lifetime_ms),
      subscription_keepalive_interval_ms:
        subscription_keepalive_interval!(
          Keyword.get(opts, :subscription_keepalive_interval_ms, 15_000)
        ),
      session_manager: Keyword.get(opts, :session_manager, Arbor.MCP.SessionManager),
      # Keep the rc.5 field so callers that inspect initialized Plug options do
      # not lose public shape during 1.x.
      sse_enabled: legacy_http_sse,
      legacy_http_sse: legacy_http_sse,
      legacy_http_sse_path:
        normalize_legacy_http_sse_path(Keyword.get(opts, :legacy_http_sse_path, "/sse")),
      legacy_http_sse_post_path:
        normalize_legacy_http_sse_path(Keyword.get(opts, :legacy_http_sse_post_path, "/message")),
      sse_mode: Keyword.get(opts, :sse_mode, default_sse_mode()),
      cors_enabled: Keyword.get(opts, :cors_enabled, false),
      allowed_origins: Keyword.get(opts, :allowed_origins, []),
      allowed_hosts: Keyword.get(opts, :allowed_hosts, :any),
      validate_origin: Keyword.get(opts, :validate_origin, true),
      body_limit: Keyword.get(opts, :body_limit, 1_000_000),
      oauth_enabled: Keyword.get(opts, :oauth_enabled, false),
      auth_config: Keyword.get(opts, :auth_config, %{}),
      # Keep the default data-only so `plug Arbor.MCP.HttpPlug, ...` can safely
      # escape initialized options into a module attribute at compile time.
      # A configured mapper may still be a function.
      scope_mapper: Keyword.get(opts, :scope_mapper),
      protected_resource_metadata: protected_resource_metadata
    }
  end

  defp protected_resource_metadata!(opts) do
    if Keyword.get(opts, :oauth_enabled, false) do
      auth_config = Keyword.get(opts, :auth_config, %{})
      resource = Keyword.get(opts, :resource) || Map.get(auth_config, :resource)

      authorization_servers =
        Keyword.get(opts, :authorization_servers) || Map.get(auth_config, :authorization_servers)

      metadata_opts = [
        resource: resource,
        authorization_servers: authorization_servers,
        scopes_supported: Keyword.get(opts, :scopes_supported, get_supported_scopes()),
        bearer_methods_supported: Keyword.get(opts, :bearer_methods_supported, ["header"])
      ]

      validate_protected_resource_uri!(resource, ":resource")

      unless is_list(authorization_servers) and authorization_servers != [] do
        raise ArgumentError,
              "OAuth-enabled Arbor.MCP.HttpPlug requires a non-empty :authorization_servers list"
      end

      Enum.each(
        authorization_servers,
        &validate_authorization_server_uri!/1
      )

      unless metadata_opts[:bearer_methods_supported] == ["header"] do
        raise ArgumentError,
              "OAuth-enabled Arbor.MCP.HttpPlug only supports bearer tokens in the Authorization header"
      end

      ProtectedResourceMetadata.init(metadata_opts)
    end
  end

  defp validate_protected_resource_uri!(value, option) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, fragment: nil, userinfo: nil}
      when is_binary(host) and host != "" ->
        if String.match?(value, ~r/[\x00-\x20\x7f]/u) do
          raise ArgumentError,
                "#{option} entries must not contain credentials, whitespace, or control characters"
        else
          :ok
        end

      _other ->
        raise ArgumentError, "#{option} entries must be absolute HTTPS URIs without fragments"
    end
  end

  defp validate_protected_resource_uri!(_value, option) do
    raise ArgumentError, "#{option} entries must be absolute HTTPS URIs without fragments"
  end

  defp validate_authorization_server_uri!(value) do
    validate_protected_resource_uri!(value, ":authorization_servers")

    if URI.parse(value).query do
      raise ArgumentError, ":authorization_servers entries must not contain query components"
    end
  end

  defp validate_mrtr_configuration!(opts) do
    if Keyword.get(opts, :mrtr, false) do
      case Arbor.MCP.Server.RequestState.validate_configuration(
             request_state: Keyword.get(opts, :request_state)
           ) do
        :ok ->
          :ok

        {:error, reason} ->
          raise ArgumentError, "invalid MRTR requestState configuration: #{reason}"
      end
    end
  end

  @doc """
  Processes HTTP connections for MCP protocol.

  Host validation (`:allowed_hosts`) runs before any routing so that DNS
  rebinding attempts are rejected before request processing.
  """
  @impl Plug
  def call(conn, opts) do
    conn = RuntimeWriter.capture(conn, Map.get(opts, :runtime))

    try do
      call_captured(conn, opts)
    after
      RuntimeWriter.retire(conn)
    end
  end

  defp call_captured(conn, opts) do
    opts = Map.put(opts, :http_endpoint, transport_endpoint(conn, opts))

    conn =
      if request_host_allowed?(conn, opts) do
        dispatch(conn, opts)
      else
        reject_disallowed_host(conn, opts)
      end

    # The plug owns the response for every request it receives, so stop the
    # pipeline here. Under a Phoenix/Plug `forward` this is a no-op; when the
    # plug is placed directly in an endpoint it keeps the router from running
    # against an already-sent conn.
    halt(conn)
  end

  # The host router supplies script_name. Caller headers, body metadata and
  # configured public endpoint values cannot author this private mount identity.
  # Relative legacy aliases share the same canonical forward domain.
  defp transport_endpoint(conn, opts) do
    logical = Map.get(opts, :endpoint, "/mcp")

    parts =
      case conn.script_name do
        [] ->
          split_path(logical)

        prefix ->
          prefix
      end

    :binary.copy("/" <> Enum.join(parts, "/"))
  end

  defp dispatch(conn, opts) do
    cond do
      modern_only_disallowed_method?(conn, opts) ->
        conn
        |> put_resp_header("allow", "POST")
        |> put_resp_content_type("application/json")
        |> send_resp(405, Jason.encode!(%{"error" => "Method not allowed"}))

      mounted_session_method?(conn, opts) ->
        handle_runtime_session_method(conn, opts)

      conn.method == "GET" and legacy_http_sse_path?(conn, opts) ->
        if legacy_http_sse_enabled?(opts) do
          handle_sse_connection(conn, legacy_sse_opts(conn, opts))
        else
          send_resp(conn, 404, "SSE not enabled")
        end

      true ->
        do_dispatch(conn.method, conn.path_info, conn, opts)
    end
  end

  defp modern_only_disallowed_method?(conn, %{protocol_mode: :modern_only} = opts) do
    conn.method in ["GET", "DELETE"] and session_transport_path?(conn, opts)
  end

  defp modern_only_disallowed_method?(conn, opts) do
    conn.method in ["GET", "DELETE"] and session_transport_path?(conn, opts) and
      modern_protocol_header?(conn)
  end

  defp session_transport_path?(conn, opts),
    do: mcp_endpoint_path?(conn, opts) or legacy_http_sse_path?(conn, opts)

  defp mounted_session_method?(conn, %{runtime: runtime} = opts) when not is_nil(runtime),
    do:
      conn.method == "DELETE" or
        (conn.method == "GET" and
           (mcp_endpoint_path?(conn, opts) or legacy_http_sse_path?(conn, opts)))

  defp mounted_session_method?(_conn, _opts), do: false

  defp handle_runtime_session_method(conn, opts) do
    if legacy_http_sse_path?(conn, opts) and not mcp_endpoint_path?(conn, opts) do
      cond do
        not legacy_http_sse_enabled?(opts) ->
          send_resp(conn, 404, "SSE not enabled")

        conn.method == "GET" ->
          handle_runtime_legacy_get(conn, opts)

        true ->
          handle_runtime_session_endpoint(conn, opts)
      end
    else
      handle_runtime_session_endpoint(conn, opts)
    end
  end

  defp handle_runtime_legacy_get(conn, opts) do
    if legacy_post_path_conflicts?(opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        400,
        Jason.encode!(
          JSONRPC.error(
            nil,
            ErrorCodes.invalid_request(),
            "Legacy SSE requires a distinct POST alias path"
          )
        )
      )
    else
      serve_runtime_legacy_get(conn, opts)
    end
  end

  defp legacy_post_path_conflicts?(opts) do
    post = split_path(Map.get(opts, :legacy_http_sse_post_path, "/message"))
    post == [] or post == split_path(Map.get(opts, :endpoint, "/mcp"))
  end

  defp serve_runtime_legacy_get(conn, opts) do
    request = %{"method" => "session/listen"}

    with :ok <- RuntimeWriter.current(conn),
         {:ok, reference} <- get_or_create_session_id(conn, :allow_new_session),
         {:ok, conn} <- validate_request_origin(conn, opts),
         {:ok, token_info} <- authorize_request(conn, request, opts),
         {:ok, resolved} <- resolve_mrtr_identity(conn, request, token_info, opts),
         {:ok, session} <-
           RuntimeSession.alias_get(
             RuntimeWriter.runtime(conn),
             RuntimeWriter.binding(conn),
             reference,
             session_metadata(resolved, token_info, :sse)
           ),
         :ok <- RuntimeWriter.current(conn),
         {:ok, cursor} <- runtime_replay_header(conn),
         {:ok, stream} <-
           RuntimeSessionStream.prepare_legacy(
             conn,
             session,
             cursor,
             opts.sse_mode,
             resolved.http_endpoint
           ) do
      endpoint =
        legacy_http_sse_post_uri(conn, opts) <>
          "?sessionId=" <>
          URI.encode_www_form(RuntimeSession.id(session))

      conn
      |> maybe_add_cors_headers(opts)
      |> add_protocol_version_header()
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("x-accel-buffering", "no")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> RuntimeSessionStream.serve(stream, {"endpoint", {:raw, endpoint}})
    else
      {:error, reason}
      when reason in [:unknown_cursor, :foreign_cursor, :cursor_evicted, :invalid_replay_header] ->
        reject_runtime_replay(conn, reason, opts)

      error ->
        reject_mcp_request(error, conn, opts, nil, nil, nil)
    end
  end

  defp reject_runtime_replay(conn, reason, opts) do
    conn
    |> maybe_add_cors_headers(opts)
    |> put_resp_content_type("application/json")
    |> send_resp(
      if(reason == :cursor_evicted, do: 410, else: 400),
      Jason.encode!(
        JSONRPC.error(nil, ErrorCodes.invalid_request(), "Invalid session replay request")
      )
    )
  end

  defp handle_runtime_session_endpoint(conn, opts) do
    request = %{
      "method" => if(conn.method == "GET", do: "session/listen", else: "session/delete")
    }

    with :ok <- RuntimeWriter.current(conn),
         {:ok, {:existing_session, id}} <- get_or_create_session_id(conn, request),
         {:ok, conn} <- validate_request_origin(conn, opts),
         {:ok, token_info} <- authorize_request(conn, request, opts),
         :ok <- RuntimeWriter.current(conn),
         {:ok, resolved} <- resolve_mrtr_identity(conn, request, token_info, opts),
         {:ok, session} <-
           RuntimeSession.addressed(
             RuntimeWriter.runtime(conn),
             RuntimeWriter.binding(conn),
             id,
             session_metadata(resolved, token_info, :http),
             conn.method == "GET"
           ),
         {:ok, conn} <- runtime_protocol_version(conn, request, session),
         :ok <- RuntimeWriter.current(conn) do
      conn = conn |> maybe_add_cors_headers(opts) |> add_protocol_version_header()
      serve_runtime_session_method(conn, resolved, session)
    else
      error -> reject_mcp_request(error, conn, opts, nil, nil, nil)
    end
  end

  defp serve_runtime_session_method(%{method: "DELETE"} = conn, _opts, session) do
    # The response is reserved while its entry authority is still valid. Its
    # session lease is separately checked by the store's final mutation guard.
    case RuntimeSession.delete(session, RuntimeWriter.binding(conn)) do
      {:ok, effect, _session} ->
        RuntimeWriter.perform(conn, effect, "", &Plug.Conn.send_resp(&1, 204, &2))

      _failure ->
        raise RuntimeWriter.AdmissionError
    end
  end

  defp serve_runtime_session_method(conn, opts, session) do
    with true <- accepts_event_stream?(conn) || {:error, :event_stream_required},
         {:ok, cursor} <- runtime_replay_header(conn),
         {:ok, stream} <- RuntimeSessionStream.prepare(conn, session, cursor, opts.sse_mode) do
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("x-accel-buffering", "no")
      |> put_resp_header("cache-control", "no-cache")
      |> RuntimeSessionStream.serve(stream)
    else
      {:error, reason}
      when reason in [
             :unknown_cursor,
             :foreign_cursor,
             :cursor_evicted,
             :invalid_replay_header,
             :event_stream_required
           ] ->
        status = if reason == :cursor_evicted, do: 410, else: 400

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          status,
          Jason.encode!(
            JSONRPC.error(nil, ErrorCodes.invalid_request(), "Invalid session replay request")
          )
        )

      error ->
        reject_mcp_request(error, conn, opts, nil, nil, nil)
    end
  end

  defp runtime_replay_header(conn) do
    case get_req_header(conn, "last-event-id") do
      [] -> {:ok, nil}
      [cursor] when byte_size(cursor) in 1..256 -> {:ok, cursor}
      _invalid -> {:error, :invalid_replay_header}
    end
  end

  # The MCP endpoint is the plug's mount root. `path_info` is relative to the
  # mount (Phoenix and Plug.Router `forward` strip the prefix into
  # `script_name`), so this holds wherever the plug is mounted. The `:path`
  # option is still honoured for plugs placed directly in an endpoint, where
  # nothing strips the prefix.
  defp mcp_endpoint_path?(conn, opts) do
    conn.path_info == [] or conn.path_info == split_path(Map.get(opts, :endpoint, "/mcp"))
  end

  defp do_dispatch("OPTIONS", _path, conn, opts) do
    Logger.debug("HttpPlug: OPTIONS request")

    if opts.cors_enabled do
      handle_cors_preflight(conn, opts)
    else
      send_resp(conn, 405, "Method not allowed")
    end
  end

  defp do_dispatch("GET", [".well-known", "oauth-protected-resource"], conn, opts) do
    if opts.oauth_enabled and protected_resource_path(opts) == [] do
      handle_well_known_resource(conn, opts)
    else
      send_resp(conn, 404, "Not Found")
    end
  end

  defp do_dispatch(
         "GET",
         [".well-known", "oauth-protected-resource" | resource_path],
         conn,
         opts
       ) do
    if opts.oauth_enabled and resource_path == protected_resource_path(opts) do
      handle_well_known_resource(conn, opts)
    else
      send_resp(conn, 404, "Not Found")
    end
  end

  defp do_dispatch("GET", [".well-known", "oauth-authorization-server"], conn, opts) do
    if opts.oauth_enabled do
      handle_authorization_server_metadata(conn, opts)
    else
      send_resp(conn, 404, "Not Found")
    end
  end

  # Handle POST to OAuth endpoints - these should return 404
  defp do_dispatch("POST", [".well-known", "oauth-authorization-server"], conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "Not found"}))
  end

  defp do_dispatch("POST", [".well-known", "oauth-protected-resource"], conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "Not found"}))
  end

  defp do_dispatch("POST", _path, conn, opts) do
    Logger.debug("HttpPlug: POST request to #{conn.request_path}")

    :telemetry.execute(
      [:arbor_mcp, :server, :http, :request],
      %{},
      %{method: conn.method, path: conn.request_path}
    )

    cond do
      legacy_http_sse_enabled?(opts) and legacy_http_sse_post_path?(conn, opts) and
          not mcp_endpoint_path?(conn, opts) ->
        if opts.runtime,
          do: handle_runtime_legacy_post(conn, opts),
          else: handle_legacy_http_sse_post(conn, opts)

      legacy_http_sse_post_path?(conn, opts) and not mcp_endpoint_path?(conn, opts) ->
        send_resp(conn, 404, "SSE not enabled")

      true ->
        handle_mcp_request(conn, opts)
    end
  end

  defp do_dispatch("DELETE", ["sse", session_id], conn, opts) do
    handle_session_delete(conn, session_id, opts, false)
  end

  defp do_dispatch("DELETE", ["mcp", "v1", "sse", session_id], conn, opts) do
    handle_session_delete(conn, session_id, opts, false)
  end

  # Per MCP spec, DELETE to the MCP endpoint with Mcp-Session-Id header terminates the session.
  defp do_dispatch("DELETE", _path, conn, opts) do
    case fetch_session_id_header(conn, "mcp-session-id") do
      {:ok, session_id} when is_binary(session_id) ->
        handle_session_delete(conn, session_id, opts, true)

      {:ok, nil} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Missing Mcp-Session-Id header"}))

      {:error, :invalid_session_id} ->
        reject_invalid_session_id(conn, opts)
    end
  end

  # Per MCP spec, SSE GET uses the same endpoint as POST.
  # Handle GET requests with Accept: text/event-stream on any path.
  defp do_dispatch("GET", _path, conn, opts) do
    accepts_sse =
      conn
      |> get_req_header("accept")
      |> Enum.any?(&String.contains?(&1, "text/event-stream"))

    if legacy_http_sse_enabled?(opts) and accepts_sse do
      handle_sse_connection(conn, opts)
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(404, Jason.encode!(%{error: "Not found"}))
    end
  end

  defp do_dispatch(_method, _path, conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "Not found"}))
  end

  defp legacy_http_sse_enabled?(%{protocol_mode: :modern_only}), do: false

  defp legacy_http_sse_enabled?(opts) do
    Map.get(opts, :legacy_http_sse, Map.get(opts, :sse_enabled, false))
  end

  defp legacy_http_sse_path?(conn, opts) do
    conn.path_info in [
      split_path(Map.get(opts, :legacy_http_sse_path, "/sse")),
      ["mcp", "v1", "sse"]
    ]
  end

  defp legacy_http_sse_post_path?(conn, opts) do
    conn.path_info == split_path(Map.get(opts, :legacy_http_sse_post_path, "/message"))
  end

  defp split_path(path) do
    String.split(path, "/", trim: true)
  end

  defp normalize_legacy_http_sse_path("/" <> _rest = path), do: path
  defp normalize_legacy_http_sse_path(path) when is_binary(path), do: "/" <> path

  defp legacy_sse_opts(conn, opts) do
    endpoint = legacy_http_sse_post_uri(conn, opts)

    Map.put(opts, :initial_sse_event_builder, fn session_id ->
      {"endpoint", {:raw, endpoint <> "?sessionId=" <> URI.encode_www_form(session_id)}}
    end)
  end

  defp legacy_http_sse_post_uri(conn, opts) do
    scheme = Atom.to_string(conn.scheme)

    default_port? =
      (scheme == "http" and conn.port == 80) or (scheme == "https" and conn.port == 443)

    authority = if default_port?, do: conn.host, else: "#{conn.host}:#{conn.port}"

    mount_prefix =
      case conn.script_name do
        [] -> ""
        parts -> "/" <> Enum.join(parts, "/")
      end

    post_path = Map.get(opts, :legacy_http_sse_post_path, "/message")
    scheme <> "://" <> authority <> mount_prefix <> post_path
  end

  # CORS preflight handling
  defp handle_cors_preflight(conn, opts) do
    if origin_allowed?(conn, opts) do
      conn
      |> maybe_add_cors_headers(opts)
      |> put_resp_header("access-control-allow-methods", "GET, POST, DELETE, OPTIONS")
      |> put_resp_header(
        "access-control-allow-headers",
        "content-type, authorization, mcp-protocol-version, mcp-session-id"
      )
      |> put_resp_header("access-control-max-age", "86400")
      |> send_resp(200, "")
    else
      send_resp(conn, 403, "Origin not allowed")
    end
  end

  # Handle regular MCP JSON-RPC requests
  defp handle_mcp_request(conn, opts) do
    case validate_request_origin(conn, opts) do
      {:ok, conn} ->
        select_mcp_era(conn, opts)

      {:error, :origin_not_allowed} ->
        conn
        |> maybe_add_cors_headers(opts)
        |> send_resp(403, "Origin not allowed")
    end
  end

  defp select_mcp_era(conn, %{runtime: runtime} = opts) when not is_nil(runtime) do
    do_handle_runtime_mcp_request(conn, opts)
  end

  defp select_mcp_era(conn, opts) do
    Logger.debug("Handling MCP request, SSE enabled: #{opts.sse_enabled}")

    # Era selection happens before session allocation. Modern requests are
    # stateless and ignore legacy session/resumption headers; legacy requests
    # retain the existing session behavior.
    case read_or_cached_body(conn, opts) do
      {:ok, body, conn} ->
        conn = assign(conn, :raw_body, body)

        case parse_json(body) do
          {:ok, request} ->
            if modern_http_request?(conn, request) do
              do_handle_mcp_request(conn, opts, nil)
            else
              handle_legacy_mcp_request(conn, opts)
            end

          {:error, _reason} ->
            # Preserve the legacy error/session shape when no modern envelope
            # can be identified from an invalid body.
            handle_legacy_mcp_request(conn, opts)
        end

      {:error, :body_too_large} ->
        conn
        |> maybe_add_cors_headers(opts)
        |> send_resp(413, "Request body too large")

      {:error, reason} ->
        Logger.error("Failed to read MCP request body", reason: LogSummary.describe(reason))
        send_resp(conn, 400, "Invalid request body")
    end
  end

  defp handle_legacy_mcp_request(conn, opts) do
    with {:ok, body, conn} <- read_or_cached_body(conn, opts),
         {:ok, request} <- parse_json(body),
         {:ok, session_reference} <- get_or_create_session_id(conn, request) do
      do_handle_mcp_request(conn, opts, session_reference)
    else
      {:error, :session_required} -> reject_missing_session(conn, opts)
      {:error, :invalid_session_id} -> reject_invalid_session_id(conn, opts)
      # Preserve the existing parse/body error handling in do_handle_mcp_request.
      {:error, _reason} -> do_handle_mcp_request(conn, opts, nil)
    end
  end

  defp do_handle_mcp_request(conn, opts, session_reference) do
    session_id = session_reference_id(session_reference)
    session_manager = Map.get(opts, :session_manager, Arbor.MCP.SessionManager)

    with {:ok, conn} <- validate_request_origin(conn, opts),
         {:ok, body, conn} <- read_or_cached_body(conn, opts),
         {:ok, request} <- parse_json(body),
         conn = assign_request_protocol_version(conn, request),
         {:ok, conn} <-
           validate_protocol_version(conn, request, session_manager, session_id),
         :ok <- validate_modern_method(request),
         :ok <- validate_request_method_params(request),
         {:ok, token_info} <- authorize_request(conn, request, opts),
         {:ok, opts} <- resolve_handler_opts(conn, request, opts),
         {:ok, opts} <- resolve_mrtr_identity(conn, request, token_info, opts),
         {:ok, session_id} <-
           establish_request_session(
             session_manager,
             session_reference,
             request,
             session_metadata(opts, token_info, :http)
           ),
         :ok <- authorize_session_lifecycle(session_manager, session_id, request),
         :ok <- claim_request_id(session_manager, session_id, request),
         process_opts =
           opts
           |> Map.put(:session_id, session_id)
           |> Map.put(:request_headers, conn.req_headers),
         result <- process_or_open_request_stream(conn, request, process_opts),
         {:ok, result, conn} <-
           finalize_legacy_protocol_version(
             result,
             conn,
             request,
             session_manager,
             session_id
           ) do
      Logger.debug("MCP request processed", reply_shape: LogSummary.describe(result))

      case result do
        {:request_stream, request_id, process_fun} ->
          :telemetry.execute(
            [:arbor_mcp, :server, :http, :response],
            %{},
            %{status: 200, streaming: true, stream: :request}
          )

          conn
          |> maybe_add_cors_headers(opts)
          |> add_protocol_version_header()
          |> put_resp_header("content-type", "text/event-stream")
          |> put_resp_header("x-accel-buffering", "no")
          |> put_resp_header("cache-control", "no-cache")
          |> send_chunked(200)
          |> RequestStream.serve(request_id, opts, process_fun)

        {:subscription, entry} ->
          :telemetry.execute(
            [:arbor_mcp, :server, :http, :response],
            %{},
            %{status: 200, streaming: true}
          )

          subscription_options = subscription_options(opts)

          conn
          |> maybe_add_cors_headers(opts)
          |> add_protocol_version_header()
          |> put_resp_header("content-type", "text/event-stream")
          |> put_resp_header("x-accel-buffering", "no")
          |> put_resp_header("cache-control", "no-cache")
          |> send_chunked(200)
          |> ModernStream.serve(entry, opts, subscription_options)

        {:ok, response} ->
          # Per MCP spec, POST responses MUST contain the result in the body,
          # even when SSE is enabled. The SSE stream is for server-initiated
          # messages only (notifications, progress updates).
          :telemetry.execute(
            [:arbor_mcp, :server, :http, :response],
            %{},
            %{status: 200}
          )

          conn
          |> maybe_add_cors_headers(opts)
          |> add_protocol_version_header()
          |> maybe_put_session_header(session_id)
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(response))

        {:notification, _} ->
          # Notifications get 202 Accepted with no body
          :telemetry.execute(
            [:arbor_mcp, :server, :http, :response],
            %{},
            %{status: 202}
          )

          conn
          |> maybe_add_cors_headers(opts)
          |> add_protocol_version_header()
          |> maybe_put_session_header(session_id)
          |> send_resp(202, "")

        {:http_error, status, response} ->
          :telemetry.execute(
            [:arbor_mcp, :server, :http, :response],
            %{},
            %{status: status}
          )

          conn
          |> maybe_add_cors_headers(opts)
          |> add_protocol_version_header()
          |> maybe_put_session_header(session_id)
          |> put_resp_content_type("application/json")
          |> send_resp(status, Jason.encode!(response))

        {:error, :no_response} ->
          :telemetry.execute(
            [:arbor_mcp, :server, :http, :response],
            %{},
            %{status: 500}
          )

          Logger.error("Handler did not provide a response",
            message_shape: LogSummary.describe(request)
          )

          error_response =
            JSONRPC.error(
              Map.get(request, "id"),
              ErrorCodes.internal_error(),
              "Internal error: no response from handler"
            )

          conn
          |> maybe_add_cors_headers(opts)
          |> add_protocol_version_header()
          |> maybe_put_session_header(session_id)
          |> put_resp_content_type("application/json")
          |> send_resp(500, Jason.encode!(error_response))

        {:error, reason} ->
          :telemetry.execute(
            [:arbor_mcp, :server, :http, :response],
            %{},
            %{status: 500}
          )

          Logger.error("Request processing error", reason: LogSummary.describe(reason))

          error_response =
            JSONRPC.error(
              Map.get(request, "id"),
              ErrorCodes.internal_error(),
              "Internal error"
            )

          conn
          |> maybe_add_cors_headers(opts)
          |> add_protocol_version_header()
          |> maybe_put_session_header(session_id)
          |> put_resp_content_type("application/json")
          |> send_resp(500, Jason.encode!(error_response))
      end
    else
      error ->
        reject_mcp_request(error, conn, opts, session_manager, session_id, session_reference)
    end
  end

  defp reject_mcp_request(
         {:error, {:header_mismatch, request_id, message}},
         conn,
         opts,
         _session_manager,
         _session_id,
         _session_reference
       ) do
    error_response =
      JSONRPC.error(request_id, ErrorCodes.header_mismatch(), message)

    conn
    |> maybe_add_cors_headers(opts)
    |> add_protocol_version_header()
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(error_response))
  end

  defp reject_mcp_request(
         {:error, {:invalid_modern_metadata, request_id, field}},
         conn,
         opts,
         _session_manager,
         _session_id,
         _session_reference
       ) do
    error_response =
      JSONRPC.error(
        request_id,
        ErrorCodes.invalid_params(),
        "Invalid request metadata",
        %{"field" => field, "reason" => "missing_required_field"}
      )

    conn
    |> maybe_add_cors_headers(opts)
    |> add_protocol_version_header()
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(error_response))
  end

  defp reject_mcp_request(
         {:error, {:unsupported_protocol_version, request_id, version}},
         conn,
         opts,
         _session_manager,
         _session_id,
         _session_reference
       ) do
    supported = VersionRegistry.known_versions()

    error_response =
      JSONRPC.error(
        request_id,
        ErrorCodes.unsupported_protocol_version(),
        "Unsupported MCP protocol version",
        %{"requested" => version, "supported" => supported}
      )

    conn
    |> maybe_add_cors_headers(opts)
    |> add_protocol_version_header()
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(error_response))
  end

  defp reject_mcp_request(
         {:error, {:modern_method_not_found, request_id}},
         conn,
         opts,
         _session_manager,
         _session_id,
         _session_reference
       ) do
    error_response =
      JSONRPC.error(request_id, ErrorCodes.method_not_found(), "Method not found")

    conn
    |> maybe_add_cors_headers(opts)
    |> add_protocol_version_header()
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(error_response))
  end

  defp reject_mcp_request(
         {:error, {:protocol_version_mismatch, message, expected_version}},
         conn,
         opts,
         _session_manager,
         session_id,
         _session_reference
       ) do
    error_response =
      JSONRPC.error(
        nil,
        ErrorCodes.invalid_request(),
        message,
        %{"expectedVersion" => expected_version}
      )

    conn
    |> assign(:request_protocol_version, expected_version)
    |> maybe_add_cors_headers(opts)
    |> add_protocol_version_header()
    |> maybe_put_session_header(session_id)
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(error_response))
  end

  defp reject_mcp_request(
         {:error, {:auth_error, {status, www_auth_header, body}}},
         conn,
         opts,
         _session_manager,
         _session_id,
         _session_reference
       ) do
    conn
    |> maybe_add_cors_headers(opts)
    |> put_resp_header("www-authenticate", www_auth_header)
    |> send_resp(status, body)
  end

  defp reject_mcp_request(
         {:error, :oauth_guard_disabled},
         conn,
         opts,
         _session_manager,
         _session_id,
         _session_reference
       ) do
    conn
    |> maybe_add_cors_headers(opts)
    |> put_resp_content_type("application/json")
    |> send_resp(500, Jason.encode!(Core.oauth_guard_disabled_error()))
  end

  defp reject_mcp_request(
         {:error, :scope_policy_missing},
         conn,
         opts,
         _session_manager,
         _session_id,
         _session_reference
       ) do
    scope_policy_error_response(conn, opts)
  end

  defp reject_mcp_request(
         {:error, {:invalid_method_params, request_id, error}},
         conn,
         opts,
         _session_manager,
         _session_id,
         _session_reference
       ) do
    conn
    |> maybe_add_cors_headers(opts)
    |> add_protocol_version_header()
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(JSONRPC.error(request_id, error)))
  end

  defp reject_mcp_request(
         {:error, reason},
         conn,
         opts,
         _session_manager,
         _session_id,
         _session_reference
       )
       when reason in [:session_not_found, :session_identity_mismatch] do
    reject_unknown_session(conn, opts)
  end

  defp reject_mcp_request(
         {:error, :session_not_initialized},
         conn,
         opts,
         _session_manager,
         _session_id,
         session_reference
       ) do
    session_lifecycle_rejection_response(
      conn,
      opts,
      session_reference_id(session_reference),
      nil,
      :session_not_initialized
    )
  end

  defp reject_mcp_request(
         {:error, :session_limit_exceeded},
         conn,
         opts,
         _session_manager,
         _session_id,
         _session_reference
       ) do
    session_limit_response(conn, opts)
  end

  defp reject_mcp_request(
         {:error, {:request_id_rejected, failed_session_id, request_id, reason, method}},
         conn,
         opts,
         session_manager,
         _session_id,
         _session_reference
       ) do
    handle_request_id_rejection(
      conn,
      opts,
      session_manager,
      failed_session_id,
      request_id,
      reason,
      method
    )
  end

  defp reject_mcp_request(
         {:error, {:session_lifecycle_rejected, request_id, reason}},
         conn,
         opts,
         _session_manager,
         session_id,
         _session_reference
       ) do
    session_lifecycle_rejection_response(conn, opts, session_id, request_id, reason)
  end

  defp reject_mcp_request(
         {:error, :session_required},
         conn,
         opts,
         _session_manager,
         _session_id,
         _session_reference
       ) do
    reject_missing_session(conn, opts)
  end

  defp reject_mcp_request(
         {:error, :session_manager_unavailable},
         conn,
         opts,
         _session_manager,
         _session_id,
         _session_reference
       ) do
    session_manager_unavailable_response(conn, opts)
  end

  defp reject_mcp_request(
         {:error, :origin_not_allowed},
         conn,
         opts,
         _session_manager,
         _session_id,
         _session_reference
       ) do
    conn
    |> maybe_add_cors_headers(opts)
    |> send_resp(403, "Origin not allowed")
  end

  defp reject_mcp_request(
         {:error, :parse_error},
         conn,
         opts,
         _session_manager,
         session_id,
         _session_reference
       ) do
    error_response = JSONRPC.error(nil, ErrorCodes.parse_error(), "Parse error")

    conn
    |> maybe_add_cors_headers(opts)
    |> add_protocol_version_header()
    |> maybe_put_session_header(session_id)
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(error_response))
  end

  defp reject_mcp_request(
         {:error, :invalid_json_rpc_envelope},
         conn,
         opts,
         _session_manager,
         session_id,
         _session_reference
       ) do
    error_response = JSONRPC.error(nil, ErrorCodes.invalid_request(), "Invalid Request")

    conn
    |> maybe_add_cors_headers(opts)
    |> add_protocol_version_header()
    |> maybe_put_session_header(session_id)
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(error_response))
  end

  defp reject_mcp_request(
         {:error, :body_too_large},
         conn,
         opts,
         _session_manager,
         _session_id,
         _session_reference
       ) do
    conn
    |> maybe_add_cors_headers(opts)
    |> send_resp(413, "Request body too large")
  end

  defp reject_mcp_request(
         {:error, reason},
         conn,
         opts,
         _session_manager,
         session_id,
         _session_reference
       ) do
    Logger.error("MCP request processing failed", reason: LogSummary.describe(reason))

    error_response = JSONRPC.error(nil, ErrorCodes.internal_error(), "Internal error")

    conn
    |> maybe_add_cors_headers(opts)
    |> add_protocol_version_header()
    |> maybe_put_session_header(session_id)
    |> put_resp_content_type("application/json")
    |> send_resp(500, Jason.encode!(error_response))
  end

  defp do_handle_runtime_mcp_request(conn, opts) do
    runtime = RuntimeWriter.runtime(conn)
    binding = RuntimeWriter.binding(conn)

    with :ok <- RuntimeWriter.current(conn),
         {:ok, body, conn} <- read_or_cached_body(conn, opts),
         {:ok, request} <- runtime_json(body),
         conn = assign_request_protocol_version_runtime(conn, request),
         :ok <- runtime_route_policy(conn, request),
         :ok <- runtime_array_policy(conn, request, opts),
         :ok <- runtime_validate_methods(request),
         {:ok, token_info} <- authorize_request_runtime(conn, request, opts),
         :ok <- RuntimeWriter.current(conn),
         {:ok, resolved} <- resolve_handler_opts(conn, request, opts),
         :ok <- RuntimeWriter.current(conn),
         {:ok, resolved} <- resolve_mrtr_identity(conn, request, token_info, resolved),
         {:ok, reference} <- runtime_session_reference(conn, request),
         {:ok, session} <-
           RuntimeSession.prepare(
             runtime,
             binding,
             reference,
             request,
             session_metadata(resolved, token_info, :http)
           ),
         {:ok, conn} <- runtime_protocol_version(conn, request, session),
         :ok <- RuntimeWriter.current(conn),
         format = runtime_output_format(conn, request),
         {:ok, _token} <-
           HTTPGateway.submit(runtime, binding, request,
             format: format,
             dispatch_opts:
               runtime_dispatch_opts(Map.put(resolved, :runtime_format, format), conn)
           ),
         response <- RuntimeWriter.await(conn),
         :ok <- runtime_response_ready(response) do
      conn =
        conn
        |> maybe_add_cors_headers(opts)
        |> add_protocol_version_header()
        |> maybe_put_session_header(RuntimeSession.id(session))

      case response do
        {:ok, effect, wire} ->
          write_runtime_output(conn, effect, wire, format, session, request)

        {:listener, binding, listener, registration} ->
          Arbor.MCP.HttpPlug.RuntimeSubscriptionStream.serve(
            conn,
            binding,
            listener,
            registration,
            opts
          )
      end
    else
      {:error, reason} = error
      when reason in [
             :http_invocation_closed,
             :http_output_busy,
             :http_frame_too_large,
             :server_busy,
             :handler_timeout,
             :runtime_unavailable,
             :request_too_large,
             :http_metadata_busy,
             :http_writer_unavailable
           ] ->
        _ = error
        raise RuntimeWriter.AdmissionError

      error ->
        reject_mcp_request(error, conn, opts, nil, nil, nil)
    end
  end

  defp runtime_response_ready({:ok, _effect, _wire}), do: :ok
  defp runtime_response_ready({:listener, _binding, _pid, _registration}), do: :ok
  defp runtime_response_ready(error), do: error

  defp runtime_json(body) do
    case Jason.decode(body) do
      {:ok, request} when is_map(request) or is_list(request) -> {:ok, request}
      {:ok, _value} -> {:error, :invalid_json_rpc_envelope}
      {:error, _reason} -> {:error, :parse_error}
    end
  end

  defp runtime_array_policy(conn, request, opts) when is_list(request) do
    if request == [] or opts.protocol_mode == :modern_only or modern_protocol_header?(conn) or
         Enum.any?(request, &modern_request_metadata?/1) or
         not RuntimeSession.valid_initialization_batch?(request),
       do: {:error, :invalid_json_rpc_envelope},
       else: :ok
  end

  defp runtime_array_policy(_conn, _request, _opts), do: :ok

  defp runtime_validate_methods(request) when is_list(request), do: :ok

  defp runtime_validate_methods(request) do
    with :ok <- validate_modern_method(request), do: validate_request_method_params(request)
  end

  defp authorize_request_runtime(conn, request, opts) when is_list(request) do
    Enum.reduce_while(request, {:ok, nil}, fn
      member, {:ok, _previous} when is_map(member) ->
        case authorize_request(conn, member, opts) do
          {:ok, token} -> {:cont, {:ok, token}}
          error -> {:halt, error}
        end

      _invalid, result ->
        {:cont, result}
    end)
  end

  defp authorize_request_runtime(conn, request, opts), do: authorize_request(conn, request, opts)

  defp assign_request_protocol_version_runtime(conn, request) when is_map(request),
    do: assign_request_protocol_version(conn, request)

  defp assign_request_protocol_version_runtime(conn, _batch), do: conn

  defp runtime_output_format(%{private: %{arbor_mcp_legacy_session: _id}}, _request),
    do: :legacy_sse

  defp runtime_output_format(conn, request),
    do: if(request_stream?(conn, request), do: :sse, else: :json)

  defp runtime_route_policy(%{private: %{arbor_mcp_legacy_session: _id}} = conn, request) do
    members = if is_list(request), do: request, else: [request]

    if modern_protocol_header?(conn) or Enum.any?(members, &modern_request_metadata?/1),
      do: {:error, {:header_mismatch, nil, "Modern requests require the MCP POST endpoint"}},
      else: :ok
  end

  defp runtime_route_policy(_conn, _request), do: :ok

  defp runtime_session_reference(%{private: %{arbor_mcp_legacy_session: id}}, _request),
    do: {:ok, {:existing_session, id}}

  defp runtime_session_reference(conn, request) do
    if modern_http_request?(conn, request),
      do: {:ok, nil},
      else:
        get_or_create_session_id(conn, RuntimeSession.initialization_request(request) || request)
  end

  defp runtime_protocol_version(conn, request, session) do
    if is_list(request) and is_nil(RuntimeSession.initialization_request(request)) do
      validate_runtime_legacy_version(conn, request, session)
    else
      request = RuntimeSession.initialization_request(request) || request

      if modern_http_request?(conn, request) or request["method"] == "initialize",
        do: validate_protocol_version(conn, request, nil, nil),
        else: validate_runtime_legacy_version(conn, request, session)
    end
  end

  defp validate_runtime_legacy_version(conn, _request, session) do
    expected = RuntimeSession.version(session) || VersionRegistry.latest_version()

    case get_req_header(conn, "mcp-protocol-version") do
      [version] when is_binary(version) ->
        if VersionRegistry.supported?(version) and version == expected,
          do: {:ok, assign(conn, :request_protocol_version, expected)},
          else:
            protocol_version_error(
              "MCP-Protocol-Version does not match the negotiated version.",
              expected
            )

      [] ->
        if FeatureFlags.enabled?(:protocol_version_header),
          do: protocol_version_error("Missing MCP-Protocol-Version header.", expected),
          else: {:ok, assign(conn, :request_protocol_version, expected)}

      _duplicate ->
        protocol_version_error("MCP-Protocol-Version header must occur exactly once.", expected)
    end
  end

  defp runtime_dispatch_opts(opts, conn) do
    keys = [
      :protocol_mode,
      :instructions,
      :request_state,
      :endpoint,
      :http_endpoint,
      :max_input_requests,
      :max_mrtr_bytes,
      :require_replay_protection,
      :principal_id,
      :tenant_id
    ]

    Enum.map(keys, &{&1, Map.get(opts, &1)}) ++
      [
        application_context: opts.handler_opts,
        request_headers: conn.req_headers,
        replay_cache: runtime_replay_cache(conn),
        request_notification_target: runtime_notification_target(opts, conn)
      ]
  end

  defp runtime_notification_target(%{runtime_format: :json}, _conn), do: nil

  defp runtime_notification_target(_opts, conn) do
    case Arbor.MCP.Server.Runtime.HTTPNotificationTarget.new(
           RuntimeWriter.runtime(conn),
           RuntimeWriter.binding(conn)
         ) do
      {:ok, target} -> target
      _closed -> nil
    end
  end

  defp runtime_replay_cache(conn) do
    case Arbor.MCP.Server.Runtime.service(RuntimeWriter.runtime(conn), :replay_cache) do
      {:ok, service} -> service
      _unavailable -> nil
    end
  end

  defp finalize_runtime_session(session, request, wire, conn) do
    response = if wire == "", do: nil, else: decode_runtime_wire(wire)
    RuntimeSession.finalize(session, request, response, conn.assigns[:request_protocol_version])
  end

  defp decode_runtime_wire("data: " <> framed),
    do: Jason.decode!(String.trim_trailing(framed, "\r\n\r\n"))

  defp decode_runtime_wire(wire), do: Jason.decode!(wire)

  defp write_runtime_output(conn, effect, wire, format, session, request) do
    kind = HTTPWriterRegistry.kind(effect)

    if kind != :notification and finalize_runtime_session(session, request, wire, conn) != :ok,
      do: raise(RuntimeWriter.AdmissionError)

    initialization_error? = kind == :response and initialization_error?(request, wire)

    conn =
      if initialization_error?,
        do:
          conn |> assign(:suppress_session_header, true) |> delete_resp_header("mcp-session-id"),
        else: conn

    conn = write_runtime_response(conn, effect, wire, format)

    if kind == :notification do
      case RuntimeWriter.await(conn) do
        {:ok, effect, wire} -> write_runtime_output(conn, effect, wire, format, session, request)
        _closed -> raise RuntimeWriter.AdmissionError
      end
    else
      if initialization_error?, do: RuntimeSession.terminate(session)

      conn
    end
  end

  defp initialization_error?(%{"method" => "initialize"}, wire) when wire != "",
    do: Map.has_key?(decode_runtime_wire(wire), "error")

  defp initialization_error?(requests, wire) when is_list(requests) and wire != "" do
    case RuntimeSession.initialization_request(requests) do
      nil ->
        false

      initial ->
        response = decode_runtime_wire(wire)

        not is_list(response) or
          Enum.any?(response, fn entry ->
            is_map(entry) and entry["id"] == initial["id"] and Map.has_key?(entry, "error")
          end)
    end
  end

  defp initialization_error?(_request, _wire), do: false

  defp write_runtime_response(conn, effect, "", _format),
    do: RuntimeWriter.perform(conn, effect, "", &Plug.Conn.send_resp(&1, 202, &2))

  # A successful deprecated POST acknowledges a durable replay commit. The
  # existing physical companion conservatively retains JSON bytes even though
  # the actual 202 body is empty. Terminal library failures have no replay
  # companion and use an explicit non-202 response without claiming durability.
  defp write_runtime_response(conn, effect, wire, :legacy_sse) do
    case HTTPWriterRegistry.response_primary(effect) do
      {:ok, primary} -> write_legacy_response(conn, effect, wire, primary)
      _uncertain -> raise RuntimeWriter.AdmissionError
    end
  end

  defp write_runtime_response(conn, effect, wire, :json) do
    conn = put_resp_content_type(conn, "application/json")
    RuntimeWriter.perform(conn, effect, wire, &Plug.Conn.send_resp(&1, 200, &2))
  end

  defp write_runtime_response(conn, effect, wire, :sse) do
    conn =
      if conn.state == :chunked do
        conn
      else
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> put_resp_header("x-accel-buffering", "no")
        |> put_resp_header("cache-control", "no-cache")
      end

    RuntimeWriter.perform(conn, effect, wire, fn conn, wire ->
      conn = if conn.state == :chunked, do: conn, else: Plug.Conn.send_chunked(conn, 200)

      case Plug.Conn.chunk(conn, wire) do
        {:ok, conn} -> conn
        error -> error
      end
    end)
  end

  defp write_legacy_response(conn, effect, wire, primary) do
    case Arbor.MCP.Server.Runtime.OutputTicket.session(primary) do
      nil ->
        conn = put_resp_content_type(conn, "application/json")
        RuntimeWriter.perform(conn, effect, wire, &Plug.Conn.send_resp(&1, 500, &2))

      _event ->
        case Arbor.MCP.SessionManager.RuntimeEvents.publish(primary) do
          :ok ->
            RuntimeWriter.perform(conn, effect, wire, fn conn, _charged_wire ->
              Plug.Conn.send_resp(conn, 202, "")
            end)

          _uncertain ->
            raise RuntimeWriter.AdmissionError
        end
    end
  end

  defp send_resp(conn, status, body), do: RuntimeWriter.send_resp(conn, status, body)
  defp send_chunked(conn, status), do: RuntimeWriter.send_chunked(conn, status)
  defp chunk(conn, body), do: RuntimeWriter.chunk(conn, body)

  defp session_reference_id({:existing_session, session_id}), do: session_id
  defp session_reference_id(_new_or_stateless), do: nil

  # Parse JSON and handle decode errors
  defp parse_json(body) do
    Core.parse_json(body)
  end

  defp modern_http_request?(conn, request) do
    modern_protocol_header?(conn) or modern_request_metadata?(request)
  end

  defp modern_protocol_header?(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [version] -> VersionRegistry.modern?(version)
      _other -> false
    end
  end

  defp modern_request_metadata?(%{"params" => %{"_meta" => meta}}) when is_map(meta) do
    Map.has_key?(meta, "io.modelcontextprotocol/protocolVersion") or
      Map.has_key?(meta, "io.modelcontextprotocol/clientCapabilities")
  end

  defp modern_request_metadata?(_request), do: false

  # Allow upstream plugs (e.g., signature-verification auth pipelines) to
  # pre-read the request body and stash it in `conn.assigns[:raw_body]`.
  # When present, we use it instead of calling `read_body/1`, which would
  # otherwise return an empty body since the underlying adapter has already
  # been consumed. Falls back to normal `read_body/1` when no cached body
  # is present, preserving existing behaviour for callers that don't pre-read.
  defp read_or_cached_body(%Plug.Conn{assigns: %{raw_body: body}} = conn, opts)
       when is_binary(body) do
    body_limit = Map.get(opts, :body_limit, 1_000_000)

    if byte_size(body) <= body_limit do
      {:ok, body, conn}
    else
      {:error, :body_too_large}
    end
  end

  defp read_or_cached_body(conn, opts) do
    body_limit = Map.get(opts, :body_limit, 1_000_000)

    with {:ok, read_opts} <- runtime_read_options(conn, body_limit) do
      case read_body(conn, read_opts) do
        {:ok, "", conn} -> parsed_json_body(conn, body_limit)
        {:ok, body, conn} -> {:ok, body, conn}
        {:more, _partial, _conn} -> {:error, :body_too_large}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp runtime_read_options(
         %Plug.Conn{private: %{arbor_mcp_http_binding: binding, arbor_mcp_runtime: runtime}},
         limit
       ) do
    with {:ok, proof} <- HTTPWriterBinding.validate(binding, runtime),
         remaining = proof.deadline - System.monotonic_time(:millisecond),
         true <- remaining > 0 do
      {:ok, [length: limit, read_length: limit, read_timeout: remaining]}
    else
      _expired -> {:error, :http_invocation_closed}
    end
  end

  defp runtime_read_options(_conn, limit), do: {:ok, [length: limit, read_length: limit]}

  defp parsed_json_body(
         %Plug.Conn{
           private: %{arbor_mcp_http_binding: _binding},
           body_params: %{"_json" => value} = params
         } = conn,
         limit
       )
       when map_size(params) == 1,
       do: encode_parsed_body(value, conn, limit)

  defp parsed_json_body(
         %Plug.Conn{body_params: %{"_json" => _value} = params} = conn,
         _body_limit
       )
       when map_size(params) == 1 do
    {:ok, "", conn}
  end

  defp parsed_json_body(%Plug.Conn{body_params: params} = conn, body_limit)
       when is_map(params) and not is_struct(params) and map_size(params) > 0 do
    if json_request?(conn) do
      encode_parsed_body(params, conn, body_limit)
    else
      {:ok, "", conn}
    end
  end

  defp parsed_json_body(conn, _body_limit), do: {:ok, "", conn}

  defp encode_parsed_body(
         params,
         %Plug.Conn{private: %{arbor_mcp_http_binding: binding, arbor_mcp_runtime: runtime}} =
           conn,
         body_limit
       ) do
    with {:ok, proof} <- HTTPWriterBinding.validate(binding, runtime),
         {:ok, %{wire: body}} <-
           OutputCodec.prepare(params,
             codec: :json,
             deadline: proof.deadline,
             max_frame_bytes: body_limit + 1,
             max_term_bytes: body_limit + 1
           ) do
      {:ok, body, conn}
    else
      {:error, reason} when reason in [:output_frame_too_large, :output_term_too_large] ->
        {:error, :body_too_large}

      _invalid ->
        {:error, :invalid_json_rpc_envelope}
    end
  end

  defp encode_parsed_body(params, conn, body_limit) do
    json_library = Application.get_env(:phoenix, :json_library, Jason)

    try do
      body = json_library.encode_to_iodata!(params) |> IO.iodata_to_binary()

      if byte_size(body) <= body_limit do
        {:ok, body, conn}
      else
        {:error, :body_too_large}
      end
    rescue
      _exception -> {:ok, "", conn}
    end
  end

  defp json_request?(conn) do
    case Plug.Conn.Utils.content_type(List.first(get_req_header(conn, "content-type"), "")) do
      {:ok, "application", subtype, _params} ->
        subtype == "json" or String.ends_with?(subtype, "+json")

      _other ->
        false
    end
  end

  defp resolve_handler_opts(conn, request, opts) do
    handler_opts = Map.get(opts, :handler_opts, [])

    resolved =
      case handler_opts do
        fun when is_function(fun, 2) ->
          fun.(conn, request)

        fun when is_function(fun, 1) ->
          fun.(conn)

        {module, function, args} when is_atom(module) and is_atom(function) and is_list(args) ->
          apply(module, function, [conn, request | args])

        other ->
          other
      end

    {:ok, Map.put(opts, :handler_opts, resolved)}
  rescue
    _exception ->
      Logger.error("Failed to resolve MCP handler_opts")
      {:error, :handler_opts_failed}
  catch
    _kind, _reason -> {:error, :handler_opts_failed}
  end

  defp resolve_mrtr_identity(conn, request, token_info, opts) do
    principal =
      resolve_identity_value(
        Map.get(opts, :principal_id),
        conn,
        request,
        token_info,
        token_claim(token_info, [
          "sub",
          :sub,
          "principal_id",
          :principal_id,
          "client_id",
          :client_id
        ])
      )

    tenant =
      resolve_identity_value(
        Map.get(opts, :tenant_id),
        conn,
        request,
        token_info,
        token_claim(token_info, ["tenant_id", :tenant_id, "tenant", :tenant])
      )

    with true <- is_nil(principal) or is_binary(principal),
         true <- is_nil(tenant) or is_binary(tenant) do
      {:ok, opts |> Map.put(:principal_id, principal) |> Map.put(:tenant_id, tenant)}
    else
      false -> {:error, :invalid_mrtr_identity}
    end
  rescue
    _exception ->
      Logger.error("Failed to resolve MRTR identity")
      {:error, :invalid_mrtr_identity}
  end

  defp resolve_identity_value(nil, _conn, _request, _token_info, fallback), do: fallback

  defp resolve_identity_value(fun, conn, request, token_info, _fallback)
       when is_function(fun, 3),
       do: fun.(conn, request, token_info)

  defp resolve_identity_value(fun, conn, request, _token_info, _fallback)
       when is_function(fun, 2),
       do: fun.(conn, request)

  defp resolve_identity_value(fun, conn, _request, _token_info, _fallback)
       when is_function(fun, 1),
       do: fun.(conn)

  defp resolve_identity_value({module, function, args}, conn, request, token_info, _fallback)
       when is_atom(module) and is_atom(function) and is_list(args),
       do: apply(module, function, [conn, request, token_info | args])

  defp resolve_identity_value(value, _conn, _request, _token_info, _fallback), do: value

  defp token_claim(token_info, keys) when is_map(token_info) do
    Enum.find_value(keys, &Map.get(token_info, &1))
  end

  defp token_claim(_token_info, _keys), do: nil

  # Handle session termination via DELETE request
  defp handle_session_delete(conn, session_id, opts, require_streamable_lifecycle?) do
    request = %{"method" => "session/delete"}

    with :ok <- validate_session_id_value(session_id),
         {:ok, conn} <- validate_request_origin(conn, opts),
         {:ok, token_info} <- authorize_request(conn, request, opts),
         {:ok, opts} <- resolve_mrtr_identity(conn, request, token_info, opts),
         {:ok, session_manager} <- ensure_session_manager(opts.session_manager),
         :ok <-
           ensure_delete_session(
             session_manager,
             session_id,
             session_metadata(opts, token_info, :http),
             require_streamable_lifecycle?
           ),
         {:ok, conn} <-
           validate_delete_protocol_version(
             conn,
             request,
             session_manager,
             session_id,
             require_streamable_lifecycle?
           ),
         :ok <- session_manager.terminate_session(session_id) do
      Arbor.MCP.SubscriptionRegistry.remove_session(session_id)

      # Try to stop the SSE handler if it exists
      case lookup_sse_handler(session_id) do
        {:ok, handler_pid} ->
          if Process.alive?(handler_pid) do
            SSEHandler.close(handler_pid)
          end

          cleanup_sse_handler(session_id)

        {:error, _} ->
          # Session not found in ETS, but that's OK
          :ok
      end

      conn
      |> maybe_add_cors_headers(opts)
      |> add_protocol_version_header()
      |> send_resp(204, "")
    else
      {:error, :invalid_session_id} ->
        reject_invalid_session_id(conn, opts)

      {:error, :session_manager_unavailable} ->
        session_manager_unavailable_response(conn, opts)

      {:error, {:auth_error, {status, www_auth_header, body}}} ->
        conn
        |> maybe_add_cors_headers(opts)
        |> put_resp_header("www-authenticate", www_auth_header)
        |> send_resp(status, body)

      {:error, :oauth_guard_disabled} ->
        conn
        |> maybe_add_cors_headers(opts)
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(Core.oauth_guard_disabled_error()))

      {:error, :scope_policy_missing} ->
        scope_policy_error_response(conn, opts)

      {:error, :invalid_mrtr_identity} ->
        invalid_mrtr_identity_response(conn, opts)

      {:error, reason} when reason in [:session_not_found, :session_identity_mismatch] ->
        reject_unknown_session(conn, opts)

      {:error, :session_not_initialized} ->
        session_lifecycle_rejection_response(
          conn,
          opts,
          session_id,
          nil,
          :session_not_initialized
        )

      {:error, {:protocol_version_mismatch, message, expected_version}} ->
        error_response =
          JSONRPC.error(
            nil,
            ErrorCodes.invalid_request(),
            message,
            %{"expectedVersion" => expected_version}
          )

        conn
        |> assign(:request_protocol_version, expected_version)
        |> maybe_add_cors_headers(opts)
        |> add_protocol_version_header()
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(error_response))

      {:error, :origin_not_allowed} ->
        conn
        |> maybe_add_cors_headers(opts)
        |> send_resp(403, "Origin not allowed")
    end
  end

  defp ensure_delete_session(session_manager, session_id, metadata, true),
    do: ensure_initialized_session(session_manager, session_id, metadata)

  defp ensure_delete_session(session_manager, session_id, metadata, false),
    do: session_manager.ensure_session(session_id, metadata)

  defp validate_delete_protocol_version(conn, request, session_manager, session_id, true),
    do: validate_legacy_protocol_version(conn, request, session_manager, session_id)

  defp validate_delete_protocol_version(conn, _request, _manager, _session_id, false),
    do: {:ok, conn}

  # The deprecated 2024-11-05 transport receives client messages on the URI
  # announced by the initial `endpoint` event and sends JSON-RPC responses on
  # the already-open SSE stream.
  defp handle_runtime_legacy_post(conn, opts) do
    with {:ok, conn, id} <- fetch_legacy_http_sse_session(conn),
         :ok <- legacy_alias_reference(conn, id) do
      conn
      |> put_private(:arbor_mcp_legacy_session, id)
      |> handle_mcp_request(opts)
    else
      {:error, :invalid_session_id} -> reject_invalid_session_id(conn, opts)
    end
  end

  defp legacy_alias_reference(conn, id) do
    case get_or_create_session_id(conn, :allow_new_session) do
      {:ok, :new_session} -> :ok
      {:ok, {:existing_session, ^id}} -> :ok
      _invalid -> {:error, :invalid_session_id}
    end
  end

  defp handle_legacy_http_sse_post(conn, opts) do
    with {:ok, conn, session_id} <- fetch_legacy_http_sse_session(conn),
         {:ok, conn} <- validate_request_origin(conn, opts),
         {:ok, body, conn} <- read_or_cached_body(conn, opts),
         {:ok, request} <- parse_json(body),
         conn = assign_request_protocol_version(conn, request),
         {:ok, conn} <-
           validate_protocol_version(conn, request, opts.session_manager, session_id),
         :ok <- validate_request_method_params(request),
         {:ok, token_info} <- authorize_request(conn, request, opts),
         {:ok, opts} <- resolve_handler_opts(conn, request, opts),
         {:ok, opts} <- resolve_mrtr_identity(conn, request, token_info, opts),
         {:ok, session_manager} <- ensure_session_manager(opts.session_manager),
         :ok <-
           ensure_deprecated_request_session(
             session_manager,
             session_id,
             request,
             session_metadata(opts, token_info, :http)
           ),
         :ok <- authorize_session_lifecycle(session_manager, session_id, request),
         :ok <- claim_request_id(session_manager, session_id, request),
         {:ok, handler} <- fetch_legacy_http_sse_handler(session_id),
         true <- Process.alive?(handler),
         result <-
           process_mcp_request(
             request,
             opts
             |> Map.put(:session_id, session_id)
             |> Map.put(:request_headers, conn.req_headers)
           ),
         {:ok, result, conn} <-
           finalize_legacy_protocol_version(
             result,
             conn,
             request,
             session_manager,
             session_id
           ),
         :ok <-
           deliver_legacy_http_sse_result_with_rollback(
             handler,
             request,
             result,
             session_manager,
             session_id
           ) do
      conn
      |> maybe_add_cors_headers(opts)
      |> add_protocol_version_header()
      |> send_resp(202, "")
    else
      {:error, :invalid_session_id} ->
        reject_invalid_session_id(conn, opts)

      {:error, :legacy_session_not_found} ->
        conn
        |> maybe_add_cors_headers(opts)
        |> send_resp(404, "Legacy SSE session not found")

      {:error, reason} when reason in [:session_not_found, :session_identity_mismatch] ->
        reject_unknown_session(conn, opts)

      {:error, {:request_id_rejected, failed_session_id, request_id, reason, method}} ->
        handle_request_id_rejection(
          conn,
          opts,
          opts.session_manager,
          failed_session_id,
          request_id,
          reason,
          method
        )

      {:error, {:session_lifecycle_rejected, request_id, reason}} ->
        session_lifecycle_rejection_response(conn, opts, nil, request_id, reason)

      false ->
        conn
        |> maybe_add_cors_headers(opts)
        |> send_resp(404, "Legacy SSE session not found")

      {:error, {:auth_error, {status, www_auth_header, body}}} ->
        conn
        |> maybe_add_cors_headers(opts)
        |> put_resp_header("www-authenticate", www_auth_header)
        |> send_resp(status, body)

      {:error, :scope_policy_missing} ->
        scope_policy_error_response(conn, opts)

      {:error, {:invalid_method_params, request_id, error}} ->
        conn
        |> maybe_add_cors_headers(opts)
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(JSONRPC.error(request_id, error)))

      {:error, {:protocol_version_mismatch, message, expected_version}} ->
        error_response =
          JSONRPC.error(
            nil,
            ErrorCodes.invalid_request(),
            message,
            %{"expectedVersion" => expected_version}
          )

        conn
        |> assign(:request_protocol_version, expected_version)
        |> maybe_add_cors_headers(opts)
        |> add_protocol_version_header()
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(error_response))

      {:error, :session_manager_unavailable} ->
        session_manager_unavailable_response(conn, opts)

      {:error, :origin_not_allowed} ->
        conn
        |> maybe_add_cors_headers(opts)
        |> send_resp(403, "Origin not allowed")

      {:error, :body_too_large} ->
        conn
        |> maybe_add_cors_headers(opts)
        |> send_resp(413, "Request body too large")

      {:error, reason} ->
        Logger.debug("Legacy HTTP+SSE POST rejected", reason: LogSummary.describe(reason))

        conn
        |> maybe_add_cors_headers(opts)
        |> send_resp(400, "Invalid legacy HTTP+SSE request")
    end
  end

  defp fetch_legacy_http_sse_session(conn) do
    conn = fetch_query_params(conn)

    case Map.get(conn.query_params, "sessionId") do
      session_id when is_binary(session_id) ->
        case validate_session_id_value(session_id) do
          :ok -> {:ok, conn, session_id}
          {:error, :invalid_session_id} = error -> error
        end

      _missing ->
        {:error, :invalid_session_id}
    end
  rescue
    Plug.Conn.InvalidQueryError -> {:error, :invalid_session_id}
  end

  defp fetch_legacy_http_sse_handler(session_id) do
    case lookup_sse_handler(session_id) do
      {:ok, handler} -> {:ok, handler}
      {:error, _reason} -> {:error, :legacy_session_not_found}
    end
  end

  defp deliver_legacy_http_sse_result_with_rollback(
         handler,
         request,
         result,
         session_manager,
         session_id
       ) do
    case deliver_legacy_http_sse_result(handler, request, result) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        if Map.get(request, "method") == "initialize" do
          cleanup_failed_initialization(session_manager, session_id)
        end

        error
    end
  end

  defp deliver_legacy_http_sse_result(_handler, _request, {:notification, _}), do: :ok

  defp deliver_legacy_http_sse_result(handler, _request, {:ok, response}) do
    deliver_legacy_http_sse_message(handler, response)
  end

  defp deliver_legacy_http_sse_result(handler, _request, {:http_error, _status, response}) do
    deliver_legacy_http_sse_message(handler, response)
  end

  defp deliver_legacy_http_sse_result(handler, request, {:error, reason}) do
    Logger.error("Legacy HTTP+SSE request processing error",
      reason: LogSummary.describe(reason)
    )

    response =
      JSONRPC.error(Map.get(request, "id"), ErrorCodes.internal_error(), "Internal error")

    deliver_legacy_http_sse_message(handler, response)
  end

  defp deliver_legacy_http_sse_result(handler, request, _unsupported_result) do
    response =
      JSONRPC.error(
        Map.get(request, "id"),
        ErrorCodes.invalid_request(),
        "Response streaming is not supported by the deprecated HTTP+SSE transport"
      )

    deliver_legacy_http_sse_message(handler, response)
  end

  defp deliver_legacy_http_sse_message(handler, response) do
    with :ok <- SSEHandler.request_send(handler) do
      SSEHandler.send_event(handler, "message", response)
    end
  catch
    :exit, _reason -> {:error, :legacy_session_not_found}
  end

  # Handle Server-Sent Events connections
  defp handle_sse_connection(conn, opts) do
    request = %{"method" => "session/listen"}
    deprecated_http_sse? = is_function(Map.get(opts, :initial_sse_event_builder), 1)
    session_request = if deprecated_http_sse?, do: :allow_new_session, else: request

    client_info = %{
      user_agent: get_req_header(conn, "user-agent") |> List.first(),
      origin: get_req_header(conn, "origin") |> List.first(),
      referer: get_req_header(conn, "referer") |> List.first(),
      remote_ip: get_peer_data(conn).address |> :inet.ntoa() |> to_string()
    }

    with {:ok, session_reference} <- get_or_create_session_id(conn, session_request),
         {:ok, conn} <- validate_request_origin(conn, opts),
         {:ok, token_info} <- authorize_request(conn, request, opts),
         {:ok, opts} <- resolve_mrtr_identity(conn, request, token_info, opts),
         {:ok, session_manager} <- ensure_session_manager(opts.session_manager),
         {:ok, session_id} <-
           establish_sse_session(
             session_manager,
             session_reference,
             session_metadata(opts, token_info, :sse, %{client_info: client_info}),
             deprecated_http_sse?
           ),
         {:ok, conn} <-
           validate_sse_session_lifecycle(
             conn,
             request,
             session_manager,
             session_id,
             deprecated_http_sse?
           ) do
      conn =
        conn
        |> maybe_add_cors_headers(opts)
        |> add_protocol_version_header()
        |> put_resp_header("content-type", "text/event-stream")
        |> put_resp_header("x-accel-buffering", "no")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("connection", "keep-alive")
        |> send_chunked(200)

      serve_sse(conn, session_id, session_manager, initial_sse_opts(opts, session_id))
    else
      {:error, :invalid_session_id} ->
        reject_invalid_session_id(conn, opts)

      {:error, {:auth_error, {status, www_auth_header, body}}} ->
        conn
        |> maybe_add_cors_headers(opts)
        |> put_resp_header("www-authenticate", www_auth_header)
        |> send_resp(status, body)

      {:error, :scope_policy_missing} ->
        scope_policy_error_response(conn, opts)

      {:error, :oauth_guard_disabled} ->
        conn
        |> maybe_add_cors_headers(opts)
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(Core.oauth_guard_disabled_error()))

      {:error, :invalid_mrtr_identity} ->
        invalid_mrtr_identity_response(conn, opts)

      {:error, reason} when reason in [:session_not_found, :session_identity_mismatch] ->
        reject_unknown_session(conn, opts)

      {:error, :session_limit_exceeded} ->
        session_limit_response(conn, opts)

      {:error, :session_required} ->
        reject_missing_session(conn, opts)

      {:error, :session_not_initialized} ->
        session_lifecycle_rejection_response(
          conn,
          opts,
          nil,
          nil,
          :session_not_initialized
        )

      {:error, {:protocol_version_mismatch, message, expected_version}} ->
        error_response =
          JSONRPC.error(
            nil,
            ErrorCodes.invalid_request(),
            message,
            %{"expectedVersion" => expected_version}
          )

        conn
        |> assign(:request_protocol_version, expected_version)
        |> maybe_add_cors_headers(opts)
        |> add_protocol_version_header()
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(error_response))

      {:error, :session_manager_unavailable} ->
        session_manager_unavailable_response(conn, opts)

      {:error, :origin_not_allowed} ->
        conn
        |> maybe_add_cors_headers(opts)
        |> send_resp(403, "Origin not allowed")
    end
  end

  defp establish_sse_session(session_manager, :new_session, metadata, true) do
    create_session(session_manager, metadata)
  end

  defp establish_sse_session(_session_manager, :new_session, _metadata, false),
    do: {:error, :session_required}

  defp establish_sse_session(session_manager, {:existing_session, session_id}, metadata, legacy?) do
    result =
      if legacy? do
        session_manager.ensure_session(session_id, metadata)
      else
        ensure_initialized_session(session_manager, session_id, metadata)
      end

    case result do
      :ok -> {:ok, session_id}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _reason -> {:error, :session_not_found}
  end

  defp validate_sse_session_lifecycle(conn, _request, _manager, _session_id, true),
    do: {:ok, conn}

  defp validate_sse_session_lifecycle(conn, request, session_manager, session_id, false) do
    validate_legacy_protocol_version(conn, request, session_manager, session_id)
  end

  defp initial_sse_opts(%{initial_sse_event_builder: builder} = opts, session_id)
       when is_function(builder, 1) do
    opts
    |> Map.delete(:initial_sse_event_builder)
    |> Map.put(:initial_sse_event, builder.(session_id))
  end

  defp initial_sse_opts(opts, _session_id), do: opts

  # `:sse_mode` decides how a GET SSE request is served:
  #
  #   * `:stream` (default) - start an `Arbor.MCP.HttpPlug.SSEHandler` and keep the
  #     request process alive for the lifetime of the stream
  #   * `:oneshot` - write a single `connected` event and return, for callers
  #     (harnesses, health checks) that only need the handshake
  #
  # The mode is resolved in `init/1`, so the request path below has no
  # environment lookups or test-only branches (audit L6). Opts maps that were
  # hand-built rather than produced by `init/1` have no `:sse_mode` key, so the
  # default is resolved once here for them.
  defp serve_sse(conn, session_id, session_manager, opts)
       when not is_map_key(opts, :sse_mode) do
    serve_sse(conn, session_id, session_manager, Map.put(opts, :sse_mode, default_sse_mode()))
  end

  defp serve_sse(conn, session_id, _session_manager, %{sse_mode: :oneshot} = opts) do
    {event_type, data} =
      Map.get(opts, :initial_sse_event, {"connected", %{session_id: session_id}})

    {:ok, conn} = chunk(conn, format_initial_sse_event(event_type, data))

    conn
  end

  defp serve_sse(conn, session_id, session_manager, opts) do
    # Use the SSE handler with backpressure control
    {:ok, handler} = SSEHandler.start_link(conn, session_id, opts)

    # Register with session manager
    session_manager.update_session(session_id, %{handler_pid: handler})

    # Also register in our simple ETS registry
    register_sse_handler(session_id, handler, session_manager)

    # Block until handler exits
    ref = Process.monitor(handler)

    receive do
      {:DOWN, ^ref, :process, ^handler, reason} ->
        # A disconnected GET stream does not terminate its MCP session. Keep
        # subscriptions and persisted events until explicit DELETE or TTL
        # cleanup so Last-Event-ID can resume the stream. Scoped cleanup avoids
        # removing a newer handler that superseded this one while it exited.
        cleanup_sse_handler(session_id, handler)

        Logger.debug("Legacy SSE handler exited",
          session_id_hash: LogSummary.fingerprint(session_id),
          reason: LogSummary.describe(reason)
        )

        conn
    end
  end

  defp format_initial_sse_event(event_type, {:raw, data}) do
    "event: #{event_type}\ndata: #{data}\n\n"
  end

  defp format_initial_sse_event(event_type, data) do
    "event: #{event_type}\ndata: #{Jason.encode!(data)}\n\n"
  end

  # Default SSE mode. `:arbor_mcp, :sse_mode` selects it explicitly; the legacy
  # `:arbor_mcp, :test_mode` flag is still honoured here (and only here) so
  # existing harnesses keep working.
  defp default_sse_mode do
    case Application.get_env(:arbor_mcp, :sse_mode) do
      mode when mode in [:stream, :oneshot] ->
        mode

      _unset ->
        if Application.get_env(:arbor_mcp, :test_mode, false), do: :oneshot, else: :stream
    end
  end

  # The default session manager is supervised by the :arbor_mcp application
  # (see Arbor.MCP.Application). If it is not running, fail fast instead of
  # lazily starting an unsupervised copy linked to the HTTP request process.
  defp ensure_session_manager(Arbor.MCP.SessionManager) do
    if Process.whereis(Arbor.MCP.SessionManager) do
      {:ok, Arbor.MCP.SessionManager}
    else
      Logger.error(
        "Arbor.MCP.SessionManager is not running. Start the :arbor_mcp application " <>
          "(or add Arbor.MCP.SessionManager to your supervision tree) before " <>
          "serving MCP session requests."
      )

      {:error, :session_manager_unavailable}
    end
  end

  defp ensure_session_manager(session_manager), do: {:ok, session_manager}

  defp establish_request_session(_session_manager, nil, _request, _metadata), do: {:ok, nil}

  defp establish_request_session(session_manager, :new_session, _request, metadata) do
    with {:ok, session_manager} <- ensure_session_manager(session_manager) do
      create_session(session_manager, metadata)
    end
  end

  defp establish_request_session(
         session_manager,
         {:existing_session, session_id},
         %{"method" => "initialize"},
         metadata
       ) do
    with {:ok, session_manager} <- ensure_session_manager(session_manager),
         :ok <- session_manager.ensure_session(session_id, metadata) do
      {:ok, session_id}
    end
  catch
    :exit, _reason -> {:error, :session_not_found}
  end

  defp establish_request_session(
         session_manager,
         {:existing_session, session_id},
         request,
         metadata
       ) do
    with {:ok, session_manager} <- ensure_session_manager(session_manager),
         :ok <-
           normalize_initialized_session_result(
             ensure_initialized_session(session_manager, session_id, metadata),
             Map.get(request, "id")
           ) do
      {:ok, session_id}
    end
  catch
    :exit, _reason -> {:error, :session_not_found}
  end

  defp ensure_deprecated_request_session(
         session_manager,
         session_id,
         %{"method" => "initialize"},
         metadata
       ) do
    session_manager.ensure_session(session_id, metadata)
  end

  defp ensure_deprecated_request_session(session_manager, session_id, _request, metadata) do
    normalize_initialized_session_result(
      ensure_initialized_session(session_manager, session_id, metadata),
      nil
    )
  end

  defp normalize_initialized_session_result({:error, :session_not_initialized}, request_id),
    do: {:error, {:session_lifecycle_rejected, request_id, :session_not_initialized}}

  defp normalize_initialized_session_result(result, _request_id), do: result

  defp ensure_initialized_session(session_manager, session_id, metadata) do
    if is_atom(session_manager) and
         function_exported?(session_manager, :ensure_initialized_session, 2) do
      session_manager.ensure_initialized_session(session_id, metadata)
    else
      {:error, :session_manager_unavailable}
    end
  end

  # Notifications and modern stateless requests do not participate in legacy
  # session request-ID tracking. Valid request IDs are claimed atomically by
  # the session manager before any handler code runs.
  defp claim_request_id(_session_manager, nil, _request), do: :ok

  defp claim_request_id(session_manager, session_id, %{"id" => request_id} = request)
       when is_binary(request_id) or is_integer(request_id) do
    if is_atom(session_manager) and function_exported?(session_manager, :claim_request_id, 2) do
      case session_manager.claim_request_id(session_id, request_id) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error,
           {:request_id_rejected, session_id, request_id, reason, Map.get(request, "method")}}

        _invalid ->
          {:error,
           {:request_id_rejected, session_id, request_id, :tracking_unavailable,
            Map.get(request, "method")}}
      end
    else
      {:error,
       {:request_id_rejected, session_id, request_id, :tracking_unavailable,
        Map.get(request, "method")}}
    end
  catch
    :exit, _reason ->
      {:error,
       {:request_id_rejected, session_id, request_id, :tracking_unavailable,
        Map.get(request, "method")}}
  end

  defp claim_request_id(_session_manager, _session_id, _notification_or_invalid_request), do: :ok

  defp authorize_session_lifecycle(_session_manager, nil, _request), do: :ok

  defp authorize_session_lifecycle(
         session_manager,
         session_id,
         %{"method" => "initialize"} = request
       ) do
    request_id = Map.get(request, "id")

    if is_atom(session_manager) and function_exported?(session_manager, :claim_initialization, 1) do
      case session_manager.claim_initialization(session_id) do
        :ok -> :ok
        {:error, :session_not_found} = error -> error
        {:error, reason} -> {:error, {:session_lifecycle_rejected, request_id, reason}}
        _invalid -> {:error, :session_manager_unavailable}
      end
    else
      {:error, :session_manager_unavailable}
    end
  catch
    :exit, _reason -> {:error, :session_not_found}
  end

  defp authorize_session_lifecycle(_session_manager, _session_id, _request), do: :ok

  defp session_metadata(opts, token_info, transport, extra \\ %{}) do
    %{
      transport: transport,
      transport_endpoint: Map.get(opts, :http_endpoint),
      principal_id: Map.get(opts, :principal_id),
      tenant_id: Map.get(opts, :tenant_id),
      issuer: token_claim(token_info, ["iss", :iss]),
      audience:
        token_claim(token_info, ["aud", :aud]) ||
          get_in(opts, [:protected_resource_metadata, :resource]),
      client_info: Map.get(extra, :client_info, %{})
    }
  end

  defp maybe_put_session_header(%{assigns: %{suppress_session_header: true}} = conn, _session_id),
    do: conn

  defp maybe_put_session_header(conn, session_id) when not is_binary(session_id), do: conn

  defp maybe_put_session_header(conn, session_id) do
    put_resp_header(conn, "mcp-session-id", session_id)
  end

  defp create_session(session_manager, metadata) do
    case session_manager.create_session(metadata) do
      session_id when is_binary(session_id) -> {:ok, session_id}
      {:error, :session_limit_exceeded} = error -> error
      _invalid -> {:error, :session_manager_unavailable}
    end
  catch
    :exit, _reason -> {:error, :session_manager_unavailable}
  end

  defp session_manager_unavailable_response(conn, opts) do
    error_response =
      JSONRPC.error(nil, ErrorCodes.internal_error(), "Service unavailable", %{
        "type" => "session_manager_unavailable"
      })

    conn
    |> maybe_add_cors_headers(opts)
    |> put_resp_content_type("application/json")
    |> send_resp(503, Jason.encode!(error_response))
  end

  defp invalid_mrtr_identity_response(conn, opts) do
    error_response = JSONRPC.error(nil, ErrorCodes.internal_error(), "Internal error")

    conn
    |> maybe_add_cors_headers(opts)
    |> put_resp_content_type("application/json")
    |> send_resp(500, Jason.encode!(error_response))
  end

  defp session_limit_response(conn, opts) do
    error_response =
      JSONRPC.error(nil, ErrorCodes.internal_error(), "Service unavailable", %{
        "type" => "session_capacity_exceeded"
      })

    conn
    |> maybe_add_cors_headers(opts)
    |> put_resp_header("retry-after", "1")
    |> put_resp_content_type("application/json")
    |> send_resp(503, Jason.encode!(error_response))
  end

  defp request_id_rejection_response(conn, opts, session_id, request_id, reason) do
    {status, message, type} =
      case reason do
        :duplicate_request_id ->
          {400, "Request ID has already been used in this session", "duplicate_request_id"}

        :request_id_limit_exceeded ->
          {429, "Request ID tracking capacity exceeded", "request_id_capacity_exceeded"}

        _other ->
          {503, "Service unavailable", "request_id_tracking_unavailable"}
      end

    error_response =
      JSONRPC.error(request_id, ErrorCodes.invalid_request(), message, %{"type" => type})

    conn =
      conn
      |> maybe_add_cors_headers(opts)
      |> add_protocol_version_header()
      |> maybe_put_session_header(session_id)
      |> put_resp_content_type("application/json")

    conn = if status in [429, 503], do: put_resp_header(conn, "retry-after", "1"), else: conn
    send_resp(conn, status, Jason.encode!(error_response))
  end

  defp handle_request_id_rejection(
         conn,
         %{runtime: runtime} = opts,
         _session_manager,
         _session_id,
         request_id,
         reason,
         "initialize"
       )
       when not is_nil(runtime),
       do: request_id_rejection_response(conn, opts, nil, request_id, reason)

  defp handle_request_id_rejection(
         conn,
         opts,
         session_manager,
         session_id,
         request_id,
         reason,
         "initialize"
       ) do
    cleanup_failed_initialization(session_manager, session_id)
    request_id_rejection_response(conn, opts, nil, request_id, reason)
  end

  defp handle_request_id_rejection(
         conn,
         opts,
         _session_manager,
         session_id,
         request_id,
         reason,
         _method
       ) do
    request_id_rejection_response(conn, opts, session_id, request_id, reason)
  end

  defp session_lifecycle_rejection_response(conn, opts, session_id, request_id, reason) do
    {message, type} =
      case reason do
        :session_not_initialized ->
          {"Session initialization has not completed", "session_not_initialized"}

        :session_already_initialized ->
          {"Session is already initialized", "session_already_initialized"}

        :initialization_in_progress ->
          {"Session initialization is already in progress", "initialization_in_progress"}

        _other ->
          {"Session lifecycle request rejected", "session_lifecycle_rejected"}
      end

    response =
      JSONRPC.error(request_id, ErrorCodes.invalid_request(), message, %{"type" => type})

    conn
    |> maybe_add_cors_headers(opts)
    |> add_protocol_version_header()
    |> maybe_put_session_header(session_id)
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(response))
  end

  defp scope_policy_error_response(conn, opts) do
    body =
      Jason.encode!(%{
        "error" => "insufficient_scope",
        "error_description" => "No OAuth scope policy is configured for this MCP method"
      })

    conn
    |> maybe_add_cors_headers(opts)
    |> put_resp_content_type("application/json")
    |> send_resp(403, body)
  end

  # Process MCP request using the configured handler
  defp process_or_open_request_stream(conn, request, opts) do
    if request_stream?(conn, request) do
      owner = self()

      process_fun = fn ->
        process_mcp_request(request, Map.put(opts, :request_notification_target, owner))
      end

      {:request_stream, Map.fetch!(request, "id"), process_fun}
    else
      process_mcp_request(request, opts)
    end
  end

  defp request_stream?(conn, %{"id" => _id, "params" => %{"_meta" => meta}})
       when is_map(meta) do
    stream_requested? =
      Map.has_key?(meta, "progressToken") or
        Map.has_key?(meta, "io.modelcontextprotocol/logLevel")

    modern_http_request?(conn, %{"params" => %{"_meta" => meta}}) and stream_requested? and
      accepts_event_stream?(conn)
  end

  defp request_stream?(_conn, _request), do: false

  defp accepts_event_stream?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/event-stream"))
  end

  defp process_mcp_request(%{"method" => "subscriptions/listen"} = request, opts) do
    open_http_subscription(request, opts)
  end

  defp process_mcp_request(request, opts) do
    handler = opts.handler
    handler_opts = Map.get(opts, :handler_opts, [])
    server_info = opts.server_info

    case handler do
      nil ->
        {:error, :no_handler_configured}

      handler_module when is_atom(handler_module) ->
        # Use Arbor.MCP.MessageProcessor to process the request
        conn =
          Arbor.MCP.MessageProcessor.new(request,
            transport: :http,
            session_id: Map.get(opts, :session_id)
          )

        # Create a simple processor that delegates to the handler
        processed_conn =
          Arbor.MCP.MessageProcessor.process(conn, %{
            handler: handler_module,
            handler_opts: handler_opts,
            handler_call_timeout: Map.get(opts, :handler_call_timeout, 10_000),
            server_info: server_info,
            server_capabilities: Map.get(opts, :server_capabilities),
            protocol_mode: Map.get(opts, :protocol_mode),
            instructions: Map.get(opts, :instructions),
            request_state: Map.get(opts, :request_state),
            endpoint: Map.get(opts, :endpoint, "/mcp"),
            max_input_requests: Map.get(opts, :max_input_requests, 16),
            max_mrtr_bytes: Map.get(opts, :max_mrtr_bytes, 1_048_576),
            replay_cache: Map.get(opts, :replay_cache),
            require_replay_protection: Map.get(opts, :require_replay_protection, false),
            principal_id: Map.get(opts, :principal_id),
            tenant_id: Map.get(opts, :tenant_id),
            request_notification_target: Map.get(opts, :request_notification_target),
            request_headers: Map.get(opts, :request_headers, [])
          })

        case processed_conn.response do
          nil ->
            # Check if this was a notification (no id field)
            if Map.get(request, "id") == nil do
              # Notifications don't get responses - return special marker
              {:notification, nil}
            else
              {:error, :no_response}
            end

          response ->
            processed_response(response, processed_conn.assigns)
        end

      handler_fun when is_function(handler_fun, 1) ->
        # Direct function handler
        case handler_fun.(request) do
          {:ok, response} -> {:ok, response}
          {:error, reason} -> {:error, reason}
          response when is_map(response) -> {:ok, response}
        end
    end
  end

  defp processed_response(
         %{"jsonrpc" => "2.0", "error" => _} = response,
         %{http_status: status}
       ) do
    {:http_error, status, response}
  end

  defp processed_response(response, _assigns), do: {:ok, response}

  defp open_http_subscription(request, opts) do
    id = Map.get(request, "id")
    params = Map.get(request, "params") || %{}

    with {:ok, context} <- RequestContext.from_message(request),
         :ok <- RequestContext.validate_protocol_mode(context, Map.get(opts, :protocol_mode)),
         :ok <- RequestContext.validate_method(context),
         :modern <- context.era,
         subscription_options = subscription_options(opts, context),
         {:ok, entry} <-
           Subscriptions.listen(
             id,
             Map.get(params, "notifications"),
             self(),
             subscription_options
           ) do
      {:subscription, entry}
    else
      {:error, reason} -> {:ok, subscription_error(id, reason)}
      _other -> {:ok, subscription_error(id, :modern_protocol_required)}
    end
  end

  defp subscription_options(opts, context) do
    opts
    |> Map.to_list()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Keyword.put(:client_capabilities, context.client_capabilities)
    |> Subscriptions.runtime_options(Map.get(opts, :handler))
  end

  defp subscription_options(opts) do
    opts
    |> Map.to_list()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Subscriptions.runtime_options(Map.get(opts, :handler))
  end

  defp subscription_error(id, %ProtocolError{} = error) do
    JSONRPC.error(id, error.code, error.message, error.data)
  end

  defp subscription_error(id, reason) do
    JSONRPC.error(id, ErrorCodes.invalid_params(), "Subscription request rejected", %{
      "reason" => subscription_reason(reason)
    })
  end

  defp subscription_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp subscription_reason(reason), do: inspect(reason)

  defp subscription_keepalive_interval!(:infinity), do: :infinity

  defp subscription_keepalive_interval!(interval)
       when is_integer(interval) and interval > 0,
       do: interval

  defp subscription_keepalive_interval!(interval) do
    raise ArgumentError,
          ":subscription_keepalive_interval_ms must be a positive integer or :infinity, " <>
            "got: #{inspect(interval)}"
  end

  # Add CORS headers if enabled
  defp maybe_add_cors_headers(conn, %{cors_enabled: true} = opts) do
    case cors_response_origin(conn, opts) do
      nil ->
        conn

      origin ->
        conn
        |> put_resp_header("access-control-allow-origin", origin)
        |> put_resp_header("access-control-allow-methods", "GET, POST, DELETE, OPTIONS")
        |> put_resp_header(
          "access-control-allow-headers",
          "content-type, authorization, mcp-protocol-version, mcp-session-id"
        )
    end
  end

  defp maybe_add_cors_headers(conn, _opts), do: conn

  defp validate_request_origin(conn, %{validate_origin: false}), do: {:ok, conn}

  defp validate_request_origin(conn, opts) do
    if origin_allowed?(conn, opts), do: {:ok, conn}, else: {:error, :origin_not_allowed}
  end

  # Host-header allow-list (DNS rebinding protection). Prefers the raw Host
  # header — the literal value the client sent — and falls back to the
  # adapter-parsed conn.host when the header is absent (e.g. HTTP/2
  # :authority).
  defp request_host_allowed?(conn, opts) do
    Core.host_allowed?(request_host(conn), Map.get(opts, :allowed_hosts, :any))
  end

  defp request_host(conn) do
    case get_req_header(conn, "host") do
      [host | _] -> host
      [] -> conn.host
    end
  end

  # 421 Misdirected Request: the Host header does not match this server.
  defp reject_disallowed_host(conn, opts) do
    error_response = JSONRPC.error(nil, ErrorCodes.invalid_request(), "Host header not allowed")

    conn
    |> maybe_add_cors_headers(opts)
    |> put_resp_content_type("application/json")
    |> send_resp(421, Jason.encode!(error_response))
  end

  defp origin_allowed?(conn, opts) do
    conn
    |> origin_context()
    |> Core.origin_allowed?(opts)
  end

  defp cors_response_origin(conn, %{allowed_origins: :any}) do
    conn
    |> origin_context()
    |> Core.cors_response_origin(%{allowed_origins: :any})
  end

  defp cors_response_origin(conn, opts) do
    conn
    |> origin_context()
    |> Core.cors_response_origin(opts)
  end

  defp request_origin(conn), do: get_req_header(conn, "origin") |> List.first()

  defp origin_context(conn) do
    %{
      origin: request_origin(conn),
      scheme: Atom.to_string(conn.scheme),
      host: conn.host,
      port: conn.port
    }
  end

  # A missing session header asks the server to issue an ID only during initialize.
  # A supplied ID is only a reference to an existing server-issued session.
  defp get_or_create_session_id(conn, request) do
    with {:ok, session_id} <- fetch_session_id_header(conn, "mcp-session-id"),
         {:ok, legacy_id} <- fetch_session_id_header(conn, "x-session-id") do
      case {session_id, legacy_id} do
        {nil, nil} -> missing_session_reference(request)
        {id, nil} -> {:ok, {:existing_session, id}}
        {nil, id} -> {:ok, {:existing_session, id}}
        {id, id} -> {:ok, {:existing_session, id}}
        {_mcp, _legacy} -> {:error, :invalid_session_id}
      end
    end
  end

  defp missing_session_reference(%{"method" => "initialize", "id" => _id}),
    do: {:ok, :new_session}

  defp missing_session_reference(:allow_new_session), do: {:ok, :new_session}

  defp missing_session_reference(_request), do: {:error, :session_required}

  defp fetch_session_id_header(conn, header) do
    case get_req_header(conn, header) do
      [] ->
        {:ok, nil}

      [value] ->
        if valid_session_id?(value) do
          {:ok, value}
        else
          {:error, :invalid_session_id}
        end

      _multiple ->
        {:error, :invalid_session_id}
    end
  end

  defp validate_session_id_value(session_id) do
    if valid_session_id?(session_id) do
      :ok
    else
      {:error, :invalid_session_id}
    end
  end

  # Client-supplied session ids are echoed back in response headers and used
  # as registry keys, so they are strictly validated: bounded length and the
  # printable token charset [A-Za-z0-9._~+/=-], covering UUID, hex, and
  # base64/base64url shapes.
  defp valid_session_id?(session_id) when is_binary(session_id) do
    byte_size(session_id) in 1..@session_id_max_bytes and
      valid_session_id_chars?(session_id)
  end

  defp valid_session_id_chars?(<<>>), do: true

  defp valid_session_id_chars?(<<c, rest::binary>>)
       when c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c in [?., ?_, ?~, ?+, ?/, ?=, ?-] do
    valid_session_id_chars?(rest)
  end

  defp valid_session_id_chars?(_other), do: false

  # 400 response for malformed session ids. Deliberately does not echo the
  # offending value or set a session header.
  defp reject_invalid_session_id(conn, opts) do
    error_response = JSONRPC.error(nil, ErrorCodes.invalid_request(), "Invalid session ID")

    conn
    |> maybe_add_cors_headers(opts)
    |> add_protocol_version_header()
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(error_response))
  end

  defp reject_unknown_session(conn, opts) do
    error_response = JSONRPC.error(nil, ErrorCodes.invalid_request(), "Session not found")

    conn
    |> maybe_add_cors_headers(opts)
    |> add_protocol_version_header()
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(error_response))
  end

  defp reject_missing_session(conn, opts) do
    error_response = JSONRPC.error(nil, ErrorCodes.invalid_request(), "Session ID required")

    conn
    |> maybe_add_cors_headers(opts)
    |> add_protocol_version_header()
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(error_response))
  end

  # Register SSE handler for a session
  defp register_sse_handler(session_id, handler_pid, session_manager) do
    previous_handler =
      case SessionRegistry.lookup(session_id) do
        {:ok, previous} when previous != handler_pid -> previous
        _other -> nil
      end

    case SessionRegistry.register(session_id, handler_pid) do
      :ok ->
        :ok

      {:error, :registry_not_started} ->
        Logger.error(
          "Arbor.MCP.HttpPlug.SessionRegistry is not running; SSE handler cannot be registered. " <>
            "Ensure the :arbor_mcp application is started.",
          session_id_hash: LogSummary.fingerprint(session_id)
        )
    end

    # Also register with the configured session manager if available
    if function_exported?(session_manager, :update_session, 2) do
      session_manager.update_session(session_id, %{handler_pid: handler_pid})
    end

    # Only one standalone GET stream owns a legacy session. Register the new
    # handler first so the old handler's scoped terminate cleanup cannot erase
    # it, then close the superseded stream.
    if is_pid(previous_handler) and Process.alive?(previous_handler) do
      SSEHandler.close(previous_handler)
    end

    case SSEHandler.replay(handler_pid) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to replay legacy SSE events",
          session_id_hash: LogSummary.fingerprint(session_id),
          reason: LogSummary.describe(reason)
        )
    end
  end

  # Look up SSE handler for a session
  defp lookup_sse_handler(session_id) do
    SessionRegistry.lookup(session_id)
  end

  @doc """
  Broadcasts a resource update to each live SSE client subscribed to `uri`.

  Subscription lookup is performed directly against ETS, and delivery uses
  independent tasks so backpressure from one client does not block the rest.
  The event is persisted before live delivery; sessions without a live SSE
  connection remain subscribed and receive it through Last-Event-ID replay
  after reconnecting. Expired sessions are removed by `Arbor.MCP.SessionManager`.
  """
  @spec broadcast_resource_update(String.t()) :: %{
          subscribers: non_neg_integer(),
          delivered: non_neg_integer()
        }
  def broadcast_resource_update(uri) when is_binary(uri) do
    session_ids = Arbor.MCP.SubscriptionRegistry.sessions(uri)

    delivered =
      session_ids
      |> Task.async_stream(&deliver_resource_update(&1, uri),
        ordered: false,
        timeout: 5_000,
        on_timeout: :kill_task
      )
      |> Enum.count(&match?({:ok, :ok}, &1))

    %{subscribers: length(session_ids), delivered: delivered}
  end

  defp deliver_resource_update(session_id, uri) do
    notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/resources/updated",
      "params" => %{"uri" => uri}
    }

    # Append independently of the connection so notifications published during
    # a reconnect gap are available to Last-Event-ID replay.
    case Arbor.MCP.SessionManager.append_event(session_id, "message", notification) do
      {:ok, event} ->
        deliver_persisted_resource_update(session_id, notification, event.id)

      {:error, _reason} ->
        :not_delivered
    end
  end

  defp deliver_persisted_resource_update(session_id, notification, event_id) do
    with {:ok, handler} <- lookup_sse_handler(session_id),
         true <- Process.alive?(handler),
         :ok <- SSEHandler.request_send(handler) do
      SSEHandler.send_event(handler, "message", notification,
        event_id: event_id,
        persist: false
      )
    else
      _not_connected -> :stored
    end
  end

  # Clean up SSE handler registration
  defp cleanup_sse_handler(session_id) do
    SessionRegistry.unregister(session_id)
  end

  defp cleanup_sse_handler(session_id, handler_pid) do
    SessionRegistry.unregister(session_id, handler_pid)
  end

  # --- New Helper Functions ---

  defp validate_protocol_version(conn, request, session_manager, session_id) do
    if modern_http_request?(conn, request) do
      request_id = Map.get(request, "id")

      case RequestHeaders.protocol_version(request) do
        version when is_binary(version) ->
          with :ok <- RequestHeaders.validate(conn.req_headers, request),
               true <- VersionRegistry.known?(version) do
            {:ok, conn}
          else
            {:error, message} -> {:error, {:header_mismatch, request_id, message}}
            false -> {:error, {:unsupported_protocol_version, request_id, version}}
          end

        _missing_version ->
          case get_req_header(conn, "mcp-protocol-version") do
            [header_version] ->
              if VersionRegistry.modern?(header_version) do
                {:error,
                 {:invalid_modern_metadata, request_id, missing_modern_metadata_field(request)}}
              else
                {:error, {:header_mismatch, request_id, "Protocol version metadata is missing"}}
              end

            _missing_or_duplicated ->
              {:error, {:header_mismatch, request_id, "Protocol version metadata is missing"}}
          end
      end
    else
      validate_legacy_protocol_version(conn, request, session_manager, session_id)
    end
  end

  defp missing_modern_metadata_field(%{"params" => %{"_meta" => meta}}) when is_map(meta),
    do: "io.modelcontextprotocol/protocolVersion"

  defp missing_modern_metadata_field(_request), do: "_meta"

  # The legacy lifecycle negotiates its version in `initialize`; the HTTP
  # header is required only on subsequent requests. If a client nevertheless
  # sends the header during initialization, validate it and require it to agree
  # with the requested version so two conflicting protocol interpretations can
  # never reach the handler.
  defp validate_legacy_protocol_version(
         conn,
         %{"method" => "initialize"} = request,
         _session_manager,
         _session_id
       ) do
    requested_version = get_in(request, ["params", "protocolVersion"])
    response_version = supported_or_preferred_version(requested_version)

    case get_req_header(conn, "mcp-protocol-version") do
      [] ->
        {:ok, assign(conn, :request_protocol_version, response_version)}

      [version] when is_binary(version) ->
        cond do
          not VersionRegistry.supported?(version) ->
            protocol_version_error(
              "Unsupported MCP-Protocol-Version: #{version}. Server supports #{response_version}.",
              response_version
            )

          is_binary(requested_version) and version != requested_version ->
            protocol_version_error(
              "MCP-Protocol-Version header does not match initialize params.protocolVersion.",
              response_version
            )

          true ->
            {:ok, assign(conn, :request_protocol_version, response_version)}
        end

      _duplicated ->
        protocol_version_error(
          "MCP-Protocol-Version header must occur exactly once.",
          response_version
        )
    end
  end

  defp validate_legacy_protocol_version(conn, _request, session_manager, session_id) do
    expected_version =
      session_protocol_version(session_manager, session_id) || VersionRegistry.latest_version()

    case get_req_header(conn, "mcp-protocol-version") do
      [version] when is_binary(version) ->
        cond do
          not VersionRegistry.supported?(version) ->
            protocol_version_error(
              "Unsupported MCP-Protocol-Version: #{version}. Server supports #{expected_version}.",
              expected_version
            )

          is_binary(session_id) and version != expected_version ->
            protocol_version_error(
              "MCP-Protocol-Version #{version} does not match the negotiated version #{expected_version}.",
              expected_version
            )

          true ->
            {:ok, assign(conn, :request_protocol_version, version)}
        end

      [] ->
        if FeatureFlags.enabled?(:protocol_version_header) do
          protocol_version_error(
            "Missing MCP-Protocol-Version header. Server requires version #{expected_version}.",
            expected_version
          )
        else
          {:ok, assign(conn, :request_protocol_version, expected_version)}
        end

      _duplicated ->
        protocol_version_error(
          "MCP-Protocol-Version header must occur exactly once.",
          expected_version
        )
    end
  end

  defp protocol_version_error(message, expected_version) do
    {:error, {:protocol_version_mismatch, message, expected_version}}
  end

  defp supported_or_preferred_version(version) when is_binary(version) do
    if VersionRegistry.supported?(version),
      do: version,
      else: VersionRegistry.preferred_version()
  end

  defp supported_or_preferred_version(_missing), do: VersionRegistry.preferred_version()

  defp session_protocol_version(session_manager, session_id) when is_binary(session_id) do
    if is_atom(session_manager) and function_exported?(session_manager, :get_session, 1) do
      case session_manager.get_session(session_id) do
        {:ok, session} when is_map(session) ->
          Map.get(session, :protocol_version) || Map.get(session, "protocol_version")

        _missing ->
          nil
      end
    end
  catch
    :exit, _reason -> nil
  end

  defp session_protocol_version(_session_manager, _session_id), do: nil

  defp finalize_legacy_protocol_version(
         {:ok, %{"error" => _error}} = result,
         conn,
         %{"method" => "initialize"},
         session_manager,
         session_id
       ) do
    abort_session_initialization(result, conn, session_manager, session_id)
  end

  defp finalize_legacy_protocol_version(
         {:ok, %{error: _error}} = result,
         conn,
         %{"method" => "initialize"},
         session_manager,
         session_id
       ) do
    abort_session_initialization(result, conn, session_manager, session_id)
  end

  defp finalize_legacy_protocol_version(
         {:ok, response} = result,
         conn,
         %{"method" => "initialize"},
         session_manager,
         session_id
       ) do
    version = initialize_response_version(response)
    expected_version = conn.assigns[:request_protocol_version]

    with true <- VersionRegistry.supported?(version) and version == expected_version,
         :ok <- complete_session_initialization(session_manager, session_id, version) do
      {:ok, result, assign(conn, :request_protocol_version, version)}
    else
      false -> fail_session_initialization(conn, session_manager, session_id)
      {:error, _reason} -> fail_session_initialization(conn, session_manager, session_id)
    end
  end

  defp finalize_legacy_protocol_version(
         result,
         conn,
         %{"method" => "initialize"},
         session_manager,
         session_id
       ) do
    abort_session_initialization(result, conn, session_manager, session_id)
  end

  defp finalize_legacy_protocol_version(result, conn, _request, _session_manager, _session_id),
    do: {:ok, result, conn}

  defp initialize_response_version(%{"result" => result}) when is_map(result),
    do: Map.get(result, "protocolVersion") || Map.get(result, :protocolVersion)

  defp initialize_response_version(%{result: result}) when is_map(result),
    do: Map.get(result, "protocolVersion") || Map.get(result, :protocolVersion)

  defp initialize_response_version(_response), do: nil

  defp complete_session_initialization(_session_manager, nil, _version), do: :ok

  defp complete_session_initialization(session_manager, session_id, version) do
    if is_atom(session_manager) and
         function_exported?(session_manager, :complete_initialization, 2) do
      case session_manager.complete_initialization(session_id, version) do
        :ok -> :ok
        other -> {:error, other}
      end
    else
      {:error, :unsupported_session_manager}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp abort_session_initialization(result, conn, session_manager, session_id) do
    cleanup_failed_initialization(session_manager, session_id)

    {:ok, result, assign(conn, :suppress_session_header, true)}
  catch
    :exit, _reason -> {:ok, result, assign(conn, :suppress_session_header, true)}
  end

  defp fail_session_initialization(_conn, session_manager, session_id) do
    cleanup_failed_initialization(session_manager, session_id)
    {:error, :session_manager_unavailable}
  catch
    :exit, _reason -> {:error, :session_manager_unavailable}
  end

  defp cleanup_failed_initialization(session_manager, session_id) do
    if is_binary(session_id) and is_atom(session_manager) and
         function_exported?(session_manager, :terminate_session, 1) do
      _ = session_manager.terminate_session(session_id)
    end

    case lookup_sse_handler(session_id) do
      {:ok, handler} ->
        if Process.alive?(handler), do: SSEHandler.close(handler)
        cleanup_sse_handler(session_id, handler)

      {:error, _reason} ->
        :ok
    end
  end

  defp validate_modern_method(request) do
    version = RequestHeaders.protocol_version(request)
    method = Map.get(request, "method")

    if VersionRegistry.modern?(version) do
      known? =
        Enum.any?(Methods.rows(), fn {known, _min, _max, _kind, _handlers} -> known == method end)

      # Reject protocol methods that are unavailable in the negotiated era,
      # while leaving explicitly implemented extension methods dispatchable.
      if not known? or Methods.available?(method, version),
        do: :ok,
        else: {:error, {:modern_method_not_found, Map.get(request, "id")}}
    else
      :ok
    end
  end

  defp validate_request_method_params(request) do
    method = Map.get(request, "method")
    params = if Map.has_key?(request, "params"), do: Map.get(request, "params"), else: %{}

    case MessageValidator.validate_method_params(method, params) do
      :ok -> :ok
      {:error, error} -> {:error, {:invalid_method_params, Map.get(request, "id"), error}}
    end
  end

  defp assign_request_protocol_version(conn, request) do
    case RequestHeaders.protocol_version(request) do
      version when is_binary(version) -> assign(conn, :request_protocol_version, version)
      _missing -> conn
    end
  end

  defp authorize_request(conn, request, opts) do
    if opts.oauth_enabled do
      # Set default realm if not provided in config
      auth_config =
        if Map.has_key?(opts.auth_config, :realm) do
          opts.auth_config
        else
          Map.put(opts.auth_config, :realm, opts.server_info.name)
        end

      case ScopeValidator.get_required_scopes(request, opts.scope_mapper) do
        {:error, reason} ->
          Logger.warning("OAuth scope policy rejected MCP method", reason: reason)
          {:error, :scope_policy_missing}

        required_scopes ->
          case ServerGuard.authorize(conn.req_headers, required_scopes, auth_config) do
            {:ok, token_info} ->
              {:ok, token_info}

            {:error, error_response} ->
              {:error, {:auth_error, add_resource_metadata(error_response, opts)}}

            :ok ->
              # ServerGuard returns :ok only when the global OAuth feature flag is
              # disabled. If this plug opted into OAuth, fail closed instead of
              # silently allowing unauthenticated MCP requests.
              {:error, :oauth_guard_disabled}
          end
      end
    else
      {:ok, nil}
    end
  end

  defp add_resource_metadata({status, challenge, body}, opts) do
    parameter = ~s(resource_metadata="#{resource_metadata_uri(opts)}")

    challenge =
      if String.contains?(challenge, "resource_metadata="),
        do: challenge,
        else: challenge <> ", " <> parameter

    {status, challenge, body}
  end

  defp resource_metadata_uri(opts) do
    resource = opts.protected_resource_metadata.resource
    uri = URI.parse(resource)
    path = String.trim_trailing(uri.path || "", "/")

    %URI{
      uri
      | path: "/.well-known/oauth-protected-resource" <> path,
        query: nil,
        fragment: nil
    }
    |> URI.to_string()
  end

  defp protected_resource_path(opts) do
    opts.protected_resource_metadata.resource
    |> URI.parse()
    |> Map.get(:path)
    |> then(&split_path(&1 || "/"))
  end

  defp handle_well_known_resource(conn, opts) do
    metadata = ProtectedResourceMetadata.build_metadata(opts.protected_resource_metadata)

    conn
    |> maybe_add_cors_headers(opts)
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> send_resp(200, Jason.encode!(metadata))
  end

  defp handle_authorization_server_metadata(conn, opts) do
    metadata = AuthorizationServerMetadata.build_metadata()

    conn
    |> maybe_add_cors_headers(opts)
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> send_resp(200, Jason.encode!(metadata))
  rescue
    e in ArgumentError ->
      Logger.error(
        "OAuth authorization server metadata configuration error: #{Exception.message(e)}"
      )

      error_response = %{
        "error" => "server_error",
        "error_description" => "Authorization server metadata is not properly configured"
      }

      conn
      |> maybe_add_cors_headers(opts)
      |> put_resp_content_type("application/json")
      |> send_resp(500, Jason.encode!(error_response))
  end

  defp get_supported_scopes do
    ScopeValidator.get_all_static_scopes()
  end

  # Per MCP spec, all responses MUST include the mcp-protocol-version header.
  defp add_protocol_version_header(conn) do
    version = conn.assigns[:request_protocol_version] || VersionRegistry.latest_version()
    put_resp_header(conn, "mcp-protocol-version", version)
  end
end
