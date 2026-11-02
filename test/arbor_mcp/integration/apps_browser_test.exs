defmodule Arbor.MCP.AppsBrowserTest do
  use ExUnit.Case, async: false
  alias Arbor.MCP.AppsFixture

  @moduletag :interop
  @moduletag :apps_browser
  @tag timeout: 180_000
  @tag assurance: ["apps.browser.example"]
  test "shipped View runs through the official bridge and cross-origin sandbox in Chromium" do
    root = Path.expand("../../..", __DIR__)

    {built, status} =
      System.cmd("npm", ["run", "build"],
        cd: Path.join(root, "examples/mcp_apps"),
        stderr_to_stdout: true
      )

    assert status == 0, built
    html = File.read!(Path.join(root, "examples/mcp_apps/dist/view.html"))
    File.mkdir_p!(Path.join(root, "tmp/mcp-apps"))

    File.write!(
      Path.join(root, "tmp/mcp-apps/view-build.json"),
      Jason.encode!(%{
        html_sha256: Base.encode16(:crypto.hash(:sha256, html), case: :lower),
        bytes: byte_size(html)
      })
    )

    fixture = AppsFixture.start(view_path: Path.join(root, "examples/mcp_apps/dist/view.html"))
    other = AppsFixture.start(view_path: Path.join(root, "examples/mcp_apps/dist/view.html"))
    refute other.endpoint == fixture.endpoint
    node = System.find_executable("node") || raise "Node.js is required"

    python =
      System.get_env("MCP_APPS_PYTHON") ||
        raise "Set MCP_APPS_PYTHON to the pinned Playwright environment"

    port =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        {:line, 65536},
        args: [
          Path.join(root, "test/interop/apps_browser_host.mjs"),
          fixture.endpoint,
          other.endpoint
        ]
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    origin =
      receive do
        {^port, {:data, {:eol, line}}} -> Jason.decode!(line)["origin"]
        {^port, {:exit_status, status}} -> flunk("Browser host exited during startup: #{status}")
      after
        20_000 -> flunk("Browser host did not become ready")
      end

    try do
      output_dir = Path.join(root, "tmp/mcp-apps/screenshots")

      {output, status} =
        System.cmd(python, [Path.join(root, "test/interop/apps_browser.py"), origin, output_dir],
          stderr_to_stdout: true
        )

      assert status == 0, output
      result = Jason.decode!(String.trim(output))
      assert result["updated"] == "$256"

      assert result["isolated"] and result["csp_blocked"] and result["visibility_checked"] and
               result["teardown"]

      assert result["screenshots"] == 3
    after
      if Port.info(port) do
        Port.command(port, "close\n")

        receive do
          {^port, {:exit_status, 0}} -> :ok
          {^port, {:exit_status, status}} -> flunk("Browser host cleanup failed: #{status}")
        after
          5_000 -> flunk("Browser host did not close")
        end
      end
    end
  end
end
