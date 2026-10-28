defmodule Arbor.MCP.Security.DependencyAdvisoryMitigationTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Plug.Test

  alias Mix.Dep.Lock
  alias Mix.Project

  test "Mint requirement and lock exclude versions affected by September 2026 advisories" do
    mint_dep = List.keyfind(Project.config()[:deps], :mint, 0)
    requirement = elem(mint_dep, 1)

    assert Version.match?("1.10.2", requirement)
    refute Version.match?("1.10.1", requirement)

    locked_version = Lock.read()[:mint] |> elem(2)
    assert Version.compare(locked_version, "1.10.2") in [:eq, :gt]
  end

  test "JOSE requirement and lock exclude versions affected by EEF-CVE-2026-65625 through 65629" do
    jose_dep = List.keyfind(Project.config()[:deps], :jose, 0)
    requirement = elem(jose_dep, 1)

    assert Version.match?("1.11.13", requirement)
    refute Version.match?("1.11.12", requirement)

    locked_version = Lock.read()[:jose] |> elem(2)
    assert Version.compare(locked_version, "1.11.13") in [:eq, :gt]
  end

  test "Decimal requirement and lock exclude versions affected by EEF-CVE-2026-97853" do
    decimal_dep = List.keyfind(Project.config()[:deps], :decimal, 0)
    requirement = elem(decimal_dep, 1)

    assert Version.match?("3.1.2", requirement)
    refute Version.match?("3.1.1", requirement)

    locked_version = Lock.read()[:decimal] |> elem(2)
    assert Version.compare(locked_version, "3.1.2") in [:eq, :gt]
  end

  test "Bandit requirement and lock include the October 26 HTTP/1, HTTP/2 and WebSocket fixes" do
    requirement = Project.config()[:deps] |> List.keyfind(:bandit, 0) |> elem(1)
    assert Version.match?("1.14.0", requirement)
    refute Version.match?("1.13.1", requirement)
    refute Version.match?("1.13.0", requirement)

    lock = Lock.read()
    assert elem(lock[:bandit], 2) == "1.14.0"
    assert elem(lock[:thousand_island], 2) == "1.6.0"
    assert Version.compare(elem(lock[:hpax], 2), "1.1.0") in [:eq, :gt]
  end

  test "Cowlib and Plug.Crypto locks include the October 2026 advisory fixes" do
    lock = Lock.read()
    assert Version.compare(elem(lock[:cowlib], 2), "2.21.0") in [:eq, :gt]
    assert Version.compare(elem(lock[:plug_crypto], 2), "2.2.1") in [:eq, :gt]

    # Only the independently justified Cowlib exception remains.
    assert Project.config()[:hex][:ignore_advisories] == ["EEF-CVE-2026-43966"]
  end

  test "Plug rejects response-header bytes covered by EEF-CVE-2026-43966" do
    conn = conn(:get, "/")

    for invalid <- ["safe\r\nx-injected: true", "safe\n", <<"safe", 0>>] do
      assert_raise Plug.Conn.InvalidHeaderError, fn ->
        Plug.Conn.put_resp_header(conn, "x-test", invalid)
      end
    end
  end

  test "Arbor.MCP modules do not import cow_cookie:cookie/1 (EEF-CVE-2026-43969, fixed in Cowlib 2.21.0)" do
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
