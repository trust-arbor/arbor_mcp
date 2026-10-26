defmodule Arbor.MCP.Soak.Runner do
  @moduledoc false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.Subscription
  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.{Runtime, Transport}

  alias Arbor.MCP.Soak.{
    Cleanup,
    ClientHandler,
    Evidence,
    Execution,
    Handler,
    Histogram,
    Policy,
    Provenance
  }

  @modes [legacy: {:legacy_only, "2025-11-25"}, modern: {:modern_only, "2026-07-28"}]
  @endpoints [:beam, :stdio, :cowboy_owned, :cowboy_host, :bandit_owned, :bandit_host]
  @request_key :binary.copy(<<83>>, 32)
  @telemetry_events [
    [:arbor_mcp, :client, :disconnected],
    [:arbor_mcp, :client, :reconnect, :attempt],
    [:arbor_mcp, :client, :reconnect, :success],
    [:arbor_mcp, :client, :reconnect, :error],
    [:arbor_mcp, :client, :reconnect, :timeout],
    [:arbor_mcp, :transport, :sse, :connected],
    [:arbor_mcp, :transport, :sse, :disconnected],
    [:arbor_mcp, :transport, :sse, :reconnecting]
  ]

  def run(args) do
    config = parse!(args)
    Logger.configure(level: if(config.debug, do: :debug, else: :warning))
    ensure_output!(config.output)
    events_path = Path.join(config.output, "events.jsonl")
    summary_path = Path.join(config.output, "summary.json")
    {:ok, io} = File.open(events_path, [:write, :exclusive, :binary])
    old_trap = Process.flag(:trap_exit, true)
    telemetry_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach_many(
        telemetry_id,
        @telemetry_events,
        fn event, measurements, metadata, owner ->
          send(owner, {:soak_client_event, event, measurements, metadata, self()})
        end,
        self()
      )

    state = %{
      config: config,
      io: io,
      summary_path: summary_path,
      started_at: DateTime.utc_now(),
      start_ms: now_ms(),
      scenarios: %{},
      closing_sse_pids: MapSet.new(),
      results: %{},
      failures: [],
      turnover_series: %{},
      sample_series: Policy.new_series(),
      samples: 0,
      next_sample: now_ms(),
      operations: 0,
      timed_counts: %{},
      turnovers: 0,
      scenario_cursor: 0,
      provenance_start: Provenance.capture()
    }

    try do
      checkpoint(state)

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
              latest_state(),
              :harness,
              :exception,
              Exception.format(:error, error, __STACKTRACE__)
            )
        catch
          kind, reason -> record_failure(latest_state(), :harness, kind, inspect(reason))
        end

      state = state |> drain_events() |> close_scenarios() |> drain_events()
      summary = summarize(state)
      File.write!(summary_path, Jason.encode_to_iodata!(jsonable(summary)))

      if summary["passed"], do: {:ok, summary}, else: {:error, summary}
    after
      :telemetry.detach(telemetry_id)
      Process.flag(:trap_exit, old_trap)
      Process.delete({__MODULE__, :state})
      File.close(io)
    end
  end

  @doc false
  def ensure_output!(output) do
    File.mkdir_p!(output)
    if File.ls!(output) != [], do: Mix.raise("soak output directory must be empty: #{output}")
    :ok
  end

  defp checkpoint(state) do
    Process.put({__MODULE__, :state}, state)
    state
  end

  defp latest_state, do: Process.get({__MODULE__, :state})

  @doc false
  def parse!(args) do
    switches = [
      short: :boolean,
      duration: :string,
      output: :string,
      rate: :string,
      mix: :string,
      turnover_requests: :integer,
      turnover_seconds: :integer,
      sample_seconds: :integer,
      era: :string,
      transports: :string,
      exercise_known_blocked: :boolean,
      only: :string,
      debug: :boolean
    ]

    {opts, rest, invalid} = OptionParser.parse(args, strict: switches)

    validate_args!(rest, invalid)

    duration = duration!(opts)
    {rate, ""} = opts |> Keyword.get(:rate, "2") |> Float.parse()
    mix = parse_mix!(opts[:mix])
    turnover_requests = opts[:turnover_requests] || 500
    turnover_seconds = opts[:turnover_seconds] || if(opts[:short], do: 30, else: 120)
    sample_seconds = opts[:sample_seconds] || 10
    eras = parse_eras!(opts[:era] || "both")
    transports = parse_transports!(opts[:transports] || "all")

    validate_numbers!(rate, turnover_requests, turnover_seconds, sample_seconds)
    validate_only!(opts[:only], eras, transports)

    %{
      duration_ms: duration,
      rate: rate * 1.0,
      mix: mix,
      turnover_requests: turnover_requests,
      turnover_ms: turnover_seconds * 1_000,
      sample_ms: sample_seconds * 1_000,
      eras: eras,
      transports: transports,
      exercise_known_blocked: opts[:exercise_known_blocked] || false,
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

  defp duration!(opts) do
    if opts[:short], do: 300_000, else: parse_duration!(opts[:duration] || "48h")
  end

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

  defp parse_mix!(nil), do: Policy.default_mix()

  defp parse_mix!(value) do
    allowed = Keyword.keys(Policy.default_mix())

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

  defp parse_eras!("both"), do: [:legacy, :modern]
  defp parse_eras!("legacy"), do: [:legacy]
  defp parse_eras!("modern"), do: [:modern]
  defp parse_eras!(_), do: Mix.raise("--era must be modern, legacy or both")

  defp parse_transports!("all"), do: @endpoints

  defp parse_transports!(value) do
    names = String.split(value, ",", trim: false)
    allowed = Map.new(@endpoints, &{Atom.to_string(&1), &1})

    if Enum.any?(names, &(not Map.has_key?(allowed, &1))) do
      Mix.raise(
        "--transports must be a comma-separated list of #{Enum.join(Map.keys(allowed) |> Enum.sort(), ",")}"
      )
    end

    Enum.uniq(Enum.map(names, &Map.fetch!(allowed, &1)))
  end

  defp validate_only!(nil, _eras, _transports), do: :ok

  defp validate_only!(id, eras, transports) do
    selected = for endpoint <- transports, era <- eras, do: "#{endpoint}/#{era}"
    if id not in selected, do: Mix.raise("--only must name a selected transport/era scenario")
  end

  defp start_scenarios(state) do
    Enum.reduce(state.config.transports, state, fn endpoint, state ->
      Enum.reduce(@modes, state, fn {era, {mode, version}}, state ->
        id = "#{endpoint}/#{era}"

        if era in state.config.eras and
             (state.config.only == nil or state.config.only == id) do
          case safe_open_scenario(endpoint, era, mode, version) do
            {:ok, scenario} ->
              write_event(state, %{type: "scenario_open", scenario: id})
              state |> put_in([:scenarios, id], scenario) |> checkpoint()

            {:error, reason, cleanup} ->
              record_failure(state, id, :startup, reason, cleanup)
          end
        else
          state
        end
      end)
    end)
  end

  defp safe_open_scenario(endpoint, era, mode, version) do
    open_scenario(endpoint, era, mode, version)
  rescue
    error ->
      {:error, Exception.format(:error, error, __STACKTRACE__), %{server: :startup_exception}}
  catch
    kind, reason -> {:error, inspect({kind, reason}), %{server: :startup_exit}}
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

        case safe_call(fn -> Client.start_link(opts) end) do
          {:ok, client} ->
            case safe_call(fn -> transport_tracking(client, endpoint, era) end) do
              {:ok, tracking} ->
                {:ok,
                 Map.merge(server, tracking)
                 |> Map.merge(%{
                   client: client,
                   endpoint: endpoint,
                   era: era,
                   opened_ms: now_ms(),
                   requests: 2,
                   operation_counts: %{}
                 })}

              error ->
                client_cleanup = safe_call(fn -> Client.stop(client) end)
                server_cleanup = close_unclaimed_server(server)
                {:error, inspect(error), %{client: client_cleanup, server: server_cleanup}}
            end

          error ->
            cleanup = close_unclaimed_server(server)
            {:error, inspect(error), cleanup}
        end

      {:error, {:listener_setup_failed, reason, cleanup}} ->
        {:error, inspect(reason), cleanup}

      {:error, reason} ->
        {:error, inspect(reason), %{server: :not_started}}
    end
  end

  defp transport_tracking(client, :stdio, _era) do
    with %{transport_state: %{subprocess: subprocess}} <- :sys.get_state(client),
         pid when is_integer(pid) and pid > 0 <- Arbor.RPC.Subprocess.os_pid(subprocess) do
      {:ok, %{subprocess: subprocess, os_pid: pid, sse_pid: nil}}
    else
      _ -> {:error, :stdio_child_identity_unavailable}
    end
  end

  defp transport_tracking(client, endpoint, :legacy)
       when endpoint in [:cowboy_owned, :cowboy_host, :bandit_owned, :bandit_host] do
    case :sys.get_state(client) do
      %{transport_state: %{sse_pid: pid}} when is_pid(pid) ->
        {:ok, %{sse_pid: pid, subprocess: nil, os_pid: nil}}

      _ ->
        {:error, :legacy_sse_identity_unavailable}
    end
  end

  defp transport_tracking(_client, _endpoint, _era),
    do: {:ok, %{sse_pid: nil, subprocess: nil, os_pid: nil}}

  defp server_opts(mode) do
    [
      handler: Handler,
      protocol_mode: mode,
      mrtr: mode == :modern_only,
      request_state: [active_key_id: "soak", keys: %{"soak" => @request_key}]
    ]
  end

  defp http_plug_opts(mode) do
    [
      sse_mode: :stream,
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
    port = 0

    if ownership == :owned do
      opts =
        server_opts(mode) ++
          [
            transport: :http,
            http:
              [adapter: adapter, port: port, host: {127, 0, 0, 1}, allowed_origins: :any] ++
                http_plug_opts(mode)
          ]

      with {:ok, root} <- Server.start_link(opts) do
        finish_server(root, fn ->
          with {:ok, listener_info} <- Transport.http_listener(root) do
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
          end
        end)
      end
    else
      with {:ok, root} <- Runtime.start_link(server_opts(mode) ++ [transport: :mounted_http]) do
        finish_server(root, fn ->
          with {:ok, listener, ref, port} <- start_host_listener(adapter, root, mode, port) do
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
          end
        end)
      end
    end
  end

  defp finish_server(root, fun) do
    result =
      try do
        fun.()
      rescue
        error -> {:error, Exception.format(:error, error, __STACKTRACE__)}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, _server} = success ->
        success

      error ->
        ref = Process.monitor(root)
        stop = safe_call(fn -> Server.stop(root) end)

        forced =
          if stop != :ok and Process.alive?(root) do
            Process.exit(root, :kill)
            true
          else
            false
          end

        down = await_down(ref, root)

        {:error,
         {:listener_setup_failed, error, %{server_stop: stop, server_down: down, forced: forced}}}
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
      use_sse: mode == :legacy_only
    ]

  defp listener_port(:cowboy, %{ranch_ref: ref}), do: :ranch.get_port(ref)

  defp listener_port(:bandit, %{listener: listener}) do
    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
    port
  end

  defp start_host_listener(:cowboy, root, mode, port) do
    ref = {:arbor_mcp_soak, System.unique_integer([:positive])}

    case Plug.Cowboy.http(
           Arbor.MCP.HttpPlug,
           [runtime: root, path: "/mcp", protocol_mode: mode, allowed_origins: :any] ++
             http_plug_opts(mode),
           ip: {127, 0, 0, 1},
           port: port,
           ref: ref
         ) do
      {:ok, listener} -> {:ok, listener, ref, :ranch.get_port(ref)}
      error -> error
    end
  end

  defp start_host_listener(:bandit, root, mode, port) do
    opts =
      [runtime: root, path: "/mcp", protocol_mode: mode, allowed_origins: :any] ++
        http_plug_opts(mode)

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
        else: do_run(state, deadline)
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
          {result, scenario} = execute(operation, scenario, state.config)
          state = record_result(state, id, operation, result, now_ms() - started)
          scenario = %{scenario | requests: scenario.requests + request_cost(operation)}
          state |> put_in([:scenarios, id], scenario) |> checkpoint()
        end)
      end)
    end
  end

  defp do_run(state, deadline) do
    ids = Map.keys(state.scenarios) |> Enum.sort()

    if now_ms() >= deadline or fatal?(state) or ids == [] do
      state
    else
      state = state |> drain_events() |> maybe_sample()
      id = Enum.at(ids, rem(state.scenario_cursor, length(ids)))
      state = maybe_turnover(state, id)

      if fatal?(state) or not Map.has_key?(state.scenarios, id) do
        state
      else
        scenario = state.scenarios[id]
        operation = Policy.next_operation(state.config.mix, scenario.operation_counts)
        started = now_ms()
        {result, scenario} = execute(operation, scenario, state.config)
        elapsed = now_ms() - started
        state = record_result(state, id, operation, result, elapsed)

        scenario = %{
          scenario
          | requests: scenario.requests + request_cost(operation),
            operation_counts: Map.update(scenario.operation_counts, operation, 1, &(&1 + 1))
        }

        state =
          %{
            state
            | scenarios: Map.put(state.scenarios, id, scenario),
              scenario_cursor: state.scenario_cursor + 1,
              operations: state.operations + 1,
              timed_counts: Map.update(state.timed_counts, "#{id}/#{operation}", 1, &(&1 + 1))
          }
          |> checkpoint()

        interval = trunc(1_000 / state.config.rate)
        remaining = interval - (now_ms() - started)
        if remaining > 0, do: Process.sleep(remaining)
        do_run(state, deadline)
      end
    end
  end

  defp fatal?(state), do: state.failures != []

  defp request_cost(op) when op in [:cancellation, :restart], do: 2
  defp request_cost(:notification), do: 3
  defp request_cost(op) when op in [:resource, :template, :prompt, :mrtr], do: 2
  defp request_cost(_), do: 1

  defp execute(operation, scenario, config) do
    reason = Policy.known_blocked(scenario.endpoint, scenario.era, operation)

    if reason != nil and not config.exercise_known_blocked do
      {{:known_blocked, reason}, scenario}
    else
      Execution.protected(fn -> perform(operation, scenario) end, scenario)
    end
  end

  defp perform(:restart, %{endpoint: :stdio} = scenario) do
    transport = :sys.get_state(scenario.client).transport_state
    os_pid = safe_call(fn -> Arbor.RPC.Subprocess.os_pid(transport.subprocess) end)

    child = %{
      scenario
      | subprocess: transport.subprocess,
        os_pid: if(is_integer(os_pid) and os_pid > 0, do: os_pid, else: nil)
    }

    close = safe_call(fn -> Arbor.RPC.Subprocess.close(transport.subprocess) end)
    receipt = Cleanup.child_receipt(child)

    if close == :ok and receipt == :reaped do
      with :ok <- await_planned_reconnect(scenario.client),
           {:ok, tracking} <- transport_tracking(scenario.client, :stdio, scenario.era) do
        {:scenario_update, :ok, Map.merge(scenario, tracking)}
      end
    else
      forced = Cleanup.force_child(child)
      {:error, {:restart_child_cleanup_failed, close, receipt, forced}}
    end
  end

  defp perform(:restart, _scenario), do: :skipped

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
           {:ok, {:error, :cancelled}} <- Task.yield(task, 3_000),
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

  defp await_planned_reconnect(client) do
    deadline = now_ms() + 10_000
    collect_reconnect(client, deadline, %{disconnected: 0, attempt: 0, success: 0})
  end

  defp collect_reconnect(client, deadline, counts) do
    remaining = max(deadline - now_ms(), 0)

    receive do
      {:soak_client_event, event, measurements, %{pid: ^client} = metadata, _source_pid} ->
        send(self(), {:soak_planned_reconnect_event, client, event, measurements, metadata})

        key =
          case event do
            [:arbor_mcp, :client, :disconnected] -> :disconnected
            [:arbor_mcp, :client, :reconnect, :attempt] -> :attempt
            [:arbor_mcp, :client, :reconnect, :success] -> :success
            _ -> :error
          end

        if key == :error do
          {:error, {:reconnect_event, event, measurements, inspect(metadata)}}
        else
          counts = Map.update!(counts, key, &(&1 + 1))

          if counts.success == 1 do
            with true <- Policy.reconnect_complete?(counts),
                 {:ok, _} <- Client.ping(client, timeout: 5_000) do
              send(self(), {:soak_planned_reconnect, client, counts})
              :ok
            else
              other -> {:error, {:reconnect_counts, counts, other}}
            end
          else
            collect_reconnect(client, deadline, counts)
          end
        end
    after
      remaining -> {:error, {:reconnect_timeout, counts}}
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

    if Policy.turnover?(
         scenario.requests,
         scenario.opened_ms,
         now_ms(),
         Policy.request_budget(scenario.endpoint, scenario.era, state.config.turnover_requests),
         state.config.turnover_ms
       ) do
      state = mark_closing_sse(state, scenario)
      cleanup = safe_close_scenario(scenario)
      state = drain_events(state)
      state = unmark_closing_sse(state, scenario)

      write_event(state, %{
        type: "turnover",
        scenario: id,
        cleanup: cleanup,
        requests: scenario.requests
      })

      state = %{state | turnovers: state.turnovers + 1} |> checkpoint()

      state =
        if cleanup_passed?(cleanup),
          do: state,
          else: record_failure(state, id, :cleanup, inspect(cleanup), cleanup)

      case safe_open_scenario(
             scenario.endpoint,
             scenario.era,
             mode(scenario.era),
             version(scenario.era)
           ) do
        {:ok, replacement} ->
          replacement = Policy.carry_operation_counts(scenario, replacement)
          state = state |> put_in([:scenarios, id], replacement) |> checkpoint()
          sample = metrics(state)

          series =
            state.turnover_series |> Map.get(id, Policy.new_series()) |> Policy.add_sample(sample)

          write_event(state, %{
            type: "turnover_sample",
            scenario: id,
            cycle: series.count,
            metrics: sample
          })

          check_leak(
            %{state | turnover_series: Map.put(state.turnover_series, id, series)},
            id,
            series
          )

        {:error, reason, evidence} ->
          state
          |> update_in([:scenarios], &Map.delete(&1, id))
          |> checkpoint()
          |> record_failure(id, :restart, reason, evidence)
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
      state = mark_closing_sse(state, scenario)
      cleanup = safe_close_scenario(scenario)
      write_event(state, %{type: "final_cleanup", scenario: id, cleanup: cleanup})

      if cleanup_passed?(cleanup),
        do: state,
        else: record_failure(state, id, :cleanup, inspect(cleanup), cleanup)
    end)
  end

  defp mark_closing_sse(state, %{sse_pid: pid}) when is_pid(pid),
    do: %{state | closing_sse_pids: MapSet.put(state.closing_sse_pids, pid)} |> checkpoint()

  defp mark_closing_sse(state, _scenario), do: state

  defp unmark_closing_sse(state, %{sse_pid: pid}) when is_pid(pid),
    do: %{state | closing_sse_pids: MapSet.delete(state.closing_sse_pids, pid)} |> checkpoint()

  defp unmark_closing_sse(state, _scenario), do: state

  defp safe_close_scenario(scenario) do
    scenario = refresh_tracking(scenario)

    cleanup =
      try do
        close_scenario(scenario)
      rescue
        error ->
          %{
            client_stop: {:error, Exception.message(error)},
            client_down: :unknown,
            server_stop: :unknown
          }
      catch
        kind, reason ->
          %{client_stop: {kind, inspect(reason)}, client_down: :unknown, server_stop: :unknown}
      end

    if Cleanup.complete?(cleanup) do
      cleanup
    else
      Map.put(cleanup, :forced_cleanup, Cleanup.force(scenario, cleanup))
    end
  end

  defp refresh_tracking(%{endpoint: endpoint, era: era, client: client} = scenario) do
    case safe_call(fn -> transport_tracking(client, endpoint, era) end) do
      {:ok, tracking} -> Map.merge(scenario, tracking)
      _unavailable -> scenario
    end
  end

  defp close_scenario(scenario) do
    client = scenario.client
    ref = Process.monitor(client)
    result = safe_call(fn -> Client.stop(client) end)
    down = await_down(ref, client)

    Map.merge(%{client_stop: result, client_down: down}, close_server(scenario))
    |> Map.put(:stdio_receipt, Cleanup.child_receipt(scenario))
    |> Map.put(:stdio_os_pid, scenario.os_pid)
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

    %{
      host_stop: host_stop,
      server_stop: result,
      server_down: down,
      listener_down: listener_down,
      port_free: Cleanup.port_free?(scenario)
    }
  end

  defp close_unclaimed_server(server) do
    cleanup = close_server(server)

    base =
      Map.merge(
        %{client_stop: :ok, client_down: :normal, stdio_receipt: :not_applicable},
        cleanup
      )

    if Cleanup.complete?(base) do
      cleanup
    else
      scenario = Map.merge(%{client: nil, subprocess: nil, os_pid: nil}, server)
      Map.put(cleanup, :forced_cleanup, Cleanup.force(scenario, base))
    end
  end

  defp safe_call(fun) do
    fun.()
  rescue
    error -> {:error, Exception.message(error)}
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

  defp cleanup_passed?(cleanup), do: Cleanup.complete?(cleanup)

  defp maybe_sample(state) do
    if now_ms() < state.next_sample do
      state
    else
      sample = metrics(state)
      series = Policy.add_sample(state.sample_series, sample)

      write_event(state, %{
        type: "sample",
        metrics: sample,
        operations: state.operations,
        turnovers: state.turnovers
      })

      state = %{
        state
        | samples: state.samples + 1,
          next_sample: now_ms() + state.config.sample_ms,
          sample_series: series
      }

      check_leak(state, :periodic, series)
    end
  end

  defp metrics(state) do
    Enum.each(state.scenarios, fn {_id, scenario} ->
      Enum.each([scenario.client, scenario.root], fn
        pid when is_pid(pid) -> :erlang.garbage_collect(pid)
        _ -> :ok
      end)
    end)

    :erlang.garbage_collect(self())
    tables = :ets.all()

    %{
      memory_bytes: :erlang.memory(:total),
      processes: :erlang.system_info(:process_count),
      ets_tables: length(tables),
      ets_words: Policy.ets_words(tables),
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

  defp check_leak(state, id, series) do
    Enum.reduce(Policy.leak_violations(series), state, fn violation, state ->
      record_failure(state, id, :leak, violation)
    end)
    |> checkpoint()
  end

  defp record_result(state, id, operation, result, elapsed) do
    key = "#{id}/#{operation}"

    entry =
      Map.get(state.results, key, %{
        ok: 0,
        error: 0,
        skipped: 0,
        blocked: 0,
        latency_hist: Histogram.new()
      })

    {entry, state} =
      case result do
        :ok ->
          {%{entry | ok: entry.ok + 1, latency_hist: Histogram.add(entry.latency_hist, elapsed)},
           state}

        :skipped ->
          {%{entry | skipped: entry.skipped + 1}, state}

        {:known_blocked, reason} ->
          if entry.blocked == 0 do
            write_event(state, %{
              type: "known_blocked",
              scenario: id,
              operation: operation,
              reason: reason
            })
          end

          {entry |> Map.put(:blocked, entry.blocked + 1) |> Map.put(:blocked_reason, reason),
           state}

        other ->
          kind =
            if String.contains?(inspect(other), "request_id_capacity_exceeded"),
              do: :request_id_capacity_exceeded,
              else: :operation

          {%{entry | error: entry.error + 1},
           record_failure(state, id, kind, %{operation: operation, result: inspect(other)})}
      end

    %{state | results: Map.put(state.results, key, entry)} |> checkpoint()
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
    %{state | failures: [failure | state.failures]} |> checkpoint()
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
    Evidence.build(state, %{
      elapsed_ms: now_ms() - state.start_ms,
      finished_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      provenance_start: state.provenance_start,
      provenance_end: Provenance.capture()
    })
  end

  defp drain_events(state) do
    receive do
      {:soak_client_event, event, measurements, metadata, source_pid} ->
        client = Map.get(metadata, :pid)

        scenario = Policy.scenario_for_event(state.scenarios, client, source_pid)

        write_event(state, %{
          type: "client_event",
          event: event,
          scenario: scenario,
          measurements: measurements,
          metadata: inspect(metadata),
          source_pid: inspect(source_pid)
        })

        planned_failure? =
          Enum.any?(state.failures, fn failure ->
            failure.scenario == scenario and failure.kind == :operation and
              is_map(failure.reason) and Map.get(failure.reason, :operation) == :restart
          end)

        state =
          if Policy.unexpected_client_event?(event, scenario != nil, planned_failure?) or
               Policy.unexpected_stream_event?(
                 event,
                 scenario != nil,
                 MapSet.member?(state.closing_sse_pids, source_pid)
               ) do
            record_failure(state, scenario, :unexpected_disconnect, %{
              event: event,
              metadata: inspect(metadata)
            })
          else
            state
          end

        drain_events(state)

      {:soak_planned_reconnect, client, counts} ->
        scenario =
          Enum.find_value(state.scenarios, fn {id, value} ->
            if value.client == client, do: id
          end)

        write_event(state, %{type: "planned_reconnect", scenario: scenario, counts: counts})
        drain_events(state)

      {:soak_planned_reconnect_event, client, event, measurements, metadata} ->
        scenario =
          Enum.find_value(state.scenarios, fn {id, value} ->
            if value.client == client, do: id
          end)

        write_event(state, %{
          type: "planned_reconnect_event",
          scenario: scenario,
          event: event,
          measurements: measurements,
          metadata: inspect(metadata)
        })

        drain_events(state)

      {:EXIT, pid, reason} ->
        state =
          if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason) do
            state
          else
            record_failure(state, :harness, :linked_exit, %{
              pid: inspect(pid),
              reason: inspect(reason)
            })
          end

        drain_events(state)
    after
      0 -> state
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp jsonable(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, jsonable(item)} end)

  defp jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)
  defp jsonable(value) when is_tuple(value), do: %{tuple: value |> Tuple.to_list() |> jsonable()}
  defp jsonable(value) when is_pid(value) or is_reference(value), do: inspect(value)
  defp jsonable(value), do: value
end
