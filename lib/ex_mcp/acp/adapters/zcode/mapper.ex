defmodule ExMCP.ACP.Adapters.ZCode.Mapper do
  @moduledoc false

  # Pure ZCode event to ACP message mapping.
  #
  # Translates ZCode `session/event` typed notifications, server-initiated
  # requests, and response messages into ACP `session/update` notifications
  # and JSON-RPC responses.

  require Logger

  alias ExMCP.ACP.Adapters.ZCode.{Config, Protocol, Sessions}
  alias ExMCP.ACP.{AdapterEvents, Envelope, PendingRequests, PromptQueue}

  @doc """
  Reduces a decoded ZCode message (response, server request, or notification)
  into ACP messages, port writes, and new adapter state.
  """
  @spec reduce_message(map(), map()) :: {[map()], [iodata()], map()}
  def reduce_message(msg, state)

  # Response to a client→server request
  def reduce_message(%{"id" => id, "result" => result}, state) when not is_nil(result) do
    handle_response(state, id, {:ok, result})
  end

  def reduce_message(%{"id" => id, "error" => error}, state) do
    handle_response(state, id, {:error, error})
  end

  # Server→client request
  def reduce_message(%{"id" => id, "method" => method, "params" => params}, state)
      when is_binary(method) do
    handle_server_request(id, method, params || %{}, state)
  end

  # Notification
  def reduce_message(
        %{
          "method" => "state.updated",
          "params" => %{"scope" => "session", "sessionId" => id, "patch" => patch}
        },
        state
      )
      when is_map(patch) do
    update_session_settings(state, id, patch)
  end

  def reduce_message(%{"method" => "session/event", "params" => params}, state) do
    handle_session_event(params || %{}, state)
  end

  def reduce_message(%{"method" => "process/resourceSample"}, state),
    do: {[], [], state}

  def reduce_message(%{"method" => method}, state) do
    Logger.debug("[ZCode Adapter] Unhandled notification: #{method}")
    {[], [], state}
  end

  def reduce_message(_msg, state), do: {[], [], state}

  # ---------------------------------------------------------------------------
  # Response handling
  # ---------------------------------------------------------------------------

  defp handle_response(state, id, reply) do
    case PendingRequests.pop(state.pending_requests, id) do
      {nil, _pending} ->
        {[], [], state}

      {%{type: type} = entry, pending} ->
        state = %{state | pending_requests: pending}
        handle_typed_response(type, entry, reply, state)
    end
  end

  defp handle_typed_response(:workspace_read_state, _entry, {:ok, result}, state) do
    models = Config.normalize_model_catalog(result["modelCatalog"] || result["settings"] || %{})
    {[], [], %{state | models: models, phase: :ready}}
  end

  defp handle_typed_response(:workspace_read_state, _entry, {:error, _error}, state) do
    {[], [], %{state | phase: :ready}}
  end

  defp handle_typed_response(:session_create, %{acp_id: acp_id}, {:ok, result}, state) do
    session_id = Protocol.session_id(result) || "zcode_#{System.unique_integer([:positive])}"
    session = Sessions.from_snapshot(session_id, result, state)
    state = Sessions.put(state, session_id, session)

    # Subscribe to events for this session
    {sub_id, state} = next_request_id(state)

    subscribe_req =
      Protocol.encode_request(sub_id, "session/subscribe", %{
        "sessionId" => session_id,
        "deliveryKind" => "desktop-continuous"
      })

    state =
      state
      |> track_request(sub_id, :session_subscribe, nil, %{session_id: session_id})

    response = Envelope.response(acp_id, session_result(session_id, result, state))
    {[response], [Protocol.line(subscribe_req)], state}
  end

  defp handle_typed_response(:session_create, %{acp_id: acp_id}, {:error, error}, state) do
    {[error_response(acp_id, error)], [], state}
  end

  defp handle_typed_response(:session_resume, %{acp_id: acp_id, meta: meta}, {:ok, result}, state) do
    session_id = meta[:session_id] || Protocol.session_id(result)
    session = Sessions.from_snapshot(session_id, result, state)

    replay? = meta[:replay?] || false
    session = Map.put(session, :subscribed, true)

    state = Sessions.put(state, session_id, session)

    replay_messages =
      if replay? do
        replay_snapshot_history(session_id, result)
      else
        []
      end

    response = Envelope.response(acp_id, session_result(session_id, result, state))
    {replay_messages ++ [response], [], state}
  end

  defp handle_typed_response(:session_resume, %{acp_id: acp_id}, {:error, error}, state) do
    {[error_response(acp_id, error)], [], state}
  end

  defp handle_typed_response(:session_subscribe, _entry, {:ok, _result}, state) do
    {[], [], state}
  end

  defp handle_typed_response(:session_subscribe, _entry, _reply, state),
    do: {[], [], state}

  defp handle_typed_response(:session_send, _entry, {:ok, _result}, state),
    do: {[], [], state}

  defp handle_typed_response(:session_send, %{acp_id: acp_id}, {:error, error}, state) do
    {[error_response(acp_id, error)], [], state}
  end

  defp handle_typed_response(:session_stop, _entry, _reply, state),
    do: {[], [], state}

  defp handle_typed_response(:session_close, _entry, _reply, state),
    do: {[], [], state}

  defp handle_typed_response(:session_list, %{acp_id: acp_id}, {:ok, result}, state) do
    sessions =
      (result["sessions"] || [])
      |> Enum.map(&Sessions.to_acp_session_info/1)

    response =
      Envelope.response(acp_id, %{"sessions" => sessions})
      |> put_optional_result("nextCursor", result["nextCursor"])

    {[response], [], state}
  end

  defp handle_typed_response(:session_list, %{acp_id: acp_id}, {:error, error}, state) do
    {[error_response(acp_id, error)], [], state}
  end

  defp handle_typed_response(:session_fork, %{acp_id: acp_id}, {:ok, result}, state) do
    session_id = Protocol.session_id(result) || "zcode_#{System.unique_integer([:positive])}"
    session = Sessions.from_snapshot(session_id, result, state)
    state = Sessions.put(state, session_id, session)

    response = Envelope.response(acp_id, session_result(session_id, result, state))
    {[response], [], state}
  end

  defp handle_typed_response(:session_fork, %{acp_id: acp_id}, {:error, error}, state) do
    {[error_response(acp_id, error)], [], state}
  end

  defp handle_typed_response(type, %{acp_id: acp_id, meta: meta}, {:ok, result}, state)
       when type in [:session_set_mode, :session_set_model, :session_set_thought_level] do
    session_id = meta[:session_id] || Protocol.session_id(result)

    # Current ZCode returns only the selected model here; older versions may ACK
    # with an empty result. Never replace the full session catalog with this patch.
    {requested_updates, [], state} =
      update_session_settings(state, session_id, meta[:requested_settings] || %{})

    {native_updates, [], state} =
      update_session_settings(state, session_id, result["settings"] || %{})

    response =
      if meta[:reply_type] == :config do
        session = Map.get(state.sessions, session_id, %{})
        %{"configOptions" => Config.config_options(session)}
      else
        %{}
      end

    replies = if is_nil(acp_id), do: [], else: [Envelope.response(acp_id, response)]
    updates = if native_updates == [], do: requested_updates, else: native_updates
    {updates ++ replies, [], state}
  end

  defp handle_typed_response(type, %{acp_id: acp_id}, {:error, error}, state)
       when type in [:session_set_mode, :session_set_model, :session_set_thought_level] do
    replies = if is_nil(acp_id), do: [], else: [error_response(acp_id, error)]
    {replies, [], state}
  end

  defp handle_typed_response(_type, _entry, _reply, state),
    do: {[], [], state}

  # ---------------------------------------------------------------------------
  # Server→client requests
  # ---------------------------------------------------------------------------

  defp handle_server_request(zcode_id, "interaction/requestPermission", params, state) do
    session_id = Sessions.id_from_params(params, state)
    cwd = session_cwd(state, session_id)

    tool_call = Protocol.permission_tool_call(params, cwd)
    options = Protocol.permission_options(params["options"] || [])

    acp_id = "zcode-permission-#{System.unique_integer([:positive])}"

    message =
      Envelope.request(
        "session/request_permission",
        %{
          "sessionId" => session_id,
          "toolCall" => Map.put(tool_call, "status", "pending"),
          "options" => options,
          "_meta" => %{
            "ex_mcp" => %{"zcode" => %{"method" => "requestPermission", "params" => params}}
          }
        },
        acp_id
      )

    tool_message =
      AdapterEvents.tool_call(session_id, Map.put(tool_call, "status", "pending"))

    entry = %{
      zcode_id: zcode_id,
      kind: :permission,
      request: params,
      session_id: session_id
    }

    state = %{
      state
      | pending_client_requests: PendingRequests.put(state.pending_client_requests, acp_id, entry)
    }

    {[tool_message, message] |> Enum.reject(&is_nil/1), [], state}
  end

  defp handle_server_request(zcode_id, "session/requestRuntimePreferences", _params, state) do
    response = Protocol.encode_response(zcode_id, default_runtime_preferences())
    {[], [Protocol.line(response)], state}
  end

  defp handle_server_request(zcode_id, "interaction/requestUserInput", _params, state) do
    response = Protocol.encode_response(zcode_id, %{"cancelled" => true})
    {[], [Protocol.line(response)], state}
  end

  defp handle_server_request(
         zcode_id,
         "interaction/requestProviderRuntimeHeaders",
         _params,
         state
       ) do
    response = Protocol.encode_response(zcode_id, %{"headersApplied" => false})
    {[], [Protocol.line(response)], state}
  end

  defp handle_server_request(zcode_id, method, _params, state) do
    Logger.debug("[ZCode Adapter] Rejecting unsupported server request: #{method}")

    error =
      Protocol.encode_error(zcode_id, -32_601, "Unsupported ZCode server request: #{method}")

    {[], [Protocol.line(error)], state}
  end

  # ---------------------------------------------------------------------------
  # session/event notification handling
  # ---------------------------------------------------------------------------

  defp handle_session_event(%{"type" => type} = event, state) do
    session_id = Sessions.id_from_params(event, state)
    event_data = unwrap_event_payload(event)

    state =
      if session_id do
        Sessions.update(state, session_id, &Map.put(&1, :prompt_activity, true))
      else
        state
      end

    handle_event_type(type, event_data, session_id, state)
  end

  defp handle_session_event(_event, state), do: {[], [], state}

  # turn lifecycle

  defp handle_event_type("turn.started", event, session_id, state) do
    turn_id = event["turnId"] || get_in(event, ["turn", "id"])

    state =
      Sessions.update(state, session_id, fn session ->
        session
        |> Map.put(:turn_id, turn_id)
        |> Map.put(:prompt_activity, true)
      end)

    {[], [], state}
  end

  defp handle_event_type("turn.completed", event, session_id, state) do
    handle_turn_completed(session_id, event, state)
  end

  defp handle_event_type("turn.failed", event, session_id, state) do
    handle_turn_failed(session_id, event, state)
  end

  # part deltas — streaming text and reasoning

  defp handle_event_type("part.delta", event, session_id, state) do
    delta = event["delta"] || ""
    field = event["field"] || "text"

    state =
      if field == "text" do
        Sessions.update(state, session_id, fn session ->
          %{session | accumulated_text: [delta | session.accumulated_text]}
        end)
      else
        state
      end

    message =
      case field do
        "text" ->
          AdapterEvents.agent_message_chunk(session_id, delta)

        "reasoning" ->
          AdapterEvents.agent_thought_chunk(session_id, delta)

        _ ->
          nil
      end

    if message, do: {[message], [], state}, else: {[], [], state}
  end

  defp handle_event_type("part.started", _event, _session_id, state),
    do: {[], [], state}

  defp handle_event_type("part.upserted", _event, _session_id, state),
    do: {[], [], state}

  defp handle_event_type("part.removed", _event, _session_id, state),
    do: {[], [], state}

  # tool lifecycle

  defp handle_event_type("tool.updated", event, session_id, state) do
    handle_tool_updated(session_id, event, state)
  end

  # session lifecycle events

  defp handle_event_type("session.created", _event, session_id, state) do
    state =
      Sessions.update(state, session_id, fn session ->
        Map.put(session, :id, session_id)
      end)

    {[], [], state}
  end

  defp handle_event_type("session.resumed", _event, _session_id, state),
    do: {[], [], state}

  defp handle_event_type("session.updated", event, session_id, state) do
    case event["mode"] || get_in(event, ["session", "mode"]) do
      nil ->
        {[], [], state}

      mode ->
        state =
          Sessions.update(state, session_id, &Map.put(&1, :mode_id, mode))

        {[AdapterEvents.current_mode_update(session_id, mode)], [], state}
    end
  end

  defp handle_event_type("session.titleUpdated", event, session_id, state) do
    title = event["title"]
    {[AdapterEvents.session_info_update(session_id, %{"title" => title})], [], state}
  end

  defp handle_event_type("session.closed", _event, _session_id, state),
    do: {[], [], state}

  # permission events (also arrive as server requests, but track status)

  defp handle_event_type("permission.requested", _event, _session_id, state),
    do: {[], [], state}

  defp handle_event_type("permission.resolved", event, session_id, state) do
    tool_call_id = event["toolCallId"]
    status = permission_status(event)

    update = %{"toolCallId" => tool_call_id, "status" => status}

    {[AdapterEvents.tool_call_update(session_id, update)], [], state}
  end

  # checkpoint / rewind

  defp handle_event_type("checkpoint.created", event, session_id, state) do
    update =
      AdapterEvents.session_info_update(session_id, %{
        "_meta" => %{"ex_mcp" => %{"zcode" => %{"checkpoint" => event["checkpointId"]}}}
      })

    {[update], [], state}
  end

  defp handle_event_type("rewind.triggered", _event, _session_id, state),
    do: {[], [], state}

  # model streaming (token-level)

  defp handle_event_type("model.streaming", event, session_id, state) do
    handle_model_streaming(event, session_id, state)
  end

  # catch-all

  defp handle_event_type(type, event, session_id, state) do
    Logger.debug("[ZCode Adapter] Unhandled event type: #{type}")

    # Still pass through as session_info_update _meta so clients don't lose data
    update =
      AdapterEvents.session_info_update(session_id, %{
        "_meta" => %{"ex_mcp" => %{"zcode" => %{"event" => type, "data" => event}}}
      })

    {[update], [], state}
  end

  # ---------------------------------------------------------------------------
  # turn.completed → synthesize ACP session/prompt response
  # ---------------------------------------------------------------------------

  defp handle_turn_completed(session_id, event, state) do
    session = Map.get(state.sessions, session_id, Sessions.empty(session_id, state))

    result_type = event["resultType"] || "success"
    stop_reason = Protocol.stop_reason(result_type)
    usage = format_usage(event["usage"])

    text =
      session.accumulated_text
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    info_messages = [
      AdapterEvents.session_info_update(session_id, %{
        "_meta" => %{"ex_mcp" => %{"zcode" => %{"status" => "completed"}}}
      })
    ]

    usage_messages =
      if usage do
        size = get_in(event, ["usage", "contextWindow"]) || nil

        used =
          usage
          |> Map.values()
          |> Enum.filter(&is_integer/1)
          |> Enum.sum()

        if is_integer(used) and used > 0 do
          [
            AdapterEvents.session_update_type(session_id, "usage_update", %{
              "used" => used,
              "size" => size || 0
            })
          ]
        else
          []
        end
      else
        []
      end

    prompt_response =
      if session.active_prompt_acp_id do
        result =
          %{
            "stopReason" => stop_reason,
            "_meta" => %{
              "ex_mcp" =>
                %{
                  "text" => text,
                  "sessionId" => session_id,
                  "turnId" => session.turn_id,
                  "resultType" => result_type
                }
                |> compact()
            }
          }
          |> maybe_put_usage(usage)

        Envelope.response(session.active_prompt_acp_id, result)
      else
        nil
      end

    state =
      Sessions.update(state, session_id, fn session ->
        session
        |> Map.put(:accumulated_text, [])
        |> Map.put(:accumulated_usage, nil)
        |> Map.put(:turn_id, nil)
        |> Map.put(:active_prompt_acp_id, nil)
        |> Map.put(:prompt_activity, false)
      end)

    messages =
      [prompt_response | info_messages ++ usage_messages]
      |> Enum.reject(&is_nil/1)

    {queued_messages, writes, state} = start_next_queued_prompt(session_id, state)

    {Enum.reverse(messages) ++ queued_messages, writes, state}
  end

  defp handle_turn_failed(session_id, event, state) do
    session = Map.get(state.sessions, session_id, Sessions.empty(session_id, state))
    error = event["error"] || %{}
    error_message = error["message"] || "Turn failed"

    response =
      if session.active_prompt_acp_id do
        Envelope.error(
          session.active_prompt_acp_id,
          -32_603,
          error_message,
          %{"ex_mcp" => %{"zcode" => %{"error" => error, "turnPhase" => event["turnPhase"]}}}
        )
      else
        nil
      end

    state =
      Sessions.update(state, session_id, fn session ->
        session
        |> Map.put(:accumulated_text, [])
        |> Map.put(:turn_id, nil)
        |> Map.put(:active_prompt_acp_id, nil)
        |> Map.put(:prompt_activity, false)
      end)

    messages = [response] |> Enum.reject(&is_nil/1)
    {queued_messages, writes, state} = start_next_queued_prompt(session_id, state)

    {messages ++ queued_messages, writes, state}
  end

  # ---------------------------------------------------------------------------
  # tool.updated handling
  # ---------------------------------------------------------------------------

  defp handle_tool_updated(session_id, event, state) do
    kind = event["kind"]
    tool_call_id = event["toolCallId"]

    case kind do
      "scheduled" ->
        {[tool_scheduled_update(session_id, event, state)], [], state}

      "started" ->
        update = %{"toolCallId" => tool_call_id, "status" => "in_progress"}
        {[AdapterEvents.tool_call_update(session_id, update)], [], state}

      "progress" ->
        {[tool_progress_update(session_id, event, tool_call_id)], [], state}

      "result" ->
        {[tool_result_update(session_id, event, tool_call_id)], [], state}

      "error" ->
        {[tool_error_update(session_id, event, tool_call_id)], [], state}

      "batch" ->
        {[], [], state}

      "raw" ->
        {[], [], state}

      _ ->
        Logger.debug("[ZCode Adapter] Unhandled tool.updated kind: #{kind}")
        {[], [], state}
    end
  end

  defp tool_scheduled_update(session_id, event, state) do
    tool_name = event["toolName"] || "tool"
    tool_call_id = event["toolCallId"]
    input = event["input"] || %{}
    cwd = session_cwd(state, session_id)

    tool_info =
      Protocol.permission_tool_call(
        %{"toolName" => tool_name, "input" => input, "toolCallId" => tool_call_id},
        cwd
      )

    update =
      tool_info
      |> Map.take(["title", "kind", "content", "locations", "rawInput"])
      |> Map.put("toolCallId", tool_call_id)
      |> Map.put("status", "pending")

    AdapterEvents.tool_call(session_id, update)
  end

  defp tool_progress_update(session_id, event, tool_call_id) do
    progress = %{
      "elapsedMs" => event["elapsedMs"],
      "stdoutTail" => event["stdoutTail"],
      "stderrTail" => event["stderrTail"]
    }

    update = %{
      "toolCallId" => tool_call_id,
      "status" => "in_progress",
      "_meta" => %{"zcode" => compact(progress)}
    }

    AdapterEvents.tool_call_update(session_id, compact(update))
  end

  defp tool_result_update(session_id, event, tool_call_id) do
    result = event["result"] || %{}

    update =
      %{
        "toolCallId" => tool_call_id,
        "status" => "completed",
        "content" => tool_result_content(result),
        "rawOutput" => tool_result_raw(result)
      }
      |> compact()

    AdapterEvents.tool_call_update(session_id, update)
  end

  defp tool_error_update(session_id, event, tool_call_id) do
    error = event["error"] || %{}

    update =
      compact(%{
        "toolCallId" => tool_call_id,
        "status" => "failed",
        "rawOutput" => error["message"] || inspect(error)
      })

    AdapterEvents.tool_call_update(session_id, update)
  end

  # ---------------------------------------------------------------------------
  # model.streaming handling
  # ---------------------------------------------------------------------------

  defp handle_model_streaming(event, session_id, state) do
    case event["kind"] do
      "text_delta" ->
        delta = event["delta"] || ""

        state =
          Sessions.update(state, session_id, fn session ->
            %{session | accumulated_text: [delta | session.accumulated_text]}
          end)

        {[AdapterEvents.agent_message_chunk(session_id, delta)], [], state}

      "reasoning_delta" ->
        delta = event["delta"] || ""
        {[AdapterEvents.agent_thought_chunk(session_id, delta)], [], state}

      _ ->
        {[], [], state}
    end
  end

  # ---------------------------------------------------------------------------
  # Replay
  # ---------------------------------------------------------------------------

  @doc "Replays snapshot messages as ACP session/update chunks."
  @spec replay_snapshot_history(String.t(), map()) :: [map()]
  def replay_snapshot_history(session_id, snapshot) do
    messages = snapshot["messages"] || []

    Enum.flat_map(messages, fn message ->
      replay_message(session_id, message)
    end)
  end

  defp replay_message(session_id, %{"role" => "user", "content" => content}) do
    text = message_text(content)

    if text == "" do
      []
    else
      [
        AdapterEvents.content_chunk(
          session_id,
          "user_message_chunk",
          %{
            "type" => "text",
            "text" => text
          },
          meta: %{"ex_mcp" => %{"zcode" => %{"replay" => true}}}
        )
      ]
    end
  end

  defp replay_message(session_id, %{"role" => "assistant"} = message) do
    parts = message["parts"] || []

    Enum.flat_map(parts, fn part ->
      case part["type"] do
        "text" ->
          text = part["text"] || ""

          if text == "" do
            []
          else
            [
              AdapterEvents.agent_message_chunk(session_id, text,
                meta: %{"ex_mcp" => %{"zcode" => %{"replay" => true}}}
              )
            ]
          end

        "reasoning" ->
          text = part["text"] || ""

          if text == "" do
            []
          else
            [
              AdapterEvents.agent_thought_chunk(session_id, text,
                meta: %{"ex_mcp" => %{"zcode" => %{"replay" => true}}}
              )
            ]
          end

        "tool" ->
          replay_tool_part(session_id, part)

        _ ->
          []
      end
    end)
  end

  defp replay_message(_session_id, _message), do: []

  defp replay_tool_part(session_id, %{"callId" => call_id} = part) do
    tool_name = part["toolName"] || part["name"] || "tool"

    case part["state"] do
      %{"output" => _output} ->
        [
          AdapterEvents.tool_call(session_id, %{
            "toolCallId" => call_id,
            "title" => tool_name,
            "status" => "completed",
            "_meta" => %{"ex_mcp" => %{"zcode" => %{"replay" => true}}}
          })
        ]

      %{"error" => _error} ->
        [
          AdapterEvents.tool_call(session_id, %{
            "toolCallId" => call_id,
            "title" => tool_name,
            "status" => "failed",
            "_meta" => %{"ex_mcp" => %{"zcode" => %{"replay" => true}}}
          })
        ]

      _ ->
        []
    end
  end

  defp replay_tool_part(_session_id, _part), do: []

  defp message_text(content) when is_binary(content), do: content

  defp message_text(content) when is_list(content) do
    content
    |> Enum.map_join("", fn
      %{"type" => "text", "text" => text} -> text || ""
      %{"text" => text} -> text || ""
      _ -> ""
    end)
  end

  defp message_text(_), do: ""

  # ---------------------------------------------------------------------------
  # Session result builder
  # ---------------------------------------------------------------------------

  @doc "Builds the ACP session setup result from a ZCode snapshot."
  @spec session_result(String.t(), map(), map()) :: map()
  def session_result(session_id, snapshot, state) do
    session =
      Map.get(state.sessions, session_id) || Sessions.from_snapshot(session_id, snapshot, state)

    %{
      "sessionId" => session_id,
      "modes" => %{
        "availableModes" => Config.modes(),
        "currentModeId" => session.mode_id
      },
      "configOptions" => Config.config_options(session),
      "_meta" => %{
        "ex_mcp" => %{
          "zcode" => %{
            "workspace" => session[:workspace],
            "protocol" => get_in(snapshot, ["protocol", "name"]),
            "protocolVersion" => get_in(snapshot, ["protocol", "version"])
          }
        }
      }
    }
    |> compact()
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp error_response(acp_id, error) when is_map(error) do
    Envelope.error(acp_id, error["code"] || -32_603, error["message"] || "ZCode error")
  end

  defp error_response(acp_id, reason) do
    Envelope.error(acp_id, -32_603, to_string(reason))
  end

  defp format_usage(nil), do: nil

  defp format_usage(usage) when is_map(usage) do
    %{
      "inputTokens" => usage["inputTokens"] || usage["input_tokens"] || 0,
      "outputTokens" => usage["outputTokens"] || usage["output_tokens"] || 0,
      "cacheReadTokens" => usage["cacheReadTokens"] || usage["cache_read_tokens"] || 0,
      "cacheCreationTokens" => usage["cacheCreationTokens"] || usage["cache_creation_tokens"] || 0
    }
  end

  defp format_usage(_), do: nil

  defp update_session_settings(state, session_id, settings) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, session} ->
        updated = Config.apply_settings(session, settings, :partial)

        if updated == session do
          {[], [], state}
        else
          options = AdapterEvents.config_option_update(session_id, Config.config_options(updated))

          modes =
            if updated.mode_id != session.mode_id,
              do: [AdapterEvents.current_mode_update(session_id, updated.mode_id)],
              else: []

          {[options | modes], [], Sessions.put(state, session_id, updated)}
        end

      :error ->
        {[], [], state}
    end
  end

  defp default_runtime_preferences do
    %{
      "nativeSearchEnhancementsEnabled" => false,
      "memoryEnabled" => false,
      "askUserQuestionAutoResolutionEnabled" => false,
      "modelContextBudgetStrategy" => "preflight-v1"
    }
  end

  defp tool_result_content(%{"display" => display}) when is_map(display) do
    case display do
      %{"text" => text} when is_binary(text) ->
        [%{"type" => "content", "content" => %{"type" => "text", "text" => text}}]

      _ ->
        []
    end
  end

  defp tool_result_content(result) when is_binary(result) do
    [%{"type" => "content", "content" => %{"type" => "text", "text" => result}}]
  end

  defp tool_result_content(result) when is_map(result) do
    text = result["text"] || result["output"] || result["summary"] || ""

    if text == "" do
      []
    else
      [%{"type" => "content", "content" => %{"type" => "text", "text" => text}}]
    end
  end

  defp tool_result_content(result) when is_list(result) do
    Enum.map(result, fn
      %{"type" => "text", "text" => text} ->
        %{"type" => "content", "content" => %{"type" => "text", "text" => text}}

      %{"text" => text} ->
        %{"type" => "content", "content" => %{"type" => "text", "text" => text}}

      other ->
        %{"type" => "content", "content" => %{"type" => "text", "text" => inspect(other)}}
    end)
  end

  defp tool_result_content(_), do: []

  defp tool_result_raw(%{"display" => display}) when is_map(display), do: display
  defp tool_result_raw(result) when is_binary(result), do: result
  defp tool_result_raw(result), do: result

  defp permission_status(%{"decision" => "allow"}), do: "completed"
  defp permission_status(%{"decision" => "deny"}), do: "failed"
  defp permission_status(_), do: "in_progress"

  defp session_cwd(state, session_id) do
    case Map.get(state.sessions, session_id) do
      %{workspace: cwd} when is_binary(cwd) -> cwd
      _ -> Map.get(state, :cwd) || Keyword.get(state.opts, :cwd)
    end
  end

  defp put_optional_result(%{"result" => _result} = response, _key, nil), do: response

  defp put_optional_result(%{"result" => result} = response, key, value),
    do: %{response | "result" => Map.put(result, key, value)}

  defp maybe_put_usage(response, nil), do: response
  defp maybe_put_usage(response, usage), do: Map.put(response, "usage", usage)

  defp next_request_id(%{next_id: id} = state),
    do: {id, %{state | next_id: id + 1}}

  defp track_request(state, id, type, acp_id, meta) do
    entry = %{type: type, acp_id: acp_id, meta: meta}
    %{state | pending_requests: PendingRequests.put(state.pending_requests, id, entry)}
  end

  defp compact(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, [], %{}] end)
    |> Map.new()
  end

  defp unwrap_event_payload(%{"payload" => payload} = event) when is_map(payload) do
    Map.merge(event, payload)
  end

  defp unwrap_event_payload(event), do: event

  defp start_next_queued_prompt(session_id, state) do
    case pop_queued_prompt(state.prompt_queue, session_id) do
      {:value, queued, queue} ->
        {id, state} = next_request_id(state)
        request = Protocol.encode_request(id, "session/send", queued.wire_params)

        state =
          %{state | prompt_queue: queue}
          |> track_request(id, :session_send, queued.acp_id, %{session_id: queued.session_id})
          |> Sessions.update(
            queued.session_id,
            &Sessions.reset_prompt_accumulators(&1, queued.acp_id)
          )

        queue_depth = PromptQueue.len(queue)

        messages = [
          AdapterEvents.agent_message_chunk(
            queued.session_id,
            "Starting queued message. (#{queue_depth} remaining)"
          ),
          AdapterEvents.session_info_update(queued.session_id, %{
            "_meta" => %{
              "ex_mcp" => %{"zcode" => %{"queueDepth" => queue_depth, "running" => true}}
            }
          })
        ]

        {messages, [Protocol.line(request)], state}

      :empty ->
        {[], [], state}
    end
  end

  defp pop_queued_prompt(queue, session_id) do
    {before, matching_and_after} =
      queue
      |> PromptQueue.to_list()
      |> Enum.split_while(&(&1.session_id != session_id))

    case matching_and_after do
      [queued | after_queued] ->
        {:value, queued, PromptQueue.from_list(before ++ after_queued)}

      [] ->
        :empty
    end
  end
end
