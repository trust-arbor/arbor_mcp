defmodule Arbor.MCP.Server.DSL.ParamSchema do
  @moduledoc false

  @numeric [:minimum, :maximum, :exclusive_minimum, :exclusive_maximum, :multiple_of]
  @string [:min_length, :max_length, :pattern]
  @array [:min_items, :max_items, :unique_items]
  @object [:min_properties, :max_properties, :additional_properties]
  @constraints @numeric ++ @string ++ @array ++ @object ++ [:enum]
  @options [:required, :default, :description, :schema] ++ @constraints
  @wire_keys %{
    exclusive_minimum: :exclusiveMinimum,
    exclusive_maximum: :exclusiveMaximum,
    multiple_of: :multipleOf,
    min_length: :minLength,
    max_length: :maxLength,
    min_items: :minItems,
    max_items: :maxItems,
    unique_items: :uniqueItems,
    min_properties: :minProperties,
    max_properties: :maxProperties,
    additional_properties: :additionalProperties
  }

  def build(type, opts) do
    validate_options!(opts)
    constraints = Keyword.take(opts, @constraints)

    if Keyword.has_key?(opts, :schema) do
      unless constraints == [],
        do: raise(ArgumentError, "Use either :schema or param constraint options")

      schema = Keyword.fetch!(opts, :schema)
      unless is_map(schema) or is_boolean(schema), do: invalid!(:schema)
      if is_boolean(schema), do: %{allOf: [schema]}, else: schema
    else
      Enum.reduce(constraints, type_schema(type), fn {key, value}, schema ->
        validate_constraint!(type, key, value)
        Map.put(schema, Map.get(@wire_keys, key, key), value)
      end)
    end
  end

  defp validate_options!(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "Param options must be a keyword list")

    keys = Keyword.keys(opts)

    unless length(keys) == length(Enum.uniq(keys)),
      do: raise(ArgumentError, "Duplicate param option")

    case keys -- @options do
      [] -> :ok
      [key | _rest] -> invalid!(key)
    end

    unless is_boolean(Keyword.get(opts, :required, false)), do: invalid!(:required)

    case Keyword.get(opts, :description) do
      value when is_nil(value) or is_binary(value) -> :ok
      _other -> invalid!(:description)
    end
  end

  defp validate_constraint!(type, key, value) do
    unless applicable?(type, key), do: invalid!(key)
    unless valid_value?(key, value), do: invalid!(key)
  end

  defp applicable?(type, key) when key in @numeric, do: type in [:number, :integer]
  defp applicable?(type, key) when key in @string, do: type == :string
  defp applicable?({:array, _item}, key) when key in @array, do: true
  defp applicable?(type, key) when key in @object, do: type in [:object, :map]
  defp applicable?(_type, :enum), do: true
  defp applicable?(_type, _key), do: false

  defp valid_value?(:multiple_of, value), do: is_number(value) and value > 0
  defp valid_value?(key, value) when key in @numeric, do: is_number(value)
  defp valid_value?(:pattern, value), do: is_binary(value)
  defp valid_value?(:enum, value), do: is_list(value) and value != []

  defp valid_value?(key, value) when key in [:unique_items, :additional_properties],
    do: is_boolean(value)

  defp valid_value?(_key, value), do: is_integer(value) and value >= 0

  defp type_schema(:map), do: %{type: "object"}
  defp type_schema({:array, item}), do: %{type: "array", items: type_schema(item)}
  defp type_schema(type), do: %{type: Atom.to_string(type)}

  defp invalid!(key), do: raise(ArgumentError, "Invalid param option: #{key}")
end
