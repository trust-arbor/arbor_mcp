defmodule CombinedArchiveConsumer do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime

  defmodule RuntimeHandler do
    def init(_args), do: {:ok, 0}

    def dispatch(request, _module, state, _opts) do
      {:response, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => state + 1}, state + 1}
    end
  end

  defmodule NativeAgent do
    @behaviour Arbor.ACP.Agent.Handler

    def init(_opts), do: {:ok, %{}}

    def handle_new_session(_params, _ctx, state),
      do: {:reply, %{"sessionId" => "consumer-session"}, state}

    def handle_prompt(session_id, _prompt, ctx, state) do
      :ok = Arbor.ACP.Agent.agent_message(ctx.agent, session_id, "archive message")
      {:reply, %{"stopReason" => "end_turn"}, state}
    end
  end

  defmodule RoleHandler do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "archive-role-probe", version: "1"

    tool "echo", "Echo text" do
      param(:message, :string, required: true)
      run(fn %{message: message}, state -> {:ok, ToolResult.text(message), state} end)
    end
  end

  def probe do
    {:ok, _} = Application.ensure_all_started(:combined_archive_consumer)

    for app <- [:arbor_rpc, :arbor_mcp, :arbor_acp, :arbor_acp_adapters] do
      expected_version =
        System.get_env("ARCHIVE_EXPECTED_VERSION_#{String.upcase(Atom.to_string(app))}") ||
          System.fetch_env!("ARCHIVE_EXPECTED_VERSION")

      ^expected_version = app |> Application.spec(:vsn) |> to_string()
    end

    verify_package_boundaries()

    System.put_env("PATH", "/no-runtime-compiler")
    System.put_env("CC", "/compiler-must-not-run")
    nil = System.find_executable("cc")
    verify_installed_helper()
    verify_independent_lifetimes()
    verify_role_entrypoints()
    verify_scoped_acp()
    record_installation()

    IO.puts("Four archive apps, MCP/ACP lifetimes and compiler-free native ownership pass")
  end

  defp verify_role_entrypoints do
    alias Arbor.MCP.{Client, Response, Server}
    {:ok, server} = Server.start_link(handler: RoleHandler, transport: :beam)

    try do
      :ok = Client.probe({:beam, server: server}, protocol_mode: :legacy_only)
      true = Process.alive?(server)
      {:ok, client} = Client.connect({:beam, server: server}, protocol_mode: :legacy_only)

      try do
        {:ok, %Response{tools: [_tool]}} = Client.tools(client)
        {:ok, [definition]} = Client.tool_definitions(client)
        "echo" = Response.tool_name(definition)
        {:ok, [^definition]} = Client.all_tools(client)
        {:ok, %Response{}} = Client.call(client, "echo", %{"message" => "complete"})
        {:ok, "content"} = Client.call_content(client, "echo", %{"message" => "content"})
        {:ok, _status} = Client.status(client)
        {:ok, _stats} = Server.stats(server)
        :ok = Client.disconnect(client)
        true = Process.alive?(client)
      after
        :ok = Client.stop(client)
      end
    after
      :ok = Server.stop(server)
    end
  end

  defp verify_package_boundaries do
    apps = [:arbor_rpc, :arbor_mcp, :arbor_acp, :arbor_acp_adapters]
    started = Application.started_applications() |> Enum.map(&elem(&1, 0))
    true = Enum.all?(apps, &(&1 in started))
    modules = Enum.flat_map(apps, &Application.spec(&1, :modules))
    true = length(modules) == MapSet.size(MapSet.new(modules))

    for module <- [
          Arbor.ACP.Adapters.ClaudeSDK,
          Arbor.ACP.Adapters.Codex,
          Arbor.ACP.Adapters.Pi,
          Arbor.ACP.Adapters.ZCode
        ],
        do: true = Code.ensure_loaded?(module)

    core_modules = Application.spec(:arbor_acp, :modules)

    false =
      Enum.any?(
        core_modules,
        &String.starts_with?(Atom.to_string(&1), "Elixir.Arbor.ACP.Adapters.")
      )

    for app <- [:cowboy, :cowlib, :ranch, :plug_cowboy, :bandit, :thousand_island, :websock],
        do: nil = Application.spec(app, :vsn)
  end

  defp verify_scoped_acp do
    alias Arbor.ACP.Agent.Transport.Memory
    alias Arbor.ACP.Client
    {:ok, peer} = Memory.new_pair()
    {:ok, agent} = Arbor.ACP.Agent.start_link(handler: NativeAgent, transport: {:memory, peer})

    try do
      {:ok, pids} =
        Client.with_connection([transport_mod: Memory, peer: peer, role: :client], fn client ->
          {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")

          {:ok,
           %{result: %{"stopReason" => "end_turn"}, text: "archive message", truncated?: false}} =
            Client.prompt_text(client, session_id, "collect text")

          state = :sys.get_state(client)
          [client, state.handler_pid, state.receiver_pid]
        end)

      true = Enum.all?(pids, &(not Process.alive?(&1)))
    after
      for pid <- [agent, peer], do: :ok = stop_owned_process(pid)
    end
  end

  defp verify_installed_helper do
    priv = :arbor_rpc |> :code.priv_dir() |> List.to_string()
    true = File.regular?(Path.join(priv, "native/arbor_rpc_subprocess"))

    {:ok, "installed-final\r\nlast", 7} =
      Arbor.RPC.Subprocess.capture([
        "/bin/sh",
        "-c",
        "printf 'installed-final\\r\\nlast'; exit 7"
      ])

    {:ok, child} = Arbor.RPC.Subprocess.open(["/bin/sleep", "30"], process_group: true)
    {:ok, %{frames: 0}} = Arbor.RPC.Subprocess.stats(child)
    :ok = Arbor.RPC.Subprocess.close(child)

    {:ok, %{direct_child: :reaped, targeted_group: :absent}} =
      Arbor.RPC.Subprocess.cleanup_receipt(child)

    :ok = Arbor.RPC.Subprocess.close(child)
  end

  defp verify_independent_lifetimes do
    alias Arbor.ACP.Agent.Transport.Memory

    {:ok, runtime} = Runtime.start_link(handler: RuntimeHandler, dispatcher: RuntimeHandler)
    {:ok, peer} = Memory.new_pair()
    {:ok, agent} = Arbor.ACP.Agent.start_link(handler: NativeAgent, transport: {:memory, peer})
    {:ok, client} = Arbor.ACP.Client.start_link(transport_mod: Memory, peer: peer, role: :client)

    try do
      {:ok, %{reserved: 0}} = Runtime.stats(runtime)
      {:ok, :ready} = Arbor.ACP.Client.status(client)
      {:ok, :ready} = Arbor.ACP.Agent.status(agent)
      {:ok, %{"result" => 1}} = Runtime.request(runtime, request(1))

      {:ok, %{"sessionId" => "consumer-session"}} =
        Arbor.ACP.Client.new_session(client, "/tmp/project")

      {:ok, %{"stopReason" => "end_turn"}} =
        Arbor.ACP.Client.prompt(client, "consumer-session", "hello")

      {:ok, %{"result" => 2}} = Runtime.request(runtime, request(2))
      :ok = Runtime.stop(runtime)

      {:ok, %{"stopReason" => "end_turn"}} =
        Arbor.ACP.Client.prompt(client, "consumer-session", "after MCP stop")

      {:ok, sibling} = Runtime.start_link(handler: RuntimeHandler, dispatcher: RuntimeHandler)

      try do
        :ok = Arbor.ACP.Client.disconnect(client)
        {:ok, :disconnected} = Arbor.ACP.Client.status(client)
        :ok = Arbor.ACP.Client.stop(client)
        false = Process.alive?(client)
        {:ok, %{"result" => 1}} = Runtime.request(sibling, request(3))
      after
        Runtime.stop(sibling)
      end
    after
      Runtime.stop(runtime)

      for pid <- [client, agent, peer], do: :ok = stop_owned_process(pid)
    end
  end

  # Disconnect can make the ACP agent exit normally while stop/3 is entering
  # :sys.terminate. Accept that race only after exact native DOWN confirmation.
  # Stop and confirmation share the original 1,000 ms cleanup budget.
  defp stop_owned_process(pid) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    monitor = Process.monitor(pid)

    stopped =
      try do
        GenServer.stop(pid, :normal, cleanup_remaining(deadline))
      catch
        :exit, reason -> {:exit, reason}
      end

    down =
      receive do
        {:DOWN, ^monitor, :process, ^pid, reason} -> {:down, reason}
      after
        cleanup_remaining(deadline) -> :unconfirmed
      end

    Process.demonitor(monitor, [:flush])

    case {stopped, down} do
      {:ok, {:down, :normal}} ->
        :ok

      {{:exit, reason}, {:down, actual}} when actual in [:normal, :noproc] ->
        if normal_stop_race?(reason, pid),
          do: :ok,
          else: {:error, {:owned_process_stop_failed, reason, down}}

      _other ->
        {:error, {:owned_process_stop_failed, stopped, down}}
    end
  end

  defp normal_stop_race?({reason, {GenServer, :stop, [pid, :normal, _timeout]}}, pid) do
    case reason do
      normal when normal in [:normal, :noproc] ->
        true

      {normal, {:sys, :terminate, [^pid, :normal, _timeout]}} when normal in [:normal, :noproc] ->
        true

      _other ->
        false
    end
  end

  defp normal_stop_race?(_reason, _pid), do: false

  defp cleanup_remaining(deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp request(id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "increment"}

  defp record_installation do
    if path = System.get_env("ARCHIVE_INSTALL_REPORT") do
      apps = [:arbor_rpc, :arbor_mcp, :arbor_acp, :arbor_acp_adapters]
      helper = Path.join(to_string(:code.priv_dir(:arbor_rpc)), "native/arbor_rpc_subprocess")

      digest = fn path ->
        path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
      end

      packages =
        Map.new(apps, fn app ->
          app_file = Path.join([to_string(:code.lib_dir(app)), "ebin", "#{app}.app"])
          modules = Application.spec(app, :modules)

          code =
            Map.new(modules, fn module ->
              {Atom.to_string(module), digest.(to_string(:code.which(module)))}
            end)

          {Atom.to_string(app),
           %{
             version: to_string(Application.spec(app, :vsn)),
             app_sha256: digest.(app_file),
             beam_sha256: code
           }}
        end)

      File.write!(path, Jason.encode!(%{helper_sha256: digest.(helper), packages: packages}))
    end
  end
end
