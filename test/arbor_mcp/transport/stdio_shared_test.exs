defmodule Arbor.MCP.Transport.StdioSharedTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client.EraCache
  alias Arbor.MCP.TestHelpers
  alias Arbor.MCP.Transport.Stdio
  alias Arbor.RPC.Subprocess

  test "per-frame limits exclude LF and multiple frames drain with zero timeout" do
    state = start("printf '{}\\n{}\\n'; exec sleep 10", max_frame_bytes: 2)

    TestHelpers.wait_until(fn -> Subprocess.stats(state.subprocess).queued == 2 end,
      timeout: 1_000
    )

    assert {:ok, "{}", state} = Stdio.receive_message(state, 0)
    assert {:ok, "{}", _state} = Stdio.receive_message(state, 0)
    assert Subprocess.stats(state.subprocess).frames == 0
  end

  test "banners, blank lines, BOM and CRLF preserve a fragmented unicode JSON frame" do
    json = Jason.encode!(%{"text" => "café 日本語 🪁"})

    state =
      start("printf 'banner\\n\\n'; printf '\\357\\273\\277%s\\r\\n' \"$1\"; exec sleep 10", [], [
        json
      ])

    assert {:ok, ^json, _state} = Stdio.receive_message(state, 1_000)
  end

  test "MCP rejects an unfinished final JSON frame at EOF" do
    state = start(~s(printf '{"text":"unfinished"}'))

    assert {:error, {:connection_error, {:process_exited, 0}}} =
             Stdio.receive_message(state, 1_000)
  end

  test "banners cannot extend the absolute receive deadline" do
    state = start("while :; do printf 'banner\\n'; sleep 0.01; done")
    started = System.monotonic_time(:millisecond)
    assert {:error, :handshake_timeout} = Stdio.receive_message(state, 40)
    assert System.monotonic_time(:millisecond) - started < 300
    assert Stdio.connected?(state)
  end

  test "a timed out banner filter leaves a later JSON frame for the next reader" do
    state = start("printf 'banner\\n'; sleep 0.08; printf '{}\\n'; exec sleep 10")
    assert {:error, :handshake_timeout} = Stdio.receive_message(state, 20)

    TestHelpers.wait_until(fn -> Subprocess.stats(state.subprocess).queued == 1 end,
      timeout: 1_000
    )

    assert {:ok, "{}", _state} = Stdio.receive_message(state, 0)
  end

  test "zero timeout skips already buffered banners without waiting for more input" do
    state = start("printf 'banner\\n\\n{}\\n'; exec sleep 10")

    TestHelpers.wait_until(fn -> Subprocess.stats(state.subprocess).queued == 3 end,
      timeout: 1_000
    )

    assert {:ok, "{}", _state} = Stdio.receive_message(state, 0)
    assert {:error, :handshake_timeout} = Stdio.receive_message(state, 0)
  end

  test "push credit is retained until the consuming process acknowledges" do
    state = start("printf '{}\\n{}\\n'; exec sleep 10")
    assert {:ok, state} = Stdio.subscribe(self(), state)
    generation = Stdio.identity(state)

    assert_receive {:arbor_rpc, ^generation, {:frame, one, "{}"}}, 1_000
    refute_receive {:arbor_rpc, ^generation, {:frame, _two, _bytes}}, 20
    assert %{inflight: 1, frames: 2} = Subprocess.stats(state.subprocess)
    assert :ok = Stdio.ack(state, one)
    assert_receive {:arbor_rpc, ^generation, {:frame, two, "{}"}}, 1_000
    assert :ok = Stdio.ack(state, two)
    assert %{inflight: 0, frames: 0} = Subprocess.stats(state.subprocess)
  end

  test "old generations are ignored and era cache identities belong to child generations" do
    one = start("exec cat")
    two = start("exec cat")
    identity = EraCache.identity(Stdio, one, [])
    refute identity == :none
    refute identity == EraCache.identity(Stdio, two, [])
    assert :ok = EraCache.observe(identity, :modern, "2026-07-28")
    assert :ok = EraCache.observe(identity, :legacy, "2025-11-25")
    assert {:ok, %{era: :modern, protocol_version: "2026-07-28"}} = EraCache.lookup(identity)
    on_exit(fn -> EraCache.clear(identity) end)
    message = {:arbor_rpc, Stdio.identity(one), {:frame, make_ref(), "{}"}}
    assert :ignore = Stdio.event(two, message)
  end

  test "oversized input closes the child with an explicit frame failure" do
    state = start("printf 'abcde'; exec sleep 10", max_frame_bytes: 4)
    assert {:error, {:connection_error, :frame_too_large}} = Stdio.receive_message(state, 1_000)
    refute Stdio.connected?(state)
  end

  test "an ephemeral pull reader cannot take child ownership" do
    state = start("exec cat")
    task = Task.async(fn -> Stdio.receive_message(state, 10) end)
    assert {:error, :handshake_timeout} = Task.await(task)
    assert Stdio.connected?(state)

    message = ~s({"jsonrpc":"2.0","id":1,"method":"ping"})
    assert {:ok, state} = Stdio.send_message(message, state)
    assert {:ok, ^message, _state} = Stdio.receive_message(state, 1_000)
  end

  test "invalid timeouts fail before reading from the child" do
    for timeout <- [-1, nil, :invalid] do
      assert {:error, :invalid_timeout} = Stdio.receive_message(%Stdio{}, timeout)
    end
  end

  defp start(script, opts \\ [], args \\ []) do
    shell = System.find_executable("sh") || flunk("sh executable required")

    assert {:ok, state} =
             Stdio.connect(Keyword.put(opts, :command, [shell, "-c", script, "sh" | args]))

    on_exit(fn -> Stdio.close(state) end)
    state
  end
end
