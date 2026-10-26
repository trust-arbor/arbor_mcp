defmodule Arbor.MCP.Soak.HarnessLogicTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Soak.{
    Cleanup,
    DependencySource,
    Evidence,
    Execution,
    Histogram,
    Policy,
    Provenance,
    Runner
  }

  test "turnover uses the lower legacy HTTP session budget" do
    refute Policy.turnover?(95, 1_000, 120_999, 96, 120_000)
    assert Policy.turnover?(96, 1_000, 1_001, 96, 120_000)
    assert Policy.turnover?(2, 1_000, 121_000, 96, 120_000)
    assert Policy.request_budget(:cowboy_owned, :legacy, 500) == 96
    assert Policy.request_budget(:bandit_host, :legacy, 80) == 80
    assert Policy.request_budget(:cowboy_owned, :modern, 500) == 500
    assert Policy.request_budget(:beam, :legacy, 500) == 500

    assert_raise Mix.Error, ~r/turnover-requests/, fn ->
      Runner.parse!(["--turnover-requests", "5001"])
    end
  end

  test "late versus post-warm-up baseline detects one scenario leak with bounded history" do
    series =
      Enum.reduce(1..10, Policy.new_series(), fn _, acc ->
        Policy.add_sample(acc, %{processes: 100})
      end)

    assert Policy.leak_violations(series) == []

    series = Enum.reduce(1..8, series, fn _, acc -> Policy.add_sample(acc, %{processes: 125}) end)

    assert [%{metric: :processes, baseline: 100.0, recent: 125.0}] =
             Policy.leak_violations(series)

    slow_leak =
      Enum.reduce(1..40, Policy.new_series(), fn n, acc ->
        Policy.add_sample(acc, %{processes: 100 + n})
      end)

    assert [%{metric: :processes}] = Policy.leak_violations(slow_leak)

    stable =
      Enum.reduce(1..100, Policy.new_series(), fn _, acc ->
        Policy.add_sample(acc, %{processes: 100})
      end)

    assert Policy.leak_violations(stable) == []
    assert length(stable.baseline) == 8
    assert length(stable.recent) == 16

    table_series =
      Enum.reduce(1..18, Policy.new_series(), fn n, acc ->
        Policy.add_sample(acc, %{ets_tables: if(n <= 10, do: 50, else: 61)})
      end)

    assert [%{metric: :ets_tables}] = Policy.leak_violations(table_series)

    missing =
      Enum.reduce(1..18, Policy.new_series(), fn _, acc ->
        Policy.add_sample(acc, %{file_descriptors: nil})
      end)

    assert Policy.leak_violations(missing) == []
  end

  test "ETS sampling ignores tables deleted after enumeration" do
    assert Policy.ets_words([:live, :deleted], fn
             :live, :memory -> 12
             :deleted, :memory -> :undefined
           end) == 12
  end

  test "fixed latency histogram bounds storage and conservatively rounds percentiles" do
    histogram = Enum.reduce([1, 2, 3, 4, 5, 50_000], Histogram.new(), &Histogram.add(&2, &1))
    assert histogram.count == 6
    assert map_size(histogram.buckets) <= 15
    assert Histogram.percentiles(histogram) == %{p50: 5, p95: 10_001, p99: 10_001}
    assert Histogram.merge([histogram, histogram]).count == 12
  end

  test "weighted chooser gives every operation a turn per scenario" do
    mix = Policy.default_mix()

    {picked, _counts} =
      Enum.map_reduce(1..length(mix), %{}, fn _, counts ->
        operation = Policy.next_operation(mix, counts)
        {operation, Map.update(counts, operation, 1, &(&1 + 1))}
      end)

    assert Enum.sort(picked) == mix |> Keyword.keys() |> Enum.sort()
    assert Policy.next_operation(mix, %{}) == :echo
    assert Policy.next_operation(mix, %{echo: 1}) == :list

    old = %{operation_counts: %{echo: 4, restart: 1}, requests: 80}
    replacement = %{operation_counts: %{}, requests: 2}

    assert Policy.carry_operation_counts(old, replacement) ==
             %{replacement | operation_counts: old.operation_counts}
  end

  test "disconnect telemetry fails unless one planned reconnect consumes it" do
    event = [:arbor_mcp, :client, :reconnect, :attempt]
    assert Policy.unexpected_client_event?(event, true)
    refute Policy.unexpected_client_event?(event, false)
    refute Policy.unexpected_client_event?(event, true, true)
    assert Policy.unexpected_client_event?([:arbor_mcp, :client, :reconnect, :success], true)
    assert Policy.reconnect_complete?(%{disconnected: 1, attempt: 1, success: 1})
    refute Policy.reconnect_complete?(%{disconnected: 1, attempt: 2, success: 1})
  end

  test "SSE reconnect telemetry is attributed by the emitting stream process" do
    client =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    stream =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      send(client, :stop)
      send(stream, :stop)
    end)

    scenarios = %{"cowboy_host/legacy" => %{client: client, sse_pid: stream}}
    assert Policy.scenario_for_event(scenarios, nil, stream) == "cowboy_host/legacy"
    assert Policy.scenario_for_event(scenarios, client, self()) == "cowboy_host/legacy"
    assert Policy.scenario_for_event(scenarios, nil, self()) == nil

    reconnecting = [:arbor_mcp, :transport, :sse, :reconnecting]
    disconnected = [:arbor_mcp, :transport, :sse, :disconnected]
    assert Policy.unexpected_stream_event?(reconnecting, true, false)
    assert Policy.unexpected_stream_event?(disconnected, true, false)
    refute Policy.unexpected_stream_event?(reconnecting, true, true)
    refute Policy.unexpected_stream_event?(reconnecting, false, false)

    assert Policy.stream_reconnect_transition(disconnected, true, false, false) ==
             {true, true}

    assert Policy.stream_reconnect_transition(reconnecting, true, false, true) ==
             {false, true}

    assert Policy.stream_reconnect_transition(
             [:arbor_mcp, :transport, :sse, :connected],
             true,
             false,
             true
           ) == {false, false}

    assert Policy.stream_reconnect_transition(reconnecting, true, false, false) ==
             {true, true}
  end

  test "failed cleanup forces listener and child teardown and remains a failure" do
    scenario = %{
      client: self(),
      root: self(),
      listener: self(),
      listener_ref: :test_ranch,
      adapter: :cowboy,
      port: 43210,
      subprocess: :test_child,
      os_pid: 76543,
      os_identity: {:ok, %{start: "birth", command: "child"}}
    }

    cleanup = %{
      client_stop: {:error, :timeout},
      client_down: :timeout,
      server_stop: {:error, :timeout},
      server_down: :timeout,
      host_stop: {:error, :timeout},
      listener_down: false,
      port_free: false,
      stdio_receipt: {:error, :unconfirmed}
    }

    receipt_count = make_ref()

    forced =
      Cleanup.force(scenario, cleanup, %{
        kill_process: fn pid ->
          send(self(), {:killed, pid})
          {:down, :killed}
        end,
        stop_ranch: fn ref ->
          send(self(), {:stopped_ranch, ref})
          :ok
        end,
        port_free?: fn _ -> true end,
        close_child: fn handle ->
          send(self(), {:closed_child, handle})
          {:error, :timeout}
        end,
        child_receipt: fn _ ->
          count = Process.get(receipt_count, 0)
          Process.put(receipt_count, count + 1)
          if count == 0, do: {:error, :unconfirmed}, else: :reaped
        end,
        os_identity: fn _pid -> scenario.os_identity end,
        kill_os_pid: fn pid, identity ->
          send(self(), {:killed_os, pid})
          assert identity == scenario.os_identity
          :signalled
        end,
        os_gone?: fn _ -> false end,
        wait_ms: 0
      })

    assert_receive {:stopped_ranch, :test_ranch}
    assert_receive {:killed, pid}
    assert pid == self()
    assert_receive {:killed, ^pid}
    assert_receive {:killed, ^pid}
    assert_receive {:closed_child, :test_child}
    assert_receive {:killed_os, 76543}
    assert forced.child.os_gone
    assert forced.port_free
    refute Cleanup.complete?(Map.put(cleanup, :forced_cleanup, forced))

    clean = %{
      client_stop: :ok,
      client_down: :normal,
      server_stop: :ok,
      server_down: :normal,
      host_stop: :ok,
      listener_down: true,
      port_free: true,
      stdio_receipt: :reaped
    }

    assert Cleanup.complete?(clean)
    refute Cleanup.complete?(%{clean | port_free: false})
    refute Cleanup.complete?(%{clean | stdio_receipt: {:error, :unconfirmed}})
  end

  test "failed subprocess lookup retains only the same child's known pid and identity" do
    original = %{
      subprocess: :first_child,
      os_pid: 76543,
      os_identity: {:ok, %{start: "birth", command: "child"}}
    }

    unavailable = %{
      get_os_pid: fn _handle -> nil end,
      os_identity: fn _pid -> {:error, :unavailable} end
    }

    assert Cleanup.track_child(:first_child, original, unavailable) == original

    assert Cleanup.track_child(:replacement_child, original, unavailable) == %{
             subprocess: :replacement_child,
             os_pid: nil,
             os_identity: {:error, :unavailable}
           }

    assert Cleanup.track_child(:replacement_child, original, %{
             get_os_pid: fn _handle -> 888 end,
             os_identity: fn 888 -> {:ok, %{start: "later", command: "child"}} end
           }).os_pid == 888
  end

  test "forced child cleanup refuses a reused or unverified OS pid" do
    child = %{
      subprocess: :child,
      os_pid: 76543,
      os_identity: {:ok, %{start: "original", command: "child"}}
    }

    common = %{
      close_child: fn _ -> {:error, :timeout} end,
      child_receipt: fn _ -> {:error, :unconfirmed} end,
      os_gone?: fn _ -> false end,
      kill_os_pid: fn _pid, _identity -> flunk("must not kill a different process") end,
      wait_ms: 0
    }

    reused =
      Cleanup.force_child(
        child,
        Map.put(common, :os_identity, fn _ ->
          {:ok, %{start: "replacement", command: "child"}}
        end)
      )

    assert match?({:error, {:unverified_os_identity, _, _}}, reused.signal)
    refute reused.os_gone

    unavailable =
      Cleanup.force_child(
        child,
        Map.put(common, :os_identity, fn _ ->
          {:error, :os_identity_unavailable}
        end)
      )

    assert match?({:error, {:unverified_os_identity, _, _}}, unavailable.signal)
    refute unavailable.os_gone
  end

  test "listener port confirmation distinguishes bound from reusable" do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(socket)
    refute Cleanup.port_free?(%{port: port})
    :ok = :gen_tcp.close(socket)
    assert Cleanup.port_free?(%{port: port})
  end

  test "setup failure stops a host listener before its runtime and confirms the port" do
    parent = self()

    listener =
      spawn(fn ->
        {:ok, socket} =
          :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

        {:ok, port} = :inet.port(socket)
        send(parent, {:listener_port, port})
        receive do: (:stop -> :gen_tcp.close(socket))
      end)

    assert_receive {:listener_port, port}
    root = spawn(fn -> receive do: (:stop -> :ok) end)

    on_exit(fn ->
      Process.exit(listener, :kill)
      Process.exit(root, :kill)
    end)

    server = %{root: root, listener: listener, owned: false, adapter: :bandit, port: port}

    cleanup =
      Cleanup.setup_failure(server, %{
        stop_host: fn _server ->
          send(parent, {:setup_step, :host_stop})
          send(listener, :stop)
          :ok
        end,
        stop_root: fn _root ->
          send(parent, {:setup_step, :root_stop})
          send(root, :stop)
          :ok
        end,
        wait_ms: 500
      })

    assert_receive {:setup_step, first_step}
    assert first_step == :host_stop
    assert_receive {:setup_step, second_step}
    assert second_step == :root_stop
    assert cleanup.listener_down
    assert cleanup.port_free
    refute Process.alive?(root)
  end

  test "dependency source comparison detects patched or added code" do
    assert DependencySource.failed(%{}) == ["<no_dependencies>"]
    dir = Path.join(System.tmp_dir!(), "soak-dep-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    on_exit(fn -> File.rm_rf!(dir) end)
    source = Path.join(dir, "lib/example.ex")
    File.write!(source, "defmodule Example, do: :original")

    expected = DependencySource.source_hashes(dir)
    assert DependencySource.compare(expected, expected).verified

    File.write!(source, "defmodule Example, do: :patched")
    patched = DependencySource.compare(DependencySource.source_hashes(dir), expected)
    refute patched.verified
    assert patched.changed_paths == ["lib/example.ex"]

    File.write!(Path.join(dir, "lib/extra.ex"), "defmodule Extra, do: :unexpected")
    extra = DependencySource.compare(DependencySource.source_hashes(dir), expected)
    refute extra.verified
    assert "lib/extra.ex" in extra.changed_paths

    clean = snapshot()
    mismatched = %{clean | dependency_sources: %{"example" => extra}}

    assert :dependency_source_mismatch in Enum.map(
             Provenance.violations(mismatched, mismatched),
             & &1.kind
           )

    assert :dependency_source_changed in Enum.map(
             Provenance.violations(clean, mismatched),
             & &1.kind
           )
  end

  test "dependency source and loaded build artifact hashes detect executable changes" do
    dir = Path.join(System.tmp_dir!(), "soak-artifacts-#{System.unique_integer([:positive])}")
    source_dir = Path.join(dir, "source")
    build_dir = Path.join(dir, "build")
    File.mkdir_p!(Path.join(source_dir, "priv"))
    File.mkdir_p!(Path.join(build_dir, "ebin"))
    File.mkdir_p!(Path.join(build_dir, "priv/native"))
    on_exit(fn -> File.rm_rf!(dir) end)

    source_priv = Path.join(source_dir, "priv/config.json")
    beam = Path.join(build_dir, "ebin/example.beam")
    native = Path.join(build_dir, "priv/native/example")
    File.write!(source_priv, "original")
    File.write!(beam, "beam-a")
    File.write!(native, "native-a")

    expected_source = DependencySource.source_hashes(source_dir)
    assert Map.has_key?(expected_source, "priv/config.json")
    File.write!(source_priv, "patched")

    refute DependencySource.compare(DependencySource.source_hashes(source_dir), expected_source).verified

    before = DependencySource.artifact_hashes(build_dir)
    assert Map.keys(before) |> Enum.sort() == ["ebin/example.beam", "priv/native/example"]

    File.write!(native, "native-b")
    after_change = DependencySource.artifact_hashes(build_dir)
    assert before["priv/native/example"] != after_change["priv/native/example"]
    assert before["ebin/example.beam"] == after_change["ebin/example.beam"]

    start_snapshot = %{snapshot() | dependency_sources: %{"example" => %{artifacts: before}}}

    end_snapshot = %{
      snapshot()
      | dependency_sources: %{"example" => %{artifacts: after_change}}
    }

    assert DependencySource.changed_artifacts(
             start_snapshot.dependency_sources,
             end_snapshot.dependency_sources
           ) == ["example"]

    assert :dependency_artifact_changed in Enum.map(
             Provenance.violations(start_snapshot, end_snapshot),
             & &1.kind
           )
  end

  test "generated Erlang source must match its locked grammar" do
    dir = Path.join(System.tmp_dir!(), "soak-grammar-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "src"))
    on_exit(fn -> File.rm_rf!(dir) end)

    input = "src/erlex_lexer.xrl"
    output = "src/erlex_lexer.erl"
    File.cp!(Path.join("deps/erlex", input), Path.join(dir, input))
    File.cp!(Path.join("deps/erlex", output), Path.join(dir, output))
    assert DependencySource.generated_matches?(dir, input, output)

    File.write!(Path.join(dir, output), File.read!(Path.join(dir, output)) <> "\n% patched\n")
    refute DependencySource.generated_matches?(dir, input, output)
  end

  test "operation exceptions and exits become failures without losing scenario state" do
    scenario = %{client: self(), requests: 42}
    assert {:ok, ^scenario} = Execution.protected(fn -> :ok end, scenario)

    assert {{:error, {:exception, message}}, ^scenario} =
             Execution.protected(fn -> raise "operation exploded" end, scenario)

    assert message =~ "operation exploded"

    assert {{:error, {:exit, :gone}}, ^scenario} =
             Execution.protected(fn -> exit(:gone) end, scenario)
  end

  test "thresholds reject only values beyond the acceptance limits" do
    assert Policy.threshold_failures(999, 1, 5_000, 6, 300_000, 300_000) == []
    failures = Policy.threshold_failures(998, 2, 5_001, 5, 299_999, 300_000)

    assert Enum.map(failures, & &1.kind) == [
             :error_rate,
             :latency_p99_ms,
             :insufficient_turnovers,
             :incomplete_duration
           ]
  end

  test "provenance rejects dirty trees, changes, and environment overrides" do
    clean = snapshot()
    assert Provenance.violations(clean, clean) == []

    assert Enum.map(
             Provenance.violations(%{clean | git_status_porcelain: " M file"}, clean),
             & &1.kind
           ) == [:dirty_tree, :provenance_changed]

    assert Enum.map(Provenance.violations(clean, %{clean | git_head: "def"}), & &1.kind) == [
             :provenance_changed
           ]

    override = %{clean | overrides: %{"ARBOR_RPC_PATH" => true, "ARBOR_V2_DEPS" => false}}

    assert Enum.map(Provenance.violations(override, override), & &1.kind) == [
             :environment_override
           ]

    assert Enum.map(Provenance.violations(clean, override), & &1.kind) == [
             :provenance_changed,
             :environment_override
           ]
  end

  test "era and transport selection validates names and blocked coverage" do
    config = Runner.parse!(["--era", "modern", "--transports", "beam,cowboy_host"])
    assert config.eras == [:modern]
    assert config.transports == [:beam, :cowboy_host]

    for endpoint <- [:cowboy_owned, :cowboy_host, :bandit_owned, :bandit_host],
        operation <- [:progress, :cancellation, :notification] do
      assert Policy.known_blocked(endpoint, :legacy, operation) =~ ":stream_closed"
      assert Policy.known_blocked(endpoint, :modern, operation) == nil
    end

    assert Policy.known_blocked(:beam, :legacy, :progress) == nil
    assert Runner.parse!(["--exercise-known-blocked"]).exercise_known_blocked
    assert_raise Mix.Error, ~r/--era/, fn -> Runner.parse!(["--era", "future"]) end
    assert_raise Mix.Error, ~r/--transports/, fn -> Runner.parse!(["--transports", "bogus"]) end
  end

  test "output directory must be empty before evidence creation" do
    dir = Path.join(System.tmp_dir!(), "soak-output-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    assert :ok == Runner.ensure_output!(dir)
    File.write!(Path.join(dir, "events.jsonl"), "existing evidence")
    assert_raise Mix.Error, ~r/must be empty/, fn -> Runner.ensure_output!(dir) end
  end

  test "evidence needs full clean 48-hour coverage for qualification" do
    config = %{
      output: "/tmp/soak-evidence",
      duration_ms: 172_800_000,
      eras: [:legacy, :modern],
      transports: [:beam, :stdio, :cowboy_owned, :cowboy_host, :bandit_owned, :bandit_host],
      only: nil,
      mix: Policy.default_mix()
    }

    histogram = Enum.reduce([1, 2, 3, 4, 5], Histogram.new(), &Histogram.add(&2, &1))

    state = %{
      config: config,
      summary_path: "/tmp/soak-evidence/summary.json",
      started_at: ~U[2026-10-26 00:00:00Z],
      scenarios:
        Map.new(
          for transport <- config.transports, era <- config.eras, do: {"#{transport}/#{era}", %{}}
        ),
      results:
        Map.new(
          for transport <- config.transports,
              era <- config.eras,
              operation <- Policy.applicable_operations(transport, era, config.mix) do
            {"#{transport}/#{era}/#{operation}",
             %{ok: 5, error: 0, skipped: 0, blocked: 0, latency_hist: histogram}}
          end
        ),
      timed_counts:
        Map.new(
          for transport <- config.transports,
              era <- config.eras,
              operation <- Policy.applicable_operations(transport, era, config.mix),
              do: {"#{transport}/#{era}/#{operation}", 1}
        ),
      failures: [],
      operations: 5,
      turnovers: 6,
      samples: 30,
      sample_series: samples(30),
      turnover_series:
        Map.new(
          for transport <- config.transports,
              era <- config.eras,
              do: {"#{transport}/#{era}", samples(18)}
        )
    }

    metadata = %{
      elapsed_ms: 172_800_000,
      finished_at: "2026-10-28T00:00:00Z",
      provenance_start: snapshot(),
      provenance_end: snapshot()
    }

    summary = Evidence.build(state, metadata)
    assert summary["passed"]
    assert summary["qualification_complete"]
    assert summary["leak_coverage_complete"]
    assert summary["source_commit"] == "abc123"

    assert summary["leak_sample_counts"] == %{
             periodic: 30,
             by_scenario: Map.new(state.turnover_series, fn {key, _series} -> {key, 18} end)
           }

    assert summary["overall_latency_ms"] == %{p50: 5, p95: 5, p99: 5}
    refute Evidence.build(state, %{metadata | elapsed_ms: 300_000})["qualification_complete"]

    short_config = %{state | config: %{config | duration_ms: 300_000}}
    refute Evidence.build(short_config, metadata)["qualification_complete"]

    missing = %{state | results: Map.delete(state.results, "stdio/legacy/restart")}
    refute Evidence.build(missing, metadata)["qualification_complete"]

    startup_only = %{state | timed_counts: Map.delete(state.timed_counts, "stdio/legacy/restart")}
    refute Evidence.build(startup_only, metadata)["qualification_complete"]

    few_periodic = %{state | sample_series: samples(17)}
    refute Evidence.build(few_periodic, metadata)["qualification_complete"]

    few_turnovers = put_in(state.turnover_series["stdio/legacy"], samples(17))
    refute Evidence.build(few_turnovers, metadata)["qualification_complete"]

    missing_series = %{state | turnover_series: Map.delete(state.turnover_series, "stdio/legacy")}
    refute Evidence.build(missing_series, metadata)["qualification_complete"]

    refute Evidence.build(%{state | config: %{config | only: "beam/modern"}}, metadata)[
             "qualification_complete"
           ]

    dirty = %{snapshot() | git_status_porcelain: " M dev/file.ex"}
    failed = Evidence.build(state, %{metadata | provenance_start: dirty, provenance_end: dirty})
    refute failed["passed"]
    refute failed["qualification_complete"]
    assert Enum.any?(failed["failures"], &(&1.kind == :dirty_tree))
  end

  defp snapshot do
    %{
      git_head: "abc123",
      git_status_porcelain: "",
      mix_lock_sha256: "sha",
      overrides: %{"ARBOR_RPC_PATH" => false, "ARBOR_V2_DEPS" => false},
      dependency_sources: %{"example" => %{verified: true, actual_sha256: "source"}}
    }
  end

  defp samples(count) do
    Enum.reduce(1..count, Policy.new_series(), fn _, series ->
      Policy.add_sample(series, %{processes: 100})
    end)
  end
end
