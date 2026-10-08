defmodule Arbor.MCP.Authorization.FullOAuthFlow do
  @moduledoc """
  Full OAuth 2.1 authorization code flow with PKCE for MCP.

  Orchestrates the complete browser-based OAuth flow:

  1. Discover Protected Resource Metadata (RFC 9728)
  2. Discover Authorization Server metadata (RFC 8414 / OIDC)
  3. Dynamic Client Registration (RFC 7591) if no client_id
  4. Authorization Code flow with PKCE (RFC 7636)
  5. Local redirect URI server to receive callback
  6. Token exchange at token endpoint

  This is used when a server returns 401 and the client has no
  pre-existing credentials. For clients with credentials, use
  `Arbor.MCP.Authorization.DiscoveryFlow` instead.

  ## Usage

      {:ok, token} = FullOAuthFlow.execute(%{
        resource_url: "http://localhost:3000/mcp",
        client_registration: :auto,
        application_type: :native,
        redirect_port: 8080
      })

  """

  require Logger

  @max_callback_request_bytes 16_384
  @callback_header_timeout_ms 10_000
  @max_callback_params 16
  @max_callback_param_bytes 4_096
  @max_authorization_redirects 5
  @authorization_deadline_ms 15_000

  alias Arbor.MCP.Authorization.{
    ClientAssertion,
    ClientRegistration,
    CredentialStore,
    HTTPClient,
    Issuer,
    MetadataFetcher,
    OAuthFlow,
    OAuthTransactionStore,
    OIDCDiscovery,
    RegistrationPolicy,
    SecureHTTP
  }

  alias Arbor.RPC.LogSummary

  @type config :: %{
          required(:resource_url) => String.t(),
          optional(:client_id) => String.t(),
          optional(:client_secret) => String.t(),
          optional(:client_registration) => RegistrationPolicy.configured_strategy(),
          optional(:credential_issuer) => String.t(),
          optional(:credential_store) => CredentialStore.store(),
          optional(:credential_context) => term(),
          optional(:client_metadata_url) => String.t(),
          optional(:application_type) => RegistrationPolicy.application_type(),
          optional(:redirect_port) => non_neg_integer(),
          optional(:private_key) => JOSE.JWK.t(),
          optional(:signing_algorithm) => String.t(),
          optional(:key_id) => String.t(),
          optional(:scopes) => [String.t()],
          optional(:resource) => String.t() | [String.t()],
          optional(:http_client) => module() | function(),
          optional(:metadata_fetch) => keyword(),
          optional(:oauth_http) => keyword(),
          optional(:authorization_max_redirects) => 0..10,
          optional(:authorization_deadline_ms) => 1..60_000,
          optional(:www_authenticate) => String.t(),
          optional(:protocol_version) => String.t()
        }

  @typep authorization_redirect_result :: {:ok, String.t()} | {:error, term()}
  @typep redirect_visited :: %{optional(String.t()) => true}
  @typep redirect_context :: {redirect_visited(), String.t()}

  @doc """
  Execute the full OAuth flow.

  Returns `{:ok, %{access_token: "...", ...}}` on success.
  """
  @spec execute(config()) :: {:ok, map()} | {:error, term()}
  def execute(config) do
    resource_hash = LogSummary.fingerprint(config[:resource_url])

    :telemetry.execute(
      [:arbor_mcp, :auth, :flow, :started],
      %{system_time: System.system_time()},
      %{resource_hash: resource_hash}
    )

    result =
      with {:ok, prm} <- discover_resource_metadata(config),
           :ok <- validate_prm_resource(prm, config),
           {:ok, as_metadata} <- discover_as_metadata(prm, config),
           {:ok, client_info} <- ensure_client_registered(as_metadata, config) do
        # Merge PRM scopes_supported into config for scope negotiation
        config =
          case prm[:scopes_supported] do
            scopes when is_list(scopes) and scopes != [] ->
              Map.put_new(config, :prm_scopes, scopes)

            _ ->
              config
          end

        run_and_persist_token(as_metadata, client_info, config)
      else
        {:error, _reason} = error -> error
      end

    case result do
      {:ok, _} = ok ->
        :telemetry.execute(
          [:arbor_mcp, :auth, :flow, :completed],
          %{system_time: System.system_time()},
          %{resource_hash: resource_hash}
        )

        ok

      {:error, reason} = err ->
        :telemetry.execute(
          [:arbor_mcp, :auth, :flow, :failed],
          %{system_time: System.system_time()},
          %{resource_hash: resource_hash, reason: LogSummary.describe(reason)}
        )

        err
    end
  end

  # Step 1: Discover which AS protects the resource
  # Select grant flow based on AS metadata's grant_types_supported.
  # If the server only supports client_credentials, use that regardless.
  # Otherwise, use auth code if no pre-existing creds, client_credentials if we have them.
  @jwt_bearer_grant "urn:ietf:params:oauth:grant-type:jwt-bearer"

  defp run_and_persist_token(as_metadata, client_info, config) do
    with {:ok, token_data} <- select_and_run_grant_flow(as_metadata, client_info, config),
         :ok <- persist_token(token_data, as_metadata, client_info, config) do
      {:ok, Map.put(token_data, :authorization_server_issuer, as_metadata["issuer"])}
    else
      {:error, _reason} = error -> error
    end
  end

  defp select_and_run_grant_flow(as_metadata, client_info, config) do
    grant_types = as_metadata["grant_types_supported"] || []
    supports_auth_code = "authorization_code" in grant_types or grant_types == []
    supports_client_creds = "client_credentials" in grant_types
    supports_jwt_bearer = @jwt_bearer_grant in grant_types

    has_preexisting_creds =
      client_info[:registration_method] == :pre_registered and
        is_binary(client_info[:client_secret])

    cond do
      supports_jwt_bearer and config[:idp_id_token] ->
        # Cross-app access: exchange IdP token for ID-JAG, then JWT bearer grant
        run_cross_app_flow(as_metadata, client_info, config)

      supports_client_creds and not supports_auth_code ->
        # Server only supports client_credentials — must use it
        run_client_credentials_flow(as_metadata, client_info, config)

      has_preexisting_creds and supports_client_creds ->
        # Have credentials and server supports client_credentials
        run_client_credentials_flow(as_metadata, client_info, config)

      true ->
        # Default to authorization code flow
        run_auth_code_flow(as_metadata, client_info, config)
    end
  end

  defp discover_resource_metadata(config) do
    fetch_opts = metadata_fetch_options(config)

    # Try PRM URL from WWW-Authenticate header first
    prm_url = extract_resource_metadata_url(config[:www_authenticate])

    prm_result =
      case prm_url do
        nil ->
          discover_prm_with_fallback(config.resource_url, fetch_opts)

        url ->
          case fetch_prm_directly(url, fetch_opts) do
            {:ok, _} = ok -> ok
            {:error, {:metadata_fetch_error, _reason}} = error -> error
            {:error, _reason} -> discover_prm_with_fallback(config.resource_url, fetch_opts)
          end
      end

    case prm_result do
      {:ok, _} = ok ->
        ok

      {:error, {:metadata_fetch_error, _reason}} = error ->
        error

      {:error, _reason} ->
        # PRM not available — fall back to direct AS metadata discovery.
        # This is required for 2025-03-26 backcompat where PRM didn't exist,
        # and is a reasonable fallback for any version when PRM is unavailable.
        Logger.info("PRM not available, falling back to direct AS discovery")
        discover_as_from_www_authenticate(config)
    end
  end

  # Fallback when PRM is unavailable: extract AS URL from WWW-Authenticate header
  # or discover AS metadata directly from the resource origin.
  # Returns a synthetic PRM with pre-fetched AS metadata to avoid double discovery.
  defp discover_as_from_www_authenticate(config) do
    www_auth = config[:www_authenticate] || ""

    # Try to extract AS URL from WWW-Authenticate header
    as_uri = extract_as_uri_from_www_auth(www_auth)

    if as_uri do
      {:ok, %{authorization_servers: [%{issuer: as_uri}]}}
    else
      # No AS URL in header — try well-known discovery on the resource origin
      uri = URI.parse(config[:resource_url])
      base = "#{uri.scheme}://#{uri.host}#{if uri.port, do: ":#{uri.port}", else: ""}"

      case OIDCDiscovery.discover(base, metadata_fetch_options(config)) do
        {:ok, metadata} ->
          with :ok <- Issuer.compare(base, metadata["issuer"]) do
            # Store the already-fetched metadata to avoid re-discovery
            {:ok,
             %{
               authorization_servers: [%{issuer: base}],
               _prefetched_as_metadata: metadata
             }}
          end

        {:error, {:metadata_fetch_error, _reason}} = error ->
          error

        {:error, _reason} ->
          # Last resort: construct endpoint URLs from the resource origin.
          # Per MCP 2025-03-26, when no metadata discovery works, assume
          # standard OAuth endpoints at the resource origin.
          Logger.info("No AS metadata found; constructing endpoints",
            server_hash: LogSummary.fingerprint(base)
          )

          synthetic_metadata = %{
            "issuer" => base,
            "authorization_endpoint" => "#{base}/authorize",
            "token_endpoint" => "#{base}/token",
            "registration_endpoint" => "#{base}/register",
            "response_types_supported" => ["code"],
            "grant_types_supported" => ["authorization_code"],
            "code_challenge_methods_supported" => ["S256"]
          }

          {:ok,
           %{
             authorization_servers: [%{issuer: base}],
             _prefetched_as_metadata: synthetic_metadata
           }}
      end
    end
  end

  defp extract_as_uri_from_www_auth(www_auth) when is_binary(www_auth) do
    case Regex.run(~r/as_uri="([^"]+)"/, www_auth) do
      [_, uri] -> uri
      _ -> nil
    end
  end

  defp extract_as_uri_from_www_auth(_), do: nil

  # Validate that PRM resource field matches our server URL (RFC 8707)
  defp validate_prm_resource(%{resource: prm_resource}, config) when is_binary(prm_resource) do
    server_url = config[:resource_url] || ""

    if urls_match?(prm_resource, server_url) do
      :ok
    else
      Logger.warning("PRM resource mismatch",
        resource_hash: LogSummary.fingerprint(prm_resource),
        server_hash: LogSummary.fingerprint(server_url)
      )

      {:error, {:resource_mismatch, prm_resource, server_url}}
    end
  end

  defp validate_prm_resource(_, _), do: :ok

  defp urls_match?(prm_resource, server_url) do
    # The PRM resource can be the base origin (protects entire origin)
    # or a specific path. Check if server URL starts with PRM resource.
    norm_prm = normalize_url(prm_resource)
    norm_server = normalize_url(server_url)
    norm_server == norm_prm or String.starts_with?(norm_server, norm_prm <> "/")
  end

  defp normalize_url(url) when is_binary(url) do
    uri = URI.parse(url)
    path = (uri.path || "/") |> String.trim_trailing("/")
    "#{uri.scheme}://#{uri.host}:#{uri.port || default_port(uri.scheme)}#{path}"
  end

  defp normalize_url(_), do: ""

  defp default_port("https"), do: 443
  defp default_port("http"), do: 80
  defp default_port(_), do: 80

  # Try path-based PRM discovery first, then fall back to root well-known.
  # Per MCP spec, path-based is /.well-known/oauth-protected-resource/mcp
  # and root is /.well-known/oauth-protected-resource
  defp discover_prm_with_fallback(resource_url, fetch_opts) do
    uri = URI.parse(resource_url)
    base = "#{uri.scheme}://#{uri.host}#{if uri.port, do: ":#{uri.port}", else: ""}"
    path = uri.path || ""

    # Try path-based first (e.g., /.well-known/oauth-protected-resource/mcp)
    path_based_url = "#{base}/.well-known/oauth-protected-resource#{path}"

    case fetch_prm_directly(path_based_url, fetch_opts) do
      {:ok, _} = ok ->
        ok

      {:error, {:metadata_fetch_error, _reason}} = error ->
        error

      {:error, _reason} ->
        # Fall back to root (e.g., /.well-known/oauth-protected-resource)
        root_url = "#{base}/.well-known/oauth-protected-resource"
        fetch_prm_directly(root_url, fetch_opts)
    end
  end

  # Fetch PRM from an explicit URL (from WWW-Authenticate header)
  defp fetch_prm_directly(url, fetch_opts) do
    case MetadataFetcher.fetch(url, fetch_opts) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} when is_map(data) ->
            parse_prm_data(data)

          {:ok, _invalid} ->
            {:error, :invalid_prm_metadata}

          {:error, reason} ->
            {:error, {:prm_parse_error, reason}}
        end

      {:ok, %{status: status}} ->
        {:error, {:prm_fetch_error, status}}

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_prm_data(data) do
    case Map.get(data, "authorization_servers", []) do
      issuers when is_list(issuers) ->
        if Enum.all?(issuers, &(is_binary(&1) and &1 != "")) do
          resource = if is_binary(data["resource"]), do: data["resource"], else: nil
          scopes = if is_list(data["scopes_supported"]), do: data["scopes_supported"], else: nil

          {:ok,
           %{
             authorization_servers: Enum.map(issuers, &%{issuer: &1}),
             resource: resource,
             scopes_supported: scopes
           }}
        else
          {:error, :invalid_prm_metadata}
        end

      _invalid ->
        {:error, :invalid_prm_metadata}
    end
  end

  # Step 2: Fetch AS metadata
  defp discover_as_metadata(prm, config) do
    # Check for prefetched AS metadata (from PRM fallback path)
    case prm do
      %{
        _prefetched_as_metadata: metadata,
        authorization_servers: [%{issuer: issuer} | _]
      }
      when is_map(metadata) ->
        with :ok <- Issuer.compare(issuer, metadata["issuer"]) do
          :telemetry.execute(
            [:arbor_mcp, :auth, :discovery, :completed],
            %{system_time: System.system_time()},
            %{issuer_hash: LogSummary.fingerprint(issuer)}
          )

          {:ok, metadata}
        end

      %{authorization_servers: [%{issuer: issuer} | _]} ->
        case OIDCDiscovery.discover(issuer, metadata_fetch_options(config)) do
          {:ok, metadata} ->
            with :ok <- Issuer.compare(issuer, metadata["issuer"]) do
              :telemetry.execute(
                [:arbor_mcp, :auth, :discovery, :completed],
                %{system_time: System.system_time()},
                %{issuer_hash: LogSummary.fingerprint(issuer)}
              )

              {:ok, metadata}
            end

          {:error, {:issuer_mismatch, _details}} = error ->
            error

          {:error, reason} ->
            {:error, {:as_discovery_failed, reason}}
        end

      _ ->
        {:error, :no_authorization_server_found}
    end
  end

  defp metadata_fetch_options(config) do
    options =
      case config[:metadata_fetch] do
        configured when is_list(configured) -> configured
        _other -> []
      end

    case config[:http_client] do
      nil -> options
      client -> Keyword.put(options, :http_client, client)
    end
  end

  # Step 3: Select pre-registration, configured CIMD, or deprecated DCR.
  defp ensure_client_registered(as_metadata, config) do
    case RegistrationPolicy.select(as_metadata, config) do
      {:ok, {:pre_registered, client_info}} ->
        {:ok, client_info}

      {:ok, {:cimd, client_info}} ->
        Logger.info("Using configured Client ID Metadata Document")
        {:ok, client_info}

      {:ok, {:dynamic, selection}} ->
        case load_persisted_registration(as_metadata, config) do
          {:ok, registration} ->
            Logger.info("Using persisted issuer-bound OAuth client registration")
            {:ok, Map.from_struct(registration)}

          :not_found ->
            do_register_client(selection, as_metadata, config)

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp do_register_client(selection, as_metadata, config) do
    registration_endpoint = selection.registration_endpoint

    Logger.info("Dynamically registering OAuth client",
      registration_endpoint_hash: LogSummary.fingerprint(registration_endpoint)
    )

    redirect_uri = "http://127.0.0.1:#{config.redirect_port}/callback"
    supported = as_metadata["token_endpoint_auth_methods_supported"] || []
    auth_method = select_registration_auth_method(supported)

    case ClientRegistration.register_client(%{
           registration_endpoint: registration_endpoint,
           client_name: "ex_mcp",
           application_type: Atom.to_string(selection.application_type),
           redirect_uris: [redirect_uri],
           grant_types: ["authorization_code", "refresh_token"],
           response_types: ["code"],
           token_endpoint_auth_method: auth_method,
           scope: Enum.join(config[:scopes] || [], " "),
           client_uri: nil,
           logo_uri: nil,
           contacts: nil,
           tos_uri: nil,
           policy_uri: nil,
           software_id: nil,
           software_version: nil
         }) do
      {:ok, reg} ->
        client_id = reg[:client_id] || reg["client_id"]

        client_info = %{
          issuer: as_metadata["issuer"],
          client_id: client_id,
          client_secret: reg[:client_secret] || reg["client_secret"],
          registration_method: :dynamic
        }

        with :ok <- persist_registration(client_info, config) do
          :telemetry.execute(
            [:arbor_mcp, :auth, :registration, :completed],
            %{system_time: System.system_time()},
            %{
              client_id_hash: LogSummary.fingerprint(client_id),
              issuer_hash: LogSummary.fingerprint(as_metadata["issuer"])
            }
          )

          {:ok, client_info}
        end

      {:error, {:registration_error, status, %{"error" => "invalid_redirect_uri"} = response}} ->
        {:error,
         {:redirect_uri_rejected,
          application_type: selection.application_type,
          redirect_uri: redirect_uri,
          status: status,
          response: response}}

      {:error, reason} ->
        {:error, {:registration_failed, reason}}
    end
  end

  defp select_registration_auth_method(supported) do
    cond do
      "none" in supported -> "none"
      "client_secret_basic" in supported -> "client_secret_basic"
      "client_secret_post" in supported -> "client_secret_post"
      true -> "none"
    end
  end

  defp load_persisted_registration(as_metadata, %{credential_store: store} = config) do
    CredentialStore.fetch_registration(
      store,
      credential_context(config),
      as_metadata["issuer"]
    )
  end

  defp load_persisted_registration(_as_metadata, _config), do: :not_found

  defp persist_registration(_client_info, config) when not is_map_key(config, :credential_store),
    do: :ok

  defp persist_registration(client_info, config) do
    CredentialStore.put_registration(
      config.credential_store,
      credential_context(config),
      client_info
    )
  end

  defp persist_token(_token_data, _as_metadata, _client_info, config)
       when not is_map_key(config, :credential_store),
       do: :ok

  defp persist_token(token_data, as_metadata, client_info, config) do
    expires_at =
      case token_field(token_data, :expires_in) do
        seconds when is_integer(seconds) and seconds >= 0 -> System.system_time(:second) + seconds
        _other -> nil
      end

    token = %{
      issuer: as_metadata["issuer"],
      client_id: client_info.client_id,
      resource: config[:resource] || config[:resource_url],
      audience: config[:audience],
      subject: config[:subject],
      client_identity: config[:client_identity] || client_info.client_id,
      granted_scopes:
        token_field(token_data, :scope) || config[:scopes] || config[:prm_scopes] || [],
      access_token: token_field(token_data, :access_token),
      refresh_token: token_field(token_data, :refresh_token),
      token_type: token_field(token_data, :token_type) || "Bearer",
      expires_at: expires_at
    }

    CredentialStore.put_token(config.credential_store, token)
  end

  defp credential_context(config),
    do: config[:credential_context] || config[:resource_url]

  defp token_field(token_data, field) do
    Map.get(token_data, field) || Map.get(token_data, Atom.to_string(field))
  end

  # Step 4a: Client credentials flow (when we have pre-existing credentials)
  defp run_client_credentials_flow(as_metadata, client_info, config) do
    token_endpoint = as_metadata["token_endpoint"]

    if is_nil(token_endpoint) do
      {:error, :missing_token_endpoint}
    else
      supported_methods =
        as_metadata["token_endpoint_auth_methods_supported"] || ["client_secret_post"]

      # Pass token_endpoint and issuer into config for JWT audience.
      # Per MCP ext-auth, the JWT aud claim should be the issuer URL.
      config =
        config
        |> Map.put(:token_endpoint, as_metadata["issuer"] || token_endpoint)

      result =
        with {:ok, token_auth_method} <-
               select_token_auth_method(supported_methods, client_info, config),
             :ok <- log_token_auth_method("client_credentials", token_auth_method),
             {:ok, body} <-
               build_client_credentials_body(client_info, config, token_auth_method) do
          HTTPClient.make_token_request(token_endpoint, body, auth_method: token_auth_method)
        else
          {:error, _reason} = error -> error
        end

      case result do
        {:ok, token_data} ->
          :telemetry.execute(
            [:arbor_mcp, :auth, :token, :obtained],
            %{system_time: System.system_time()},
            %{token_type: token_data[:token_type] || token_data["token_type"]}
          )

          {:ok, token_data}

        {:error, _reason} = error ->
          error
      end
    end
  end

  # Step 4c: Cross-app access flow (RFC 8693 token exchange + RFC 7523 JWT bearer)
  # 1. Exchange IdP ID token for an ID-JAG at the IdP's token endpoint
  # 2. Present the ID-JAG to the AS via JWT bearer grant
  defp run_cross_app_flow(as_metadata, client_info, config) do
    token_endpoint = as_metadata["token_endpoint"]
    idp_token_endpoint = config[:idp_token_endpoint]
    id_token = config[:idp_id_token]
    resource = config[:resource] || config[:resource_url]

    Logger.info("Running cross-app access flow (token exchange → JWT bearer)")

    # Step 1: Exchange ID token for ID-JAG at IdP
    exchange_body = [
      {"grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"},
      {"subject_token", id_token},
      {"subject_token_type", "urn:ietf:params:oauth:token-type:id_token"},
      {"requested_token_type", "urn:ietf:params:oauth:token-type:id-jag"},
      {"audience", as_metadata["issuer"] || token_endpoint},
      {"resource", resource}
    ]

    # Add client auth if we have IdP client credentials
    exchange_body =
      if config[:idp_client_id] do
        exchange_body ++ [{"client_id", config[:idp_client_id]}]
      else
        exchange_body
      end

    case HTTPClient.make_token_request(idp_token_endpoint, exchange_body, auth_method: :none) do
      {:ok, exchange_result} ->
        id_jag = exchange_result[:access_token] || exchange_result["access_token"]

        Logger.info("ID-JAG obtained via token exchange, presenting to AS")

        # Step 2: Present ID-JAG to AS via JWT bearer grant
        # Use client_secret_basic auth if we have a secret
        bearer_body = [
          {"grant_type", @jwt_bearer_grant},
          {"assertion", id_jag},
          {"client_id", client_info.client_id},
          {"client_secret", client_info[:client_secret] || ""},
          {"resource", resource}
        ]

        auth_method =
          if client_info[:client_secret], do: :client_secret_basic, else: :none

        case HTTPClient.make_token_request(token_endpoint, bearer_body, auth_method: auth_method) do
          {:ok, token_data} ->
            :telemetry.execute(
              [:arbor_mcp, :auth, :token, :obtained],
              %{system_time: System.system_time()},
              %{token_type: "cross_app_access"}
            )

            {:ok, token_data}

          {:error, reason} ->
            {:error, {:jwt_bearer_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:token_exchange_failed, reason}}
    end
  end

  defp build_client_credentials_body(client_info, config, :private_key_jwt) do
    # JWT-based client authentication for client_credentials grant
    token_endpoint = config[:token_endpoint] || ""
    private_key = config[:private_key] || client_info[:private_key]
    alg = config[:signing_algorithm] || "ES256"

    case Arbor.MCP.Authorization.ClientAssertion.build_assertion_params(
           client_id: client_info.client_id,
           token_endpoint: token_endpoint,
           private_key: private_key,
           alg: alg
         ) do
      {:ok, assertion_params} ->
        resource = config[:resource] || config[:resource_url] || ""

        body =
          [{"grant_type", "client_credentials"}, {"resource", resource}]
          |> Enum.concat(assertion_params)
          |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)

        {:ok, body}

      {:error, reason} ->
        {:error, {:client_assertion_failed, reason}}
    end
  end

  defp build_client_credentials_body(client_info, config, _auth_method) do
    body =
      [
        grant_type: "client_credentials",
        client_id: client_info.client_id,
        client_secret: Map.get(client_info, :client_secret),
        resource: config[:resource] || config[:resource_url]
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    {:ok, body}
  end

  # Step 4b: Run authorization code flow with PKCE
  defp run_auth_code_flow(as_metadata, client_info, config) do
    authorization_endpoint = as_metadata["authorization_endpoint"]
    token_endpoint = as_metadata["token_endpoint"]

    # Determine token endpoint auth method from AS metadata
    supported_methods =
      as_metadata["token_endpoint_auth_methods_supported"] || ["client_secret_post"]

    with :ok <- validate_endpoints(authorization_endpoint, token_endpoint),
         {:ok, token_auth_method} <-
           select_token_auth_method(supported_methods, client_info, config),
         {:ok, server_pid, redirect_uri} <- setup_redirect_server(config) do
      result =
        case start_flow(client_info, redirect_uri, as_metadata, config) do
          {:ok, auth_url, state_data} ->
            result =
              authorize_and_exchange(
                auth_url,
                state_data,
                server_pid,
                client_info,
                redirect_uri,
                token_endpoint,
                config,
                token_auth_method
              )

            OAuthTransactionStore.abort(state_data.transaction_id)
            result

          {:error, _reason} = error ->
            error
        end

      stop_redirect_server(server_pid)

      case result do
        {:ok, token_data} ->
          :telemetry.execute(
            [:arbor_mcp, :auth, :token, :obtained],
            %{system_time: System.system_time()},
            %{token_type: token_data[:token_type] || token_data["token_type"]}
          )

          {:ok, token_data}

        {:error, _reason} = error ->
          error
      end
    else
      {:error, _reason} = error -> error
    end
  end

  defp validate_endpoints(auth_ep, token_ep) do
    if auth_ep && token_ep, do: :ok, else: {:error, :missing_endpoints}
  end

  defp setup_redirect_server(config) do
    port = config[:redirect_port] || 0

    case start_redirect_server(port) do
      {:ok, server_pid, actual_port} ->
        {:ok, server_pid, "http://127.0.0.1:#{actual_port}/callback"}

      {:error, reason} ->
        {:error, {:redirect_server_failed, reason}}
    end
  end

  defp start_flow(client_info, redirect_uri, as_metadata, config) do
    # Use scopes from: 1) WWW-Authenticate header, 2) PRM scopes_supported,
    # 3) AS metadata scopes_supported, 4) empty
    scopes =
      case config[:scopes] do
        s when is_list(s) and s != [] ->
          s

        _ ->
          config[:prm_scopes] || as_metadata["scopes_supported"] || []
      end

    OAuthFlow.start_authorization_flow(%{
      client_id: client_info.client_id,
      redirect_uri: redirect_uri,
      authorization_endpoint: as_metadata["authorization_endpoint"],
      issuer: as_metadata["issuer"],
      require_issuer: as_metadata["authorization_response_iss_parameter_supported"] == true,
      scopes: scopes,
      resource: config[:resource] || config[:resource_url]
    })
  end

  defp authorize_and_exchange(
         auth_url,
         state_data,
         server_pid,
         client_info,
         redirect_uri,
         token_endpoint,
         config,
         token_auth_method
       ) do
    Logger.info("Starting OAuth authorization request")
    Logger.info("Token endpoint auth method: #{token_auth_method}")

    with {:ok, _} <- follow_authorization(auth_url, redirect_uri, config),
         {:ok, code} <- wait_for_callback(server_pid, state_data),
         {:ok, body} <-
           authorization_code_token_body(
             code,
             state_data,
             client_info,
             redirect_uri,
             token_endpoint,
             config,
             token_auth_method
           ),
         :ok <-
           OAuthTransactionStore.redeem_code(
             state_data.transaction_id,
             code,
             redirect_uri
           ) do
      HTTPClient.make_token_request(
        token_endpoint,
        body,
        auth_method: token_auth_method
      )
    else
      {:error, _reason} = error -> error
    end
  end

  defp authorization_code_token_body(
         code,
         state_data,
         client_info,
         redirect_uri,
         token_endpoint,
         config,
         token_auth_method
       ) do
    base =
      [
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri,
        client_id: client_info.client_id,
        code_verifier: state_data.code_verifier,
        client_secret: client_info[:client_secret],
        resource: config[:resource] || config[:resource_url]
      ]
      |> Enum.reject(fn {_, value} -> is_nil(value) end)

    maybe_add_client_assertion(base, client_info, token_endpoint, config, token_auth_method)
  end

  defp maybe_add_client_assertion(base, client_info, token_endpoint, config, :private_key_jwt) do
    private_key = config[:private_key] || client_info[:private_key]

    if is_nil(private_key) do
      {:error, :private_key_required}
    else
      case ClientAssertion.build_assertion_params(
             client_id: client_info.client_id,
             token_endpoint: token_endpoint,
             private_key: private_key,
             alg: config[:signing_algorithm] || client_info[:signing_algorithm] || "ES256",
             kid: config[:key_id] || client_info[:key_id]
           ) do
        {:ok, assertion_params} ->
          base = Enum.reject(base, fn {key, _value} -> key in [:client_id, "client_id"] end)
          {:ok, base ++ assertion_params}

        {:error, reason} ->
          {:error, {:client_assertion_failed, reason}}
      end
    end
  end

  defp maybe_add_client_assertion(base, _client_info, _token_endpoint, _config, _auth_method),
    do: {:ok, base}

  defp select_token_auth_method(supported, client_info, config) when is_list(supported) do
    private_key = config[:private_key] || client_info[:private_key]
    client_secret = client_info[:client_secret]

    cond do
      "private_key_jwt" in supported and not is_nil(private_key) ->
        {:ok, :private_key_jwt}

      "client_secret_basic" in supported and is_binary(client_secret) ->
        {:ok, :client_secret_basic}

      "client_secret_post" in supported and is_binary(client_secret) ->
        {:ok, :client_secret_post}

      "none" in supported ->
        {:ok, :none}

      true ->
        {:error, {:no_usable_token_auth_method, supported}}
    end
  end

  defp select_token_auth_method(_supported, _client_info, _config),
    do: {:error, :invalid_token_auth_methods}

  defp log_token_auth_method(flow, token_auth_method) do
    Logger.info("Using #{flow} flow with #{token_auth_method} auth")
    :ok
  end

  # The non-interactive conformance flow follows redirects through the same
  # pinned and bounded network boundary as token requests. Intermediate hops
  # remain on the authorization endpoint's origin; the only cross-origin hop
  # permitted is an exact match to the local callback URI.
  @doc false
  def follow_authorization_redirects(url, callback_uri, config \\ %{}),
    do: follow_authorization(url, callback_uri, config)

  defp follow_authorization(url, callback_uri, config) do
    max_redirects =
      bounded_integer(config[:authorization_max_redirects], @max_authorization_redirects, 0, 10)

    deadline_ms =
      bounded_integer(
        config[:authorization_deadline_ms],
        @authorization_deadline_ms,
        1,
        60_000
      )

    with {:ok, start_uri} <- parse_authorization_uri(url),
         {:ok, callback_uri} <- parse_authorization_uri(callback_uri),
         {:ok, authorization_origin} <- exact_origin(start_uri) do
      follow_authorization_hop(
        start_uri,
        callback_uri,
        authorization_origin,
        secure_http_options(config),
        max_redirects,
        System.monotonic_time(:millisecond) + deadline_ms,
        %{}
      )
    end
  end

  @spec follow_authorization_hop(
          URI.t(),
          URI.t(),
          String.t(),
          keyword(),
          non_neg_integer(),
          integer(),
          redirect_visited()
        ) :: authorization_redirect_result()
  defp follow_authorization_hop(
         uri,
         callback_uri,
         authorization_origin,
         http_opts,
         redirects_left,
         deadline,
         visited
       ) do
    canonical = URI.to_string(uri)

    cond do
      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :authorization_deadline_exceeded}

      Map.has_key?(visited, canonical) ->
        {:error, :authorization_redirect_cycle}

      true ->
        request_authorization_hop(
          uri,
          callback_uri,
          authorization_origin,
          http_opts,
          redirects_left,
          deadline,
          visited,
          canonical
        )
    end
  end

  @spec request_authorization_hop(
          URI.t(),
          URI.t(),
          String.t(),
          keyword(),
          non_neg_integer(),
          integer(),
          redirect_visited(),
          String.t()
        ) :: authorization_redirect_result()
  defp request_authorization_hop(
         uri,
         callback_uri,
         authorization_origin,
         http_opts,
         redirects_left,
         deadline,
         visited,
         canonical
       ) do
    case bounded_authorization_request(
           canonical,
           [{"accept", "text/html"}],
           http_opts,
           deadline
         ) do
      {:ok, {{_, status, _}, headers, _body}} when status in [301, 302, 303, 307, 308] ->
        follow_authorization_redirect(
          uri,
          callback_uri,
          authorization_origin,
          http_opts,
          redirects_left,
          deadline,
          {visited, canonical},
          headers
        )

      {:ok, {{_, 200, _}, _headers, _body}} ->
        {:ok, canonical}

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, {:auth_server_error, status}}

      {:error, :authorization_deadline_exceeded} = error ->
        error

      {:error, reason} ->
        {:error, {:auth_request_failed, reason}}
    end
  end

  @spec follow_authorization_redirect(
          URI.t(),
          URI.t(),
          String.t(),
          keyword(),
          non_neg_integer(),
          integer(),
          redirect_context(),
          list()
        ) :: authorization_redirect_result()
  defp follow_authorization_redirect(
         uri,
         callback_uri,
         authorization_origin,
         http_opts,
         redirects_left,
         deadline,
         redirect_context,
         headers
       ) do
    {visited, canonical} = redirect_context

    with true <- redirects_left > 0,
         {:ok, next_uri} <- redirect_location(uri, headers),
         :ok <- validate_authorization_redirect(next_uri, callback_uri, authorization_origin) do
      follow_authorization_target(
        next_uri,
        callback_uri,
        authorization_origin,
        http_opts,
        redirects_left,
        deadline,
        visited,
        canonical
      )
    else
      false -> {:error, :authorization_redirect_limit}
      {:error, _reason} = error -> error
    end
  end

  @spec follow_authorization_target(
          URI.t(),
          URI.t(),
          String.t(),
          keyword(),
          non_neg_integer(),
          integer(),
          redirect_visited(),
          String.t()
        ) :: authorization_redirect_result()
  defp follow_authorization_target(
         next_uri,
         callback_uri,
         authorization_origin,
         http_opts,
         redirects_left,
         deadline,
         visited,
         canonical
       ) do
    if exact_callback?(next_uri, callback_uri) do
      request_authorization_callback(next_uri, http_opts, deadline)
    else
      follow_authorization_hop(
        next_uri,
        callback_uri,
        authorization_origin,
        http_opts,
        redirects_left - 1,
        deadline,
        Map.put(visited, canonical, true)
      )
    end
  end

  defp request_authorization_callback(callback_uri, http_opts, deadline) do
    Logger.info("Following OAuth redirect to callback")

    case bounded_authorization_request(URI.to_string(callback_uri), [], http_opts, deadline) do
      {:ok, {{_, status, _}, _headers, _body}} when status in 200..399 ->
        {:ok, URI.to_string(callback_uri)}

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, {:callback_error, status}}

      {:error, :authorization_deadline_exceeded} = error ->
        error

      {:error, reason} ->
        {:error, {:callback_request_failed, reason}}
    end
  end

  defp redirect_location(base_uri, headers) do
    locations =
      for {name, value} <- headers,
          String.downcase(to_string(name)) == "location",
          do: String.trim(to_string(value))

    case locations do
      [location] when location != "" ->
        try do
          base_uri
          |> URI.merge(location)
          |> URI.to_string()
          |> parse_authorization_uri()
        rescue
          _exception -> {:error, :invalid_redirect_location}
        end

      [] ->
        {:error, :no_redirect_location}

      _multiple ->
        {:error, :invalid_redirect_location}
    end
  end

  defp validate_authorization_redirect(uri, callback_uri, authorization_origin) do
    with {:ok, origin} <- exact_origin(uri) do
      if exact_callback?(uri, callback_uri) or origin == authorization_origin,
        do: :ok,
        else: {:error, :cross_origin_authorization_redirect}
    end
  end

  defp exact_callback?(candidate, callback) do
    String.downcase(candidate.scheme) == String.downcase(callback.scheme) and
      String.downcase(candidate.host) == String.downcase(callback.host) and
      effective_port(candidate) == effective_port(callback) and candidate.path == callback.path and
      is_nil(candidate.fragment) and is_nil(candidate.userinfo)
  end

  defp exact_origin(uri) do
    if is_binary(uri.host) and is_binary(uri.scheme) do
      host = String.downcase(uri.host)
      host = if String.contains?(host, ":"), do: "[#{host}]", else: host
      {:ok, "#{String.downcase(uri.scheme)}://#{host}:#{effective_port(uri)}"}
    else
      {:error, :invalid_authorization_uri}
    end
  end

  defp effective_port(%URI{port: port}) when is_integer(port), do: port
  defp effective_port(%URI{scheme: "https"}), do: 443
  defp effective_port(%URI{scheme: "http"}), do: 80
  defp effective_port(_uri), do: nil

  defp parse_authorization_uri(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{host: host, scheme: scheme} = uri}
      when is_binary(host) and scheme in ["http", "https"] ->
        if is_nil(uri.userinfo) and is_nil(uri.fragment),
          do: {:ok, uri},
          else: {:error, :invalid_authorization_uri}

      _other ->
        {:error, :invalid_authorization_uri}
    end
  end

  defp parse_authorization_uri(_url), do: {:error, :invalid_authorization_uri}

  defp secure_http_options(config) do
    case config[:oauth_http] do
      opts when is_list(opts) -> opts
      _other -> []
    end
  end

  defp bounded_authorization_request(url, headers, http_opts, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :authorization_deadline_exceeded}
    else
      hop_opts =
        http_opts
        |> Keyword.put(
          :request_timeout_ms,
          min(http_opts[:request_timeout_ms] || 5_000, remaining)
        )
        |> Keyword.put(
          :connect_timeout_ms,
          min(http_opts[:connect_timeout_ms] || 2_000, remaining)
        )
        |> Keyword.put(:dns_timeout_ms, min(http_opts[:dns_timeout_ms] || 1_000, remaining))
        |> Keyword.put(
          :max_response_bytes,
          min(http_opts[:max_response_bytes] || 1_048_576, 262_144)
        )

      task = Task.async(fn -> SecureHTTP.request(:get, url, headers, nil, hop_opts) end)

      case Task.yield(task, remaining) do
        {:ok, result} ->
          result

        {:exit, _reason} ->
          {:error, :auth_request_failed}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, :authorization_deadline_exceeded}
      end
    end
  end

  defp bounded_integer(value, _default, min_value, max_value)
       when is_integer(value) and value >= min_value and value <= max_value,
       do: value

  defp bounded_integer(_value, default, _min_value, _max_value), do: default

  # Start a minimal HTTP server to receive the OAuth callback
  defp start_redirect_server(port) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, listen_socket} =
          :gen_tcp.listen(port, [
            :binary,
            active: false,
            reuseaddr: true,
            ip: {127, 0, 0, 1}
          ])

        {:ok, actual_port} = :inet.port(listen_socket)
        send(parent, {:redirect_server_started, actual_port})

        # Accept one connection
        case :gen_tcp.accept(listen_socket, 30_000) do
          {:ok, socket} ->
            receive_callback(socket, listen_socket, parent)

          {:error, reason} ->
            :gen_tcp.close(listen_socket)
            send(parent, {:redirect_callback, {:error, reason}})
        end
      end)

    receive do
      {:redirect_server_started, actual_port} -> {:ok, pid, actual_port}
    after
      5_000 -> {:error, :redirect_server_timeout}
    end
  end

  defp receive_callback(socket, listen_socket, parent) do
    case read_callback_headers(socket) do
      {:ok, data} ->
        {response, result} = callback_response(data)
        :gen_tcp.send(socket, response)
        close_callback_sockets(socket, listen_socket)
        send(parent, {:redirect_callback, result})

      {:error, reason} ->
        close_callback_sockets(socket, listen_socket)
        send(parent, {:redirect_callback, {:error, reason}})
    end
  end

  @doc false
  @spec read_callback_headers(port(), pos_integer()) ::
          {:ok, binary()}
          | {:error,
             :callback_headers_too_large
             | :callback_header_timeout
             | :invalid_callback_headers
             | term()}
  def read_callback_headers(socket, timeout_ms \\ @callback_header_timeout_ms)

  def read_callback_headers(socket, timeout_ms)
      when is_port(socket) and is_integer(timeout_ms) and timeout_ms > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_read_callback_headers(socket, deadline, [], 0)
  end

  def read_callback_headers(_socket, _timeout_ms), do: {:error, :invalid_callback_headers}

  defp do_read_callback_headers(_socket, _deadline, _chunks, bytes_read)
       when bytes_read >= @max_callback_request_bytes,
       do: {:error, :callback_headers_too_large}

  defp do_read_callback_headers(socket, deadline, chunks, bytes_read) do
    remaining_bytes = @max_callback_request_bytes - bytes_read
    remaining_ms = deadline - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      {:error, :callback_header_timeout}
    else
      with :ok <-
             :inet.setopts(socket,
               packet: :line,
               packet_size: remaining_bytes,
               active: false
             ),
           {:ok, chunk} <- recv_callback_header_chunk(socket, remaining_ms) do
        new_size = bytes_read + byte_size(chunk)

        if new_size > @max_callback_request_bytes do
          {:error, :callback_headers_too_large}
        else
          chunks = [chunk | chunks]
          data = chunks |> Enum.reverse() |> IO.iodata_to_binary()

          case :binary.match(data, "\r\n\r\n") do
            {offset, 4} ->
              {:ok, binary_part(data, 0, offset + 4)}

            :nomatch ->
              if valid_callback_line_endings?(data) do
                do_read_callback_headers(socket, deadline, chunks, new_size)
              else
                {:error, :invalid_callback_headers}
              end
          end
        end
      end
    end
  end

  defp recv_callback_header_chunk(socket, remaining_ms) do
    case :gen_tcp.recv(socket, 0, remaining_ms) do
      {:error, :emsgsize} -> {:error, :callback_headers_too_large}
      {:error, :timeout} -> {:error, :callback_header_timeout}
      result -> result
    end
  end

  defp valid_callback_line_endings?(data) do
    data
    |> :binary.matches("\n")
    |> Enum.all?(fn {offset, 1} -> offset > 0 and :binary.at(data, offset - 1) == ?\r end)
  end

  defp callback_response(data) do
    case extract_request_path(data) do
      "/callback" -> callback_query_response(data)
      _other -> {bad_callback_response("Invalid callback path"), {:error, :invalid_callback_path}}
    end
  end

  defp callback_query_response(data) do
    case extract_callback_params(data) do
      {:ok, callback_params} ->
        response =
          "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n" <>
            "<html><body>Authorization complete. You may close this window.</body></html>"

        {response, {:ok, callback_params}}

      {:error, reason} ->
        {bad_callback_response("Invalid callback query"), {:error, reason}}
    end
  end

  defp bad_callback_response(message) do
    "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\n\r\n#{message}"
  end

  defp close_callback_sockets(socket, listen_socket) do
    :gen_tcp.close(socket)
    :gen_tcp.close(listen_socket)
  end

  defp wait_for_callback(_server_pid, transaction) do
    receive do
      {:redirect_callback, {:ok, callback_params}} ->
        case OAuthFlow.validate_authorization_response(callback_params, transaction) do
          {:ok, code} ->
            {:ok, code}

          {:error, :state_mismatch} = error ->
            Logger.warning("OAuth callback state mismatch")
            error

          {:error, {:issuer_mismatch, _details}} = error ->
            Logger.warning("OAuth callback issuer mismatch")
            error

          {:error, _reason} = error ->
            error
        end

      {:redirect_callback, {:error, _reason} = error} ->
        error
    after
      30_000 -> {:error, :callback_timeout}
    end
  end

  defp stop_redirect_server(pid) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      Process.exit(pid, :shutdown)
    end
  end

  defp extract_request_path(data) do
    # Parse "GET /callback?code=xxx&state=yyy HTTP/1.1\r\n..."
    case Regex.run(~r/^(?:GET|POST)\s+([^\s?]+)/, data) do
      [_, path] -> path
      _ -> nil
    end
  end

  defp extract_callback_params(data) when byte_size(data) <= @max_callback_request_bytes do
    with [_, request_target] <- Regex.run(~r/^(?:GET|POST)\s+(\S+)/, data),
         query when is_binary(query) <- URI.parse(request_target).query,
         {:ok, pairs} <- decode_callback_query(query) do
      {:ok, Map.new(pairs)}
    else
      _invalid -> {:error, :invalid_callback_query}
    end
  rescue
    ArgumentError -> {:error, :invalid_callback_query}
  end

  defp extract_callback_params(_data), do: {:error, :invalid_callback_query}

  defp decode_callback_query(query) do
    pairs = query |> URI.query_decoder() |> Enum.take(@max_callback_params + 1)

    valid? =
      length(pairs) <= @max_callback_params and
        Enum.all?(pairs, fn {key, value} ->
          byte_size(key) <= @max_callback_param_bytes and
            byte_size(value) <= @max_callback_param_bytes
        end) and
        map_size(Map.new(pairs)) == length(pairs)

    if valid?, do: {:ok, pairs}, else: {:error, :invalid_callback_query}
  end

  defp extract_resource_metadata_url(nil), do: nil

  defp extract_resource_metadata_url(www_auth) when is_binary(www_auth) do
    case Regex.run(~r/resource_metadata="([^"]+)"/, www_auth) do
      [_, url] -> url
      _ -> nil
    end
  end
end
