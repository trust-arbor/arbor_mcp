defmodule Arbor.MCP.AppsPhoenixHostTest do
  use ExUnit.Case, async: false
  alias Arbor.MCP.AppsFixture

  @moduletag :interop
  @moduletag :apps_phoenix
  @tag timeout: 240_000
  @tag assurance: ["apps.browser.phoenix_host"]
  test "the shipped Phoenix host renders and forwards Apps with per-browser client ownership" do
    root = Path.expand("../../..", __DIR__)
    host = Path.join(root, "examples/mcp_apps/phoenix_host")
    example = Path.join(root, "examples/mcp_apps")
    run!("npm", ["ci", "--ignore-scripts", "--no-audit", "--no-fund"], cd: example)
    run!("npm", ["run", "build"], cd: example)
    run!("mix", ["deps.get"], cd: host, env: [{"MIX_ENV", "dev"}])
    run!("mix", ["compile", "--warnings-as-errors"], cd: host, env: [{"MIX_ENV", "dev"}])
    run!("mix", ["format", "--check-formatted"], cd: host, env: [{"MIX_ENV", "dev"}])
    run!("mix", ["test", "--no-start"], cd: host, env: [{"MIX_ENV", "test"}])
    run!("node", [Path.join(host, "build.mjs")], cd: root)
    fixture = AppsFixture.start(view_path: Path.join(example, "dist/view.html"))

    python =
      System.get_env("MCP_APPS_PYTHON") || raise "Pinned Playwright environment is required"

    mix = System.find_executable("mix") || raise "Mix is required"

    build =
      for name <- ["host.js", "sandbox.js", "host.css"], into: %{} do
        data = File.read!(Path.join(host, "priv/static/assets/#{name}"))
        {name, Base.encode16(:crypto.hash(:sha256, data), case: :lower)}
      end

    File.mkdir_p!(Path.join(root, "tmp/mcp-apps"))
    File.write!(Path.join(root, "tmp/mcp-apps/phoenix-host-build.json"), Jason.encode!(build))

    port =
      Port.open({:spawn_executable, mix}, [
        :binary,
        :exit_status,
        {:line, 65536},
        {:cd, String.to_charlist(host)},
        args: ["run", "--no-compile", "--no-halt", "test/browser_driver.exs"],
        env: [
          {~c"MIX_ENV", ~c"dev"},
          {~c"MCP_APPS_HOST_PORT", ~c"0"},
          {~c"MCP_APPS_SANDBOX_PORT", ~c"0"},
          {~c"MCP_APPS_SERVER_URL", String.to_charlist(fixture.endpoint)}
        ]
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    try do
      ready = json_line(port, 20_000)
      refute ready["origin"] == ready["sandboxOrigin"]

      {output, status} =
        System.cmd(
          python,
          [
            Path.join(root, "test/interop/apps_phoenix_browser.py"),
            ready["origin"],
            ready["sandboxOrigin"],
            Path.join(root, "tmp/mcp-apps/phoenix"),
            Jason.encode!(build)
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output
      proof = Jason.decode!(String.trim(output))
      assert proof["phoenix"] and proof["csp"] and proof["visibility"] and proof["reopened"]
      assert proof["tabs"] == 2 and proof["screenshots"] == 4 and proof["reconnected"]
      Port.command(port, "await_closed\n")
      assert %{"closed" => true, "observed" => 3} = json_line(port, 10_000)
    after
      if Port.info(port) do
        Port.command(port, "close\n")

        receive do
          {^port, {:exit_status, 0}} -> :ok
          {^port, {:exit_status, status}} -> flunk("Phoenix host exited with #{status}")
        after
          10_000 -> flunk("Phoenix host did not stop")
        end
      end
    end
  end

  defp run!(command, args, opts) do
    {output, status} = System.cmd(command, args, Keyword.put(opts, :stderr_to_stdout, true))
    assert status == 0, output
  end

  defp json_line(port, timeout) do
    receive do
      {^port, {:data, {:eol, line}}} -> Jason.decode!(line)
      {^port, {:exit_status, status}} -> flunk("Phoenix host stopped: #{status}")
    after
      timeout -> flunk("Phoenix host did not return its lifecycle receipt")
    end
  end
end
