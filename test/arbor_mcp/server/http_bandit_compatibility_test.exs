defmodule Arbor.MCP.Server.HTTPBanditCompatibilityTest do
  use ExUnit.Case, async: false

  import Arbor.MCP.TestHelpers, only: [assert_socket_closed: 2, listening_socket: 1]

  alias Arbor.MCP.Server.HTTP.Bandit.Owned
  alias Arbor.MCP.Server.{Runtime, Transport}

  defmodule Handler do
    use Arbor.MCP.Server.Handler
  end

  defmodule Echo do
    @behaviour WebSock
    def init(observer) do
      send(observer, {:websocket_connection, self()})
      {:ok, observer}
    end

    def handle_in({data, opcode: opcode}, state), do: {:push, {opcode, data}, state}
    def handle_info(_message, state), do: {:ok, state}
  end

  defmodule HostPlug do
    def init(options), do: options

    def call(%{request_path: "/ws"} = conn, options),
      do: Plug.Conn.upgrade_adapter(conn, :websocket, {Echo, options[:observer], []})

    def call(%{request_path: "/health"} = conn, _options),
      do: Plug.Conn.send_resp(conn, 200, "host alive")

    def call(conn, options), do: Arbor.MCP.HttpPlug.call(conn, options[:mcp])
  end

  test "owned qualification rejects other versions before handler effects in an isolated VM" do
    assert Owned.compatible?()

    # Application metadata belongs to the VM. Exercise rejection without
    # replacing modules or changing the running test suite's application state.
    script = """
    defmodule UnreachableHandler do
      use Arbor.MCP.Server.Handler
      def init(_), do: raise("unsupported constructor initialized its handler")
    end

    originals = for app <- [:bandit, :thousand_island], into: %{} do
      :ok = Application.load(app)
      {:ok, properties} = :application.get_all_key(app)
      {app, properties}
    end

    for {bandit, island} <- [
          {"1.12.5", "1.5.0"}, {"1.13.1", "1.6.0"},
          {"1.14.1", "1.6.0"}, {"1.14.0", "1.5.0"}, {"1.14.0", "1.6.1"}
        ] do
      for {app, version} <- [bandit: bandit, thousand_island: island] do
        :ok = Application.unload(app)
        :ok = :application.load({:application, app,
          Keyword.put(originals[app], :vsn, String.to_charlist(version))})
      end

      false = Arbor.MCP.Server.HTTP.Bandit.Owned.compatible?()
      {:error, :unsupported_owned_bandit_constructor} =
        Arbor.MCP.Server.Runtime.start_link(handler: UnreachableHandler,
          transport: :http, http: [adapter: :bandit, port: 0])
      {:ok, _} = Arbor.MCP.Server.HTTP.Config.new([adapter: :bandit, port: 0], :borrowed)
    end
    IO.puts("unqualified pairs rejected; borrowed configuration accepted")
    """

    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])
    {output, status} = System.cmd("elixir", paths ++ ["-e", script], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "unqualified pairs rejected; borrowed configuration accepted"
  end

  for ownership <- [:owned, :host], protocol <- [:http1, :http2] do
    @tag :physical_http
    test "#{ownership} Bandit serves MCP over #{protocol} and respects listener ownership" do
      {root, listener, port} = start_listener(unquote(ownership))
      socket = listening_socket(port)
      conn = connect(port, unquote(protocol))
      request = notify_request_stop()

      body =
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: %{
            protocolVersion: "2025-11-25",
            capabilities: %{},
            clientInfo: %{name: "bandit-compatibility", version: "1"}
          }
        })

      headers = [
        {"content-type", "application/json"},
        {"accept", "application/json"},
        {"mcp-protocol-version", "2025-11-25"},
        {"x-compatibility-request", request}
      ]

      {:ok, conn, ref} = Mint.HTTP.request(conn, "POST", "/mcp", headers, body)
      {conn, events} = response(conn, ref)
      assert {:status, ref, 200} in events
      result = events |> response_body(ref) |> Jason.decode!()
      assert result["id"] == 1
      assert result["result"]["protocolVersion"] == "2025-11-25"
      # The client can read the whole response before the server's write
      # returns; over HTTP/2 the stream hands its frames to the connection
      # process first. Stopping then reports that write as unsettled IO, so
      # wait for Bandit to finish the request.
      assert_receive {:request_stopped, ^request}, 1_000

      monitor = Process.monitor(listener)
      socket_monitor = :erlang.monitor(:port, socket)
      assert :ok = Runtime.stop(root)

      if unquote(ownership) == :host do
        assert Process.alive?(listener)
        {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", "/health", [], nil)
        {conn, events} = response(conn, ref)
        assert response_body(events, ref) == "host alive"
        Mint.HTTP.close(conn)
        assert :ok = Supervisor.stop(listener)
      else
        Mint.HTTP.close(conn)
      end

      assert_receive {:DOWN, ^monitor, :process, ^listener, _}, 1_000
      assert_socket_closed(socket, socket_monitor)
    end
  end

  @tag :physical_http
  test "host Bandit upgrades WebSockets, echoes data and ping, and closes active connections" do
    {root, listener, port} = start_listener(:host)
    socket = listening_socket(port)
    {conn, ref, websocket} = websocket(port)
    assert_receive {:websocket_connection, connection}, 1_000

    {conn, websocket} = send_frame(conn, ref, websocket, {:text, "bandit 1.14.0"})
    {conn, websocket, frames} = frames(conn, ref, websocket)
    assert {:text, "bandit 1.14.0"} in frames
    {conn, websocket} = send_frame(conn, ref, websocket, {:binary, <<0, 1, 255>>})
    {conn, websocket, frames} = frames(conn, ref, websocket)
    assert {:binary, <<0, 1, 255>>} in frames

    assert :ok = Runtime.stop(root)
    assert Process.alive?(connection)
    {conn, websocket} = send_frame(conn, ref, websocket, {:ping, "still hosted"})
    {conn, websocket, frames} = frames(conn, ref, websocket)
    assert {:pong, "still hosted"} in frames

    {conn, websocket} = send_frame(conn, ref, websocket, {:close, 1_000, "done"})
    {conn, _websocket, frames} = frames(conn, ref, websocket)
    assert Enum.any?(frames, &match?({:close, 1_000, _}, &1))
    Mint.HTTP.close(conn)

    # Keep another WebSocket live across host shutdown.
    {conn, _ref, _websocket} = websocket(port)
    assert_receive {:websocket_connection, connection}, 1_000
    monitor = Process.monitor(connection)
    socket_monitor = :erlang.monitor(:port, socket)
    assert :ok = Supervisor.stop(listener)
    assert_receive {:DOWN, ^monitor, :process, ^connection, _}, 1_000
    Mint.HTTP.close(conn)
    assert_socket_closed(socket, socket_monitor)
  end

  # Bandit 1.14.0 returns `:more` from an HTTP/2 read that reaches `:length`
  # before END_STREAM, so a body exactly at the limit must not look oversized.
  @tag :physical_http
  test "an HTTP/2 body exactly at body_limit is accepted without content-length" do
    {:ok, root} = Runtime.start_link(handler: Handler, transport: :mounted_http)
    on_exit(fn -> Runtime.stop(root) end)

    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-11-25",
          capabilities: %{},
          clientInfo: %{name: "bandit-body-limit", version: "1"}
        }
      })

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"},
      {"mcp-protocol-version", "2025-11-25"}
    ]

    for {limit, status} <- [{byte_size(body), 200}, {byte_size(body) - 1, 413}] do
      mcp = Arbor.MCP.HttpPlug.init(runtime: root, path: "/mcp", body_limit: limit)

      {:ok, listener} =
        Bandit.start_link(
          plug: {HostPlug, [mcp: mcp, observer: self()]},
          port: 0,
          ip: {127, 0, 0, 1},
          startup_log: false
        )

      {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)
      conn = connect(port, :http2)

      # Streaming sends no content-length, and `:eof` sends END_STREAM in an
      # empty DATA frame of its own.
      {:ok, conn, ref} = Mint.HTTP.request(conn, "POST", "/mcp", headers, :stream)
      {:ok, conn} = Mint.HTTP.stream_request_body(conn, ref, body)
      {:ok, conn} = Mint.HTTP.stream_request_body(conn, ref, :eof)
      {conn, events} = response(conn, ref)
      assert {:status, ref, status} in events

      Mint.HTTP.close(conn)
      assert :ok = Supervisor.stop(listener)
    end
  end

  @tag :physical_http
  test "the owned MCP Plug does not expose a WebSocket endpoint" do
    {_root, _listener, port} = start_listener(:owned)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, connect(port, :http1), "/mcp", [])
    {conn, events} = response(conn, ref)
    assert {:status, ref, 400} in events
    assert response_body(events, ref) =~ "Session ID required"
    refute {:status, ref, 101} in events
    Mint.HTTP.close(conn)
  end

  # Bandit emits [:bandit, :request, :stop] after the plug, and so its
  # response write, has returned.
  defp notify_request_stop do
    test = self()
    request = Base.encode16(:crypto.strong_rand_bytes(8))
    handler = {__MODULE__, request}

    :ok =
      :telemetry.attach(
        handler,
        [:bandit, :request, :stop],
        fn _event, _measurements, metadata, _config ->
          with %Plug.Conn{} = conn <- metadata[:conn],
               [^request] <- Plug.Conn.get_req_header(conn, "x-compatibility-request"),
               do: send(test, {:request_stopped, request})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    request
  end

  defp start_listener(ownership) do
    options = [
      startup_log: false,
      thousand_island_options: [num_acceptors: 1, shutdown_timeout: 100]
    ]

    {:ok, root} =
      Runtime.start_link(
        handler: Handler,
        transport: if(ownership == :owned, do: :http, else: :mounted_http),
        http: [adapter: :bandit, port: 0, host: {127, 0, 0, 1}, listener_options: options]
      )

    on_exit(fn -> Runtime.stop(root) end)

    listener =
      if ownership == :owned do
        {:ok, %{adapter: :bandit, listener: listener}} = Transport.http_listener(root)
        listener
      else
        mcp = Arbor.MCP.HttpPlug.init(runtime: root, path: "/mcp")

        {:ok, listener} =
          Bandit.start_link(
            [plug: {HostPlug, [mcp: mcp, observer: self()]}, port: 0, ip: {127, 0, 0, 1}] ++
              options
          )

        on_exit(fn -> if Process.alive?(listener), do: Supervisor.stop(listener) end)
        listener
      end

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)
    {root, listener, port}
  end

  defp connect(port, protocol) do
    {:ok, conn} =
      Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [protocol], mode: :passive)

    assert Mint.HTTP.protocol(conn) == protocol
    conn
  end

  defp response(conn, ref, accumulated \\ []) do
    {:ok, conn, events} = Mint.HTTP.recv(conn, 0, 2_000)
    accumulated = accumulated ++ events

    if {:done, ref} in accumulated,
      do: {conn, accumulated},
      else: response(conn, ref, accumulated)
  end

  defp response_body(events, ref),
    do: for({:data, ^ref, data} <- events, into: "", do: data)

  defp websocket(port) do
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, connect(port, :http1), "/ws", [])
    {conn, events} = response(conn, ref)
    assert {:status, ref, 101} in events

    headers =
      Enum.flat_map(events, fn
        {:headers, ^ref, headers} -> headers
        _ -> []
      end)

    {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, 101, headers, mode: :passive)
    {conn, ref, websocket}
  end

  defp send_frame(conn, ref, websocket, frame) do
    {:ok, websocket, data} = Mint.WebSocket.encode(websocket, frame)
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    {conn, websocket}
  end

  defp frames(conn, ref, websocket) do
    {:ok, conn, events} = Mint.WebSocket.recv(conn, 0, 2_000)
    {:ok, websocket, frames} = Mint.WebSocket.decode(websocket, response_body(events, ref))
    if frames == [], do: frames(conn, ref, websocket), else: {conn, websocket, frames}
  end
end
