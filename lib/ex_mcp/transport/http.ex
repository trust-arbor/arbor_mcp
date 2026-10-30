defmodule ExMCP.Transport.HTTP do
  @moduledoc """
  Streamable HTTP client transport for both supported MCP wire eras.

  MCP 2026-07-28 and the legacy 2025-03-26 through 2025-11-25 revisions use
  the same MCP endpoint but have different lifecycle rules. Select the
  compatibility policy with `:protocol_mode`; do not infer the wire shape
  from `transport: :http` alone.

  | Behavior | Legacy Streamable HTTP | MCP 2026-07-28 |
  |---|---|---|
  | Establishment | `initialize`; the server may issue `Mcp-Session-Id` | `server/discover`; stateless requests |
  | Streaming | Optional standalone GET stream plus request-owned SSE | Request- and subscription-owned POST responses |
  | Resumption | `Last-Event-ID` and session DELETE | Close/reissue the owning POST; no session cursor |

  Modern requests always use a fresh POST. ExMCP derives
  `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`, and annotated
  `Mcp-Param-*` routing headers from the JSON-RPC body. Modern SSE is selected
  by the response to the owning POST and does not depend on `:use_sse`.

  ## Features

  - **Dual-era negotiation**: Modern discovery with explicit, safe legacy fallback
  - **Request-owned streaming**: JSON or SSE responses on modern POST requests
  - **Modern subscriptions**: Long-lived `subscriptions/listen` POST streams
  - **Legacy compatibility**: Session IDs, GET SSE, event resumption, and DELETE
  - **Configurable endpoint**: Customize the MCP endpoint path
  - **Protocol routing**: Validated version, method, name, and parameter headers

  ## Security Features

  The Streamable HTTP transport supports comprehensive security features:

  - **Authentication**: Bearer tokens, API keys, basic auth
  - **Origin Validation**: Prevent DNS rebinding attacks (recommended to enable)
  - **CORS Headers**: Cross-origin resource sharing
  - **Security Headers**: XSS protection, frame options, etc.
  - **TLS/SSL**: Secure connections with certificate validation

  ## Modern-preferred example

      {:ok, client} = ExMCP.Client.start_link(
        transport: :http,
        url: "https://api.example.com/mcp",
        protocol_mode: :prefer_modern,
        security: %{
          auth: {:bearer, "your-token"},
          validate_origin: true,
          allowed_origins: ["https://app.example.com"],
          # Send credentials to this exact origin without consent, for this
          # connection only (in addition to config :ex_mcp, :security).
          trusted_origins: ["https://api.example.com"]
        }
      )

  With `:prefer_modern`, ExMCP probes with `server/discover` and falls back only
  when a live peer provides positive legacy compatibility evidence. Use
  `:modern_only` when fallback is not allowed.

  ## Legacy session compatibility

  `:session_id`, `:use_sse`, `Mcp-Session-Id`, `Last-Event-ID`, the standalone
  GET stream, and DELETE termination apply only after a connection settles on
  a legacy revision. For example:

      {:ok, legacy_client} = ExMCP.Client.start_link(
        transport: :http,
        url: "https://api.example.com",
        protocol_mode: :legacy_only,
        protocol_version: "2025-11-25",
        session_id: "existing-session",
        use_sse: true
      )

  Setting `use_sse: false` disables the legacy standalone GET stream. It does
  not disable a modern request-owned SSE response.

  > #### Security Best Practices {: .warning}
  >
  > 1. **Always use HTTPS** in production
  > 2. **Enable origin validation** to prevent DNS rebinding attacks
  > 3. **Bind to localhost** when possible for local servers
  > 4. **Implement proper authentication** (bearer tokens, API keys, etc.)
  > 5. **Set restrictive CORS policies** for cross-origin requests
  """

  @behaviour ExMCP.Transport
  require Logger

  alias ExMCP.Authorization.{FullOAuthFlow, LogSanitizer}
  alias ExMCP.Client.Deadline

  alias ExMCP.Internal.{
    CACerts,
    DNSResolver,
    Headers,
    LogSummary,
    Options,
    Security,
    SecurityConfig,
    SSE
  }

  alias ExMCP.Protocol.VersionNegotiator
  alias ExMCP.Transport.{SecurityGuard, SSEClient}

  alias ExMCP.Transport.HTTP.{
    BoundedClient,
    ModernStreamClient,
    PostStream,
    RequestHeaders,
    TargetPolicy,
    ToolHeaders
  }

  defstruct [
    :base_url,
    :headers,
    :http_client,
    :sse_pid,
    :endpoint,
    :security,
    :origin,
    :session_id,
    :use_sse,
    :last_event_id,
    :last_response,
    :timeouts,
    :protocol_version,
    :protocol_era,
    :auth_config,
    :access_token,
    :retry_delay,
    :max_retry_delay,
    :auth_provider,
    :auth_provider_state,
    :max_response_bytes,
    :max_stream_buffer_bytes,
    :max_request_bytes,
    :dns_timeout_ms,
    :dns_resolver,
    :allowed_private_hosts,
    # Absolute monotonic-millisecond deadline for the synchronous exchanges
    # made with this state (see put_deadline/2); nil when only the configured
    # timeouts apply.
    :deadline,
    tool_headers: %{},
    tool_listing_generation: 0,
    tool_headers_generation: 0,
    modern_streams: %{},
    sse_deferred_attempted: false,
    auth_completed: false,
    granted_scopes: nil
  ]

  @type t :: %__MODULE__{
          base_url: String.t(),
          headers: [{String.t(), String.t()}],
          http_client: module(),
          sse_pid: pid() | nil,
          endpoint: String.t(),
          security: ExMCP.Security.Validation.security_config() | nil,
          origin: String.t() | nil,
          session_id: String.t() | nil,
          use_sse: boolean(),
          last_event_id: String.t() | nil,
          last_response: map() | nil,
          timeouts: map(),
          protocol_version: String.t(),
          protocol_era: :legacy | :modern | :unknown,
          tool_headers: %{optional(String.t()) => [map()]},
          tool_listing_generation: non_neg_integer(),
          tool_headers_generation: non_neg_integer(),
          modern_streams: %{optional(ExMCP.Types.request_id()) => pid()},
          sse_deferred_attempted: boolean(),
          auth_provider: module() | nil,
          auth_provider_state: any(),
          max_response_bytes: pos_integer(),
          max_stream_buffer_bytes: pos_integer(),
          max_request_bytes: pos_integer(),
          dns_timeout_ms: pos_integer(),
          dns_resolver: module() | function(),
          allowed_private_hosts: [String.t()],
          deadline: integer() | nil,
          granted_scopes: [String.t()] | nil
        }

  @default_endpoint "/mcp/v1"
  @session_header "Mcp-Session-Id"
  @protocol_version_header "mcp-protocol-version"
  @default_max_response_bytes 8 * 1_024 * 1_024
  @default_max_stream_buffer_bytes 1 * 1_024 * 1_024
  @default_max_request_bytes 8 * 1_024 * 1_024

  @impl true
  def connect(config) do
    raw_url = Keyword.fetch!(config, :url)

    # If no explicit endpoint is provided, extract path from URL.
    # e.g., "http://localhost:3000/mcp" → base_url: "http://localhost:3000", endpoint: "/mcp"
    {base_url, default_ep} = split_url_path(raw_url)

    headers = Keyword.get(config, :headers, [])
    http_client = Keyword.get(config, :http_client, :httpc)
    endpoint = Keyword.get(config, :endpoint, default_ep)
    security = Keyword.get(config, :security)
    use_sse = Keyword.get(config, :use_sse, true)
    session_id = Keyword.get(config, :session_id)

    protocol_version =
      Keyword.get(config, :protocol_version) ||
        Application.get_env(:ex_mcp, :protocol_version) ||
        VersionNegotiator.latest_version()

    # Extract timeout configurations with backwards compatibility
    connect_timeout = Keyword.get(config, :timeout, 5_000)
    request_timeout = Keyword.get(config, :request_timeout, 30_000)
    stream_handshake_timeout = Keyword.get(config, :stream_handshake_timeout, 15_000)
    stream_idle_timeout = Keyword.get(config, :stream_idle_timeout, 60_000)

    max_response_bytes =
      Options.positive_integer(config, :max_response_bytes, @default_max_response_bytes)

    max_stream_buffer_bytes =
      Options.positive_integer(config, :max_stream_buffer_bytes, @default_max_stream_buffer_bytes)

    max_request_bytes =
      Options.positive_integer(config, :max_request_bytes, @default_max_request_bytes)

    dns_timeout_ms = Options.positive_integer(config, :dns_timeout_ms, 1_000)
    dns_resolver = Keyword.get(config, :dns_resolver, DNSResolver)
    allowed_private_hosts = Keyword.get(config, :allowed_private_hosts, [])

    Logger.debug("HTTP transport connecting",
      use_sse: use_sse,
      endpoint_hash: LogSummary.fingerprint({base_url, endpoint})
    )

    # Extract origin if provided
    origin =
      case security do
        %{origin: origin} -> origin
        _ -> extract_origin_from_url(base_url)
      end

    # Build security headers
    security_headers =
      if security do
        Security.build_security_headers(security)
      else
        []
      end

    # Merge all headers
    all_headers = Enum.uniq_by(headers ++ security_headers, fn {name, _} -> name end)

    # Create timeout configuration
    timeouts = %{
      connect: connect_timeout,
      request: request_timeout,
      stream_handshake: stream_handshake_timeout,
      stream_idle: stream_idle_timeout
    }

    # OAuth config for automatic 401 → discover → token → retry flow.
    # Prefer auth: %{client_registration: {:cimd, "https://..."}, ...} or an
    # explicit pre-registered strategy. Legacy client_id/client_secret keys remain accepted.
    auth_config = Keyword.get(config, :auth)

    # Reconnection options (passed through to SSEClient)
    max_retry_delay = Keyword.get(config, :max_retry_delay, 60_000)

    # Auth provider: explicit provider tuple, or auto-create from :auth config
    provider =
      init_auth_provider(
        Keyword.get(config, :auth_provider),
        auth_config,
        base_url,
        endpoint,
        protocol_version
      )

    state = %__MODULE__{
      base_url: base_url,
      headers: all_headers,
      http_client: http_client,
      endpoint: endpoint,
      security: security,
      origin: origin,
      use_sse: use_sse,
      session_id: session_id,
      timeouts: timeouts,
      protocol_version: protocol_version,
      protocol_era: :unknown,
      tool_headers: %{},
      modern_streams: %{},
      auth_config: auth_config,
      max_retry_delay: max_retry_delay,
      max_response_bytes: max_response_bytes,
      max_stream_buffer_bytes: max_stream_buffer_bytes,
      max_request_bytes: max_request_bytes,
      dns_timeout_ms: dns_timeout_ms,
      dns_resolver: dns_resolver,
      allowed_private_hosts: allowed_private_hosts
    }

    # Validate security configuration
    # Per MCP spec, session ID comes from the server after initialization.
    # SSE is deferred until after the first successful POST (which provides
    # the session ID needed for the GET SSE stream).
    with {:ok, {auth_provider, auth_provider_state}} <- provider,
         state = %{state | auth_provider: auth_provider, auth_provider_state: auth_provider_state},
         :ok <- validate_security(state),
         :ok <- TargetPolicy.validate_options(network_policy_options(state)) do
      if use_sse do
        Logger.debug("HTTP transport configured with SSE (deferred until after initialization)")
      else
        Logger.debug("SSE disabled, using synchronous HTTP responses")
      end

      :telemetry.execute([:ex_mcp, :transport, :connection, :opened], %{}, %{
        transport: :http,
        endpoint_hash: LogSummary.fingerprint(base_url)
      })

      {:ok, state}
    end
  end

  @impl true
  def send_message(message, %__MODULE__{} = state) do
    case send_keeping_state(message, state) do
      {:error, reason, _state} -> {:error, reason}
      result -> result
    end
  end

  @doc false
  # send_message/2, except that a send that fails after changing the
  # transport state returns that state too, as {:error, reason, state}. An
  # auth provider may have refreshed its token (spending a rotating refresh
  # token) or recorded a failed flow's loop guards before the request failed;
  # ExMCP.Client keeps that state instead of using the old one again.
  @spec send_keeping_state(term(), t()) ::
          {:ok, t()} | {:ok, t(), term()} | {:error, term()} | {:error, term(), t()}
  def send_keeping_state(message, %__MODULE__{use_sse: true, sse_pid: nil} = state) do
    # SSE configured but not yet started (pre-initialization).
    # Handle synchronously like non-SSE mode, then start SSE if we get a session ID.
    case send_sync(message, state) do
      {:ok, new_state, response_data} ->
        {:ok, maybe_start_deferred_sse(new_state, message), response_data}

      {:ok, new_state} ->
        {:ok, maybe_start_deferred_sse(new_state, message)}

      error ->
        error
    end
  end

  @client_auth_fields [
    :access_token,
    :auth_completed,
    :auth_provider_state,
    :headers
  ]

  def send_keeping_state(message, %__MODULE__{use_sse: true, sse_pid: sse_pid} = state)
      when is_pid(sse_pid) do
    parent = self()
    request_id = extract_request_id(message)
    request_state = apply_provider_token(state)
    {page_info, request_state} = prepare_tool_list_page(message, request_state)

    client_auth? = Process.get({ExMCP.Client, :client}) == true

    task_pid =
      spawn(fn ->
        task_ref =
          receive do
            {:start_async_post, ref} -> ref
          after
            5_000 -> nil
          end

        result =
          if client_auth? do
            perform_async(message, request_state, parent, page_info: page_info)
          else
            perform_async_standalone(message, request_state, parent, page_info: page_info)
          end

        changes = result_state_changes(request_state, result)
        changes = if client_auth?, do: Map.drop(changes, @client_auth_fields), else: changes

        meta = %{
          task_ref: task_ref,
          task_pid: self(),
          request_id: request_id,
          deadline: request_state.deadline,
          tool_list: page_info,
          state_changes: changes
        }

        send(parent, {:async_post_result, without_state(result), meta})
      end)

    task_ref = Process.monitor(task_pid)
    send(parent, {:async_post_task, task_ref, request_id})
    send(parent, {:async_post_task, task_ref, request_id, task_pid})
    if not client_auth?, do: send(task_pid, {:start_async_post, task_ref})

    {:ok,
     %{
       state
       | access_token: request_state.access_token,
         headers: request_state.headers,
         auth_provider_state: request_state.auth_provider_state,
         tool_listing_generation: request_state.tool_listing_generation
     }}
  end

  def send_keeping_state(message, %__MODULE__{} = state), do: send_sync(message, state)

  defp send_sync(message, state), do: exchange(message, apply_provider_token(state), [])

  @doc false
  def send_authenticated(message, %__MODULE__{} = state, opts \\ []) do
    exchange(message, state, opts)
  end

  defp exchange(message, state, opts) do
    case perform_with_token(message, state, opts) do
      {:ok, response} ->
        handle_http_response(response, state, message, opts)

      {:ok, response, new_state} ->
        case handle_http_response(response, new_state, message, opts) do
          {:error, reason} -> {:error, reason, new_state}
          result -> result
        end

      {:error, reason, new_state} ->
        {:error, reason, new_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp perform_with_token(body, %{auth_provider: provider} = state, opts)
       when not is_nil(provider) do
    case perform_http_request(body, state, opts) do
      {:ok, response} ->
        handle_provider_auth_challenge(response, body, state, opts)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp perform_with_token(body, state, opts) do
    case perform_http_request(body, state, opts) do
      {:ok, response} ->
        case handle_auth_challenge(response, body, state, opts) do
          :no_challenge ->
            {:ok, response}

          {:ok, retry_response, new_state} ->
            case handle_auth_challenge(retry_response, body, new_state, opts) do
              :no_challenge -> {:ok, retry_response, new_state}
              {:ok, r, s} -> {:ok, r, s}
              {:error, reason, s} -> {:error, reason, s}
            end

          {:error, reason, new_state} ->
            {:error, reason, new_state}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp perform_async_standalone(message, state, parent, opts) do
    stream =
      PostStream.consumer(parent,
        max_buffer_bytes: state.max_stream_buffer_bytes,
        max_kept_bytes: state.max_response_bytes
      )

    exchange(message, state, [event_stream: stream] ++ opts)
  end

  defp perform_async(message, state, parent, opts, attempts \\ 0) do
    stream =
      PostStream.consumer(parent,
        max_buffer_bytes: state.max_stream_buffer_bytes,
        max_kept_bytes: state.max_response_bytes
      )

    request_opts = [event_stream: stream] ++ opts

    case perform_http_request(message, state, request_opts) do
      {:ok, response} ->
        case extract_auth_status(response, state) do
          :ok ->
            handle_http_response(response, state, message, opts)

          {kind, www_auth} when attempts < 2 ->
            case await_authentication(parent, kind, www_auth, state) do
              {:ok, token} ->
                if is_integer(state.deadline) and Deadline.expired?(state.deadline) do
                  {:error, :timeout}
                else
                  perform_async(
                    message,
                    apply_token_to_state(state, token),
                    parent,
                    opts,
                    attempts + 1
                  )
                end

              {:error, reason} ->
                {:error, {:authentication_failed, reason}}
            end

          _challenge ->
            handle_http_response(response, state, message, opts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @auth_wait_ms 600_000

  defp await_authentication(parent, kind, www_auth, state) do
    if is_integer(state.deadline) and Deadline.expired?(state.deadline) do
      {:error, :timeout}
    else
      ref = make_ref()
      monitor = Process.monitor(parent)

      challenge = %{
        status: if(kind == :unauthorized, do: 401, else: 403),
        www_authenticate: www_auth,
        scopes: extract_scope_from_www_auth(www_auth),
        token: state.access_token || bearer_token(state.headers),
        deadline: state.deadline
      }

      send(parent, {:http_post_auth_challenge, self(), ref, challenge})

      wait =
        case state.deadline do
          deadline when is_integer(deadline) ->
            min(max(deadline - System.monotonic_time(:millisecond), 0), @auth_wait_ms)

          nil ->
            @auth_wait_ms
        end

      receive do
        {:http_post_auth_result, ^ref, result} ->
          Process.demonitor(monitor, [:flush])
          result

        {:DOWN, ^monitor, :process, _pid, _reason} ->
          {:error, :client_gone}
      after
        wait ->
          Process.demonitor(monitor, [:flush])
          {:error, :timeout}
      end
    end
  end

  defp handle_provider_auth_challenge(response, body, state, opts) do
    case extract_auth_status(response, state) do
      {:unauthorized, www_auth} ->
        provider_authenticate(:handle_unauthorized, www_auth, body, state, opts)

      {:forbidden, www_auth} ->
        provider_authenticate(:handle_forbidden, www_auth, body, state, opts)

      :ok ->
        {:ok, response, state}
    end
  end

  defp provider_authenticate(callback, www_auth, body, state, opts) do
    provider = state.auth_provider
    scopes = extract_scope_from_www_auth(www_auth)

    case apply(provider, callback, [www_auth, scopes, state.auth_provider_state]) do
      {:ok, token, new_ps} ->
        new_state =
          state
          |> Map.put(:auth_provider_state, new_ps)
          |> apply_token_to_state(token)

        provider_retry_request(body, new_state, opts)

      {:error, reason, ps} ->
        {:error, reason, %{state | auth_provider_state: ps}}
    end
  end

  defp provider_retry_request(body, state, opts) do
    case perform_http_request(body, state, opts) do
      {:ok, retry_resp} ->
        case extract_auth_status(retry_resp, state) do
          {:forbidden, www_auth} ->
            provider_authenticate(:handle_forbidden, www_auth, body, state, opts)

          _ ->
            {:ok, retry_resp, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp extract_auth_status({{_, 401, _}, headers, _body}, state) do
    www_auth = Headers.get(headers, "www-authenticate")

    if unauthorized_challenge?(state, www_auth) do
      {:unauthorized, www_auth}
    else
      :ok
    end
  end

  defp extract_auth_status({{_, 403, _}, headers, _body}, state) do
    www_auth = Headers.get(headers, "www-authenticate")

    if forbidden_challenge?(state, www_auth) do
      {:forbidden, www_auth}
    else
      :ok
    end
  end

  defp extract_auth_status(_response, _state), do: :ok

  defp unauthorized_challenge?(%{auth_provider: p}, _www) when not is_nil(p), do: true
  defp unauthorized_challenge?(%{auth_config: c}, _www) when not is_nil(c), do: true
  defp unauthorized_challenge?(_state, "Bearer" <> _), do: true
  defp unauthorized_challenge?(_state, "bearer" <> _), do: true
  defp unauthorized_challenge?(_state, _www), do: false

  defp forbidden_challenge?(%{auth_provider: p}, _www) when not is_nil(p), do: true

  defp forbidden_challenge?(_state, www) when is_binary(www) do
    String.contains?(www, "insufficient_scope")
  end

  defp forbidden_challenge?(_state, _www), do: false

  defp apply_provider_token(%{auth_provider: provider, auth_provider_state: ps} = state)
       when not is_nil(provider) do
    case provider.get_token(ps) do
      {:ok, nil, new_ps} ->
        %{state | auth_provider_state: new_ps}

      {:ok, token, new_ps} ->
        %{
          state
          | auth_provider_state: new_ps,
            access_token: token,
            headers: put_bearer_header(state.headers, token)
        }

      {:error, _} ->
        state
    end
  end

  defp apply_provider_token(state), do: state

  defp apply_token_to_state(state, token) do
    %{
      state
      | access_token: token,
        headers: put_bearer_header(state.headers, token)
    }
  end

  defp init_auth_provider(:none, _auth_config, _base_url, _endpoint, _version),
    do: {:ok, {nil, nil}}

  defp init_auth_provider({mod, provider_config}, _auth_config, _base_url, _endpoint, _version),
    do: start_auth_provider(mod, provider_config)

  defp init_auth_provider(nil, auth_config, base_url, endpoint, version)
       when is_map(auth_config) do
    provider_config =
      auth_config
      |> Map.put(:resource_url, base_url <> (endpoint || ""))
      |> Map.put(:protocol_version, version)

    start_auth_provider(ExMCP.Authorization.Provider.OAuth, provider_config)
  end

  defp init_auth_provider(nil, _auth_config, _base_url, _endpoint, _version),
    do: {:ok, {nil, nil}}

  # A configured provider that can't start fails the connection: without it,
  # every request would go out without the credentials the application set up.
  # Only an atom reason is kept, because a provider's other reasons, and its
  # exceptions, may carry its config, secrets included.
  defp start_auth_provider(mod, provider_config) do
    case mod.init(provider_config) do
      {:ok, provider_state} -> {:ok, {mod, provider_state}}
      {:error, reason} when is_atom(reason) -> auth_provider_failed(mod, reason)
      {:error, _reason} -> auth_provider_failed(mod, :redacted)
      _invalid -> auth_provider_failed(mod, :invalid_init_result)
    end
  rescue
    exception -> auth_provider_failed(mod, {:raised, exception.__struct__})
  catch
    kind, _reason -> auth_provider_failed(mod, kind)
  end

  defp auth_provider_failed(mod, reason) do
    Logger.error(
      "HTTP auth provider #{inspect(mod)} failed to initialize (#{inspect(reason)}); " <>
        "not connecting without it"
    )

    {:error, {:auth_provider_init_failed, mod, reason}}
  end

  @doc false
  def run_inline_oauth_challenge(%__MODULE__{} = state, challenge) do
    status = Map.get(challenge, :status, 401)
    www_auth = Map.get(challenge, :www_authenticate)
    scopes = Map.get(challenge, :scopes, [])

    case validate_inline_challenge(status, www_auth, scopes, state) do
      :ok -> execute_inline_oauth(state, www_auth, scopes, status)
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp validate_inline_challenge(403, www_auth, scopes, _state) do
    has_scope_err = is_binary(www_auth) and String.contains?(www_auth, "insufficient_scope")
    has_scopes = is_list(scopes) and scopes != []

    if has_scope_err or has_scopes do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp validate_inline_challenge(401, www_auth, _scopes, state) do
    if state.auth_config != nil or bearer_challenge?(www_auth) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp validate_inline_challenge(_status, _www, _scopes, _state), do: :ok

  defp bearer_challenge?("Bearer" <> _), do: true
  defp bearer_challenge?("bearer" <> _), do: true
  defp bearer_challenge?(_), do: false

  defp execute_inline_oauth(state, www_auth, challenge_scopes, status) do
    scopes = resolve_oauth_scopes(challenge_scopes, state, www_auth)
    config = build_inline_oauth_config(state, www_auth, scopes)

    Logger.info("Attempting full OAuth flow (status: #{status})")

    case FullOAuthFlow.execute(config) do
      {:ok, token_result} ->
        access_token = token_result[:access_token] || token_result["access_token"]
        granted = extract_granted_scopes(token_result, scopes)

        new_state = %{
          state
          | access_token: access_token,
            auth_completed: true,
            granted_scopes: granted,
            headers: put_bearer_header(state.headers, access_token)
        }

        {{:ok, access_token}, new_state}

      {:error, reason} ->
        Logger.warning("Full OAuth flow failed: #{LogSanitizer.format(reason)}")
        {{:error, {:oauth_failed, reason}}, state}
    end
  end

  defp resolve_oauth_scopes([_ | _] = scopes, %{granted_scopes: granted}, _www)
       when is_list(granted) do
    Enum.uniq(granted ++ scopes)
  end

  defp resolve_oauth_scopes([_ | _] = scopes, _state, _www), do: scopes

  defp resolve_oauth_scopes(_empty, %{granted_scopes: [_ | _] = granted}, _www), do: granted

  defp resolve_oauth_scopes(_empty, %{auth_config: %{scopes: s}}, _www) when is_list(s), do: s

  defp resolve_oauth_scopes(_empty, _state, www_auth), do: extract_scope_from_www_auth(www_auth)

  defp build_inline_oauth_config(state, www_auth, scopes) do
    resource_url = build_url(state, "")

    base_config =
      (state.auth_config || %{})
      |> Map.put(:resource_url, resource_url)
      |> Map.put(:www_authenticate, www_auth)
      |> Map.put(:protocol_version, state.protocol_version)
      |> with_connection_trust(state)

    case scopes do
      [_ | _] -> Map.put(base_config, :scopes, scopes)
      _ -> base_config
    end
  end

  defp extract_granted_scopes(token_result, requested_scopes) do
    case token_result[:scope] || token_result["scope"] do
      scope when is_binary(scope) ->
        String.split(scope, ~r/\s+/, trim: true)

      _ ->
        requested_scopes
    end
  end

  defp handle_auth_challenge({status_line, headers, _body}, body, state, opts) do
    case status_line do
      {_, code, _} when code in [401, 403] ->
        www_auth = Headers.get(headers, "www-authenticate")
        scopes = extract_scope_from_www_auth(www_auth)
        challenge = %{status: code, www_authenticate: www_auth, scopes: scopes}

        case run_inline_oauth_challenge(state, challenge) do
          {{:ok, _token}, new_state} ->
            case perform_http_request(body, new_state, opts) do
              {:ok, retry_resp} -> {:ok, retry_resp, new_state}
              {:error, reason} -> {:error, reason, new_state}
            end

          {{:error, :unauthorized}, ^state} ->
            :no_challenge

          {{:error, :forbidden}, ^state} ->
            :no_challenge

          {{:error, reason}, new_state} ->
            {:error, reason, new_state}
        end

      _ ->
        :no_challenge
    end
  end

  defp bearer_token(headers) do
    case Headers.get(headers, "authorization") do
      "Bearer " <> token -> token
      _none -> nil
    end
  end

  defp extract_scope_from_www_auth(nil), do: []

  defp extract_scope_from_www_auth(www_auth) when is_binary(www_auth) do
    case Regex.run(~r/scope="([^"]+)"/, www_auth) do
      [_, scope_str] -> String.split(scope_str, " ", trim: true)
      _ -> []
    end
  end

  defp put_bearer_header(headers, token) do
    headers
    |> Headers.delete("authorization")
    |> List.insert_at(0, {"Authorization", "Bearer #{token}"})
  end

  defp perform_http_request(body, state, opts) do
    # According to MCP spec, POST directly to the MCP endpoint, not /messages
    url = build_url(state, "")
    Logger.debug("HTTP request", endpoint_hash: LogSummary.fingerprint(url))

    :telemetry.execute([:ex_mcp, :transport, :message, :sent], %{size: byte_size(body)}, %{
      transport: :http,
      endpoint_hash: LogSummary.fingerprint(url)
    })

    headers = RequestHeaders.build(body, state)

    # Security validation before making external request
    case sanitize_http_request("POST", url, headers, state) do
      {:ok, sanitized_headers} ->
        make_http_request(url, sanitized_headers, body, state, opts)

      {:error, security_error} ->
        Logger.warning("HTTP request blocked by security policy",
          error: LogSummary.describe(security_error)
        )

        {:error, {:security_violation, security_error}}
    end
  end

  @doc false
  @spec sanitize_http_request(String.t(), String.t(), list(), t()) ::
          {:ok, list()} | {:error, term()}
  def sanitize_http_request(method, url, headers, state)
      when is_binary(method) and is_binary(url) and is_list(headers) do
    # Build SecurityGuard request
    security_request = %{
      url: url,
      headers: headers,
      method: String.upcase(method),
      transport: :http,
      user_id: extract_user_id(state)
    }

    config =
      :http
      |> SecurityConfig.get_transport_config()
      |> with_connection_trust(state)

    case SecurityGuard.validate_request(security_request, config) do
      {:ok, sanitized_request} ->
        {:ok, sanitized_request.headers}

      {:error, security_error} ->
        {:error, security_error}
    end
  end

  defp make_http_request(url, headers, body, state, opts) do
    with {:ok, transport_opts} <- https_transport_opts(url, state) do
      BoundedClient.request(:post, url, headers, "application/json", body,
        event_stream: Keyword.get(opts, :event_stream),
        deadline: state.deadline,
        connect_timeout: state.timeouts.connect,
        request_timeout: state.timeouts.request,
        max_request_bytes: state.max_request_bytes,
        max_response_bytes: state.max_response_bytes,
        transport_opts: transport_opts,
        dns_timeout_ms: state.dns_timeout_ms,
        dns_resolver: state.dns_resolver,
        allowed_private_hosts: state.allowed_private_hosts
      )
    end
  end

  @doc false
  # Builds the `http_options` list handed to `:httpc.request/4,5`.
  #
  # TLS settings must be passed as a single `{:ssl, opts}` entry:
  # `build_ssl_options/1` returns a *flat* ssl option list, and splicing that
  # straight into `http_options` makes httpc reject each entry ("Invalid
  # option {verify,verify_peer} ignored"), silently dropping every configured
  # TLS setting.
  @spec httpc_http_options(String.t(), t()) :: keyword()
  def httpc_http_options(url, state) do
    base_http_opts = [{:timeout, state.timeouts.request}, {:autoredirect, false}]

    case URI.parse(url).scheme do
      "https" -> [{:ssl, build_ssl_options_from_state(state)} | base_http_opts]
      _other -> base_http_opts
    end
  end

  # Extracts the JSON-RPC id from an outbound client *request* for async POST
  # correlation. Notifications (no id), batches, and responses to
  # server-initiated requests (no "method" key) yield nil — a crash of those
  # POSTs has no pending client request to fail.
  defp extract_request_id(message) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, %{"method" => _, "id" => id}} when not is_nil(id) -> id
      _ -> nil
    end
  end

  defp extract_request_id(_message), do: nil

  # Transport-state fields an async POST may durably change. Everything else
  # is either transient (:last_response) or owned by the connection lifecycle
  # (:sse_pid, :sse_deferred_attempted) and must never be reported back. The
  # client updates :tool_headers itself from each tools/list result (see
  # cache_tool_list/3), so concurrent pages cannot overwrite one another.
  @async_merge_fields [
    :session_id,
    :access_token,
    :auth_completed,
    :auth_provider_state,
    :headers,
    :retry_delay,
    :last_event_id
  ]

  @doc false
  # Applies a tools/list response from an async POST to the client's own
  # transport state.
  #
  # A new listing generation (a fresh first page whose generation exceeds
  # tool_headers_generation) legitimately resets the cache. Pages belonging to
  # the current listing generation merge into the cache, ensuring that if cursor
  # pages complete before their first page, the first page does not erase the
  # cursor pages' cached tool headers. Pages from an older generation are ignored
  # as stale.
  @spec cache_tool_list(
          t(),
          :first | :cursor | {:first, pos_integer()} | {:cursor, pos_integer()} | nil,
          term()
        ) :: t()
  def cache_tool_list(%__MODULE__{} = state, page_info, response_data) do
    case Jason.decode(response_data) do
      {:ok, %{"result" => %{"tools" => tools}}} when is_list(tools) ->
        apply_tool_list_cache(state, page_info, tools)

      _other ->
        state
    end
  rescue
    _invalid -> state
  end

  defp apply_tool_list_cache(state, {:first, gen}, tools) when is_integer(gen) do
    current_gen = state.tool_headers_generation || 0

    cond do
      gen < current_gen ->
        state

      gen > current_gen ->
        %{state | tool_headers_generation: gen, tool_headers: ToolHeaders.cache(tools)}

      true ->
        %{state | tool_headers: Map.merge(state.tool_headers || %{}, ToolHeaders.cache(tools))}
    end
  end

  defp apply_tool_list_cache(state, {:cursor, gen}, tools) when is_integer(gen) do
    current_gen = state.tool_headers_generation || 0

    cond do
      gen < current_gen ->
        state

      gen > current_gen ->
        %{state | tool_headers_generation: gen, tool_headers: ToolHeaders.cache(tools)}

      true ->
        %{state | tool_headers: Map.merge(state.tool_headers || %{}, ToolHeaders.cache(tools))}
    end
  end

  defp apply_tool_list_cache(state, kind, tools) when kind in [:first, :cursor] do
    %{state | tool_headers: Map.merge(state.tool_headers || %{}, ToolHeaders.cache(tools))}
  end

  defp apply_tool_list_cache(state, _page_info, _tools), do: state

  defp prepare_tool_list_page(message, state) do
    case Jason.decode(message) do
      {:ok, %{"method" => "tools/list"} = request} ->
        if get_in(request, ["params", "cursor"]) do
          {{:cursor, state.tool_listing_generation || 0}, state}
        else
          gen = (state.tool_listing_generation || 0) + 1
          {{:first, gen}, %{state | tool_listing_generation: gen}}
        end

      _other ->
        {nil, state}
    end
  rescue
    _invalid -> {nil, state}
  end

  defp result_state_changes(snapshot, {:ok, new_state}) do
    async_state_changes(snapshot, new_state)
  end

  defp result_state_changes(snapshot, {:ok, new_state, _response_data}) do
    async_state_changes(snapshot, new_state)
  end

  defp result_state_changes(snapshot, {:error, _reason, new_state}) do
    async_state_changes(snapshot, new_state)
  end

  defp result_state_changes(_snapshot, _error), do: %{}

  defp without_state({:error, reason, _state}), do: {:error, reason}
  defp without_state(result), do: result

  @doc false
  # Computes the durable transport-state fields an async POST changed relative
  # to the snapshot the task was spawned with:
  #
  #   * :session_id — server-driven session rotation (Mcp-Session-Id header)
  #   * :access_token / :auth_completed / :headers — OAuth 401/403 retry
  #     (maybe_oauth_retry / run_full_oauth_flow / apply_token_to_state)
  #   * :auth_provider_state — auth provider token refresh
  #   * :retry_delay / :last_event_id — SSE-formatted POST response metadata
  #
  # The task runs on a snapshot, so its computed state cannot replace the
  # client's copy wholesale — concurrent updates to unrelated fields would be
  # clobbered. Only actual changes are reported; ExMCP.Client merges them into
  # its current transport state. With several POSTs in flight the merges are
  # serialized through the client process and the last delivered change wins.
  def async_state_changes(%__MODULE__{} = snapshot, %__MODULE__{} = new_state) do
    Enum.reduce(@async_merge_fields, %{}, fn field, acc ->
      new_value = Map.fetch!(new_state, field)

      if new_value == Map.fetch!(snapshot, field) do
        acc
      else
        Map.put(acc, field, new_value)
      end
    end)
  end

  # The origins this connection was told to trust (`security:
  # %{trusted_origins: [...]}`) join the VM-wide ones for its own requests
  # only; no other connection is affected.
  defp with_connection_trust(config, %{security: %{trusted_origins: origins}})
       when is_list(origins) do
    Map.update(config, :trusted_origins, origins, &Enum.uniq(&1 ++ origins))
  end

  defp with_connection_trust(config, _state), do: config

  defp extract_user_id(state) do
    config = SecurityConfig.get_transport_config(:http)

    case Map.get(config, :user_id_resolver) do
      nil ->
        # Default behavior if no resolver is configured
        cond do
          # Check if user_id is explicitly set in state (struct is a map)
          Map.has_key?(state, :user_id) ->
            Map.get(state, :user_id)

          # Check security context for user information
          is_map(state.security) ->
            Map.get(state.security, :user_id, "http_anonymous")

          # Check session ID as fallback
          state.session_id ->
            "session_#{LogSummary.fingerprint(state.session_id)}"

          # Default fallback
          true ->
            "http_anonymous"
        end

      resolver ->
        # Use the configured resolver. The resolver is expected to be a function
        # that takes the transport state and returns a user ID string.
        resolver.(state)
    end
  end

  defp handle_http_response({status_line, headers, body}, state, request_body, opts) do
    # Convert charlist to binary if needed (httpc returns charlists by default)
    body_binary = if is_list(body), do: List.to_string(body), else: body
    {_, status_code, _} = status_line

    :telemetry.execute(
      [:ex_mcp, :transport, :message, :received],
      %{size: byte_size(body_binary)},
      %{transport: :http, status: status_code}
    )

    # Extract session ID from server response headers (per MCP spec)
    state = maybe_update_session_id(headers, state)

    case status_line do
      {_, 200, _} ->
        # Always parse the response body — per MCP spec, POST responses
        # contain the result even in SSE mode. The SSE stream is for
        # server-initiated messages (notifications, progress updates).
        handle_non_sse_response(body_binary, headers, state, request_body, opts)

      {_, 202, _} ->
        # 202 Accepted - notification was accepted, no response body expected
        {:ok, state}

      {_, 401, _} ->
        # Extract WWW-Authenticate header for OAuth discovery hints
        www_auth = Headers.get(headers, "www-authenticate")
        {:error, {:unauthorized, 401, body_binary, www_auth}}

      {_, status, _} ->
        {:error, {:http_error, status, body_binary}}
    end
  end

  defp handle_non_sse_response(body, headers, state, request_body, opts) do
    content_type = Headers.get(headers, "content-type") || ""

    if String.contains?(String.downcase(content_type), "text/event-stream") do
      handle_sse_post_response(body, state, request_body, opts)
    else
      case Jason.decode(body) do
        {:ok, response} ->
          state = cache_tool_headers(state, request_body, response, opts)
          {:ok, %{state | last_response: response}, Jason.encode!(response)}

        {:error, reason} ->
          {:error, {:json_decode_error, reason}}
      end
    end
  end

  defp cache_tool_headers(
         state,
         request_body,
         %{"result" => %{"tools" => tools}},
         opts
       )
       when is_list(tools) do
    case Jason.decode(request_body) do
      {:ok, %{"method" => "tools/list"} = request} ->
        page_info = resolve_tool_list_page(request, state, opts)
        state = maybe_advance_listing_generation(state, page_info)
        apply_tool_list_cache(state, page_info, tools)

      _other ->
        state
    end
  rescue
    _invalid -> state
  end

  defp cache_tool_headers(state, _request_body, _response, _opts), do: state

  defp resolve_tool_list_page(request, state, opts) do
    case Keyword.get(opts, :page_info) do
      nil ->
        if get_in(request, ["params", "cursor"]) do
          {:cursor, state.tool_listing_generation || 0}
        else
          gen = (state.tool_listing_generation || 0) + 1
          {:first, gen}
        end

      captured_page_info ->
        captured_page_info
    end
  end

  defp maybe_advance_listing_generation(state, {:first, gen}) when is_integer(gen) do
    if gen > (state.tool_listing_generation || 0),
      do: %{state | tool_listing_generation: gen},
      else: state
  end

  defp maybe_advance_listing_generation(state, _page_info), do: state

  # Process SSE-formatted POST response.
  # Extracts JSON data, retry fields, and event IDs.
  # If no JSON result is found (just priming events), the response
  # will come via GET SSE stream — start/ensure SSE is connected.
  defp handle_sse_post_response(body, state, request_body, opts) do
    events = SSE.parse_complete(body)
    state = apply_sse_event_metadata(events, state)
    handle_sse_json_data(sse_json_data(events), state, request_body, opts)
  end

  defp apply_sse_event_metadata(events, state) do
    Enum.reduce(events, state, fn event, acc ->
      acc
      |> apply_sse_retry(event[:retry])
      |> apply_sse_event_id(event[:id])
    end)
  end

  defp apply_sse_retry(state, ms) when is_integer(ms) and ms >= 0,
    do: %{state | retry_delay: min(ms, state.max_retry_delay)}

  defp apply_sse_retry(state, _missing_or_invalid), do: state

  defp apply_sse_event_id(state, nil), do: state
  defp apply_sse_event_id(state, id), do: %{state | last_event_id: id}

  # The POST's answer is the response among its events. The notifications
  # and requests ahead of it were handed to the client as they arrived (see
  # PostStream), or, in a body read whole during establishment, aren't
  # answered.
  defp sse_json_data(events) do
    Enum.find_value(events, "", fn
      %{data: data} when is_binary(data) and data != "" ->
        case Jason.decode(data) do
          {:ok, %{"id" => _id, "result" => _result}} -> data
          {:ok, %{"id" => _id, "error" => _error}} -> data
          {:ok, %{"method" => _method}} -> nil
          {:ok, _response} -> data
          {:error, _reason} -> nil
        end

      _no_data ->
        nil
    end)
  end

  defp handle_sse_json_data("", state, _request_body, _opts), do: reconnect_deferred_sse(state)

  defp handle_sse_json_data(json_data, state, request_body, opts) do
    case Jason.decode(json_data) do
      {:ok, response} ->
        state = cache_tool_headers(state, request_body, response, opts)
        {:ok, %{state | last_response: response}, Jason.encode!(response)}

      {:error, _reason} ->
        reconnect_deferred_sse(state)
    end
  end

  # The POST contained only priming events (or invalid JSON); the result must
  # arrive on the GET stream. Reconnect it using the latest bounded retry.
  defp reconnect_deferred_sse(state) do
    trigger_sse_reconnect(state)
    {:ok, maybe_start_deferred_sse(state)}
  end

  @impl true
  def receive_message(%__MODULE__{use_sse: true, sse_pid: sse_pid} = state)
      when is_pid(sse_pid) do
    # Ensure SSEClient sends events to the calling process (may be the receiver task,
    # not the process that originally started the SSE connection)
    send(sse_pid, {:change_parent, self()})

    receive do
      {:sse_event, ^sse_pid, %{data: data} = event} ->
        receive_sse_event(data, event, state)

      {:sse_error, ^sse_pid, reason} ->
        {:error, {:sse_error, reason}}

      # A server may close the session's GET stream at any time, and an
      # ExMCP server closes it when its request process ends. The session
      # lives on: the SSE client opens the stream again with Last-Event-ID,
      # so the receiver keeps waiting rather than reporting the connection
      # closed, which would drop the session and fail every pending request.
      # Errors, such as a 404 for an expired session, still end the
      # connection.
      {:sse_closed, ^sse_pid} ->
        receive_message(state)

      # The SSE client answers a 405 by giving up on the stream: the server
      # no longer offers one. The first GET's 405 reaches the process that
      # opened the stream, so this is a reopened GET. Requests and their
      # responses don't need the stream, so the connection carries on
      # POST-only, as when the server never offered one, and the reader
      # stops instead of waiting for events that won't come.
      {:sse_not_supported, ^sse_pid} ->
        {:error, :stream_withdrawn}
    end
  end

  def receive_message(%__MODULE__{last_response: response} = state)
      when response != nil do
    # Return stored response (from POST) and clear it
    {:ok, response, %{state | last_response: nil}}
  end

  def receive_message(%__MODULE__{use_sse: true, sse_pid: nil} = state) do
    # SSE enabled but no stream started yet (no session ID from server).
    # Wait for SSE to connect, or a 405/error indicating SSE not supported.
    receive do
      {:sse_connected, pid} ->
        receive_message(%{state | sse_pid: pid})

      {:sse_not_supported, _pid} ->
        # Server doesn't support SSE — fall back to sync mode
        Logger.info("SSE not supported, falling back to sync mode")
        {:error, :not_supported_in_sync_mode}
    after
      500 ->
        {:error, :waiting_for_session}
    end
  end

  def receive_message(%__MODULE__{use_sse: false} = _state) do
    # Non-SSE mode — responses returned directly from send_message
    {:error, :not_supported_in_sync_mode}
  end

  def receive_message(%__MODULE__{} = _state) do
    {:error, :not_connected}
  end

  # MCP messages travel in `message` events, the SSE default. Other events,
  # such as the `connected` event an ExMCP server opens its GET stream with,
  # aren't JSON-RPC messages, and the client skips them, as the TypeScript
  # SDK's client does.
  defp receive_sse_event(_data, %{type: type} = event, state)
       when type not in [nil, "message"] do
    send(state.sse_pid, {:sse_event_ack, self()})
    event_id = Map.get(event, :id)
    receive_message(if event_id, do: %{state | last_event_id: event_id}, else: state)
  end

  defp receive_sse_event(data, event, state) do
    send(state.sse_pid, {:sse_event_ack, self()})
    event_id = Map.get(event, :id)
    new_state = if event_id, do: %{state | last_event_id: event_id}, else: state

    case Jason.decode(data) do
      {:ok, %{"type" => "keep-alive"}} ->
        # Ignore keep-alive messages and continue receiving
        receive_message(new_state)

      {:ok, message} ->
        {:ok, message, new_state}

      {:error, reason} ->
        {:error, {:json_decode_error, reason}}
    end
  end

  @doc """
  Terminates the server-side session by sending DELETE to the endpoint.

  Per the MCP spec, clients SHOULD send a DELETE request with the session ID
  to allow the server to clean up session state. This is best-effort — errors
  are logged but don't prevent client shutdown.

  Returns `:ok` regardless of server response (fire-and-forget).
  """
  @spec terminate_session(t()) :: :ok
  def terminate_session(%__MODULE__{protocol_era: :modern}), do: :ok
  def terminate_session(%__MODULE__{session_id: nil}), do: :ok

  def terminate_session(%__MODULE__{session_id: session_id} = state) when is_binary(session_id) do
    url = state.base_url <> state.endpoint

    headers = [
      {@session_header, session_id},
      {@protocol_version_header, state.protocol_version}
      | state.headers
    ]

    result =
      with {:ok, sanitized_headers} <- sanitize_http_request("DELETE", url, headers, state),
           {:ok, transport_opts} <- https_transport_opts(url, state) do
        BoundedClient.request(:delete, url, sanitized_headers, "application/json", "",
          deadline: state.deadline,
          connect_timeout: state.timeouts.connect,
          request_timeout: state.timeouts.request,
          max_request_bytes: state.max_request_bytes,
          max_response_bytes: state.max_response_bytes,
          transport_opts: transport_opts,
          dns_timeout_ms: state.dns_timeout_ms,
          dns_resolver: state.dns_resolver,
          allowed_private_hosts: state.allowed_private_hosts
        )
      end

    case result do
      {:ok, {{_, status, _}, _, _}} when status in [200, 202, 204] ->
        :telemetry.execute([:ex_mcp, :transport, :session, :terminated], %{}, %{
          session_id_hash: LogSummary.fingerprint(session_id)
        })

        Logger.debug("Session terminated", status: status)
        :ok

      {:ok, {{_, status, _}, _, _}} ->
        Logger.debug("Session termination returned HTTP #{status} (non-fatal)")
        :ok

      {:error, reason} ->
        Logger.debug("Session termination failed (non-fatal)",
          reason: LogSummary.describe(reason)
        )

        :ok
    end
  end

  @impl true
  def close(%__MODULE__{} = state) do
    :telemetry.execute([:ex_mcp, :transport, :connection, :closed], %{}, %{
      transport: :http,
      session_id_hash: if(state.session_id, do: LogSummary.fingerprint(state.session_id))
    })

    # Best-effort session termination before closing
    terminate_session(state)

    Enum.each(state.modern_streams, fn {_request_id, pid} ->
      ModernStreamClient.cancel(pid)
    end)

    # Stop SSE connection if active. SSEClient is a GenServer that does not
    # trap exits, so Process.exit(pid, :normal) would be silently ignored and
    # leak the process. GenServer.stop runs its terminate/2 (cancelling the
    # httpc request); tolerate an already-dead or slow-to-stop client.
    if is_pid(state.sse_pid) do
      stop_sse_client(state.sse_pid)
    end

    :ok
  end

  @doc false
  # Caps every synchronous HTTP exchange made with this state (DNS, connect
  # and response together) at an absolute monotonic-millisecond deadline, or
  # removes the cap with nil. A request whose deadline has already passed is
  # refused with `:deadline_expired` before anything is sent. The client sets
  # it while establishing a connection and for a request whose caller gave
  # it a timeout, and clears it afterwards.
  @spec put_deadline(t(), integer() | nil) :: t()
  def put_deadline(%__MODULE__{} = state, deadline) when is_integer(deadline) or is_nil(deadline),
    do: %{state | deadline: deadline}

  # The SSE client is start_linked by the process that opened it (the
  # client). Modern request streams are started unlinked and monitor their
  # parent instead, and async POST tasks are spawn_monitored.
  @impl true
  def linked_processes(%__MODULE__{sse_pid: sse_pid}) when is_pid(sse_pid), do: [sse_pid]
  def linked_processes(%__MODULE__{}), do: []

  @doc false
  @spec settle_protocol_era(t(), :legacy | :modern | :unknown, String.t()) :: t()
  def settle_protocol_era(%__MODULE__{} = state, :modern, version) do
    if is_pid(state.sse_pid), do: stop_sse_client(state.sse_pid)

    %{
      state
      | protocol_version: version,
        protocol_era: :modern,
        use_sse: false,
        sse_pid: nil,
        session_id: nil,
        last_event_id: nil,
        modern_streams: %{},
        sse_deferred_attempted: false
    }
  end

  def settle_protocol_era(%__MODULE__{} = state, era, version) do
    %{state | protocol_version: version, protocol_era: era}
  end

  @doc false
  # Ends what a failed legacy handshake left in `attempt` that `snapshot` did
  # not have: the session the server handed out and a deferred SSE client.
  # The DELETE is bounded by `attempt`'s deadline.
  @spec abandon_attempt(t(), t()) :: :ok
  def abandon_attempt(%__MODULE__{} = attempt, %__MODULE__{} = snapshot) do
    if is_binary(attempt.session_id) and attempt.session_id != snapshot.session_id do
      terminate_session(attempt)
    end

    if is_pid(attempt.sse_pid) and attempt.sse_pid != snapshot.sse_pid do
      stop_sse_client(attempt.sse_pid)
    end

    :ok
  end

  defp stop_sse_client(pid) do
    GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _ -> :ok
  end

  @doc false
  # A failure after the provider's token was resolved returns the state too,
  # as send_keeping_state/2 does, so a refreshed token isn't lost.
  @spec open_stream(binary(), t(), pid(), keyword()) ::
          {:ok, t()} | {:error, term()} | {:error, term(), t()}
  def open_stream(message, state, parent, opts \\ [])

  def open_stream(message, %__MODULE__{protocol_era: :modern} = state, parent, opts)
      when is_binary(message) and is_pid(parent) and is_list(opts) do
    request_id = extract_request_id(message)
    stream_kind = Keyword.get(opts, :stream_kind, :request)

    with :ok <- request_within_limit(message, state.max_request_bytes),
         :ok <- validate_stream_kind(stream_kind),
         :ok <- validate_stream_request_id(request_id, state) do
      # Resolve the provider's current token before deriving request headers.
      # Unlike the ordinary POST path, a modern request stream is owned by a
      # dedicated process, so it cannot call perform_with_token/3. It hands a
      # later 401/403 back to the client process, which answers the
      # challenges of all its streams one at a time.
      state
      |> apply_provider_token()
      |> start_stream(message, request_id, stream_kind, parent, opts)
    end
  end

  def open_stream(_message, _state, _parent, _opts), do: {:error, :modern_http_stream_required}

  defp start_stream(state, message, request_id, stream_kind, parent, opts) do
    url = build_url(state, "")
    headers = RequestHeaders.build(message, state)

    with {:ok, headers} <- sanitize_http_request("POST", url, headers, state),
         {:ok, http_options} <- modern_stream_http_options(url, state),
         {:ok, pid} <-
           ModernStreamClient.start(
             parent: parent,
             request_id: request_id,
             url: url,
             headers: headers,
             body: message,
             stream_kind: stream_kind,
             http_options: http_options,
             handshake_timeout: state.timeouts.stream_handshake,
             idle_timeout: state.timeouts.stream_idle,
             max_response_bytes: state.max_response_bytes,
             max_buffer_bytes: state.max_stream_buffer_bytes,
             auth_provider: state.auth_provider,
             deadline: Keyword.get(opts, :deadline),
             header_sanitizer: fn retry_headers ->
               sanitize_http_request("POST", url, retry_headers, state)
             end
           ) do
      {:ok, %{state | modern_streams: Map.put(state.modern_streams, request_id, pid)}}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc false
  @spec close_stream(t(), ExMCP.Types.request_id()) :: t()
  def close_stream(%__MODULE__{} = state, request_id) do
    case Map.pop(state.modern_streams, request_id) do
      {nil, _streams} ->
        state

      {pid, streams} ->
        ModernStreamClient.cancel(pid)
        %{state | modern_streams: streams}
    end
  end

  @doc false
  @spec forget_stream(t(), ExMCP.Types.request_id(), pid()) :: t()
  def forget_stream(%__MODULE__{} = state, request_id, pid) do
    case Map.get(state.modern_streams, request_id) do
      ^pid -> %{state | modern_streams: Map.delete(state.modern_streams, request_id)}
      _other -> state
    end
  end

  @doc false
  @spec stream_owner?(t(), ExMCP.Types.request_id(), pid()) :: boolean()
  def stream_owner?(%__MODULE__{} = state, request_id, pid) do
    Map.get(state.modern_streams, request_id) == pid
  end

  defp validate_stream_request_id(nil, _state), do: {:error, :stream_request_id_required}

  defp validate_stream_request_id(request_id, state) do
    if Map.has_key?(state.modern_streams, request_id),
      do: {:error, :duplicate_stream_request_id},
      else: :ok
  end

  defp validate_stream_kind(kind) when kind in [:request, :subscription], do: :ok
  defp validate_stream_kind(_kind), do: {:error, :invalid_modern_stream_kind}

  defp request_within_limit(body, limit) do
    if byte_size(body) <= limit, do: :ok, else: {:error, :request_too_large}
  end

  defp modern_stream_http_options(url, state) do
    options = [
      timeout: :infinity,
      connect_timeout: state.timeouts.connect,
      autoredirect: false,
      dns_timeout_ms: state.dns_timeout_ms,
      dns_resolver: state.dns_resolver,
      allowed_private_hosts: state.allowed_private_hosts
    ]

    case https_transport_opts(url, state) do
      {:ok, []} -> {:ok, options}
      {:ok, ssl_options} -> {:ok, [{:ssl, ssl_options} | options]}
      {:error, _reason} = error -> error
    end
  end

  # NOTE: HTTP transport does NOT implement subscribe/2 (push model) because
  # bidirectional flows (elicitation, sampling) require the receiver task to
  # process SSE events while the GenServer is blocked on a synchronous POST.
  # The push model would deadlock: GenServer blocked in handle_call doing POST,
  # can't process {:transport_event, elicitation} in handle_info.
  # The receiver task (separate process) avoids this by forwarding SSE events
  # as {:transport_message, msg} which queue in the GenServer mailbox.
  # When :httpc is replaced with an async HTTP client, push mode can be enabled.

  # Private functions

  defp maybe_update_session_id(_headers, %{protocol_era: :modern} = state), do: state

  defp maybe_update_session_id(headers, state) do
    case Headers.get(headers, @session_header) do
      nil -> state
      session_id -> %{state | session_id: session_id}
    end
  end

  defp maybe_start_deferred_sse(state, message) do
    if modern_request?(message), do: state, else: maybe_start_deferred_sse(state)
  end

  defp maybe_start_deferred_sse(
         %{use_sse: true, sse_pid: nil, session_id: session_id, sse_deferred_attempted: false} =
           state
       )
       when is_binary(session_id) do
    Logger.debug("Starting deferred SSE connection",
      session_id_hash: LogSummary.fingerprint(session_id)
    )

    state = %{state | sse_deferred_attempted: true}

    case start_sse(state) do
      {:ok, sse_pid} ->
        handshake_timeout = state.timeouts.stream_handshake

        receive do
          {:sse_connected, ^sse_pid} ->
            Logger.debug("Deferred SSE connection established")
            %{state | sse_pid: sse_pid}

          {:sse_error, ^sse_pid, reason} ->
            stop_sse_client(sse_pid)

            Logger.debug("Deferred SSE connection failed; falling back",
              reason: LogSummary.describe(reason)
            )

            state
        after
          handshake_timeout ->
            stop_sse_client(sse_pid)
            Logger.debug("Deferred SSE connection timeout, falling back to non-SSE")
            state
        end

      {:error, reason} ->
        Logger.debug("Failed to start deferred SSE; falling back",
          reason: LogSummary.describe(reason)
        )

        state
    end
  end

  defp maybe_start_deferred_sse(state), do: state

  defp modern_request?(message) when is_binary(message) do
    case Jason.decode(message) do
      {:ok,
       %{
         "params" => %{
           "_meta" => %{"io.modelcontextprotocol/protocolVersion" => version}
         }
       }} ->
        is_binary(version)

      _other ->
        false
    end
  end

  # Trigger SSE reconnection when POST response closes without a result.
  # Sends a message to SSEClient to close current connection and reconnect
  # with the server-specified retry delay.
  defp trigger_sse_reconnect(%{
         sse_pid: sse_pid,
         retry_delay: retry_delay,
         last_event_id: last_id
       })
       when is_pid(sse_pid) do
    Logger.info("Triggering SSE reconnection (POST response had no result)")
    if retry_delay, do: send(sse_pid, {:update_retry_delay, retry_delay})
    if last_id, do: send(sse_pid, {:update_last_event_id, last_id})
    send(sse_pid, :force_reconnect)
  end

  defp trigger_sse_reconnect(%{sse_pid: sse_pid}) when is_pid(sse_pid) do
    send(sse_pid, :force_reconnect)
  end

  defp trigger_sse_reconnect(_state), do: :ok

  defp start_sse(state) do
    url = build_url(state, "")
    Logger.debug("Starting SSE connection", endpoint_hash: LogSummary.fingerprint(url))

    # Build headers including session
    sse_headers = [
      {@session_header, state.session_id} | state.headers
    ]

    # Add Last-Event-ID if we have one for resumability
    sse_headers =
      if state.last_event_id do
        [{"Last-Event-ID", state.last_event_id} | sse_headers]
      else
        sse_headers
      end

    with {:ok, sse_headers} <- sanitize_http_request("GET", url, sse_headers, state),
         {:ok, transport_opts} <- https_transport_opts(url, state) do
      # Use the enhanced SSE client with keep-alive and reconnection.
      # Pass retry_delay from POST SSE response if available.
      opts = [
        url: url,
        headers: sse_headers,
        initial_retry_delay: state.retry_delay,
        max_retry_delay: state.max_retry_delay,
        ssl_opts: transport_opts,
        parent: self(),
        connect_timeout: state.timeouts.connect,
        handshake_timeout: state.timeouts.stream_handshake,
        idle_timeout: state.timeouts.stream_idle,
        max_response_bytes: state.max_response_bytes,
        max_buffer_bytes: state.max_stream_buffer_bytes,
        dns_timeout_ms: state.dns_timeout_ms,
        dns_resolver: state.dns_resolver,
        allowed_private_hosts: state.allowed_private_hosts
      ]

      case SSEClient.start_link(opts) do
        {:ok, sse_pid} ->
          # Return immediately, connection happens asynchronously
          {:ok, sse_pid}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_url(%__MODULE__{base_url: base_url, endpoint: endpoint}, path) do
    # Normalize endpoint - ensure it starts with / and doesn't end with /
    normalized_endpoint = normalize_endpoint(endpoint)

    base_url
    |> URI.parse()
    |> Map.put(:path, normalized_endpoint <> path)
    |> URI.to_string()
  end

  defp normalize_endpoint(""), do: ""

  defp normalize_endpoint(endpoint) do
    endpoint
    |> ensure_leading_slash()
    |> String.trim_trailing("/")
  end

  defp ensure_leading_slash("/" <> _ = endpoint), do: endpoint
  defp ensure_leading_slash(endpoint), do: "/" <> endpoint

  defp network_policy_options(state) do
    [
      dns_timeout_ms: state.dns_timeout_ms,
      dns_resolver: state.dns_resolver,
      allowed_private_hosts: state.allowed_private_hosts
    ]
  end

  # Security-related helper functions

  defp validate_security(%{security: nil}), do: :ok

  defp validate_security(%{security: security}) do
    Security.validate_config(security)
  end

  # Split a full URL into {base_url, path} so callers can pass a single URL.
  # "http://localhost:3000/mcp" → {"http://localhost:3000", "/mcp"}
  # "http://localhost:3000" → {"http://localhost:3000", "/mcp/v1"} (default)
  defp split_url_path(url) do
    uri = URI.parse(url)

    case uri.path do
      nil ->
        {url, @default_endpoint}

      "/" ->
        {url, @default_endpoint}

      "" ->
        {url, @default_endpoint}

      path ->
        base = "#{uri.scheme}://#{uri.host}#{if uri.port, do: ":#{uri.port}", else: ""}"
        {base, path}
    end
  end

  defp extract_origin_from_url(url) do
    uri = URI.parse(url)

    if uri.scheme && uri.host do
      "#{uri.scheme}://#{uri.host}#{if uri.port && uri.port != default_port(uri.scheme), do: ":#{uri.port}", else: ""}"
    else
      nil
    end
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443
  defp default_port(_), do: nil

  @doc """
  Builds SSL options from TLS configuration.

  Always returns a *flat* `:ssl` option list. Callers passing the result to
  `:httpc` must wrap it themselves, e.g. `[{:ssl, ssl_opts} | http_opts]` —
  passing the flat list unwrapped makes `:httpc` silently ignore every
  TLS option.

  The defaults enable peer verification, the OS trust store (loaded with a
  deadline; see "TLS trust store" in the configuration guide), TLS 1.2/1.3,
  and HTTPS hostname matching with wildcard support
  (`:customize_hostname_check`). Each default can be overridden through the
  TLS configuration map. With `verify: :verify_none` and no `:cacerts`, the
  trust store is not loaded and no `:cacerts` option is returned.

  ## Examples

      tls_config = %{
        verify: :verify_peer,
        versions: [:"tlsv1.2", :"tlsv1.3"],
        cert: "client.pem",
        key: "client.key"
      }

      ssl_opts = ExMCP.Transport.HTTP.build_ssl_options(tls_config)
      # => [verify: :verify_peer, cacerts: [...], versions: [...], ...]
  """
  def build_ssl_options(tls_config) when is_map(tls_config) do
    verify = Map.get(tls_config, :verify, :verify_peer)

    base_ssl_opts =
      [verify: verify] ++
        cacerts_option(tls_config, verify) ++
        [
          versions: Map.get(tls_config, :versions, [:"tlsv1.2", :"tlsv1.3"]),
          customize_hostname_check:
            Map.get(tls_config, :customize_hostname_check, default_hostname_check())
        ]

    # Add client certificate if provided
    ssl_opts =
      case Map.get(tls_config, :cert) do
        nil -> base_ssl_opts
        cert -> Keyword.put(base_ssl_opts, :cert, cert)
      end

    # Add private key if provided
    ssl_opts =
      case Map.get(tls_config, :key) do
        nil -> ssl_opts
        key -> Keyword.put(ssl_opts, :key, key)
      end

    # Add cipher suites if provided
    ssl_opts =
      case Map.get(tls_config, :ciphers) do
        nil -> ssl_opts
        ciphers -> Keyword.put(ssl_opts, :ciphers, ciphers)
      end

    # Add verify function if provided
    case Map.get(tls_config, :verify_fun) do
      nil -> ssl_opts
      verify_fun -> Keyword.put(ssl_opts, :verify_fun, verify_fun)
    end
  end

  def build_ssl_options(_) do
    # Default secure SSL options
    build_ssl_options(%{})
  end

  # Only peer verification uses trust anchors. Loading the default store for
  # `verify: :verify_none` would fail the connection whenever the store is
  # unavailable, for certificates that are never checked.
  defp cacerts_option(tls_config, verify) do
    case {Map.fetch(tls_config, :cacerts), verify} do
      {{:ok, cacerts}, _verify} -> [cacerts: cacerts]
      {:error, :verify_peer} -> [cacerts: CACerts.get()]
      {:error, _verify} -> []
    end
  end

  # Enables wildcard certificate matching for HTTPS per RFC 6125. Without
  # this, :ssl rejects certificates such as `*.example.com`.
  defp default_hostname_check do
    [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
  end

  # TLS options for an outbound request. When the default trust store is
  # unavailable and no fallback is configured, the request fails closed with an
  # error instead of raising inside the client.
  defp https_transport_opts(url, state) do
    case URI.parse(url).scheme do
      "https" ->
        try do
          {:ok, build_ssl_options_from_state(state)}
        rescue
          e in CACerts.UnavailableError -> {:error, {:trust_store_unavailable, e.reason}}
        end

      _other ->
        {:ok, []}
    end
  end

  defp build_ssl_options_from_state(%{security: %{tls: tls_config}}) when is_map(tls_config) do
    build_ssl_options(tls_config)
  end

  defp build_ssl_options_from_state(_state) do
    build_ssl_options(%{})
  end
end

defimpl Inspect, for: ExMCP.Transport.HTTP do
  # Header values, tokens, the session id and auth configuration never print;
  # see ExMCP.Internal.Redaction.
  def inspect(state, opts),
    do: Inspect.Any.inspect(ExMCP.Internal.Redaction.http(state), opts)
end
