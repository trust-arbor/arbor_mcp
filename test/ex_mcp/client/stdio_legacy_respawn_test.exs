defmodule ExMCP.Client.StdioLegacyRespawnTest do
  @moduledoc """
  A stdio server that predates `server/discover` may exit when the probe
  arrives (Python's `mcp` 1.8 and earlier do) or never answer it. Under
  `:prefer_modern` the client then reaps that child and connects a fresh one
  with the legacy `initialize`, once, so nothing that was sent to the probed
  child can reach the handshake. `:modern_only` never respawns, and
  `:prefer_legacy` and `:legacy_only` open with `initialize` anyway.

  The servers are scripted in `sh` (see `ExMCP.Test.ScriptedStdioServer`);
  each records a `start` line per process, so a test counts the respawns.
  """

  use ExUnit.Case, async: true

  import ExMCP.Test.ScriptedStdioServer,
    only: [connect_concurrently: 4, methods: 1, start_client: 4, starts: 1, stop_client: 1]

  alias ExMCP.Client
  alias ExMCP.Client.EraCache
  alias ExMCP.Transport.Stdio

  @moduletag :tmp_dir

  @modes [:modern_only, :prefer_modern, :prefer_legacy, :legacy_only]
  @legacy_handshake ["initialize", "notifications/initialized"]

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "a legacy server that exits on the probe" do
    test "is respawned and initialized under prefer_modern only", %{tmp_dir: tmp_dir} do
      results = connect_concurrently(tmp_dir, :exits, @modes, [])

      %{result: result, methods: methods, starts: starts} = results[:prefer_modern]
      assert {:ok, client} = result, "prefer_modern: #{inspect(result)}"
      assert {:ok, "2025-11-25"} = Client.negotiated_version(client)
      assert {:ok, %{"name" => "scripted-legacy"}} = Client.server_info(client)
      assert methods == ["server/discover" | @legacy_handshake]
      assert starts == 2
      assert_legacy_observed(client)

      for mode <- [:prefer_legacy, :legacy_only] do
        %{result: result, methods: methods, starts: starts} = results[mode]
        assert {:ok, client} = result, "#{mode}: #{inspect(result)}"
        assert {:ok, "2025-11-25"} = Client.negotiated_version(client)
        assert {methods, starts} == {@legacy_handshake, 1}, "#{mode}"
      end

      %{result: result, methods: methods, starts: starts} = results[:modern_only]
      assert {:error, {:transport_connect_failed, reason}} = result
      assert reason =~ "{:era_probe_failed, {:transport_error, "
      assert {methods, starts} == {["server/discover"], 1}
    end
  end

  describe "a legacy server that writes something other than an answer and exits" do
    # Non-JSON stdout lines (banners, logs) are ignored, so a server that
    # prints one and then exits has not answered: it is replaced like any
    # other. (On 1.x the probe does not skip notifications: one is taken for
    # an unexpected answer, so the `notifies` era is not covered here.)
    for era <- [:banner] do
      test "is respawned and initialized after #{era} output", %{tmp_dir: tmp_dir} do
        %{prefer_modern: %{result: result, methods: methods, starts: starts}} =
          connect_concurrently(tmp_dir, unquote(era), [:prefer_modern], [])

        assert {:ok, client} = result, inspect(result)
        assert {:ok, "2025-11-25"} = Client.negotiated_version(client)
        assert methods == ["server/discover" | @legacy_handshake]
        assert starts == 2
      end
    end
  end

  describe "a legacy server that never answers the probe" do
    test "is respawned and initialized once the probe times out", %{tmp_dir: tmp_dir} do
      results = connect_concurrently(tmp_dir, :silent, @modes, handshake_timeout: 1_500)

      %{result: result, methods: methods, starts: starts} = results[:prefer_modern]
      assert {:ok, client} = result, "prefer_modern: #{inspect(result)}"
      assert {:ok, "2025-11-25"} = Client.negotiated_version(client)
      assert methods == ["server/discover" | @legacy_handshake]
      assert starts == 2

      for mode <- [:prefer_legacy, :legacy_only] do
        %{result: result, methods: methods, starts: starts} = results[mode]
        assert {:ok, _client} = result, "#{mode}: #{inspect(result)}"
        assert {methods, starts} == {@legacy_handshake, 1}, "#{mode}"
      end

      %{result: result, methods: methods, starts: starts} = results[:modern_only]
      assert {:error, {:transport_connect_failed, reason}} = result
      assert reason == "{:era_probe_failed, {:transport_error, :handshake_timeout}}"
      assert {methods, starts} == {["server/discover"], 1}
    end
  end

  describe "a respawn that is not a legacy server" do
    test "fails clearly after one respawn when initialize fails too", %{tmp_dir: tmp_dir} do
      %{prefer_modern: %{result: result, methods: methods, starts: starts}} =
        connect_concurrently(tmp_dir, :broken, [:prefer_modern], [])

      assert {:error, {:transport_connect_failed, reason}} = result
      assert reason =~ "{:era_probe_and_initialize_failed, "
      assert reason =~ "respawned: true"
      assert methods == ["server/discover", "initialize"]
      assert starts == 2
    end

    test "a modern-only server slower than the probe fails on initialize", %{tmp_dir: tmp_dir} do
      %{prefer_modern: %{result: result, methods: methods, starts: starts}} =
        connect_concurrently(tmp_dir, :modern, [:prefer_modern],
          start_delay_s: 2,
          era_probe_timeout: 1_000,
          handshake_timeout: 5_000
        )

      # The respawned server rejects initialize as a modern server does, with
      # the versions it supports.
      assert {:error, {:transport_connect_failed, reason}} = result
      assert reason =~ "{:era_probe_and_initialize_failed, "
      assert reason =~ ~s("supported" => ["2026-07-28"])
      assert reason =~ "respawned: true"
      assert starts == 2
      assert List.last(methods) == "initialize"
    end

    test "a server that never answers anything fails within the establishment bound",
         %{tmp_dir: tmp_dir} do
      %{prefer_modern: %{result: result, methods: methods, starts: starts, elapsed_ms: elapsed}} =
        connect_concurrently(tmp_dir, :mute, [:prefer_modern], handshake_timeout: 1_000)

      # 1 s probe, then the respawned initialize until the 2 s bound.
      assert {:error, :establish_timeout} = result
      assert elapsed < 6_000, "took #{elapsed} ms"
      assert methods == ["server/discover", "initialize"]
      assert starts == 2
    end
  end

  describe "an answer that is not silence" do
    # Only a child that exits without a word, or a probe that times out, is
    # replaced: output that is oversized, malformed or cut off is an answer
    # of a sort, and fails the connection on the pipe it came from.
    for {era, expected} <- [
          oversized: "{:era_probe_failed, {:transport_error, :frame_too_large}}",
          malformed: "{:era_probe_failed, {:unexpected_response, ",
          partial:
            "{:era_probe_failed, {:transport_error, {:connection_error, {:unfinished_frame, {:process_exited, 5}}}}}"
        ] do
      test "#{era} output is not respawned", %{tmp_dir: tmp_dir} do
        %{prefer_modern: %{result: result, methods: methods, starts: starts}} =
          connect_concurrently(tmp_dir, unquote(era), [:prefer_modern], max_frame_bytes: 4_096)

        assert {:error, {:transport_connect_failed, reason}} = result
        assert String.starts_with?(reason, unquote(expected)), reason
        assert {methods, starts} == {["server/discover"], 1}
      end
    end
  end

  describe "a reconnect" do
    test "respawns again for a server that exits on the probe", %{tmp_dir: tmp_dir} do
      log = Path.join(tmp_dir, "reconnect.log")
      attach_reconnect_events()

      {:ok, client} =
        start_client(:exits, :prefer_modern, log,
          reconnect: true,
          reconnect_backoff: [initial: 10, max: 40]
        )

      on_exit(fn -> stop_client(client) end)
      assert {:ok, "2025-11-25"} = Client.negotiated_version(client)
      assert starts(log) == 2
      # Answered after notifications/initialized, so that was read too.
      assert {:ok, _result} = Client.ping(client)

      %{transport_state: %{os_pid: os_pid}} = :sys.get_state(client)
      assert {_output, 0} = System.cmd("kill", ["-KILL", "#{os_pid}"])

      assert_receive {:reconnect, :success, ^client}, 15_000
      refute_received {:reconnect, :error, ^client}
      assert {:ok, "2025-11-25"} = Client.negotiated_version(client)
      assert {:ok, _result} = Client.ping(client)
      assert starts(log) == 4

      # Each ping reads as "other"; the last is left out.
      assert Enum.drop(methods(log), -1) ==
               ["server/discover" | @legacy_handshake] ++
                 ["other", "server/discover" | @legacy_handshake]
    end
  end

  defp assert_legacy_observed(client) do
    %{transport_mod: Stdio, transport_state: transport_state} = :sys.get_state(client)

    assert {:ok, %{era: :legacy, protocol_version: "2025-11-25"}} =
             EraCache.lookup(EraCache.identity(Stdio, transport_state, []))
  end

  defp attach_reconnect_events do
    test_pid = self()
    handler_id = "stdio-legacy-respawn-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [[:ex_mcp, :client, :reconnect, :success], [:ex_mcp, :client, :reconnect, :error]],
      fn [_, _, _, outcome], _measurements, %{pid: pid}, _config ->
        send(test_pid, {:reconnect, outcome, pid})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
