defmodule Arbor.MCP.Internal.NameValue do
  @moduledoc false

  @type builder :: (String.t(), String.t() -> map())

  @spec list(map() | list(), builder()) :: [map()]
  def list(values, builder \\ &entry/2)

  def list(values, builder) when is_map(values) do
    Enum.map(values, fn {name, value} -> builder.(to_string(name), to_string(value)) end)
  end

  def list(values, builder) when is_list(values) do
    Enum.map(values, fn
      %{"name" => name, "value" => value} = item ->
        Map.merge(item, %{"name" => to_string(name), "value" => to_string(value)})

      %{name: name, value: value} ->
        builder.(to_string(name), to_string(value))

      {name, value} ->
        builder.(to_string(name), to_string(value))
    end)
  end

  def list(_values, _builder), do: []

  @spec map(map() | list()) :: map()
  def map(values) when is_map(values) do
    Map.new(values, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  def map(values) when is_list(values) do
    Map.new(values, fn
      %{"name" => name, "value" => value} -> {to_string(name), to_string(value)}
      %{name: name, value: value} -> {to_string(name), to_string(value)}
      {name, value} -> {to_string(name), to_string(value)}
    end)
  end

  def map(_values), do: %{}

  @spec charlist_pairs(map() | list()) :: [{charlist(), charlist()}]
  def charlist_pairs(values) when is_map(values) do
    Enum.map(values, fn {name, value} -> charlist_pair(name, value) end)
  end

  def charlist_pairs(values) when is_list(values) do
    Enum.map(values, fn
      %{"name" => name, "value" => value} -> charlist_pair(name, value)
      %{name: name, value: value} -> charlist_pair(name, value)
      {name, value} -> charlist_pair(name, value)
    end)
  end

  def charlist_pairs(_values), do: []

  @spec entry(String.t(), String.t()) :: map()
  def entry(name, value), do: %{"name" => name, "value" => value}

  defp charlist_pair(name, value),
    do: {to_charlist(to_string(name)), to_charlist(to_string(value))}
end
