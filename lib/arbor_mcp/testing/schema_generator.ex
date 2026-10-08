defmodule Arbor.MCP.Testing.SchemaGenerator do
  @moduledoc """
  Generates valid test values from JSON Schema definitions.

  Useful for conformance testing, property-based testing, and automated
  tool exploration. Given a JSON Schema `inputSchema`, produces minimal
  valid arguments that satisfy the schema constraints.

  ## Examples

      iex> schema = %{"type" => "object", "properties" => %{
      ...>   "name" => %{"type" => "string"},
      ...>   "age" => %{"type" => "integer"}
      ...> }, "required" => ["name"]}
      iex> Arbor.MCP.Testing.SchemaGenerator.generate_args(schema)
      %{"name" => "test", "age" => 1}

  """

  @doc """
  Generate a map of arguments from a JSON Schema object definition.

  Returns a map with generated values for all properties. Required
  properties always get values; optional properties get values too
  (conformance tests may validate them).
  """
  @spec generate_args(map() | nil) :: map()
  def generate_args(nil), do: %{}
  def generate_args(%{"type" => "object"} = schema), do: generate_object(schema)
  def generate_args(_), do: %{}

  @doc """
  Generate a single value from a JSON Schema type definition.
  """
  @spec generate_value(map() | nil) :: term()
  def generate_value(nil), do: nil

  def generate_value(%{"enum" => [first | _]}), do: first

  def generate_value(%{"const" => value}), do: value

  def generate_value(%{"default" => value}), do: value

  def generate_value(%{"type" => "string"} = schema) do
    cond do
      schema["format"] == "uri" -> "https://example.com"
      schema["format"] == "email" -> "test@example.com"
      schema["format"] == "date-time" -> "2026-01-01T00:00:00Z"
      schema["minLength"] -> String.duplicate("a", schema["minLength"])
      true -> "test"
    end
  end

  def generate_value(%{"type" => "integer"} = schema) do
    schema["minimum"] || schema["default"] || 1
  end

  def generate_value(%{"type" => "number"} = schema) do
    schema["minimum"] || schema["default"] || 1.0
  end

  def generate_value(%{"type" => "boolean"}), do: true

  def generate_value(%{"type" => "array"} = schema) do
    case schema["items"] do
      nil -> []
      item_schema -> [generate_value(item_schema)]
    end
  end

  def generate_value(%{"type" => "object"} = schema), do: generate_object(schema)

  def generate_value(%{"type" => "null"}), do: nil

  # Union types: pick the first non-null type
  def generate_value(%{"type" => types}) when is_list(types) do
    type = Enum.find(types, &(&1 != "null")) || "string"
    generate_value(%{"type" => type})
  end

  # anyOf/oneOf: pick the first option
  def generate_value(%{"anyOf" => [first | _]}), do: generate_value(first)
  def generate_value(%{"oneOf" => [first | _]}), do: generate_value(first)

  def generate_value(_), do: "test"

  # Generate an object from a JSON Schema with properties
  defp generate_object(%{"properties" => props}) when is_map(props) do
    Map.new(props, fn {name, prop_schema} ->
      {name, generate_value(prop_schema)}
    end)
  end

  defp generate_object(_), do: %{}
end
