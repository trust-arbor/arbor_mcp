defmodule Arbor.MCP.Examples.ForwardingGateway.Upstream do
  @moduledoc false
  use Arbor.MCP.Server.Handler
  alias Arbor.MCP.Server.Context

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}

  @impl true
  def handle_list_tools(_cursor, state) do
    tools =
      for name <- ~w(echo ask hold) do
        %{
          "name" => name,
          "description" => "Controlled #{state.source} fixture: #{name}",
          "inputSchema" => %{"type" => "object"}
        }
      end

    {:ok, tools, nil, state}
  end

  @impl true
  def handle_call_tool("echo", arguments, state), do: result(arguments, state)

  def handle_call_tool("ask", _arguments, state) do
    if state[:observer],
      do:
        send(
          state.observer,
          {:upstream_round, state.principal, state.source, Context.progress_token()}
        )

    case Context.input_responses() do
      nil ->
        :ok = Context.report_progress(1, 2, "asking")

        request = %{
          "method" => "elicitation/create",
          "params" => %{
            "message" => "What should we call you?",
            "requestedSchema" => %{
              "type" => "object",
              "properties" => %{"name" => %{"type" => "string"}},
              "required" => ["name"]
            }
          }
        }

        {:input_required, %{"name" => request}, %{"step" => 1}, state}

      %{"name" => %{"action" => "accept", "content" => %{"name" => name}}} ->
        :ok = Context.report_progress(2, 2, "answered")
        result(%{"greeting" => "Hello, #{name}"}, state)

      _denied ->
        result(%{"declined" => true}, state)
    end
  end

  def handle_call_tool("hold", arguments, state) do
    send(state.observer, {:upstream_holding, state.principal, state.source, self()})

    receive do
      :release ->
        result(arguments, state)

      {:arbor_mcp_cancelled, _token, reason} ->
        send(state.observer, {:upstream_cancelled, state.principal, state.source, reason})
        {:error, %{code: -32603, message: "Cancelled"}, state}
    end
  end

  defp result(arguments, state) do
    value = %{"source" => state.source, "principal" => state.principal, "arguments" => arguments}

    {:ok,
     %{
       "content" => [%{"type" => "text", "text" => Jason.encode!(value)}],
       "structuredContent" => value
     }, state}
  end
end

defmodule Arbor.MCP.Examples.ForwardingGateway.ClientHandler do
  @moduledoc false
  @behaviour Arbor.MCP.Client.Handler

  def init(opts), do: {:ok, Map.new(opts)}
  def handle_ping(state), do: {:ok, %{}, state}
  def handle_list_roots(state), do: {:ok, [], state}

  def handle_create_message(_params, state),
    do: {:error, "Sampling is not part of this example", state}

  def handle_elicitation_create(_message, _schema, state),
    do: {:ok, %{"action" => "accept", "content" => %{"name" => state.principal}}, state}

  def handle_progress(_request, params, state) do
    if state[:observer], do: send(state.observer, {:downstream_progress, state.principal, params})
    {:ok, state}
  end
end

