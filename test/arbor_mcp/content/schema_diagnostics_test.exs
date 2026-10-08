defmodule Arbor.MCP.Content.SchemaDiagnosticsTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Content.SchemaPolicy

  test "composition errors retain valid-branch annotations without opening backend errors" do
    assert {:ok, compiled} =
             SchemaPolicy.compile(%{"oneOf" => [%{"type" => "number"}, %{"minimum" => 0}]})

    assert {:error, [{message, "#"}]} = SchemaPolicy.validate(1, compiled)
    assert message =~ "oneOf"
  end

  test "reports missing property names and escaped nested instance paths" do
    schema = %{
      "properties" => %{
        "a/b~c" => %{"type" => "object", "required" => ["name"]}
      }
    }

    assert {:ok, compiled} = SchemaPolicy.compile(schema)
    assert {:error, errors} = SchemaPolicy.validate(%{"a/b~c" => %{}}, compiled)
    assert Enum.any?(errors, fn {message, path} -> message =~ "name" and path == "#/a~1b~0c" end)
  end

  test "does not expose rejected values or enum and constant members" do
    schema = %{
      "properties" => %{
        "numeric" => %{"maximum" => 0},
        "enum" => %{"enum" => ["private-schema-enum"]},
        "constant" => %{"const" => "private-schema-constant"}
      }
    }

    assert {:ok, compiled} = SchemaPolicy.compile(schema)

    assert {:error, errors} =
             SchemaPolicy.validate(
               %{
                 "numeric" => 987_654_321,
                 "enum" => "private-input",
                 "constant" => "private-input"
               },
               compiled
             )

    assert errors != []

    for {message, _path} <- errors do
      refute message =~ "private"
      refute message =~ "987654321"
    end
  end

  test "bounds diagnostic count and text even for long property names" do
    long_name = String.duplicate("x", 300)

    properties =
      for index <- 1..40, into: %{} do
        {Integer.to_string(index), %{"type" => "string"}}
      end

    schema = %{"properties" => Map.put(properties, long_name, %{"required" => [long_name]})}
    data = Map.new(properties, fn {key, _schema} -> {key, 1} end) |> Map.put(long_name, %{})

    assert {:ok, compiled} = SchemaPolicy.compile(schema)
    assert {:error, errors} = SchemaPolicy.validate(data, compiled)
    assert length(errors) == 16

    assert Enum.all?(errors, fn {message, path} ->
             byte_size(message) <= 256 and byte_size(path) <= 256
           end)

    assert {:ok, long_compiled} =
             SchemaPolicy.compile(%{"properties" => %{long_name => %{"required" => [long_name]}}})

    assert {:error, [{"required properties are missing", "#"}]} =
             SchemaPolicy.validate(%{long_name => %{}}, long_compiled)
  end
end
