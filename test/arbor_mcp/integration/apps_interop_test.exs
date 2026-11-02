defmodule Arbor.MCP.AppsInteropTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.AppsFixture

  @moduletag :interop
  @moduletag :interop_apps
  setup_all do
    root = Path.expand("../../..", __DIR__)

    {output, status} =
      System.cmd("npm", ["ci", "--ignore-scripts", "--no-audit", "--no-fund"],
        cd: Path.join(root, "examples/mcp_apps"),
        stderr_to_stdout: true
      )

    assert status == 0, output

    {output, status} =
      System.cmd("npm", ["run", "build"],
        cd: Path.join(root, "examples/mcp_apps"),
        stderr_to_stdout: true
      )

    assert status == 0, output
    {:ok, view_path: Path.join(root, "examples/mcp_apps/dist/view.html")}
  end

  @tag assurance: ["apps.sdk.stdio"]
  test "the documented stdio launcher serves the compiled View to the official SDK" do
    node = System.find_executable("node") || raise "Node.js 24+ is required"
    mix = System.find_executable("mix") || raise "Mix is required"
    script = Path.expand("../../interop/apps_peer.mjs", __DIR__)
    {output, status} = System.cmd(node, [script, "--stdio", mix], stderr_to_stdout: true)
    assert status == 0, output
    result = Jason.decode!(String.trim(output))
    assert result["toolCount"] == 3
    assert result["tornDown"]
  end

  @tag assurance: ["apps.sdk.interop"]
  test "official Apps SDK validates Elixir declarations and exchanges View/Host tool messages", %{
    view_path: path
  } do
    fixture = AppsFixture.start(view_path: path)
    node = System.find_executable("node") || raise "Node.js 24+ is required"
    script = Path.expand("../../interop/apps_peer.mjs", __DIR__)
    {output, status} = System.cmd(node, [script, fixture.endpoint], stderr_to_stdout: true)
    assert status == 0, output
    result = Jason.decode!(String.trim(output))
    assert result["uri"] == "ui://arbor/plan.html"
    assert result["toolCount"] == 3
    assert result["totalCents"] == 25600
    assert result["forwarded"] == ["update_plan"]
    assert result["metadata"] == "Local estimate"
    assert result["tornDown"] == true
  end
end
