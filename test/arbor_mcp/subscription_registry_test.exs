defmodule Arbor.MCP.SubscriptionRegistryTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Arbor.MCP.{HttpPlug, SessionManager, SubscriptionRegistry}
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Test.RuntimeHTTPFixture

  defmodule SubscriptionHandler do
    use Arbor.MCP.Server.Handler
    def init(opts), do: {:ok, %{observer: opts[:observer]}}
    def handle_subscribe_resource(_uri, state), do: {:ok, %{}, state}
    def handle_unsubscribe_resource(_uri, state), do: {:ok, %{}, state}

    def handle_call_tool("broadcast", %{"uri" => uri}, state) do
      result = Arbor.MCP.Server.notify_resource_update(uri)
      send(state.observer, {:publication, result})
      {:ok, %{"content" => []}, state}
    end
  end

  defmodule ObservedAdapter do
    alias Plug.Adapters.Test.Conn
    defdelegate send_chunked(state, status, headers), to: Conn
    defdelegate read_req_body(state, options), to: Conn
    defdelegate send_resp(state, status, headers, body), to: Conn

    def chunk(state, wire) do
      send(state.observer, {:stream_wire, self(), IO.iodata_to_binary(wire)})
      Conn.chunk(state, wire)
    end
  end

  test "HTTP sessions subscribe and unsubscribe independently" do
    {runtime, opts, resources, sessions} = host()
    uri = "test://shared"
    ids = for _ <- 1..2, do: RuntimeHTTPFixture.session(runtime)
    [session_a, session_b] = ids
    assert post_resource_request(opts, session_a, "resources/subscribe", uri).status == 200
    assert post_resource_request(opts, session_b, "resources/subscribe", uri).status == 200

    {:ok, lease_a} = SessionManager.ensure_session(sessions, session_a, %{}, [])
    {:ok, lease_b} = SessionManager.ensure_session(sessions, session_b, %{}, [])
    assert {:ok, [^uri]} = SubscriptionRegistry.subscriptions(resources, lease_a, [])
    assert {:ok, [^uri]} = SubscriptionRegistry.subscriptions(resources, lease_b, [])
    assert post_resource_request(opts, session_a, "resources/unsubscribe", uri).status == 200
    assert {:ok, []} = SubscriptionRegistry.subscriptions(resources, lease_a, [])
    assert {:ok, [^uri]} = SubscriptionRegistry.subscriptions(resources, lease_b, [])

    for id <- ids,
        do: assert(match?({:ok, %{id: ^id}}, RuntimeHTTPFixture.session_state(runtime, id)))

    assert is_nil(Process.whereis(SubscriptionRegistry))
  end

  test "terminating and expiring explicitly supervised standalone sessions remove subscriptions" do
    start_supervised!(SubscriptionRegistry)
    manager_name = {:global, {:subscription_session_manager, make_ref()}}

    manager =
      start_supervised!(
        {SessionManager, name: manager_name, session_ttl_seconds: 0, cleanup_interval_ms: 60_000}
      )

    terminated = GenServer.call(manager, {:create_session, %{transport: :http}})
    expired = GenServer.call(manager, {:create_session, %{transport: :http}})
    assert :ok = SubscriptionRegistry.subscribe(terminated, "test://one")
    assert :ok = SubscriptionRegistry.subscribe(terminated, "test://two")
    assert :ok = GenServer.call(manager, {:terminate_session, terminated})
    assert SubscriptionRegistry.subscriptions(terminated) == []
    assert :ok = SubscriptionRegistry.subscribe(expired, "test://one")
    send(manager, :cleanup_expired_sessions)
    assert {:ok, %{status: :terminated}} = GenServer.call(manager, {:get_session, expired})
    assert SubscriptionRegistry.subscriptions(expired) == []
  end

  test "runtime callback broadcasts durably reach all subscribers and physically deliver to live streams" do
    {runtime, opts, _resources, sessions} = host()
    uri = "test://broadcast"
    ids = for _ <- 1..3, do: RuntimeHTTPFixture.session(runtime)

    for id <- ids,
        do: assert(post_resource_request(opts, id, "resources/subscribe", uri).status == 200)

    observer = self()

    streams =
      for id <- Enum.take(ids, 2) do
        task =
          Task.async(fn ->
            connection =
              conn(:get, "/mcp")
              |> put_req_header("accept", "text/event-stream")
              |> put_req_header("mcp-session-id", id)
              |> put_req_header("mcp-protocol-version", "2025-06-18")

            {_, state} = connection.adapter

            connection = %{
              connection
              | adapter: {ObservedAdapter, Map.put(state, :observer, observer)}
            }

            HttpPlug.call(connection, Map.put(opts, :sse_mode, :stream))
          end)

        pid = task.pid
        assert_receive {:stream_wire, ^pid, initial}, 1_000
        assert initial =~ "event: connected"
        task
      end

    result =
      request(opts, hd(ids), "tools/call", %{
        "name" => "broadcast",
        "arguments" => %{"uri" => uri}
      })

    assert result.status == 200
    assert_receive {:publication, %{subscribers: 3, delivered: 2}}, 1_000

    for task <- streams do
      pid = task.pid
      assert_receive {:stream_wire, ^pid, notification}, 1_000
      assert notification =~ "notifications/resources/updated"
      assert notification =~ uri
    end

    for id <- ids do
      {:ok, lease} = SessionManager.ensure_session(sessions, id, %{}, [])

      assert {:ok,
              %{
                events: [
                  %{
                    data: %{
                      "method" => "notifications/resources/updated",
                      "params" => %{"uri" => ^uri}
                    }
                  }
                ]
              }} = SessionManager.replay_page(sessions, lease, nil, [])
    end

    for task <- streams, do: Task.shutdown(task, :brutal_kill)
    assert {:error, :no_request_context} = Arbor.MCP.Server.notify_resource_update(uri)
    assert is_nil(Process.whereis(Arbor.MCP.HttpPlug.SessionRegistry))
  end

  defp host do
    runtime = RuntimeHTTPFixture.start(SubscriptionHandler, handler_args: [observer: self()])
    opts = RuntimeHTTPFixture.options(runtime, sse_mode: :oneshot)
    {:ok, resources} = Runtime.service(runtime, :resource_subscriptions)
    {:ok, sessions} = Runtime.service(runtime, :sessions)
    {runtime, opts, resources, sessions}
  end

  defp post_resource_request(opts, id, method, uri),
    do: request(opts, id, method, %{"uri" => uri})

  defp request(opts, session_id, method, params) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }

    conn(:post, "/mcp", Jason.encode!(request))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-session-id", session_id)
    |> put_req_header("mcp-protocol-version", "2025-06-18")
    |> HttpPlug.call(opts)
  end
end
