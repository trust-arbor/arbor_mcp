defmodule Arbor.MCP.Protocol.Methods do
  @moduledoc """
  Canonical registry of MCP methods understood by ArborMCP.

  Every row records the method name, its inclusive version bounds, whether it
  is a request or notification, and the consumer-specific handler functions.
  Consumers derive their dispatch maps and version gates from this registry so
  method additions do not require parallel string tables.

  Unknown methods remain version-available for backward compatibility; the
  individual dispatchers still decide whether to invoke a custom-method hook or
  return `Method not found`.
  """

  alias Arbor.MCP.Internal.RevisionCatalog

  @type version :: String.t()
  @type kind :: :request | :notification
  @type consumer :: :server_dispatch | :message_processor | :request_processor
  @type handlers :: %{optional(consumer()) => atom()}
  @type row :: {String.t(), version(), version() | nil, kind(), handlers()}

  @versions RevisionCatalog.legacy_versions()
  @v2024 Enum.at(@versions, 3)
  @v20250618 Enum.at(@versions, 1)
  @v20251125 Enum.at(@versions, 0)
  @v20260728 RevisionCatalog.known_versions() |> hd()

  @modern_methods ~w(
    server/discover
    completion/complete
    prompts/get
    prompts/list
    resources/list
    resources/templates/list
    resources/read
    subscriptions/listen
    tasks/cancel
    tasks/get
    tasks/update
    tools/call
    tools/list
    notifications/cancelled
    notifications/tasks
  )

  @rows [
    {"initialize", @v2024, nil, :request,
     %{
       server_dispatch: :initialize,
       request_processor: :process_initialize
     }},
    {"ping", @v2024, nil, :request, %{server_dispatch: :ping}},
    {"tools/list", @v2024, nil, :request,
     %{
       server_dispatch: :tools_list,
       message_processor: :handle_tools_list,
       request_processor: :process_tools_list
     }},
    {"tools/call", @v2024, nil, :request,
     %{
       server_dispatch: :tools_call,
       message_processor: :handle_tools_call,
       request_processor: :process_tools_call
     }},
    {"resources/list", @v2024, nil, :request,
     %{
       server_dispatch: :resources_list,
       message_processor: :handle_resources_list,
       request_processor: :process_resources_list
     }},
    {"resources/templates/list", @v2024, nil, :request,
     %{
       server_dispatch: :resource_templates_list,
       message_processor: :handle_resource_templates_list
     }},
    {"resources/read", @v2024, nil, :request,
     %{
       server_dispatch: :resources_read,
       message_processor: :handle_resources_read,
       request_processor: :process_resources_read
     }},
    {"resources/subscribe", @v2024, nil, :request,
     %{
       server_dispatch: :resources_subscribe,
       message_processor: :handle_resources_subscribe
     }},
    {"resources/unsubscribe", @v2024, nil, :request,
     %{
       server_dispatch: :resources_unsubscribe,
       message_processor: :handle_resources_unsubscribe
     }},
    {"prompts/list", @v2024, nil, :request,
     %{
       server_dispatch: :prompts_list,
       message_processor: :handle_prompts_list,
       request_processor: :process_prompts_list
     }},
    {"prompts/get", @v2024, nil, :request,
     %{
       server_dispatch: :prompts_get,
       message_processor: :handle_prompts_get,
       request_processor: :process_prompts_get
     }},
    {"completion/complete", @v2024, nil, :request,
     %{
       server_dispatch: :completion_complete,
       message_processor: :handle_completion_complete
     }},
    {"logging/setLevel", @v2024, nil, :request,
     %{
       server_dispatch: :set_log_level,
       message_processor: :handle_set_log_level
     }},
    {"roots/list", @v2024, nil, :request,
     %{
       server_dispatch: :roots_list,
       message_processor: :handle_roots_list
     }},
    {"sampling/createMessage", @v2024, nil, :request, %{}},
    {"elicitation/create", @v20250618, nil, :request, %{}},
    {"tasks/get", @v20251125, nil, :request,
     %{
       server_dispatch: :task_get,
       message_processor: :handle_task_get,
       request_processor: :process_task_get
     }},
    {"tasks/list", @v20251125, nil, :request,
     %{
       server_dispatch: :task_list,
       message_processor: :handle_task_list,
       request_processor: :process_task_list
     }},
    {"tasks/result", @v20251125, nil, :request,
     %{
       server_dispatch: :task_result,
       message_processor: :handle_task_result,
       request_processor: :process_task_result
     }},
    {"tasks/cancel", @v20251125, nil, :request,
     %{
       server_dispatch: :task_cancel,
       message_processor: :handle_task_cancel,
       request_processor: :process_task_cancel
     }},
    {"tasks/update", @v20260728, @v20260728, :request,
     %{
       server_dispatch: :task_update,
       message_processor: :handle_task_update,
       request_processor: :process_task_update
     }},
    {"server/discover", @v20260728, @v20260728, :request,
     %{
       server_dispatch: :server_discover,
       message_processor: :handle_server_discover,
       request_processor: :process_server_discover
     }},
    {"subscriptions/listen", @v20260728, @v20260728, :request, %{}},
    {"notifications/initialized", @v2024, nil, :notification,
     %{request_processor: :process_initialized_notification}},
    {"notifications/tools/list_changed", @v2024, nil, :notification, %{}},
    {"notifications/resources/list_changed", @v2024, nil, :notification, %{}},
    {"notifications/prompts/list_changed", @v2024, nil, :notification, %{}},
    {"notifications/progress", @v2024, nil, :notification, %{}},
    {"notifications/message", @v2024, nil, :notification, %{}},
    {"notifications/cancelled", @v2024, nil, :notification, %{}},
    {"notifications/resources/updated", @v2024, nil, :notification, %{}},
    {"notifications/roots/list_changed", @v2024, nil, :notification, %{}},
    {"notifications/tasks/status", @v20251125, nil, :notification,
     %{request_processor: :process_task_status_notification}},
    {"notifications/tasks", @v20260728, @v20260728, :notification, %{}},
    {"notifications/elicitation/complete", @v20251125, nil, :notification,
     %{
       server_dispatch: :elicitation_complete,
       request_processor: :process_elicitation_complete
     }}
  ]

  @doc "Returns every canonical method row."
  @spec rows() :: [row()]
  def rows, do: @rows

  @doc "Returns the methods handled by a specific dispatcher."
  @spec methods_for(consumer()) :: [String.t()]
  def methods_for(consumer) do
    for {method, _min, _max, _kind, handlers} <- @rows,
        Map.has_key?(handlers, consumer),
        do: method
  end

  @doc "Returns a method-to-handler map for a specific dispatcher."
  @spec handler_map(consumer()) :: %{String.t() => atom()}
  def handler_map(consumer) do
    Map.new(@rows, fn {method, _min, _max, _kind, handlers} ->
      {method, Map.get(handlers, consumer)}
    end)
    |> Enum.reject(fn {_method, handler} -> is_nil(handler) end)
    |> Map.new()
  end

  @doc "Returns the notification methods available in a version."
  @spec notification_methods(version()) :: [String.t()]
  def notification_methods(version) do
    for {method, _min, _max, :notification, _handlers} <- @rows,
        available?(method, version),
        do: method
  end

  @doc "Returns request methods introduced by a version after the base revision."
  @spec introduced_request_methods(version()) :: [String.t()]
  def introduced_request_methods(version) do
    for {method, min, _max, :request, _handlers} <- @rows,
        min == version,
        min != @v2024,
        method not in ["elicitation/create", "server/discover", "subscriptions/listen"],
        do: method
  end

  @doc "Checks the version bounds for a known method. Unknown methods remain allowed."
  @spec available?(String.t(), version()) :: boolean()
  def available?(method, version) do
    case Enum.find(@rows, fn {known, _min, _max, _kind, _handlers} -> known == method end) do
      nil ->
        true

      {_method, _min, _max, _kind, _handlers} when version == @v20260728 ->
        method in @modern_methods

      {_method, min, max, _kind, _handlers} ->
        within_bounds?(version, min, max)
    end
  end

  defp within_bounds?(version, min, max) do
    version_index = Enum.find_index(@versions, &(&1 == version))
    min_index = Enum.find_index(@versions, &(&1 == min))
    max_index = max && Enum.find_index(@versions, &(&1 == max))

    is_integer(version_index) and is_integer(min_index) and
      version_index <= min_index and (is_nil(max_index) or version_index >= max_index)
  end
end
