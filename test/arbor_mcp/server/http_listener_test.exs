defmodule Arbor.MCP.Server.HTTPListenerTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.Transport
  alias Arbor.MCP.Server.HTTP.{Bandit, Cowboy}

  defmodule Handler do
    use Arbor.MCP.Server.Handler
  end

  test "listener packages remain optional in the published dependency declaration" do
    dependencies = Mix.Project.config()[:deps]

    for app <- [:plug_cowboy, :cowlib, :bandit] do
      dependency = List.keyfind(dependencies, app, 0)
      assert Keyword.fetch!(elem(dependency, 2), :optional)
    end

    requirement = dependencies |> List.keyfind(:bandit, 0) |> elem(1)
    assert Version.match?("1.12.5", requirement)
    refute Version.match?("1.12.4", requirement)
    assert Version.compare(Mix.Dep.Lock.read()[:bandit] |> elem(2), "1.12.5") in [:eq, :gt]
  end

  test "unsupported adapters and invalid listener options fail explicitly" do
    assert {:error, {:unsupported_http_adapter, :unknown}} = start(http_adapter: :unknown)
    assert {:error, :invalid_http_listener_options} = start(http_listener_options: %{})

    assert {:error, {:unsupported_http_option, :bandit, :ranch_ref}} =
             start(http_adapter: :bandit, ranch_ref: make_ref())

    assert {:error, :invalid_http_shutdown_timeout} =
             Transport.stop_http_server(:unused_reference, http_shutdown_timeout: :infinity)
  end

  test "availability reports the explicit backends independently" do
    assert %{adapters: %{cowboy: true, bandit: true}, available: true} =
             Transport.list_transports().http

    assert Cowboy.available?()
    assert Bandit.available?()
  end

  test "the compatibility default preserves the Cowboy reference and already-started result" do
    ref = make_ref()
    assert {:ok, listener} = start(ranch_ref: ref)
    on_exit(fn -> stop_if_alive(listener) end)
    assert {:ok, ^ref} = Cowboy.reference(listener)
    assert {:ok, ^listener} = start(ranch_ref: ref)
    port = :ranch.get_port(ref)
    assert port > 0
    assert_http(port)
    assert_stopped(listener, fn -> Transport.stop_http_server(ref) end)
    assert {:error, :not_found} = Cowboy.stop(ref)
    refute_open(port)
  end

  test "an absent or false Ranch reference retains the default Plug reference" do
    for opts <- [[], [ranch_ref: false]] do
      assert {:ok, listener} = start(opts)
      on_exit(fn -> stop_if_alive(listener) end)
      assert {:ok, Arbor.MCP.HttpPlug.HTTP} = Cowboy.reference(listener)
      assert :ok = Transport.stop_http_server(listener)
    end
  end

  test "PID lookup and shutdown do not query an unrelated suspended Cowboy listener" do
    assert {:ok, unrelated} = start(ranch_ref: make_ref())
    assert {:ok, listener} = start(ranch_ref: make_ref())
    :sys.suspend(unrelated)

    on_exit(fn ->
      if Process.alive?(unrelated), do: :sys.resume(unrelated)
      stop_if_alive(unrelated)
      stop_if_alive(listener)
    end)

    operation =
      Task.async(fn ->
        assert {:ok, _ref} = Cowboy.reference(listener)
        Transport.stop_http_server(listener, http_shutdown_timeout: 200)
      end)

    assert {:ok, :ok} = Task.yield(operation, 1_000)
    refute Process.alive?(listener)
    assert Process.alive?(unrelated)
  end

  test "generic PID shutdown removes a Cowboy listener rather than allowing Ranch restart" do
    ref = make_ref()
    assert {:ok, listener} = start(http_adapter: :cowboy, ranch_ref: ref)
    on_exit(fn -> stop_if_alive(listener) end)
    port = :ranch.get_port(ref)
    assert_stopped(listener, fn -> Transport.stop_server(listener) end)
    assert {:error, :not_found} = Cowboy.stop(ref)
    refute_open(port)
  end

  test "Cowboy shutdown bounds a delayed listener and permits completing Ranch removal" do
    ref = make_ref()
    assert {:ok, listener} = start(ranch_ref: ref)
    port = :ranch.get_port(ref)
    delayed = add_delayed_child(listener)

    on_exit(fn ->
      Process.exit(delayed, :kill)
      Cowboy.stop(ref)
    end)

    monitor = Process.monitor(listener)
    started = System.monotonic_time(:millisecond)

    assert {:error, {:http_listener_operation_timeout, :cowboy, :shutdown}} =
             Transport.stop_http_server(ref, http_shutdown_timeout: 30)

    assert System.monotonic_time(:millisecond) - started < 1_000
    assert Process.alive?(listener)
    Process.exit(delayed, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^listener, _reason}, 1_000
    assert :ok = Cowboy.stop(ref)
    assert {:error, :not_found} = Cowboy.stop(ref)
    refute_open(port)
  end

  test "Bandit starts the same MCP Plug and shuts down by its own PID" do
    assert {:ok, listener} = start(http_adapter: :bandit)
    on_exit(fn -> stop_if_alive(listener, :bandit) end)
    assert {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
    assert port > 0
    assert_http(port)

    assert_stopped(listener, fn -> Transport.stop_http_server(listener, http_adapter: :bandit) end)

    assert {:error, :not_found} = Bandit.stop(listener)
    refute_open(port)
  end

  test "Bandit rejects an unrelated live PID without messaging or stopping it" do
    unrelated = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(unrelated, :kill) end)
    assert {:error, :invalid_http_listener} = Bandit.stop(unrelated)
    assert Process.alive?(unrelated)
    assert {:messages, []} = Process.info(unrelated, :messages)
  end

  test "generic PID shutdown routes Bandit through its finite adapter lifecycle" do
    assert {:ok, listener} = start(http_adapter: :bandit)
    on_exit(fn -> stop_if_alive(listener, :bandit) end)
    assert {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
    assert_stopped(listener, fn -> Transport.stop_server(listener) end)
    refute_open(port)
  end

  test "Bandit shutdown has a finite budget and reports incomplete cleanup honestly" do
    assert {:ok, listener} = start(http_adapter: :bandit)
    assert {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
    delayed = add_delayed_child(listener)

    on_exit(fn ->
      Process.exit(delayed, :kill)
      stop_if_alive(listener, :bandit)
    end)

    monitor = Process.monitor(listener)
    started = System.monotonic_time(:millisecond)

    assert {:error, {:http_listener_operation_timeout, :bandit, :shutdown}} =
             Transport.stop_http_server(listener,
               http_adapter: :bandit,
               http_shutdown_timeout: 30
             )

    assert System.monotonic_time(:millisecond) - started < 1_000
    assert Process.alive?(listener)
    Process.exit(delayed, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^listener, _reason}, 1_000
    refute_open(port)
  end

  test "Cowboy-only option precedence cannot change the bound host or port implicitly" do
    ref = make_ref()

    assert {:ok, listener} =
             start(
               ranch_ref: ref,
               http_listener_options: [
                 ref: :ignored_listener_reference,
                 port: 1,
                 ip: {0, 0, 0, 0}
               ]
             )

    on_exit(fn -> stop_if_alive(listener) end)
    assert {:ok, ^ref} = Cowboy.reference(listener)
    assert {{127, 0, 0, 1}, port} = :ranch.get_addr(ref)
    assert port > 1
    assert :ok = Transport.stop_http_server(listener)
  end

  defp start(opts) do
    Transport.start_http_server(
      Handler,
      %{name: "optional-listener", version: "2.0.0"},
      [],
      Keyword.merge([port: 0, host: {127, 0, 0, 1}], opts)
    )
  end

  defp add_delayed_child(listener) do
    parent = self()

    child = %{
      id: :delayed_shutdown,
      shutdown: :infinity,
      start:
        {Task, :start_link,
         [
           fn ->
             Process.flag(:trap_exit, true)
             send(parent, :delayed_shutdown_started)
             receive do: (:release -> :ok)
           end
         ]}
    }

    assert {:ok, delayed} = Supervisor.start_child(listener, child)
    assert_receive :delayed_shutdown_started
    delayed
  end

  defp assert_http(port) do
    url = ~c"http://127.0.0.1:#{port}/mcp"

    initialize =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 0,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "listener-test", "version" => "2.0.0"}
        }
      })

    headers = [{~c"accept", ~c"application/json, text/event-stream"}]

    assert {:ok, {{_version, 200, _reason}, initialize_headers, _response}} =
             :httpc.request(
               :post,
               {url, headers, ~c"application/json", initialize},
               [timeout: 2_000],
               []
             )

    {_, session} = List.keyfind(initialize_headers, ~c"mcp-session-id", 0)

    headers = [
      {~c"mcp-session-id", session},
      {~c"mcp-protocol-version", ~c"2025-11-25"} | headers
    ]

    notification = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    assert {:ok, {{_version, 202, _reason}, _headers, _response}} =
             :httpc.request(
               :post,
               {url, headers, ~c"application/json", notification},
               [timeout: 2_000],
               []
             )

    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

    assert {:ok, {{_version, 200, _reason}, _headers, response}} =
             :httpc.request(
               :post,
               {url, headers, ~c"application/json", body},
               [timeout: 2_000],
               []
             )

    assert %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}} = Jason.decode!(to_string(response))
  end

  defp assert_stopped(listener, stop) do
    monitor = Process.monitor(listener)
    assert :ok = stop.()
    assert_receive {:DOWN, ^monitor, :process, ^listener, _reason}, 1_000
    refute Process.alive?(listener)
  end

  defp stop_if_alive(listener, adapter \\ :cowboy) do
    if Process.alive?(listener),
      do: Transport.stop_http_server(listener, http_adapter: adapter)
  end

  defp refute_open(port) do
    assert {:error, :econnrefused} =
             :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 500)
  end
end
