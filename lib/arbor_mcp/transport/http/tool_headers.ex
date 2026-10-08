defmodule Arbor.MCP.Transport.HTTP.ToolHeaders do
  @moduledoc false

  require Logger

  alias Arbor.MCP.Transport.HTTP.RequestHeaders

  @type annotation :: %{header: String.t(), path: [String.t()], type: String.t()}

  @spec compile(map()) :: {:ok, [annotation()]} | {:error, term()}
  def compile(tool) when is_map(tool) do
    case input_schema(tool) do
      schema when is_map(schema) ->
        with {:ok, annotations} <- collect_schema(stringify_keys(schema), []),
             :ok <- validate_unique_names(annotations) do
          {:ok, annotations}
        end

      _missing_or_invalid ->
        {:ok, []}
    end
  end

  def compile(_tool), do: {:ok, []}

  @spec filter_valid_tools([map()]) :: [map()]
  def filter_valid_tools(tools) when is_list(tools) do
    Enum.filter(tools, fn tool ->
      case compile(tool) do
        {:ok, _annotations} ->
          true

        {:error, reason} ->
          Logger.warning(
            "Excluding tool with invalid x-mcp-header annotation: " <>
              "tool=#{inspect(tool_name(tool))} reason=#{inspect(reason)}"
          )

          false
      end
    end)
  end

  @spec cache([map()]) :: %{optional(String.t()) => [annotation()]}
  def cache(tools) when is_list(tools) do
    Enum.reduce(tools, %{}, fn tool, acc ->
      with name when is_binary(name) <- tool_name(tool),
           {:ok, annotations} <- compile(tool) do
        Map.put(acc, name, annotations)
      else
        _invalid -> acc
      end
    end)
  end

  @spec validate_request([{String.t(), String.t()}], [annotation()], map()) ::
          :ok | {:error, String.t()}
  def validate_request(headers, annotations, arguments)
      when is_list(headers) and is_list(annotations) and is_map(arguments) do
    Enum.reduce_while(annotations, :ok, fn annotation, :ok ->
      values = header_values(headers, "Mcp-Param-#{annotation.header}")

      case fetch_path(arguments, annotation.path) do
        {:ok, nil} ->
          if values == [],
            do: {:cont, :ok},
            else: {:halt, {:error, "Mcp-Param header must be omitted for a null value"}}

        :error ->
          if values == [],
            do: {:cont, :ok},
            else: {:halt, {:error, "Mcp-Param header has no corresponding argument"}}

        {:ok, body_value} ->
          case validate_present_value(values, body_value, annotation.type) do
            :ok ->
              {:cont, :ok}

            {:error, reason} ->
              {:halt, {:error, "Mcp-Param-#{annotation.header}: #{reason}"}}
          end
      end
    end)
  end

  def validate_request(_headers, _annotations, _arguments),
    do: {:error, "Tool arguments or HTTP headers are malformed"}

  defp collect_schema(schema, path) do
    with {:ok, own} <- own_annotation(schema, path),
         {:ok, nested} <- collect_properties(schema, path),
         :ok <- reject_unreachable_annotations(schema) do
      {:ok, own ++ nested}
    end
  end

  defp own_annotation(%{"x-mcp-header" => header} = schema, [_ | _] = path) do
    type = Map.get(schema, "type")

    cond do
      not is_binary(header) or not valid_header_suffix?(header) ->
        {:error, :invalid_header_name}

      type not in ["string", "integer", "boolean"] ->
        {:error, :unsupported_header_value_type}

      true ->
        {:ok, [%{header: header, path: path, type: type}]}
    end
  end

  defp own_annotation(%{"x-mcp-header" => _header}, []),
    do: {:error, :header_annotation_requires_property_path}

  defp own_annotation(_schema, _path), do: {:ok, []}

  defp collect_properties(%{"properties" => properties}, path) when is_map(properties) do
    Enum.reduce_while(properties, {:ok, []}, fn
      {property, schema}, {:ok, acc} when is_binary(property) and is_map(schema) ->
        case collect_schema(schema, path ++ [property]) do
          {:ok, annotations} -> {:cont, {:ok, acc ++ annotations}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _invalid_property, _acc ->
        {:halt, {:error, :invalid_property_schema}}
    end)
  end

  defp collect_properties(%{"properties" => _invalid}, _path),
    do: {:error, :invalid_properties}

  defp collect_properties(_schema, _path), do: {:ok, []}

  defp reject_unreachable_annotations(schema) do
    schema
    |> Map.drop(["x-mcp-header", "properties"])
    |> Enum.find_value(:ok, fn {_key, value} ->
      if contains_annotation?(value), do: {:error, :unreachable_header_annotation}, else: false
    end)
  end

  defp contains_annotation?(%{"x-mcp-header" => _value}), do: true

  defp contains_annotation?(map) when is_map(map),
    do: Enum.any?(map, fn {_key, value} -> contains_annotation?(value) end)

  defp contains_annotation?(list) when is_list(list), do: Enum.any?(list, &contains_annotation?/1)
  defp contains_annotation?(_value), do: false

  defp validate_unique_names(annotations) do
    names = Enum.map(annotations, &String.downcase(&1.header))
    if length(names) == length(Enum.uniq(names)), do: :ok, else: {:error, :duplicate_header_name}
  end

  defp validate_present_value([], _body_value, _type),
    do: {:error, "Required Mcp-Param header is missing"}

  defp validate_present_value([_first, _second | _rest], _body_value, _type),
    do: {:error, "Mcp-Param header must occur exactly once"}

  defp validate_present_value([encoded], body_value, type) do
    with {:ok, decoded} <- RequestHeaders.decode_value(encoded),
         true <- header_value_matches?(decoded, body_value, type) do
      :ok
    else
      false -> {:error, "Mcp-Param header does not match the JSON-RPC body"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp header_value_matches?(decoded, body_value, "string") when is_binary(body_value),
    do: decoded == body_value

  defp header_value_matches?(decoded, body_value, "boolean") when is_boolean(body_value),
    do: decoded == if(body_value, do: "true", else: "false")

  defp header_value_matches?(decoded, body_value, "integer") when is_integer(body_value),
    do: decimal_integer_equal?(decoded, body_value)

  defp header_value_matches?(_decoded, _body_value, _type), do: false

  defp decimal_integer_equal?(value, integer) do
    case Regex.run(~r/^([+-]?)(\d+)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$/, value) do
      [_, sign, whole, fraction, exponent] ->
        compare_decimal_integer(sign, whole, fraction, exponent, integer)

      [_, sign, whole, fraction] ->
        compare_decimal_integer(sign, whole, fraction, "0", integer)

      [_, sign, whole] ->
        compare_decimal_integer(sign, whole, "", "0", integer)

      _no_match ->
        false
    end
  end

  defp compare_decimal_integer(sign, whole, fraction, exponent, integer) do
    with true <- byte_size(whole) + byte_size(fraction) <= 128,
         true <- byte_size(exponent) <= 4,
         {exponent, ""} <- Integer.parse(exponent),
         true <- exponent in -128..128,
         {digits, ""} <- Integer.parse(whole <> fraction) do
      digits = if sign == "-", do: -digits, else: digits
      scale = String.length(fraction) - exponent

      cond do
        scale <= 0 -> digits * Integer.pow(10, -scale) == integer
        rem(digits, Integer.pow(10, scale)) == 0 -> div(digits, Integer.pow(10, scale)) == integer
        true -> false
      end
    else
      _invalid -> false
    end
  end

  defp header_values(headers, name) do
    normalized = String.downcase(name)

    for {header_name, value} <- headers,
        is_binary(header_name),
        String.downcase(header_name) == normalized,
        do: value
  end

  defp fetch_path(value, []), do: {:ok, value}

  defp fetch_path(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> fetch_path(value, rest)
      :error -> :error
    end
  end

  defp fetch_path(_value, _path), do: :error

  defp valid_header_suffix?(header) do
    byte_size(header) in 1..128 and Regex.match?(~r/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/, header)
  end

  defp tool_name(tool), do: Map.get(tool, "name") || Map.get(tool, :name)

  defp input_schema(tool) do
    Map.get(tool, "inputSchema") || Map.get(tool, :inputSchema) ||
      Map.get(tool, "input_schema") || Map.get(tool, :input_schema)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
