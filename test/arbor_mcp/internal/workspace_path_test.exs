defmodule Arbor.MCP.Internal.WorkspacePathTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Internal.WorkspacePath

  test "accepts a root and its descendants without accepting lexical siblings" do
    root = Path.join(System.tmp_dir!(), "ex_mcp_workspace")

    assert WorkspacePath.within?(root, root)
    assert WorkspacePath.within?(Path.join(root, "nested/file.txt"), root)
    refute WorkspacePath.within?(root <> "-other/file.txt", root)
    refute WorkspacePath.within?(Path.join(root, "../outside/file.txt"), root)
  end

  test "resolves existing symlinks while retaining nonexistent descendants" do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "ex_mcp_workspace_root_#{suffix}")
    outside = Path.join(System.tmp_dir!(), "ex_mcp_workspace_outside_#{suffix}")

    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(root, "escape"))

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(outside)
    end)

    assert WorkspacePath.within?(Path.join(root, "not-created/file.txt"), root)
    refute WorkspacePath.within?(Path.join(root, "escape/not-created.txt"), root)
  end
end
