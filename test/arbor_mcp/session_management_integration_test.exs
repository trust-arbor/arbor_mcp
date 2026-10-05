defmodule Arbor.MCP.SessionManagementIntegrationTest do
  @moduledoc "Addressed HTTP session lifecycle, durable replay and reconnect integration."
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  alias Arbor.MCP.{HttpPlug, SessionManager}
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Test.RuntimeHTTPFixture

  defmodule ObservedAdapter do
    alias Plug.Adapters.Test.Conn
    defdelegate read_req_body(state, opts), to: Conn
    defdelegate send_resp(state, status, headers, body), to: Conn
    defdelegate send_chunked(state, status, headers), to: Conn

    def chunk(state, data) do
      send(state.observer, {:stream_wire, self(), IO.iodata_to_binary(data)})
      Conn.chunk(state, data)
    end
  end

  setup do
    runtime = RuntimeHTTPFixture.start()
    {:ok, service} = Runtime.service(runtime, :sessions)
    opts = RuntimeHTTPFixture.options(runtime, legacy_http_sse: true, sse_mode: :oneshot)
    %{runtime: runtime, service: service, opts: opts}
  end

  test "creates a new addressed session on the deprecated SSE handshake", %{
    service: service,
    opts: opts
  } do
    result = conn(:get, "/sse") |> HttpPlug.call(opts)
    assert result.status == 200
    assert get_resp_header(result, "content-type") == ["text/event-stream"]
    id = alias_session_id(result)
    assert {:ok, lease} = SessionManager.ensure_session(service, id, %{}, [])
    assert {:ok, %{id: ^id, initialized: false}} = SessionManager.get_session(service, lease, [])
    assert {:ok, %{sessions: 1}} = SessionManager.get_stats(service, [])
    assert is_nil(Process.whereis(SessionManager))
  end

  test "reuses the exact existing session with its session header", %{
    runtime: runtime,
    service: service,
    opts: opts
  } do
    id = RuntimeHTTPFixture.session(runtime, false)
    result = conn(:get, "/sse") |> put_req_header("mcp-session-id", id) |> HttpPlug.call(opts)
    assert result.status == 200
    assert alias_session_id(result) == id
    assert {:ok, %{sessions: 1}} = SessionManager.get_stats(service, [])
  end

  test "a caller-supplied unknown session cannot mint a replacement", %{
    service: service,
    opts: opts
  } do
    result =
      conn(:get, "/sse")
      |> put_req_header("mcp-session-id", "non-existent-session")
      |> HttpPlug.call(opts)

    assert result.status == 404
    assert {:ok, %{sessions: 0}} = SessionManager.get_stats(service, [])
  end

  test "appends an exact durable response before replay", %{runtime: runtime, service: service} do
    id = RuntimeHTTPFixture.session(runtime)
    {:ok, lease} = SessionManager.ensure_session(service, id, %{}, [])
    response = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"echo" => "hello"}}
    assert {:ok, event} = SessionManager.append_event(service, lease, "message", response, [])

    assert {:ok, %{events: [^event], more?: false}} =
             SessionManager.replay_page(service, lease, nil, [])
  end

  test "DELETE closes only the captured addressed session", %{
    runtime: runtime,
    service: service,
    opts: opts
  } do
    id = RuntimeHTTPFixture.session(runtime)
    sibling = RuntimeHTTPFixture.session(runtime)
    {:ok, lease} = SessionManager.ensure_session(service, id, %{}, [])

    result =
      conn(:delete, "/mcp")
      |> put_req_header("mcp-session-id", id)
      |> put_req_header("mcp-protocol-version", "2025-06-18")
      |> HttpPlug.call(opts)

    assert result.status == 204
    assert {:error, :session_not_found} = SessionManager.ensure_session(service, id, %{}, [])
    assert {:error, _retired} = SessionManager.get_session(service, lease, [])
    assert {:ok, %{initialized: true}} = RuntimeHTTPFixture.session_state(runtime, sibling)
  end

  test "DELETE cannot close an unknown session", %{service: service, opts: opts} do
    result =
      conn(:delete, "/mcp")
      |> put_req_header("mcp-session-id", "non-existent-session")
      |> put_req_header("mcp-protocol-version", "2025-06-18")
      |> HttpPlug.call(opts)

    assert result.status == 404
    assert {:ok, %{sessions: 0}} = SessionManager.get_stats(service, [])
  end

  test "a disconnected GET preserves replay and reconnects after the opaque cursor", %{
    runtime: runtime,
    service: service,
    opts: opts
  } do
    id = RuntimeHTTPFixture.session(runtime)
    {:ok, lease} = SessionManager.ensure_session(service, id, %{}, [])
    observer = self()

    first =
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

    pid = first.pid
    assert_receive {:stream_wire, ^pid, handshake}, 1_000
    assert handshake =~ "event: connected"

    assert {:ok, before_gap} =
             SessionManager.append_event(service, lease, "message", %{message: "before-gap"}, [])

    assert_receive {:stream_wire, ^pid, delivered}, 1_000
    assert delivered =~ "id: #{before_gap.id}"
    assert Task.shutdown(first, :brutal_kill) == nil
    assert {:ok, %{initialized: true}} = SessionManager.get_session(service, lease, [])

    assert {:ok, gap} =
             SessionManager.append_event(service, lease, "message", %{message: "during-gap"}, [])

    result =
      conn(:get, "/mcp")
      |> put_req_header("accept", "text/event-stream")
      |> put_req_header("mcp-session-id", id)
      |> put_req_header("mcp-protocol-version", "2025-06-18")
      |> put_req_header("last-event-id", before_gap.id)
      |> HttpPlug.call(opts)

    assert result.status == 200
    assert result.resp_body =~ "id: #{gap.id}"
    assert result.resp_body =~ "during-gap"
    refute result.resp_body =~ "before-gap"
  end

  test "the session and tagged replay cursor persist across separate readers", %{
    runtime: runtime,
    service: service
  } do
    id = RuntimeHTTPFixture.session(runtime)
    {:ok, lease} = SessionManager.ensure_session(service, id, %{}, [])

    {:ok, first} =
      SessionManager.append_event(service, lease, "notification", %{message: "first"}, [])

    {:ok, second} =
      SessionManager.append_event(service, lease, "response", %{result: "success"}, [])

    assert {:ok, renewed} = SessionManager.ensure_session(service, id, %{}, [])

    assert {:ok, %{events: [^second]}} =
             SessionManager.replay_page(service, renewed, first.id, [])

    assert {:ok, %{events: [^first, ^second]}} =
             SessionManager.replay_page(service, renewed, nil, [])
  end

  test "addressed session accounting includes the retained replay", %{
    runtime: runtime,
    service: service
  } do
    id = RuntimeHTTPFixture.session(runtime)
    _other = RuntimeHTTPFixture.session(runtime)
    {:ok, lease} = SessionManager.ensure_session(service, id, %{}, [])

    for n <- 1..3,
        do:
          assert(
            match?(
              {:ok, _},
              SessionManager.append_event(service, lease, "test", %{counter: n}, [])
            )
          )

    assert {:ok, %{sessions: 2, events: 3, replay_bytes: bytes, metadata_bytes: metadata}} =
             SessionManager.get_stats(service, [])

    assert bytes > 0
    assert metadata > 0
  end

  defp alias_session_id(conn) do
    [_, endpoint] = Regex.run(~r/event: endpoint\s+data: ([^\r\n]+)/, conn.resp_body)
    endpoint |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("sessionId")
  end
end
