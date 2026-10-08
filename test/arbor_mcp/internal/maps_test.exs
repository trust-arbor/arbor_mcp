defmodule Arbor.MCP.Internal.MapsTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Internal.Maps

  test "puts present values" do
    assert %{}
           |> Maps.put_present("nil", nil)
           |> Maps.put_present("false", false) == %{"false" => false}
  end

  test "puts non-empty values" do
    assert %{}
           |> Maps.put_non_empty("nil", nil)
           |> Maps.put_non_empty("empty_string", "")
           |> Maps.put_non_empty("empty_list", [])
           |> Maps.put_non_empty("empty_map", %{})
           |> Maps.put_non_empty("false", false)
           |> Maps.put_non_empty("zero", 0) == %{"false" => false, "zero" => 0}
  end

  test "puts values except nil and empty lists" do
    assert %{}
           |> Maps.put_present_non_empty_list("nil", nil)
           |> Maps.put_present_non_empty_list("empty_list", [])
           |> Maps.put_present_non_empty_list("empty_string", "")
           |> Maps.put_present_non_empty_list("empty_map", %{}) == %{
             "empty_string" => "",
             "empty_map" => %{}
           }
  end

  test "puts truthy values" do
    assert %{}
           |> Maps.put_truthy("nil", nil)
           |> Maps.put_truthy("false", false)
           |> Maps.put_truthy("empty", "")
           |> Maps.put_truthy("zero", 0) == %{"empty" => "", "zero" => 0}
  end

  test "puts values unless they match the skip value" do
    assert %{}
           |> Maps.put_unless("arguments", %{}, %{})
           |> Maps.put_unless("metadata", %{"source" => "test"}, %{}) == %{
             "metadata" => %{"source" => "test"}
           }
  end
end
