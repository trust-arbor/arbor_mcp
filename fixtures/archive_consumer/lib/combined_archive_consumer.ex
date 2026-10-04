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

    def handle_prompt(_id, _prompt, _ctx, state),
      do: {:reply, %{"stopReason" => "end_turn"}, state}
  end

  def probe do
    {:ok, _} = Application.ensure_all_started(:combined_archive_consumer)
    verify_package_boundaries()

    System.put_env("PATH", "/no-runtime-compiler")
    System.put_env("CC", "/compiler-must-not-run")
    nil = System.find_executable("cc")
    verify_installed_helper()
    verify_independent_lifetimes()
    IO.puts("Four archive apps, MCP/ACP lifetimes and compiler-free native ownership pass")
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
        {:ok, %{"result" => 1}} = Runtime.request(sibling, request(3))
      after
        Runtime.stop(sibling)
      end
    after
      Runtime.stop(runtime)

      for pid <- [client, agent, peer],
          do: if(Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000))
    end
  end

  defp request(id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "increment"}
end
