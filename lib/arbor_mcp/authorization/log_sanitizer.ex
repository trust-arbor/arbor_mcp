defmodule Arbor.MCP.Authorization.LogSanitizer do
  @moduledoc false

  @redacted "[REDACTED]"
  @sensitive_keys MapSet.new(~w(
    access_token refresh_token id_token token
    registration_access_token authorization_code
    code_verifier code_challenge id_jag
    client_secret client_assertion assertion
    code state cookie set_cookie authorization
  ))

  @doc false
  @spec sanitize(term()) :: term()
  def sanitize(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if sensitive_key?(key) do
        {key, @redacted}
      else
        {key, sanitize(nested)}
      end
    end)
  end

  def sanitize(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&sanitize/1)
    |> List.to_tuple()
  end

  def sanitize(value) when is_list(value) do
    if List.ascii_printable?(value) do
      value |> List.to_string() |> sanitize()
    else
      Enum.map(value, &sanitize/1)
    end
  end

  def sanitize(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) -> sanitize(decoded)
      _not_json -> sanitize_binary(value)
    end
  end

  def sanitize(value), do: value

  @doc false
  @spec format(term()) :: String.t()
  def format(value) do
    value
    |> sanitize()
    |> inspect(limit: 20, printable_limit: 500)
  end

  defp sanitize_binary(value) do
    value
    |> redact_authorization_value()
    |> redact_query_values()
    |> strip_uri_secrets()
  end

  defp redact_authorization_value(value) do
    Regex.replace(~r/\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+\/-]+=*/i, value, @redacted)
  end

  defp redact_query_values(value) do
    Regex.replace(
      ~r/\b(access_token|refresh_token|id_token|token|registration_access_token|authorization_code|code_verifier|code_challenge|id_jag|client_secret|client_assertion|assertion|code|state|cookie|authorization)=([^&\s]+)/i,
      value,
      "\\1=#{@redacted}"
    )
  end

  defp strip_uri_secrets(value) do
    Regex.replace(~r{https?://[^\s"']+}, value, &strip_one_uri/1)
  end

  defp strip_one_uri(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        uri
        |> Map.put(:query, nil)
        |> Map.put(:fragment, nil)
        |> Map.put(:userinfo, nil)
        |> URI.to_string()

      _not_uri ->
        value
    end
  end

  defp sensitive_key?(key) do
    normalized =
      key
      |> to_string()
      |> String.downcase()
      |> String.replace("-", "_")

    MapSet.member?(@sensitive_keys, normalized)
  end
end
