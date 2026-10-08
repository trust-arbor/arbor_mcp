defmodule Arbor.MCP.Server.DSLBoundaryTest do
  use ExUnit.Case, async: true

  defp reject(body, expected, options \\ "") do
    source = """
    defmodule DSLBoundary#{System.unique_integer([:positive])} do
      use Arbor.MCP.Server.Handler
      use Arbor.MCP.Server.DSL#{options}
      #{body}
    end
    """

    error = assert_raise CompileError, fn -> Code.compile_string(source, "dsl_boundary.ex") end
    assert error.description =~ expected
    assert error.file == "dsl_boundary.ex"
    assert is_integer(error.line) and error.line > 0
    error
  end

  test "duplicate parameters fail at the second declaration, before schema construction" do
    error =
      reject(
        """
        tool "echo" do
          param :value, :string
          param :value, :integer
          run fn _args, state -> {:ok, "ok", state} end
        end
        """,
        "Duplicate param name :value"
      )

    assert error.line == 6
  end

  test "prompt arguments and resource-template parameters must be unique" do
    reject(
      """
      prompt "echo" do
        arg :value
        arg :value, required: true
        render fn _args, state -> {:ok, %{messages: []}, state} end
      end
      """,
      "Duplicate arg name :value"
    )

    reject(
      """
      resource_template "file:///{path}" do
        param :path, :string
        param :path, :string
        read fn _args, state -> {:ok, "ok", state} end
      end
      """,
      "Duplicate param name :path"
    )
  end

  test "scalar metadata cannot silently override an earlier instruction" do
    for {instruction, first, second} <- [
          {"title", ~s("first"), ~s("second")},
          {"input_schema", ~s(%{type: "object"}), ~s(%{type: "object", properties: %{}})},
          {"annotations", "[]", "[readOnlyHint: true]"}
        ] do
      reject(
        """
        tool "echo" do
          #{instruction} #{first}
          #{instruction} #{second}
          run fn _args, state -> {:ok, "ok", state} end
        end
        """,
        "Repeated `#{instruction}`"
      )
    end
  end

  test "all nested instructions reject use outside a primitive" do
    for instruction <- [
          "param :value, :string",
          "arg :value",
          "run fn _, state -> {:ok, state} end",
          "handle fn _, state -> {:ok, state} end",
          "read fn _, state -> {:ok, state} end",
          "render fn _, state -> {:ok, state} end",
          "title \"stray\"",
          "name \"stray\"",
          "description \"stray\"",
          "annotations []",
          "icons []",
          "meta %{}",
          "execution %{}",
          "input_schema %{}",
          "output_schema %{}",
          "mime_type \"text/plain\"",
          "size 1"
        ] do
      reject(instruction, "must appear inside")
    end
  end

  test "unknown, duplicate and malformed use options fail at the use line" do
    assert reject("", "Unknown Arbor.MCP.Server.DSL option :versoin", ", versoin: \"typo\"").line ==
             3

    reject("", "Repeated Arbor.MCP.Server.DSL option :name", ", name: \"a\", name: \"b\"")
    reject("", "options must be a keyword list", ", :invalid")
  end

  test "contextually ignored metadata is rejected" do
    for {kind, handler} <- [{"tool", "run"}, {"prompt", "render"}] do
      reject(
        """
        #{kind} "echo" do
          name "ignored"
          #{handler} fn _args, state -> {:ok, "ok", state} end
        end
        """,
        "`name` is not valid inside #{kind}"
      )
    end

    reject(
      """
      prompt "echo" do
        annotations []
        render fn _args, state -> {:ok, %{messages: []}, state} end
      end
      """,
      "`annotations` is not valid inside prompt"
    )
  end
end
