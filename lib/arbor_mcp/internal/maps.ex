defmodule Arbor.MCP.Internal.Maps do
  @moduledoc false

  @spec put_present(map(), any(), any()) :: map()
  def put_present(map, _key, nil), do: map
  def put_present(map, key, value), do: Map.put(map, key, value)

  @spec put_non_empty(map(), any(), any()) :: map()
  def put_non_empty(map, _key, nil), do: map
  def put_non_empty(map, _key, ""), do: map
  def put_non_empty(map, _key, []), do: map
  def put_non_empty(map, _key, empty) when empty == %{}, do: map
  def put_non_empty(map, key, value), do: Map.put(map, key, value)

  @spec put_present_non_empty_list(map(), any(), any()) :: map()
  def put_present_non_empty_list(map, _key, nil), do: map
  def put_present_non_empty_list(map, _key, []), do: map
  def put_present_non_empty_list(map, key, value), do: Map.put(map, key, value)

  @spec put_truthy(map(), any(), any()) :: map()
  def put_truthy(map, _key, value) when value in [nil, false], do: map
  def put_truthy(map, key, value), do: Map.put(map, key, value)

  @spec put_unless(map(), any(), any(), any()) :: map()
  def put_unless(map, _key, value, value), do: map
  def put_unless(map, key, value, _skip_value), do: Map.put(map, key, value)
end
