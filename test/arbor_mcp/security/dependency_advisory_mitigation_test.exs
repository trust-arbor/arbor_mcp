defmodule Arbor.MCP.Security.DependencyAdvisoryMitigationTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Plug.Test

  test "Mint requirement and lock exclude versions affected by September 2026 advisories" do
    mint_dep = List.keyfind(Mix.Project.config()[:deps], :mint, 0)
    requirement = elem(mint_dep, 1)

    assert Version.match?("1.10.2", requirement)
    refute Version.match?("1.10.1", requirement)

    locked_version = Mix.Dep.Lock.read()[:mint] |> elem(2)
    assert Version.compare(locked_version, "1.10.2") in [:eq, :gt]
  end

  test "Plug rejects response-header bytes covered by EEF-CVE-2026-43966" do
    conn = conn(:get, "/")

    for invalid <- ["safe\r\nx-injected: true", "safe\n", <<"safe", 0>>] do
      assert_raise Plug.Conn.InvalidHeaderError, fn ->
        Plug.Conn.put_resp_header(conn, "x-test", invalid)
      end
    end
  end

  test "Arbor.MCP modules do not import cow_cookie:cookie/1 from EEF-CVE-2026-43969" do
    refute {:cow_cookie, :cookie, 1} in application_imports([:arbor_mcp])
  end

  test "the Arbor.MCP server stack does not import cow_link:link/1 from EEF-CVE-2026-43971" do
    refute {:cow_link, :link, 1} in application_imports([
             :arbor_mcp,
             :plug,
             :plug_cowboy,
             :cowboy
           ])
  end

  defp application_imports(applications) do
    Enum.flat_map(applications, fn application ->
      {:ok, modules} = :application.get_key(application, :modules)

      Enum.flat_map(modules, fn module ->
        {:module, ^module} = Code.ensure_loaded(module)

        case :code.which(module) do
          path when is_list(path) ->
            case :beam_lib.chunks(path, [:imports]) do
              {:ok, {_module, [{:imports, module_imports}]}} -> module_imports
              _unavailable -> []
            end

          _not_loaded ->
            []
        end
      end)
    end)
  end
end
