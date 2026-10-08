defmodule Arbor.RPC.PortEnvironmentTest do
  use ExUnit.Case, async: false

  alias Arbor.RPC.PortEnvironment

  test "validates supported child environment policies" do
    assert :ok = PortEnvironment.validate_policy([])
    assert :ok = PortEnvironment.validate_policy(environment_policy: :isolated)
    assert :ok = PortEnvironment.validate_policy(environment_policy: :inherit)

    assert {:error, {:invalid_environment_policy, :unsafe}} =
             PortEnvironment.validate_policy(environment_policy: :unsafe)
  end

  test "normalizes supported environment shapes without losing explicit removals" do
    assert PortEnvironment.normalize(%{"BAR" => false, FOO: 1}) == %{
             "FOO" => "1",
             "BAR" => false
           }

    assert PortEnvironment.normalize([
             {"TUPLE", 2},
             %{name: :ATOM_MAP, value: true},
             %{"name" => "STRING_MAP", "value" => "value"}
           ]) == %{
             "TUPLE" => "2",
             "ATOM_MAP" => "true",
             "STRING_MAP" => "value"
           }

    assert PortEnvironment.normalize(:invalid) == %{}
  end

  test "encodes normalized values for Port.open/2" do
    assert PortEnvironment.to_port(%{"SET" => "value", "UNSET" => false})
           |> Map.new() == %{~c"SET" => ~c"value", ~c"UNSET" => false}
  end

  test "isolated base removes ambient variables while inherit starts empty" do
    sentinel = "EX_MCP_PORT_ENVIRONMENT_TEST_SECRET"
    previous = System.get_env(sentinel)
    System.put_env(sentinel, "ambient")

    on_exit(fn ->
      if is_binary(previous),
        do: System.put_env(sentinel, previous),
        else: System.delete_env(sentinel)
    end)

    assert PortEnvironment.base([])[sentinel] == false
    assert PortEnvironment.base(environment_policy: :inherit) == %{}
  end

  @release_host %{
    "PATH" => "/srv/app/erts-16.3/bin:/srv/app/bin:/usr/local/bin:/usr/bin:/bin",
    "RELEASE_ROOT" => "/srv/app",
    "HOME" => "/home/app",
    "SECRET_TOKEN" => "never-inherited"
  }

  describe "child PATH hygiene" do
    test "an OTP release's own directories are removed from the inherited PATH" do
      env = PortEnvironment.base([], @release_host)

      assert env["PATH"] == "/usr/local/bin:/usr/bin:/bin"
      assert env["HOME"] == "/home/app"
      assert env["SECRET_TOKEN"] == false
      assert env["RELEASE_ROOT"] == false
    end

    test "the inherit policy gets the same PATH" do
      assert PortEnvironment.base([environment_policy: :inherit], @release_host) == %{
               "PATH" => "/usr/local/bin:/usr/bin:/bin"
             }
    end

    test "a directory that merely shares the release root's prefix is kept" do
      host = %{@release_host | "PATH" => "/srv/app/bin:/srv/application/bin:/bin"}
      assert PortEnvironment.base([], host)["PATH"] == "/srv/application/bin:/bin"
    end

    test "PATH is untouched outside a release" do
      host = Map.delete(@release_host, "RELEASE_ROOT")

      assert PortEnvironment.base([], host)["PATH"] == host["PATH"]
      assert PortEnvironment.base([environment_policy: :inherit], host) == %{}
    end

    test "on Windows, entries are split on ; and compared without case or slash direction" do
      host = %{
        "PATH" => "C:\\app\\erts-16.3\\bin;c:/APP/bin;C:\\Windows\\system32;C:\\application\\bin",
        "RELEASE_ROOT" => "C:\\App\\"
      }

      windows = {:win32, :nt}

      assert PortEnvironment.child_path([], host, windows) ==
               "C:\\Windows\\system32;C:\\application\\bin"

      assert PortEnvironment.base([environment_policy: :inherit], host, windows) == %{
               "PATH" => "C:\\Windows\\system32;C:\\application\\bin"
             }
    end

    test "the child's PATH is an explicit one when given, else the cleaned inherited one" do
      assert PortEnvironment.child_path([], @release_host) == "/usr/local/bin:/usr/bin:/bin"

      assert PortEnvironment.child_path([env: [{"PATH", "/opt/tools"}]], @release_host) ==
               "/opt/tools"

      assert PortEnvironment.child_path([env: %{"PATH" => false}], @release_host) == nil
    end
  end
end
