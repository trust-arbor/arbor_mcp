defmodule Arbor.MCP.Server.Runtime.HTTPReverseOAuthTest do
  use ExUnit.Case, async: false
  import Plug.Conn

  alias Arbor.MCP.{HttpPlug, SessionManager}
  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    HTTPGateway,
    HTTPWriterProxy,
    HTTPWriterRegistry
  }

  alias Arbor.MCP.Server.Runtime.HTTPResources.Source

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    alias Arbor.MCP.Protocol.Initialize
    alias Arbor.MCP.Server

    def init(opts), do: {:ok, %{observer: opts[:observer], calls: 0}}

    def handle_initialize(params, state),
      do:
        {:ok,
         Initialize.build_initialize_result(params, %{
           "serverInfo" => %{"name" => "reverse-oauth", "version" => "2"},
           "capabilities" => %{"tools" => %{}}
         }), state}

    def handle_call_tool("ping", _args, state) do
      send(state.observer, {:oauth_reverse_worker, self()})
      result = Server.ping(self(), 1_000)
      send(state.observer, {:oauth_reverse_result, result})
      receive do: (:finish -> :ok)
      {:ok, %{"content" => []}, %{state | calls: state.calls + 1}}
    end

    def handle_call_tool("peek", _args, state),
      do: {:ok, %{"content" => [], "structuredContent" => %{"calls" => state.calls}}, state}
  end

  setup do
    previous = Application.fetch_env(:arbor_mcp, :oauth2_enabled)
    Application.put_env(:arbor_mcp, :oauth2_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_mcp, :oauth2_enabled, value)
        :error -> Application.delete_env(:arbor_mcp, :oauth2_enabled)
      end
    end)

    :ok
  end

  test "an introspected same-principal token with no application scopes settles the exact reverse" do
    host = host()
    session = initialize(host)
    opened = open_reverse(host, session)
    result = %{"answer" => 7}

    assert %{status: 202, resp_body: ""} =
             post(host.opts, session.id, response(opened.request["id"], result), "alice-reply")

    assert_receive {:introspected, "alice-reply"}, 1_000
    finish_reverse(host, session, opened, {:ok, result})
  end

  test "missing inactive and incorrectly bound bearers never consume a pending reverse" do
    host = host()
    session = initialize(host)
    opened = open_reverse(host, session)

    for {token, error} <- [
          {nil, "invalid_request"},
          {"inactive", "invalid_token"},
          {"wrong-issuer", "invalid_token"},
          {"wrong-audience", "invalid_token"},
          {"expired", "invalid_token"}
        ] do
      assert %{status: 401} =
               conn = post(host.opts, session.id, response(opened.request["id"], %{}), token)

      assert %{"error" => ^error, "error_description" => description} =
               Jason.decode!(conn.resp_body)

      assert is_binary(description)
      assert [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ ~s(error="#{error}")
      if token, do: assert_receive({:introspected, ^token}, 1_000)
      assert_pending(host, session, opened)
    end

    assert %{status: 202, resp_body: ""} =
             post(host.opts, session.id, response(opened.request["id"], %{}), "alice-reply")

    finish_reverse(host, session, opened, {:ok, %{}})
  end

  test "authenticated foreign principal and same-bearer tenant or host endpoint cannot settle" do
    host = host()
    session = initialize(host)
    opened = open_reverse(host, session)
    value = response(opened.request["id"], %{})

    attempts = [
      {host.opts, "bob-reply", []},
      {Map.put(host.opts, :tenant_id, "tenant-other"), "alice-reply", []},
      {host.opts, "alice-reply", ["other-host-mount"]}
    ]

    for {opts, token, prefix} <- attempts do
      assert %{status: 404} = conn = post(opts, session.id, value, token, prefix)

      assert Jason.decode!(conn.resp_body) == %{
               "jsonrpc" => "2.0",
               "id" => nil,
               "error" => %{"code" => -32600, "message" => "Session not found"}
             }

      assert_receive {:introspected, ^token}, 1_000
      assert_pending(host, session, opened)
    end

    assert %{status: 202, resp_body: ""} = post(host.opts, session.id, value, "alice-reply")
    finish_reverse(host, session, opened, {:ok, %{}})
  end

  test "a second authentic same-principal session cannot authorize the first reverse loan" do
    host = host()
    session = initialize(host)
    other = initialize(host)
    refute session.lease == other.lease
    opened = open_reverse(host, session)
    value = response(opened.request["id"], %{"exact" => true})

    assert %{status: 202, resp_body: ""} = post(host.opts, other.id, value, "alice-reply")
    assert_pending(host, session, opened)

    assert %{status: 202, resp_body: ""} = post(host.opts, session.id, value, "alice-reply")
    finish_reverse(host, session, opened, {:ok, %{"exact" => true}})
  end

  test "a result-plus-error envelope remains invalid without reaching bearer introspection" do
    host = host()
    session = initialize(host)
    opened = open_reverse(host, session)

    value =
      Map.put(response(opened.request["id"], %{}), "error", %{
        "code" => -32603,
        "message" => "Client failure"
      })

    assert %{status: 400} = conn = post(host.opts, session.id, value, "malformed-probe")
    assert %{"error" => %{"code" => -32600}} = Jason.decode!(conn.resp_body)
    refute_receive {:introspected, "malformed-probe"}, 20
    assert_pending(host, session, opened)

    assert %{status: 202, resp_body: ""} =
             post(host.opts, session.id, response(opened.request["id"], %{}), "alice-reply")

    finish_reverse(host, session, opened, {:ok, %{}})
  end

  test "a host custom response scope still denies insufficient tokens and accepts its scope" do
    mapper = fn
      %{"jsonrpc" => "2.0", "id" => _id, "result" => _result} -> ["host:reverse:reply"]
      _method -> nil
    end

    host = host(scope_mapper: mapper)
    session = initialize(host)
    opened = open_reverse(host, session)
    value = response(opened.request["id"], %{})

    assert %{status: 403} = conn = post(host.opts, session.id, value, "alice-reply")

    assert Jason.decode!(conn.resp_body) == %{
             "error" => "insufficient_scope",
             "error_description" => "The request requires higher privileges."
           }

    assert [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ ~s(scope="host:reverse:reply")
    assert_pending(host, session, opened)

    assert %{status: 202, resp_body: ""} = post(host.opts, session.id, value, "alice-scoped")
    assert_receive {:introspected, "alice-scoped"}, 1_000
    finish_reverse(host, session, opened, {:ok, %{}})
  end

  defp host(mount_options \\ []) do
    root =
      start_supervised!(
        {Runtime,
         handler: Handler,
         handler_args: [observer: self()],
         request_timeout_ms: 2_000,
         max_concurrency: 1,
         max_queue: 0,
         services: [sessions: []]},
        id: make_ref()
      )

    {:ok, runtime} = Runtime.ref(root)
    observer = self()

    config = %{
      realm: "reverse-oauth",
      introspection_endpoint: "https://oauth.example/introspect",
      client_id: "resource-client",
      client_secret: "resource-secret",
      expected_issuer: "https://issuer.example",
      expected_audience: "https://mcp.example",
      clock_skew_seconds: 0,
      oauth_http: [
        dns_resolver: fn _host, _timeout -> {:ok, [{93, 184, 216, 34}]} end,
        request_fun: fn :post, {_url, headers, _content_type, body}, options, _request_opts ->
          assert {~c"authorization", ~c"Basic cmVzb3VyY2UtY2xpZW50OnJlc291cmNlLXNlY3JldA=="} in headers

          assert options[:autoredirect] == false
          token = URI.decode_query(body)["token"]
          send(observer, {:introspected, token})
          {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], Jason.encode!(token_claims(token))}}
        end
      ]
    }

    opts =
      HttpPlug.init(
        Keyword.merge(
          [
            runtime: runtime,
            protocol_mode: :legacy_only,
            allowed_origins: :any,
            oauth_enabled: true,
            resource: "https://mcp.example",
            authorization_servers: ["https://issuer.example"],
            auth_config: config,
            tenant_id: fn _conn, _request, token -> token.username end
          ],
          mount_options
        )
      )

    %{runtime: runtime, opts: opts}
  end

  defp token_claims("inactive"), do: %{active: false}

  defp token_claims(token) do
    now = System.system_time(:second)

    claims = %{
      active: true,
      sub: if(token == "bob-reply", do: "bob", else: "alice"),
      username: "tenant-a",
      iss: "https://issuer.example",
      aud: "https://mcp.example",
      exp: now + 60,
      nbf: now - 60,
      scope: ""
    }

    case token do
      "alice-tool" -> Map.put(claims, :scope, "mcp:tools:execute:ping mcp:tools:execute:peek")
      "alice-scoped" -> Map.put(claims, :scope, "host:reverse:reply")
      "wrong-issuer" -> Map.put(claims, :iss, "https://other-issuer.example")
      "wrong-audience" -> Map.put(claims, :aud, "https://other-resource.example")
      "expired" -> Map.put(claims, :exp, now - 1)
      _reply -> claims
    end
  end

  defp initialize(host) do
    value = %{
      "jsonrpc" => "2.0",
      "id" => "init-" <> Integer.to_string(System.unique_integer([:positive])),
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "clientInfo" => %{"name" => "oauth-client", "version" => "2"},
        "capabilities" => %{}
      }
    }

    assert %{status: 200} = conn = post(host.opts, nil, value, "alice-tool")
    [id] = get_resp_header(conn, "mcp-session-id")
    {:ok, sessions} = Runtime.service(host.runtime, :sessions)

    metadata = %{
      principal_id: "alice",
      tenant_id: "tenant-a",
      issuer: "https://issuer.example",
      audience: "https://mcp.example",
      transport: :http,
      transport_endpoint: "/mcp",
      client_info: %{}
    }

    {:ok, lease} = SessionManager.ensure_initialized_session(sessions, id, metadata, [])

    assert {:ok, %{metadata: ^metadata, initialized: true}} =
             SessionManager.get_session(sessions, lease, [])

    eventually(fn -> match?(%{reserved: 0}, Runtime.stats!(host.runtime)) end)
    %{id: id, sessions: sessions, lease: lease}
  end

  defp open_reverse(host, session) do
    writer = spawn(fn -> writer_loop() end)
    on_exit(fn -> if Process.alive?(writer), do: Process.exit(writer, :kill) end)
    token = make_ref()

    send(writer, {:open, self(), token, host.runtime, session.lease})
    assert_receive {^token, :ok}, 1_000

    caller = Task.async(fn -> post(host.opts, session.id, tool(2, "ping"), "alice-tool") end)
    assert_receive {:oauth_reverse_worker, worker}, 1_000

    request =
      eventually_value(fn ->
        {:ok, %{events: events}} =
          SessionManager.replay_page(session.sessions, session.lease, nil, [])

        if event = Enum.find(events, &(&1.data["method"] == "ping")), do: event.data
      end)

    {:ok, gateway} = HTTPGateway.address(host.runtime)
    pending = :sys.get_state(gateway).reverse.pending
    assert map_size(pending) == 1
    [{control, proof}] = Map.to_list(pending)
    assert proof.id == request["id"]
    assert proof.producer == worker
    assert proof.response_token == nil
    assert Source.lease(proof.source) == session.lease
    assert Source.endpoint(proof.source) == "/mcp"

    assert Source.matches?(proof.source, %{
             principal_id: "alice",
             tenant_id: "tenant-a",
             transport_endpoint: "/mcp"
           })

    assert proof.deadline <= Source.deadline(proof.source)
    assert :atomics.get(proof.phase, 1) == 0
    {:ok, stats} = SessionManager.get_stats(session.sessions, [])

    %{
      caller: caller,
      worker: worker,
      request: request,
      control: control,
      proof: proof,
      stats: stats
    }
  end

  defp assert_pending(host, session, opened) do
    {:ok, gateway} = HTTPGateway.address(host.runtime)
    assert :sys.get_state(gateway).reverse.pending[opened.control] == opened.proof
    assert :atomics.get(opened.proof.phase, 1) == 0
    assert match?(%{active: 1, response_bytes: 0}, Runtime.stats!(host.runtime))
    assert {:ok, opened.stats} == SessionManager.get_stats(session.sessions, [])
    refute_receive {:oauth_reverse_result, _result}, 0
  end

  defp finish_reverse(host, session, opened, expected) do
    assert_receive {:oauth_reverse_result, ^expected}, 1_000
    send(opened.worker, :finish)
    assert %{status: 200} = conn = Task.await(opened.caller, 2_000)

    assert Jason.decode!(conn.resp_body) == %{
             "jsonrpc" => "2.0",
             "id" => 2,
             "result" => %{"content" => []}
           }

    eventually(fn -> match?(%{reserved: 0, response_bytes: 0}, Runtime.stats!(host.runtime)) end)

    assert {:ok, %{events: [%{data: request}]}} =
             SessionManager.replay_page(session.sessions, session.lease, nil, [])

    assert request == opened.request

    assert %{status: 200} = peek = post(host.opts, session.id, tool(3, "peek"), "alice-tool")
    assert get_in(Jason.decode!(peek.resp_body), ["result", "structuredContent", "calls"]) == 1
  end

  defp writer_loop do
    receive do
      {:open, caller, token, runtime, lease} ->
        {:ok, binding} = HTTPWriterProxy.capture(runtime)
        :ok = HTTPWriterRegistry.bind_lease(binding, lease)
        :ok = HTTPWriterRegistry.register_session_stream(binding)
        send(caller, {token, :ok})
        writer_loop()

      _notice ->
        writer_loop()
    end
  end

  defp post(opts, session, value, bearer, prefix \\ []) do
    conn =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(value))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-protocol-version", "2025-11-25")

    conn = %{conn | script_name: prefix}
    conn = if session, do: put_req_header(conn, "mcp-session-id", session), else: conn
    conn = if bearer, do: put_req_header(conn, "authorization", "Bearer " <> bearer), else: conn
    HttpPlug.call(conn, opts)
  end

  defp response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp tool(id, name),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => %{}}
    }

  defp eventually(operation), do: eventually_value(fn -> if operation.(), do: :ok end)
  defp eventually_value(operation, attempts \\ 200)

  defp eventually_value(_operation, 0),
    do: flunk("authenticated reverse operation did not settle")

  defp eventually_value(operation, attempts) do
    case operation.() do
      nil ->
        Process.sleep(5)
        eventually_value(operation, attempts - 1)

      value ->
        value
    end
  end
end
