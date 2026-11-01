defmodule Arbor.MCP.Authorization.FullOAuthFlowCredentialStoreTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Arbor.MCP.Authorization.CredentialStore
  alias Arbor.MCP.Authorization.FullOAuthFlow
  alias Arbor.RPC.LogSummary

  defmodule StoreAdapter do
    @behaviour CredentialStore

    @impl true
    def fetch_registration(context, issuer, agent) do
      Agent.get(agent, fn state ->
        case state.index[{context, issuer}] do
          nil -> :not_found
          key -> {:ok, key, state.registrations[key]}
        end
      end)
    end

    @impl true
    def put_registration(context, key, registration, agent) do
      Agent.update(agent, fn state ->
        issuer = elem(key, 3)

        state
        |> put_in([:index, {context, issuer}], key)
        |> put_in([:registrations, key], registration)
      end)
    end

    @impl true
    def fetch_token(key, agent) do
      Agent.get(agent, fn state ->
        case state.tokens[key] do
          nil -> :not_found
          token -> {:ok, token}
        end
      end)
    end

    @impl true
    def put_token(key, token, agent) do
      Agent.update(agent, &put_in(&1, [:tokens, key], token))
    end
  end

  for {label, advertised} <- [
        {"absent", nil},
        {"empty", []},
        {"plain_only", ["plain"]},
        {"wrong_type", "S256"}
      ] do
    @tag assurance: ["oauth.pkce.#{label}"]
    test "refuses code authorization when S256 metadata is #{label}" do
      {:ok, store_agent} =
        Agent.start_link(fn -> %{index: %{}, registrations: %{}, tokens: %{}} end)

      server = oauth_server("unused-client", nil, pkce_methods: unquote(Macro.escape(advertised)))

      assert {:error, :pkce_s256_not_supported} =
               server
               |> flow_config({StoreAdapter, store_agent})
               |> FullOAuthFlow.execute()

      assert %{authorizations: 0, tokens: 0} = Agent.get(server.counter, & &1)
    end
  end

  @tag assurance: ["oauth.pkce.undiscovered"]
  test "guessed endpoints cannot advertise undiscovered PKCE support" do
    {:ok, store_agent} =
      Agent.start_link(fn -> %{index: %{}, registrations: %{}, tokens: %{}} end)

    server = oauth_server("unused-client", nil, no_metadata: true)
    owner = self()

    config =
      server
      |> flow_config({StoreAdapter, store_agent})
      |> Map.merge(%{
        client_registration: {:pre_registered, "registered-client", "registered-secret"},
        client_id: "registered-client",
        client_secret: "registered-secret",
        credential_issuer: server.resource_origin <> ":443",
        oauth_http: [
          dns_resolver: fn _host, _timeout -> {:ok, [{93, 184, 216, 34}]} end,
          request_fun: fn method, _request, _http_options, _request_options ->
            send(owner, {:unexpected_protocol_request, method})
            {:error, :fixture_stopped}
          end
        ]
      })

    assert {:error, :pkce_s256_not_supported} = FullOAuthFlow.execute(config)
    refute_received {:unexpected_protocol_request, _method}
    assert %{authorizations: 0, tokens: 0} = Agent.get(server.counter, & &1)
  end

  @tag assurance: ["oauth.dcr.issuer"]
  test "reuses DCR credentials only for the same issuer and re-registers after an AS change" do
    {:ok, store_agent} =
      Agent.start_link(fn -> %{index: %{}, registrations: %{}, tokens: %{}} end)

    first_as = oauth_server("client-at-first-as")
    store = {StoreAdapter, store_agent}

    config = flow_config(first_as, store)

    assert {:ok, %{access_token: "token-for-client-at-first-as"}} =
             FullOAuthFlow.execute(config)

    assert {:ok, %{access_token: "token-for-client-at-first-as"}} =
             FullOAuthFlow.execute(config)

    assert Agent.get(first_as.counter, & &1.registrations) == 1

    second_as = oauth_server("client-at-second-as")

    assert {:ok, %{access_token: "token-for-client-at-second-as"}} =
             second_as
             |> flow_config(store)
             |> FullOAuthFlow.execute()

    assert Agent.get(second_as.counter, & &1.registrations) == 1

    stored_issuers =
      Agent.get(store_agent, fn state ->
        state.registrations
        |> Map.values()
        |> Enum.map(& &1.issuer)
        |> Enum.sort()
      end)

    assert stored_issuers == Enum.sort([first_as.issuer, second_as.issuer])
  end

  test "rejects AS metadata whose issuer differs from the discovered identifier" do
    {:ok, store_agent} =
      Agent.start_link(fn -> %{index: %{}, registrations: %{}, tokens: %{}} end)

    server = oauth_server("unused-client", "https://different.example")

    assert {:error, {:issuer_mismatch, expected: expected, actual: "https://different.example"}} =
             server
             |> flow_config({StoreAdapter, store_agent})
             |> FullOAuthFlow.execute()

    assert expected == server.issuer
    assert Agent.get(server.counter, & &1.registrations) == 0
  end

  test "sends a pathless PRM resource identifier unchanged on the token request" do
    {:ok, store_agent} =
      Agent.start_link(fn -> %{index: %{}, registrations: %{}, tokens: %{}} end)

    server = oauth_server("pathless-resource-client", nil, prm_resource: :pathless_origin)

    assert {:ok, %{access_token: "token-for-pathless-resource-client"}} =
             server
             |> flow_config({StoreAdapter, store_agent})
             |> FullOAuthFlow.execute()

    assert [params] = Agent.get(server.counter, & &1.token_requests)
    assert params["resource"] == server.resource_origin
    refute String.ends_with?(params["resource"], "/")
  end

  test "treats malformed optional PRM fields as absent" do
    {:ok, store_agent} =
      Agent.start_link(fn -> %{index: %{}, registrations: %{}, tokens: %{}} end)

    server =
      oauth_server("client-with-malformed-prm", nil,
        prm_resource: 42,
        prm_scopes: "not-a-list"
      )

    assert {:ok, %{access_token: "token-for-client-with-malformed-prm"}} =
             server
             |> flow_config({StoreAdapter, store_agent})
             |> FullOAuthFlow.execute()
  end

  test "preserves token endpoint errors across the authorization code flow" do
    {:ok, store_agent} =
      Agent.start_link(fn -> %{index: %{}, registrations: %{}, tokens: %{}} end)

    response = %{"error" => "invalid_client", "error_description" => "credentials rejected"}
    server = oauth_server("rejected-client", nil, token_error: response)

    assert {:error, {:oauth_error, 401, ^response}} =
             server
             |> flow_config({StoreAdapter, store_agent})
             |> FullOAuthFlow.execute()
  end

  test "preserves native and web DCR redirect rejections without a weakening retry" do
    {:ok, store_agent} =
      Agent.start_link(fn -> %{index: %{}, registrations: %{}, tokens: %{}} end)

    response = %{
      "error" => "invalid_redirect_uri",
      "error_description" => "redirect URI is not registered by policy"
    }

    for application_type <- [:native, :web] do
      server = oauth_server("unused-client", nil, registration_error: response)

      config =
        server
        |> flow_config({StoreAdapter, store_agent})
        |> Map.put(:application_type, application_type)

      expected_redirect = "http://127.0.0.1:#{server.redirect_port}/callback"

      assert {:error,
              {:redirect_uri_rejected,
               application_type: ^application_type,
               redirect_uri: ^expected_redirect,
               status: 400,
               response: ^response}} = FullOAuthFlow.execute(config)

      state = Agent.get(server.counter, & &1)
      assert state.registrations == 1
      assert state.tokens == 0
      assert [request] = state.registration_requests
      assert request["application_type"] == Atom.to_string(application_type)
      assert request["redirect_uris"] == [expected_redirect]
    end
  end

  test "OAuth logs and telemetry expose only fingerprints for private identifiers" do
    unique = System.unique_integer([:positive])
    client_id = "private-client-#{unique}"
    server = oauth_server(client_id)
    resource_url = server.resource_origin <> "/mcp"
    registration_endpoint = server.actual_origin <> "/register"

    {:ok, store_agent} =
      Agent.start_link(fn -> %{index: %{}, registrations: %{}, tokens: %{}} end)

    events = [
      [:arbor_mcp, :auth, :flow, :started],
      [:arbor_mcp, :auth, :discovery, :completed],
      [:arbor_mcp, :auth, :registration, :completed],
      [:arbor_mcp, :auth, :flow, :completed]
    ]

    handler_id = "oauth-privacy-success-#{unique}"
    owner = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, _measurements, metadata, pid ->
          if self() == pid, do: send(pid, {event, metadata})
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log([metadata: [:registration_endpoint_hash]], fn ->
        assert {:ok, %{access_token: "token-for-" <> ^client_id}} =
                 server
                 |> flow_config({StoreAdapter, store_agent})
                 |> FullOAuthFlow.execute()
      end)

    assert_receive {[:arbor_mcp, :auth, :flow, :started], started}
    assert started == %{resource_hash: LogSummary.fingerprint(resource_url)}

    assert_receive {[:arbor_mcp, :auth, :discovery, :completed], discovery}
    assert discovery == %{issuer_hash: LogSummary.fingerprint(server.issuer)}

    assert_receive {[:arbor_mcp, :auth, :registration, :completed], registration}

    assert registration == %{
             client_id_hash: LogSummary.fingerprint(client_id),
             issuer_hash: LogSummary.fingerprint(server.issuer)
           }

    assert_receive {[:arbor_mcp, :auth, :flow, :completed], completed}
    assert completed == %{resource_hash: LogSummary.fingerprint(resource_url)}

    refute log =~ registration_endpoint
    refute log =~ server.issuer
    refute log =~ resource_url
    refute log =~ client_id
    assert log =~ LogSummary.fingerprint(registration_endpoint)
  end

  test "PRM mismatch logs and failure telemetry do not expose either resource URL" do
    unique = System.unique_integer([:positive])
    private_prm_resource = "https://private-prm-#{unique}.example/resource"
    server = oauth_server("unused-client", nil, prm_resource: private_prm_resource)
    server_url = server.resource_origin <> "/mcp"

    {:ok, store_agent} =
      Agent.start_link(fn -> %{index: %{}, registrations: %{}, tokens: %{}} end)

    handler_id = "oauth-privacy-failure-#{unique}"
    owner = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:arbor_mcp, :auth, :flow, :failed],
        fn event, _measurements, metadata, pid ->
          if self() == pid, do: send(pid, {event, metadata})
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log([metadata: [:resource_hash, :server_hash]], fn ->
        assert {:error, {:resource_mismatch, ^private_prm_resource, ^server_url}} =
                 server
                 |> flow_config({StoreAdapter, store_agent})
                 |> FullOAuthFlow.execute()
      end)

    assert_receive {[:arbor_mcp, :auth, :flow, :failed], metadata}

    assert metadata == %{
             resource_hash: LogSummary.fingerprint(server_url),
             reason: "tuple(size=3)"
           }

    refute log =~ private_prm_resource
    refute log =~ server_url
    assert log =~ LogSummary.fingerprint(private_prm_resource)
    assert log =~ LogSummary.fingerprint(server_url)
  end

  defp oauth_server(client_id, metadata_issuer \\ nil, opts \\ []) do
    bypass = Bypass.open()
    unique = System.unique_integer([:positive])
    issuer_host = "auth-#{unique}.example"
    resource_host = "resource-#{unique}.example"
    issuer = "https://#{issuer_host}"
    resource_origin = "https://#{resource_host}"
    actual_origin = "http://localhost:#{bypass.port}"
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_address, redirect_port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)
    metadata_issuer = metadata_issuer || issuer

    {:ok, counter} =
      Agent.start_link(fn ->
        %{
          registrations: 0,
          registration_requests: [],
          authorizations: 0,
          tokens: 0,
          token_requests: []
        }
      end)

    prm_resource = prm_resource_field(opts[:prm_resource], resource_origin)

    metadata_client = fn uri, _address, _opts ->
      body =
        case {uri.host, uri.path} do
          {^resource_host, "/prm"} ->
            %{"authorization_servers" => [issuer]}
            |> maybe_put("resource", prm_resource)
            |> maybe_put("scopes_supported", opts[:prm_scopes])

          {^issuer_host, "/.well-known/openid-configuration"} ->
            %{
              "issuer" => metadata_issuer,
              "authorization_endpoint" => actual_origin <> "/authorize",
              "token_endpoint" => actual_origin <> "/token",
              "registration_endpoint" => actual_origin <> "/register",
              "grant_types_supported" => ["authorization_code", "refresh_token"],
              "token_endpoint_auth_methods_supported" => ["client_secret_post"]
            }
            |> maybe_put(
              "code_challenge_methods_supported",
              Keyword.get(opts, :pkce_methods, ["S256"])
            )

          _other ->
            nil
        end

      body = if opts[:no_metadata], do: nil, else: body

      if body,
        do: {:ok, %{status: 200, headers: [], body: Jason.encode!(body)}},
        else: {:ok, %{status: 404, headers: [], body: ""}}
    end

    Bypass.stub(bypass, "POST", "/register", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      Agent.update(counter, fn state ->
        state
        |> Map.update!(:registrations, fn count -> count + 1 end)
        |> Map.update!(:registration_requests, &[request | &1])
      end)

      case opts[:registration_error] do
        nil ->
          json(conn, 201, %{
            "client_id" => client_id,
            "client_secret" => "secret-for-#{client_id}"
          })

        error ->
          json(conn, 400, error)
      end
    end)

    Bypass.stub(bypass, "GET", "/authorize", fn conn ->
      Agent.update(counter, &Map.update!(&1, :authorizations, fn count -> count + 1 end))
      params = URI.decode_query(conn.query_string)
      query = URI.encode_query(%{"code" => "fixture-code", "state" => params["state"]})

      conn
      |> Plug.Conn.put_resp_header("location", params["redirect_uri"] <> "?" <> query)
      |> Plug.Conn.resp(302, "")
    end)

    Bypass.stub(bypass, "POST", "/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

      Agent.update(counter, fn state ->
        state
        |> Map.update!(:tokens, fn count -> count + 1 end)
        |> Map.update!(:token_requests, &[params | &1])
      end)

      case opts[:token_error] do
        nil ->
          json(conn, 200, %{
            "access_token" => "token-for-#{client_id}",
            "token_type" => "Bearer",
            "expires_in" => 3_600,
            "scope" => "tools:read"
          })

        error ->
          json(conn, 401, error)
      end
    end)

    %{
      bypass: bypass,
      issuer: issuer,
      resource_origin: resource_origin,
      actual_origin: actual_origin,
      redirect_port: redirect_port,
      metadata_client: metadata_client,
      counter: counter
    }
  end

  defp flow_config(server, store) do
    %{
      resource_url: server.resource_origin <> "/mcp",
      www_authenticate: ~s(Bearer resource_metadata="#{server.resource_origin}/prm"),
      client_registration: :auto,
      application_type: :native,
      redirect_port: server.redirect_port,
      oauth_http: [allow_insecure_loopback: true],
      credential_store: store,
      credential_context: "test-installation",
      scopes: ["tools:read"],
      metadata_fetch: [
        http_client: server.metadata_client,
        dns_resolver: fn _host, _timeout -> {:ok, [{93, 184, 216, 34}]} end,
        allowed_endpoint_origins: [server.actual_origin],
        allow_insecure_loopback: true
      ]
    }
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp prm_resource_field(:pathless_origin, resource_origin), do: resource_origin
  defp prm_resource_field(other, _resource_origin), do: other
end
