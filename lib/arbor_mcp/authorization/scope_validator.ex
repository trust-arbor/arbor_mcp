defmodule Arbor.MCP.Authorization.ScopeValidator do
  @moduledoc """
  Maps MCP operations to required OAuth scopes and validates them.

  This module provides a centralized way to manage scope requirements for
  different MCP methods. It defines a standard set of scopes following the
  `mcp:<domain>:<action>` convention and offers functions to retrieve required
  scopes for a method and validate them against the scopes granted in a token.

  ## Standard Scopes

  The following standard scopes are defined. Only explicitly declared wildcard
  scopes can satisfy more-specific scopes. For example, a token with the
  `mcp:tools:execute` scope can access any tool, satisfying the more specific
  `mcp:tools:execute:<tool_name>` requirement.

  ### Tools
  - `mcp:tools:list`: Allows listing available tools (`tools/list`).
  - `mcp:tools:get`: Allows retrieving the definition of a specific tool (`tools/get`).
  - `mcp:tools:execute`: Allows executing any tool. This is a wildcard scope.
  - `mcp:tools:execute:<tool_name>`: Allows executing a specific tool (`tools/execute`).

  ### Resources
  - `mcp:resources:list`: Allows listing available resources (`resources/list`).
  - `mcp:resources:get`: Allows retrieving any specific resource (`resources/get`).
  - `mcp:resources:create`: Allows creating any new resource (`resources/create`).
  - `mcp:resources:update`: Allows updating any existing resource (`resources/update`).
  - `mcp:resources:delete`: Allows deleting any resource (`resources/delete`).
  - More granular resource scopes (e.g., `mcp:resources:get:<resource_id>`) can be
    implemented with a custom mapper.

  ### Prompts
  - `mcp:prompts:execute`: Allows executing a prompt (`prompts/execute`).

  ## Usage

  To get the required scopes for an MCP request:

      request = %{"method" => "tools/list"}
      Arbor.MCP.Authorization.ScopeValidator.get_required_scopes(request)
      #=> ["mcp:tools:list"]

      execute_request = %{
        "method" => "tools/execute",
        "params" => %{"tool_name" => "my_calculator"}
      }
      Arbor.MCP.Authorization.ScopeValidator.get_required_scopes(execute_request)
      #=> ["mcp:tools:execute:my_calculator"]

  To validate scopes from a token:

      token_scopes = ["mcp:tools:execute"]
      required_scopes = ["mcp:tools:execute:my_calculator"]

      Arbor.MCP.Authorization.ScopeValidator.validate(token_scopes, required_scopes)
      #=> :ok

      token_scopes = ["mcp:tools:list", "mcp:tools:get"]
      required_scopes = ["mcp:tools:execute:my_calculator"]
      Arbor.MCP.Authorization.ScopeValidator.validate(token_scopes, required_scopes)
      #=> {:error, :insufficient_scope}

  ## Extensibility

  The scope mapping can be extended by passing a custom mapping function
  to `get_required_scopes/2`. This function receives the request map and should
  return a list of required scopes. If it returns `nil`, the standard mapping
  is used as a fallback.

      my_mapper = fn
        %{"method" => "custom/op"} -> ["my:custom:scope"]
        %{"method" => "resources/get", "params" => %{"id" => resource_id}} ->
          ["mcp:resources:get:" <> resource_id]
        _ ->
          nil # Fallback to default for other methods
      end

      Arbor.MCP.Authorization.ScopeValidator.get_required_scopes(request, my_mapper)
  """

  alias Arbor.MCP.Internal.MessageValidator

  @type token_scopes :: [String.t()]
  @type required_scopes :: [String.t()]
  @type request :: map()
  @type mapping_error :: :unmapped_method | :invalid_scope_mapping
  @type custom_mapper :: (request() -> required_scopes() | nil)
  @type optional_mapper :: custom_mapper() | nil

  @declared_wildcards %{
    "mcp:tools:execute" => "mcp:tools:execute:"
  }

  @static_scopes [
    "mcp:server:discover",
    "mcp:tools:list",
    "mcp:tools:get",
    "mcp:tools:execute",
    "mcp:resources:list",
    "mcp:resources:get",
    "mcp:resources:create",
    "mcp:resources:update",
    "mcp:resources:delete",
    "mcp:resources:subscribe",
    "mcp:prompts:list",
    "mcp:prompts:get",
    "mcp:prompts:execute",
    "mcp:completion:complete",
    "mcp:logging:set",
    "mcp:roots:list",
    "mcp:sampling:create",
    "mcp:elicitation:create",
    "mcp:tasks:get",
    "mcp:tasks:list",
    "mcp:tasks:result",
    "mcp:tasks:cancel",
    "mcp:tasks:update",
    "mcp:subscriptions:listen",
    "mcp:requests:cancel",
    "mcp:sessions:listen",
    "mcp:sessions:delete"
  ]

  @doc """
  Retrieves the list of required OAuth scopes for a given MCP request.

  This function inspects the `method` and `params` of the request to determine
  the necessary scopes. It can be extended with a custom mapping function.
  """
  @spec get_required_scopes(request(), optional_mapper()) ::
          required_scopes() | {:error, mapping_error()}
  def get_required_scopes(request, custom_mapper \\ nil)

  def get_required_scopes(request, nil), do: default_scope_mapping(request)

  def get_required_scopes(request, custom_mapper) when is_function(custom_mapper, 1) do
    case custom_mapper.(request) do
      nil -> default_scope_mapping(request)
      scopes when is_list(scopes) -> validate_scope_mapping(scopes)
      _invalid -> {:error, :invalid_scope_mapping}
    end
  rescue
    _error -> {:error, :invalid_scope_mapping}
  catch
    _kind, _reason -> {:error, :invalid_scope_mapping}
  end

  def get_required_scopes(_request, _invalid_mapper), do: {:error, :invalid_scope_mapping}

  @doc """
  Validates that a set of token scopes satisfies a set of required scopes.

  This function checks if for every required scope, either the scope itself or a
  more general "wildcard" scope exists in the token scopes.

  For example, if `required_scopes` is `["mcp:tools:execute:calculator"]`, this
  function will return `:ok` if `token_scopes` contains either
  `"mcp:tools:execute:calculator"` or `"mcp:tools:execute"`.
  """
  @spec validate(token_scopes(), required_scopes()) :: :ok | {:error, :insufficient_scope}
  def validate(token_scopes, required_scopes) do
    token_scope_set = MapSet.new(token_scopes)

    all_required_present? =
      Enum.all?(required_scopes, &scope_satisfied?(&1, token_scope_set))

    if all_required_present? do
      :ok
    else
      {:error, :insufficient_scope}
    end
  end

  @doc """
  Returns a list of all standard, statically-defined MCP scopes.

  This is useful for advertising supported scopes, for example in a
  `.well-known/oauth-protected-resource` endpoint. Note that this list does not
  include dynamically generated scopes like `mcp:tools:execute:<tool_name>`.
  """
  @spec get_all_static_scopes() :: [String.t()]
  def get_all_static_scopes, do: @static_scopes

  #
  # Private Functions
  #

  defp default_scope_mapping(%{"method" => "tools/list"}), do: ["mcp:tools:list"]
  defp default_scope_mapping(%{"method" => "tools/get"}), do: ["mcp:tools:get"]

  defp default_scope_mapping(%{
         "method" => "tools/call",
         "params" => %{"name" => tool_name}
       })
       when is_binary(tool_name) and tool_name != "" do
    ["mcp:tools:execute:#{tool_name}"]
  end

  defp default_scope_mapping(%{"method" => "tools/call"}), do: ["mcp:tools:execute"]

  defp default_scope_mapping(%{
         "method" => "tools/execute",
         "params" => %{"tool_name" => tool_name}
       })
       when is_binary(tool_name) and tool_name != "" do
    ["mcp:tools:execute:#{tool_name}"]
  end

  defp default_scope_mapping(%{"method" => "tools/execute"}), do: ["mcp:tools:execute"]

  defp default_scope_mapping(%{"method" => "resources/list"}), do: ["mcp:resources:list"]

  defp default_scope_mapping(%{"method" => "resources/templates/list"}),
    do: ["mcp:resources:list"]

  defp default_scope_mapping(%{"method" => "resources/read"}), do: ["mcp:resources:get"]
  defp default_scope_mapping(%{"method" => "resources/get"}), do: ["mcp:resources:get"]
  defp default_scope_mapping(%{"method" => "resources/create"}), do: ["mcp:resources:create"]
  defp default_scope_mapping(%{"method" => "resources/update"}), do: ["mcp:resources:update"]
  defp default_scope_mapping(%{"method" => "resources/delete"}), do: ["mcp:resources:delete"]

  defp default_scope_mapping(%{"method" => method})
       when method in ["resources/subscribe", "resources/unsubscribe"],
       do: ["mcp:resources:subscribe"]

  defp default_scope_mapping(%{"method" => "prompts/list"}), do: ["mcp:prompts:list"]
  defp default_scope_mapping(%{"method" => "prompts/get"}), do: ["mcp:prompts:get"]
  defp default_scope_mapping(%{"method" => "prompts/execute"}), do: ["mcp:prompts:execute"]

  defp default_scope_mapping(%{"method" => "completion/complete"}),
    do: ["mcp:completion:complete"]

  defp default_scope_mapping(%{"method" => "session/delete"}), do: ["mcp:sessions:delete"]

  defp default_scope_mapping(%{"method" => "session/listen"}),
    do: ["mcp:sessions:listen"]

  defp default_scope_mapping(%{"method" => "server/discover"}),
    do: ["mcp:server:discover"]

  defp default_scope_mapping(%{"method" => "subscriptions/listen"}),
    do: ["mcp:subscriptions:listen"]

  defp default_scope_mapping(%{"method" => "logging/setLevel"}), do: ["mcp:logging:set"]
  defp default_scope_mapping(%{"method" => "roots/list"}), do: ["mcp:roots:list"]

  defp default_scope_mapping(%{"method" => "sampling/createMessage"}),
    do: ["mcp:sampling:create"]

  defp default_scope_mapping(%{"method" => "elicitation/create"}),
    do: ["mcp:elicitation:create"]

  defp default_scope_mapping(%{"method" => "tasks/get"}), do: ["mcp:tasks:get"]
  defp default_scope_mapping(%{"method" => "tasks/list"}), do: ["mcp:tasks:list"]
  defp default_scope_mapping(%{"method" => "tasks/result"}), do: ["mcp:tasks:result"]
  defp default_scope_mapping(%{"method" => "tasks/cancel"}), do: ["mcp:tasks:cancel"]
  defp default_scope_mapping(%{"method" => "tasks/update"}), do: ["mcp:tasks:update"]

  defp default_scope_mapping(%{"method" => "notifications/cancelled"}),
    do: ["mcp:requests:cancel"]

  defp default_scope_mapping(%{"method" => method})
       when method in ["initialize", "initialized", "ping", "notifications/initialized"],
       do: []

  # The remaining notification methods are emitted by servers or clients as
  # protocol bookkeeping. They do not grant access to application resources.
  defp default_scope_mapping(%{"method" => method})
       when method in [
              "notifications/tools/list_changed",
              "notifications/resources/list_changed",
              "notifications/prompts/list_changed",
              "notifications/progress",
              "notifications/message",
              "notifications/resources/updated",
              "notifications/roots/list_changed",
              "notifications/tasks/status",
              "notifications/tasks",
              "notifications/elicitation/complete"
            ],
       do: []

  # A validated response settles protocol work already addressed to its session.
  # Empty application scopes still require ServerGuard's bearer/claim checks;
  # the HTTP session lease and reverse producer proof authorize its destination.
  defp default_scope_mapping(%{"jsonrpc" => "2.0", "id" => id} = response)
       when (is_binary(id) or is_integer(id) or is_nil(id)) and
              not is_map_key(response, "method") do
    case MessageValidator.validate_response(response) do
      {:ok, _response} -> []
      {:error, _invalid} -> {:error, :unmapped_method}
    end
  end

  # There is deliberately no universal catch-all scope. Extensions must supply
  # an explicit mapper, otherwise OAuth authorization fails closed.
  defp default_scope_mapping(_request), do: {:error, :unmapped_method}

  defp scope_satisfied?(required_scope, token_scope_set) do
    if MapSet.member?(token_scope_set, required_scope) do
      true
    else
      Enum.any?(@declared_wildcards, fn {wildcard, required_prefix} ->
        MapSet.member?(token_scope_set, wildcard) and
          String.starts_with?(required_scope, required_prefix)
      end)
    end
  end

  defp validate_scope_mapping(scopes) do
    if scopes != [] and Enum.all?(scopes, &(is_binary(&1) and &1 != "")),
      do: scopes,
      else: {:error, :invalid_scope_mapping}
  end
end
