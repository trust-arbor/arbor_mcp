defmodule ExMCP.Client.InitializeCapabilitiesTest do
  @moduledoc """
  A legacy `initialize` always sent `"capabilities": %{}`, whatever the
  client's `:capabilities` option said, so servers that respect declared
  capabilities never sent this client elicitation, sampling or roots
  requests. The declared capabilities are now sent; atom keys are sent as
  strings, as the same map arrives over the wire.
  """

  use ExUnit.Case, async: true

  alias ExMCP.Client
  alias ExMCP.Server.HandlerServer

  defmodule ServerHandler do
    @moduledoc false
    use ExMCP.Server.Handler

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}

    @impl true
    def handle_initialize(params, state) do
      send(state.owner, {:initialize_params, params})

      {:ok,
       %{
         "protocolVersion" => params["protocolVersion"],
         "capabilities" => %{},
         "serverInfo" => %{"name" => "initialize-capabilities", "version" => "1"}
       }, state}
    end
  end

  defp connect(opts) do
    {:ok, server} =
      HandlerServer.start_link(
        handler: ServerHandler,
        transport: :test,
        handler_args: [owner: self()],
        protocol_mode: :legacy_only
      )

    on_exit(fn -> ExMCP.TestHelpers.safe_stop_process(server) end)

    Client.start_link(
      [
        transport: :test,
        server: server,
        protocol_mode: :legacy_only,
        health_check_interval: nil,
        reconnect: false
      ] ++ opts
    )
  end

  test "a legacy initialize sends the client's declared capabilities" do
    {:ok, _client} =
      connect(capabilities: %{"elicitation" => %{"form" => %{}}, "sampling" => %{}})

    assert_receive {:initialize_params, %{"capabilities" => capabilities}}, 2_000
    assert capabilities == %{"elicitation" => %{"form" => %{}}, "sampling" => %{}}
  end

  test "capabilities declared with atom keys are sent as strings" do
    {:ok, _client} = connect(capabilities: %{sampling: %{}})

    assert_receive {:initialize_params, %{"capabilities" => capabilities}}, 2_000
    assert capabilities == %{"sampling" => %{}}
  end

  test "a client that declares nothing still sends empty capabilities" do
    {:ok, _client} = connect([])

    assert_receive {:initialize_params, %{"capabilities" => capabilities}}, 2_000
    assert capabilities == %{}
  end
end
