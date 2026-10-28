defmodule Arbor.MCP.Client.StdioLegacyRespawnTest do
  @moduledoc """
  A stdio server that predates `server/discover` may exit when the probe
  arrives (Python's `mcp` 1.8 and earlier do) or never answer it. Under
  `:prefer_modern` the client then reaps that child and connects a fresh one
  with the legacy `initialize`, once, so nothing that was sent to the probed
  child can reach the handshake. `:modern_only` never respawns, and
  `:prefer_legacy` and `:legacy_only` open with `initialize` anyway.

  The servers are scripted in `sh` (see `Arbor.MCP.Test.ScriptedStdioServer`);
  each records a `start` line per process, so a test counts the respawns.
  """

  use ExUnit.Case, async: true

  import Arbor.MCP.Test.ScriptedStdioServer,
    only: [connect_concurrently: 4, methods: 1, start_client: 4, starts: 1, stop_client: 1]

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.EraCache
  alias Arbor.MCP.TestHelpers
  alias Arbor.MCP.Transport.Stdio

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
    # Non-JSON stdout lines (banners, logs) are ignored and valid JSON-RPC
    # notifications are skipped while the probe waits, so a server that
    # sends either and then exits has not answered: it is replaced like any
    # other.
    for era <- [:banner, :notifies] do
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
    # of a sort, and fails the connection on the pipe it came from. An
    # oversized frame is reported as finished or unfinished depending on how
    # the pipe delivers it (Linux and macOS buffer differently).
    for {era, expected} <- [
          oversized: [
            "{:era_probe_failed, {:transport_error, {:connection_error, :frame_too_large}}}",
            "{:era_probe_failed, {:transport_error, {:connection_error, {:unfinished_frame, :frame_too_large}}}}"
          ],
          malformed: ["{:era_probe_failed, {:unexpected_response, "],
          partial: [
            "{:era_probe_failed, {:transport_error, {:connection_error, {:unfinished_frame, {:process_exited, 5}}}}}"
          ]
        ] do
      test "#{era} output is not respawned", %{tmp_dir: tmp_dir} do
        %{prefer_modern: %{result: result, methods: methods, starts: starts}} =
          connect_concurrently(tmp_dir, unquote(era), [:prefer_modern], max_frame_bytes: 4_096)

        assert {:error, {:transport_connect_failed, reason}} = result
        assert Enum.any?(unquote(expected), &String.starts_with?(reason, &1)), reason
        assert {methods, starts} == {["server/discover"], 1}
      end
    end
  end

  describe "a server that cannot be confirmed stopped" do
    # A policy that would retry anything, the strongest test of the guard.
    @retry_anything [
      max_attempts: 3,
      initial_delay: 10,
      jitter: false,
      should_retry?: &__MODULE__.always/1
    ]

    test "is not replaced by a second one, even under a retry policy", %{tmp_dir: tmp_dir} do
      for {label, policy} <- [none: [], default: [max_attempts: 2], anything: @retry_anything] do
        log = Path.join(tmp_dir, "unconfirmed-#{label}.log")
        result = start_with_stuck_close(log, :prefer_modern, retry_policy: policy)

        assert {:error,
                {:transport_connect_failed,
                 {:probed_server_stop_unconfirmed,
                  %{probe: {:transport_error, :handshake_timeout}, cleanup: {:error, _}}}}} =
                 result,
               "#{label}: #{inspect(result)}"

        assert starts(log) == 1, "#{label} started #{starts(log)} servers"
      end
    end

    # The failure path without a respawn: modern_only gives up on the probe,
    # and closing the child is not confirmed either.
    test "after a failed attempt stops a retry from starting another", %{tmp_dir: tmp_dir} do
      log = Path.join(tmp_dir, "failed-attempt.log")
      result = start_with_stuck_close(log, :modern_only, retry_policy: @retry_anything)

      assert {:error,
              {:transport_connect_failed,
               {:cleanup_failed, {:era_probe_failed, {:transport_error, :handshake_timeout}},
                {:error, _cleanup}}}} = result

      assert starts(log) == 1
    end
  end

  @doc false
  def always(_reason), do: true

  # Starts a client against a mute server and, once the probe has reached the
  # server, stops the probed child's stdio actor from answering, so closing
  # the child cannot confirm it is gone. Returns what the start returned.
  defp start_with_stuck_close(log, mode, opts) do
    owner = self()

    starter =
      spawn_link(fn ->
        Process.flag(:trap_exit, true)

        result =
          start_client(
            :mute,
            mode,
            log,
            [handshake_timeout: 1_000, establish_timeout: 30_000, cleanup_timeout: 600] ++ opts
          )

        send(owner, {:started, self(), result})

        receive do
          {:EXIT, ^owner, _reason} -> :ok
        end
      end)

    TestHelpers.wait_until(fn -> "server/discover" in methods(log) end, timeout: 5_000)
    true = :erlang.suspend_process(stdio_actor(starter))

    receive do
      {:started, ^starter, result} -> result
    after
      30_000 -> flunk("the client did not finish starting")
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

  # The stdio actor that the client `starter` is starting owns.
  defp stdio_actor(starter) do
    {:links, links} = Process.info(starter, :links)
    [client] = Enum.filter(links, &(dictionary_value(&1, {Arbor.MCP.Client, :client}) == true))

    [actor] =
      Enum.filter(
        Process.list(),
        &(dictionary_value(&1, {Arbor.RPC.Subprocess.Actor, :owner}) == client)
      )

    actor
  end

  defp dictionary_value(pid, key) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> :proplists.get_value(key, dictionary, nil)
      nil -> nil
    end
  end

  defp dictionary_value(_port, _key), do: nil

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
      [[:arbor_mcp, :client, :reconnect, :success], [:arbor_mcp, :client, :reconnect, :error]],
      fn [_, _, _, outcome], _measurements, %{pid: pid}, _config ->
        send(test_pid, {:reconnect, outcome, pid})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
