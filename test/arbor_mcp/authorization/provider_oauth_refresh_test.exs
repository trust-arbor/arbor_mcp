defmodule Arbor.MCP.Authorization.ProviderOAuthRefreshTest do
  @moduledoc """
  The default OAuth provider renews an access token with its refresh token,
  before the token expires and when the server rejects it, instead of running
  the browser flow again (which also found the same authorization server and
  stopped with `:auth_loop_detected`).
  """

  use ExUnit.Case, async: true

  @moduletag :oauth

  alias Arbor.MCP.Authorization.Provider.OAuth
  alias Arbor.MCP.Transport.HTTP

  defmodule RecordingStore do
    @moduledoc false
    @behaviour Arbor.MCP.Authorization.CredentialStore

    @impl true
    def fetch_registration(_context, _issuer, _pid), do: :not_found
    @impl true
    def put_registration(_context, _key, _registration, _pid), do: :ok
    @impl true
    def fetch_token(_key, _pid), do: :not_found

    @impl true
    def put_token(key, token, pid) do
      send(pid, {:put_token, key, token})
      :ok
    end
  end

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, token_endpoint: "http://localhost:#{bypass.port}/token"}
  end

  defp state(token_endpoint, overrides) do
    struct!(
      %OAuth{
        access_token: "old-token",
        resource_url: "https://mcp.example/mcp",
        auth_config: %{},
        auth_completed: true,
        authorization_server_issuer: "https://auth.example",
        refresh: %{
          refresh_token: "refresh-1",
          token_endpoint: token_endpoint,
          issuer: "https://auth.example",
          auth_methods: ["none"],
          client_info: %{client_id: "client-1"},
          resource: "https://mcp.example/mcp"
        }
      },
      overrides
    )
  end

  defp expect_refresh(bypass, response) do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:token_request, URI.decode_query(body)})

      {status, body} = response

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)
  end

  @tag :reauth_round7
  test "real identical-byte refreshes advance transport generations and provider acquisitions",
       %{bypass: bypass} = context do
    owner = self()

    Bypass.stub(bypass, "POST", "/token", fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      send(owner, :identical_refresh)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"access_token" => "old-token", "expires_in" => 0}))
    end)

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      case Plug.Conn.get_req_header(conn, "authorization") do
        [] ->
          send(owner, :rejected_cache_omitted)

          conn
          |> Plug.Conn.put_resp_header("www-authenticate", "Bearer")
          |> Plug.Conn.resp(401, "")

        ["Bearer old-token"] ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}))
      end
    end)

    {:ok, transport} = HTTP.connect(url: "http://localhost:#{bypass.port}/mcp", use_sse: false)
    transport = HTTP.put_oauth_token(transport, %{access_token: "old-token"}, [])
    provider = state(context.token_endpoint, expires_at: 0)
    transport = %{transport | auth_provider: OAuth, auth_provider_state: provider}
    request = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

    assert {:ok, first, _} = HTTP.send_authenticated(request, transport)
    assert first.credential_generation > transport.credential_generation
    assert first.auth_provider_state.token_acquisitions == 1
    assert {:ok, second, _} = HTTP.send_authenticated(request, first)
    assert second.credential_generation > first.credential_generation
    assert second.auth_provider_state.token_acquisitions == 2
    assert first.access_token == "old-token"
    assert second.access_token == "old-token"
    assert_receive :identical_refresh
    assert_receive :identical_refresh

    cached = %{second.auth_provider_state | expires_at: System.system_time(:second) + 600}

    retired =
      HTTP.retire_credential(
        %{second | auth_provider_state: cached},
        second.credential_generation
      )

    assert {:error, {:auth_refused, {:authentication_failed, :rejected_credential}},
            after_rejection} =
             HTTP.send_authenticated(request, retired)

    assert after_rejection.credential_generation == retired.credential_generation
    assert after_rejection.auth_provider_state.token_acquisitions == 2
    refute_received :rejected_cache_omitted
    refute_received :identical_refresh
  end

  test "an expiring token is refreshed before a request", %{bypass: bypass} = context do
    expect_refresh(
      bypass,
      {200,
       %{"access_token" => "new-token", "expires_in" => 3600, "refresh_token" => "refresh-2"}}
    )

    expiring = state(context.token_endpoint, expires_at: System.system_time(:second) - 1)

    assert {:ok, "new-token", refreshed} = OAuth.get_token(expiring)

    assert_received {:token_request,
                     %{
                       "grant_type" => "refresh_token",
                       "refresh_token" => "refresh-1",
                       "client_id" => "client-1",
                       "resource" => "https://mcp.example/mcp"
                     }}

    assert refreshed.refresh.refresh_token == "refresh-2"
    assert refreshed.expires_at > System.system_time(:second) + 3_000
  end

  test "a token that is not about to expire is used as is", context do
    fresh = state(context.token_endpoint, expires_at: System.system_time(:second) + 600)
    assert {:ok, "old-token", ^fresh} = OAuth.get_token(fresh)
  end

  test "a rejected token is refreshed instead of rerunning the flow",
       %{bypass: bypass} = context do
    # A server that doesn't rotate refresh tokens: the old one stays.
    expect_refresh(bypass, {200, %{"access_token" => "new-token", "expires_in" => 3600}})

    assert {:ok, "new-token", refreshed} =
             OAuth.handle_unauthorized(
               ~s(Bearer realm="mcp"),
               [],
               state(context.token_endpoint, [])
             )

    assert refreshed.refresh.refresh_token == "refresh-1"
  end

  test "a failed refresh falls back to authenticating again", %{bypass: bypass} = context do
    expect_refresh(bypass, {400, %{"error" => "invalid_grant"}})
    # Discovery for the fallback flow fails at once: nothing listens there.
    rejected =
      state(context.token_endpoint,
        resource_url: "https://127.0.0.1:1/mcp",
        auth_completed: false
      )

    assert {:error, {:oauth_failed, _reason}, _state} =
             OAuth.handle_unauthorized(~s(Bearer realm="mcp"), [], rejected)

    assert_received {:token_request, %{"grant_type" => "refresh_token"}}
  end

  test "tokens and the auth config stay out of inspect output", context do
    inspected =
      inspect(state(context.token_endpoint, auth_config: %{idp_id_token: "assertion-secret"}))

    refute inspected =~ "old-token"
    refute inspected =~ "refresh-1"
    refute inspected =~ "assertion-secret"
  end

  test "a refresh replaces the stored token under the first flow's binding",
       %{bypass: bypass} = context do
    # No new refresh token and no scope: the earlier ones stay in force.
    expect_refresh(bypass, {200, %{"access_token" => "new-token", "expires_in" => 3600}})

    binding = %{
      issuer: "https://auth.example",
      client_id: "client-1",
      resource: "https://discovered.example/mcp",
      audience: nil,
      subject: nil,
      client_identity: "client-1",
      granted_scopes: "tools:read"
    }

    rejected =
      state(context.token_endpoint, auth_config: %{credential_store: {RecordingStore, self()}})

    rejected = put_in(rejected.refresh[:binding], binding)

    assert {:ok, "new-token", _state} =
             OAuth.handle_unauthorized(~s(Bearer realm="mcp"), [], rejected)

    assert_received {:put_token, _key, token}
    assert token.access_token == "new-token"
    assert token.refresh_token == "refresh-1"
    assert token.resource == "https://discovered.example/mcp"
    assert token.granted_scopes == ["tools:read"]
  end

  # Discovery for https://mcp.example/mcp names `issuer` as its authorization
  # server. The metadata is served without the network.
  # prm: :challenge serves the metadata at the URL the challenge names,
  # :well_known only at the resource's well-known path, false nowhere.
  defp discovery(issuer, prm \\ :challenge) do
    test_pid = self()

    client = fn uri, _address, _opts ->
      send(test_pid, {:metadata_fetch, uri.host, uri.path})

      body =
        case {uri.host, uri.path} do
          {"mcp.example", "/prm"} when prm == :challenge ->
            %{"authorization_servers" => [issuer]}

          {"mcp.example", "/.well-known/oauth-protected-resource" <> _path}
          when prm == :well_known ->
            %{"authorization_servers" => [issuer]}

          {_host, "/.well-known/" <> _kind} ->
            %{
              "issuer" => issuer,
              "authorization_endpoint" => issuer <> "/authorize",
              "token_endpoint" => issuer <> "/token",
              "response_types_supported" => ["code"]
            }

          _other ->
            nil
        end

      if body,
        do: {:ok, %{status: 200, headers: [], body: Jason.encode!(body)}},
        else: {:ok, %{status: 404, headers: [], body: ""}}
    end

    %{
      metadata_fetch: [
        http_client: client,
        dns_resolver: fn _host, _timeout -> {:ok, [{93, 184, 216, 34}]} end
      ]
    }
  end

  @challenge ~s(Bearer resource_metadata="https://mcp.example/prm")

  test "a refreshed token rejected again is refreshed again while the issuer is the same",
       %{bypass: bypass} = context do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:token_request, URI.decode_query(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"access_token" => "new-token", "expires_in" => 3600})
      )
    end)

    rejected = state(context.token_endpoint, auth_config: discovery("https://auth.example"))
    assert {:ok, "new-token", refreshed} = OAuth.handle_unauthorized(@challenge, [], rejected)
    assert_received {:token_request, %{"grant_type" => "refresh_token"}}

    # Discovery finds the same authorization server: no browser flow.
    assert {:ok, "new-token", _state} = OAuth.handle_unauthorized(@challenge, [], refreshed)
    assert_received {:metadata_fetch, "mcp.example", "/prm"}
    assert_received {:token_request, %{"grant_type" => "refresh_token"}}
  end

  test "a refreshed token rejected again runs the full flow once the issuer has moved",
       %{bypass: bypass} = context do
    expect_refresh(bypass, {200, %{"access_token" => "new-token", "expires_in" => 3600}})

    rejected = state(context.token_endpoint, auth_config: discovery("https://new-auth.example"))
    assert {:ok, "new-token", refreshed} = OAuth.handle_unauthorized(@challenge, [], rejected)
    assert_received {:token_request, %{"grant_type" => "refresh_token"}}

    # The flow stops at client registration, none being configured, but it
    # ran against the new server instead of refreshing at the old one.
    assert {:error, {:oauth_failed, _reason}, _state} =
             OAuth.handle_unauthorized(@challenge, [], refreshed)

    assert_received {:metadata_fetch, "new-auth.example", _path}
    refute_received {:token_request, _}
  end

  defp refresh_every_time(bypass) do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:token_request, URI.decode_query(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"access_token" => "new-token", "expires_in" => 3600})
      )
    end)
  end

  test "the refreshed token stays out of inspect output", %{bypass: bypass} = context do
    expect_refresh(bypass, {200, %{"access_token" => "new-token", "expires_in" => 3600}})

    assert {:ok, "new-token", refreshed} =
             OAuth.handle_unauthorized(@challenge, [], state(context.token_endpoint, []))

    refute inspect(refreshed) =~ "new-token"
  end

  test "an issuer guessed without published metadata is not a move",
       %{bypass: bypass} = context do
    refresh_every_time(bypass)
    # No protected resource metadata: only a guessed issuer could differ.
    config = discovery("https://new-auth.example", false)

    assert {:ok, _token, refreshed} =
             OAuth.handle_unauthorized(
               @challenge,
               [],
               state(context.token_endpoint, auth_config: config)
             )

    assert {:ok, _token, _state} = OAuth.handle_unauthorized(@challenge, [], refreshed)
    assert_received {:token_request, _first}
    assert_received {:token_request, _second}
  end

  test "a failed migration flow isn't started again", %{bypass: bypass} = context do
    refresh_every_time(bypass)
    config = discovery("https://new-auth.example")

    assert {:ok, _token, refreshed} =
             OAuth.handle_unauthorized(
               @challenge,
               [],
               state(context.token_endpoint, auth_config: config)
             )

    assert {:error, {:oauth_failed, _reason}, failed} =
             OAuth.handle_unauthorized(@challenge, [], refreshed)

    # The next 401 refreshes at the old server; when that token is rejected
    # too, the flow for the server it already tried doesn't run again.
    assert {:ok, _token, refreshed} = OAuth.handle_unauthorized(@challenge, [], failed)
    assert {:ok, _token, _state} = OAuth.handle_unauthorized(@challenge, [], refreshed)

    assert_received {:token_request, _first}
    assert_received {:token_request, _second}
    assert_received {:token_request, _third}
  end

  test "a stale metadata URL in the challenge falls back to the well-known metadata",
       %{bypass: bypass} = context do
    expect_refresh(bypass, {200, %{"access_token" => "new-token", "expires_in" => 3600}})
    config = discovery("https://new-auth.example", :well_known)

    assert {:ok, _token, refreshed} =
             OAuth.handle_unauthorized(
               @challenge,
               [],
               state(context.token_endpoint, auth_config: config)
             )

    # The challenge's /prm is gone, but the well-known metadata names a new
    # server, so the full flow runs there instead of another refresh.
    assert {:error, {:oauth_failed, _reason}, _state} =
             OAuth.handle_unauthorized(@challenge, [], refreshed)

    assert_received {:metadata_fetch, "new-auth.example", _path}
  end

  test "a flow that failed after a rejection isn't started again", context do
    rejected =
      state(context.token_endpoint,
        access_token: nil,
        auth_completed: false,
        last_rejected_issuer: "https://auth.example",
        refresh: nil
      )

    assert {:error, :auth_loop_detected, _state} =
             OAuth.handle_unauthorized(@challenge, [], rejected)
  end

  test "after a failed flow, a server the metadata newly names may still be tried", context do
    failed =
      state(context.token_endpoint,
        access_token: nil,
        auth_completed: false,
        last_rejected_issuer: "https://auth.example",
        refresh: nil,
        auth_config: discovery("https://new-auth.example")
      )

    # The flow runs (and stops at client registration) rather than refusing.
    assert {:error, {:oauth_failed, _reason}, tried} =
             OAuth.handle_unauthorized(@challenge, [], failed)

    assert_received {:metadata_fetch, "new-auth.example", _path}

    # Tried once, it isn't started again.
    assert {:error, :auth_loop_detected, _state} =
             OAuth.handle_unauthorized(@challenge, [], tried)
  end

  test "a refresh that changes the granted scope files later tokens under it",
       %{bypass: bypass} = context do
    expect_refresh(bypass, {200, %{"access_token" => "new-token", "scope" => "tools:read"}})

    binding = %{
      issuer: "https://auth.example",
      client_id: "client-1",
      resource: "https://mcp.example/mcp",
      audience: nil,
      subject: nil,
      client_identity: "client-1",
      granted_scopes: "tools:read tools:write"
    }

    rejected =
      state(context.token_endpoint, auth_config: %{credential_store: {RecordingStore, self()}})

    rejected = put_in(rejected.refresh[:binding], binding)

    assert {:ok, "new-token", refreshed} =
             OAuth.handle_unauthorized(~s(Bearer realm="mcp"), [], rejected)

    assert_received {:put_token, _key, %{granted_scopes: ["tools:read"]}}
    assert refreshed.refresh.binding.granted_scopes == "tools:read"
  end
end
