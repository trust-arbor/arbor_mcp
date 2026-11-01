# Repo-only host for the official Tasks extension scenarios. Task storage,
# routing, envelopes and lifecycle operations all use the published library.
unless Code.ensure_loaded?(Arbor.MCP) do
  Mix.install([{:arbor_mcp, path: "."}, {:plug_cowboy, "~> 2.7"}, {:ranch, "== 1.8.1"}])
end

{:ok, _started} = Application.ensure_all_started(:arbor_mcp)
{:ok, _started} = Application.ensure_all_started(:plug_cowboy)

defmodule TasksConformanceHandler do
  use Arbor.MCP.Server.Handler, tasks: :store

  alias Arbor.MCP.Server.Context
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Tasks
  alias Arbor.MCP.Tasks.Extension
  alias Arbor.MCP.Tasks.Server, as: TaskServer

  def __server_capabilities__, do: Extension.put_capability(%{"tools" => %{}})
  def __server_info__, do: %{name: "arbor-tasks-conformance", version: "1.0.0"}

  @impl true
  def init(_args), do: {:ok, %{}}

  @impl true
  def handle_list_tools(_cursor, state) do
    tools =
      for name <-
            ~w(greet slow_compute failing_job protocol_error_job confirm_delete multi_input test_tool_with_task) do
        %{
          name: name,
          description: "Official Tasks conformance fixture: #{name}",
          inputSchema: %{
            type: "object",
            properties: %{name: %{type: "string"}, seconds: %{type: "number"}}
          }
        }
      end

    {:ok, tools, nil, state}
  end

  @impl true
  def handle_call_tool("greet", args, state),
    do: {:ok, result("Hello, #{args["name"] || "World"}!"), state}

  def handle_call_tool("test_tool_with_task" = name, args, state) do
    responses = Context.input_responses() || %{}

    cond do
      not declared?() ->
        TaskServer.create(name, args, state)

      map_size(responses) == 0 ->
        {:input_required, input_requests(["user_name"]), %{"phase" => "collect-name"}, state}

      true ->
        start_task(name, Map.put(args, "responses", responses), state)
    end
  end

  def handle_call_tool(name, args, state)
      when name in ~w(slow_compute failing_job protocol_error_job confirm_delete multi_input) do
    if declared?() or name == "failing_job" do
      start_task(name, args, state)
    else
      {:ok, result("Synchronous #{name}"), state}
    end
  end

  def handle_call_tool(name, _args, state),
    do: {:error, Arbor.MCP.Error.method_not_found(name), state}

  defp start_task(name, args, state) do
    {:ok, service} = Runtime.service(:tasks)
    opts = [service: service, owner: Tasks.owner(), notify: false, ttl: 60_000, poll_interval: 20]

    case TaskServer.create(name, args, state, opts) do
      {:ok, created, state} ->
        id = created["taskId"]

        if name in ["confirm_delete", "multi_input"] do
          keys = if name == "multi_input", do: ["first", "second"], else: ["approval"]
          {:ok, _waiting} = Tasks.require_input(id, input_requests(keys), opts)
        end

        seconds = if name == "slow_compute", do: max(args["seconds"] || 0, 0), else: 0
        finish_at = System.monotonic_time(:millisecond) + trunc(seconds * 1_000)

        {:ok, _worker} =
          Task.Supervisor.start_child(TasksConformanceWorkers, fn ->
            run_task(id, name, args, opts, finish_at)
          end)

        {:ok, created, state}

      error ->
        error
    end
  end

  defp run_task(id, name, args, opts, finish_at) do
    {:ok, current} = Tasks.get(id, opts)
    {:ok, cancelled?} = Tasks.cancellation_requested?(id, opts)

    cond do
      cancelled? ->
        {:ok, _cancelled} = Tasks.mark_cancelled(id, opts)

      current["status"] == "input_required" or System.monotonic_time(:millisecond) < finish_at ->
        receive do
        after
          20 -> run_task(id, name, args, opts, finish_at)
        end

      name == "protocol_error_job" ->
        {:ok, _failed} = Tasks.fail(id, %{"code" => -32603, "message" => "Fixture failure"}, opts)

      name == "failing_job" ->
        {:ok, _completed} =
          Tasks.complete(id, Map.put(result("Fixture tool error"), "isError", true), opts)

      true ->
        {:ok, responses} = Tasks.take_input_responses(id, opts)
        text = "Completed #{name}: #{Jason.encode!(args)} #{Jason.encode!(responses)}"
        {:ok, _completed} = Tasks.complete(id, result(text), opts)
    end
  end

  defp declared?, do: Extension.declared?(Context.current().client_capabilities)
  defp result(text), do: %{"content" => [%{"type" => "text", "text" => text}]}

  defp input_requests(keys) do
    Map.new(keys, fn key ->
      {key,
       %{
         "method" => "elicitation/create",
         "params" => %{
           "mode" => "form",
           "message" => "Provide #{key}",
           "requestedSchema" => %{
             "type" => "object",
             "properties" => %{key => %{"type" => "string"}},
             "required" => [key]
           }
         }
       }}
    end)
  end
end

defmodule TasksConformanceRouter do
  @behaviour Plug

  @opts Arbor.MCP.HttpPlug.init(
          runtime: TasksConformanceRuntime,
          protocol_mode: :modern_only,
          mrtr: true,
          request_state: [active_key_id: "tasks", keys: %{"tasks" => :binary.copy(<<42>>, 32)}],
          allowed_hosts: ["localhost", "127.0.0.1", "::1", "[::1]"],
          allowed_origins: :any
        )

  @impl true
  def init(_opts), do: []

  @impl true
  def call(conn, _opts), do: Arbor.MCP.HttpPlug.call(conn, @opts)
end

port = String.to_integer(List.first(System.argv(), "3099"))

{:ok, _supervisor} =
  Supervisor.start_link(
    [
      {Task.Supervisor, name: TasksConformanceWorkers},
      {Arbor.MCP.Server.Runtime,
       name: TasksConformanceRuntime,
       handler: TasksConformanceHandler,
       transport: :mounted_http,
       services: [replay_cache: []]},
      {Plug.Cowboy,
       scheme: :http, plug: TasksConformanceRouter, options: [port: port, ip: {127, 0, 0, 1}]}
    ],
    strategy: :one_for_one
  )

IO.puts("Server ready on http://localhost:#{port}/mcp")

receive do
  :stop -> :ok
end
