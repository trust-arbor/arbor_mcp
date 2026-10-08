defmodule Arbor.MCP.Server.DSLCompileErrorTest do
  use ExUnit.Case, async: true

  defp compile!(code) do
    Code.compile_string(code)
  end

  defp assert_compile_error!(code, message_parts) when is_list(message_parts) do
    error =
      assert_raise CompileError, fn ->
        compile!(code)
      end

    message = Exception.message(error)

    for part <- message_parts do
      assert message =~ part, """
      Expected compile error to include #{inspect(part)}.

      Full message:
      #{message}
      """
    end

    assert is_integer(error.line) or is_nil(error.line)
    error
  end

  test "unknown instruction includes suggestion for camelCase mistakes" do
    code = """
    defmodule DSLErrUnknown#{System.unique_integer([:positive])} do
      use Arbor.MCP.Server.Handler
      use Arbor.MCP.Server.DSL

      tool "echo" do
        inputSchema %{type: "object"}
        run fn _args, state -> {:ok, "ok", state} end
      end
    end
    """

    assert_compile_error!(code, [
      "Unknown Arbor.MCP.Server.DSL instruction: inputSchema",
      "Did you mean `input_schema`?"
    ])
  end

  test "missing run handler names the tool and suggests an example" do
    code = """
    defmodule DSLErrMissingRun#{System.unique_integer([:positive])} do
      use Arbor.MCP.Server.Handler
      use Arbor.MCP.Server.DSL

      tool "echo" do
        param :message, :string
      end
    end
    """

    assert_compile_error!(code, [
      "tool \"echo\" must define",
      "`run`",
      "run fn args, state ->"
    ])
  end

  test "bare :array param type is rejected with a fix suggestion" do
    code = """
    defmodule DSLErrBareArray#{System.unique_integer([:positive])} do
      use Arbor.MCP.Server.Handler
      use Arbor.MCP.Server.DSL

      tool "analyze" do
        param :data, :array, required: true
        run fn _args, state -> {:ok, "ok", state} end
      end
    end
    """

    assert_compile_error!(code, [
      "Invalid param type :array",
      "{:array, item_type}",
      "{:array, :string}"
    ])
  end

  test "unknown param type atoms are rejected" do
    code = """
    defmodule DSLErrBadType#{System.unique_integer([:positive])} do
      use Arbor.MCP.Server.Handler
      use Arbor.MCP.Server.DSL

      tool "echo" do
        param :id, :uuid
        run fn _args, state -> {:ok, "ok", state} end
      end
    end
    """

    assert_compile_error!(code, [
      "Invalid param type :uuid",
      ":string, :integer, :number, :boolean"
    ])
  end

  test "duplicate tool names are rejected" do
    code = """
    defmodule DSLErrDupTool#{System.unique_integer([:positive])} do
      use Arbor.MCP.Server.Handler
      use Arbor.MCP.Server.DSL

      tool "echo" do
        run fn _args, state -> {:ok, "a", state} end
      end

      tool "echo" do
        run fn _args, state -> {:ok, "b", state} end
      end
    end
    """

    assert_compile_error!(code, [
      "Duplicate tool \"echo\"",
      "2 times"
    ])
  end

  test "arg is not allowed inside tool declarations" do
    code = """
    defmodule DSLErrArgInTool#{System.unique_integer([:positive])} do
      use Arbor.MCP.Server.Handler
      use Arbor.MCP.Server.DSL

      tool "echo" do
        arg :message, required: true
        run fn _args, state -> {:ok, "ok", state} end
      end
    end
    """

    assert_compile_error!(code, [
      "`arg` is not valid inside tool",
      "Use `arg` in prompt declarations"
    ])
  end

  test "non-literal param types are rejected" do
    code = """
    defmodule DSLErrNonLiteral#{System.unique_integer([:positive])} do
      use Arbor.MCP.Server.Handler
      use Arbor.MCP.Server.DSL

      tool "echo" do
        param :value, SomeModule.type()
        run fn _args, state -> {:ok, "ok", state} end
      end
    end
    """

    assert_compile_error!(code, [
      "Expected a compile-time literal for param type",
      "SomeModule.type()"
    ])
  end

  test "resource without read handler fails with example" do
    code = """
    defmodule DSLErrMissingRead#{System.unique_integer([:positive])} do
      use Arbor.MCP.Server.Handler
      use Arbor.MCP.Server.DSL

      resource "config://app" do
        mime_type "application/json"
      end
    end
    """

    assert_compile_error!(code, [
      "resource \"config://app\" must define",
      "`read`",
      "read fn params, state ->"
    ])
  end
end
