defmodule Arbor.MCP.Server.Internal.DSLArguments do
  @moduledoc false
  alias Arbor.MCP.Content.SchemaPolicy
  alias Arbor.MCP.Server.DSL.Builder
  alias Arbor.MCP.Server.ResultNormalizer

  def prepare_tool_arguments(arguments, params, input_schema) when is_map(arguments) do
    json = ResultNormalizer.stringify_keys(arguments)

    json =
      Enum.reduce(params, json, fn param, acc ->
        if param.has_default,
          do: Map.put_new(acc, Atom.to_string(param.name), param.default),
          else: acc
      end)

    case SchemaPolicy.validate_optional(Map.drop(json, ["_meta"]), input_schema) do
      :ok -> {:ok, Builder.normalize_arguments(arguments, params)}
      {:error, _diagnostics} -> invalid_tool_arguments()
    end
  rescue
    ArgumentError -> invalid_tool_arguments()
  end

  def prepare_tool_arguments(_arguments, _params, _input_schema), do: invalid_tool_arguments()

  defp invalid_tool_arguments,
    do: {:error, Arbor.MCP.Error.protocol_error(-32602, "Invalid tool arguments")}

  def validate_tool_response(response, nil), do: {:ok, response}

  def validate_tool_response(response, output_schema) do
    normalized = ResultNormalizer.stringify_keys(response)

    case Map.fetch(normalized, "structuredContent") do
      :error ->
        {:ok, response}

      {:ok, data} ->
        case validate_with_schema(data, output_schema) do
          :ok ->
            {:ok, response}

          {:error, errors} ->
            {:error, "Output validation failed: #{format_validation_errors(errors)}"}
        end
    end
  end

  defp validate_with_schema(data, schema) do
    case SchemaPolicy.validate_optional(data, schema) do
      :ok ->
        :ok

      {:error, reason} when is_tuple(reason) or is_atom(reason) ->
        {:error, [SchemaPolicy.format_error(reason)]}

      {:error, errors} ->
        {:error, errors}
    end
  end

  defp format_validation_errors(errors) when is_list(errors) do
    Enum.map_join(errors, ", ", fn
      message when is_binary(message) -> message
      {message, _path} when is_binary(message) -> message
      _other -> "Invalid structured output"
    end)
  end
end
