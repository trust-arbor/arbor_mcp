defmodule Arbor.MCP.Soak.Runner do
  @moduledoc false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.Subscription
  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.{Runtime, Transport}
  alias Arbor.MCP.Soak.{ClientHandler, Handler}

  @modes [legacy: {:legacy_only, "2025-11-25"}, modern: {:modern_only, "2026-07-28"}]
  @endpoints [:beam, :stdio, :cowboy_owned, :cowboy_host, :bandit_owned, :bandit_host]
  @default_mix [
    echo: 40,
    list: 12,
    resource: 8,
    template: 8,
    prompt: 8,
    progress: 8,
    cancellation: 4,
    notification: 4,
    mrtr: 4,
    ping: 4
  ]
  @request_key :binary.copy(<<83>>, 32)

  def run(args) do
    config = parse!(args)
    Logger.configure(level: if(config.debug, do: :debug, else: :warning))
    File.mkdir_p!(config.output)
    events_path = Path.join(config.output, "events.jsonl")
    summary_path = Path.join(config.output, "summary.json")
    {:ok, io} = File.open(events_path, [:write, :binary])

    state = %{
      config: config,
      io: io,
      summary_path: summary_path,
      started_at: DateTime.utc_now(),
      start_ms: now_ms(),
      scenarios: %{},
      results: %{},
      failures: [],
      turnover_samples: [],
      samples: 0,
      next_sample: now_ms(),
      operations: 0,
      turnovers: 0,
      scenario_cursor: 0
    }

    state =
      try do
        state
        |> start_scenarios()
        |> exercise_scenarios()
        |> then(&%{&1 | start_ms: now_ms(), next_sample: now_ms()})
        |> run_until_deadline()
      rescue
        error ->
          record_failure(
            state,
            :harness,
            :exception,
            Exception.format(:error, error, __STACKTRACE__)
          )
      catch
        kind, reason -> record_failure(state, :harness, kind, inspect(reason))
      end

    state = close_scenarios(state)
    summary = summarize(state)
    File.write!(summary_path, Jason.encode_to_iodata!(jsonable(summary)))
    File.close(io)

    if summary["passed"], do: {:ok, summary}, else: {:error, summary}
  end

  defp parse!(args) do
    switches = [
      short: :boolean,
      duration: :string,
      output: :string,
      rate: :string,
      mix: :string,
      turnover_requests: :integer,
      turnover_seconds: :integer,
      sample_seconds: :integer,
      only: :string,
      debug: :boolean
    ]

    {opts, rest, invalid} = OptionParser.parse(args, strict: switches)

    validate_args!(rest, invalid)

    duration = if opts[:short], do: 300_000, else: parse_duration!(opts[:duration] || "48h")
    {rate, ""} = opts |> Keyword.get(:rate, "2") |> Float.parse()
    mix = parse_mix!(opts[:mix])
    turnover_requests = opts[:turnover_requests] || 500
    turnover_seconds = opts[:turnover_seconds] || if(opts[:short], do: 30, else: 120)
    sample_seconds = opts[:sample_seconds] || 10

    validate_numbers!(rate, turnover_requests, turnover_seconds, sample_seconds)

    %{
      duration_ms: duration,
      rate: rate * 1.0,
      mix: mix,
      turnover_requests: turnover_requests,
      turnover_ms: turnover_seconds * 1_000,
      sample_ms: sample_seconds * 1_000,
      only: opts[:only],
      debug: opts[:debug] || false,
      output:
        Path.expand(
          opts[:output] ||
            "_build/soak/#{DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(":", "-")}"
        )
    }
  end

  defp validate_args!([], []), do: :ok

  defp validate_args!(rest, invalid),
    do: Mix.raise("invalid soak arguments: #{inspect(rest ++ invalid)}")

  defp validate_numbers!(rate, requests, turnover, sample) do
    if rate <= 0, do: Mix.raise("--rate must be positive")

    if requests < 20 or requests > 5_000,
      do: Mix.raise("--turnover-requests must be between 20 and 5000")

    if turnover <= 0 or sample <= 0,
      do: Mix.raise("turnover and sample seconds must be positive")
  end

  defp parse_duration!(value) do
    case Regex.run(~r/^(\d+)(s|m|h)$/, value) do
      [_, n, unit] ->
        String.to_integer(n) * %{"s" => 1_000, "m" => 60_000, "h" => 3_600_000}[unit]

      _ ->
        Mix.raise("--duration must be Ns, Nm or Nh")
    end
  end

  defp parse_mix!(nil), do: @default_mix

  defp parse_mix!(value) do
    allowed = Keyword.keys(@default_mix)

    mix =
      for part <- String.split(value, ","), part != "" do
        case String.split(part, ":") do
          [name, weight] ->
            atom = String.to_existing_atom(name)
            number = String.to_integer(weight)
            if atom not in allowed or number <= 0, do: Mix.raise("invalid --mix entry: #{part}")
            {atom, number}

          _ ->
            Mix.raise("invalid --mix entry: #{part}")
        end
      end

    if mix == [], do: Mix.raise("--mix cannot be empty")
    mix
  rescue
    ArgumentError -> Mix.raise("invalid --mix entry")
  end

  defp start_scenarios(state) do
    Enum.reduce(@endpoints, state, fn endpoint, state ->
      Enum.reduce(@modes, state, fn {era, {mode, version}}, state ->
        id = "#{endpoint}/#{era}"

        if state.config.only == nil or state.config.only == id do
          case open_scenario(endpoint, era, mode, version) do
            {:ok, scenario} ->
              write_event(state, %{type: "scenario_open", scenario: id})
              put_in(state.scenarios[id], scenario)

            {:error, reason, cleanup} ->
              record_failure(state, id, :startup, reason, cleanup)
          end
        else
          state
        end
      end)
    end)
  end

  defp open_scenario(endpoint, era, mode, version) do
    case open_server(endpoint, mode) do
      {:ok, server} ->
        opts = [
          protocol_mode: mode,
          protocol_version: version,
          health_check_interval: nil,
          handler: {ClientHandler, [owner: self()]},
          capabilities: %{"elicitation" => %{"form" => %{}}},
          reconnect: true
        ]

        opts = Keyword.merge(opts, server.client_opts)

        case Client.start_link(opts) do
          {:ok, client} ->
            {:ok,
             Map.merge(server, %{
               client: client,
               endpoint: endpoint,
               era: era,
               opened_ms: now_ms(),
               requests: 2
             })}

          error ->
            cleanup = close_server(server)
            {:error, inspect(error), cleanup}
        end

      {:error, reason} ->
        {:error, inspect(reason), %{server: :not_started}}
    end
  end

  defp server_opts(mode) do
    [
      handler: Handler,
      protocol_mode: mode,
      mrtr: mode == :modern_only,
      request_state: [active_key_id: "soak", keys: %{"soak" => @request_key}]
    ]
  end

  defp mrtr_opts(mode) do
    [
      mrtr: mode == :modern_only,
      request_state: [active_key_id: "soak", keys: %{"soak" => @request_key}]
    ]
  end

  defp open_server(:beam, mode) do
    with {:ok, root} <- Server.start_link(server_opts(mode) ++ [transport: :beam]) do
      {:ok,
       %{
         root: root,
         listener: nil,
         listener_ref: nil,
         client_opts: [transport: :beam, server: root]
       }}
    end
  end

  defp open_server(:stdio, mode) do
    elixir = System.find_executable("elixir") || raise "elixir executable not found"
    era = if mode == :modern_only, do: "modern", else: "legacy"
    env = [{"ERL_LIBS", Path.expand("_build/#{Mix.env()}/lib")}, {"ARBOR_SOAK_ERA", era}]

    {:ok,
     %{
       root: nil,
       listener: nil,
       listener_ref: nil,
       client_opts: [
         transport: :stdio,
         command: [elixir, "-e", "Arbor.MCP.Soak.ServerHost.run()"],
         env: env
       ]
     }}
  end

  defp open_server(endpoint, mode) do
    {adapter, ownership} = http_endpoint(endpoint)
    port = free_port()
    origin = "http://127.0.0.1:#{port}"

    if ownership == :owned do
      opts =
        server_opts(mode) ++
          [
            transport: :http,
            http:
              [adapter: adapter, port: port, host: {127, 0, 0, 1}, allowed_origins: [origin]] ++
                mrtr_opts(mode)
          ]

      with {:ok, root} <- Server.start_link(opts) do
        case Transport.http_listener(root) do
          {:ok, listener_info} ->
            port = listener_port(adapter, listener_info)

            {:ok,
             %{
               root: root,
               listener: listener_info.listener,
               listener_ref: Map.get(listener_info, :ranch_ref),
               owned: true,
               adapter: adapter,
               port: port,
               client_opts: http_client_opts(port, mode)
             }}

          error ->
            :ok = Server.stop(root)
            error
        end
      end
    else
      with {:ok, root} <- Runtime.start_link(server_opts(mode) ++ [transport: :mounted_http]) do
        case start_host_listener(adapter, root, mode, port, origin) do
          {:ok, listener, ref, port} ->
            {:ok,
             %{
               root: root,
               listener: listener,
               listener_ref: ref,
               owned: false,
               adapter: adapter,
               port: port,
               client_opts: http_client_opts(port, mode)
             }}

          error ->
            :ok = Server.stop(root)
            error
        end
      end
    end
  end

  defp http_endpoint(:cowboy_owned), do: {:cowboy, :owned}
  defp http_endpoint(:cowboy_host), do: {:cowboy, :host}
  defp http_endpoint(:bandit_owned), do: {:bandit, :owned}
  defp http_endpoint(:bandit_host), do: {:bandit, :host}

  defp http_client_opts(port, mode),
    do: [
      transport: :http,
      url: "http://127.0.0.1:#{port}/mcp",
      use_sse: mode == :legacy_only,
      stream_idle_timeout: 2_000
    ]

  defp listener_port(:cowboy, %{ranch_ref: ref}), do: :ranch.get_port(ref)

  defp listener_port(:bandit, %{listener: listener}) do
    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
    port
  end

  defp start_host_listener(:cowboy, root, mode, port, origin) do
    ref = {:arbor_mcp_soak, System.unique_integer([:positive])}

    case Plug.Cowboy.http(
           Arbor.MCP.HttpPlug,
           [runtime: root, path: "/mcp", protocol_mode: mode, allowed_origins: [origin]] ++
             mrtr_opts(mode),
           ip: {127, 0, 0, 1},
           port: port,
           ref: ref
         ) do
      {:ok, listener} -> {:ok, listener, ref, :ranch.get_port(ref)}
      error -> error
    end
  end

  defp start_host_listener(:bandit, root, mode, port, origin) do
    opts =
      [runtime: root, path: "/mcp", protocol_mode: mode, allowed_origins: [origin]] ++
        mrtr_opts(mode)

    case Bandit.start_link(
           plug: {Arbor.MCP.HttpPlug, opts},
           port: port,
           ip: {127, 0, 0, 1},
           startup_log: false
         ) do
      {:ok, listener} ->
        {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
        {:ok, listener, nil, port}

      error ->
        error
    end
  end

  defp run_until_deadline(state) do
    deadline = state.start_ms + state.config.duration_ms
    ids = Map.keys(state.scenarios) |> Enum.sort()

    if ids == [] do
      record_failure(state, :harness, :no_scenarios, "no connection established")
    else
      if Enum.any?(state.failures, &(&1.kind == :startup)),
        do: state,
        else: do_run(state, ids, deadline)
    end
  end

  defp exercise_scenarios(state) do
    if Enum.any?(state.failures, &(&1.kind == :startup)) do
      state
    else
      Enum.reduce(Enum.sort(Map.keys(state.scenarios)), state, fn id, state ->
        if state.config.debug do
          client_state = :sys.get_state(state.scenarios[id].client)
          transport = client_state.transport_state

          write_event(state, %{
            type: "client_debug",
            scenario: id,
            receiver_task: inspect(client_state.receiver_task),
            sse_pid: inspect(Map.get(transport, :sse_pid)),
            sse_alive:
              is_pid(Map.get(transport, :sse_pid)) and
                Process.alive?(Map.get(transport, :sse_pid))
          })
        end

        Enum.reduce(Keyword.keys(state.config.mix), state, fn operation, state ->
          scenario = state.scenarios[id]
          started = now_ms()
          result = perform(operation, scenario)
          state = record_result(state, id, operation, result, now_ms() - started)
          scenario = %{scenario | requests: scenario.requests + request_cost(operation)}
          put_in(state.scenarios[id], scenario)
        end)
      end)
    end
  end

  defp do_run(state, ids, deadline) do
    if now_ms() >= deadline or fatal?(state) do
      state
    else
      state = maybe_sample(state)
      id = Enum.at(ids, rem(state.scenario_cursor, length(ids)))
      state = maybe_turnover(state, id)
      scenario = state.scenarios[id]
      operation = choose_operation(state)
      started = now_ms()
      result = perform(operation, scenario)
      elapsed = now_ms() - started
      state = record_result(state, id, operation, result, elapsed)

      scenario = %{
        state.scenarios[id]
        | requests: state.scenarios[id].requests + request_cost(operation)
      }

      state = %{
        state
        | scenarios: Map.put(state.scenarios, id, scenario),
          scenario_cursor: state.scenario_cursor + 1,
          operations: state.operations + 1
      }

      interval = trunc(1_000 / state.config.rate)
      remaining = interval - (now_ms() - started)
      if remaining > 0, do: Process.sleep(remaining)
      do_run(state, ids, deadline)
    end
  end

  defp fatal?(state) do
    Enum.any?(state.failures, fn f -> f.kind in [:request_id_capacity_exceeded, :leak] end)
  end

  defp request_cost(:cancellation), do: 2
  defp request_cost(:notification), do: 3
  defp request_cost(op) when op in [:resource, :template, :prompt, :mrtr], do: 2
  defp request_cost(_), do: 1

  defp choose_operation(state) do
    mix = state.config.mix
    total = Enum.reduce(mix, 0, fn {_op, weight}, sum -> sum + weight end)
    pick = rem(state.operations, total)

    Enum.reduce_while(mix, pick, fn {op, weight}, remaining ->
      if remaining < weight, do: {:halt, op}, else: {:cont, remaining - weight}
    end)
  end

  defp perform(:echo, scenario) do
    value = "soak-#{System.unique_integer([:positive])}"

    with {:ok, %{"content" => [%{"text" => ^value}]}} <-
           Client.call_tool(scenario.client, "echo", %{"value" => value},
             format: :map,
             timeout: 5_000
           )
           |> normalized(),
         do: :ok
  end

  defp perform(:list, scenario) do
    with {:ok, %{"tools" => tools}} <-
           Client.list_tools(scenario.client,
             format: :map,
             timeout: 5_000
           )
           |> normalized(),
         true <- Enum.any?(tools, &(&1["name"] == "echo")),
         do: :ok
  end

  defp perform(:resource, scenario) do
    with {:ok, %{"resources" => [_ | _]}} <-
           Client.list_resources(scenario.client, format: :map, timeout: 5_000) |> normalized(),
         {:ok, %{"contents" => [%{"text" => "soak soak://fixed"}]}} <-
           Client.read_resource(scenario.client, "soak://fixed",
             format: :map,
             timeout: 5_000
           )
           |> normalized(),
         do: :ok
  end

  defp perform(:template, scenario) do
    with {:ok, %{"resourceTemplates" => [_ | _]}} <-
           Client.list_resource_templates(scenario.client, format: :map, timeout: 5_000)
           |> normalized(),
         {:ok, %{"contents" => [%{"text" => "soak soak://item/one"}]}} <-
           Client.read_resource(scenario.client, "soak://item/one",
             format: :map,
             timeout: 5_000
           )
           |> normalized(),
         do: :ok
  end

  defp perform(:prompt, scenario) do
    with {:ok, %{"prompts" => [_ | _]}} <-
           Client.list_prompts(scenario.client, format: :map, timeout: 5_000) |> normalized(),
         {:ok, %{"messages" => [%{"content" => %{"text" => "Hi soak"}}]}} <-
           Client.get_prompt(scenario.client, "greet", %{"name" => "soak"},
             format: :map,
             timeout: 5_000
           )
           |> normalized(),
         do: :ok
  end

  defp perform(:progress, scenario) do
    token = "soak-#{System.unique_integer([:positive])}"

    with {:ok, _} <-
           Client.call_tool(scenario.client, "progress", %{},
             progress_token: token,
             format: :map,
             timeout: 5_000
           ),
         :ok <- receive_progress(token, 2_000),
         do: receive_progress(token, 2_000)
  end

  defp perform(:cancellation, scenario) do
    token = "cancel-#{System.unique_integer([:positive])}"

    task =
      Task.async(fn ->
        Client.call_tool(scenario.client, "hold", %{},
          progress_token: token,
          format: :map,
          timeout: 5_000
        )
      end)

    result =
      with :ok <- receive_progress(token, 2_000),
           [request_id] <- Client.get_pending_requests(scenario.client),
           :ok <- Client.send_cancelled(scenario.client, request_id, "soak cancellation"),
           {:error, :cancelled} <- Task.await(task, 3_000),
           do: :ok

    if result != :ok and Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    result
  end

  defp perform(:notification, %{era: :modern} = scenario) do
    with {:ok, subscription} <-
           Client.listen(scenario.client, %{"toolsListChanged" => true}, timeout: 5_000),
         {:ok, %{"content" => [%{"text" => ":ok"}]}} <-
           Client.call_tool(scenario.client, "notify", %{},
             format: :map,
             timeout: 5_000
           )
           |> normalized() do
      result =
        receive do
          {:ex_mcp_subscription, ^subscription, "notifications/tools/list_changed", _} -> :ok
        after
          2_000 -> {:error, :notification_timeout}
        end

      :ok = Subscription.cancel(subscription)
      result
    end
  end

  defp perform(:notification, scenario) do
    with {:ok, listener} <-
           Client.subscribe_notifications(
             scenario.client,
             %{"toolsListChanged" => true}
           ),
         {:ok, %{"content" => [%{"text" => ":ok"}]}} <-
           Client.call_tool(scenario.client, "notify", %{},
             format: :map,
             timeout: 5_000
           )
           |> normalized() do
      result =
        receive do
          {:ex_mcp_notification, ^listener, "notifications/tools/list_changed", _} -> :ok
        after
          2_000 -> {:error, :notification_timeout}
        end

      :ok = Client.unsubscribe_notifications(listener)
      result
    end
  end

  defp perform(:mrtr, %{era: :legacy}), do: :skipped

  defp perform(:mrtr, scenario) do
    with {:ok, %{"resultType" => "complete", "content" => [%{"text" => "hello soak"}]}} <-
           Client.call_tool(scenario.client, "onboard", %{}, format: :map, timeout: 5_000)
           |> normalized() do
      receive do
        :soak_elicitation -> :ok
      after
        2_000 -> {:error, :elicitation_not_observed}
      end
    end
  end

  defp perform(:ping, scenario) do
    case Client.ping(scenario.client, timeout: 5_000) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp receive_progress(token, timeout) do
    receive do
      {:soak_progress, _request_id, %{"progressToken" => ^token}} -> :ok
    after
      timeout -> {:error, :progress_timeout}
    end
  end

  defp normalized({:ok, value}) when is_map(value),
    do: {:ok, value |> Jason.encode!() |> Jason.decode!()}

  defp normalized(other), do: other

  defp maybe_turnover(state, id) do
    scenario = state.scenarios[id]

    if scenario.requests >= state.config.turnover_requests or
         now_ms() - scenario.opened_ms >= state.config.turnover_ms do
      cleanup = close_scenario(scenario)

      write_event(state, %{
        type: "turnover",
        scenario: id,
        cleanup: cleanup,
        requests: scenario.requests
      })

      state = %{state | turnovers: state.turnovers + 1}

      state =
        if cleanup_passed?(cleanup),
          do: state,
          else: record_failure(state, id, :cleanup, inspect(cleanup), cleanup)

      case open_scenario(
             scenario.endpoint,
             scenario.era,
             mode(scenario.era),
             version(scenario.era)
           ) do
        {:ok, replacement} ->
          state = put_in(state.scenarios[id], replacement)
          sample = metrics()
          check_leak(%{state | turnover_samples: [sample | state.turnover_samples]}, id)

        {:error, reason, evidence} ->
          record_failure(state, id, :restart, reason, evidence)
      end
    else
      state
    end
  end

  defp mode(:legacy), do: :legacy_only
  defp mode(:modern), do: :modern_only
  defp version(:legacy), do: "2025-11-25"
  defp version(:modern), do: "2026-07-28"

  defp close_scenarios(state) do
    Enum.reduce(state.scenarios, state, fn {id, scenario}, state ->
      cleanup = close_scenario(scenario)
      write_event(state, %{type: "final_cleanup", scenario: id, cleanup: cleanup})

      if cleanup_passed?(cleanup),
        do: state,
        else: record_failure(state, id, :cleanup, inspect(cleanup), cleanup)
    end)
  end

  defp close_scenario(scenario) do
    client = scenario.client
    ref = Process.monitor(client)
    result = safe_call(fn -> Client.stop(client) end)
    down = await_down(ref, client)
    Map.merge(%{client_stop: result, client_down: down}, close_server(scenario))
  end

  defp close_server(%{root: nil}), do: %{server_stop: :not_owned}

  defp close_server(%{root: root} = scenario) do
    listener = Map.get(scenario, :listener)
    owned = Map.get(scenario, :owned, false)

    host_stop =
      if listener && !owned do
        case scenario.adapter do
          :cowboy -> safe_call(fn -> Plug.Cowboy.shutdown(scenario.listener_ref) end)
          :bandit -> safe_call(fn -> Supervisor.stop(listener) end)
        end
      else
        :not_host
      end

    ref = Process.monitor(root)
    result = safe_call(fn -> Server.stop(root) end)
    down = await_down(ref, root)
    listener_down = if listener, do: not Process.alive?(listener), else: :not_applicable
    %{host_stop: host_stop, server_stop: result, server_down: down, listener_down: listener_down}
  end

  defp safe_call(fun) do
    fun.()
  catch
    kind, reason -> {kind, inspect(reason)}
  end

  defp await_down(ref, pid) do
    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> reason
    after
      5_000 -> :timeout
    end
  end

  defp cleanup_passed?(cleanup) do
    cleanup.client_stop == :ok and cleanup.client_down in [:normal, :noproc] and
      cleanup.server_stop in [:ok, :not_owned] and
      Map.get(cleanup, :server_down, :normal) in [:normal, :noproc] and
      Map.get(cleanup, :host_stop, :not_host) in [:ok, :not_host] and
      Map.get(cleanup, :listener_down, true) in [true, :not_applicable]
  end

  defp maybe_sample(state) do
    if now_ms() < state.next_sample do
      state
    else
      sample = metrics()

      write_event(state, %{
        type: "sample",
        metrics: sample,
        operations: state.operations,
        turnovers: state.turnovers
      })

      %{state | samples: state.samples + 1, next_sample: now_ms() + state.config.sample_ms}
    end
  end

  defp metrics do
    tables = :ets.all()

    %{
      memory_bytes: :erlang.memory(:total),
      processes: :erlang.system_info(:process_count),
      ets_tables: length(tables),
      ets_words:
        Enum.reduce(tables, 0, fn table, sum -> sum + (:ets.info(table, :memory) || 0) end),
      ports: length(Port.list()),
      file_descriptors: file_descriptors()
    }
  end

  defp file_descriptors do
    case System.cmd("lsof", ["-n", "-P", "-p", System.pid()], stderr_to_stdout: true) do
      {output, 0} -> max(length(String.split(output, "\n", trim: true)) - 1, 0)
      _ -> nil
    end
  rescue
    ErlangError -> nil
  end

  defp check_leak(state, id) do
    samples = Enum.take(state.turnover_samples, 6) |> Enum.reverse()

    thresholds = %{
      memory_bytes: 32 * 1_048_576,
      processes: 20,
      ets_words: 100_000,
      ports: 10,
      file_descriptors: 20
    }

    Enum.reduce(thresholds, state, fn {key, threshold}, state ->
      values = Enum.map(samples, &Map.get(&1, key))

      if length(values) == 6 and Enum.all?(values, &is_integer/1) and
           increasing?(values) and
           List.last(values) - hd(values) > threshold do
        record_failure(state, id, :leak, %{metric: key, values: values, threshold: threshold})
      else
        state
      end
    end)
  end

  defp increasing?(values) do
    values
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> b > a end)
  end

  defp record_result(state, id, operation, result, elapsed) do
    key = "#{id}/#{operation}"
    entry = Map.get(state.results, key, %{ok: 0, error: 0, skipped: 0, latency_ms: []})

    {entry, state} =
      case result do
        :ok ->
          {%{entry | ok: entry.ok + 1, latency_ms: [elapsed | entry.latency_ms]}, state}

        :skipped ->
          {%{entry | skipped: entry.skipped + 1}, state}

        other ->
          kind =
            if String.contains?(inspect(other), "request_id_capacity_exceeded"),
              do: :request_id_capacity_exceeded,
              else: :operation

          {%{entry | error: entry.error + 1},
           record_failure(state, id, kind, %{operation: operation, result: inspect(other)})}
      end

    %{state | results: Map.put(state.results, key, entry)}
  end

  defp record_failure(state, scenario, kind, reason, cleanup \\ nil) do
    failure = %{
      scenario: scenario,
      kind: kind,
      reason: reason,
      cleanup: cleanup,
      at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    write_event(state, Map.put(failure, :type, "failure"))
    %{state | failures: [failure | state.failures]}
  end

  defp write_event(state, event) do
    IO.binwrite(state.io, [
      Jason.encode_to_iodata!(
        jsonable(Map.put(event, :at, DateTime.utc_now() |> DateTime.to_iso8601()))
      ),
      "\n"
    ])

    :file.sync(state.io)
  end

  defp summarize(state) do
    results =
      for {key, entry} <- state.results, into: %{} do
        {key,
         Map.drop(entry, [:latency_ms])
         |> Map.put(
           :latency_ms,
           percentiles(entry.latency_ms)
         )}
      end

    successes = Enum.reduce(state.results, 0, fn {_key, e}, sum -> sum + e.ok end)
    errors = Enum.reduce(state.results, 0, fn {_key, e}, sum -> sum + e.error end)
    latencies = state.results |> Map.values() |> Enum.flat_map(& &1.latency_ms)
    overall = percentiles(latencies)
    error_rate = if successes + errors == 0, do: 1.0, else: errors / (successes + errors)
    elapsed = now_ms() - state.start_ms
    config = state.config

    threshold_failures =
      []
      |> maybe_threshold(error_rate > 0.001, :error_rate, error_rate)
      |> maybe_threshold(overall.p99 > 5_000, :latency_p99_ms, overall.p99)
      |> maybe_threshold(
        length(state.turnover_samples) < 6,
        :insufficient_turnovers,
        length(state.turnover_samples)
      )
      |> maybe_threshold(elapsed < config.duration_ms, :incomplete_duration, elapsed)

    failures = Enum.reverse(state.failures) ++ threshold_failures

    %{
      "passed" => failures == [],
      "summary_path" => state.summary_path,
      "events_path" => Path.join(config.output, "events.jsonl"),
      "started_at" => DateTime.to_iso8601(state.started_at),
      "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "elapsed_ms" => elapsed,
      "source_commit" => git_head(),
      "mix_lock_sha256" =>
        Base.encode16(:crypto.hash(:sha256, File.read!("mix.lock")), case: :lower),
      "elixir" => System.version(),
      "otp" => List.to_string(:erlang.system_info(:otp_release)),
      "platform" => :erlang.system_info(:system_architecture) |> List.to_string(),
      "os" => :os.type() |> inspect(),
      "config" => config,
      "scenarios" => Map.keys(state.scenarios) |> Enum.sort(),
      "operations" => state.operations,
      "turnovers" => state.turnovers,
      "samples" => state.samples,
      "overall_latency_ms" => overall,
      "results" => results,
      "failures" => failures
    }
  end

  defp maybe_threshold(failures, true, kind, value),
    do: failures ++ [%{kind: kind, value: value}]

  defp maybe_threshold(failures, false, _kind, _value), do: failures

  defp percentiles([]), do: %{p50: 0, p95: 0, p99: 0}

  defp percentiles(values) do
    sorted = Enum.sort(values)
    n = length(sorted)

    %{
      p50: Enum.at(sorted, ceil(n * 0.5) - 1),
      p95: Enum.at(sorted, ceil(n * 0.95) - 1),
      p99: Enum.at(sorted, ceil(n * 0.99) - 1)
    }
  end

  defp git_head do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {hash, 0} -> String.trim(hash)
      _ -> nil
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp jsonable(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, jsonable(item)} end)

  defp jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)
  defp jsonable(value) when is_tuple(value), do: %{tuple: value |> Tuple.to_list() |> jsonable()}
  defp jsonable(value) when is_pid(value) or is_reference(value), do: inspect(value)
  defp jsonable(value), do: value
end
