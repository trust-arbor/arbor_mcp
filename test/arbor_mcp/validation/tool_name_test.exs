defmodule Arbor.MCP.Validation.ToolNameTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Validation.ToolName

  # ---------- validate/1 ----------

  describe "validate/1 with valid names" do
    test "accepts a simple alphabetic name" do
      assert {:ok, "mytool"} = ToolName.validate("mytool")
    end

    test "accepts a name with uppercase letters" do
      assert {:ok, "MyTool"} = ToolName.validate("MyTool")
    end

    test "accepts a name with digits" do
      assert {:ok, "tool123"} = ToolName.validate("tool123")
    end

    test "accepts a name with underscores" do
      assert {:ok, "my_tool"} = ToolName.validate("my_tool")
    end

    test "accepts a name with dots" do
      assert {:ok, "my.tool"} = ToolName.validate("my.tool")
    end

    test "accepts a name with hyphens" do
      assert {:ok, "my-tool"} = ToolName.validate("my-tool")
    end

    test "accepts a name combining all allowed characters" do
      assert {:ok, "My_Tool-v1.2"} = ToolName.validate("My_Tool-v1.2")
    end

    test "accepts a single character name" do
      assert {:ok, "a"} = ToolName.validate("a")
    end

    test "accepts a single digit name" do
      assert {:ok, "9"} = ToolName.validate("9")
    end

    test "accepts a single underscore" do
      assert {:ok, "_"} = ToolName.validate("_")
    end

    test "accepts a single dot" do
      assert {:ok, "."} = ToolName.validate(".")
    end

    test "accepts a single hyphen" do
      assert {:ok, "-"} = ToolName.validate("-")
    end

    test "accepts a name starting with a digit" do
      assert {:ok, "123tool"} = ToolName.validate("123tool")
    end

    test "accepts a name starting with an underscore" do
      assert {:ok, "_private"} = ToolName.validate("_private")
    end

    test "accepts a name starting with a dot" do
      assert {:ok, ".hidden"} = ToolName.validate(".hidden")
    end

    test "accepts a name starting with a hyphen" do
      assert {:ok, "-flag"} = ToolName.validate("-flag")
    end

    test "accepts a name that is all digits" do
      assert {:ok, "12345"} = ToolName.validate("12345")
    end

    test "accepts a name that is all underscores" do
      assert {:ok, "___"} = ToolName.validate("___")
    end

    test "accepts a dotted namespace-style name" do
      assert {:ok, "com.example.tool"} = ToolName.validate("com.example.tool")
    end

    test "accepts a kebab-case name" do
      assert {:ok, "my-cool-tool"} = ToolName.validate("my-cool-tool")
    end

    test "accepts a snake_case name" do
      assert {:ok, "my_cool_tool"} = ToolName.validate("my_cool_tool")
    end
  end

  describe "validate/1 boundary: maximum length" do
    test "accepts a name of exactly 128 characters" do
      name = String.duplicate("a", 128)
      assert {:ok, ^name} = ToolName.validate(name)
    end

    test "rejects a name of 129 characters" do
      name = String.duplicate("a", 129)
      assert {:error, message} = ToolName.validate(name)
      assert message =~ "between 1 and 128 characters"
    end

    test "rejects a name well over the limit" do
      name = String.duplicate("x", 256)
      assert {:error, message} = ToolName.validate(name)
      assert message =~ "between 1 and 128 characters"
    end

    test "accepts a 127-character name" do
      name = String.duplicate("b", 127)
      assert {:ok, ^name} = ToolName.validate(name)
    end
  end

  describe "validate/1 with empty and blank inputs" do
    test "rejects an empty string" do
      assert {:error, message} = ToolName.validate("")
      assert message =~ "between 1 and 128 characters"
    end
  end

  describe "validate/1 with invalid characters" do
    test "rejects a name with spaces" do
      assert {:error, message} = ToolName.validate("my tool")
      assert message =~ "invalid characters"
    end

    test "rejects a name with a leading space" do
      assert {:error, message} = ToolName.validate(" tool")
      assert message =~ "invalid characters"
    end

    test "rejects a name with a trailing space" do
      assert {:error, message} = ToolName.validate("tool ")
      assert message =~ "invalid characters"
    end

    test "rejects a name with a forward slash" do
      assert {:error, message} = ToolName.validate("path/tool")
      assert message =~ "invalid characters"
    end

    test "rejects a name with a backslash" do
      assert {:error, message} = ToolName.validate("path\\tool")
      assert message =~ "invalid characters"
    end

    test "rejects a name with an at sign" do
      assert {:error, message} = ToolName.validate("user@tool")
      assert message =~ "invalid characters"
    end

    test "rejects a name with a hash" do
      assert {:error, message} = ToolName.validate("tool#1")
      assert message =~ "invalid characters"
    end

    test "rejects a name with a colon" do
      assert {:error, message} = ToolName.validate("ns:tool")
      assert message =~ "invalid characters"
    end

    test "rejects a name with a plus sign" do
      assert {:error, message} = ToolName.validate("tool+extra")
      assert message =~ "invalid characters"
    end

    test "rejects a name with an exclamation mark" do
      assert {:error, message} = ToolName.validate("tool!")
      assert message =~ "invalid characters"
    end

    test "rejects a name with parentheses" do
      assert {:error, message} = ToolName.validate("tool(1)")
      assert message =~ "invalid characters"
    end

    test "rejects a name with brackets" do
      assert {:error, message} = ToolName.validate("tool[0]")
      assert message =~ "invalid characters"
    end

    test "rejects a name with curly braces" do
      assert {:error, message} = ToolName.validate("tool{x}")
      assert message =~ "invalid characters"
    end

    test "rejects a name with a newline" do
      assert {:error, message} = ToolName.validate("tool\nname")
      assert message =~ "invalid characters"
    end

    test "rejects a name with a tab" do
      assert {:error, message} = ToolName.validate("tool\tname")
      assert message =~ "invalid characters"
    end

    test "rejects a name with unicode letters" do
      assert {:error, message} = ToolName.validate("caf\u00E9")
      assert message =~ "invalid characters"
    end

    test "rejects a name with emoji" do
      assert {:error, message} = ToolName.validate("tool\u{1F680}")
      assert message =~ "invalid characters"
    end

    test "rejects a name with a null byte" do
      assert {:error, message} = ToolName.validate("tool\0name")
      assert message =~ "invalid characters"
    end

    test "rejects a name with an equals sign" do
      assert {:error, message} = ToolName.validate("key=value")
      assert message =~ "invalid characters"
    end

    test "rejects a name with an ampersand" do
      assert {:error, message} = ToolName.validate("a&b")
      assert message =~ "invalid characters"
    end

    test "rejects a name with a pipe" do
      assert {:error, message} = ToolName.validate("a|b")
      assert message =~ "invalid characters"
    end

    test "rejects a name consisting only of spaces" do
      assert {:error, message} = ToolName.validate("   ")
      assert message =~ "invalid characters"
    end
  end

  describe "validate/1 with non-string inputs" do
    test "rejects an atom" do
      assert {:error, "Tool name must be a string"} = ToolName.validate(:my_tool)
    end

    test "rejects nil" do
      assert {:error, "Tool name must be a string"} = ToolName.validate(nil)
    end

    test "rejects an integer" do
      assert {:error, "Tool name must be a string"} = ToolName.validate(42)
    end

    test "rejects a float" do
      assert {:error, "Tool name must be a string"} = ToolName.validate(3.14)
    end

    test "rejects a list" do
      assert {:error, "Tool name must be a string"} = ToolName.validate(["tool"])
    end

    test "rejects a map" do
      assert {:error, "Tool name must be a string"} = ToolName.validate(%{name: "tool"})
    end

    test "rejects a tuple" do
      assert {:error, "Tool name must be a string"} = ToolName.validate({:tool})
    end

    test "rejects a boolean" do
      assert {:error, "Tool name must be a string"} = ToolName.validate(true)
    end

    test "rejects a charlist" do
      assert {:error, "Tool name must be a string"} = ToolName.validate(~c"tool")
    end
  end

  describe "validate/1 with multi-byte unicode near boundary" do
    test "rejects a name where byte_size exceeds 128 but String.length does not" do
      # Each multi-byte character takes more than 1 byte
      # e.g. a 2-byte character repeated 65 times = 130 bytes but 65 chars
      name = String.duplicate("\u00E9", 65)
      # byte_size will be 130, which exceeds 128
      assert byte_size(name) > 128
      assert {:error, message} = ToolName.validate(name)
      # Could be either length error or invalid chars - the point is it's rejected
      assert is_binary(message)
    end
  end

  # ---------- valid?/1 ----------

  describe "valid?/1 with valid names" do
    test "returns true for a simple name" do
      assert ToolName.valid?("mytool")
    end

    test "returns true for a name with all allowed character types" do
      assert ToolName.valid?("My_Tool-v1.2")
    end

    test "returns true for a single character" do
      assert ToolName.valid?("x")
    end

    test "returns true for exactly 128 characters" do
      assert ToolName.valid?(String.duplicate("z", 128))
    end
  end

  describe "valid?/1 with invalid names" do
    test "returns false for an empty string" do
      refute ToolName.valid?("")
    end

    test "returns false for a name with spaces" do
      refute ToolName.valid?("my tool")
    end

    test "returns false for a name that is too long" do
      refute ToolName.valid?(String.duplicate("a", 129))
    end

    test "returns false for a name with a slash" do
      refute ToolName.valid?("a/b")
    end

    test "returns false for a name with unicode" do
      refute ToolName.valid?("caf\u00E9")
    end
  end

  describe "valid?/1 with non-string inputs" do
    test "returns false for nil" do
      refute ToolName.valid?(nil)
    end

    test "returns false for an atom" do
      refute ToolName.valid?(:tool)
    end

    test "returns false for an integer" do
      refute ToolName.valid?(42)
    end

    test "returns false for a list" do
      refute ToolName.valid?(["tool"])
    end

    test "returns false for a map" do
      refute ToolName.valid?(%{})
    end

    test "returns false for a boolean" do
      refute ToolName.valid?(false)
    end
  end

  describe "valid?/1 mirrors validate/1" do
    test "valid? returns true when validate returns {:ok, _}" do
      names = [
        "tool",
        "my_tool",
        "my-tool",
        "my.tool",
        "Tool123",
        "_",
        ".",
        "-",
        "a",
        String.duplicate("x", 128)
      ]

      for name <- names do
        assert {:ok, _} = ToolName.validate(name),
               "validate/1 should accept #{inspect(name)}"

        assert ToolName.valid?(name),
               "valid?/1 should return true for #{inspect(name)}"
      end
    end

    test "valid? returns false when validate returns {:error, _}" do
      names = [
        "",
        "my tool",
        "tool/name",
        "tool@home",
        String.duplicate("a", 129),
        "caf\u00E9"
      ]

      for name <- names do
        assert {:error, _} = ToolName.validate(name),
               "validate/1 should reject #{inspect(name)}"

        refute ToolName.valid?(name),
               "valid?/1 should return false for #{inspect(name)}"
      end
    end

    test "valid? returns false for non-strings just as validate returns error" do
      inputs = [nil, :atom, 42, 3.14, [], %{}, true]

      for input <- inputs do
        assert {:error, "Tool name must be a string"} = ToolName.validate(input),
               "validate/1 should reject non-string #{inspect(input)}"

        refute ToolName.valid?(input),
               "valid?/1 should return false for non-string #{inspect(input)}"
      end
    end
  end

  # ---------- max_length/0 and pattern/0 ----------
  # Note: The module defines @max_length and @name_pattern as module attributes
  # but does not expose public max_length/0 or pattern/0 functions.
  # We verify the constants indirectly through the public API behavior.

  describe "max_length constant (verified through validate/1)" do
    test "128-character name is accepted" do
      assert {:ok, _} = ToolName.validate(String.duplicate("a", 128))
    end

    test "129-character name is rejected with message referencing 128" do
      assert {:error, message} = ToolName.validate(String.duplicate("a", 129))
      assert message =~ "128"
    end
  end

  describe "pattern constant (verified through validate/1)" do
    test "all individual allowed characters are accepted" do
      # lowercase a-z
      for c <- ?a..?z do
        assert {:ok, _} = ToolName.validate(<<c>>),
               "Expected #{<<c>>} to be valid"
      end

      # uppercase A-Z
      for c <- ?A..?Z do
        assert {:ok, _} = ToolName.validate(<<c>>),
               "Expected #{<<c>>} to be valid"
      end

      # digits 0-9
      for c <- ?0..?9 do
        assert {:ok, _} = ToolName.validate(<<c>>),
               "Expected #{<<c>>} to be valid"
      end

      # special allowed characters
      for c <- ["_", ".", "-"] do
        assert {:ok, _} = ToolName.validate(c),
               "Expected #{inspect(c)} to be valid"
      end
    end

    test "common disallowed ASCII characters are rejected" do
      disallowed = [
        " ",
        "!",
        "\"",
        "#",
        "$",
        "%",
        "&",
        "'",
        "(",
        ")",
        "*",
        "+",
        ",",
        "/",
        ":",
        ";",
        "<",
        "=",
        ">",
        "?",
        "@",
        "[",
        "\\",
        "]",
        "^",
        "`",
        "{",
        "|",
        "}",
        "~"
      ]

      for c <- disallowed do
        assert {:error, _} = ToolName.validate(c),
               "Expected #{inspect(c)} to be invalid"
      end
    end
  end
end
