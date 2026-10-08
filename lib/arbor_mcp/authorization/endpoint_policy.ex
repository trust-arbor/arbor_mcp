defmodule Arbor.MCP.Authorization.EndpointPolicy do
  @moduledoc false

  alias Arbor.MCP.Authorization.MetadataFetcher

  @endpoint_fields ~w(
    authorization_endpoint
    token_endpoint
    registration_endpoint
    introspection_endpoint
    revocation_endpoint
    userinfo_endpoint
    jwks_uri
  )

  @doc """
  Validates endpoint URLs advertised by authorization-server metadata.

  Endpoints must be HTTPS, contain no userinfo or fragment, and share the
  issuer's exact origin unless their origin is explicitly listed in
  `:allowed_endpoint_origins`.
  """
  @spec validate_metadata(map(), String.t(), keyword()) :: :ok | {:error, term()}
  def validate_metadata(metadata, issuer, opts \\ [])

  def validate_metadata(metadata, issuer, opts)
      when is_map(metadata) and is_binary(issuer) and is_list(opts) do
    with {:ok, issuer_origin} <- exact_origin(issuer, opts),
         {:ok, allowed_origins} <- allowed_origins(opts) do
      metadata
      |> Map.take(@endpoint_fields)
      |> Enum.reduce_while(:ok, fn {field, endpoint}, :ok ->
        case validate_endpoint(endpoint, issuer_origin, allowed_origins, opts) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:invalid_endpoint, field, reason}}}
        end
      end)
    end
  end

  def validate_metadata(_metadata, _issuer, _opts), do: {:error, :invalid_metadata}

  @doc "Returns a canonical exact origin for a URL."
  @spec exact_origin(String.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def exact_origin(url, opts \\ [])

  def exact_origin(url, opts) when is_binary(url) and is_list(opts) do
    with :ok <- MetadataFetcher.validate_url(url, opts),
         {:ok, uri} <- URI.new(url),
         true <- is_binary(uri.host) do
      scheme = String.downcase(uri.scheme)
      host = String.downcase(uri.host)
      host = if String.contains?(host, ":"), do: "[#{host}]", else: host
      port = canonical_port(scheme, uri.port)
      {:ok, "#{scheme}://#{host}#{if port, do: ":#{port}", else: ""}"}
    else
      {:error, _reason} -> {:error, :invalid_uri}
      false -> {:error, :invalid_uri}
    end
  end

  def exact_origin(_url, _opts), do: {:error, :invalid_uri}

  defp allowed_origins(opts) do
    opts
    |> Keyword.get(:allowed_endpoint_origins, [])
    |> case do
      origins when is_list(origins) ->
        Enum.reduce_while(origins, {:ok, []}, fn origin, {:ok, acc} ->
          case exact_origin(origin, opts) do
            {:ok, ^origin} -> {:cont, {:ok, [origin | acc]}}
            _other -> {:halt, {:error, :invalid_allowed_endpoint_origin}}
          end
        end)

      _other ->
        {:error, :invalid_allowed_endpoint_origins}
    end
  end

  defp validate_endpoint(endpoint, issuer_origin, allowed_origins, opts)
       when is_binary(endpoint) do
    with {:ok, endpoint_origin} <- exact_origin(endpoint, opts) do
      if endpoint_origin == issuer_origin or endpoint_origin in allowed_origins,
        do: :ok,
        else: {:error, :cross_origin}
    end
  end

  defp validate_endpoint(_endpoint, _issuer_origin, _allowed_origins, _opts),
    do: {:error, :invalid_uri}

  defp canonical_port("https", port) when port in [nil, 443], do: nil
  defp canonical_port("http", port) when port in [nil, 80], do: nil
  defp canonical_port(_scheme, port), do: port
end
