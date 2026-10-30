defmodule Arbor.MCP.Authorization.Provider do
  @moduledoc """
  Behaviour for pluggable OAuth/auth providers in MCP transports.

  Instead of embedding OAuth logic directly in the HTTP transport,
  a Provider encapsulates token storage, retrieval, and the authentication
  flow. The transport delegates all auth concerns to the provider.

  ## Built-in Providers

  - `Arbor.MCP.Authorization.Provider.OAuth` — Full OAuth 2.1 with PKCE, PRM discovery,
    dynamic client registration, and scope step-up. This is the default when
    `:auth` config is provided.

  - `Arbor.MCP.Authorization.Provider.Static` — Simple static token provider for
    pre-existing bearer tokens. No refresh or discovery.

  ## Custom Providers

  Implement the behaviour to integrate with your own auth system:

      defmodule MyAuthProvider do
        @behaviour Arbor.MCP.Authorization.Provider

        @impl true
        def init(config) do
          {:ok, %{api_key: config[:api_key]}}
        end

        @impl true
        def get_token(state) do
          {:ok, state.api_key, state}
        end

        @impl true
        def handle_unauthorized(_www_auth, _scopes, state) do
          {:error, :unauthorized, state}
        end

        @impl true
        def handle_forbidden(_www_auth, _scopes, state) do
          {:error, :forbidden, state}
        end
      end

  ## Usage with Transport

      {:ok, client} = Arbor.MCP.Client.start_link(
        transport: :http,
        url: "https://api.example.com/mcp",
        auth_provider: {MyAuthProvider, api_key: "sk-..."}
      )

  The provider owns the `Authorization` header. An `Authorization` header set
  through the transport's `:headers` or `:security` options is dropped when the
  transport connects, with a warning, so each request carries the token
  `c:get_token/1` gives for it, or no `Authorization` header at all.
  """

  @type state :: any()
  @type config :: map() | keyword()

  @doc """
  Initialize the provider with configuration.

  Called once when the transport is created. Returns initial provider state.

  An error fails the connection rather than leaving it unauthenticated: the
  HTTP transport's `connect/1` returns
  `{:error, {:auth_provider_init_failed, module, reason}}`, and
  `Arbor.MCP.Client.start_link/1` returns that reason inside
  `{:error, {:transport_connect_failed, ...}}`. `reason` is kept only when it
  is an atom; any other error is reported as `:redacted`, an exception as
  `{:raised, exception_module}`, a throw or exit as `:throw` or `:exit`, and
  any other return as `:invalid_init_result`, since those may carry the
  provider's config.
  """
  @callback init(config()) :: {:ok, state()} | {:error, term()}

  @doc """
  Get the current access token, if available.

  The HTTP transport calls it for every request it sends, and the request
  carries what it returns:

    * `{:ok, token, new_state}` sends the request with `token` as its bearer
      token.
    * `{:ok, nil, new_state}` means no token is available yet (pre-auth): the
      request goes out without an `Authorization` header, and any token the
      provider gave before is dropped, so the server's 401 can start the
      provider's flow (`c:handle_unauthorized/3`).
    * `{:error, reason}` refuses the request before anything is sent. It goes
      out neither with an earlier token nor without one, and the caller gets
      `{:auth_provider_token_failed, module, reason}`, which
      `Arbor.MCP.Client.delivery_outcome/1` reports as `:not_sent`. When the
      refused request is the one that opens the connection,
      `Arbor.MCP.Client.start_link/1` returns
      `{:error, {:transport_connect_failed, {:auth_provider_token_failed, module, reason}}}`.

  `reason` is kept only when it is an atom, as for `c:init/1`: any other error
  is reported as `:redacted`, an exception as `{:raised, exception_module}`, a
  throw or exit as `:throw` or `:exit`, and any other return as
  `:invalid_token_result`, since those may carry the provider's secrets.

  A token is taken as newly acquired only when the provider's state changed
  since its last token. A token the server rejected with a 401 is therefore
  refused before it is sent if the provider returns it again with its state
  unchanged, even after an error or `nil` in between.

  A provider that would rather let the server decide returns a token instead
  of an error. The built-in `Arbor.MCP.Authorization.Provider.OAuth` does: when
  a refresh fails, it returns the token it has, and a 401 then decides whether
  to authenticate again.
  """
  @callback get_token(state()) :: {:ok, String.t() | nil, state()} | {:error, term()}

  @doc """
  Handle a 401 Unauthorized response from the server.

  The provider should attempt to authenticate (e.g., run OAuth flow,
  refresh token, etc.) and return a new token.

  - `www_authenticate` — the WWW-Authenticate header value (may be nil)
  - `scopes` — extracted scopes from the challenge (may be empty)

  Returns `{:ok, token, new_state}` on success, `{:error, reason, new_state}` on failure.
  """
  @callback handle_unauthorized(
              www_authenticate :: String.t() | nil,
              scopes :: [String.t()],
              state()
            ) :: {:ok, String.t(), state()} | {:error, term(), state()}

  @doc """
  Handle a 403 Forbidden response (typically scope step-up).

  Similar to `handle_unauthorized/3` but for scope-related rejections.
  The provider should attempt re-authorization with broader scopes.

  Returns `{:ok, token, new_state}` on success, `{:error, reason, new_state}` on failure.
  """
  @callback handle_forbidden(
              www_authenticate :: String.t() | nil,
              scopes :: [String.t()],
              state()
            ) :: {:ok, String.t(), state()} | {:error, term(), state()}
end
