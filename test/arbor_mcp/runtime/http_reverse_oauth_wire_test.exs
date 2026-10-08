defmodule Arbor.MCP.Qualification.HTTPReverseOAuthWireTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.{Client, SessionManager}
  alias Arbor.MCP.Server.{Runtime, Transport}
  alias Arbor.MCP.Server.Runtime.HTTPGateway
  alias Arbor.MCP.Server.Runtime.HTTPResources.Source
  alias Arbor.MCP.SessionManager.SessionLease

  @root_ms 2_000
  @reverse_ms 1_500
  @cleanup_ms 4_000
  @max_http_bytes 65_536

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

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    alias Arbor.MCP.Protocol.Initialize
    alias Arbor.MCP.Server
    alias Arbor.MCP.Server.Runtime.HTTPResources.Source

    def init(opts) do
      send(opts[:observer], {:wire_handler_initialized, self()})
      {:ok, %{observer: opts[:observer], calls: 0}}
    end

    def handle_initialize(params, state) do
      {:ok,
       Initialize.build_initialize_result(params, %{
         "serverInfo" => %{"name" => "oauth-owned-wire", "version" => "2"},
         "capabilities" => %{"tools" => %{}}
       }), state}
    end

    def handle_call_tool("ping", _args, state) do
      {:ok, source} = Source.capture()
      send(state.observer, {:wire_server_source, source})
      send(state.observer, {:wire_server_worker, self()})
      result = Server.ping(self(), 1_500)
      send(state.observer, {:wire_server_reverse_result, result})

      {:ok, %{"content" => [], "structuredContent" => %{"calls" => state.calls + 1}},
       %{state | calls: state.calls + 1}}
    end

    def handle_call_tool("peek", _args, state),
      do: {:ok, %{"content" => [], "structuredContent" => %{"calls" => state.calls}}, state}
  end

  defmodule ClientHandler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_ping(state) do
      send(state.observer, {:wire_client_reverse_received, self()})

      result =
        if state.hold do
          receive do
            {:wire_release_ping, value} -> {:ok, value}
          after
            1_500 -> {:error, "Qualification reply was not released"}
          end
        else
          {:ok, %{"actualClient" => true}}
        end

      :ets.insert(state.policy, {:reply_only, true})

      case result do
        {:ok, value} -> {:ok, value, state}
        {:error, reason} -> {:error, reason, state}
      end
    end

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state), do: {:error, "Not supported", state}
  end

  test "owned Cowboy and an actual Client settle authenticated reverse bookkeeping" do
    with_hosts(fn host, _sibling ->
      client = client(host, false)
      assert Client.negotiated_version(client) == {:ok, "2024-11-05"}

      assert {:ok, %{"structuredContent" => %{"calls" => 1}}} =
               Client.call_tool(client, "ping", %{},
                 format: :map,
                 timeout: @root_ms,
                 retry_policy: false
               )

      assert_receive {:wire_client_reverse_received, ^client}, 1_000
      assert_receive {:wire_server_reverse_result, {:ok, %{"actualClient" => true}}}, 1_000
      assert_receive {:wire_server_worker, _worker}, 1_000
      assert_receive {:wire_server_source, source}, 1_000
      assert_receive {:wire_introspected, "alice-tool", ""}, 1_000
      settled(host, now() + 1_000)
      assert_one_reverse(host, Source.lease(source))
      :ets.insert(host.policy, {:reply_only, false})
      assert calls(client) == 1
      refute_receive {:wire_handler_initialized, _extra_init}, 0
    end)
  end

  test "a retained 2024 batch keeps the native GET loop available for reverse requests" do
    with_hosts([max_queue: 1], fn host, _sibling ->
      client = client(host, false)
      assert Client.negotiated_version(client) == {:ok, "2024-11-05"}

      assert {:ok,
              [
                {:ok, %{"structuredContent" => %{"calls" => 1}}},
                {:ok, %{"structuredContent" => %{"calls" => 1}}}
              ]} =
               Client.batch_request(
                 client,
                 [
                   {"tools/call", %{"name" => "ping", "arguments" => %{}}},
                   {"tools/call", %{"name" => "peek", "arguments" => %{}}}
                 ],
                 @root_ms
               )

      assert_receive {:wire_client_reverse_received, ^client}, 1_000
      assert_receive {:wire_server_reverse_result, {:ok, %{"actualClient" => true}}}, 1_000
      assert_receive {:wire_server_worker, _worker}, 1_000
      assert_receive {:wire_server_source, source}, 1_000
      assert_receive {:wire_introspected, "alice-tool", ""}, 1_000
      settled(host, now() + 1_000)

      {:ok, %{events: events}} =
        SessionManager.replay_page(host.sessions, Source.lease(source), nil, [])

      assert Enum.count(events, &(is_map(&1.data) and &1.data["method"] == "ping")) == 1

      # One durable envelope retains the complete atomic batch in wire order.
      assert [aggregate] = Enum.filter(events, &is_list(&1.data))
      assert [first, second] = aggregate.data
      assert first["result"] == %{"content" => [], "structuredContent" => %{"calls" => 1}}
      assert second["result"] == %{"content" => [], "structuredContent" => %{"calls" => 1}}
      assert is_integer(first["id"]) and is_integer(second["id"])
      refute first["id"] == second["id"]

      :ets.insert(host.policy, {:reply_only, false})
      assert calls(client) == 1
      refute_receive {:wire_handler_initialized, _extra_init}, 0
    end)
  end

  test "actual HTTP denials cannot consume or renew the original Client reverse wait" do
    with_hosts(fn host, sibling ->
      client = client(host, true)
      other_session = initialize_raw(host)
      settled(host, now() + 1_000)

      caller =
        Task.async(fn ->
          Client.call_tool(client, "ping", %{},
            format: :map,
            timeout: @root_ms,
            retry_policy: false
          )
        end)

      Process.put(:oauth_wire_caller, caller)
      assert_receive {:wire_server_worker, worker}, 1_000
      assert_receive {:wire_client_reverse_received, ^client}, 1_000
      opened = pending(host, worker)
      session_id = SessionLease.id(Source.lease(opened.proof.source))
      assert session_id != other_session
      assert opened.proof.deadline <= Source.deadline(opened.proof.source)
      assert opened.proof.deadline > now()
      assert opened.proof.deadline - now() <= @reverse_ms
      assert Source.endpoint(opened.proof.source) == "/mcp"

      assert Source.matches?(opened.proof.source, %{
               principal_id: "alice",
               tenant_id: "tenant-a",
               transport_endpoint: "/mcp"
             })

      {:ok, before_stats} = SessionManager.get_stats(host.sessions, [])
      response = %{"jsonrpc" => "2.0", "id" => opened.proof.id, "result" => %{"forged" => true}}

      for {bearer, error} <- [
            {nil, "invalid_request"},
            {"inactive", "invalid_token"},
            {"wrong-issuer", "invalid_token"},
            {"wrong-audience", "invalid_token"},
            {"expired", "invalid_token"}
          ] do
        {401, headers, body} =
          post(host, "/mcp", session_id, response, bearer, opened.proof.deadline)

        assert %{"error" => ^error} = Jason.decode!(body)
        assert headers["www-authenticate"] =~ ~s(error="#{error}")
        assert_pending(host, opened, before_stats)
      end

      for bearer <- ["bob-reply", "alice-other-tenant"] do
        assert {404, _headers, body} =
                 post(host, "/mcp", session_id, response, bearer, opened.proof.deadline)

        assert Jason.decode!(body) == %{
                 "jsonrpc" => "2.0",
                 "id" => nil,
                 "error" => %{"code" => -32600, "message" => "Session not found"}
               }

        assert_pending(host, opened, before_stats)
      end

      # Same validated bearer, different real session: acceptance is a no-op,
      # never authority to satisfy a source captured from the Client session.
      assert {202, _headers, ""} =
               post(host, "/mcp", other_session, response, "alice-reply", opened.proof.deadline)

      assert_pending(host, opened, before_stats)

      # This proves a separate owned runtime/endpoint cannot settle this source.
      # Same-root forwarded-prefix isolation remains the separate Plug fixture.
      assert {404, _headers, _body} =
               post(sibling, "/other", session_id, response, "alice-reply", opened.proof.deadline)

      assert_pending(host, opened, before_stats)

      malformed = Map.put(response, "error", %{"code" => -32603, "message" => "Invalid"})

      assert {400, _headers, body} =
               post(host, "/mcp", session_id, malformed, "malformed-probe", opened.proof.deadline)

      assert %{"error" => %{"code" => -32600}} = Jason.decode!(body)
      refute_receive {:wire_introspected, "malformed-probe", _scope}, 0
      assert_pending(host, opened, before_stats)

      # Only the actual Client callback returns and sends its normal authenticated
      # response to the endpoint advertised by its persistent legacy SSE stream.
      assert now() < opened.proof.deadline
      send(client, {:wire_release_ping, %{"actualClient" => true}})
      assert_receive {:wire_server_reverse_result, {:ok, %{"actualClient" => true}}}, 1_000
      assert {:ok, %{"structuredContent" => %{"calls" => 1}}} = Task.await(caller, @root_ms)
      Process.delete(:oauth_wire_caller)
      assert_receive {:wire_introspected, "alice-tool", ""}, 1_000
      settled(host, now() + 1_000)
      assert_one_reverse(host, Source.lease(opened.proof.source))
      :ets.insert(host.policy, {:reply_only, false})
      assert calls(client) == 1
      refute_receive {:wire_handler_initialized, _extra_init}, 0
    end)
  end

  defp with_hosts(fun), do: with_hosts([], fun)

  defp with_hosts(options, fun) do
    Process.put(:oauth_wire_clients, [])
    Process.put(:oauth_wire_hosts, [])
    Process.delete(:oauth_wire_caller)

    try do
      host = host("/mcp", options)
      sibling = host("/other")
      fun.(host, sibling)
    after
      cleanup(now() + @cleanup_ms)
    end
  end

  defp host(path), do: host(path, [])

  defp host(path, options) do
    observer = self()
    policy = :ets.new(__MODULE__, [:set, :public])
    :ets.insert(policy, {:reply_only, false})

    {:ok, root} =
      Runtime.start_link(
        handler: Handler,
        handler_args: [observer: observer],
        transport: :http,
        init_timeout_ms: 1_000,
        shutdown_timeout_ms: 1_000,
        request_timeout_ms: @root_ms,
        max_concurrency: 1,
        max_queue: Keyword.get(options, :max_queue, 0),
        services: [sessions: [options: [session_ttl_ms: 10_000]]],
        http: [
          adapter: :cowboy,
          host: {127, 0, 0, 1},
          port: 0,
          path: path,
          protocol_mode: :legacy_only,
          legacy_http_sse: true,
          sse_mode: :stream,
          allowed_origins: :any,
          oauth_enabled: true,
          resource: "https://mcp.example",
          authorization_servers: ["https://issuer.example"],
          tenant_id: fn _conn, _request, token -> token.username end,
          auth_config: auth_config(observer, policy)
        ]
      )

    # Record the newly created owned root before any fallible observation.
    pending = %{
      root: root,
      policy: policy,
      path: path,
      root_monitor: Process.monitor(root),
      listener: nil,
      listener_monitor: nil,
      port: nil
    }

    Process.put(:oauth_wire_hosts, [pending | Process.get(:oauth_wire_hosts)])
    assert_receive {:wire_handler_initialized, _scheduler}, 1_000
    {:ok, runtime} = Runtime.ref(root)
    {:ok, info} = Transport.http_listener(runtime)
    assert info.adapter == :cowboy
    port = :ranch.get_port(info.ranch_ref)
    {:ok, sessions} = Runtime.service(runtime, :sessions)

    host = %{
      root: root,
      runtime: runtime,
      listener: info.listener,
      port: port,
      sessions: sessions,
      policy: policy,
      path: path,
      root_monitor: pending.root_monitor,
      listener_monitor: Process.monitor(info.listener)
    }

    Process.put(
      :oauth_wire_hosts,
      Enum.map(Process.get(:oauth_wire_hosts), fn
        %{root: ^root} -> host
        other -> other
      end)
    )

    host
  end

  defp client(host, hold) do
    {:ok, client} =
      Client.start_link(
        transport: :sse,
        url: "http://127.0.0.1:#{host.port}",
        protocol_mode: :legacy_only,
        protocol_version: "2024-11-05",
        headers: [{"authorization", "Bearer alice-tool"}],
        handler: {ClientHandler, [observer: self(), hold: hold, policy: host.policy]},
        establish_timeout: 2_000,
        handshake_timeout: 2_000,
        timeout: 1_000,
        request_timeout: 2_000,
        stream_handshake_timeout: 2_000,
        stream_idle_timeout: 10_000,
        max_response_bytes: @max_http_bytes,
        max_stream_buffer_bytes: @max_http_bytes,
        max_request_bytes: @max_http_bytes,
        client_cleanup_timeout: 1_000,
        health_check_interval: nil,
        retry_policy: [],
        allowed_private_hosts: ["127.0.0.1"]
      )

    entry = %{pid: client, monitor: Process.monitor(client)}
    Process.put(:oauth_wire_clients, [entry | Process.get(:oauth_wire_clients)])
    settled(host, now() + 1_000)
    client
  end

  defp auth_config(observer, policy) do
    %{
      realm: "reverse-oauth-wire",
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
          claims = claims(token)

          claims =
            if token == "alice-tool" and :ets.lookup(policy, :reply_only) == [{:reply_only, true}] do
              Map.put(claims, :scope, "")
            else
              claims
            end

          send(observer, {:wire_introspected, token, Map.get(claims, :scope)})
          {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], Jason.encode!(claims)}}
        end
      ]
    }
  end

  defp claims("inactive"), do: %{active: false}

  defp claims(token) do
    t = System.system_time(:second)

    claims = %{
      active: true,
      sub: if(token == "bob-reply", do: "bob", else: "alice"),
      username: if(token == "alice-other-tenant", do: "tenant-other", else: "tenant-a"),
      iss: "https://issuer.example",
      aud: "https://mcp.example",
      exp: t + 60,
      nbf: t - 60,
      scope: ""
    }

    case token do
      "alice-tool" ->
        Map.put(
          claims,
          :scope,
          "mcp:tools:execute:ping mcp:tools:execute:peek mcp:sessions:listen"
        )

      "wrong-issuer" ->
        Map.put(claims, :iss, "https://other-issuer.example")

      "wrong-audience" ->
        Map.put(claims, :aud, "https://other-resource.example")

      "expired" ->
        Map.put(claims, :exp, t - 1)

      _ ->
        claims
    end
  end

  defp initialize_raw(host) do
    value = %{
      "jsonrpc" => "2.0",
      "id" => "other-initialize",
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2024-11-05",
        "clientInfo" => %{"name" => "other-authentic-session", "version" => "2"},
        "capabilities" => %{}
      }
    }

    {200, headers, body} = post(host, host.path, nil, value, "alice-tool", now() + @root_ms)
    assert %{"id" => "other-initialize", "result" => _result} = Jason.decode!(body)
    id = Map.fetch!(headers, "mcp-session-id")
    assert is_binary(id) and byte_size(id) > 0
    id
  end

  defp pending(host, worker) do
    {:ok, gateway} = HTTPGateway.address(host.runtime)
    pending = :sys.get_state(gateway, 500).reverse.pending
    assert map_size(pending) == 1
    [{control, proof}] = Map.to_list(pending)
    assert proof.producer == worker and proof.response_token == nil
    assert :atomics.get(proof.phase, 1) == 0
    %{control: control, proof: proof}
  end

  defp assert_pending(host, opened, stats) do
    assert now() < opened.proof.deadline
    {:ok, gateway} = HTTPGateway.address(host.runtime)

    assert :sys.get_state(gateway, remaining(opened.proof.deadline)).reverse.pending[
             opened.control
           ] ==
             opened.proof

    assert :atomics.get(opened.proof.phase, 1) == 0
    assert match?(%{active: 1, response_bytes: 0}, Runtime.stats!(host.runtime))
    assert {:ok, ^stats} = SessionManager.get_stats(host.sessions, [])
    refute_receive {:wire_server_reverse_result, _result}, 0
  end

  defp assert_one_reverse(host, lease) do
    {:ok, %{events: events}} = SessionManager.replay_page(host.sessions, lease, nil, [])
    assert Enum.count(events, &(&1.data["method"] == "ping")) == 1

    assert Enum.count(
             events,
             &match?(
               %{"structuredContent" => %{"calls" => 1}},
               Map.get(&1.data, "result")
             )
           ) == 1
  end

  defp calls(client) do
    {:ok, %{"structuredContent" => %{"calls" => count}}} =
      Client.call_tool(client, "peek", %{}, format: :map, timeout: @root_ms, retry_policy: false)

    count
  end

  defp settled(host, deadline) do
    case Runtime.stats(host.runtime) do
      {:ok, %{reserved: 0, response_bytes: 0}} ->
        :ok

      _ ->
        assert now() < deadline
        Process.sleep(5)
        settled(host, deadline)
    end
  end

  defp post(host, path, session, value, bearer, deadline) do
    body = Jason.encode!(value)
    assert byte_size(body) <= @max_http_bytes

    headers = [
      {"host", "127.0.0.1:#{host.port}"},
      {"connection", "close"},
      {"content-type", "application/json"},
      {"accept", "application/json"},
      {"content-length", Integer.to_string(byte_size(body))},
      {"mcp-protocol-version", "2024-11-05"}
    ]

    headers = if session, do: [{"mcp-session-id", session} | headers], else: headers
    headers = if bearer, do: [{"authorization", "Bearer " <> bearer} | headers], else: headers

    {:ok, socket} =
      :gen_tcp.connect(
        {127, 0, 0, 1},
        host.port,
        [:binary, active: false],
        min(200, remaining(deadline))
      )

    try do
      :ok = :inet.setopts(socket, send_timeout: remaining(deadline), send_timeout_close: true)

      :ok =
        :gen_tcp.send(socket, [
          "POST ",
          path,
          " HTTP/1.1\r\n",
          Enum.map(headers, fn {k, v} -> [k, ": ", v, "\r\n"] end),
          "\r\n",
          body
        ])

      receive_response(socket, "", deadline)
    after
      :gen_tcp.close(socket)
    end
  end

  defp receive_response(socket, buffer, deadline) do
    assert byte_size(buffer) <= @max_http_bytes

    case :binary.split(buffer, "\r\n\r\n") do
      [header, body] ->
        [status | lines] = String.split(header, "\r\n")
        ["HTTP/1.1", code | _] = String.split(status, " ")

        headers =
          Map.new(lines, fn line ->
            [name, value] = String.split(line, ":", parts: 2)
            {String.downcase(name), String.trim(value)}
          end)

        length = headers |> Map.get("content-length", "0") |> String.to_integer()
        assert length in 0..@max_http_bytes
        assert not Map.has_key?(headers, "transfer-encoding")

        if byte_size(body) >= length do
          {String.to_integer(code), headers, binary_part(body, 0, length)}
        else
          recv_more(socket, buffer, deadline)
        end

      _ ->
        recv_more(socket, buffer, deadline)
    end
  end

  defp recv_more(socket, buffer, deadline) do
    {:ok, bytes} = :gen_tcp.recv(socket, 0, remaining(deadline))
    assert byte_size(buffer) + byte_size(bytes) <= @max_http_bytes
    receive_response(socket, buffer <> bytes, deadline)
  end

  defp cleanup(deadline) do
    # Release only our own held callback; public cleanup remains authoritative.
    for entry <- Process.get(:oauth_wire_clients, []) do
      send(entry.pid, {:wire_release_ping, %{}})
    end

    # Dispatch the bounded public root stops before Task/Client/DOWN/refusal
    # observations can consume this same overall cutoff. A stalled earlier stop
    # or caller suspension can still leave insufficient budget for a later stop;
    # that remains explicitly unconfirmed, never a cleanup success.
    root_stop_failures =
      Enum.flat_map(Process.get(:oauth_wire_hosts, []), fn host ->
        try do
          assert remaining(deadline) >= 1_000
          assert :ok = Runtime.stop(host.root)
          []
        rescue
          _error -> [:owned_root_stop_unconfirmed]
        catch
          _kind, _reason -> [:owned_root_stop_unconfirmed]
        end
      end)

    caller_failures =
      if caller = Process.get(:oauth_wire_caller) do
        try do
          # This is the test's own request Task, not a library child or borrowed host.
          _ =
            Task.yield(caller, min(500, remaining(deadline))) ||
              Task.shutdown(caller, :brutal_kill)

          []
        rescue
          _error -> [:request_task_cleanup_unconfirmed]
        catch
          _kind, _reason -> [:request_task_cleanup_unconfirmed]
        end
      else
        []
      end

    client_failures =
      Enum.flat_map(Process.get(:oauth_wire_clients, []), fn %{pid: client, monitor: monitor} ->
        try do
          assert remaining(deadline) >= 1_000
          assert :ok = Client.stop(client)
          assert_receive {:DOWN, ^monitor, :process, ^client, _reason}, remaining(deadline)
          []
        rescue
          _error -> [:client_cleanup_unconfirmed]
        catch
          _kind, _reason -> [:client_cleanup_unconfirmed]
        end
      end)

    root_failures =
      Enum.flat_map(Process.get(:oauth_wire_hosts, []), fn host ->
        try do
          # Observe the already-attempted stop; do not renew its public budget.
          root = host.root
          root_monitor = host.root_monitor
          listener = host.listener
          listener_monitor = host.listener_monitor
          assert_receive {:DOWN, ^root_monitor, :process, ^root, _reason}, remaining(deadline)

          if is_pid(listener) and is_reference(listener_monitor) and is_integer(host.port) do
            assert_receive {:DOWN, ^listener_monitor, :process, ^listener, _reason},
                           remaining(deadline)

            refused(host.port, deadline)
            []
          else
            # Missing observations remain unconfirmed after public root cleanup.
            [:listener_cleanup_observation_unconfirmed]
          end
        rescue
          _error -> [:owned_root_cleanup_unconfirmed]
        catch
          _kind, _reason -> [:owned_root_cleanup_unconfirmed]
        after
          :ets.delete(host.policy)
        end
      end)

    Process.delete(:oauth_wire_clients)
    Process.delete(:oauth_wire_hosts)
    Process.delete(:oauth_wire_caller)
    assert root_stop_failures ++ caller_failures ++ client_failures ++ root_failures == []
  end

  defp refused(port, deadline) do
    case :gen_tcp.connect(
           {127, 0, 0, 1},
           port,
           [:binary, active: false],
           min(50, remaining(deadline))
         ) do
      {:error, :econnrefused} ->
        :ok

      {:ok, socket} ->
        :gen_tcp.close(socket)
        Process.sleep(5)
        refused(port, deadline)

      _transitional ->
        Process.sleep(5)
        refused(port, deadline)
    end
  end

  defp remaining(deadline) do
    ms = deadline - now()
    assert ms > 0
    ms
  end

  defp now, do: System.monotonic_time(:millisecond)
end
