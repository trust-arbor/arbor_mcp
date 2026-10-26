defmodule ExMCP.Server do
  @moduledoc """
  Public server-side helpers for running MCP servers.

  Server implementations should use `ExMCP.Server.Handler` directly. For a
  declarative handler DSL, combine it with `ExMCP.Server.DSL`:

      defmodule MyServer do
        use ExMCP.Server.Handler
        use ExMCP.Server.DSL

        tool "echo", "Echo input" do
          param :message, :string, required: true

          run fn %{message: message}, state ->
            {:ok, %{text: message}, state}
          end
        end
      end

  Use `ExMCP.Server.HandlerServer.start_link/1` when you need a transport-aware
  process for a handler module.

  > #### Deprecated API {: .warning}
  >
  > `ExMCP.Server.Tools` (and `Tools.Simplified`) are deprecated, retained
  > throughout 1.x, and planned for removal in **2.0.0**. Prefer
  > `ExMCP.Server.DSL` for new code.

  > #### Protocol-deprecated features {: .warning}
  >
  > MCP 2026-07-28 deprecated Roots, Sampling, and protocol Logging. ExMCP
  > retains their public APIs throughout 1.x for legacy and 2026-07-28
  > compatibility. New implementations should pass directories through tool
  > parameters, resource URIs, or server configuration; call LLM provider APIs
  > directly; and use stderr or OpenTelemetry for operational logs.
  """

  @doc """
  Sends a log message through the server.

  MCP protocol Logging is deprecated as of 2026-07-28. This API remains
  available throughout ExMCP 1.x for compatibility. Prefer stderr on stdio or
  OpenTelemetry for new observability integrations.
  """
  @spec send_log_message(GenServer.server(), atom() | String.t(), String.t(), map()) :: :ok
  def send_log_message(server, level, message, data) do
    notify_client(server, {:send_log_message, level, message, data})
  end

  @doc """
  Sends a ping request to the connected client.
  """
  @spec ping(GenServer.server(), timeout()) :: {:ok, map()} | {:error, any()}
  def ping(server, timeout \\ 5000) do
    GenServer.call(server, :ping, timeout)
  end

  @doc """
  Lists roots available from the connected client.

  MCP Roots is deprecated as of 2026-07-28. This API remains available
  throughout ExMCP 1.x for compatibility. New implementations should pass
  directories or files via tool parameters, resource URIs, or server
  configuration.
  """
  @spec list_roots(GenServer.server(), timeout()) :: {:ok, %{roots: [map()]}} | {:error, any()}
  def list_roots(server, timeout \\ 5000) do
    GenServer.call(server, {:list_roots, timeout}, timeout)
  end

  @doc """
  Notifies the client that the server's roots have changed.

  MCP Roots is deprecated as of 2026-07-28 and retained throughout ExMCP 1.x.
  Prefer explicit tool parameters, resource URIs, or server configuration for
  new implementations.
  """
  @spec notify_roots_changed(GenServer.server()) :: :ok
  def notify_roots_changed(server) do
    GenServer.cast(server, :notify_roots_changed)
  end

  @doc """
  Sends a progress notification to the client.
  """
  @spec notify_progress(GenServer.server(), any(), number()) :: :ok
  def notify_progress(server, progress_token, progress) do
    notify_client(server, {:notify_progress, progress_token, progress, nil})
  end

  @doc """
  Sends a progress notification with a total to the client.
  """
  @spec notify_progress(GenServer.server(), any(), number(), number()) :: :ok
  def notify_progress(server, progress_token, progress, total) do
    notify_client(server, {:notify_progress, progress_token, progress, total})
  end

  @doc """
  Sends a resource update notification for subscribed clients.
  """
  @spec notify_resource_update(GenServer.server(), String.t()) :: :ok
  def notify_resource_update(server, uri) do
    notify_client(server, {:notify_resource_update, uri})
  end

  @doc """
  Sends a resource update to streamable-HTTP clients subscribed to `uri`.
  """
  @spec notify_resource_update(String.t()) :: %{
          subscribers: non_neg_integer(),
          delivered: non_neg_integer()
        }
  def notify_resource_update(uri) when is_binary(uri) do
    ExMCP.HttpPlug.broadcast_resource_update(uri)
  end

  @doc """
  Notifies subscribed clients that the resource list has changed.
  """
  @spec notify_resources_changed(GenServer.server()) :: :ok
  def notify_resources_changed(server) do
    notify_client(server, {:notify_resources_changed})
  end

  @doc """
  Notifies subscribed clients that the tools list has changed.
  """
  @spec notify_tools_changed(GenServer.server()) :: :ok
  def notify_tools_changed(server) do
    notify_client(server, {:notify_tools_changed})
  end

  @doc """
  Notifies subscribed clients that the prompts list has changed.
  """
  @spec notify_prompts_changed(GenServer.server()) :: :ok
  def notify_prompts_changed(server) do
    notify_client(server, {:notify_prompts_changed})
  end

  @doc """
  Gets the list of pending request IDs on the server.
  """
  @spec get_pending_requests(GenServer.server()) :: [ExMCP.Types.request_id()]
  def get_pending_requests(server) do
    GenServer.call(server, :get_pending_requests)
  end

  @doc """
  Sends a cancellation notification to the server.
  """
  @spec cancel_request(GenServer.server(), ExMCP.Types.request_id(), String.t() | nil) :: :ok
  def cancel_request(server, request_id, reason \\ nil) do
    params = %{"requestId" => request_id}
    params = if reason, do: Map.put(params, "reason", reason), else: params
    GenServer.cast(server, {:notification, "notifications/cancelled", params})
  end

  @doc """
  Sends a `sampling/createMessage` request to the connected client.

  MCP Sampling is deprecated as of 2026-07-28. This API remains available
  throughout ExMCP 1.x for compatibility. New implementations should integrate
  directly with an LLM provider API.
  """
  @spec create_message(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def create_message(server, params) do
    case GenServer.call(server, {:create_message, params}) do
      {:error, {:unknown_call, _request}} -> {:error, :not_implemented}
      result -> result
    end
  end

  @doc """
  Builds an `elicitation/create` entry for a modern MRTR `input_required` result.

  This is a builder, not a server-to-client POST. Return it from a tool,
  resource, or prompt handler inside `{:input_required, requests, state}`.
  On a modern connection the client satisfies the request through MRTR; you
  do not POST `elicitation/create` yourself.

  Form mode uses `message` plus `requested_schema` (or `requestedSchema`).
  URL mode uses `mode: "url"` and `url`. `elicitationId` is generated when
  omitted.

  Keys may be atoms or strings, in snake_case or camelCase.

  ## Examples

      requests = %{
        "profile" =>
          ExMCP.Server.elicit(%{
            message: "Choose a display name",
            requested_schema: %{
              "type" => "object",
              "properties" => %{"name" => %{"type" => "string"}}
            }
          })
      }

      {:input_required, requests, state}

      requests = %{
        "login" =>
          ExMCP.Server.elicit(%{
            message: "Sign in to continue",
            mode: "url",
            url: "https://auth.example.com/login"
          })
      }

  The raw `%{"method" => "elicitation/create", "params" => ...}` map is
  equivalent.
  """
  @spec elicit(map()) :: %{String.t() => term()}
  def elicit(params) when is_map(params) do
    %{
      "method" => "elicitation/create",
      "params" => elicit_params(params)
    }
  end

  defp elicit_params(params) do
    message = elicit_get(params, :message) || ""

    if elicit_url_mode?(params) do
      elicit_url_params(params, message)
    else
      schema = elicit_get(params, :requested_schema) || %{}
      %{"message" => message, "requestedSchema" => schema}
    end
  end

  defp elicit_url_mode?(params) do
    case elicit_get(params, :mode) do
      mode when mode in ["url", :url] -> true
      mode when mode in ["form", :form] -> false
      _other -> is_binary(elicit_get(params, :url))
    end
  end

  defp elicit_url_params(params, message) do
    url = elicit_get(params, :url) || ""
    id = elicit_get(params, :elicitation_id)

    %{
      "message" => message,
      "mode" => "url",
      "url" => url,
      "elicitationId" => elicit_id(id)
    }
  end

  defp elicit_id(id) when is_binary(id) and id != "", do: id

  defp elicit_id(_id) do
    "elicit-#{System.unique_integer([:positive, :monotonic])}"
  end

  @elicit_aliases %{
    message: ["message", :message],
    requested_schema: [
      "requestedSchema",
      :requestedSchema,
      "requested_schema",
      :requested_schema
    ],
    mode: ["mode", :mode],
    url: ["url", :url],
    elicitation_id: [
      "elicitationId",
      :elicitationId,
      "elicitation_id",
      :elicitation_id
    ]
  }

  defp elicit_get(map, key) do
    Enum.find_value(@elicit_aliases[key], fn alias_key ->
      if Map.has_key?(map, alias_key), do: Map.get(map, alias_key)
    end)
  end

  # A handler mounted through ExMCP.HttpPlug runs one temporary GenServer per
  # request with no transport of its own, so the notify casts above would
  # neither reach the client nor even be handled: a bare `use
  # ExMCP.Server.Handler` module has no handle_cast clauses of its own. When
  # such a handler notifies from inside a request callback, its current
  # context names the HTTP session the request belongs to, and the
  # notification is delivered to that session directly (see
  # ExMCP.HttpPlug.deliver_session_notification/3) — only that session, never
  # an earlier request's. A notify cast outside a request callback follows the
  # long-standing cast path to a transport-aware server; the per-request
  # handler of a mounted request is stopped once it has replied, so such a
  # cast finds no process and is dropped (a cast never fails, crashes or
  # hangs on a dead pid).

  defp notify_client(server, cast) do
    case mounted_session(server) do
      nil -> GenServer.cast(server, cast)
      {session_id, session_manager} -> deliver_mounted(cast, session_id, session_manager)
    end

    :ok
  end

  # Inside a request callback the handler process is its own server, and its
  # current context names the HTTP session the request belongs to, plus the
  # session manager its server was configured with. Nothing is remembered
  # beyond the callback: a later request (or none at all) must never fall
  # back to an earlier request's session.
  defp mounted_session(server) do
    if server == self() do
      case ExMCP.Server.Context.current() do
        %{session_id: session_id, session_manager: session_manager}
        when is_binary(session_id) ->
          {session_id, session_manager || ExMCP.SessionManager}

        _other ->
          nil
      end
    else
      nil
    end
  end

  defp deliver_mounted({:send_log_message, level, message, data}, session_id, session_manager) do
    notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/message",
      "params" => %{
        "level" => level,
        "logger" => "ExMCP.Server",
        "data" => data || %{},
        "message" => message
      }
    }

    ExMCP.HttpPlug.deliver_session_notification(session_id, notification, session_manager)
  end

  defp deliver_mounted(
         {:notify_progress, progress_token, progress, total},
         session_id,
         session_manager
       ) do
    notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/progress",
      "params" => %{"progressToken" => progress_token, "progress" => progress, "total" => total}
    }

    ExMCP.HttpPlug.deliver_session_notification(session_id, notification, session_manager)
  end

  defp deliver_mounted({:notify_resource_update, uri}, _session_id, _session_manager) do
    # Resource updates belong to subscribers of the URI across sessions, as
    # on a transport-aware server.
    ExMCP.HttpPlug.broadcast_resource_update(uri)
  end

  defp deliver_mounted(cast, session_id, session_manager) do
    {method, params} = mounted_notification(cast)

    ExMCP.HttpPlug.deliver_session_notification(
      session_id,
      %{"jsonrpc" => "2.0", "method" => method, "params" => params},
      session_manager
    )
  end

  defp mounted_notification({:notify_tools_changed}),
    do: {"notifications/tools/list_changed", %{}}

  defp mounted_notification({:notify_resources_changed}),
    do: {"notifications/resources/list_changed", %{}}

  defp mounted_notification({:notify_prompts_changed}),
    do: {"notifications/prompts/list_changed", %{}}
end
