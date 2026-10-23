defmodule Arbor.MCP.Internal.ServerManagerTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Internal.{Discovery, ServerManager}

  @moduletag :unit

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "arbor-mcp-discovery-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    marker = Path.join(tmp, "launched")
    script = Path.join(tmp, "launch-me")

    File.write!(script, """
    #!/bin/sh
    echo launched >> "#{marker}"
    exit 0
    """)

    File.chmod!(script, 0o755)

    original_cwd = File.cwd!()
    File.cd!(tmp)

    File.write!(
      "mcp.json",
      Jason.encode!(%{"servers" => [%{"name" => "workspace-mcp", "command" => script}]})
    )

    on_exit(fn ->
      File.cd!(original_cwd)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, marker: marker, script: script}
  end

  test "does not launch servers discovered from a workspace mcp.json", %{marker: marker} do
    {:ok, manager} =
      start_supervised(
        {ServerManager, name: :"server-manager-#{System.unique_integer([:positive])}"}
      )

    refute function_exported?(ServerManager, :discover_and_start, 0)
    refute function_exported?(ServerManager, :discover_and_start, 1)

    assert ServerManager.list_servers(manager) == []
    refute File.exists?(marker)
  end

  test "test_server does not execute a discovered command", %{marker: marker, script: script} do
    refute Discovery.test_server(%{command: [script]})
    refute Discovery.test_server(%{command: script})
    refute File.exists?(marker)
  end
end
