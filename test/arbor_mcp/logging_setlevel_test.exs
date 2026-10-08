defmodule Arbor.MCP.LoggingSetLevelTest do
  @moduledoc """
  Tests for the logging/setLevel request handler.
  """
  use ExUnit.Case, async: true
  alias Arbor.MCP.TestHelpers
  @moduletag :integration
  @moduletag :logging

  alias Arbor.MCP.Client
  alias Arbor.MCP.Protocol.ErrorCodes
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule TestHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_args), do: {:ok, %{log_level: "info"}}

    @impl true
    def handle_initialize(_params, state) do
      result = %{
        protocolVersion: "2025-03-26",
        serverInfo: %{name: "test-server", version: "1.0.0"},
        capabilities: %{}
      }

      {:ok, result, state}
    end

    @impl true
    def handle_set_log_level(level, state) do
      # Validate log level
      valid_levels = ["debug", "info", "warning", "error"]

      if level in valid_levels do
        {:ok, %{state | log_level: level}}
      else
        {:error, "Invalid log level: #{level}", state}
      end
    end

    @impl true
    def handle_call_tool(_name, _args, state) do
      {:error, "No tools available", state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      {:ok, [], nil, state}
    end
  end

  describe "logging/setLevel" do
    setup do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: TestHandler,
          handler_args: []
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: :legacy_only
        )

      on_exit(fn ->
        TestHelpers.safe_stop_process(client)
        TestHelpers.safe_stop_process(server)
      end)

      {:ok, client: client, server: server}
    end

    test "sets log level successfully", %{client: client} do
      assert {:ok, %{}} = Client.set_log_level(client, "debug")
    end

    test "accepts all valid log levels", %{client: client} do
      valid_levels = ["debug", "info", "warning", "error"]

      for level <- valid_levels do
        assert {:ok, %{}} = Client.set_log_level(client, level)
      end
    end

    test "returns error for invalid log level", %{client: client} do
      assert {:error, error} = Client.set_log_level(client, "verbose")
      assert error.code == ErrorCodes.invalid_params()
      assert error.message == "Invalid parameters"
    end
  end

  describe "handler implementation" do
    test "default handler implementation just returns ok" do
      defmodule MinimalHandler do
        use Arbor.MCP.Server.Handler

        @impl true
        def init(_args), do: {:ok, %{}}

        @impl true
        def handle_initialize(_params, state) do
          {:ok,
           %{
             protocolVersion: "2025-03-26",
             serverInfo: %{name: "minimal", version: "1.0.0"},
             capabilities: %{}
           }, state}
        end
      end

      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: MinimalHandler,
          handler_args: []
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: :legacy_only
        )

      # Should succeed with default implementation
      assert {:ok, %{}} = Client.set_log_level(client, "debug")

      GenServer.stop(client)
      GenServer.stop(server)
    end
  end
end
