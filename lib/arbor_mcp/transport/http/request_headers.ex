defmodule Arbor.MCP.Transport.HTTP.RequestHeaders do
  @moduledoc false

  alias Arbor.MCP.Internal.{Headers, Security, VersionRegistry}

  @protocol_version_header "MCP-Protocol-Version"
  @session_header "Mcp-Session-Id"
  @last_event_id_header "Last-Event-ID"
  @sentinel_prefix "=?base64?"
  @sentinel_suffix "?="
  @max_header_name_bytes 256
  @max_header_value_bytes 8_192

  @name_sources %{
    "tools/call" => "name",
    "resources/read" => "uri",
    "prompts/get" => "name"
  }

  @spec build(binary(), map()) :: [{String.t(), String.t()}]
  def build(body, state) do
    message = decode_message(body)
    body_version = body_protocol_version(message)
    protocol_version = body_version || state.protocol_version

    modern? =
      case body_version do
        version when is_binary(version) -> VersionRegistry.modern?(version)
        _missing -> false
      end

    configured_headers =
      if modern?,
        do: remove_modern_reserved_headers(state.headers),
        else: state.headers

    base_headers = [
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"},
      {@protocol_version_header, protocol_version}
      | configured_headers
    ]

    base_headers
    |> add_legacy_transport_headers(state, modern?)
    |> add_modern_request_headers(message, modern?)
    |> add_tool_parameter_headers(message, state, modern?)
    |> add_origin(state.origin)
    |> add_security_headers(state.security)
    |> Headers.delete("accept-encoding")
    |> List.insert_at(0, {"accept-encoding", "identity"})
  end

  @spec encode_value(String.t() | integer() | boolean()) :: String.t()
  def encode_value(value) do
    string_value = value_to_string(value)

    if plain_header_value?(string_value) and not sentinel?(string_value) do
      string_value
    else
      @sentinel_prefix <> Base.encode64(string_value) <> @sentinel_suffix
    end
  end

  @spec validate([{String.t(), String.t()}], map()) :: :ok | {:error, String.t()}
  def validate(headers, request) when is_list(headers) and is_map(request) do
    with :ok <- validate_header_bounds(headers),
         {:ok, protocol_version} <- required_header(headers, @protocol_version_header),
         :ok <-
           compare(protocol_version, body_protocol_version(request), @protocol_version_header),
         {:ok, method} <- required_header(headers, "Mcp-Method"),
         :ok <- compare(method, Map.get(request, "method"), "Mcp-Method") do
      validate_name_header(headers, request)
    end
  end

  def validate(_headers, _request), do: {:error, "Malformed HTTP request headers"}

  @spec protocol_version(map()) :: String.t() | nil
  def protocol_version(request), do: body_protocol_version(request)

  defp decode_message(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, message} when is_map(message) -> message
      _other -> %{}
    end
  end

  defp decode_message(_body), do: %{}

  defp body_protocol_version(%{
         "params" => %{
           "_meta" => %{"io.modelcontextprotocol/protocolVersion" => version}
         }
       })
       when is_binary(version),
       do: version

  defp body_protocol_version(_message), do: nil

  defp remove_modern_reserved_headers(headers) do
    headers =
      Enum.reduce(
        [
          @protocol_version_header,
          "Mcp-Method",
          "Mcp-Name",
          @session_header,
          @last_event_id_header
        ],
        headers,
        &Headers.delete(&2, &1)
      )

    Enum.reject(headers, fn {name, _value} ->
      is_binary(name) and String.starts_with?(String.downcase(name), "mcp-param-")
    end)
  end

  defp validate_header_bounds(headers) do
    Enum.reduce_while(headers, :ok, fn
      {name, value}, :ok when is_binary(name) and is_binary(value) ->
        cond do
          byte_size(name) > @max_header_name_bytes ->
            {:halt, {:error, "HTTP header name exceeds the configured limit"}}

          byte_size(value) > @max_header_value_bytes ->
            {:halt, {:error, "HTTP header value exceeds the configured limit"}}

          true ->
            {:cont, :ok}
        end

      _malformed, :ok ->
        {:halt, {:error, "Malformed HTTP request headers"}}
    end)
  end

  defp required_header(headers, name) do
    values = header_values(headers, name)

    case values do
      [value] -> {:ok, value}
      [] -> {:error, "Required #{name} header is missing"}
      _duplicates -> {:error, "Required #{name} header must occur exactly once"}
    end
  end

  defp header_values(headers, name) do
    normalized_name = String.downcase(name)

    for {header_name, value} <- headers,
        is_binary(header_name),
        String.downcase(header_name) == normalized_name,
        do: value
  end

  defp compare(header_value, body_value, name) when is_binary(body_value) do
    if header_value == body_value,
      do: :ok,
      else: {:error, "#{name} header does not match the JSON-RPC body"}
  end

  defp compare(_header_value, _body_value, name) do
    {:error, "#{name} source field is missing from the JSON-RPC body"}
  end

  defp validate_name_header(headers, %{"method" => method} = request) do
    case Map.fetch(@name_sources, method) do
      {:ok, source_field} ->
        with {:ok, encoded_name} <- required_header(headers, "Mcp-Name"),
             {:ok, decoded_name} <- decode_value(encoded_name) do
          compare(decoded_name, get_in(request, ["params", source_field]), "Mcp-Name")
        end

      :error ->
        :ok
    end
  end

  defp validate_name_header(_headers, _request), do: {:error, "JSON-RPC method is missing"}

  @spec decode_value(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def decode_value(value) when is_binary(value) do
    cond do
      sentinel?(value) ->
        encoded_size =
          byte_size(value) - byte_size(@sentinel_prefix) - byte_size(@sentinel_suffix)

        encoded = binary_part(value, byte_size(@sentinel_prefix), encoded_size)

        case Base.decode64(encoded) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:error, "Base64 sentinel header value is malformed"}
        end

      plain_header_value?(value) ->
        {:ok, value}

      true ->
        {:error, "HTTP header value contains unsafe characters"}
    end
  end

  def decode_value(_value), do: {:error, "HTTP header value is malformed"}

  defp add_legacy_transport_headers(headers, _state, true), do: headers

  defp add_legacy_transport_headers(headers, state, false) do
    headers
    |> maybe_prepend(@session_header, state.session_id)
    |> maybe_prepend(@last_event_id_header, state.last_event_id)
  end

  defp add_modern_request_headers(headers, _message, false), do: headers

  defp add_modern_request_headers(headers, %{"method" => method} = message, true)
       when is_binary(method) do
    headers = [{"Mcp-Method", method} | headers]

    case Map.fetch(@name_sources, method) do
      {:ok, source_field} ->
        case get_in(message, ["params", source_field]) do
          value when is_binary(value) -> [{"Mcp-Name", encode_value(value)} | headers]
          _missing_or_invalid -> headers
        end

      :error ->
        headers
    end
  end

  defp add_modern_request_headers(headers, _message, true), do: headers

  defp add_tool_parameter_headers(
         headers,
         %{"method" => "tools/call", "params" => params},
         state,
         true
       ) do
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})
    cache = Map.get(state, :tool_headers) || %{}

    cache
    |> Map.get(name, [])
    |> Enum.reduce(headers, fn annotation, acc ->
      case fetch_path(arguments, annotation.path) do
        {:ok, nil} ->
          acc

        {:ok, value} when is_binary(value) or is_integer(value) or is_boolean(value) ->
          [{"Mcp-Param-#{annotation.header}", encode_value(value)} | acc]

        _missing_or_invalid ->
          acc
      end
    end)
  end

  defp add_tool_parameter_headers(headers, _message, _state, _modern?), do: headers

  defp fetch_path(value, []), do: {:ok, value}

  defp fetch_path(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> fetch_path(value, rest)
      :error -> :error
    end
  end

  defp fetch_path(_value, _path), do: :error

  defp add_origin(headers, nil), do: headers
  defp add_origin(headers, origin), do: [{"Origin", origin} | headers]

  defp add_security_headers(headers, security) do
    if security && Map.get(security, :include_security_headers, false) do
      headers ++ Security.build_standard_security_headers()
    else
      headers
    end
  end

  defp maybe_prepend(headers, _name, nil), do: headers
  defp maybe_prepend(headers, name, value), do: [{name, value} | headers]

  defp value_to_string(value) when is_binary(value), do: value
  defp value_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp value_to_string(true), do: "true"
  defp value_to_string(false), do: "false"

  defp plain_header_value?(""), do: true

  defp plain_header_value?(value) do
    value == String.trim(value) and
      value
      |> :binary.bin_to_list()
      |> Enum.all?(&(&1 == 0x09 or &1 in 0x20..0x7E))
  end

  defp sentinel?(value) do
    String.starts_with?(value, @sentinel_prefix) and
      String.ends_with?(value, @sentinel_suffix)
  end
end
