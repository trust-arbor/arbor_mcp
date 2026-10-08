defmodule Arbor.MCP.FacadeBoundaryTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.Runtime

  defmodule CleanupTransport do
    def close({owner, result}) do
      send(owner, :facade_cleanup_attempted)
      result
    end
  end

  defmodule PingTransport do
    @behaviour Arbor.MCP.Transport
    defstruct [:test, :pending]

    @impl true
    def connect(opts), do: {:ok, %__MODULE__{test: Keyword.fetch!(opts, :test)}}

    @impl true
    def send_message(wire, state) do
      message = Jason.decode!(wire)

      response =
        case message do
          %{"id" => id, "method" => "initialize", "params" => params} ->
            %{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{
                "protocolVersion" => params["protocolVersion"],
                "serverInfo" => %{"name" => "ping-cleanup", "version" => "1"},
                "capabilities" => %{}
              }
            }

          %{"id" => id} ->
            %{
              "jsonrpc" => "2.0",
              "id" => id,
              "error" => %{"code" => -32601, "message" => "Unsupported discovery"}
            }

          _notification ->
            nil
        end

      {:ok, %{state | pending: if(response, do: Jason.encode!(response), else: state.pending)}}
    end

    @impl true
    def receive_message(%{pending: wire} = state) when is_binary(wire),
      do: {:ok, wire, %{state | pending: nil}}

    def receive_message(_state), do: {:error, :closed}
    @impl true
    def subscribe(_pid, state), do: {:ok, state}
    @impl true
    def capabilities(_state), do: [:push]
    @impl true
    def connected?(_state), do: true

    @impl true
    def close(state) do
      send(state.test, :ping_cleanup_attempted)
      {:error, :cleanup_denied}
    end
  end

  test "test-only Response conversion is absent" do
    Code.ensure_loaded!(Arbor.MCP.Response)
    refute function_exported?(Arbor.MCP.Response, :to_test_map, 1)
  end

  test "implementation bridges are absent from public facades" do
    for {module, signatures} <- [
          {Client,
           [
             connection_options: 2,
             start_scoped: 3,
             parse_connection_spec: 1,
             prepare_transport_config: 1,
             make_request: 5
           ]},
          {Arbor.MCP.Server.DSL, [prepare_tool_arguments: 3, validate_tool_response: 2]},
          {Arbor.MCP.Server.Result,
           [
             normalize_tool: 2,
             normalize_tool_result: 1,
             normalize_resource: 4,
             normalize_prompt: 2
           ]},
          {Arbor.MCP.Server.DSL.Result,
           [
             normalize_tool: 2,
             normalize_tool_result: 1,
             normalize_resource: 4,
             normalize_prompt: 2
           ]},
          {Runtime,
           [
             start_configured: 3,
             reserve_ingress: 3,
             publish_ingress: 5,
             dispatch_reserved: 3,
             dispatch_reserved: 4,
             discard_ingress: 2
           ]}
        ] do
      Code.ensure_loaded!(module)

      for {name, arity} <- signatures do
        refute function_exported?(module, name, arity),
               "#{inspect(module)}.#{name}/#{arity} leaked"
      end
    end
  end

  test "supported advanced runtime operations remain exported and documented" do
    Code.ensure_loaded!(Runtime)
    {:docs_v1, _, _, _, _, _, entries} = Code.fetch_docs(Runtime)

    for {name, arity} <- [
          submit: 3,
          request: 3,
          await: 2,
          cancel: 4,
          cancel_scope: 2,
          stats: 1,
          cancelled?: 0
        ] do
      assert function_exported?(Runtime, name, arity)

      {_, _, _, documentation, _} =
        Enum.find(entries, fn {key, _, _, _, _} -> key == {:function, name, arity} end)

      assert is_map(documentation)
    end
  end

  test "facade shutdown reports a transport cleanup failure" do
    client = start_supervised!({Client, transport: :test, _skip_connect: true})
    owner = self()
    monitor = Process.monitor(client)

    :sys.replace_state(client, fn state ->
      %{
        state
        | transport_mod: CleanupTransport,
          transport_state: {owner, {:error, :cleanup_denied}},
          connection_status: :connected
      }
    end)

    assert {:error, :cleanup_denied} = Arbor.MCP.disconnect(client)
    assert_receive :facade_cleanup_attempted
    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}
  end

  test "facade shutdown is idempotent after confirmed stop" do
    {:ok, client} = Client.start_link(transport: :test, _skip_connect: true)
    monitor = Process.monitor(client)
    assert :ok = Arbor.MCP.disconnect(client)
    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}
    assert :ok = Arbor.MCP.disconnect(client)
  end

  test "advertised capabilities do not promise transport-list fallback" do
    refute :transport_fallback in Arbor.MCP.info().features
  end

  test "temporary ping reports cleanup failure even after successful connectivity" do
    assert {:error, {:cleanup_failed, :cleanup_denied, :ok}} =
             Arbor.MCP.ping({PingTransport, test: self()}, reconnect: false)

    assert_receive :ping_cleanup_attempted
  end
end
