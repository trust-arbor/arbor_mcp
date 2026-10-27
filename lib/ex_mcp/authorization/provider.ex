defmodule ExMCP.Authorization.Provider do
  @moduledoc """
  Behaviour for pluggable OAuth/auth providers in MCP transports.

  Instead of embedding OAuth logic directly in the HTTP transport,
  a Provider encapsulates token storage, retrieval, and the authentication
  flow. The transport delegates all auth concerns to the provider.

  ## Built-in Providers

  - `ExMCP.Authorization.Provider.OAuth` — Full OAuth 2.1 with PKCE, PRM discovery,
    dynamic client registration, and scope step-up. This is the default when
    `:auth` config is provided.

  - `ExMCP.Authorization.Provider.Static` — Simple static token provider for
    pre-existing bearer tokens. No refresh or discovery.

  ## Custom Providers

  Implement the behaviour to integrate with your own auth system:

      defmodule MyAuthProvider do
        @behaviour ExMCP.Authorization.Provider

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

      {:ok, client} = ExMCP.Client.start_link(
        transport: :http,
        url: "https://api.example.com/mcp",
        auth_provider: {MyAuthProvider, api_key: "sk-..."}
      )

  ## Where callbacks run

  With `ExMCP.Client`, the callbacks run inside the client process itself
  whenever it sends a request synchronously (HTTP without an open SSE
  stream) and when it answers a modern request stream's 401 or 403, one
  challenge at a time. While a callback runs, which for a browser sign-in
  can take minutes, the client handles nothing else.

  A callback must therefore not call the client it authenticates:

  - A direct call (`ExMCP.Client.list_tools(client)` from the callback, say)
    is a call to itself. For a stream's challenge the client turns it into
    `{:error, :auth_provider_called_client}`. Elsewhere it exits with
    `:calling_self`, which stops the client.
  - A call through another process that in turn calls the client deadlocks
    until one of the calls times out.
  """

  @type state :: any()
  @type config :: map() | keyword()

  @doc """
  Initialize the provider with configuration.

  Called once when the transport is created. Returns initial provider state.
  """
  @callback init(config()) :: {:ok, state()} | {:error, term()}

  @doc """
  Get the current access token, if available.

  Returns `{:ok, token, new_state}` if a valid token is available,
  or `{:ok, nil, state}` if no token is available yet (pre-auth).
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
