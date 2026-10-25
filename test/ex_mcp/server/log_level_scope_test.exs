defmodule ExMCP.Server.LogLevelScopeTest do
  @moduledoc """
  The default `handle_set_log_level/2` used to call `Logger.configure/1`, so
  any connected client could change the host application's global log level.
  It now only validates the level.
  """

  use ExUnit.Case, async: false

  defmodule Handler do
    @moduledoc false
    use ExMCP.Server.Handler
  end

  test "a client's level leaves the host's Logger level alone" do
    level = Logger.level()
    assert {:ok, %{}} = Handler.handle_set_log_level("emergency", %{})
    assert {:ok, %{}} = Handler.handle_set_log_level("debug", %{})
    assert Logger.level() == level
  end

  test "an invalid level is rejected" do
    assert {:error, "Invalid log level: " <> _, %{}} =
             Handler.handle_set_log_level("loud", %{})
  end
end
