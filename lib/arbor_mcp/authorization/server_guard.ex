defmodule Arbor.MCP.Authorization.ServerGuard do
  @moduledoc """
  OAuth 2.1 Resource Server guard for validating bearer tokens.

  This module provides functionality for an MCP server acting as an OAuth 2.1
  Resource Server to validate incoming requests containing bearer tokens. It
  implements the validation logic as specified in RFC 6750.

  ## Features

  - Extracts bearer tokens from the `Authorization` header.
  - Validates tokens using OAuth 2.0 Token Introspection (RFC 7662).
  - Authenticates the resource server to the introspection endpoint.
  - Binds active tokens to the configured issuer and audience/resource.
  - Enforces `exp` and `nbf` NumericDate claims with bounded clock skew.
  - Performs scope-based access control.
  - Generates appropriate `WWW-Authenticate` error responses.
  - Integrates with `Arbor.MCP.FeatureFlags` to be enabled/disabled.

  ## Usage

  This module is typically used in an MCP server's request processing pipeline,
  for example, in a Plug or before a message handler.

      def handle_request(conn, required_scopes) do
        auth_config = %{
          introspection_endpoint: "https://auth.example.com/introspect",
          realm: "mcp-server",
          client_id: "mcp-server",
          client_secret: System.fetch_env!("MCP_INTROSPECTION_SECRET"),
          expected_issuer: "https://auth.example.com",
          expected_audience: "https://mcp.example.com"
        }

        case Arbor.MCP.Authorization.ServerGuard.authorize(conn.req_headers, required_scopes, auth_config) do
          {:ok, token_info} ->
            # Authorization successful, proceed with processing
            # token_info contains claims about the token
            process_authorized_request(conn, token_info)

          {:error, {status, www_auth_header, body}} ->
            # Authorization failed, send error response
            conn
            |> put_resp_header("www-authenticate", www_auth_header)
            |> send_resp(status, body)
        end
      end
  """

  alias Arbor.MCP.Authorization
  alias Arbor.MCP.Authorization.{ScopeValidator, Validator}
  alias Arbor.MCP.FeatureFlags
  alias Arbor.MCP.Internal.Headers

  @type auth_config :: %{
          required(:introspection_endpoint) => String.t(),
          required(:client_id) => String.t(),
          required(:client_secret) => String.t(),
          required(:expected_issuer) => String.t(),
          optional(:expected_audience) => String.t() | [String.t()],
          optional(:expected_resource) => String.t() | [String.t()],
          optional(:introspection_auth_method) => :client_secret_basic | :client_secret_post,
          optional(:clock_skew_seconds) => non_neg_integer(),
          optional(:oauth_http) => keyword(),
          optional(:realm) => String.t(),
          optional(:legacy_unbound_tokens) => boolean()
        }

  @type token_info :: map()
  @type error_response :: {integer(), String.t(), String.t()}

  @doc """
  Authorizes a request by validating the bearer token and checking scopes.

  This is the main entry point for the guard. It performs the following steps:
  1. Checks if OAuth 2.1 authorization is enabled via feature flags.
  2. Extracts the bearer token from the `Authorization` header.
  3. Validates the token using the introspection endpoint.
  4. Verifies that the token's scopes include all required scopes.

  ## Parameters
  - `headers`: A map or list of request headers.
  - `required_scopes`: A list of scope strings required for the operation.
  - `config`: Authorization configuration containing the introspection endpoint,
    resource-server credentials, expected issuer, and expected audience/resource.

  For migration only, `legacy_unbound_tokens: true` retains the old unauthenticated,
  unbound introspection behavior. It disables issuer, audience, and lifetime binding
  and must not be used in production.

  ## Return Value
  - `{:ok, token_info}`: If authorization is successful. `token_info` is the map
    returned from the introspection endpoint.
  - `{:error, error_response}`: If authorization fails. `error_response` is a tuple
    `{status_code, www_authenticate_header, body}`.
  - `:ok`: If authorization is disabled via feature flags.
  """
  @spec authorize(map() | list(), [String.t()], auth_config()) ::
          {:ok, token_info()} | {:error, error_response()} | :ok
  def authorize(headers, required_scopes, config) do
    if FeatureFlags.enabled?(:oauth2_auth) do
      do_authorize(headers, required_scopes, config)
    else
      # Auth is not enabled, so we allow the request.
      :ok
    end
  end

  defp do_authorize(headers, required_scopes, config) do
    with :ok <- validate_config(config),
         {:ok, token} <- extract_bearer_token(headers),
         {:ok, token_info} <- validate_token(token, config),
         :ok <- validate_token_claims(token_info, config),
         :ok <- check_scopes(token_info, required_scopes) do
      :telemetry.execute(
        [:arbor_mcp, :auth, :authorize, :success],
        %{system_time: System.system_time()},
        %{scopes: required_scopes}
      )

      {:ok, token_info}
    else
      {:error, :missing_token} ->
        :telemetry.execute(
          [:arbor_mcp, :auth, :authorize, :failure],
          %{system_time: System.system_time()},
          %{reason: :missing_token}
        )

        {:error,
         build_error_response(
           401,
           "invalid_request",
           "Authorization header is missing or malformed.",
           Map.get(config, :realm),
           nil
         )}

      {:error, :invalid_token, reason} ->
        :telemetry.execute(
          [:arbor_mcp, :auth, :authorize, :failure],
          %{system_time: System.system_time()},
          %{reason: :invalid_token}
        )

        {:error, build_error_response(401, "invalid_token", reason, Map.get(config, :realm), nil)}

      {:error, :invalid_token_claims} ->
        :telemetry.execute(
          [:arbor_mcp, :auth, :authorize, :failure],
          %{system_time: System.system_time()},
          %{reason: :invalid_token_claims}
        )

        {:error,
         build_error_response(
           401,
           "invalid_token",
           "The access token is not valid for this resource server.",
           Map.get(config, :realm),
           nil
         )}

      {:error, :insufficient_scope} ->
        :telemetry.execute(
          [:arbor_mcp, :auth, :authorize, :failure],
          %{system_time: System.system_time()},
          %{reason: :insufficient_scope}
        )

        scope_str = Enum.join(required_scopes, " ")

        {:error,
         build_error_response(
           403,
           "insufficient_scope",
           "The request requires higher privileges.",
           Map.get(config, :realm),
           scope_str
         )}

      {:error, :token_validation_failed, _reason} ->
        :telemetry.execute(
          [:arbor_mcp, :auth, :authorize, :failure],
          %{system_time: System.system_time()},
          %{reason: :token_validation_failed}
        )

        {:error,
         build_error_response(
           401,
           "invalid_token",
           "Token validation failed.",
           Map.get(config, :realm),
           nil
         )}

      {:error, reason} ->
        :telemetry.execute(
          [:arbor_mcp, :auth, :authorize, :failure],
          %{system_time: System.system_time()},
          %{reason: reason}
        )

        # Handle other errors, like config validation or unexpected validation results
        {:error,
         build_error_response(
           500,
           "server_error",
           "Authorization check failed.",
           Map.get(config, :realm),
           nil
         )}
    end
  end

  defp validate_config(%{introspection_endpoint: endpoint} = config) when is_binary(endpoint) do
    with :ok <- Validator.validate_https_endpoint(endpoint),
         :ok <- validate_realm(Map.get(config, :realm)),
         :ok <- validate_clock_skew(Map.get(config, :clock_skew_seconds, 30)) do
      if Map.get(config, :legacy_unbound_tokens, false) do
        :ok
      else
        validate_bound_config(config)
      end
    end
  end

  defp validate_config(_) do
    {:error, :invalid_auth_config}
  end

  defp validate_bound_config(config) do
    auth_method = Map.get(config, :introspection_auth_method, :client_secret_basic)

    with :ok <- non_empty_string(Map.get(config, :client_id)),
         :ok <- non_empty_string(Map.get(config, :client_secret)),
         true <- auth_method in [:client_secret_basic, :client_secret_post],
         :ok <- non_empty_string(Map.get(config, :expected_issuer)),
         :ok <- validate_expected_targets(config) do
      :ok
    else
      _other -> {:error, :invalid_auth_config}
    end
  end

  defp validate_expected_targets(config) do
    targets = expected_targets(config)

    if targets != [] and Enum.all?(targets, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, :invalid_auth_config}
  end

  defp validate_realm(nil), do: :ok

  defp validate_realm(realm) when is_binary(realm) and realm != "" do
    if String.contains?(realm, ["\r", "\n"]),
      do: {:error, :invalid_auth_config},
      else: :ok
  end

  defp validate_realm(_realm), do: {:error, :invalid_auth_config}

  defp validate_clock_skew(value) when is_integer(value) and value >= 0 and value <= 300, do: :ok
  defp validate_clock_skew(_value), do: {:error, :invalid_auth_config}

  defp non_empty_string(value) when is_binary(value) and value != "", do: :ok
  defp non_empty_string(_value), do: {:error, :invalid_auth_config}

  @doc """
  Extracts a bearer token from the `Authorization` header.
  """
  @spec extract_bearer_token(map() | list()) :: {:ok, String.t()} | {:error, :missing_token}
  def extract_bearer_token(headers) do
    auth_header = Headers.get(headers, "authorization")

    case auth_header do
      "Bearer " <> token ->
        if String.length(token) > 0, do: {:ok, token}, else: {:error, :missing_token}

      _ ->
        {:error, :missing_token}
    end
  end

  defp validate_token(token, config) do
    opts =
      if Map.get(config, :legacy_unbound_tokens, false) do
        secure_http_options(config)
      else
        Keyword.merge(secure_http_options(config),
          client_id: config.client_id,
          client_secret: config.client_secret,
          auth_method: Map.get(config, :introspection_auth_method, :client_secret_basic)
        )
      end

    case Authorization.validate_token(token, config.introspection_endpoint, opts) do
      {:ok, token_info} ->
        {:ok, token_info}

      {:error, :token_inactive} ->
        {:error, :invalid_token, "The access token is expired, revoked, or malformed."}

      {:error, {:oauth_error, _status, %{"error" => "invalid_token"}}} ->
        {:error, :invalid_token, "The access token is invalid."}

      {:error, reason} ->
        # Do not expose upstream response bodies or transport details to clients.
        {:error, :token_validation_failed, classify_validation_error(reason)}
    end
  end

  defp classify_validation_error({:oauth_error, status, _body}), do: {:oauth_error, status}
  defp classify_validation_error({:http_error, status, _body}), do: {:http_error, status}
  defp classify_validation_error(_reason), do: :request_failed

  defp secure_http_options(config) do
    case config[:oauth_http] do
      opts when is_list(opts) -> opts
      _other -> []
    end
  end

  defp validate_token_claims(_token_info, %{legacy_unbound_tokens: true}), do: :ok

  defp validate_token_claims(token_info, config) do
    now = System.system_time(:second)
    skew = Map.get(config, :clock_skew_seconds, 30)

    with :ok <- validate_issuer_claim(claim(token_info, :iss), config.expected_issuer),
         :ok <- validate_audience_claim(claim(token_info, :aud), expected_targets(config)),
         :ok <- validate_exp_claim(claim(token_info, :exp), now, skew),
         :ok <- validate_nbf_claim(claim(token_info, :nbf), now, skew) do
      :ok
    else
      _error -> {:error, :invalid_token_claims}
    end
  end

  defp validate_issuer_claim(issuer, expected) when is_binary(issuer) and issuer == expected,
    do: :ok

  defp validate_issuer_claim(_issuer, _expected), do: {:error, :issuer_mismatch}

  defp validate_audience_claim(audience, expected) when is_binary(audience),
    do: validate_audience_claim([audience], expected)

  defp validate_audience_claim(audience, expected) when is_list(audience) do
    if Enum.all?(audience, &is_binary/1) and Enum.all?(expected, &(&1 in audience)),
      do: :ok,
      else: {:error, :audience_mismatch}
  end

  defp validate_audience_claim(_audience, _expected), do: {:error, :audience_mismatch}

  defp validate_exp_claim(exp, now, skew) when is_number(exp) do
    if now < exp + skew, do: :ok, else: {:error, :token_expired}
  end

  defp validate_exp_claim(_exp, _now, _skew), do: {:error, :missing_expiration}

  defp validate_nbf_claim(nil, _now, _skew), do: :ok

  defp validate_nbf_claim(nbf, now, skew) when is_number(nbf) do
    if now + skew >= nbf, do: :ok, else: {:error, :token_not_yet_valid}
  end

  defp validate_nbf_claim(_nbf, _now, _skew), do: {:error, :invalid_not_before}

  defp expected_targets(config) do
    [:expected_audience, :expected_resource]
    |> Enum.flat_map(fn key ->
      case Map.get(config, key) do
        nil -> []
        value when is_list(value) -> value
        value -> [value]
      end
    end)
    |> Enum.uniq()
  end

  defp claim(token_info, key), do: Map.get(token_info, key) || Map.get(token_info, to_string(key))

  defp check_scopes(token_info, required_scopes) do
    # Per RFC 6749, scope is a space-delimited string.
    token_scopes_str = Map.get(token_info, :scope) || Map.get(token_info, "scope") || ""

    if is_binary(token_scopes_str) do
      token_scopes = String.split(token_scopes_str, " ", trim: true)
      ScopeValidator.validate(token_scopes, required_scopes)
    else
      {:error, :insufficient_scope}
    end
  end

  defp build_error_response(status, error_code, description, realm, scope) do
    realm = escape_auth_param(realm)
    scope = escape_auth_param(scope)
    description = escape_auth_param(description)

    parts =
      [
        if(realm, do: ~s(realm="#{realm}")),
        ~s(error="#{error_code}"),
        if(description != "", do: ~s(error_description="#{description}")),
        if(scope, do: ~s(scope="#{scope}"))
      ]
      |> Enum.reject(&is_nil/1)

    www_auth_header = "Bearer " <> Enum.join(parts, ", ")
    body = Jason.encode!(%{error: error_code, error_description: description})

    {status, www_auth_header, body}
  end

  defp escape_auth_param(nil), do: nil

  defp escape_auth_param(value) do
    value
    |> to_string()
    |> String.replace(["\\", "\"", "\r", "\n"], fn
      "\\" -> "\\\\"
      "\"" -> "\\\""
      _control -> " "
    end)
  end
end