defmodule Arbor.MCP.Examples.ForwardingGateway.Demo do
  @moduledoc false
  use GenServer
  alias Arbor.MCP.{Client, Server}
  alias Arbor.MCP.Examples.ForwardingGateway.{ClientHandler, Handler, HTTPPlug, Upstream, Watcher}
  alias Arbor.MCP.Server.Runtime

  @principals ~w(alice bob)
  @sources ~w(alpha beta)
  @form %{"elicitation" => %{"form" => %{}}}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def fixture(pid), do: GenServer.call(pid, :fixture)

  @impl true
  def init(opts) do
    {:ok, demo} = start(opts)
    {:ok, demo}
  end

  @impl true
  def handle_call(:fixture, _from, demo), do: {:reply, demo, demo}

  @impl true
  def terminate(_reason, demo), do: stop(demo)

  def start(opts \\ []) do
    {:ok, root} = DynamicSupervisor.start_link(strategy: :one_for_one)

    try do
      observer = Keyword.get(opts, :observer, self())

      upstreams =
        Map.new(@sources, fn source ->
          identities =
            Map.new(@principals, fn principal ->
              runtime =
                child(
                  root,
                  {Runtime,
                   runtime_options(Upstream,
                     principal: principal,
                     source: source,
                     observer: observer
                   )}
                )

              {"fixture-#{source}-#{principal}", %{principal: principal, runtime: runtime}}
            end)

          {source, %{identities: identities, url: listener(root, identities, :modern_only)}}
        end)

      gateways =
        Map.new(@principals, fn principal ->
          clients =
            Map.new(@sources, fn source ->
              client =
                child(
                  root,
                  {Client,
                   [
                     transport: :http,
                     url: upstreams[source].url,
                     headers: [{"authorization", "Bearer fixture-#{source}-#{principal}"}],
                     protocol_mode: :modern_only,
                     conformance_mode: false,
                     capabilities: @form,
                     health_check_interval: nil
                   ]}
                )

              {source, client}
            end)

          routes =
            Map.new(
              Enum.flat_map(clients, fn {source, client} ->
                {:ok, tools} = Client.all_tools(client, timeout: 5_000)

                Enum.map(tools, fn tool ->
                  name = tool["name"]
                  alias_name = source <> "__" <> name

                  {alias_name,
                   %{client: client, name: name, definition: Map.put(tool, "name", alias_name)}}
                end)
              end)
            )

          runtime = child(root, {Runtime, runtime_options(Handler, routes: routes)})
          watcher = child(root, {Watcher, [runtime: runtime, clients: Map.values(clients)]})
          :ok = Watcher.ready(watcher)
          {principal, %{runtime: runtime, watcher: watcher, clients: clients}}
        end)

      identities =
        Map.new(gateways, fn {principal, gateway} ->
          {"fixture-gateway-#{principal}", %{principal: principal, runtime: gateway.runtime}}
        end)

      {:ok,
       %{
         root: root,
         upstreams: upstreams,
         gateways: gateways,
         url: listener(root, identities, :prefer_modern, Keyword.get(opts, :call_timeout, 5_000))
       }}
    rescue
      error ->
        Supervisor.stop(root)
        reraise error, __STACKTRACE__
    end
  end

  def connect(demo, principal, opts \\ []) do
    defaults = [
      transport: :http,
      url: demo.url,
      protocol_mode: :modern_only,
      headers: [{"authorization", "Bearer fixture-gateway-#{principal}"}],
      capabilities: @form,
      handler: {ClientHandler, [principal: principal, observer: opts[:observer]]},
      health_check_interval: nil
    ]

    {:ok, child(demo.root, {Client, Keyword.merge(defaults, Keyword.delete(opts, :observer))})}
  end

  def notify(demo, principal, source) do
    runtime = demo.upstreams[source].identities["fixture-#{source}-#{principal}"].runtime
    Server.notify_tools_changed(runtime)
  end

  def stop_identity(demo, principal) do
    gateway = demo.gateways[principal]
    :ok = DynamicSupervisor.terminate_child(demo.root, gateway.watcher)
    :ok = DynamicSupervisor.terminate_child(demo.root, gateway.runtime)

    Enum.each(gateway.clients, fn {_source, client} ->
      DynamicSupervisor.terminate_child(demo.root, client)
    end)
  end

  def stop(demo) do
    if Process.alive?(demo.root) do
      children = DynamicSupervisor.which_children(demo.root)

      for {_id, pid, _type, [Watcher]} <- children,
          do: DynamicSupervisor.terminate_child(demo.root, pid)

      for {_id, pid, _type, [Client]} <- children,
          do: DynamicSupervisor.terminate_child(demo.root, pid)

      Supervisor.stop(demo.root)
    end

    :ok
  end

  defp runtime_options(handler, handler_args) do
    [
      handler: handler,
      handler_args: handler_args,
      transport: :mounted_http,
      protocol_mode: :prefer_modern,
      mrtr: true,
      request_state: [
        active_key_id: "example",
        keys: %{"example" => :crypto.strong_rand_bytes(32)}
      ],
      services: [replay_cache: []],
      require_replay_protection: true,
      request_timeout_ms: 5_000,
      max_concurrency: 8
    ]
  end

  defp child(root, spec) do
    spec = Supervisor.child_spec(spec, id: make_ref(), restart: :temporary)
    {:ok, pid} = DynamicSupervisor.start_child(root, spec)
    pid
  end

  defp listener(root, identities, mode, timeout \\ 5_000) do
    ref = {:forwarding_example, make_ref()}
    plug = {HTTPPlug, [identities: identities, protocol_mode: mode, timeout: timeout]}

    spec =
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: plug,
        options: [ip: {127, 0, 0, 1}, port: 0, ref: ref]
      )

    child(root, spec)
    "http://127.0.0.1:#{:ranch.get_port(ref)}/mcp"
  end
end
