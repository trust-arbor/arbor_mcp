defmodule Arbor.MCP.Security.TokenHandler do
  @moduledoc """
  Handles outbound credential isolation and exact-origin trust classification.

  `:trusted_origins` entries are exact HTTP(S) origins: scheme, normalized
  host, and effective port must all match. The explicitly broader
  `:trusted_hosts` policy exists for loopback compatibility and deployments
  that intentionally trust every scheme and port on a host.
  """

  @sensitive_headers [
    "authorization",
    "cookie",
    "x-api-key",
    "x-auth-token",
    "x-csrf-token"
  ]

  @doc """
  Removes credential headers unless the target matches the configured trust
  policy.
  """
  @spec check_token_passthrough(String.t(), [{String.t(), String.t()}], map()) ::
          {:ok, [{String.t(), String.t()}]}
  def check_token_passthrough(url, headers, config) do
    {:ok, strip_sensitive_headers(headers, classify_url(url, config))}
  end

  @doc """
  Classifies a URL against exact origins or a complete security config.

  Passing a list applies exact-origin semantics. Passing a map additionally
  applies its explicitly broad `:trusted_hosts` entries.
  """
  @spec classify_url(String.t(), [String.t()] | map()) :: :internal | :external
  def classify_url(url, trusted_origins) when is_list(trusted_origins) do
    classify_url(url, %{trusted_origins: trusted_origins})
  end

  def classify_url(url, config) when is_map(config) do
    case parse_target_origin(url) do
      {:ok, target} ->
        exact_match? =
          config
          |> Map.get(:trusted_origins, [])
          |> Enum.any?(fn origin -> parse_trusted_origin(origin) == {:ok, target} end)

        host_match? =
          config
          |> Map.get(:trusted_hosts, [])
          |> Enum.any?(&trusted_host_match?(target.host, &1))

        if exact_match? or host_match?, do: :internal, else: :external

      _invalid ->
        :external
    end
  end

  def classify_url(_url, _config), do: :external

  @doc "Strips sensitive headers from targets outside the trust boundary."
  @spec strip_sensitive_headers([{String.t(), String.t()}], :internal | :external) ::
          [{String.t(), String.t()}]
  def strip_sensitive_headers(headers, :internal), do: headers

  def strip_sensitive_headers(headers, :external) do
    Enum.reject(headers, fn {name, _value} ->
      String.downcase(name) in @sensitive_headers
    end)
  end

  @doc "Extracts a canonical `scheme://host:port` origin."
  @spec extract_origin(String.t()) :: {:ok, String.t()} | {:error, :invalid_uri}
  def extract_origin(url) do
    case parse_target_origin(url) do
      {:ok, origin} -> {:ok, format_origin(origin)}
      {:error, _reason} -> {:error, :invalid_uri}
    end
  end

  @doc false
  @spec valid_trusted_origin?(term()) :: boolean()
  def valid_trusted_origin?(origin), do: match?({:ok, _origin}, parse_trusted_origin(origin))

  @doc false
  @spec valid_trusted_host?(term()) :: boolean()
  def valid_trusted_host?(host) when is_binary(host) do
    normalized = normalize_trusted_host(host)
    wildcard? = String.starts_with?(normalized, "*.")
    bare_host = if wildcard?, do: String.trim_leading(normalized, "*."), else: normalized

    bare_host != "" and not String.contains?(bare_host, "*") and
      not String.contains?(normalized, ["://", "/", "?", "#", "@", "\r", "\n"])
  end

  def valid_trusted_host?(_host), do: false

  defp parse_target_origin(url) when is_binary(url) do
    with {:ok, %URI{} = uri} <- URI.new(url),
         true <- is_binary(uri.scheme) and String.downcase(uri.scheme) in ["http", "https"],
         true <- is_binary(uri.host) and uri.host != "",
         true <- is_nil(uri.userinfo) and is_nil(uri.fragment),
         true <- is_nil(uri.port) or uri.port in 1..65_535 do
      scheme = String.downcase(uri.scheme)

      {:ok,
       %{
         scheme: scheme,
         host: String.downcase(uri.host),
         port: effective_port(scheme, uri.port)
       }}
    else
      _invalid -> {:error, :invalid_uri}
    end
  end

  defp parse_target_origin(_url), do: {:error, :invalid_uri}

  defp parse_trusted_origin(origin) when is_binary(origin) do
    with {:ok, %URI{} = uri} <- URI.new(origin),
         true <- uri.path in [nil, "", "/"] and is_nil(uri.query),
         {:ok, parsed} <- parse_target_origin(origin) do
      {:ok, parsed}
    else
      _invalid -> {:error, :invalid_origin}
    end
  end

  defp parse_trusted_origin(_origin), do: {:error, :invalid_origin}

  defp trusted_host_match?(target_host, trusted) when is_binary(trusted) do
    trusted = normalize_trusted_host(trusted)

    cond do
      not valid_trusted_host?(trusted) ->
        false

      String.starts_with?(trusted, "*.") ->
        suffix = String.trim_leading(trusted, "*")
        apex = String.trim_leading(suffix, ".")
        target_host != apex and String.ends_with?(target_host, suffix)

      true ->
        target_host == trusted
    end
  end

  defp trusted_host_match?(_target_host, _trusted), do: false

  defp normalize_trusted_host(host) do
    host
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.downcase()
  end

  defp format_origin(%{scheme: scheme, host: host, port: port}) do
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host
    port_suffix = if port == URI.default_port(scheme), do: "", else: ":#{port}"
    "#{scheme}://#{host}#{port_suffix}"
  end

  defp effective_port(scheme, nil), do: URI.default_port(scheme)
  defp effective_port(_scheme, port), do: port
end
