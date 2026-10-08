defmodule Arbor.MCP.Compliance.Handlers.Handler20251125 do
  @moduledoc """
  Test handler for MCP 2025-11-25 compliance.

  It retains the 2025-06-18 handler's tools, resources, prompts, completion,
  roots, sampling, and subscription behavior while advertising 2025-11-25 and
  adding task callbacks.
  """

  use Arbor.MCP.Server.Handler

  alias Arbor.MCP.Compliance.Handlers.Handler20250618, as: PreviousHandler

  @impl true
  def init(args), do: PreviousHandler.init(args)

  @impl true
  def handle_initialize(_params, state) do
    {:ok,
     %{
       protocolVersion: "2025-11-25",
       serverInfo: %{name: "test-server-2025-11-25", version: "1.0.0"},
       capabilities: Arbor.MCP.Internal.VersionRegistry.capabilities_for_version("2025-11-25")
     }, state}
  end

  @impl true
  def handle_list_tools(cursor, state), do: PreviousHandler.handle_list_tools(cursor, state)

  @impl true
  def handle_call_tool(name, arguments, state),
    do: PreviousHandler.handle_call_tool(name, arguments, state)

  @impl true
  def handle_list_resources(cursor, state),
    do: PreviousHandler.handle_list_resources(cursor, state)

  @impl true
  def handle_read_resource(uri, state), do: PreviousHandler.handle_read_resource(uri, state)

  @impl true
  def handle_subscribe_resource(uri, state),
    do: PreviousHandler.handle_subscribe_resource(uri, state)

  @impl true
  def handle_unsubscribe_resource(uri, state),
    do: PreviousHandler.handle_unsubscribe_resource(uri, state)

  @impl true
  def handle_list_prompts(cursor, state), do: PreviousHandler.handle_list_prompts(cursor, state)

  @impl true
  def handle_get_prompt(name, arguments, state),
    do: PreviousHandler.handle_get_prompt(name, arguments, state)

  @impl true
  def handle_list_resource_templates(cursor, state),
    do: PreviousHandler.handle_list_resource_templates(cursor, state)

  @impl true
  def handle_list_roots(state), do: PreviousHandler.handle_list_roots(state)

  @impl true
  def handle_create_message(params, state),
    do: PreviousHandler.handle_create_message(params, state)

  @impl true
  def handle_complete(ref, argument, state),
    do: PreviousHandler.handle_complete(ref, argument, state)

  @impl true
  def handle_set_log_level(level, state),
    do: PreviousHandler.handle_set_log_level(level, state)

  @impl true
  def handle_task_get(task_id, state) do
    {:ok, %{taskId: task_id, status: "working"}, state}
  end

  @impl true
  def handle_task_list(_cursor, state) do
    {:ok, [], nil, state}
  end

  @impl true
  def handle_task_result(task_id, state) do
    {:ok, %{taskId: task_id, status: "completed", result: %{}}, state}
  end

  @impl true
  def handle_task_cancel(task_id, state) do
    {:ok, %{taskId: task_id, status: "cancelled"}, state}
  end
end
