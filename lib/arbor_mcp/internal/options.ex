defmodule Arbor.MCP.Internal.Options do
  @moduledoc false

  @spec positive_integer(keyword(), atom(), pos_integer()) :: pos_integer()
  def positive_integer(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end
end
