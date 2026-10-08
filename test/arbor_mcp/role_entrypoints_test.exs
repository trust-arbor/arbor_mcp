defmodule Arbor.MCP.RoleEntrypointsTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.{Client, ClientConfig, Response, Server}
  alias Arbor.MCP.Server.{Runtime, Transport}
  alias Arbor.MCP.Test.StdioRuntimeFixture.Device

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_initialize(params, state) do
      {:ok,
       %{
         protocolVersion: params["protocolVersion"],
         serverInfo: %{name: "role-entrypoints", version: "1"},
         capabilities: %{tools: %{}, resources: %{}}
       }, state}
    end

    @impl true
    def handle_list_tools(cursor, state) do
      name = if cursor, do: "second", else: "echo"
      {:ok, [%{name: name, inputSchema: %{type: "object"}}], "next-page", state}
    end

    @impl true
    def handle_call_tool(name, _arguments, state) do
      {:ok,
       %{
         content: [%{type: "text", text: name}],
         isError: name == "failure",
         _meta: %{source: "entrypoints"}
       }, state}
    end

    @impl true
    def handle_list_resources(_cursor, state),
      do: {:ok, [%{uri: "memory://config", name: "config"}], "next-resource", state}

    @impl true
    def handle_read_resource(uri, state),
      do: {:ok, [%{uri: uri, text: "{\"enabled\":true}", mimeType: "application/json"}], state}
  end

  defmodule DSLHandler do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "dsl-entrypoints", version: "1"
  end

  test "canonical operations retain pages and errors while extraction is explicit" do
    server = start_supervised!({Server, handler: Handler, transport: :test})

    client =
      start_supervised!({Client, transport: :test, server: server, protocol_mode: :legacy_only})

    assert {:ok, %Response{nextCursor: "next-page"}} = Client.tools(client)
    assert {:ok, [%{"name" => "echo"}]} = Client.tool_definitions(client)

    assert {:ok, %Response{nextCursor: "next-page", tools: [%{"name" => "second"}]}} =
             Client.tool_definitions(client, cursor: "next-page", format: :struct)

    assert {:ok, %Response{is_error: true}} = Client.call(client, "failure")

    assert {:error, %Arbor.MCP.Error.ToolError{reason: %Response{is_error: true}}} =
             Client.call_content(client, "failure")

    assert {:ok, "echo"} = Client.call_content(client, "echo")

    assert Client.call_content(client, "echo", %{}, format: :map) ==
             Arbor.MCP.call(client, "echo", %{}, format: :map)

    assert {:ok, [%{"uri" => "memory://config"}]} = Client.resource_definitions(client)
    assert {:ok, %Response{nextCursor: "next-resource"}} = Client.list_resources(client)

    assert {:ok, %{"enabled" => true}} =
             Client.read_content(client, "memory://config", parse_json: true)

    assert Client.read_content(client, "memory://config") ==
             Arbor.MCP.read(client, "memory://config")

    assert_raise ArgumentError, fn ->
      Client.call_content(client, "echo", %{}, unsupported: true)
    end
  end

  test "probe owns its temporary client and borrows the existing server" do
    server = start_supervised!({Server, handler: Handler, transport: :beam})
    config = ClientConfig.new(:test) |> ClientConfig.put_transport(:beam, server: server)

    assert :ok = Client.probe(config, protocol_mode: :legacy_only)
    assert Process.alive?(server)
    assert {:ok, _stats} = Server.stats(server)

    assert {:ok, client} = Client.connect(config, protocol_mode: :legacy_only)
    assert {:ok, %Response{}} = Client.ping(client)
    assert :ok = Client.disconnect(client)
    assert Process.alive?(client)
    assert {:ok, %{connection_status: :disconnected}} = Client.status(client)
    assert :ok = Client.stop(client)
    refute Process.alive?(client)
    assert {:error, :client_not_alive} = Client.status(client)
    assert_raise RuntimeError, fn -> Client.status!(client) end
  end

  test "plain and generated handlers have supervisor child specs and shared startup" do
    for {module, opts} <- [
          {Server, [handler: Handler, transport: :beam]},
          {DSLHandler, [transport: :beam]}
        ] do
      spec = Supervisor.child_spec({module, opts}, restart: :temporary)
      assert spec.type == :supervisor
      root = start_supervised!(spec)
      assert {:ok, _ref} = Runtime.ref(root)
      assert {:ok, _stats} = Server.stats(root)
      assert is_map(Server.stats!(root))
      monitor = Process.monitor(root)
      assert :ok = Server.stop(root)
      assert_receive {:DOWN, ^monitor, :process, ^root, :normal}
    end

    assert {:error, {:unsupported_transport, :invalid}} =
             Server.start_link(handler: Handler, transport: :invalid)
  end

  test "the root startup wrapper now supports stdio without owning borrowed IO" do
    input = start_supervised!({Device, owner: self()}, id: :input)
    output = start_supervised!({Device, owner: self()}, id: :output)

    {:ok, server} =
      Arbor.MCP.start_server(
        handler: Handler,
        transport: :stdio,
        stdio_input: input,
        stdio_output: output,
        stdio_startup_delay: 0
      )

    monitor = Process.monitor(server)
    assert {:ok, _stats} = Server.stats(server)
    assert :ok = Server.stop(server)
    assert_receive {:DOWN, ^monitor, :process, ^server, :normal}
    assert Process.alive?(input)
    assert Process.alive?(output)
  end

  @tag :requires_http
  test "plain handlers can start and stop an owned HTTP listener" do
    root =
      start_supervised!({Server, handler: Handler, transport: :http, port: 0},
        restart: :temporary
      )

    assert {:ok, _listener} = Transport.http_listener(root)
    monitor = Process.monitor(root)
    assert :ok = Server.stop(root)
    assert_receive {:DOWN, ^monitor, :process, ^root, :normal}
  end
end
