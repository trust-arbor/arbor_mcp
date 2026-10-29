defmodule Arbor.MCP.Client.HTTPAuthGenerationTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.{Deadline, HTTPAuth}
  alias Arbor.MCP.Transport.HTTP

  @moduletag :reauth_round6

  for kind <- [:post, :request, :subscription] do
    @tag :reauth_round8
    test "a rejected cached static credential is refused before another #{kind} POST" do
      bypass = Bypass.open()
      owner = self()

      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        send(owner, :static_token_posted)
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer A"]
        conn |> Plug.Conn.put_resp_header("www-authenticate", "Basic") |> Plug.Conn.resp(401, "")
      end)

      {:ok, transport} =
        HTTP.connect(
          url: "http://127.0.0.1:#{bypass.port}/mcp",
          use_sse: false,
          auth_provider: {Arbor.MCP.Authorization.Provider.Static, token: "A"}
        )

      transport = HTTP.settle_protocol_era(transport, :modern, "2026-07-28")
      request = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call"})
      assert {:error, :unauthorized, retired} = HTTP.send_authenticated(request, transport)
      assert_receive :static_token_posted
      assert retired.access_token == nil

      result =
        if unquote(kind) == :post,
          do: HTTP.send_async(request, retired),
          else: HTTP.open_stream(request, retired, self(), stream_kind: unquote(kind))

      assert {:error, {:auth_refused, {:authentication_failed, :rejected_credential}},
              after_refusal} = result

      assert after_refusal.credential_generation == retired.credential_generation
      assert after_refusal.rejected_generation == retired.rejected_generation
      assert after_refusal.access_token == nil
      refute_received :static_token_posted
    end
  end

  for kind <- [:post, :stream] do
    @tag :reauth_round7
    test "#{kind} rejection notices require ownership and retire only the matching generation" do
      a = credential(%HTTP{headers: []}, "A")
      b = credential(a, "B")
      state = state(%{b | modern_streams: %{1 => self()}})

      message = fn id, generation ->
        {:http_credential_rejected, unquote(kind), self(), id, generation}
      end

      assert {:noreply, ^state} = Client.handle_info(message.(2, b.credential_generation), state)
      assert {:noreply, state} = Client.handle_info(message.(1, a.credential_generation), state)
      assert state.transport_state.access_token == "B"
      assert state.transport_state.rejected_generation == a.credential_generation
      assert {:noreply, state} = Client.handle_info(message.(1, b.credential_generation), state)
      assert state.transport_state.access_token == nil
      assert state.transport_state.rejected_generation == b.credential_generation
    end
  end

  for kind <- [:post, :health_ping, :request, :subscription] do
    test "#{kind} carries the sent credential generation through an authenticated retry" do
      kind = unquote(kind)
      bypass = Bypass.open()

      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        status =
          if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer A"], do: 401, else: 403

        conn
        |> Plug.Conn.put_resp_header(
          "www-authenticate",
          ~s(Bearer error="insufficient_scope", scope="read")
        )
        |> Plug.Conn.resp(status, "")
      end)

      {:ok, transport} = HTTP.connect(url: "http://127.0.0.1:#{bypass.port}/mcp", use_sse: false)
      transport = HTTP.settle_protocol_era(transport, :modern, "2026-07-28")
      a = credential(transport, "A")
      b = credential(a, "B")
      method = if kind == :health_ping, do: "ping", else: "tools/call"
      message = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method})

      {pid, auth_kind} =
        if kind in [:post, :health_ping] do
          assert {:ok, _} = HTTP.send_async(message, a)
          assert_receive {:async_post_task, _monitor, pid, 1}
          {pid, :post}
        else
          assert {:ok, opened} = HTTP.open_stream(message, a, self(), stream_kind: kind)
          {opened.modern_streams[1], :stream}
        end

      monitor = Process.monitor(pid)
      {ref, challenge} = receive_challenge(auth_kind, pid)
      assert challenge.credential_generation == a.credential_generation
      HTTPAuth.reply(%{kind: auth_kind, pid: pid, ref: ref}, {:ok, "B"}, b)
      {ref, challenge} = receive_challenge(auth_kind, pid)
      assert challenge.credential_generation == b.credential_generation
      assert challenge.token == "B"
      reason = {:oauth_failed, :insufficient_scope}
      HTTPAuth.reply(%{kind: auth_kind, pid: pid, ref: ref}, {:error, reason}, b)

      if auth_kind == :post do
        assert_receive {:async_post_result, {:error, {:auth_refused, ^reason}}, _meta}
      else
        assert_receive {:modern_http_stream_closed, ^pid, 1, {:auth_refused, ^reason}}
      end

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    end
  end

  test "a delayed rejection of A followed by rejection of B cannot promote an old A result" do
    a = credential(%HTTP{headers: []}, "A")
    b = credential(a, "B")
    state = state(b)
    state = reject(state, a)
    assert state.transport_state == %{b | rejected_generation: a.credential_generation}
    assert state.transport_state.rejected_generation == a.credential_generation
    state = reject(state, b)
    assert state.transport_state.access_token == nil
    {state, worker, id, ref} = worker(state)
    state = HTTPAuth.result(state, worker, id, result(a))

    assert state.transport_state.access_token == nil
    assert state.transport_state.rejected_generation == b.credential_generation
    assert_receive {:http_post_auth_result, ^ref, {:error, {:oauth_failed, :stale_credential}}}
  end

  test "a rejection of A before or after B is promoted never retires B" do
    for order <- [:before, :after] do
      a = credential(%HTTP{headers: []}, "A")
      b = credential(a, "B")
      state = state(a)
      state = if order == :before, do: reject(state, a), else: state
      {state, worker, id, ref} = worker(state)
      state = HTTPAuth.result(state, worker, id, result(b))
      state = if order == :after, do: reject(state, a), else: state

      assert state.transport_state.access_token == "B"
      assert state.transport_state.credential_generation == b.credential_generation
      assert state.transport_state.rejected_generation == a.credential_generation
      generation = b.credential_generation

      assert_receive {:http_post_auth_result, ^ref,
                      {:ok, "B", %{credential_generation: ^generation}}}
    end
  end

  test "retired workers completing before or after the active worker cannot overwrite it" do
    for order <- [:before, :after] do
      a = credential(%HTTP{headers: []}, "A")
      b = credential(a, "B")
      {state, old, old_id, old_ref} = worker(state(a))
      monitor = Process.monitor(old)
      state = HTTPAuth.cancel_request(state, 1)
      assert_receive {:http_post_auth_result, ^old_ref, {:error, :stream_retired}}
      assert_receive {:DOWN, ^monitor, :process, ^old, :killed}
      {state, active, id, ref} = worker(state)

      if order == :before, do: assert(HTTPAuth.result(state, old, old_id, result(a)) == state)
      state = HTTPAuth.result(state, active, id, result(b))
      if order == :after, do: assert(HTTPAuth.result(state, old, old_id, result(a)) == state)
      assert state.transport_state.access_token == "B"
      assert_receive {:http_post_auth_result, ^ref, {:ok, "B", _}}
    end
  end

  test "one hundred rotations and rejections retain fixed-size auth state" do
    initial = state(credential(%HTTP{headers: []}, "token-000"))
    size = generation_state_size(initial)

    state =
      Enum.reduce(1..100, initial, fn cycle, acc ->
        previous_generation = acc.transport_state.credential_generation
        acc = reject(acc, acc.transport_state)
        token = "token-" <> String.pad_leading(Integer.to_string(cycle), 3, "0")
        fresh = credential(acc.transport_state, token)
        {acc, worker, id, ref} = worker(acc)
        acc = HTTPAuth.result(acc, worker, id, result(fresh))
        assert_receive {:http_post_auth_result, ^ref, {:ok, ^token, _}}
        assert acc.transport_state.credential_generation > previous_generation
        assert acc.transport_state.rejected_generation == previous_generation
        assert acc.http_auth.worker == nil
        assert acc.http_auth.waiters == %{}
        assert acc.http_auth.monitors == %{}
        assert generation_state_size(acc) == size
        acc
      end)

    assert state.transport_state.access_token == "token-100"
    assert HTTPAuth.retire(state).http_auth == %HTTPAuth{}
    assert HTTPAuth.retire(state).transport_state.rejected_generation == 0
  end

  test "a fresh exchange may reuse bearer bytes while receiving a new generation" do
    a = credential(%HTTP{headers: []}, "A")
    state = reject(state(a), a)
    fresh = credential(state.transport_state, "A")
    {state, worker, id, ref} = worker(state)
    state = HTTPAuth.result(state, worker, id, result(fresh))
    assert fresh.credential_generation > a.credential_generation
    assert state.transport_state.credential_generation == fresh.credential_generation
    assert state.transport_state.access_token == "A"
    assert_receive {:http_post_auth_result, ^ref, {:ok, "A", _}}
  end

  defp credential(transport, token),
    do: HTTP.put_oauth_token(transport, %{access_token: token, scope: "read"}, ["read"])

  defp generation_state_size(state),
    do:
      :erts_debug.size(
        {state.http_auth, state.transport_state.credential_generation,
         state.transport_state.rejected_generation}
      )

  defp receive_challenge(:post, pid) do
    assert_receive {:http_post_auth_challenge, ^pid, ref, challenge}, 2_000
    {ref, challenge}
  end

  defp receive_challenge(:stream, pid) do
    assert_receive {:modern_http_stream_auth_challenge, ^pid, 1, ref, challenge}, 2_000
    {ref, challenge}
  end

  defp result(transport),
    do: {:ok, transport.access_token, transport.granted_scopes, transport.credential_generation}

  defp reject(state, transport),
    do:
      HTTPAuth.reject_token(state, %{
        status: 401,
        token: transport.access_token,
        credential_generation: transport.credential_generation
      })

  defp state(transport) do
    %Client{
      transport_mod: HTTP,
      transport_state: transport,
      pending_requests: %{1 => {{self(), make_ref()}, :single, "tools/call"}},
      async_post_tasks: %{make_ref() => {self(), 1}}
    }
  end

  defp worker(state) do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    id = make_ref()
    ref = make_ref()
    monitor = Process.monitor(self())

    waiter = %{
      kind: :post,
      pid: self(),
      request_id: 1,
      ref: ref,
      deadline: Deadline.after_ms(5_000),
      scopes: [],
      flow: id,
      monitor: monitor,
      timer: nil
    }

    worker = %{
      pid: pid,
      monitor: Process.monitor(pid),
      id: id,
      timer: nil,
      deadline: waiter.deadline,
      scopes: ["read"],
      rejected_generation: state.transport_state.rejected_generation
    }

    auth = %{
      state.http_auth
      | worker: worker,
        waiters: %{ref => waiter},
        monitors: %{monitor => ref}
    }

    {%{state | http_auth: auth}, pid, id, ref}
  end
end
