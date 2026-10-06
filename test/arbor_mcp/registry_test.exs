defmodule Arbor.MCP.RegistryTest do
  use ExUnit.Case, async: false
  import Arbor.MCP.TestHelpers, only: [unique_process_name: 2]

  alias Arbor.MCP.Registry

  setup %{test: test} do
    registry_name = unique_process_name(test, "registry")
    registry = start_supervised!({Registry, name: registry_name})

    %{registry: registry}
  end

  describe "register/5 and lookup/3" do
    test "registers and looks up a tool", %{registry: registry} do
      metadata = %{description: "Test tool", input_schema: %{}}

      assert :ok = Registry.register(registry, :tool, "test_tool", TestModule, metadata)
      assert {:ok, capability} = Registry.lookup(registry, :tool, "test_tool")

      assert capability.name == "test_tool"
      assert capability.type == :tool
      assert capability.module == TestModule
      assert capability.metadata == metadata
    end

    test "returns error for non-existent capability", %{registry: registry} do
      assert {:error, :not_found} = Registry.lookup(registry, :tool, "nonexistent")
    end
  end

  describe "unregister/3" do
    test "unregisters a capability", %{registry: registry} do
      Registry.register(registry, :tool, "test_tool", TestModule)
      assert {:ok, _} = Registry.lookup(registry, :tool, "test_tool")

      assert :ok = Registry.unregister(registry, :tool, "test_tool")
      assert {:error, :not_found} = Registry.lookup(registry, :tool, "test_tool")
    end
  end

  describe "list/2" do
    test "lists capabilities by type", %{registry: registry} do
      Registry.register(registry, :tool, "tool1", TestModule1)
      Registry.register(registry, :tool, "tool2", TestModule2)
      Registry.register(registry, :resource, "resource1", TestModule3)

      tools = Registry.list(registry, :tool)
      resources = Registry.list(registry, :resource)

      assert length(tools) == 2
      assert length(resources) == 1

      tool_names = Enum.map(tools, & &1.name)
      assert "tool1" in tool_names
      assert "tool2" in tool_names

      assert hd(resources).name == "resource1"
    end
  end

  describe "list_all/1" do
    test "lists all capabilities", %{registry: registry} do
      Registry.register(registry, :tool, "tool1", TestModule1)
      Registry.register(registry, :resource, "resource1", TestModule2)
      Registry.register(registry, :prompt, "prompt1", TestModule3)

      all_capabilities = Registry.list_all(registry)

      assert length(all_capabilities) == 3

      types = Enum.map(all_capabilities, & &1.type)
      assert :tool in types
      assert :resource in types
      assert :prompt in types
    end
  end
end
