defmodule Arbor.MCP.Internal.OptionsTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Internal.Options

  test "positive_integer/3 accepts positive values and otherwise uses the default" do
    assert Options.positive_integer([limit: 7], :limit, 10) == 7
    assert Options.positive_integer([limit: 0], :limit, 10) == 10
    assert Options.positive_integer([limit: -1], :limit, 10) == 10
    assert Options.positive_integer([limit: "7"], :limit, 10) == 10
    assert Options.positive_integer([], :limit, 10) == 10
  end
end
