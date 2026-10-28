defmodule Arbor.MCP.Client.StdioProbeStartupTest do
  @moduledoc """
  A stdio server is a child process the client has just spawned, so the first
  message it reads also waits for it to start: a BEAM under `mix run`, `npx` or
  `uvx` on a cold cache, or any server on a loaded host. That start is not
  evidence of either protocol era. The `server/discover` probe must wait for
  it as long as a legacy `initialize` would, in every protocol mode and on
  every reconnect, through the reliability wrapper too, while a server that
  never answers still fails within a bounded time.

  The servers are scripted in `sh` (see `Arbor.MCP.Test.ScriptedStdioServer`)
  so the start-up delay is the only slow part.
  """

  use ExUnit.Case, async: true

  import Arbor.MCP.Test.ScriptedStdioServer,
    only: [connect_concurrently: 4, methods: 1, start_client: 4, stop_client: 1]

  alias Arbor.MCP.Client

  @moduletag :tmp_dir

  # Longer than the 2 s default `:era_probe_timeout`, well inside the 10 s
  # default `:handshake_timeout`.
  @start_delay_s 3

  @modes [:modern_only, :prefer_modern, :prefer_legacy, :legacy_only]

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "a modern server that is slow to start" do
    test "connects in every mode that enables the modern era", %{tmp_dir: tmp_dir} do
      # Inside the reliability wrapper too, with its circuit breaker, whose
      # own 5 s call limit the start must outlast.
      wrapped =
        {:wrapped_modern_only, :modern_only,
         reliability: [circuit_breaker: [failure_threshold: 5]], start_delay_s: 6}

      results =
        connect_concurrently(tmp_dir, :modern, [wrapped | @modes], start_delay_s: @start_delay_s)

      for mode <- [:modern_only, :prefer_modern, :wrapped_modern_only] do
        %{result: result, methods: methods} = results[mode]
        assert {:ok, client} = result, "#{mode}: #{inspect(result)}"
        assert {:ok, "2026-07-28"} = Client.negotiated_version(client)
        assert {:ok, %{"name" => "scripted-modern"}} = Client.server_info(client)
        # Settled by the probe alone: initialize is never sent.
        assert methods == ["server/discover"], "#{mode}: #{inspect(methods)}"
      end

      # prefer_legacy opens with initialize and moves forward only because the
      # server, once started, rejected it as a modern server does.
      %{result: result, methods: methods} = results[:prefer_legacy]
      assert {:ok, client} = result, "prefer_legacy: #{inspect(result)}"
      assert {:ok, "2026-07-28"} = Client.negotiated_version(client)
      assert methods == ["initialize", "server/discover"]

      # Strict legacy never probes, so it fails on the server's own answer.
      %{result: result, methods: methods} = results[:legacy_only]
      assert {:error, {:initialize_error, %{"code" => -32022}}} = result
      assert methods == ["initialize"]
    end
  end

  describe "a legacy server that is slow to start" do
    test "connects in every mode that enables the legacy era", %{tmp_dir: tmp_dir} do
      results = connect_concurrently(tmp_dir, :legacy, @modes, start_delay_s: @start_delay_s)

      # prefer_modern falls back on the server's own answer to the probe, the
      # -32601 it sends once started, not on the time it took to start.
      %{result: result, methods: methods, starts: starts} = results[:prefer_modern]
      assert {:ok, client} = result, "prefer_modern: #{inspect(result)}"
      assert {:ok, "2025-11-25"} = Client.negotiated_version(client)
      assert methods == ["server/discover", "initialize", "notifications/initialized"]
      assert starts == 1

      for mode <- [:prefer_legacy, :legacy_only] do
        %{result: result, methods: methods} = results[mode]
        assert {:ok, client} = result, "#{mode}: #{inspect(result)}"
        assert {:ok, "2025-11-25"} = Client.negotiated_version(client)
        assert methods == ["initialize", "notifications/initialized"], "#{mode}"
      end

      # Strict modern never falls back: it fails on the server's -32601, which
      # it waited for, rather than on a timeout.
      %{result: result, methods: methods} = results[:modern_only]
      assert {:error, {:transport_connect_failed, reason}} = result
      assert reason =~ "{:era_probe_failed, {:json_rpc_error, "
      assert reason =~ "-32601"
      assert methods == ["server/discover"]
    end

    # A legacy server that answers the probe late inside its bound and then
    # takes seconds over initialize still fits the default establishment
    # bound, :handshake_timeout plus the probe's own (12 s here).
    test "is reached after a late probe answer and a slow initialize", %{tmp_dir: tmp_dir} do
      %{prefer_modern: %{result: result, methods: methods, elapsed_ms: elapsed_ms}} =
        connect_concurrently(tmp_dir, :legacy, [:prefer_modern],
          start_delay_s: 5,
          initialize_delay_s: 4,
          handshake_timeout: 6_000
        )

      assert {:ok, client} = result, inspect(result)
      assert {:ok, "2025-11-25"} = Client.negotiated_version(client)
      assert methods == ["server/discover", "initialize", "notifications/initialized"]
      # Past the 8 s (6 s handshake plus 2 s probe) the old default allowed.
      assert elapsed_ms >= 8_000, "connected after #{elapsed_ms} ms"
    end
  end

  describe "a server that never answers" do
    test "fails at the handshake bound, and only after it", %{tmp_dir: tmp_dir} do
      %{modern_only: %{result: result, methods: methods, starts: starts, elapsed_ms: elapsed_ms}} =
        connect_concurrently(tmp_dir, :mute, [:modern_only], handshake_timeout: 4_000)

      assert {:error, {:transport_connect_failed, reason}} = result
      assert reason == "{:era_probe_failed, {:transport_error, :handshake_timeout}}"
      # The 2 s probe bound this used to have would have given up by now.
      assert elapsed_ms >= 4_000, "gave up after #{elapsed_ms} ms"
      # The probe's own bound, not the 8 s establishment bound, ended it.
      assert elapsed_ms < 7_000, "took #{elapsed_ms} ms"
      assert methods == ["server/discover"]
      assert starts == 1
    end

    test "an explicit :era_probe_timeout still bounds the probe", %{tmp_dir: tmp_dir} do
      %{modern_only: %{result: result, methods: methods, elapsed_ms: elapsed_ms}} =
        connect_concurrently(tmp_dir, :mute, [:modern_only], era_probe_timeout: 300)

      assert {:error, {:transport_connect_failed, reason}} = result
      assert reason == "{:era_probe_failed, {:transport_error, :handshake_timeout}}"
      # Well short of the 10 s handshake bound it would get otherwise.
      assert elapsed_ms < 5_000, "took #{elapsed_ms} ms"
      assert methods == ["server/discover"]
    end
  end

  describe "an unusable answer to the probe" do
    test "is not legacy evidence after a slow start", %{tmp_dir: tmp_dir} do
      %{prefer_modern: %{result: result, methods: methods, starts: starts}} =
        connect_concurrently(tmp_dir, :garbage, [:prefer_modern], start_delay_s: @start_delay_s)

      assert {:error, {:transport_connect_failed, reason}} = result
      assert reason =~ "{:era_probe_failed, {:unexpected_response, "
      assert methods == ["server/discover"]
      # The server answered, so nothing is respawned.
      assert starts == 1
    end
  end

  describe "a reconnect" do
    test "waits for the restarted server to start", %{tmp_dir: tmp_dir} do
      log = Path.join(tmp_dir, "reconnect.log")
      attach_reconnect_events()

      # Only the first server starts at once, so the client connects and
      # only its reconnect meets a slow start.
      {:ok, client} =
        start_client(:modern, :prefer_modern, log,
          start_delay_s: @start_delay_s,
          first_start: Path.join(tmp_dir, "first-start"),
          reconnect: true,
          reconnect_backoff: [initial: 10, max: 40]
        )

      on_exit(fn -> stop_client(client) end)
      assert {:ok, "2026-07-28"} = Client.negotiated_version(client)

      %{transport_state: %{os_pid: os_pid}} = :sys.get_state(client)
      assert {_output, 0} = System.cmd("kill", ["-KILL", "#{os_pid}"])

      assert_receive {:reconnect, :success, ^client}, 15_000
      refute_received {:reconnect, :error, ^client}

      assert {:ok, "2026-07-28"} = Client.negotiated_version(client)
      # A modern ping is a server/discover of its own.
      assert {:ok, _result} = Client.ping(client)
      assert methods(log) == ["server/discover", "server/discover", "server/discover"]
    end
  end

  defp attach_reconnect_events do
    test_pid = self()
    handler_id = "stdio-probe-startup-#{System.unique_integer([:positive])}"

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
