defmodule Arbor.MCP.Authorization.ClientIdMetadata do
  @moduledoc """
  OAuth Client ID Metadata Document support for MCP authorization.

  Implements the OAuth Client ID Metadata Document mechanism where the
  client's `client_id` is a URL that resolves to a JSON document
  containing the client's OAuth metadata.

  This enables dynamic client registration-like behavior without
  requiring a registration endpoint.

  Client IDs are exact HTTPS URLs with a non-root path. The document at that
  URL must repeat the exact client ID and provide `client_name` and
  `redirect_uris`. Authorization servers advertise support with
  `client_id_metadata_document_supported: true`.
  """

  alias Arbor.MCP.Authorization.MetadataFetcher
  alias Arbor.MCP.Internal.MapBuilder

  @max_document_bytes 262_144

  @type client_metadata :: %{String.t() => term()}

  @doc """
  Fetches and parses client metadata from a client_id URL.

  ## Parameters
  - `client_id_url` - The client_id URL to fetch metadata from
  - `opts` - Hardened metadata-fetch options. A custom `:http_client` must
    implement `get(uri, approved_address, opts)` and connect to the supplied
    address while preserving `uri.host` for TLS and HTTP host validation.

  ## Returns
  - `{:ok, metadata}` - Successfully fetched client metadata
  - `{:error, reason}` - Failed to fetch or parse metadata

  The default client permits only HTTPS public addresses, revalidates and pins
  every redirect hop, bounds time and response bytes, and sends no credentials.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, client_metadata()} | {:error, term()}
  def fetch(client_id_url, opts \\ []) do
    with :ok <- validate_url(client_id_url),
         {:ok, metadata} <- do_fetch(client_id_url, opts),
         :ok <- validate(metadata, client_id_url) do
      {:ok, metadata}
    end
  end

  @doc "Returns whether authorization-server metadata advertises CIMD support."
  @spec supported?(map()) :: boolean()
  def supported?(metadata) when is_map(metadata) do
    Map.get(metadata, "client_id_metadata_document_supported") == true or
      Map.get(metadata, :client_id_metadata_document_supported) == true
  end

  def supported?(_metadata), do: false

  @doc "Validates the URL form required for a CIMD client identifier."
  @spec validate_url(String.t()) :: :ok | {:error, term()}
  def validate_url(client_id_url) when is_binary(client_id_url) do
    case URI.parse(client_id_url) do
      %URI{
        scheme: "https",
        host: host,
        path: path,
        userinfo: nil,
        fragment: nil
      }
      when is_binary(host) and host != "" and is_binary(path) and path not in ["", "/"] ->
        :ok

      %URI{scheme: scheme} when scheme != "https" ->
        {:error, :https_client_id_required}

      %URI{path: path} when path in [nil, "", "/"] ->
        {:error, :client_id_path_required}

      _invalid ->
        {:error, :invalid_client_id_url}
    end
  rescue
    ArgumentError -> {:error, :invalid_client_id_url}
  end

  def validate_url(_client_id_url), do: {:error, :invalid_client_id_url}

  @doc """
  Validates client metadata structure.

  ## Required Fields
  - `client_id` - Must match the URL it was fetched from
  - `client_name` - Human-readable name for the client
  - `redirect_uris` - List of allowed redirect URIs

  ## Optional Fields
  - `client_uri` - URL of the client's home page
  - `logo_uri` - URL of the client's logo
  - `scope` - Space-separated list of requested scopes
  - `contacts` - List of contact emails
  - `tos_uri` - Terms of service URL
  - `policy_uri` - Privacy policy URL
  """
  @spec validate(client_metadata(), String.t()) :: :ok | {:error, term()}
  def validate(metadata, expected_client_id)
      when is_map(metadata) and is_binary(expected_client_id) do
    with :ok <- validate_url(expected_client_id),
         :ok <- validate_client_id(metadata, expected_client_id),
         :ok <- validate_required_fields(metadata),
         :ok <- validate_client_name(metadata),
         :ok <- validate_redirect_uris(metadata) do
      validate_private_key_jwt(metadata)
    end
  end

  def validate(_metadata, _expected_client_id), do: {:error, :invalid_client_metadata}

  @doc """
  Builds a client metadata document for this application.

  Useful for MCP clients that want to publish their own metadata.
  """
  @spec build_metadata(keyword()) :: client_metadata()
  def build_metadata(opts \\ []) do
    %{
      "client_id" => Keyword.fetch!(opts, :client_id),
      "client_name" => Keyword.fetch!(opts, :client_name),
      "redirect_uris" => Keyword.fetch!(opts, :redirect_uris)
    }
    |> MapBuilder.put_if_present("client_uri", Keyword.get(opts, :client_uri))
    |> MapBuilder.put_if_present("logo_uri", Keyword.get(opts, :logo_uri))
    |> MapBuilder.put_if_present("scope", Keyword.get(opts, :scope))
    |> MapBuilder.put_if_present("contacts", Keyword.get(opts, :contacts))
    |> MapBuilder.put_if_present("tos_uri", Keyword.get(opts, :tos_uri))
    |> MapBuilder.put_if_present("policy_uri", Keyword.get(opts, :policy_uri))
    |> MapBuilder.put_if_present("grant_types", Keyword.get(opts, :grant_types))
    |> MapBuilder.put_if_present("response_types", Keyword.get(opts, :response_types))
    |> MapBuilder.put_if_present(
      "token_endpoint_auth_method",
      Keyword.get(opts, :token_endpoint_auth_method)
    )
    |> MapBuilder.put_if_present("jwks_uri", Keyword.get(opts, :jwks_uri))
    |> MapBuilder.put_if_present("jwks", Keyword.get(opts, :jwks))
  end

  # Private helpers

  defp do_fetch(url, opts) do
    max_bytes = min_valid_limit(Keyword.get(opts, :max_response_bytes))
    fetch_opts = Keyword.put(opts, :max_response_bytes, max_bytes)

    case MetadataFetcher.fetch(url, fetch_opts) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
          _ -> {:error, :invalid_json}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, {:metadata_fetch_error, :response_too_large}} ->
        {:error, :metadata_document_too_large}

      {:error, _reason} = error ->
        error
    end
  end

  defp min_valid_limit(limit) when is_integer(limit) and limit >= 0,
    do: min(limit, @max_document_bytes)

  defp min_valid_limit(_limit), do: @max_document_bytes

  defp validate_client_id(metadata, expected_client_id) do
    case Map.get(metadata, "client_id") do
      ^expected_client_id -> :ok
      nil -> {:error, :missing_client_id}
      actual -> {:error, {:client_id_mismatch, expected: expected_client_id, actual: actual}}
    end
  end

  defp validate_required_fields(metadata) do
    required = ["client_id", "client_name", "redirect_uris"]
    missing = Enum.reject(required, &Map.has_key?(metadata, &1))

    case missing do
      [] -> :ok
      [field | _] -> {:error, {:missing_required_field, field}}
    end
  end

  defp validate_client_name(%{"client_name" => name}) when is_binary(name) and name != "",
    do: :ok

  defp validate_client_name(_metadata), do: {:error, {:invalid_field, "client_name"}}

  defp validate_redirect_uris(%{"redirect_uris" => uris}) when is_list(uris) and uris != [] do
    if Enum.all?(uris, &valid_redirect_uri?/1) and Enum.uniq(uris) == uris do
      :ok
    else
      {:error, {:invalid_field, "redirect_uris"}}
    end
  end

  defp validate_redirect_uris(_metadata), do: {:error, {:invalid_field, "redirect_uris"}}

  defp valid_redirect_uri?(uri) when is_binary(uri) and uri != "" do
    case URI.parse(uri) do
      %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        true

      %URI{scheme: "http", host: host, userinfo: nil, fragment: nil}
      when host in ["localhost", "127.0.0.1", "[::1]", "::1"] ->
        true

      _invalid ->
        false
    end
  end

  defp valid_redirect_uri?(_uri), do: false

  defp validate_private_key_jwt(%{"token_endpoint_auth_method" => "private_key_jwt"} = metadata) do
    cond do
      valid_jwks_uri?(Map.get(metadata, "jwks_uri")) -> :ok
      valid_jwks?(Map.get(metadata, "jwks")) -> :ok
      true -> {:error, :private_key_jwt_requires_jwks}
    end
  end

  defp validate_private_key_jwt(_metadata), do: :ok

  defp valid_jwks_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        true

      _invalid ->
        false
    end
  end

  defp valid_jwks_uri?(_uri), do: false

  defp valid_jwks?(%{"keys" => keys}) when is_list(keys) and keys != [], do: true
  defp valid_jwks?(_jwks), do: false
end
