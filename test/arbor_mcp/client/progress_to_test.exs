defmodule Arbor.MCP.Client.ProgressToTest do
  # `progress_to: pid` also sends a request's progress to `pid`, as
  # `{:arbor_mcp_progress, client, progress_token, params}`, so a process that
  # forwards the request for another client, such as a gateway, can relay it.
  #
  # The first part runs against arbor_mcp servers over every transport that
  # carries progress: modern and legacy Streamable HTTP (a Runtime-mounted
  # HttpPlug on Bandit), stdio, BEAM and the in-process test transport. The
  # second part scripts the server's messages to pin down when the client
  # delivers.
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.RequestHandler
  alias Arbor.MCP.Error.{ProtocolError, ValidationError}
  alias Arbor.MCP.Server.{Context, HandlerServer, Runtime}

  @key :binary.copy(<<9>>, 32)
  @answers %{"name" => %{"action" => "accept", "content" => %{"name" => "Tom"}}}
  @fixture Path.expand("../../../priv/test/progress_stdio_server.exs", __DIR__)
  @project_root Path.expand("../../..", __DIR__)
  @form %{"elicitation" => %{"form" => %{}}}

  defmodule AppHandler do
    use Arbor.MCP.Server.Handler

    @name_schema %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}

    @impl true
    def handle_list_tools(_cursor, state) do
      tools =
        for name <- ~w(steps held ask),
            do: %{name: name, description: name, inputSchema: %{"type" => "object"}}

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("steps", _arguments, state) do
      results = for step <- 1..2, do: Context.report_progress(step, 2, "step #{step}")
      {:ok, %{content: [%{type: "text", text: inspect(results)}]}, state}
    end

    # Reports once, then waits for the test, so two calls are in flight at
    # the same time.
    def handle_call_tool("held", _arguments, state) do
      :ok = Context.report_progress(1, 2)
      send(state.owner, {:held, self(), Context.progress_token()})

      receive do
        :release -> :ok
      after
        5_000 -> :ok
      end

      :ok = Context.report_progress(2, 2)
      {:ok, %{content: [%{type: "text", text: "released"}]}, state}
    end

    # Reports progress on each MRTR round.
    def handle_call_tool("ask", _arguments, state) do
      case Context.input_responses() do
        nil ->
          :ok = Context.report_progress(1, 2, "asking")

          request = %{
            "method" => "elicitation/create",
            "params" => %{"message" => "Name?", "requestedSchema" => @name_schema}
          }

          {:input_required, %{"name" => request}, %{"step" => 1}, state}

        %{"name" => %{"content" => %{"name" => name}}} ->
          :ok = Context.report_progress(2, 2, "answered")
          {:ok, %{content: [%{type: "text", text: "Welcome, #{name}"}]}, state}
      end
    end
  end

  # The gateway from "Forwarding clients" in docs/CONFIGURATION.md, as it
  # stands there: it relays the upstream progress to its downstream client.
  defmodule GatewayHandler do
    use Arbor.MCP.Server.Handler

    alias Arbor.MCP.Server.Context

    @impl true
    def init(opts), do: {:ok, %{upstream: Keyword.fetch!(opts, :upstream)}}

    @impl true
    def handle_list_tools(_cursor, state),
      do: {:ok, [%{name: "ask", inputSchema: %{"type" => "object"}}], nil, state}

    @impl true
    def handle_call_tool(name, arguments, state) do
      sealed = Context.request_state() || %{}
      # One upstream progress token for every round of this call.
      token =
        sealed["token"] || "gateway-" <> Integer.to_string(System.unique_integer([:positive]))

      callback = self()

      opts = [
        mrtr: :manual,
        # What the downstream client declared for this request.
        client_capabilities: Context.current().client_capabilities,
        # nil on the first round; the downstream answers on its retry.
        input_responses: Context.input_responses(),
        request_state: sealed["upstream"],
        progress_token: token,
        progress_to: callback,
        format: :map
      ]

      task =
        Task.async(fn -> Arbor.MCP.Client.call_tool(state.upstream, name, arguments, opts) end)

      case relay_progress(task, state.upstream, token) do
        {:input_required, %{input_requests: requests, request_state: upstream}} ->
          {:input_required, requests, %{"upstream" => upstream, "token" => token}, state}

        {:ok, result} ->
          {:ok, result, state}

        {:error, reason} ->
          {:error, reason, state}
      end
    end

    defp relay_progress(%Task{ref: ref} = task, upstream, token) do
      receive do
        {:arbor_mcp_progress, ^upstream, ^token, %{"progress" => progress} = params} ->
          _ = Context.report_progress(progress, params["total"], params["message"])
          relay_progress(task, upstream, token)

        {^ref, result} ->
          Process.demonitor(ref, [:flush])
          result
      end
    end
  end

  defmodule Recorder do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state), do: {:error, "not used", state}

    @impl true
    def handle_elicitation_create(_message, _schema, state),
      do: {:ok, %{"action" => "accept", "content" => %{"name" => "Lin"}}, state}

    @impl true
    def handle_progress(_request_id, params, state) do
      send(state.owner, {:handler_progress, params})
      {:ok, state}
    end
  end

  # Keeps every request pending and reports what it was sent; the test sends
  # the server's messages itself.
  defmodule PendingTransport do
    def send_message(encoded, state) do
      send(state.owner, {:wire, Jason.decode!(encoded)})
      {:ok, state}
    end
  end

  @transports [
    {:http, :modern_only, []},
    {:http, :legacy_only, [use_sse: false]},
    {:http, :legacy_only, [use_sse: true]},
    {:stdio, :modern_only, []},
    {:stdio, :legacy_only, []},
    {:beam, :modern_only, []},
    {:beam, :legacy_only, []},
    {:test, :modern_only, []},
    {:test, :legacy_only, []}
  ]

  describe "delivery over each transport" do
    for {transport, mode, opts} <- @transports do
      test "#{transport}, #{mode}#{if opts == [], do: "", else: ", " <> inspect(opts)}" do
        client = connect(unquote(transport), unquote(mode), unquote(opts))

        assert {:ok, %{"content" => [%{"text" => "[:ok, :ok]"}]}} =
                 Client.call_tool(client, "steps", %{},
                   progress_to: self(),
                   progress_token: "job-1",
                   timeout: 10_000,
                   format: :map
                 )

        assert_receive {:arbor_mcp_progress, ^client, "job-1",
                        %{"progressToken" => "job-1", "progress" => 1, "total" => 2} = first}

        assert first["message"] == "step 1"
        assert_receive {:arbor_mcp_progress, ^client, "job-1", %{"progress" => 2}}

        # Alongside the client handler, not instead of it.
        assert_receive {:handler_progress, %{"progressToken" => "job-1", "progress" => 1}}
        assert_receive {:handler_progress, %{"progressToken" => "job-1", "progress" => 2}}
        refute_received {:arbor_mcp_progress, _client, _token, _params}
      end
    end
  end

  describe "against an arbor_mcp server" do
    test "a request without a progress token gets one" do
      client = connect(:test, :modern_only)

      assert {:ok, _result} =
               Client.call_tool(client, "steps", %{}, progress_to: self(), format: :map)

      assert_receive {:arbor_mcp_progress, ^client, "progress-" <> _ = token,
                      %{"progressToken" => token, "progress" => 1}}

      assert_receive {:arbor_mcp_progress, ^client, ^token, %{"progress" => 2}}
    end

    test "a dead target misses the progress, and the request goes on" do
      client = connect(:test, :legacy_only)
      target = spawn(fn -> :ok end)
      ref = Process.monitor(target)
      assert_receive {:DOWN, ^ref, :process, ^target, _reason}

      assert {:ok, %{"content" => [%{"text" => "[:ok, :ok]"}]}} =
               Client.call_tool(client, "steps", %{},
                 progress_to: target,
                 progress_token: "lost",
                 format: :map
               )

      assert_receive {:handler_progress, %{"progressToken" => "lost", "progress" => 2}}
      assert {:ok, _pong} = Client.ping(client)
    end

    for {transport, mode} <- [{:http, :modern_only}, {:test, :legacy_only}] do
      test "concurrent requests reach their own targets (#{transport}, #{mode})" do
        client = connect(unquote(transport), unquote(mode))

        calls =
          for name <- ["a", "b"] do
            Task.async(fn ->
              result =
                Client.call_tool(client, "held", %{},
                  progress_to: self(),
                  progress_token: name,
                  timeout: 10_000,
                  format: :map
                )

              {name, result, drain_progress()}
            end)
          end

        # Both are in flight at once before either is released.
        workers =
          for _call <- calls do
            assert_receive {:held, worker, token}, 5_000
            {token, worker}
          end

        assert workers |> Enum.map(&elem(&1, 0)) |> Enum.sort() == ["a", "b"]
        Enum.each(workers, fn {_token, worker} -> send(worker, :release) end)

        for {name, result, progress} <- Task.await_many(calls, 10_000) do
          assert {:ok, %{"content" => [%{"text" => "released"}]}} = result
          assert [{^client, ^name, 1}, {^client, ^name, 2}] = progress
        end
      end
    end

    test "automatic MRTR rounds share one generated token, and each round reports" do
      client = connect(:http, :modern_only)

      assert {:ok, %{"content" => [%{"text" => "Welcome, Lin"}]}} =
               Client.call_tool(client, "ask", %{}, progress_to: self(), format: :map)

      assert_receive {:arbor_mcp_progress, ^client, token, %{"message" => "asking"}}
      assert_receive {:arbor_mcp_progress, ^client, ^token, %{"message" => "answered"}}
    end

    test "manual MRTR rounds repeat the caller's token, and each round reports" do
      client = connect(:http, :modern_only)
      round = [mrtr: :manual, progress_to: self(), progress_token: "up-1", format: :map]

      assert {:input_required, %{request_state: state}} =
               Client.call_tool(client, "ask", %{}, round)

      assert_receive {:arbor_mcp_progress, ^client, "up-1", %{"message" => "asking"}}

      answers = %{"name" => %{"action" => "accept", "content" => %{"name" => "Tom"}}}

      assert {:ok, %{"content" => [%{"text" => "Welcome, Tom"}]}} =
               Client.call_tool(
                 client,
                 "ask",
                 %{},
                 round ++ [input_responses: answers, request_state: state]
               )

      assert_receive {:arbor_mcp_progress, ^client, "up-1", %{"message" => "answered"}}
    end
  end

  # On these transports progress is routed by token, so a round's
  # input_required answer must not hold back the token its continuation
  # reuses.
  describe "MRTR continuations over token-routed transports" do
    for transport <- [:test, :beam, :stdio] do
      test "an automatic continuation keeps its progress (#{transport})" do
        client = connect(unquote(transport), :modern_only)

        assert {:ok, %{"content" => [%{"text" => "Welcome, Lin"}]}} =
                 Client.call_tool(client, "ask", %{},
                   progress_to: self(),
                   timeout: 10_000,
                   format: :map
                 )

        assert_receive {:arbor_mcp_progress, ^client, token, %{"message" => "asking"}}
        assert_receive {:arbor_mcp_progress, ^client, ^token, %{"message" => "answered"}}
      end

      test "a manual continuation keeps its progress (#{transport})" do
        client = connect(unquote(transport), :modern_only)
        round = [mrtr: :manual, progress_to: self(), progress_token: "m-1", timeout: 10_000]

        assert {:input_required, %{request_state: state}} =
                 Client.call_tool(client, "ask", %{}, round)

        assert_receive {:arbor_mcp_progress, ^client, "m-1", %{"message" => "asking"}}

        answers = %{"name" => %{"action" => "accept", "content" => %{"name" => "Tom"}}}
        continuation = round ++ [input_responses: answers, request_state: state, format: :map]

        assert {:ok, %{"content" => [%{"text" => "Welcome, Tom"}]}} =
                 Client.call_tool(client, "ask", %{}, continuation)

        assert_receive {:arbor_mcp_progress, ^client, "m-1", %{"message" => "answered"}}
      end
    end
  end

  describe "a gateway" do
    for mode <- [:modern_only, :legacy_only] do
      test "relays the upstream progress of every round to its downstream client (#{mode})" do
        upstream = connect(:http, :modern_only)

        gateway =
          start_supervised!(
            {HandlerServer,
             handler: GatewayHandler,
             handler_args: [upstream: upstream],
             transport: :test,
             protocol_mode: unquote(mode),
             mrtr: true,
             request_state: [active_key_id: "gateway", keys: %{"gateway" => @key}]},
            id: make_ref()
          )

        downstream =
          start_client(transport: :test, server: gateway, protocol_mode: unquote(mode))

        assert {:ok, %{"content" => [%{"text" => "Welcome, Lin"}]}} =
                 Client.call_tool(downstream, "ask", %{},
                   progress_token: "down-1",
                   timeout: 10_000,
                   format: :map
                 )

        # The downstream client's own token, on both rounds.
        assert_receive {:handler_progress, %{"progressToken" => "down-1", "message" => "asking"}}

        assert_receive {:handler_progress,
                        %{"progressToken" => "down-1", "message" => "answered"}}
      end
    end
  end

  describe "options" do
    test "manual MRTR with progress_to needs an explicit progress token" do
      client = scripted()
      reason = "manual MRTR with progress_to needs an explicit :progress_token"

      for operation <- [
            &Client.call_tool(client, "ask", %{}, &1),
            &Client.get_prompt(client, "greeting", %{}, &1),
            &Client.read_resource(client, "memo://note", &1)
          ] do
        assert {:error, %ValidationError{field: :progress_token, reason: ^reason}} =
                 operation.(mrtr: :manual, progress_to: self())
      end

      refute_received {:wire, _request}

      # A request that can't pause has no rounds, so a generated token is fine.
      call = Task.async(fn -> Client.list_tools(client, mrtr: :manual, progress_to: self()) end)
      assert_receive {:wire, %{"params" => %{"_meta" => %{"progressToken" => "progress-" <> _}}}}
      Task.shutdown(call, :brutal_kill)
    end

    test "progress_to must be a pid, and nil leaves it unset" do
      client = scripted()

      assert_raise ArgumentError, "progress_to must be a pid", fn ->
        Client.call_tool(client, "steps", %{}, progress_to: :owner)
      end

      call = Task.async(fn -> Client.call_tool(client, "steps", %{}, progress_to: nil) end)
      assert_receive {:wire, %{"params" => %{"_meta" => meta}}}
      refute Map.has_key?(meta, "progressToken")
      Task.shutdown(call, :brutal_kill)
    end
  end

  describe "when the client delivers" do
    test "only while the request is pending: progress stops at the response" do
      client = scripted()
      caller = self()

      call =
        Task.async(fn ->
          Client.call_tool(client, "steps", %{},
            progress_to: caller,
            progress_token: "t",
            format: :map
          )
        end)

      assert_receive {:wire, %{"id" => id, "params" => %{"_meta" => %{"progressToken" => "t"}}}}

      progress(client, "t", 1)
      assert_receive {:arbor_mcp_progress, ^client, "t", %{"progress" => 1}}

      respond(client, id)
      assert {:ok, _result} = Task.await(call)

      progress(client, "t", 2)
      _state = :sys.get_state(client)
      refute_received {:arbor_mcp_progress, _client, _token, _params}
    end

    # The request stream path doesn't route by token, so the delivery itself
    # checks that the request is still pending.
    test "a request stream's progress for a settled request isn't delivered" do
      client = scripted()
      caller = self()

      call =
        Task.async(fn ->
          Client.call_tool(client, "steps", %{}, progress_to: caller, progress_token: "s")
        end)

      assert_receive {:wire, %{"id" => id}}
      respond(client, id)
      assert {:ok, _result} = Task.await(call)

      message = %{
        "method" => "notifications/progress",
        "params" => %{"progressToken" => "s", "progress" => 3}
      }

      state = :sys.get_state(client)
      assert {:noreply, _state} = RequestHandler.handle_request_stream_message(id, message, state)
      refute_received {:arbor_mcp_progress, _client, _token, _params}
    end

    test "a settled request's late progress never reaches a newer request that reuses its token" do
      client = scripted()
      test_pid = self()
      a_target = spawn_link(fn -> forward_to(test_pid, "a") end)
      b_target = spawn_link(fn -> forward_to(test_pid, "b") end)

      a = start_call(client, progress_to: a_target, progress_token: "shared")
      assert_receive {:wire, %{"id" => a_id}}
      respond(client, a_id)
      assert {:ok, _result} = Task.await(a)

      b = start_call(client, progress_to: b_target, progress_token: "shared")
      assert_receive {:wire, %{"id" => b_id}}

      # A's late notification, as legacy HTTP can send on the GET stream after
      # the POST's response.
      progress(client, "shared", 2)
      _state = :sys.get_state(client)
      refute_received {:forwarded, _target, _message}

      # Once A's token has gone the cleanup grace, B's own progress reaches B.
      :sys.replace_state(client, &%{&1 | progress_tombstones: %{}})
      progress(client, "shared", 1)

      assert_receive {:forwarded, "b",
                      {:arbor_mcp_progress, ^client, "shared", %{"progress" => 1}}}

      respond(client, b_id)
      assert {:ok, _result} = Task.await(b)
    end

    test "a request stream's progress naming another request's token reaches no target" do
      client = scripted()
      test_pid = self()

      ids =
        for name <- ["a", "b"] do
          target = spawn_link(fn -> forward_to(test_pid, name) end)
          start_call(client, progress_to: target, progress_token: name)

          assert_receive {:wire,
                          %{"id" => id, "params" => %{"_meta" => %{"progressToken" => ^name}}}}

          id
        end

      [a_id, _b_id] = ids
      state = :sys.get_state(client)

      RequestHandler.handle_request_stream_message(a_id, progress_message("b", 1), state)
      refute_received {:forwarded, _target, _message}

      RequestHandler.handle_request_stream_message(a_id, progress_message("a", 1), state)
      assert_receive {:forwarded, "a", {:arbor_mcp_progress, _client, "a", %{"progress" => 1}}}
      refute_received {:forwarded, _target, _message}

      for id <- ids, do: respond(client, id)
    end

    test "progress stops once the caller's own timeout has answered it, on either route" do
      client = scripted()

      assert {:error, :timeout} =
               Client.call_tool(client, "steps", %{},
                 progress_to: self(),
                 progress_token: "slow",
                 timeout: 50
               )

      assert_receive {:wire, %{"id" => id}}

      # The client keeps the request through its cleanup grace, but the
      # caller already has its answer.
      state = :sys.get_state(client)
      assert Map.has_key?(state.pending_requests, id)

      progress(client, "slow", 1)
      _state = :sys.get_state(client)
      RequestHandler.handle_request_stream_message(id, progress_message("slow", 1), state)
      refute_received {:arbor_mcp_progress, _client, _token, _params}
    end

    test "no targets remain once a burst of requests settles, however it ends" do
      client = scripted()
      :sys.replace_state(client, &%{&1 | default_timeout: 50})

      settle = [
        complete: fn id -> respond(client, id) end,
        error: fn id -> respond_error(client, id) end,
        cancel: fn id -> :ok = Client.send_cancelled(client, id, "stop") end,
        # The client's own timer answers a call without a timeout.
        client_timeout: fn _id -> :ok end
      ]

      calls =
        for {{how, settle}, n} <- Enum.with_index(settle) do
          call = start_call(client, progress_to: self(), progress_token: "#{how}-#{n}")
          assert_receive {:wire, %{"id" => id, "method" => "tools/call"}}
          settle.(id)
          call
        end

      # A caller's own timeout leaves the request to the cleanup grace.
      timed_out = start_call(client, progress_to: self(), progress_token: "caller", timeout: 50)
      assert_receive {:wire, %{"id" => _id, "method" => "tools/call"}}

      assert [{:ok, _}, {:error, _}, {:error, :cancelled}, {:error, :timeout}, {:error, :timeout}] =
               Task.await_many(calls ++ [timed_out], 5_000)

      assert :ok =
               Arbor.MCP.TestHelpers.wait_until(
                 fn -> :sys.get_state(client).progress_targets == %{} end,
                 timeout: 5_000
               )
    end

    # The caller-exit cancellation (cancel_on_caller_exit, on by default for a
    # modern request) settles the request through drop_pending/2, which drops
    # its target with it.
    test "a caller that exits leaves no target, and its target gets no more progress" do
      client = scripted()
      test_pid = self()
      target = spawn_link(fn -> forward_to(test_pid, "gone") end)

      call = start_call(client, progress_to: target, progress_token: "gone")
      assert_receive {:wire, %{"id" => id, "method" => "tools/call"}}

      progress(client, "gone", 1)
      assert_receive {:forwarded, "gone", {:arbor_mcp_progress, ^client, "gone", _params}}

      Task.shutdown(call, :brutal_kill)

      assert_receive {:wire,
                      %{"method" => "notifications/cancelled", "params" => %{"requestId" => ^id}}}

      state = :sys.get_state(client)
      refute Map.has_key?(state.pending_requests, id)
      assert state.progress_targets == %{}

      progress(client, "gone", 2)
      _state = :sys.get_state(client)
      refute_received {:forwarded, _target, _message}
    end

    test "an abandoned input_required round's token is held back from its deadline" do
      client = scripted()
      test_pid = self()

      round =
        start_call(client,
          mrtr: :manual,
          progress_to: self(),
          progress_token: "left",
          timeout: 150
        )

      assert_receive {:wire, %{"id" => id, "method" => "tools/call"}}

      result = %{
        "resultType" => "input_required",
        "inputRequests" => %{
          "name" => %{
            "method" => "elicitation/create",
            "params" => %{"message" => "Name?", "requestedSchema" => %{"type" => "object"}}
          }
        },
        "requestState" => "sealed"
      }

      send(
        client,
        {:transport_message, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})}
      )

      assert {:input_required, _round} = Task.await(round)

      # Reserved for a continuation until the round's deadline, and held
      # back for the cleanup grace after it.
      %{"left" => %{until: until}} = :sys.get_state(client).progress_reservations
      assert until > System.monotonic_time(:millisecond)

      # Nothing continued it by then: a request that reuses the token now
      # gets no connection-level progress for it.
      :ok =
        Arbor.MCP.TestHelpers.wait_until(fn -> System.monotonic_time(:millisecond) >= until end,
          timeout: 2_000
        )

      target = spawn_link(fn -> forward_to(test_pid, "late") end)
      reuse = start_call(client, progress_to: target, progress_token: "left")
      assert_receive {:wire, %{"id" => reuse_id, "method" => "tools/call"}}

      progress(client, "left", 1)
      _state = :sys.get_state(client)
      refute_received {:forwarded, _target, _message}

      respond(client, reuse_id)
      assert {:ok, _result} = Task.await(reuse)
    end

    # The caller's monotonic clock may be another node's: the client measures
    # the caller's deadline on its own clock, from the relative timeout.
    test "a remote caller's deadline is taken on the client's clock" do
      client = scripted()
      state = :sys.get_state(client)
      caller = remote_pid()

      # A caller node whose monotonic clock trails this one by a minute.
      meta = %{
        timeout: 30_000,
        deadline: System.monotonic_time(:millisecond) - 60_000,
        progress_to: self(),
        cancel_on_caller_exit: false,
        cache_mode: :bypass
      }

      params = %{"name" => "steps", "arguments" => %{}, "_meta" => %{"progressToken" => "far"}}

      assert {:noreply, state} =
               RequestHandler.handle_request(
                 "tools/call",
                 params,
                 {caller, make_ref()},
                 state,
                 meta
               )

      assert_receive {:wire, %{"method" => "tools/call"}}

      message = Jason.encode!(Map.put(progress_message("far", 1), "jsonrpc", "2.0"))
      RequestHandler.parse_transport_message(message, state)
      assert_received {:arbor_mcp_progress, _client, "far", %{"progress" => 1}}
    end

    test "a manual continuation that omits progress_to gets the round's target back" do
      client = scripted()
      test_pid = self()
      first = spawn_link(fn -> forward_to(test_pid, "first") end)

      id = await_round(client, progress_to: first, progress_token: "c", request_state: "rs-1")

      continuation =
        start_call(client,
          mrtr: :manual,
          progress_token: "c",
          input_responses: @answers,
          request_state: "rs-1",
          timeout: 5_000
        )

      assert_receive {:wire, %{"id" => next_id, "params" => %{"requestState" => "rs-1"}}}
      refute next_id == id

      # On either route.
      progress(client, "c", 2)

      assert_receive {:forwarded, "first",
                      {:arbor_mcp_progress, ^client, "c", %{"progress" => 2}}}

      state = :sys.get_state(client)
      RequestHandler.handle_request_stream_message(next_id, progress_message("c", 3), state)

      assert_receive {:forwarded, "first",
                      {:arbor_mcp_progress, _client, "c", %{"progress" => 3}}}

      respond(client, next_id)
      assert {:ok, _result} = Task.await(continuation)
    end

    test "a manual continuation that names its own progress_to target uses it" do
      client = scripted()
      test_pid = self()
      first = spawn_link(fn -> forward_to(test_pid, "first") end)
      second = spawn_link(fn -> forward_to(test_pid, "second") end)

      _id = await_round(client, progress_to: first, progress_token: "o", request_state: "rs-1")

      continuation =
        start_call(client,
          mrtr: :manual,
          progress_to: second,
          progress_token: "o",
          input_responses: @answers,
          request_state: "rs-1",
          timeout: 5_000
        )

      assert_receive {:wire, %{"id" => next_id, "params" => %{"requestState" => "rs-1"}}}
      progress(client, "o", 2)
      assert_receive {:forwarded, "second", {:arbor_mcp_progress, ^client, "o", _params}}
      refute_received {:forwarded, "first", _message}

      respond(client, next_id)
      assert {:ok, _result} = Task.await(continuation)
    end

    test "only the round's own continuation can claim its reserved token" do
      client = scripted()
      test_pid = self()
      round_target = spawn_link(fn -> forward_to(test_pid, "round") end)
      other_target = spawn_link(fn -> forward_to(test_pid, "other") end)

      _id =
        await_round(client, progress_to: round_target, progress_token: "t", request_state: "rs-A")

      # An unrelated call, and a continuation presenting another round's
      # state, start, but get none of the round's late progress.
      for {name, opts} <- [
            {"other", []},
            {"steps",
             [mrtr: :manual, input_responses: @answers, request_state: "rs-X", timeout: 5_000]}
          ] do
        call =
          Task.async(fn ->
            Client.call_tool(
              client,
              name,
              %{},
              [progress_to: other_target, progress_token: "t"] ++ opts
            )
          end)

        assert_receive {:wire, %{"id" => id, "method" => "tools/call"}}
        progress(client, "t", 1)
        _state = :sys.get_state(client)
        refute_received {:forwarded, _target, _message}

        respond(client, id)
        assert {:ok, _result} = Task.await(call)
      end
    end

    test "an input_required round's reservation never ends an earlier request's tombstone" do
      client = scripted()
      test_pid = self()
      old_target = spawn_link(fn -> forward_to(test_pid, "old") end)
      new_target = spawn_link(fn -> forward_to(test_pid, "new") end)

      # A settles, so its token is tombstoned for the cleanup grace.
      old = start_call(client, progress_to: old_target, progress_token: "r")
      assert_receive {:wire, %{"id" => old_id}}
      respond(client, old_id)
      assert {:ok, _result} = Task.await(old)

      # B reuses the token, returns input_required within the grace, and its
      # continuation claims B's reservation.
      _id =
        await_round(client, progress_to: new_target, progress_token: "r", request_state: "rs-B")

      continuation =
        start_call(client,
          mrtr: :manual,
          progress_token: "r",
          input_responses: @answers,
          request_state: "rs-B",
          timeout: 5_000
        )

      assert_receive {:wire, %{"id" => next_id, "params" => %{"requestState" => "rs-B"}}}

      # A's late progress still reaches no target while A's tombstone lasts.
      progress(client, "r", 9)
      _state = :sys.get_state(client)
      refute_received {:forwarded, _target, _message}

      # Once it has gone, B's continuation gets its own progress.
      :sys.replace_state(client, &%{&1 | progress_tombstones: %{}})
      progress(client, "r", 1)
      assert_receive {:forwarded, "new", {:arbor_mcp_progress, ^client, "r", %{"progress" => 1}}}

      respond(client, next_id)
      assert {:ok, _result} = Task.await(continuation)
    end

    # The client monitors a target's caller whatever cancel_on_caller_exit
    # says. A pid on a node this VM isn't connected to stands in for a
    # remote caller whose node connection is lost: its monitor fires with
    # :noconnection.
    test "a remote caller that can't be reached stops getting progress" do
      client = scripted()

      meta = %{
        timeout: 30_000,
        deadline: System.monotonic_time(:millisecond) + 30_000,
        progress_to: self(),
        cancel_on_caller_exit: false,
        cache_mode: :bypass
      }

      params = %{"name" => "steps", "arguments" => %{}, "_meta" => %{"progressToken" => "far"}}

      send(
        client,
        {:"$gen_call", {remote_pid(), make_ref()}, {:request, "tools/call", params, meta}}
      )

      assert_receive {:wire, %{"id" => id, "method" => "tools/call"}}

      state = :sys.get_state(client)
      assert Map.has_key?(state.pending_requests, id)
      assert %{pid: nil} = state.progress_targets[id]

      progress(client, "far", 1)
      _state = :sys.get_state(client)
      refute_received {:arbor_mcp_progress, _client, _token, _params}
    end

    test "a local caller that exits without cancelling stops getting progress" do
      client = scripted()
      test_pid = self()
      target = spawn_link(fn -> forward_to(test_pid, "kept") end)

      call =
        start_call(client,
          progress_to: target,
          progress_token: "kept",
          cancel_on_caller_exit: false
        )

      assert_receive {:wire, %{"id" => id, "method" => "tools/call"}}
      ref = Process.monitor(call.pid)
      Task.shutdown(call, :brutal_kill)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}

      state = :sys.get_state(client)
      assert Map.has_key?(state.pending_requests, id)
      assert %{pid: nil} = state.progress_targets[id]

      progress(client, "kept", 1)
      _state = :sys.get_state(client)
      refute_received {:forwarded, _target, _message}
    end

    test "a malformed input_required round neither crashes the client nor is reserved" do
      client = scripted()
      monitor = Process.monitor(client)

      sibling = start_call(client, progress_to: self(), progress_token: "sibling")
      assert_receive {:wire, %{"id" => sibling_id}}

      bad =
        start_call(client,
          mrtr: :manual,
          progress_to: self(),
          progress_token: "bad",
          timeout: 5_000
        )

      assert_receive {:wire, %{"id" => bad_id}}

      respond_with(client, bad_id, %{"resultType" => "input_required", "inputRequests" => nil})

      assert {:error, %ProtocolError{message: "inputRequests must be an object"}} =
               Task.await(bad)

      state = :sys.get_state(client)
      refute Map.has_key?(state.progress_reservations, "bad")
      assert Map.has_key?(state.progress_tombstones, "bad")

      respond(client, sibling_id)
      assert {:ok, _result} = Task.await(sibling)
      refute_received {:DOWN, ^monitor, :process, _pid, _reason}
    end

    test "a requestState over the request's byte limit is neither hashed nor reserved" do
      client = scripted()

      call =
        start_call(client,
          mrtr: :manual,
          progress_to: self(),
          progress_token: "big",
          max_mrtr_bytes: 128,
          timeout: 5_000
        )

      assert_receive {:wire, %{"id" => id}}
      respond_with(client, id, input_required_result(String.duplicate("s", 200)))
      assert {:error, %ProtocolError{message: "MRTR byte limit exceeded"}} = Task.await(call)

      state = :sys.get_state(client)
      refute Map.has_key?(state.progress_reservations, "big")
      assert Map.has_key?(state.progress_tombstones, "big")
    end

    test "a continuation whose request_state is over its byte limit claims nothing" do
      client = scripted()
      test_pid = self()
      target = spawn_link(fn -> forward_to(test_pid, "round") end)
      request_state = String.duplicate("r", 100)

      _id =
        await_round(client,
          progress_to: target,
          progress_token: "cap",
          request_state: request_state
        )

      continuation =
        start_call(client,
          mrtr: :manual,
          progress_token: "cap",
          input_responses: %{"name" => %{"action" => "decline"}},
          request_state: request_state,
          max_mrtr_bytes: 64,
          timeout: 5_000
        )

      assert_receive {:wire, %{"id" => next_id, "params" => %{"requestState" => ^request_state}}}
      progress(client, "cap", 1)
      _state = :sys.get_state(client)
      refute_received {:forwarded, _target, _message}

      respond(client, next_id)
      assert {:ok, _result} = Task.await(continuation)
    end

    test "expired tombstones and reservations are swept even when no request follows" do
      client = scripted()

      for n <- 1..5 do
        call = start_call(client, progress_to: self(), progress_token: "done-#{n}")
        assert_receive {:wire, %{"id" => id}}
        respond(client, id)
        assert {:ok, _result} = Task.await(call)
      end

      for n <- 1..3 do
        await_round(client,
          progress_to: self(),
          progress_token: "left-#{n}",
          request_state: "rs-#{n}",
          timeout: 300
        )
      end

      state = :sys.get_state(client)
      assert map_size(state.progress_tombstones) == 5
      assert map_size(state.progress_reservations) == 3

      :ok =
        Arbor.MCP.TestHelpers.wait_until(
          fn ->
            state = :sys.get_state(client)
            state.progress_tombstones == %{} and state.progress_reservations == %{}
          end,
          timeout: 5_000
        )

      assert :sys.get_state(client).progress_sweep == nil
    end

    test "input request ids over the byte limit are neither kept nor reserved" do
      client = scripted()
      request = %{"method" => "roots/list", "params" => %{}}
      ids = for n <- 1..2, into: %{}, do: {"#{n}" <> String.duplicate("i", 256 * 1024), request}

      call =
        start_call(client,
          mrtr: :manual,
          progress_to: self(),
          progress_token: "ids",
          max_mrtr_bytes: 128,
          timeout: 5_000
        )

      assert_receive {:wire, %{"id" => id}}
      respond_with(client, id, %{"resultType" => "input_required", "inputRequests" => ids})
      assert {:error, %ProtocolError{message: "MRTR byte limit exceeded"}} = Task.await(call)

      state = :sys.get_state(client)
      refute Map.has_key?(state.progress_reservations, "ids")
      assert Map.has_key?(state.progress_tombstones, "ids")
    end

    test "a round without requestState is reserved by a digest of its ids, which its continuation matches" do
      client = scripted()
      test_pid = self()
      target = spawn_link(fn -> forward_to(test_pid, "ids") end)
      request = %{"method" => "elicitation/create", "params" => %{"message" => "?"}}

      round =
        start_call(client,
          mrtr: :manual,
          progress_to: target,
          progress_token: "d",
          timeout: 5_000
        )

      assert_receive {:wire, %{"id" => id}}

      respond_with(client, id, %{
        "resultType" => "input_required",
        "inputRequests" => %{"b" => request, "a" => request}
      })

      assert {:input_required, %{request_state: nil}} = Task.await(round)

      %{"d" => %{identity: {_round, {:inputs, digest}}}} =
        :sys.get_state(client).progress_reservations

      assert is_binary(digest) and byte_size(digest) == 32

      decline = %{"action" => "decline"}

      continuation =
        start_call(client,
          mrtr: :manual,
          progress_token: "d",
          input_responses: %{"a" => decline, "b" => decline},
          timeout: 5_000
        )

      assert_receive {:wire, %{"id" => next_id, "params" => %{"inputResponses" => _responses}}}
      progress(client, "d", 1)
      assert_receive {:forwarded, "ids", {:arbor_mcp_progress, ^client, "d", %{"progress" => 1}}}

      respond(client, next_id)
      assert {:ok, _result} = Task.await(continuation)
    end

    # The reviewer's race. The sweep timer (T1) fires, and its message is
    # queued while the client handles a late input_required answer whose
    # cutoff has already passed. Moving the timer earlier can't cancel T1, so
    # both messages arrive. Only the current one may sweep and arm again;
    # otherwise a second timer is left that reset_progress/1 doesn't cancel.
    test "a sweep queued before its timer moved neither sweeps nor arms a second timer" do
      client = scripted()

      # F: a reservation that outlasts the race, so each sweep arms again.
      _f =
        await_round(client,
          progress_to: self(),
          progress_token: "f",
          request_state: "rs-f",
          timeout: 3_000
        )

      # Y: a round whose caller times out before its answer comes.
      y =
        start_call(client,
          mrtr: :manual,
          progress_to: self(),
          progress_token: "y",
          cancel_on_caller_exit: false,
          timeout: 50
        )

      assert_receive {:wire, %{"id" => y_id}}
      assert {:error, :timeout} = Task.await(y)

      # E: a settled request, whose tombstone arms the timer soonest.
      e = start_call(client, progress_to: self(), progress_token: "e")
      assert_receive {:wire, %{"id" => e_id}}
      respond(client, e_id)
      assert {:ok, _result} = Task.await(e)
      t1 = elem(:sys.get_state(client).progress_sweep, 0)

      # Y's late answer is queued first, then T1 fires and queues its sweep.
      :ok = :sys.suspend(client)
      respond_with(client, y_id, input_required_result("rs-y"))
      :ok = Arbor.MCP.TestHelpers.wait_until(fn -> Process.read_timer(t1) == false end)
      :ok = :sys.resume(client)

      state = :sys.get_state(client)
      %{"f" => %{until: f_until}} = state.progress_reservations
      assert state.progress_sweep != nil

      # A reconnect resets the bookkeeping. No timer may outlive it.
      :sys.replace_state(client, &RequestHandler.reset_progress/1)
      :erlang.trace(client, true, [:receive])

      :ok =
        Arbor.MCP.TestHelpers.wait_until(
          fn -> System.monotonic_time(:millisecond) > f_until + 1_200 end,
          timeout: 10_000
        )

      _state = :sys.get_state(client)
      :erlang.trace(client, false, [:receive])
      refute Enum.any?(traced_messages(client), &sweep?/1)
    end

    test "a sweep message from before a reconnect does nothing" do
      client = scripted()
      _id = await_round(client, progress_to: self(), progress_token: "old", request_state: "rs-o")
      {_timer, _at, old_ref} = :sys.get_state(client).progress_sweep

      # The reconnect's teardown, then a new connection's hold.
      :sys.replace_state(client, &RequestHandler.reset_progress/1)
      call = start_call(client, progress_to: self(), progress_token: "new")
      assert_receive {:wire, %{"id" => id}}
      respond(client, id)
      assert {:ok, _result} = Task.await(call)

      before = :sys.get_state(client)
      send(client, {:progress_sweep, old_ref})
      after_stale = :sys.get_state(client)

      assert after_stale.progress_sweep == before.progress_sweep
      assert after_stale.progress_tombstones == before.progress_tombstones
      assert after_stale.progress_reservations == before.progress_reservations
    end

    test "each request's progress goes only to its own target" do
      client = scripted()
      test_pid = self()

      targets =
        for name <- ["x", "y"] do
          target = spawn_link(fn -> forward_to(test_pid, name) end)

          Task.async(fn ->
            Client.call_tool(client, "steps", %{}, progress_to: target, progress_token: name)
          end)

          assert_receive {:wire,
                          %{"id" => id, "params" => %{"_meta" => %{"progressToken" => ^name}}}}

          {name, id}
        end

      for {name, _id} <- Enum.reverse(targets), do: progress(client, name, 1)

      assert_receive {:forwarded, "x", {:arbor_mcp_progress, ^client, "x", _params}}
      assert_receive {:forwarded, "y", {:arbor_mcp_progress, ^client, "y", _params}}
      _state = :sys.get_state(client)
      refute_received {:forwarded, _target, _message}

      for {_name, id} <- targets, do: respond(client, id)
    end
  end

  # Servers and clients

  defp connect(transport, mode, opts \\ [])

  defp connect(:http, mode, opts) do
    runtime =
      start_supervised!(
        {Runtime,
         handler: AppHandler,
         handler_args: [owner: self()],
         transport: :mounted_http,
         protocol_mode: mode},
        id: make_ref()
      )

    plug_opts = [
      runtime: runtime,
      path: "/mcp",
      protocol_mode: mode,
      sse_mode: :stream,
      mrtr: true,
      request_state: [active_key_id: "progress", keys: %{"progress" => @key}],
      principal_id: "progress-test"
    ]

    listener =
      start_supervised!(
        {Bandit,
         plug: {Arbor.MCP.HttpPlug, plug_opts}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)

    start_client(
      [
        transport: :http,
        url: "http://127.0.0.1:#{port}/mcp",
        protocol_mode: mode,
        use_sse: false,
        security: %{origin: nil}
      ] ++ opts
    )
  end

  defp connect(:stdio, mode, _opts) do
    mix = System.find_executable("mix") || flunk("mix executable is required")

    start_client(
      transport: :stdio,
      command: [mix, "run", "--no-compile", "--no-start", @fixture, Atom.to_string(mode)],
      cd: @project_root,
      env: mix_child_env(),
      protocol_mode: mode
    )
  end

  defp connect(transport, mode, _opts) when transport in [:beam, :test] do
    server =
      start_supervised!(
        {HandlerServer,
         handler: AppHandler,
         handler_args: [owner: self()],
         transport: transport,
         protocol_mode: mode,
         mrtr: true,
         request_state: [active_key_id: "progress", keys: %{"progress" => @key}]},
        id: make_ref()
      )

    start_client(transport: transport, server: server, protocol_mode: mode)
  end

  # The stdio transport isolates the child's environment; the fixture needs
  # the same Mix setup as this VM (see ModernStdioTest).
  defp mix_child_env do
    [{"MIX_ENV", "test"}] ++
      for name <- ["MIX_HOME", "MIX_ARCHIVES", "MIX_DEPS_PATH", "MIX_BUILD_PATH"],
          value = System.get_env(name),
          do: {name, value}
  end

  defp start_client(opts) do
    defaults = [
      capabilities: @form,
      handler: {Recorder, [owner: self()]},
      health_check_interval: nil,
      reconnect: false
    ]

    {:ok, client} = Client.start_link(Keyword.merge(defaults, opts))

    on_exit(fn ->
      try do
        Client.disconnect(client)
      catch
        :exit, _reason -> :ok
      end
    end)

    client
  end

  # A ready modern client whose requests stay pending until the test answers.
  defp scripted do
    owner = self()

    client =
      start_supervised!(
        {Client,
         _skip_connect: true,
         handler: {Recorder, [owner: owner]},
         capabilities: @form,
         health_check_interval: nil},
        id: make_ref()
      )

    :sys.replace_state(client, fn state ->
      %{
        state
        | transport_mod: PendingTransport,
          transport_state: %{owner: owner},
          protocol_version: "2026-07-28",
          connection_status: :ready,
          initialized: true
      }
    end)

    client
  end

  defp progress(client, token, progress) do
    message = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/progress",
      "params" => %{"progressToken" => token, "progress" => progress}
    }

    send(client, {:transport_message, Jason.encode!(message)})
  end

  # A pid on a node this VM isn't connected to.
  defp remote_pid do
    node = "remote@nowhere"
    :erlang.binary_to_term(<<131, 88, 119, byte_size(node), node::binary, 1::32, 0::32, 1::32>>)
  end

  # A manual round of "steps" that the scripted server answers with
  # input_required and `request_state`; returns the round's request id.
  defp await_round(client, opts) do
    {request_state, opts} = Keyword.pop!(opts, :request_state)
    round = start_call(client, Keyword.merge([mrtr: :manual, timeout: 5_000], opts))
    assert_receive {:wire, %{"id" => id, "method" => "tools/call"}}
    respond_with(client, id, input_required_result(request_state))
    assert {:input_required, %{request_state: ^request_state}} = Task.await(round)
    id
  end

  defp input_required_result(request_state) do
    %{
      "resultType" => "input_required",
      "inputRequests" => %{
        "name" => %{
          "method" => "elicitation/create",
          "params" => %{"message" => "Name?", "requestedSchema" => %{"type" => "object"}}
        }
      },
      "requestState" => request_state
    }
  end

  defp traced_messages(client, acc \\ []) do
    receive do
      {:trace, ^client, :receive, message} -> traced_messages(client, [message | acc])
    after
      0 -> acc
    end
  end

  defp sweep?(:progress_sweep), do: true
  defp sweep?({:progress_sweep, _ref}), do: true
  defp sweep?(_message), do: false

  defp respond_with(client, id, result) do
    message = %{"jsonrpc" => "2.0", "id" => id, "result" => result}
    send(client, {:transport_message, Jason.encode!(message)})
  end

  defp start_call(client, opts) do
    Task.async(fn -> Client.call_tool(client, "steps", %{}, opts) end)
  end

  defp progress_message(token, progress) do
    %{
      "method" => "notifications/progress",
      "params" => %{"progressToken" => token, "progress" => progress}
    }
  end

  defp respond_error(client, id) do
    error = %{"code" => -32_603, "message" => "failed"}

    send(
      client,
      {:transport_message, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "error" => error})}
    )
  end

  defp respond(client, id) do
    result = %{"resultType" => "complete", "content" => []}

    send(
      client,
      {:transport_message, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})}
    )
  end

  defp forward_to(test_pid, name) do
    receive do
      message ->
        send(test_pid, {:forwarded, name, message})
        forward_to(test_pid, name)
    end
  end

  defp drain_progress(acc \\ []) do
    receive do
      {:arbor_mcp_progress, client, token, %{"progress" => progress}} ->
        drain_progress([{client, token, progress} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
