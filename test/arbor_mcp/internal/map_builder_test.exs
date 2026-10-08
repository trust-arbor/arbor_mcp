defmodule Arbor.MCP.Internal.MapBuilderTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Internal.MapBuilder

  test "puts values when present" do
    assert %{}
           |> MapBuilder.put_if_present("data", nil)
           |> MapBuilder.put_if_present("message", "ok") == %{"message" => "ok"}
  end

  test "puts values only when truthy" do
    assert %{}
           |> MapBuilder.put_if_truthy("nil", nil)
           |> MapBuilder.put_if_truthy("false", false)
           |> MapBuilder.put_if_truthy("zero", 0)
           |> MapBuilder.put_if_truthy("empty", "") == %{"zero" => 0, "empty" => ""}
  end

  test "puts values unless they match a skip value" do
    assert %{}
           |> MapBuilder.put_unless("arguments", %{}, %{})
           |> MapBuilder.put_unless("metadata", %{"source" => "test"}, %{}) == %{
             "metadata" => %{"source" => "test"}
           }
  end
end
