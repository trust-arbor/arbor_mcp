defmodule Arbor.MCP.SpecSync.GitHubClient do
  @moduledoc """
  GitHub API client for fetching MCP specification files.

  Uses `:httpc` (Erlang's built-in HTTP client) following the same
  pattern as `Arbor.MCP.Authorization.HTTPClient`. Supports GitHub token
  authentication for higher rate limits.
  """

  @repo "modelcontextprotocol/modelcontextprotocol"
  @api_base "https://api.github.com"
  @raw_base "https://raw.githubusercontent.com"
  @version_pattern ~r/^\d{4}-\d{2}-\d{2}$/

  @doc """
  Discovers available specification versions from the GitHub repository.

  Queries the GitHub Contents API for directories under `schema/` that
  match the date-based version pattern (YYYY-MM-DD).

  Returns `{:ok, versions}` with a sorted list of version strings,
  or `{:error, reason}`.
  """
  @spec discover_versions(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def discover_versions(opts \\ []) do
    url = "#{@api_base}/repos/#{@repo}/contents/schema"

    case api_request(:get, url, opts) do
      {:ok, {200, _headers, body}} ->
        case Jason.decode(body) do
          {:ok, entries} when is_list(entries) ->
            versions =
              entries
              |> Enum.filter(fn entry ->
                entry["type"] == "dir" and
                  Regex.match?(@version_pattern, entry["name"] || "")
              end)
              |> Enum.map(& &1["name"])
              |> Enum.sort()

            {:ok, versions}

          {:ok, _} ->
            {:error, :unexpected_response}

          {:error, reason} ->
            {:error, {:json_decode_error, reason}}
        end

      {:ok, {status, headers, _body}} ->
        {:error, {:api_error, status, rate_limit_info(headers)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Lists files in a GitHub directory recursively using the Git Trees API.

  Returns `{:ok, paths}` with a list of file paths relative to the repo root.
  """
  @spec list_directory(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def list_directory(dir_path, opts \\ []) do
    branch = Keyword.get(opts, :branch, "main")
    encoded_branch = URI.encode(branch, &URI.char_unreserved?/1)
    url = "#{@api_base}/repos/#{@repo}/git/trees/#{encoded_branch}?recursive=1"

    case api_request(:get, url, opts) do
      {:ok, {200, _headers, body}} ->
        case Jason.decode(body) do
          {:ok, %{"tree" => entries, "truncated" => false}} when is_list(entries) ->
            {:ok, files_under_directory(entries, dir_path)}

          {:ok, %{"tree" => _entries, "truncated" => true}} ->
            {:error, :truncated_tree}

          {:ok, _} ->
            {:error, :unexpected_response}

          {:error, reason} ->
            {:error, {:json_decode_error, reason}}
        end

      {:ok, {404, _headers, _body}} ->
        {:ok, []}

      {:ok, {status, headers, _body}} ->
        {:error, {:api_error, status, rate_limit_info(headers)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Fetches a raw file from the repository.

  Uses `raw.githubusercontent.com` which does NOT count against the
  GitHub API rate limit. Supports conditional requests via ETag/If-None-Match.

  Returns:
  - `{:ok, {content, headers}}` on success (200)
  - `{:ok, :not_modified}` when the file hasn't changed (304)
  - `{:ok, :not_found}` when the file doesn't exist (404)
  - `{:error, reason}` on failure
  """
  @spec fetch_raw_file(String.t(), keyword()) ::
          {:ok, {binary(), list()}} | {:ok, :not_modified} | {:ok, :not_found} | {:error, term()}
  def fetch_raw_file(path, opts \\ []) do
    branch = Keyword.get(opts, :branch, "main")
    url = "#{@raw_base}/#{@repo}/#{branch}/#{path}"

    extra_headers =
      case Keyword.get(opts, :etag) do
        nil -> []
        etag -> [{"if-none-match", etag}]
      end

    case raw_request(:get, url, extra_headers, opts) do
      {:ok, {200, headers, body}} ->
        {:ok, {body, headers}}

      {:ok, {304, _headers, _body}} ->
        {:ok, :not_modified}

      {:ok, {404, _headers, _body}} ->
        {:ok, :not_found}

      {:ok, {status, _headers, _body}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Returns rate limit info from the last API response headers.
  """
  @spec rate_limit_info(list()) :: map()
  def rate_limit_info(headers) do
    headers_map = normalize_headers(headers)

    %{
      limit: Map.get(headers_map, "x-ratelimit-limit"),
      remaining: Map.get(headers_map, "x-ratelimit-remaining"),
      reset: Map.get(headers_map, "x-ratelimit-reset"),
      used: Map.get(headers_map, "x-ratelimit-used")
    }
  end

  @doc """
  Extracts the ETag value from response headers.
  """
  @spec get_etag(list()) :: String.t() | nil
  def get_etag(headers) do
    headers
    |> normalize_headers()
    |> Map.get("etag")
  end

  # Private

  defp api_request(method, url, opts) do
    headers = api_headers(opts)
    do_request(method, url, headers)
  end

  defp raw_request(method, url, extra_headers, opts) do
    headers = raw_headers(opts) ++ extra_headers
    do_request(method, url, headers)
  end

  defp do_request(method, url, headers) do
    httpc_headers =
      Enum.map(headers, fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)

    request = {String.to_charlist(url), httpc_headers}

    ssl_opts = [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        versions: [:"tlsv1.2", :"tlsv1.3"],
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]

    case :httpc.request(method, request, ssl_opts, body_format: :binary) do
      {:ok, {{_http_version, status, _reason}, resp_headers, body}} ->
        {:ok, {status, resp_headers, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp api_headers(opts) do
    base = [
      {"accept", "application/vnd.github.v3+json"},
      {"user-agent", "Arbor.MCP-SpecSync/1.0"}
    ]

    case github_token(opts) do
      nil -> base
      token -> [{"authorization", "Bearer #{token}"} | base]
    end
  end

  defp raw_headers(opts) do
    base = [{"user-agent", "Arbor.MCP-SpecSync/1.0"}]

    case github_token(opts) do
      nil -> base
      token -> [{"authorization", "Bearer #{token}"} | base]
    end
  end

  defp github_token(opts) do
    Keyword.get(opts, :token) || System.get_env("GITHUB_TOKEN")
  end

  defp normalize_headers(headers) do
    Map.new(headers, fn {k, v} ->
      key = if is_list(k), do: List.to_string(k), else: to_string(k)
      val = if is_list(v), do: List.to_string(v), else: to_string(v)
      {String.downcase(key), val}
    end)
  end

  defp files_under_directory(entries, dir_path) do
    prefix = String.trim_trailing(dir_path, "/") <> "/"

    entries
    |> Enum.filter(fn entry ->
      entry["type"] == "blob" and String.starts_with?(entry["path"] || "", prefix)
    end)
    |> Enum.map(& &1["path"])
    |> Enum.sort()
  end
end
