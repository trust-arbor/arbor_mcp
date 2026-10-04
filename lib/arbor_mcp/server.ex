defmodule Arbor.MCP.Server do
  @moduledoc """
  Public server-side helpers for running MCP servers.

  Server implementations should use `Arbor.MCP.Server.Handler` directly. For a
  declarative handler DSL, combine it with `Arbor.MCP.Server.DSL`:

      defmodule MyServer do
        use Arbor.MCP.Server.Handler
        use Arbor.MCP.Server.DSL

        tool "echo", "Echo input" do
          param :message, :string, required: true

          run fn %{message: message}, state ->
            {:ok, %{text: message}, state}
          end
        end
      end

  Use `Arbor.MCP.Server.HandlerServer.start_link/1` when you need a transport-aware
  process for a handler module. It returns a runtime supervisor; these helpers
  accept that supervisor, its registered name or its opaque runtime reference.
  Runtime-backed helpers return `{:error, :server_busy}` when their admission
  lane is full. Controls issued inside a callback carry its invocation scope,
  so cancelled callbacks cannot send controls to a replacement peer.

  > #### Deprecated API {: .warning}
  >
  > `Arbor.MCP.Server.Tools` (and `Tools.Simplified`) are deprecated, retained
  > throughout 1.x, and planned for removal in **2.0.0**. Prefer
  > `Arbor.MCP.Server.DSL` for new code.

  > #### Protocol-deprecated features {: .warning}
  >
  > MCP 2026-07-28 deprecated Roots, Sampling, and protocol Logging. Arbor.MCP
  > retains their public APIs throughout 1.x for legacy and 2026-07-28
  > compatibility. New implementations should pass directories through tool
  > parameters, resource URIs, or server configuration; call LLM provider APIs
  > directly; and use stderr or OpenTelemetry for operational logs.
  """

  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{CallbackContext, Ref}

  @type server :: Runtime.server()

  @doc """
  Sends a log message through the server.

  MCP protocol Logging is deprecated as of 2026-07-28. This API remains
  available throughout Arbor.MCP 1.x for compatibility. Prefer stderr on stdio or
  OpenTelemetry for new observability integrations.
  """
  @spec send_log_message(server(), atom() | String.t(), String.t(), map()) ::
          :ok | {:error, atom()}
  def send_log_message(server, level, message, data) do
    cast_control(server, {:send_log_message, level, message, data})
  end

  @doc """
  Sends a ping request to the connected client.
  """
  @spec ping(server(), timeout()) :: {:ok, map()} | {:error, any()}
  def ping(server, timeout \\ 5000) do
    call_control(server, :ping, timeout)
  end

  @doc """
  Lists roots available from the connected client.

  MCP Roots is deprecated as of 2026-07-28. This API remains available
  throughout Arbor.MCP 1.x for compatibility. New implementations should pass
  directories or files via tool parameters, resource URIs, or server
  configuration.
  """
  @spec list_roots(server(), timeout()) :: {:ok, %{roots: [map()]}} | {:error, any()}
  def list_roots(server, timeout \\ 5000) do
    call_control(server, {:list_roots, timeout}, timeout)
  end

  @doc """
  Notifies the client that the server's roots have changed.

  MCP Roots is deprecated as of 2026-07-28 and retained throughout Arbor.MCP 1.x.
  Prefer explicit tool parameters, resource URIs, or server configuration for
  new implementations.
  """
  @spec notify_roots_changed(server()) :: :ok | {:error, atom()}
  def notify_roots_changed(server) do
    cast_control(server, :notify_roots_changed)
  end

  @doc """
  Sends a progress notification to the client.
  """
  @spec notify_progress(server(), any(), number()) :: :ok | {:error, atom()}
  def notify_progress(server, progress_token, progress) do
    cast_control(server, {:notify_progress, progress_token, progress, nil})
  end

  @doc """
  Sends a progress notification with a total to the client.
  """
  @spec notify_progress(server(), any(), number(), number()) :: :ok | {:error, atom()}
  def notify_progress(server, progress_token, progress, total) do
    cast_control(server, {:notify_progress, progress_token, progress, total})
  end

  @doc """
  Sends a resource update notification for subscribed clients.
  """
  @spec notify_resource_update(server(), String.t()) :: :ok | {:error, atom()}
  def notify_resource_update(server, uri) do
    cast_control(server, {:notify_resource_update, uri})
  end

  @doc """
  Sends a resource update to streamable-HTTP clients subscribed to `uri`.
  """
  @spec notify_resource_update(String.t()) :: %{
          subscribers: non_neg_integer(),
          delivered: non_neg_integer()
        }
  def notify_resource_update(uri) when is_binary(uri) do
    Arbor.MCP.HttpPlug.broadcast_resource_update(uri)
  end

  @doc """
  Notifies subscribed clients that the resource list has changed.
  """
  @spec notify_resources_changed(server()) :: :ok | {:error, atom()}
  def notify_resources_changed(server) do
    cast_control(server, {:notify_resources_changed})
  end

  @doc """
  Notifies subscribed clients that the tools list has changed.
  """
  @spec notify_tools_changed(server()) :: :ok | {:error, atom()}
  def notify_tools_changed(server) do
    cast_control(server, {:notify_tools_changed})
  end

  @doc """
  Notifies subscribed clients that the prompts list has changed.
  """
  @spec notify_prompts_changed(server()) :: :ok | {:error, atom()}
  def notify_prompts_changed(server) do
    cast_control(server, {:notify_prompts_changed})
  end

  @doc """
  Gets the list of pending request IDs on the server.
  """
  @spec get_pending_requests(server()) :: [Arbor.MCP.Types.request_id()]
  def get_pending_requests(server) do
    call_control(server, :get_pending_requests)
  end

  @doc """
  Sends a cancellation notification to the server.
  """
  @spec cancel_request(server(), Arbor.MCP.Types.request_id(), String.t() | nil) ::
          :ok | {:error, atom()}
  def cancel_request(server, request_id, reason \\ nil) do
    params = %{"requestId" => request_id}
    params = if reason, do: Map.put(params, "reason", reason), else: params
    cast_control(server, {:notification, "notifications/cancelled", params})
  end

  @doc """
  Sends a `sampling/createMessage` request to the connected client.

  MCP Sampling is deprecated as of 2026-07-28. This API remains available
  throughout Arbor.MCP 1.x for compatibility. New implementations should integrate
  directly with an LLM provider API.
  """
  @spec create_message(server(), map()) :: {:ok, map()} | {:error, term()}
  def create_message(server, params) do
    case call_control(server, {:create_message, params}) do
      {:error, {:unknown_call, _request}} -> {:error, :not_implemented}
      result -> result
    end
  end

  @doc """
  Calls a custom handler callback through the runtime's bounded scheduler.

  The callback returns `{:reply, reply, next_state}`. Deferred `GenServer.reply/2`,
  continuation and process-stop return forms are unsupported. A finite caller
  timeout ends the wait without cancelling accepted work or leaking late replies.
  Its `from` retains the original caller PID with a callback-owned proxy reply
  tag. Treat that tag as opaque; a direct reply to it cannot settle the caller's
  request or bypass the scheduler's state commit.
  """
  def call(server, request, timeout \\ 5_000) do
    case Runtime.ref(server) do
      {:ok, runtime} ->
        case Runtime.request(runtime, %{"payload" => request},
               kind: :call,
               via_edge: true,
               await_timeout: timeout
             ) do
          {:ok, reply} -> reply
          error -> error
        end

      {:error, _reason} ->
        case Ref.address(server) do
          {:ok, address} -> GenServer.call(address, request, timeout)
          {:error, _reason} -> {:error, :runtime_unavailable}
        end
    end
  end

  @doc """
  Queues a custom handler cast through the runtime's bounded scheduler.

  The callback returns `{:noreply, next_state}`; its state commits in the same
  order as accepted RPC and custom-call work.
  """
  def cast(server, request) do
    case Runtime.edge(server) do
      {:ok, edge} ->
        case Runtime.submit(server, %{"payload" => request},
               kind: :cast,
               via_edge: true,
               owner: edge,
               reply_to: edge
             ) do
          {:ok, _token} -> :ok
          error -> error
        end

      {:error, _reason} ->
        case Ref.address(server) do
          {:ok, address} -> GenServer.cast(address, request)
          {:error, _reason} -> {:error, :runtime_unavailable}
        end
    end
  end

  defp call_control(server, request, timeout \\ 5_000) do
    case Runtime.ref(server) do
      {:ok, runtime} ->
        payload = {:edge_call, request, control_origin()}

        case Runtime.request(runtime, %{"payload" => payload},
               kind: :edge_control,
               origin: control_origin(),
               via_edge: true,
               await_timeout: timeout
             ) do
          {:ok, reply} -> reply
          error -> error
        end

      {:error, _reason} ->
        case Ref.address(server) do
          {:ok, address} -> GenServer.call(address, request, timeout)
          {:error, _reason} -> {:error, :runtime_unavailable}
        end
    end
  end

  defp cast_control(server, request) do
    case Runtime.edge(server) do
      {:ok, edge} ->
        payload = {:edge_cast, request, control_origin()}

        case Runtime.submit(server, %{"payload" => payload},
               kind: :edge_control,
               origin: control_origin(),
               via_edge: true,
               reply_to: edge
             ) do
          {:ok, _token} -> :ok
          error -> error
        end

      {:error, _reason} ->
        case Ref.address(server) do
          {:ok, address} -> GenServer.cast(address, request)
          {:error, _reason} -> {:error, :runtime_unavailable}
        end
    end
  end

  defp control_origin do
    case CallbackContext.current() do
      nil -> nil
      invocation -> Map.take(invocation, [:scope, :token, :generation])
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
          Arbor.MCP.Server.elicit(%{
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
          Arbor.MCP.Server.elicit(%{
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
end
