defmodule Arbor.MCP.Integration.PythonLegacyStdioInteropTest do
  @moduledoc """
  Python `mcp` 1.6 and 1.8 stdio servers exit when the `server/discover` probe
  arrives before `initialize` (1.10 and later answer -32602). A
  `:prefer_modern` client must still reach one, by initializing a fresh
  process. Needs `uv`; run with `mix test --include interop`.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Client

  @moduletag :interop
  @moduletag :interop_python

  @server Path.expand("../../interop/python/legacy_fastmcp_server.py", __DIR__)

  setup do
    Process.flag(:trap_exit, true)
    uv = System.find_executable("uv") || flunk("uv is required for the Python interop tests")
    {:ok, uv: uv}
  end

  for mode <- [:modern_only, :prefer_modern, :prefer_legacy, :legacy_only] do
    test "a #{mode} client and a Python mcp 1.8.1 FastMCP server", %{uv: uv} do
      result =
        Client.start_link(
          transport: :stdio,
          command: [
            uv,
            "run",
            "--no-project",
            "--with",
            "mcp==1.8.1",
            "--with",
            "pydantic<2.11",
            "python",
            "-I",
            @server
          ],
          protocol_mode: unquote(mode),
          health_check_interval: nil,
          reconnect: false
        )

      if unquote(mode) == :modern_only do
        # The server exits on the probe and modern_only never falls back.
        assert {:error, {:transport_connect_failed, reason}} = result
        assert reason =~ "{:era_probe_failed, {:transport_error, "
      else
        assert {:ok, client} = result, inspect(result)
        on_exit(fn -> stop(client) end)
        assert {:ok, version} = Client.negotiated_version(client)
        assert version in ["2025-03-26", "2024-11-05"]
        assert {:ok, %{"name" => "python-legacy-server"}} = Client.server_info(client)

        assert {:ok, %{"content" => [%{"text" => "hi"}]}} =
                 Client.call_tool(client, "echo", %{"text" => "hi"},
                   format: :map,
                   timeout: 10_000
                 )
      end
    end
  end

  defp stop(client) do
    Client.stop(client)
  catch
    :exit, _reason -> :ok
  end
end
