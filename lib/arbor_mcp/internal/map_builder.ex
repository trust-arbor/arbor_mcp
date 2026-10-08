defmodule Arbor.MCP.Internal.MapBuilder do
  @moduledoc """
  Small pipe-friendly helpers for building protocol maps.

  These helpers keep optional-field decisions explicit at call sites while
  avoiding repeated private `maybe_put` functions across MCP modules.
  """

  @doc "Puts `value` into `map` when the value is not `nil`."
  @spec put_if_present(map(), any(), any()) :: map()
  defdelegate put_if_present(map, key, value), to: Arbor.MCP.Internal.Maps, as: :put_present

  @doc "Puts `value` into `map` when the value is truthy."
  @spec put_if_truthy(map(), any(), any()) :: map()
  defdelegate put_if_truthy(map, key, value), to: Arbor.MCP.Internal.Maps, as: :put_truthy

  @doc "Puts `value` into `map` unless it equals `skip_value`."
  @spec put_unless(map(), any(), any(), any()) :: map()
  defdelegate put_unless(map, key, value, skip_value), to: Arbor.MCP.Internal.Maps
end
