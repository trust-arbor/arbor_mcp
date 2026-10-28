defmodule ExMCP.Client.StdioReliabilityBreakerTest do
  @moduledoc """
  A stdio client whose transport is wrapped with a circuit breaker enabled:
  the breaker used to run each receive in a process of its own, which took
  over the stdio port (`Stdio.receive_message/2` connects it to the caller)
  and closed it when that process exited, so the first request failed
  whatever its timeout. The receive now runs in the transport's owning
  process — the breaker still admits and reports it, and still trips on real
  failures.
  """

  use ExUnit.Case, async: true

  import ExMCP.Test.ScriptedStdioServer,
    only: [connect_concurrently: 4, methods: 1, start_client: 4, stop_client: 1]

  alias ExMCP.Client

  @moduletag :tmp_dir

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "connects and serves requests with the breaker enabled", %{tmp_dir: tmp_dir} do
    log = Path.join(tmp_dir, "breaker-modern.log")

    {:ok, client} =
      start_client(:modern, :modern_only, log,
        reliability: [circuit_breaker: [failure_threshold: 5]]
      )

    assert {:ok, "2026-07-28"} = Client.negotiated_version(client)
    assert {:ok, %{"name" => "scripted-modern"}} = Client.server_info(client)

    # Several requests, each answered through the breaker-guarded receive.
    for _ <- 1..3 do
      assert {:ok, _} = Client.ping(client, timeout: 5_000)
    end

    assert {:ok, _pong} = Client.ping(client, timeout: 5_000)
    stop_client(client)

    # The probe and every ping — in the modern era a ping is a
    # server/discover — were served by the same child: the port survived
    # each receive instead of closing with the first.
    assert log |> methods() |> Enum.all?(&(&1 == "server/discover"))
    assert length(methods(log)) >= 5
  end

  test "a failing receive still trips the breaker", %{tmp_dir: tmp_dir} do
    # The `broken` era exits on any request, so every receive ends in a
    # closed transport: after the failure threshold the breaker opens and
    # refuses before the transport is touched again.
    log = Path.join(tmp_dir, "breaker-broken.log")

    {:error, {:transport_connect_failed, _reason}} =
      start_client(:broken, :modern_only, log,
        reliability: [
          circuit_breaker: [failure_threshold: 2, reset_timeout: 60_000]
        ]
      )

    assert methods(log) == ["server/discover"]
  end
end
