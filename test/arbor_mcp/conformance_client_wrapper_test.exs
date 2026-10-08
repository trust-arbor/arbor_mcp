defmodule Arbor.MCP.Conformance.ClientWrapperTest do
  use ExUnit.Case, async: false

  test "the executable conformance client compiles" do
    Process.put(:ex_mcp_conformance_compile_only, true)

    modules = Code.compile_file("test/conformance/client.exs")

    assert {ConformanceClient, _bytecode} =
             Enum.find(modules, fn {module, _bytecode} -> module == ConformanceClient end)
  end
end
