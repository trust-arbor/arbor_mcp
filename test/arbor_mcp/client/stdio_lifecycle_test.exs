defmodule Arbor.MCP.Client.StdioLifecycleTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.{Client, TestHelpers}
  alias Arbor.MCP.Transport.{ReliabilityWrapper, Stdio}
  alias Arbor.RPC.Subprocess

  test "client processing releases delivery credit rather than forwarding it" do
    {client, transport} = start_client()
    generation = Stdio.identity(transport)
    :ok = :sys.suspend(client)

    on_exit(fn ->
      try do
        if Process.alive?(client), do: :sys.resume(client)
      catch
        :exit, _reason -> :ok
      end
    end)

    assert :ok = Subprocess.write(transport.subprocess, "banner\nbanner\n")

    TestHelpers.wait_until(fn ->
      match?(%{frames: 2, inflight: 1}, Subprocess.stats(transport.subprocess))
    end)

    {:messages, messages} = Process.info(client, :messages)
    assert Enum.count(messages, &match?({:arbor_rpc, ^generation, {:frame, _, _}}, &1)) == 1

    :ok = :sys.resume(client)

    TestHelpers.wait_until(fn ->
      match?(%{frames: 0, inflight: 0}, Subprocess.stats(transport.subprocess))
    end)

    assert {:ok, %{connection_status: :ready}} = Client.get_status(client)
    assert :ok = Client.disconnect(client)
    refute Stdio.connected?(transport)
  end

  test "hard actor death disconnects the live client and reaps its child" do
    {client, transport} = start_client()
    monitor = Process.monitor(transport.reader_pid)
    Process.exit(transport.reader_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}

    TestHelpers.wait_until(fn ->
      match?({:ok, %{connection_status: :disconnected}}, Client.get_status(client))
    end)

    TestHelpers.wait_until(fn -> not os_alive?(transport.os_pid) end, timeout: 2_000)
    assert Process.alive?(client)
  end

  test "a dead reliability component cannot skip cleanup of the live child" do
    {client, wrapped} = start_client(circuit_breaker: [failure_threshold: 3])
    child = wrapped.wrapped_state
    Process.exit(wrapped.circuit_breaker_pid, :kill)

    TestHelpers.wait_until(fn ->
      match?({:ok, %{connection_status: :disconnected}}, Client.get_status(client))
    end)

    refute Stdio.connected?(child)
    TestHelpers.wait_until(fn -> not os_alive?(child.os_pid) end, timeout: 2_000)
    assert Process.alive?(client)
  end

  test "an ACK failure preserves a parsed reply and disconnects instead of stalling credit" do
    {client, transport} = start_client()
    reply = make_ref()
    owner = self()

    :sys.replace_state(client, fn state ->
      %{state | pending_requests: %{1 => {{owner, reply}, :single, "ping"}}}
    end)

    # A generation-matching but invalid receipt is rejected by the actual actor.
    # The protocol result is delivered before transport teardown settles other work.
    send(client, {
      :arbor_rpc,
      Stdio.identity(transport),
      {:frame, make_ref(),
       ~s({"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","value":1}})}
    })

    assert_receive {^reply, {:ok, %{"resultType" => "complete", "value" => 1}}}

    TestHelpers.wait_until(fn ->
      match?({:ok, %{connection_status: :disconnected}}, Client.get_status(client))
    end)

    refute Stdio.connected?(transport)
    assert Process.alive?(client)
  end

  test "wrapper close has a finite fallback for a suspended owned component" do
    {client, wrapped} = start_client(circuit_breaker: [failure_threshold: 3])
    :ok = :sys.suspend(wrapped.circuit_breaker_pid)
    started = System.monotonic_time(:millisecond)

    assert :ok = Client.disconnect(client)
    assert System.monotonic_time(:millisecond) - started < 2_000
    refute Process.alive?(wrapped.circuit_breaker_pid)
    refute Stdio.connected?(wrapped.wrapped_state)
  end

  test "terminal cleanup failures survive an idempotent close of the stopped generation" do
    {client, transport} = start_client()
    :ok = :sys.suspend(client)

    try do
      send(client, {
        :arbor_rpc,
        Stdio.identity(transport),
        {:closed, {:cleanup_failed, {:exit_status, 0}, {:error, :cleanup_denied}}, ""}
      })

      assert :ok = Stdio.close(transport)
    after
      :sys.resume(client)
    end

    TestHelpers.wait_until(fn ->
      :sys.get_state(client).cleanup_result == {:error, :cleanup_denied}
    end)

    assert {:error, :cleanup_denied} = Client.disconnect(client)
    assert {:error, :cleanup_denied} = Client.disconnect(client)
  end

  defp start_client(reliability_opts \\ []) do
    {:ok, client} =
      Client.start_link(
        transport: :test,
        _skip_connect: true,
        reconnect: false,
        health_check_interval: nil
      )

    shell = System.find_executable("sh") || flunk("sh executable required")

    state =
      :sys.replace_state(client, fn state ->
        {:ok, transport} = Stdio.connect(command: [shell, "-c", "exec cat"])
        {:ok, transport} = Stdio.subscribe(self(), transport)

        {mod, transport} =
          if reliability_opts == [] do
            {Stdio, transport}
          else
            {:ok, wrapper} = ReliabilityWrapper.wrap(Stdio, transport, reliability_opts)
            {ReliabilityWrapper, wrapper}
          end

        %{state | transport_mod: mod, transport_state: transport, connection_status: :ready}
      end)

    on_exit(fn ->
      try do
        if Process.alive?(client), do: Client.stop(client)
      catch
        :exit, _reason -> :ok
      end
    end)

    {client, state.transport_state}
  end

  defp os_alive?(pid) do
    {_output, status} =
      System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

    status == 0
  end
end
