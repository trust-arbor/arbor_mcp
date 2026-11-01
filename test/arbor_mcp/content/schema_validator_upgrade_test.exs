defmodule Arbor.MCP.Content.SchemaValidatorUpgradeTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Content.SchemaPolicy

  test "modern string length counts code points and preserves the public result shape" do
    decomposed = "e\u0301"
    assert :ok = SchemaPolicy.validate(decomposed, %{type: "string", minLength: 2})

    assert {:error, [{_message, "#"}]} =
             SchemaPolicy.validate(decomposed, %{type: "string", maxLength: 1})

    assert :ok = SchemaPolicy.validate("é", %{type: "string", maxLength: 1})
  end

  test "regex budget errors remain invalid through negation and successful alternatives" do
    value = String.duplicate("a", 40) <> "!"
    pattern = %{"pattern" => "^(a|aa)+$"}

    for schema <- [%{"not" => pattern}, %{"anyOf" => [pattern, true]}] do
      assert {:ok, compiled} = SchemaPolicy.compile(schema)
      assert :ok = SchemaPolicy.validate("ordinary", compiled)
      assert {:error, errors} = SchemaPolicy.validate(value, compiled)
      assert Enum.any?(errors, fn {message, _path} -> message =~ "indeterminate_pattern" end)
      refute inspect(errors) =~ value
    end
  end

  test "patternProperties budget errors retain bounded scrubbed diagnostics" do
    key = String.duplicate("a", 40) <> "!"
    schema = %{patternProperties: %{"^(a|aa)+$" => false}, additionalProperties: true}
    assert {:ok, compiled} = SchemaPolicy.compile(schema)
    assert :ok = SchemaPolicy.validate(%{"ordinary" => "ok"}, compiled)
    assert {:error, errors} = SchemaPolicy.validate(%{key => "private-input-value"}, compiled)
    assert Enum.any?(errors, fn {message, _path} -> message =~ "indeterminate_pattern" end)

    assert Enum.all?(errors, fn {message, path} ->
             byte_size(message) <= 256 and byte_size(path) <= 256
           end)

    refute inspect(errors) =~ "private-input-value"
  end
end
