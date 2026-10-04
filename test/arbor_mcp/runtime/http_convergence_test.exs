defmodule Arbor.MCP.Server.Runtime.HTTPConvergenceTest do
  use ExUnit.Case, async: true
  alias Arbor.MCP.{HttpPlug, SessionManager}
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{HTTPWriterProxy, HTTPWriterRegistry}

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    alias Arbor.MCP.Protocol.Initialize
    alias Arbor.MCP.Server.Context

    def init(opts) do
      send(opts[:test], :convergence_init)
      {:ok, %{test: opts[:test], count: 0}}
    end

    def handle_initialize(%{"clientInfo" => %{"name" => "fail"}}, state),
      do: {:error, :fixture_initialization_failed, state}

    def handle_initialize(params, state) do
      send(state.test, :convergence_initialize_callback)

      {:ok,
       Initialize.build_initialize_result(params, %{
         "serverInfo" => %{"name" => "convergence", "version" => "2"},
         "capabilities" => %{"tools" => %{}}
       }), state}
    end

    def handle_call_tool("count", _args, state) do
      send(state.test, {:convergence_count, state.count})

      {:ok, %{"content" => [], "structuredContent" => %{"count" => state.count}},
       %{state | count: state.count + 1}}
    end

    def handle_call_tool("hold", _args, state) do
      send(state.test, {:convergence_hold, Context.current().request_id, self()})
      if Context.progress_token(), do: Context.report_progress(1)
      receive do: (:finish -> :ok)

      {:ok, %{"content" => [], "structuredContent" => %{"count" => state.count}},
       %{state | count: state.count + 1}}
    end

    def handle_call_tool("collect", _args, state) do
      send(state.test, {:convergence_collect, Context.input_responses()})

      case Context.input_responses() do
        nil ->
          requests = %{
            "profile" => %{
              "method" => "elicitation/create",
              "params" => %{
                "message" => "Choose a name",
                "requestedSchema" => %{"type" => "object"}
              }
            }
          }

          {:input_required, requests, %{"step" => "profile"}, %{state | count: state.count + 1}}

        %{"profile" => response} ->
          text = response["content"]["name"] <> ":" <> Context.request_state()["step"]

          {:ok, %{"content" => [%{"type" => "text", "text" => text}]},
           %{state | count: state.count + 1}}
      end
    end

    def handle_elicitation_complete(id, state) do
      send(state.test, {:convergence_notification, id, self()})
      if id == "hold", do: receive(do: (:finish -> :ok))
      {:ok, %{state | count: state.count + 1}}
    end
  end

  test "a legacy initialization array establishes one addressed session and retains root state" do
    {runtime, opts} = runtime()
    assert_receive :convergence_init
    conn = post([initialize(), count(2)], opts)
    assert conn.status == 200, conn.resp_body
    [id] = Plug.Conn.get_resp_header(conn, "mcp-session-id")

    assert [
             %{"id" => 1, "result" => %{"protocolVersion" => "2025-11-25"}},
             %{"id" => 2, "result" => %{"structuredContent" => %{"count" => 0}}}
           ] = Jason.decode!(conn.resp_body)

    assert_receive :convergence_initialize_callback
    assert_receive {:convergence_count, 0}
    {:ok, service} = Runtime.service(runtime, :sessions)
    assert {:ok, _lease} = SessionManager.ensure_initialized_session(service, id, %{}, [])

    next = post(count(3), opts, id)
    assert next.status == 200
    assert Jason.decode!(next.resp_body)["result"]["structuredContent"]["count"] == 1
    refute_receive :convergence_init, 5
    settled(runtime)
  end

  test "misordered or multiple initialization members are rejected before claims and callbacks" do
    {runtime, opts} = runtime()

    for members <- [[count(2), initialize()], [initialize(), %{initialize() | "id" => 3}]] do
      conn = post(members, opts)
      assert conn.status == 400
      assert Plug.Conn.get_resp_header(conn, "mcp-session-id") == []
    end

    refute_receive :convergence_initialize_callback, 5
    refute_receive {:convergence_count, _}, 5
    {:ok, service} = Runtime.service(runtime, :sessions)
    assert {:ok, %{sessions: 0}} = SessionManager.get_stats(service, [])
    settled(runtime)
  end

  test "failed array initialization suppresses its session header and skips following effects" do
    {runtime, opts} = runtime()
    failed = put_in(initialize(), ["params", "clientInfo", "name"], "fail")
    conn = post([failed, count(2)], opts)
    assert conn.status == 200
    assert [%{"id" => 1, "error" => _}] = Jason.decode!(conn.resp_body)
    assert Plug.Conn.get_resp_header(conn, "mcp-session-id") == []
    refute_receive {:convergence_count, _}, 5
    {:ok, service} = Runtime.service(runtime, :sessions)
    assert {:ok, %{sessions: 0}} = SessionManager.get_stats(service, [])
    settled(runtime)
  end

  test "modern arrays cannot initialize a session or invoke any legacy callback" do
    {runtime, opts} = runtime()
    conn = post([initialize(), count(2)], %{opts | protocol_mode: :modern_only})
    assert conn.status == 400
    assert Plug.Conn.get_resp_header(conn, "mcp-session-id") == []
    refute_receive :convergence_initialize_callback, 5
    refute_receive {:convergence_count, _}, 5
    settled(runtime)
  end

  test "mounted modern MRTR seals and resumes under addressed replay protection and shared state" do
    {runtime, opts} = runtime(services: [sessions: [], replay_cache: []])
    opts = mrtr_options(opts)
    first = post(collect(1), opts)
    assert first.status == 200, first.resp_body
    interim = Jason.decode!(first.resp_body)["result"]
    assert interim["resultType"] == "input_required"
    assert Map.keys(interim["inputRequests"]) == ["profile"]
    assert is_binary(interim["requestState"])
    assert Plug.Conn.get_resp_header(first, "mcp-session-id") == []
    assert_receive {:convergence_collect, nil}

    retry = retry(interim["requestState"])
    second = post(retry, opts)
    assert second.status == 200

    assert %{
             "result" => %{
               "resultType" => "complete",
               "content" => [
                 %{"type" => "text", "text" => "Ada:profile"}
               ]
             }
           } = Jason.decode!(second.resp_body)

    assert_receive {:convergence_collect, %{"profile" => _}}

    replay = post(%{retry | "id" => 3}, opts)
    assert %{"error" => %{"code" => -32602}} = Jason.decode!(replay.resp_body)
    refute_receive {:convergence_collect, _}, 5

    assert {:ok, %{"result" => %{"structuredContent" => %{"count" => 2}}}} =
             Runtime.request(runtime, count(4))

    settled(runtime)
  end

  test "MRTR continuation rejects changed endpoint or authorization identity before callbacks" do
    {runtime, opts} = runtime(services: [sessions: [], replay_cache: []])
    opts = mrtr_options(opts)
    initial = post(collect(1), opts)
    token = Jason.decode!(initial.resp_body)["result"]["requestState"]
    assert_receive {:convergence_collect, nil}

    for changed <- [
          %{opts | endpoint: "/another"},
          %{opts | principal_id: "another"},
          %{opts | tenant_id: "another"}
        ] do
      response = post(retry(token), changed)
      assert %{"error" => %{"code" => -32602}} = Jason.decode!(response.resp_body)
      refute_receive {:convergence_collect, _}, 5
    end

    assert {:ok, %{"result" => %{"structuredContent" => %{"count" => 1}}}} =
             Runtime.request(runtime, count(4))

    settled(runtime)
  end

  test "invalid or late trusted identity resolution never renews callback authority" do
    {runtime, opts} = runtime(request_timeout_ms: 40)
    opts = mrtr_options(opts)
    invalid = %{opts | principal_id: fn _conn, _request, _claims -> %{private: true} end}
    response = post(collect(1), invalid)
    assert response.status == 500
    assert Jason.decode!(response.resp_body)["error"]["message"] == "Internal error"
    refute_receive {:convergence_collect, _}, 5

    late = %{
      opts
      | principal_id: fn _conn, _request, _claims ->
          Process.sleep(60)
          "alice"
        end
    }

    assert_raise Arbor.MCP.HttpPlug.RuntimeWriter.AdmissionError, fn -> post(collect(2), late) end
    refute_receive {:convergence_collect, _}, 5
    settled(runtime)
  end

  defp runtime(extra \\ []) do
    root =
      start_supervised!(
        {Runtime,
         Keyword.merge(
           [
             handler: Handler,
             handler_args: [test: self()],
             request_timeout_ms: 2_000,
             services: [sessions: []]
           ],
           extra
         )}
      )

    {:ok, runtime} = Runtime.ref(root)
    {runtime, HttpPlug.init(runtime: runtime, protocol_mode: :legacy_only)}
  end

  defp mrtr_options(opts) do
    opts
    |> Map.put(:protocol_mode, :modern_only)
    |> Map.put(:endpoint, "/mcp")
    |> Map.put(:principal_id, "alice")
    |> Map.put(:tenant_id, "team")
    |> Map.put(:require_replay_protection, true)
    |> Map.put(:request_state,
      active_key_id: "fixture",
      keys: %{
        "fixture" => :binary.copy(<<42>>, 32)
      },
      ttl_seconds: 60
    )
  end

  defp collect(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{
        "name" => "collect",
        "arguments" => %{},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}}
        }
      }
    }
  end

  defp retry(token) do
    collect(2)
    |> put_in(["params", "requestState"], token)
    |> put_in(["params", "inputResponses"], %{
      "profile" => %{
        "action" => "accept",
        "content" => %{"name" => "Ada"}
      }
    })
  end

  defp initialize do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "convergence", "version" => "2"}
      }
    }
  end

  defp count(id),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "count", "arguments" => %{}}
    }

  defp post(request, opts, id \\ nil) do
    conn =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(request))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn =
      if id,
        do:
          conn
          |> Plug.Conn.put_req_header("mcp-session-id", id)
          |> Plug.Conn.put_req_header("mcp-protocol-version", "2025-11-25"),
        else: conn

    conn =
      if opts.protocol_mode == :modern_only and is_map(request) do
        conn
        |> Plug.Conn.put_req_header("mcp-protocol-version", "2026-07-28")
        |> Plug.Conn.put_req_header("mcp-method", request["method"])
        |> Plug.Conn.put_req_header("mcp-name", request["params"]["name"])
      else
        conn
      end

    HttpPlug.call(conn, opts)
  end

  defp settled(runtime) do
    {:ok, domain} = HTTPWriterProxy.domain(runtime)

    wait(fn ->
      Runtime.stats(runtime).reserved == 0 and
        match?(%{frames: 0, in_flight: 0}, HTTPWriterRegistry.stats(domain))
    end)
  end

  defp wait(fun, left \\ 200)
  defp wait(_fun, 0), do: flunk("convergence state not reached")

  defp wait(fun, left) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          wait(fun, left - 1)
        )
  end
end
