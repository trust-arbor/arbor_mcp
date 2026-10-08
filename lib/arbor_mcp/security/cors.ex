defmodule Arbor.MCP.Security.CORS do
  @moduledoc """
  Handles Cross-Origin Resource Sharing (CORS) logic.

  This module is responsible for validating request origins and building
  appropriate CORS headers for responses.
  """

  # Types needed for function specs
  @type auth_method ::
          {:bearer, token :: String.t()}
          | {:api_key, key :: String.t(), opts :: keyword()}
          | {:basic, username :: String.t(), password :: String.t()}
          | {:custom, headers :: [{String.t(), String.t()}]}
          | {:oauth2, map()}

  @type cors_config :: %{
          optional(:allowed_origins) => [String.t()] | :any,
          optional(:allowed_methods) => [String.t()],
          optional(:allowed_headers) => [String.t()],
          optional(:expose_headers) => [String.t()],
          optional(:max_age) => integer(),
          optional(:allow_credentials) => boolean()
        }

  @type tls_config :: %{
          optional(:verify) => :verify_peer | :verify_none,
          optional(:cacerts) => [binary()],
          optional(:cert) => binary(),
          optional(:key) => binary(),
          optional(:versions) => [atom()],
          optional(:ciphers) => [String.t()]
        }

  @type security_config :: %{
          optional(:auth) => auth_method(),
          optional(:headers) => [{String.t(), String.t()}],
          optional(:validate_origin) => boolean(),
          optional(:allowed_origins) => [String.t()],
          optional(:cors) => cors_config(),
          optional(:tls) => tls_config()
        }

  @doc """
  Validates origin header against allowed origins.

  ## Examples

      iex> Arbor.MCP.Security.CORS.validate_origin("https://example.com", ["https://example.com"])
      :ok

      iex> Arbor.MCP.Security.CORS.validate_origin("https://evil.com", ["https://example.com"])
      {:error, :origin_not_allowed}
  """
  @spec validate_origin(String.t() | nil, [String.t()] | :any) ::
          :ok | {:error, :origin_not_allowed}
  def validate_origin(_origin, :any), do: :ok
  def validate_origin(nil, _allowed_origins), do: :ok

  def validate_origin(origin, allowed_origins) when is_list(allowed_origins) do
    if origin in allowed_origins do
      :ok
    else
      {:error, :origin_not_allowed}
    end
  end

  @doc """
  Builds CORS headers based on configuration.
  """
  @spec build_cors_headers(cors_config(), String.t() | nil) :: [{String.t(), String.t()}]
  def build_cors_headers(cors_config, origin \\ nil) do
    []
    |> add_origin_header(cors_config, origin)
    |> add_cors_header(
      cors_config,
      "Access-Control-Allow-Methods",
      :allowed_methods,
      &Enum.join(&1, ", ")
    )
    |> add_cors_header(
      cors_config,
      "Access-Control-Allow-Headers",
      :allowed_headers,
      &Enum.join(&1, ", ")
    )
    |> add_cors_header(
      cors_config,
      "Access-Control-Expose-Headers",
      :expose_headers,
      &Enum.join(&1, ", ")
    )
    |> add_cors_header(cors_config, "Access-Control-Max-Age", :max_age, &to_string/1)
    |> add_credentials_header(cors_config)
    |> Enum.reverse()
  end

  defp add_origin_header(headers, cors_config, origin) do
    case Map.get(cors_config, :allowed_origins, :any) do
      :any ->
        [{"Access-Control-Allow-Origin", "*"} | headers]

      origins when is_list(origins) ->
        if origin && origin in origins do
          [{"Access-Control-Allow-Origin", origin} | headers]
        else
          headers
        end

      _ ->
        headers
    end
  end

  defp add_cors_header(headers, cors_config, header_name, key, formatter)
       when is_map(cors_config) do
    case Map.get(cors_config, key) do
      nil -> headers
      value -> [{header_name, formatter.(value)} | headers]
    end
  end

  defp add_credentials_header(headers, cors_config) do
    if Map.get(cors_config, :allow_credentials, false) do
      [{"Access-Control-Allow-Credentials", "true"} | headers]
    else
      headers
    end
  end

  @doc """
  Validates request origin against security policy.

  This implements DNS rebinding attack protection as required by the MCP spec.
  """
  @spec validate_request_origin(String.t() | nil, security_config()) ::
          :ok | {:error, :origin_validation_failed}
  def validate_request_origin(origin, %{validate_origin: true} = config) do
    allowed = Map.get(config, :allowed_origins, [])

    case validate_origin(origin, allowed) do
      :ok -> :ok
      {:error, :origin_not_allowed} -> {:error, :origin_validation_failed}
    end
  end

  def validate_request_origin(_, _), do: :ok
end
