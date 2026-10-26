defmodule ExMCP.ACP.Registry do
  @moduledoc """
  Helpers for the public ACP agent registry.

  The registry is distributed as JSON and lists ACP-compatible agents plus
  their distribution metadata. These helpers keep ExMCP clients from having to
  hard-code the CDN URL or common lookup details.
  """

  @default_url "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json"

  alias ExMCP.Internal.NameValue

  @type agent :: map()
  @type registry :: map()

  @doc "Returns the public ACP registry URL."
  @spec default_url() :: String.t()
  def default_url, do: @default_url

  @doc """
  Fetches and decodes the ACP registry.

  Options:

  - `:url` - registry URL, defaults to the public latest registry.
  - `:timeout` - request timeout in milliseconds, defaults to 15 seconds.
  - `:headers` - additional HTTP request headers.
  - `:http_client` - test hook taking `(url, headers, timeout)` and returning
    `{:ok, body}` or `{:error, reason}`.

  HTTP redirects are refused (`{:error, {:redirect_refused, status, location}}`)
  so request headers are not replayed onto another origin, including an
  https-to-http downgrade. The returned location has its userinfo, query and
  fragment removed, since a signed URL can carry a token there.
  """
  @spec fetch(keyword()) :: {:ok, registry()} | {:error, any()}
  def fetch(opts \\ []) do
    url = Keyword.get(opts, :url, @default_url)
    timeout = Keyword.get(opts, :timeout, 15_000)
    headers = Keyword.get(opts, :headers, [])
    http_client = Keyword.get(opts, :http_client, &http_get/3)

    with {:ok, body} <- http_client.(url, headers, timeout) do
      parse(body)
    end
  end

  @doc "Decodes registry JSON."
  @spec parse(iodata()) :: {:ok, registry()} | {:error, Jason.DecodeError.t()}
  def parse(json) do
    json
    |> IO.iodata_to_binary()
    |> Jason.decode()
  end

  @doc "Returns all agent entries in a decoded registry map."
  @spec agents(registry()) :: [agent()]
  def agents(%{"agents" => agents}) when is_list(agents), do: agents
  def agents(_registry), do: []

  @doc "Finds an agent by exact id or name, falling back to case-insensitive lookup."
  @spec get_agent(registry(), String.t()) :: agent() | nil
  def get_agent(registry, id_or_name) when is_binary(id_or_name) do
    agents = agents(registry)

    Enum.find(agents, &(&1["id"] == id_or_name or &1["name"] == id_or_name)) ||
      Enum.find(agents, fn agent ->
        String.downcase(agent["id"] || "") == String.downcase(id_or_name) or
          String.downcase(agent["name"] || "") == String.downcase(id_or_name)
      end)
  end

  @doc "Searches agent id, name, and description fields case-insensitively."
  @spec find_agents(registry(), String.t()) :: [agent()]
  def find_agents(registry, query) when is_binary(query) do
    query = String.downcase(query)

    Enum.filter(agents(registry), fn agent ->
      ["id", "name", "description"]
      |> Enum.map(&(agent[&1] || ""))
      |> Enum.any?(&String.contains?(String.downcase(&1), query))
    end)
  end

  @doc ~S(Returns a distribution entry such as `"npx"` or `"binary"`.)
  @spec distribution(agent(), String.t() | atom()) :: map() | nil
  def distribution(agent, kind) do
    get_in(agent, ["distribution", to_string(kind)])
  end

  @doc """
  Builds an `npx` command from an agent registry entry.

  Returns `{:error, :npx_distribution_not_found}` when the agent does not have
  an `npx` distribution, or `{:error, :invalid_npx_package}` when the package
  name is not a valid npm package specifier. Valid packages are separated from
  `npx` flags with `--`.
  """
  @spec npx_command(agent()) ::
          {:ok, [String.t()]} | {:error, :npx_distribution_not_found | :invalid_npx_package}
  def npx_command(agent) do
    case distribution(agent, "npx") do
      %{"package" => package} = npx ->
        if valid_npx_package?(package) do
          {:ok, ["npx", "-y", "--", package | Map.get(npx, "args", [])]}
        else
          {:error, :invalid_npx_package}
        end

      _ ->
        {:error, :npx_distribution_not_found}
    end
  end

  @max_npm_name 214
  @npm_name_re ~r/^[A-Za-z0-9][A-Za-z0-9._~-]*$/
  @npm_spec_re ~r/^[A-Za-z0-9][A-Za-z0-9._~+-]*$/

  defp valid_npx_package?(package) when is_binary(package) and package != "" do
    case npx_package_parts(package) do
      {:ok, name, spec} ->
        byte_size(name) <= @max_npm_name and valid_npm_name?(name) and valid_npm_spec?(spec)

      :error ->
        false
    end
  end

  defp valid_npx_package?(_package), do: false

  defp npx_package_parts("@" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [_scope] ->
        :error

      [scope, name_and_spec] ->
        split_name_and_spec("@#{scope}/", name_and_spec)
    end
  end

  defp npx_package_parts(package), do: split_name_and_spec("", package)

  defp split_name_and_spec(prefix, name_and_spec) do
    case String.split(name_and_spec, "@", parts: 2) do
      [name] when name != "" -> {:ok, prefix <> name, nil}
      [name, spec] when name != "" and spec != "" -> {:ok, prefix <> name, spec}
      _ -> :error
    end
  end

  defp valid_npm_name?("@" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [scope, name] -> Regex.match?(@npm_name_re, scope) and Regex.match?(@npm_name_re, name)
      _ -> false
    end
  end

  defp valid_npm_name?(name), do: Regex.match?(@npm_name_re, name)

  defp valid_npm_spec?(nil), do: true
  defp valid_npm_spec?(spec), do: Regex.match?(@npm_spec_re, spec)

  defp http_get(url, headers, timeout) do
    ensure_http_started()

    request = {String.to_charlist(url), normalize_headers(headers)}
    # Disable :httpc's default autoredirect so Authorization and other
    # request headers are not replayed onto a different origin.
    http_options = [timeout: timeout, connect_timeout: timeout, autoredirect: false]
    options = [body_format: :binary]

    case :httpc.request(:get, request, http_options, options) do
      {:ok, {{_, status, _}, _headers, body}} when status in 200..299 ->
        {:ok, body}

      {:ok, {{_, status, _reason}, resp_headers, _body}} when status in 300..399 ->
        {:error, {:redirect_refused, status, location_header(resp_headers)}}

      {:ok, {{_, status, reason}, _headers, body}} ->
        {:error, {:http_error, status, to_string(reason), body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp location_header(headers) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(to_string(name)) == "location", do: redact_location(to_string(value))
    end)
  end

  # A signed redirect target can carry a token in its query or userinfo.
  defp redact_location(location) do
    URI.to_string(%{URI.parse(location) | userinfo: nil, query: nil, fragment: nil})
  end

  defp ensure_http_started do
    _ = Application.ensure_all_started(:ssl)
    _ = Application.ensure_all_started(:inets)
    :ok
  end

  defp normalize_headers(headers), do: NameValue.charlist_pairs(headers)
end
