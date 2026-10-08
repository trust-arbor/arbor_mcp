defmodule Arbor.MCP.Authorization.ProtectedResourceMetadata do
  @moduledoc """
  OAuth 2.0 Protected Resource Metadata Discovery (RFC 9728 - Draft).

  This module implements the discovery mechanism for protected resources to
  advertise their authorization server relationships. This allows MCP servers
  to indicate which authorization servers protect their resources.

  ## Example

      # Discover authorization servers for a protected resource
      {:ok, metadata} = ProtectedResourceMetadata.discover("https://api.example.com/mcp")

      # Use discovered authorization server
      [auth_server | _] = metadata.authorization_servers
      {:ok, auth_metadata} = Authorization.discover_server_metadata(auth_server.issuer)
  """

  alias Arbor.MCP.Authorization.MetadataFetcher
  alias Arbor.MCP.Internal.Headers

  @type authorization_server :: %{
          issuer: String.t(),
          metadata_endpoint: String.t() | nil,
          scopes_supported: [String.t()] | nil,
          audience: String.t() | [String.t()] | nil
        }

  @type metadata :: %{
          resource: String.t(),
          scopes_supported: [String.t()] | nil,
          authorization_servers: [authorization_server()]
        }

  @type www_authenticate_info :: %{
          realm: String.t() | nil,
          as_uri: String.t() | nil,
          resource_uri: String.t() | nil,
          error: String.t() | nil,
          error_description: String.t() | nil
        }

  @doc """
  Discovers protected resource metadata from the resource URL.

  Makes a request to /.well-known/oauth-protected-resource to discover
  which authorization servers protect this resource. The request uses the
  shared HTTPS-only, public-address, pinned metadata fetch boundary. Test and
  local-development callers may explicitly enable the loopback-only HTTP
  exception supported by `Arbor.MCP.Authorization.MetadataFetcher`.

  The returned metadata keeps the document's `resource` and top-level
  `scopes_supported`. Per RFC 9728 §3.3 a document is used only when its
  `resource` names the resource identifier its well-known URL was built from:

    * the path-specific document
      (`/.well-known/oauth-protected-resource/<path>`) must name
      `resource_url` itself;
    * the root document (`/.well-known/oauth-protected-resource`) may name the
      origin, which is the identifier that URL is derived from, or
      `resource_url`, which MCP servers that publish only root metadata use.

  Scheme and host compare case-insensitively, an explicit default port equals
  an omitted one, and a trailing `/` is ignored; any other difference in
  scheme, host, port, path or query is a different resource, and a `resource`
  carrying a fragment is invalid. A document that lacks `resource` or names
  another resource is skipped and the next URL is tried; when none is usable
  the result is `{:error, {:resource_mismatch, expected: resource_url,
  actual: resource}}` or `{:error, {:invalid_metadata, "Missing resource"}}`.
  """
  @spec discover(String.t(), keyword()) :: {:ok, metadata()} | {:error, term()}
  def discover(resource_url, opts \\ []) do
    with :ok <- validate_endpoint(resource_url, opts) do
      resource_url
      |> build_metadata_urls()
      |> fetch_metadata(resource_url, opts, nil)
    end
  end

  @doc """
  Parses WWW-Authenticate header for authorization information.

  Extracts Bearer authentication parameters including realm, as_uri,
  resource_uri, and error information.
  """
  @spec parse_www_authenticate(String.t()) :: {:ok, www_authenticate_info()} | {:error, term()}
  def parse_www_authenticate(header) do
    cond do
      not is_binary(header) or header == "" ->
        {:error, :invalid_header}

      String.starts_with?(header, "Bearer ") ->
        case parse_bearer_params(header) do
          %{} = params -> {:ok, params}
          :error -> {:error, :invalid_bearer_params}
        end

      true ->
        {:error, :not_bearer}
    end
  end

  # Private functions

  defp validate_endpoint(url, opts) do
    case MetadataFetcher.validate_url(url, opts) do
      :ok -> :ok
      {:error, {:metadata_fetch_error, :https_required}} -> {:error, :https_required}
      {:error, _reason} -> {:error, :invalid_resource_url}
    end
  end

  # Each metadata URL is paired with the resource identifiers its document may
  # name (RFC 9728 §3.3).
  defp build_metadata_urls(resource_url) do
    uri = URI.parse(resource_url)
    resource_path = uri.path || ""

    root_url =
      %URI{uri | path: "/.well-known/oauth-protected-resource", query: nil, fragment: nil}
      |> URI.to_string()

    origin = %URI{uri | path: nil, query: nil, fragment: nil, userinfo: nil} |> URI.to_string()

    case String.trim_trailing(resource_path, "/") do
      "" ->
        [{root_url, Enum.uniq([resource_url, origin])}]

      path ->
        path_url =
          %URI{
            uri
            | path: "/.well-known/oauth-protected-resource#{path}",
              query: nil,
              fragment: nil
          }
          |> URI.to_string()

        [{path_url, [resource_url]}, {root_url, [origin, resource_url]}]
    end
  end

  defp fetch_metadata([{metadata_url, accepted} | fallback_urls], resource_url, opts, skipped) do
    case MetadataFetcher.fetch(metadata_url, opts) do
      {:ok, %{status: 200, body: body}} ->
        case parse_metadata_response(body, resource_url, accepted) do
          {:skip, reason} -> fetch_metadata(fallback_urls, resource_url, opts, {:error, reason})
          result -> result
        end

      {:ok, %{status: 404}} ->
        fetch_metadata(fallback_urls, resource_url, opts, skipped)

      {:ok, %{status: 401, headers: headers}} ->
        # Check for WWW-Authenticate header
        case find_www_authenticate_header(headers) do
          {:ok, _auth_info} ->
            # Could extract metadata URL from header
            {:error, :unauthorized}

          :error ->
            {:error, :unauthorized}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, _reason} = error ->
        error
    end
  end

  # A document that was skipped for naming another resource is the more useful
  # answer than "no metadata" once every URL has been tried.
  defp fetch_metadata([], _resource_url, _opts, nil), do: {:error, :no_metadata}
  defp fetch_metadata([], _resource_url, _opts, skipped), do: skipped

  defp parse_metadata_response(body, resource_url, accepted) do
    case Jason.decode(body) do
      {:ok, %{} = document} ->
        with :ok <- check_resource(document, resource_url, accepted),
             {:ok, scopes} <- parse_scopes_supported(document),
             {:ok, servers} <- parse_authorization_servers(document) do
          {:ok,
           %{
             resource: Map.fetch!(document, "resource"),
             scopes_supported: scopes,
             authorization_servers: servers
           }}
        end

      {:ok, _} ->
        {:error, {:invalid_metadata, "Missing authorization_servers"}}

      {:error, reason} ->
        {:error, {:json_decode_error, reason}}
    end
  end

  # RFC 9728 §3.3: metadata whose `resource` is not the identifier its
  # well-known URL was built from MUST NOT be used.
  defp check_resource(%{"resource" => resource}, resource_url, accepted)
       when is_binary(resource) and resource != "" do
    if Enum.any?(accepted, &same_resource?(resource, &1)) do
      :ok
    else
      {:skip, {:resource_mismatch, expected: resource_url, actual: resource}}
    end
  end

  defp check_resource(%{"resource" => resource}, resource_url, _accepted)
       when not is_nil(resource),
       do: {:skip, {:resource_mismatch, expected: resource_url, actual: resource}}

  defp check_resource(_document, _resource_url, _accepted),
    do: {:skip, {:invalid_metadata, "Missing resource"}}

  defp same_resource?(candidate, expected) do
    case {resource_key(candidate), resource_key(expected)} do
      {{:ok, key}, {:ok, key}} -> true
      _ -> false
    end
  end

  defp resource_key(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, fragment: nil} = uri
      when is_binary(scheme) and is_binary(host) and host != "" ->
        scheme = String.downcase(scheme)

        {:ok,
         {scheme, String.downcase(host), uri.port || URI.default_port(scheme),
          String.trim_trailing(uri.path || "", "/"), uri.query}}

      _other ->
        :error
    end
  end

  defp parse_scopes_supported(%{"scopes_supported" => nil}), do: {:ok, nil}

  defp parse_scopes_supported(%{"scopes_supported" => scopes}) when is_list(scopes) do
    if Enum.all?(scopes, &(is_binary(&1) and &1 != "")) do
      {:ok, scopes}
    else
      {:error, {:invalid_metadata, "Invalid scopes_supported"}}
    end
  end

  defp parse_scopes_supported(%{"scopes_supported" => _invalid}),
    do: {:error, {:invalid_metadata, "Invalid scopes_supported"}}

  defp parse_scopes_supported(_document), do: {:ok, nil}

  defp parse_authorization_servers(%{"authorization_servers" => servers})
       when is_list(servers) do
    servers
    |> Enum.reduce_while({:ok, []}, fn server, {:ok, acc} ->
      case parse_authorization_server(server) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_authorization_servers(_document),
    do: {:error, {:invalid_metadata, "Missing authorization_servers"}}

  defp parse_authorization_server(issuer) when is_binary(issuer) and issuer != "" do
    {:ok, %{issuer: issuer, metadata_endpoint: nil, scopes_supported: nil, audience: nil}}
  end

  defp parse_authorization_server(%{"issuer" => issuer} = server)
       when is_binary(issuer) and issuer != "" do
    {:ok,
     %{
       issuer: issuer,
       metadata_endpoint: Map.get(server, "metadata_endpoint"),
       scopes_supported: Map.get(server, "scopes_supported"),
       audience: Map.get(server, "audience")
     }}
  end

  defp parse_authorization_server(_server),
    do: {:error, {:invalid_metadata, "Invalid authorization server"}}

  defp find_www_authenticate_header(headers) do
    case Headers.get(headers, "www-authenticate") do
      value when is_binary(value) ->
        {:ok, value}

      nil ->
        :error

      _ ->
        :error
    end
  end

  defp parse_bearer_params(header) do
    # Remove "Bearer " prefix
    params_string = String.replace_prefix(header, "Bearer ", "")

    # Return error for empty or malformed
    if params_string == "" or params_string == "Bearer" do
      :error
    else
      # Parse comma-separated key=value pairs
      params =
        params_string
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reduce(%{}, fn param, acc ->
          case String.split(param, "=", parts: 2) do
            [key, value] when key != "" and value != "" ->
              # Check for properly paired quotes
              if String.starts_with?(value, "\"") and not String.ends_with?(value, "\"") do
                # Unclosed quote - invalid
                Map.put(acc, :_invalid, true)
              else
                # Remove quotes if present
                clean_value = String.trim(value, "\"")
                Map.put(acc, key, clean_value)
              end

            _ ->
              acc
          end
        end)

      # Return parsed params or error if no valid params found
      if map_size(params) == 0 or Map.has_key?(params, :_invalid) do
        :error
      else
        %{
          realm: Map.get(params, :realm),
          as_uri: Map.get(params, :as_uri),
          resource_uri: Map.get(params, :resource_uri),
          error: Map.get(params, :error),
          error_description: Map.get(params, :error_description)
        }
      end
    end
  end
end
