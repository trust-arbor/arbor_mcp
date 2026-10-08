defmodule ExMCP.ACP.Adapters.ClaudeSDK.Mapper do
  @moduledoc false

  # Pure Claude SDK message to ACP message mapping.

  alias ExMCP.ACP.Adapters.ClaudeSDK.Protocol, as: ClaudeProtocol
  alias ExMCP.ACP.Adapters.ClaudeSDK.SessionStore
  alias ExMCP.ACP.Adapters.ClaudeSDK.ToolInfo
  alias ExMCP.ACP.Protocol, as: ACPProtocol
  alias ExMCP.ACP.{AdapterEvents, Capabilities, Envelope, PendingRequests, PromptQueue}

  @stop_reasons %{
    "end_turn" => "end_turn",
    "stop" => "end_turn",
    "tool_use" => "end_turn",
    "max_tokens" => "max_tokens",
    "refusal" => "refusal",
    "cancelled" => "cancelled"
  }

  @auth_errors ~w(authentication_failed oauth_org_not_allowed billing_error)

  # Mode the session falls back to when Auto is selected but the current model
  # does not support it, and the one-per-session notice that announces it.
  # Both match claude-agent-acp `src/session-mode.ts` (#1025).
  @auto_mode_fallback "acceptEdits"
  @auto_mode_fallback_notice "**Auto mode unavailable:** the selected model does not support Auto mode; using Accept edits instead."

  @doc "Builds the dynamic session setup result for the current adapter state."
  @spec session_result(map(), String.t()) :: map()
  def session_result(state, session_id) do
    %{
      "sessionId" => session_id,
      "modes" => modes_result(state),
      "configOptions" => config_options(state)
    }
    |> compact()
  end

  @doc "Builds dynamic config options from SDK initialization/model state."
  @spec config_options(map()) :: [map()]
  def config_options(state) do
    [
      mode_option(state),
      model_option(state),
      effort_option(state),
      fast_mode_option(state),
      agent_option(state)
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc "Builds the dynamic ACP modes result."
  @spec modes_result(map()) :: map()
  def modes_result(state) do
    %{
      "availableModes" => modes(state),
      "currentModeId" => effective_mode(state)
    }
  end

  @doc """
  Static, universally available Claude permission modes.

  The catalog is stable: Auto is advertised regardless of the selected
  model, and a session that selects it while the model cannot run it falls
  back to Accept edits (see `auto_fallback?/1`). Each entry carries its
  semantic kind under `_meta.kind`, matching claude-agent-acp
  `buildAvailableModes` (#1025).
  """
  @spec modes() :: [map()]
  def modes do
    [
      %{
        "id" => "default",
        "name" => "Manual",
        "description" => "Always ask before making changes",
        "_meta" => %{"kind" => "standard"}
      },
      %{
        "id" => "acceptEdits",
        "name" => "Accept edits",
        "description" => "Automatically accept all file edits",
        "_meta" => %{"kind" => "standard"}
      },
      %{
        "id" => "plan",
        "name" => "Plan",
        "description" => "Create a plan before making changes",
        "_meta" => %{"kind" => "plan"}
      },
      %{
        "id" => "auto",
        "name" => "Auto",
        "description" => "Claude handles permission decisions",
        "_meta" => %{"kind" => "auto_review"}
      }
    ]
  end

  @doc "Mode list gated by the explicit dangerous-mode opt-in."
  @spec modes(map()) :: [map()]
  def modes(state) do
    # A host may opt a session out of bypass through session meta; that wins
    # over the adapter option and over a bypass mode inherited at spawn time.
    bypass_allowed? = Map.get(state, :bypass_allowed?, true)

    if bypass_allowed? and
         (Keyword.get(Map.get(state, :opts, []), :allow_dangerously_skip_permissions, false) or
            Map.get(state, :permission_mode) == "bypassPermissions") do
      modes() ++
        [
          %{
            "id" => "bypassPermissions",
            "name" => "Bypass permissions",
            "description" => "Accepts all permissions",
            "_meta" => %{"kind" => "full_access"}
          }
        ]
    else
      modes()
    end
  end

  @doc """
  The mode the session actually runs in, after the Auto-mode fallback.

  Auto clamps to Accept edits when the current model is known and does not
  advertise Auto support; a mode outside the catalog clamps to `default`.
  """
  @spec current_mode(map()) :: String.t()
  def current_mode(state), do: effective_mode(state)

  @doc """
  True when the session asked for Auto but the current model cannot run it.

  A model Claude never described is treated as capable, matching
  claude-agent-acp's `isAutoUnavailable`: only a known model without
  `supportsAutoMode` triggers the fallback.
  """
  @spec auto_fallback?(map()) :: boolean()
  def auto_fallback?(state) do
    permission_mode_to_mode(Map.get(state, :permission_mode) || "default") == "auto" and
      auto_unavailable?(state)
  end

  @doc "The mode Auto falls back to when the model does not support it."
  @spec auto_fallback_mode() :: String.t()
  def auto_fallback_mode, do: @auto_mode_fallback

  @doc "The client-visible notice announcing the Auto-mode fallback."
  @spec auto_fallback_notice(map()) :: map()
  def auto_fallback_notice(state) do
    AdapterEvents.agent_message_chunk(session_id(state), @auto_mode_fallback_notice)
  end

  @doc "The `current_mode_update` for the session's effective mode."
  @spec mode_update(map()) :: map()
  def mode_update(state), do: current_mode_update(state)

  @doc """
  The Auto-mode fallback notice, at most once per session.

  Returns `{[], state}` once the notice has been delivered, so a session that
  keeps re-selecting Auto does not spam the transcript
  (`autoModeFallbackWarningShown` upstream).
  """
  @spec auto_fallback_messages(map()) :: {[map()], map()}
  def auto_fallback_messages(state) do
    if Map.get(state, :auto_fallback_warned?, false) do
      {[], %{state | auto_fallback_pending?: false}}
    else
      {[auto_fallback_notice(state)],
       %{state | auto_fallback_warned?: true, auto_fallback_pending?: false}}
    end
  end

  @doc "The Auto-mode fallback notice held since `session/new`, if one is due."
  @spec auto_fallback_pending_messages(map()) :: {[map()], map()}
  def auto_fallback_pending_messages(state) do
    if Map.get(state, :auto_fallback_pending?, false) do
      auto_fallback_messages(state)
    else
      {[], state}
    end
  end

  @doc """
  Rewrites an Auto `setMode` permission decision to the fallback mode.

  A client that accepts an Exit Plan "use auto mode" option asks Claude to
  switch the session to Auto; when the model cannot run Auto that request
  would be rejected, so it is clamped the same way the mode catalog is.
  Returns `{response, fallback_applied?}`.
  """
  @spec apply_auto_permission_fallback(map(), map()) :: {map(), boolean()}
  def apply_auto_permission_fallback(%{"behavior" => "allow"} = response, state) do
    updates = response["updatedPermissions"]

    if auto_unavailable?(state) and is_list(updates) and Enum.any?(updates, &auto_set_mode?/1) do
      {Map.put(response, "updatedPermissions", Enum.map(updates, &clamp_auto_set_mode/1)), true}
    else
      {response, false}
    end
  end

  def apply_auto_permission_fallback(response, _state), do: {response, false}

  defp auto_set_mode?(%{"type" => "setMode", "mode" => "auto"}), do: true
  defp auto_set_mode?(_update), do: false

  defp clamp_auto_set_mode(%{"type" => "setMode", "mode" => "auto"} = update),
    do: Map.put(update, "mode", @auto_mode_fallback)

  defp clamp_auto_set_mode(update), do: update

  @doc "Classifies a Claude SDK result into an ACP stop reason."
  @spec stop_reason(map()) :: String.t()
  def stop_reason(%{"subtype" => subtype})
      when subtype in ["error_max_turns", "error_max_budget_usd"] do
    "max_turn_requests"
  end

  def stop_reason(%{"subtype" => "error_max_structured_output_retries"}), do: "max_turn_requests"

  def stop_reason(%{"stop_reason" => reason}) when is_binary(reason) do
    Map.get(@stop_reasons, reason, "end_turn")
  end

  def stop_reason(%{"is_error" => true}), do: "refusal"
  def stop_reason(_), do: "end_turn"

  @doc "Maps one decoded SDK stdout message into ACP messages and SDK writes."
  @spec reduce_message(map(), map()) :: {[map()], [iodata()], map()}
  def reduce_message(%{"type" => "control_response"} = event, state) do
    handle_control_response(event, state)
  end

  def reduce_message(
        %{"type" => "control_request", "request_id" => request_id, "request" => request},
        state
      ) do
    handle_control_request(request_id, request, state)
  end

  def reduce_message(%{"type" => "control_cancel_request", "request_id" => request_id}, state) do
    state = cancel_pending_client_request(state, request_id)
    {[], [], state}
  end

  def reduce_message(%{"type" => "stream_event", "event" => event} = wrapper, state) do
    state = maybe_set_session(state, wrapper)
    handle_stream_event(event, state)
  end

  def reduce_message(%{"type" => "assistant", "message" => message} = wrapper, state) do
    state = maybe_set_session(state, wrapper)
    handle_assistant(message, SessionStore.message_grouping_id(wrapper), state)
  end

  def reduce_message(%{"type" => "user", "message" => message} = wrapper, state) do
    state = maybe_set_session(state, wrapper)
    handle_user(message, state)
  end

  def reduce_message(%{"type" => "result"} = event, state) do
    handle_result(event, maybe_set_session(state, event))
  end

  def reduce_message(%{"type" => "system"} = event, state) do
    handle_system(event, maybe_set_session(state, event))
  end

  def reduce_message(%{"type" => "tool_progress"} = event, state) do
    update =
      %{
        "toolCallId" => event["tool_use_id"],
        "status" => "in_progress",
        "_meta" => %{
          "ex_mcp" => %{
            "claude_sdk" => %{
              "toolName" => event["tool_name"],
              "elapsedTimeSeconds" => event["elapsed_time_seconds"],
              "taskId" => event["task_id"]
            }
          }
        }
      }
      |> compact()

    {[AdapterEvents.tool_call_update(session_id(state), update)], [], state}
  end

  def reduce_message(%{"type" => "tool_use_summary"} = event, state) do
    update = %{
      "_meta" => %{"ex_mcp" => %{"claude_sdk" => %{"toolUseSummary" => event["summary"]}}}
    }

    {[AdapterEvents.session_info_update(session_id(state), update)], [], state}
  end

  def reduce_message(%{"type" => "rate_limit_event"} = event, state) do
    update = %{
      "_meta" => %{
        "ex_mcp" => %{
          "claude_sdk" => %{
            "status" => "rate_limited",
            "rateLimitInfo" => event["rate_limit_info"]
          }
        }
      }
    }

    {[AdapterEvents.session_info_update(session_id(state), update)], [], state}
  end

  def reduce_message(_event, state), do: {[], [], state}

  @doc """
  Replays persisted Claude JSONL transcript entries as ACP session updates.
  """
  @spec replay_messages([map()], map()) :: {[map()], map()}
  def replay_messages(events, state) when is_list(events) do
    Enum.reduce(events, {[], state}, fn event, {messages, acc} ->
      acc = remember_message_id(event, acc)
      {replay_messages, acc} = replay_message(event, acc)
      {messages ++ replay_messages, acc}
    end)
  end

  @doc """
  Maps a client JSON-RPC response back into a Claude control response.

  Returns `{:ok, messages, iodata, state}` when answering the response also
  requires ACP session updates (the Auto-mode fallback notice).
  """
  @spec client_response(map(), map()) ::
          {:ok, iodata(), map()} | {:ok, [map()], iodata(), map()} | :unknown
  def client_response(%{"id" => id, "result" => result}, state) do
    case pop_pending_client_request(state, id) do
      {nil, _state} ->
        :unknown

      {%{request_id: request_id, request: request, kind: :permission}, state} ->
        permission_response(request_id, request, result, state)

      {%{request_id: request_id, request: request, kind: :elicitation_question}, state} ->
        response = ask_user_question_result(result, request)

        {:ok, ClaudeProtocol.control_success(request_id, response) |> ClaudeProtocol.line(),
         state}

      {%{request_id: request_id, kind: :file_read, request: request}, state} ->
        response =
          case file_read_response(result, request) do
            {:ok, response} -> ClaudeProtocol.control_success(request_id, response)
            {:error, error} -> ClaudeProtocol.control_error(request_id, error)
          end

        {:ok, ClaudeProtocol.line(response), state}

      {%{request_id: request_id}, state} ->
        {:ok, ClaudeProtocol.control_success(request_id, result || %{}) |> ClaudeProtocol.line(),
         state}
    end
  end

  def client_response(%{"id" => id, "error" => error}, state) do
    case pop_pending_client_request(state, id) do
      {nil, _state} ->
        :unknown

      {%{request_id: request_id, request: request, kind: :elicitation_question}, state} ->
        response = ask_user_question_result(%{"action" => "cancel"}, request)

        {:ok, ClaudeProtocol.control_success(request_id, response) |> ClaudeProtocol.line(),
         state}

      {%{request_id: request_id}, state} ->
        message = error["message"] || "ACP client request failed"
        {:ok, ClaudeProtocol.control_error(request_id, message) |> ClaudeProtocol.line(), state}
    end
  end

  def client_response(_msg, _state), do: :unknown

  defp permission_response(request_id, request, result, state) do
    {response, fallback?} =
      result["outcome"]
      |> Kernel.||(result)
      |> ClaudeProtocol.permission_result(request)
      |> apply_auto_permission_fallback(state)

    {messages, state} = if fallback?, do: auto_fallback_messages(state), else: {[], state}
    line = request_id |> ClaudeProtocol.control_success(response) |> ClaudeProtocol.line()

    if messages == [], do: {:ok, line, state}, else: {:ok, messages, line, state}
  end

  defp replay_message(%{"type" => "user"} = event, state) do
    {tool_messages, _writes, state} = reduce_message(event, state)
    text_messages = replay_user_content(event, state)
    {text_messages ++ tool_messages, state}
  end

  defp replay_message(event, state) do
    {messages, _writes, state} = reduce_message(event, state)
    {messages, state}
  end

  defp replay_user_content(event, state) do
    event
    |> get_in(["message", "content"])
    |> replay_content_blocks()
    |> Enum.map(fn content ->
      AdapterEvents.content_chunk(session_id(state), "user_message_chunk", content,
        meta: replay_meta(event),
        message_id: SessionStore.message_grouping_id(event)
      )
    end)
  end

  defp replay_content_blocks(content) when is_binary(content),
    do: [%{"type" => "text", "text" => content}]

  defp replay_content_blocks(content) when is_list(content) do
    content
    |> Enum.reject(&(&1["type"] == "tool_result"))
    |> Enum.flat_map(&replay_content_block/1)
  end

  defp replay_content_blocks(_content), do: []

  defp replay_content_block(%{"type" => "text", "text" => text}) when is_binary(text),
    do: [%{"type" => "text", "text" => text}]

  defp replay_content_block(%{"type" => "image", "source" => source}) when is_map(source) do
    [
      %{
        "type" => "image",
        "mimeType" => source["media_type"] || source["mimeType"] || "image/png",
        "data" => source["data"] || ""
      }
    ]
  end

  defp replay_content_block(_block), do: []

  defp replay_meta(event) do
    %{
      "ex_mcp" => %{
        "claude_sdk" =>
          %{
            "replay" => true,
            "messageUuid" => message_uuid(event),
            "parentUuid" => event["parentUuid"] || event["parent_uuid"],
            "timestamp" => event["timestamp"]
          }
          |> compact()
      }
    }
  end

  defp remember_message_id(event, state) do
    uuid = message_uuid(event)

    if is_binary(uuid) and Map.has_key?(state, :message_ids) do
      %{state | message_ids: Map.put(state.message_ids, uuid, event)}
    else
      state
    end
  end

  defp message_uuid(event) do
    event["uuid"] || event["message_uuid"] || event["messageUuid"] ||
      get_in(event, ["message", "id"])
  end

  defp handle_control_response(
         %{"response" => %{"request_id" => request_id, "response" => response}},
         state
       ) do
    case Map.pop(state.pending_controls, request_id) do
      {nil, _pending} ->
        {[], [], state}

      {:initialize, pending} ->
        state =
          %{state | pending_controls: pending}
          |> put_init_response(response || %{})

        messages = initialization_updates(state)
        {messages, [], state}

      {_kind, pending} ->
        {[], [], %{state | pending_controls: pending}}
    end
  end

  defp handle_control_response(%{"response" => %{"request_id" => request_id}}, state) do
    {_kind, pending} = Map.pop(state.pending_controls, request_id)
    {[], [], %{state | pending_controls: pending}}
  end

  defp handle_control_response(_event, state), do: {[], [], state}

  defp handle_control_request(
         request_id,
         %{"subtype" => "can_use_tool", "tool_name" => "AskUserQuestion"} = request,
         state
       ) do
    case ask_user_question_request(request, state) do
      {:ok, params, questions} ->
        acp_id = ACPProtocol.generate_id()
        message = Envelope.request("elicitation/create", params, acp_id)

        request =
          request
          |> Map.put("_questions", questions)
          |> Map.put_new("input", %{})

        state =
          put_pending_client_request(
            state,
            acp_id,
            request_id,
            :elicitation_question,
            request
          )

        {[message], [], state}

      {:error, reason} ->
        response = %{
          "behavior" => "deny",
          "message" => reason,
          "interrupt" => true,
          "toolUseID" => request["tool_use_id"],
          "decisionClassification" => "user_reject"
        }

        {[], [ClaudeProtocol.control_success(request_id, response) |> ClaudeProtocol.line()],
         state}
    end
  end

  defp handle_control_request(request_id, %{"subtype" => "can_use_tool"} = request, state) do
    request = Map.put(request, "_available_modes", Enum.map(modes(state), & &1["id"]))
    acp_id = ACPProtocol.generate_id()
    tool_call = ClaudeProtocol.permission_tool_call(request, state.cwd)
    options = ClaudeProtocol.permission_options(request)
    tool_call_id = tool_call["toolCallId"]

    message =
      ACPProtocol.encode_permission_request(session_id(state), tool_call, options)
      |> Map.put("_meta", permission_meta(request, tool_call))
      |> Map.put("id", acp_id)

    tool_message =
      if Map.has_key?(state.tool_calls, tool_call_id) do
        nil
      else
        AdapterEvents.tool_call(session_id(state), Map.put(tool_call, "status", "pending"))
      end

    state =
      state
      |> put_pending_client_request(acp_id, request_id, :permission, request)
      |> Map.update!(:tool_calls, fn tool_calls ->
        Map.put_new(tool_calls, tool_call_id, %{
          name: request["tool_name"],
          input: request["input"] || %{}
        })
      end)

    {[tool_message, message] |> Enum.reject(&is_nil/1), [], state}
  end

  defp handle_control_request(request_id, %{"subtype" => "read_file"} = request, state) do
    case validate_file_read_limit(request) do
      :ok ->
        acp_id = ACPProtocol.generate_id()

        # ACP's line/limit fields cannot express a byte cap. Keep the native
        # cap with this request and enforce it on the correlated response.
        message =
          ACPProtocol.encode_file_read_request(session_id(state), request["path"])
          |> Map.put("id", acp_id)

        state = put_pending_client_request(state, acp_id, request_id, :file_read, request)
        {[message], [], state}

      {:error, error} ->
        {[], [ClaudeProtocol.control_error(request_id, error) |> ClaudeProtocol.line()], state}
    end
  end

  defp handle_control_request(request_id, %{"subtype" => subtype}, state) do
    error = "Claude SDK control request #{subtype} is not supported by ExMCP yet"
    {[], [ClaudeProtocol.control_error(request_id, error) |> ClaudeProtocol.line()], state}
  end

  defp handle_control_request(request_id, _request, state) do
    {[],
     [
       ClaudeProtocol.control_error(request_id, "Malformed Claude SDK control request")
       |> ClaudeProtocol.line()
     ], state}
  end

  defp validate_file_read_limit(request) do
    case Map.fetch(request, "max_bytes") do
      :error -> :ok
      {:ok, limit} when is_integer(limit) and limit >= 0 -> :ok
      {:ok, _limit} -> {:error, "read_file max_bytes must be a non-negative integer"}
    end
  end

  defp file_read_response(result, request) when is_map(result) do
    content =
      case Map.fetch(result, "content") do
        {:ok, content} when not is_nil(content) -> content
        _other -> file_read_contents(result)
      end

    limit = Map.get(request, "max_bytes")

    cond do
      not is_binary(content) ->
        {:error, "read_file response must contain UTF-8 text"}

      is_integer(limit) and byte_size(content) > limit ->
        {:error, "read_file response exceeds max_bytes"}

      not String.valid?(content) ->
        {:error, "read_file response must contain UTF-8 text"}

      true ->
        {:ok,
         %{"contents" => content, "absPath" => result["absPath"] || request["path"]}
         |> compact()}
    end
  end

  defp file_read_response(_result, _request),
    do: {:error, "read_file response must contain UTF-8 text"}

  defp file_read_contents(result) do
    case Map.get(result, "contents") do
      nil -> ""
      content -> content
    end
  end

  defp ask_user_question_request(request, state) do
    questions =
      request
      |> get_in(["input", "questions"])
      |> valid_questions()

    cond do
      not is_map(get_in(state.client_capabilities || %{}, ["elicitation", "form"])) ->
        {:error, "AskUserQuestion requires ACP form elicitation support"}

      questions == [] ->
        {:error, "AskUserQuestion called with no valid questions"}

      true ->
        properties =
          questions
          |> Enum.with_index()
          |> Enum.reduce(%{}, fn {question, index}, acc ->
            options =
              Enum.map(question["options"], fn option ->
                %{"const" => option["label"], "title" => option["label"]}
                |> maybe_put("description", option["description"])
                |> maybe_put(
                  "_meta",
                  if(is_binary(option["preview"]),
                    do: %{"_claude/askUserQuestionOption" => %{"preview" => option["preview"]}},
                    else: nil
                  )
                )
              end)

            description = if length(questions) == 1, do: nil, else: question["question"]

            selection =
              if question["multiSelect"] == true do
                %{"type" => "array", "items" => %{"anyOf" => options}}
              else
                %{"type" => "string", "oneOf" => options}
              end
              |> maybe_put("title", question["header"])
              |> maybe_put("description", description)

            custom = %{
              "type" => "string",
              "title" => "Other",
              "description" =>
                if(question["multiSelect"] == true,
                  do: "Type your own answer to add to your selection above (optional).",
                  else:
                    "Type your own answer, or add a note to the option you chose above (optional)."
                ),
              "_meta" => %{
                "_askUserQuestionCustomAnswer" => %{
                  "questionId" => "question_#{index}",
                  "isCustomAnswer" => true
                }
              }
            }

            acc
            |> Map.put("question_#{index}", selection)
            |> Map.put("question_#{index}_custom", custom)
          end)

        message =
          if length(questions) == 1,
            do: hd(questions)["question"],
            else: "Please answer the following questions."

        params = %{
          "mode" => "form",
          "sessionId" => session_id(state),
          "toolCallId" => request["tool_use_id"],
          "message" => message,
          "requestedSchema" => %{"type" => "object", "properties" => properties}
        }

        {:ok, params, questions}
    end
  end

  defp valid_questions(questions) when is_list(questions) do
    Enum.filter(questions, fn
      %{"question" => question, "options" => options}
      when is_binary(question) and is_list(options) and options != [] ->
        Enum.all?(options, fn
          %{"label" => label} when is_binary(label) and label != "" -> true
          _ -> false
        end)

      _ ->
        false
    end)
  end

  defp valid_questions(_questions), do: []

  defp ask_user_question_result(%{"action" => "decline"}, request) do
    allow_ask_user_question(request, %{})
  end

  defp ask_user_question_result(%{"action" => "accept", "content" => content}, request)
       when is_map(content) do
    {answers, annotations} =
      request["_questions"]
      |> Enum.with_index()
      |> Enum.reduce({%{}, %{}}, fn {question, index}, {answers, annotations} ->
        key = question["question"]
        custom = custom_answer(content["question_#{index}_custom"])
        picks = picked_answers(content["question_#{index}"])

        # A multi-select is additive: the checked options and the typed answer
        # are independent fields, so filling both means both. A single-select
        # is answered by one thing: the typed answer replaces nothing picked,
        # and otherwise travels beside the pick as the tool's own per-question
        # `annotations[question].notes`, the slot the CLI renders to the model
        # as `"Q"="A" notes: ...`, so a client that presents the box as a
        # notes field cannot make the selection disappear.
        cond do
          question["multiSelect"] == true ->
            items = if custom == "", do: picks, else: picks ++ [custom]
            {put_answer(answers, key, join_multi_select(items)), annotations}

          picks == [] ->
            {put_answer(answers, key, custom), annotations}

          custom == "" ->
            {put_answer(answers, key, Enum.join(picks, ", ")), annotations}

          true ->
            {put_answer(answers, key, Enum.join(picks, ", ")),
             Map.put(annotations, key, %{"notes" => custom})}
        end
      end)

    allow_ask_user_question(request, answers, annotations)
  end

  defp ask_user_question_result(_response, request) do
    %{
      "behavior" => "deny",
      "message" => "User cancelled AskUserQuestion",
      "interrupt" => true,
      "toolUseID" => request["tool_use_id"],
      "decisionClassification" => "user_reject"
    }
  end

  defp allow_ask_user_question(request, answers, annotations \\ %{}) do
    input = request["input"] || %{}

    updated_input =
      input
      |> Map.put("answers", answers)
      |> then(fn input ->
        if annotations == %{} do
          input
        else
          existing = if is_map(input["annotations"]), do: input["annotations"], else: %{}
          Map.put(input, "annotations", Map.merge(existing, annotations))
        end
      end)

    %{
      "behavior" => "allow",
      "updatedInput" => updated_input,
      "toolUseID" => request["tool_use_id"],
      "decisionClassification" => "user_temporary"
    }
  end

  defp custom_answer(custom) when is_binary(custom), do: String.trim(custom)
  defp custom_answer(_custom), do: ""

  defp picked_answers(picks) when is_list(picks) do
    picks
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.map(&to_string/1)
  end

  defp picked_answers(pick) when is_binary(pick) and pick != "", do: [pick]
  defp picked_answers(_pick), do: []

  defp put_answer(answers, _key, ""), do: answers
  defp put_answer(answers, key, answer), do: Map.put(answers, key, answer)

  # The CLI's own AskUserQuestion UI comma-joins multi-select answers and
  # JSON-quotes any item that itself contains the separator or a double quote;
  # the tool's `call()` splits the string back on the same rule, so a typed
  # answer such as `Redis, not Memcached` stays one item.
  defp join_multi_select(items) do
    Enum.map_join(items, ", ", fn item ->
      if String.contains?(item, ", ") or String.contains?(item, "\""),
        do: Jason.encode!(item),
        else: item
    end)
  end

  defp permission_meta(request, tool_call) do
    title =
      if request["tool_name"] == "ExitPlanMode", do: "Ready to code?", else: tool_call["title"]

    %{
      "permission" =>
        %{"version" => 1, "title" => title || request["tool_name"] || "Use tool?"}
        |> maybe_put(
          "description",
          if(is_binary(request["decision_reason"]),
            do: "Reason: #{request["decision_reason"]}",
            else: nil
          )
        )
    }
  end

  # `message_start` is the only streamed event carrying the Anthropic API
  # message id, and it is the same id the consolidated assistant message and
  # the persisted transcript use, so every chunk of the message that follows is
  # tagged with it. Mirrors `currentStreamMessageId` in claude-agent-acp
  # `src/acp-agent.ts`.
  defp handle_stream_event(%{"type" => "message_start", "message" => message}, state) do
    {[], [], %{state | stream_message_id: stream_message_id(message)}}
  end

  defp handle_stream_event(%{"type" => "content_block_start", "content_block" => block}, state) do
    case block do
      %{"type" => "tool_use"} ->
        {messages, state} = emit_tool_pending(block, state)
        {messages, [], state}

      %{"type" => type} ->
        {[], [], %{state | current_block_type: type}}

      _ ->
        {[], [], state}
    end
  end

  defp handle_stream_event(%{"type" => "content_block_delta", "delta" => delta}, state) do
    case delta do
      %{"type" => "text_delta", "text" => text} ->
        state = %{
          state
          | text_acc: [text | state.text_acc],
            current_assistant_text_streamed?: true
        }

        {[
           AdapterEvents.agent_message_chunk(session_id(state), text,
             message_id: state.stream_message_id
           )
         ], [], state}

      %{"type" => "thinking_delta", "thinking" => thinking} ->
        state = %{
          state
          | thinking_acc: [thinking | state.thinking_acc],
            current_block_type: "thinking"
        }

        {[
           AdapterEvents.agent_thought_chunk(session_id(state), thinking,
             message_id: state.stream_message_id
           )
         ], [], state}

      %{"type" => "input_json_delta"} ->
        {[], [], state}

      _ ->
        {[], [], state}
    end
  end

  defp handle_stream_event(%{"type" => "content_block_stop"}, state) do
    {[], [], finalize_block(state)}
  end

  defp handle_stream_event(_event, state), do: {[], [], state}

  defp stream_message_id(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp stream_message_id(_message), do: nil

  defp handle_assistant(%{"content" => content} = message, message_id, state)
       when is_list(content) do
    state =
      state
      |> maybe_set(:model, message["model"])
      |> maybe_set_session(message)

    {messages, writes, state} =
      Enum.reduce(content, {[], [], state}, fn block, {messages, writes, acc} ->
        {new_messages, new_writes, acc} = handle_assistant_block(block, message_id, acc)
        {messages ++ new_messages, writes ++ new_writes, acc}
      end)

    {messages, writes, %{state | current_assistant_text_streamed?: false}}
  end

  defp handle_assistant(_message, _message_id, state),
    do: {[], [], %{state | current_assistant_text_streamed?: false}}

  defp handle_assistant_block(
         %{"type" => "text"},
         _message_id,
         %{current_assistant_text_streamed?: true} = state
       ) do
    {[], [], state}
  end

  defp handle_assistant_block(%{"type" => "text", "text" => text}, message_id, state) do
    state = %{state | text_acc: [text | state.text_acc]}

    {[AdapterEvents.agent_message_chunk(session_id(state), text, message_id: message_id)], [],
     state}
  end

  defp handle_assistant_block(%{"type" => "thinking", "thinking" => thinking}, _message_id, state) do
    state = %{
      state
      | thinking_blocks: [%{text: thinking, signature: nil} | state.thinking_blocks]
    }

    {[], [], state}
  end

  defp handle_assistant_block(%{"type" => "tool_use"} = block, _message_id, state) do
    {pending_messages, state} = emit_tool_pending(block, state)
    {update_messages, state} = emit_tool_update(block, state)

    plan_messages =
      if block["name"] == "TodoWrite" do
        entries = ToolInfo.plan_entries(block["input"] || %{})

        if entries == [],
          do: [],
          else: [AdapterEvents.plan(session_id(state), entries)]
      else
        []
      end

    {pending_messages ++ update_messages ++ plan_messages, [], state}
  end

  defp handle_assistant_block(_block, _message_id, state), do: {[], [], state}

  defp handle_user(%{"content" => content}, state) when is_list(content) do
    {messages, state} =
      content
      |> Enum.filter(&(&1["type"] == "tool_result"))
      |> Enum.reduce({[], state}, fn result, {messages, acc} ->
        tool_call_id = result["tool_use_id"]
        tool = Map.get(acc.tool_calls, tool_call_id, %{})
        update = tool_result_update(result, tool)
        acc = %{acc | tool_calls: Map.delete(acc.tool_calls, tool_call_id)}

        {[AdapterEvents.tool_call_update(session_id(acc), update) | messages], acc}
      end)

    {Enum.reverse(messages), [], state}
  end

  defp handle_user(_message, state), do: {[], [], state}

  defp handle_result(result, state) do
    state =
      state
      |> finalize_block()
      |> Map.put(
        :fast_mode_enabled,
        fast_mode_enabled?(result["fast_mode_state"], state.fast_mode_enabled)
      )
      |> accumulate_model_usage(result)

    cond do
      not is_nil(state.deferred_result) and MapSet.size(state.background_subagents) == 0 ->
        settle_result(state.deferred_result, %{state | deferred_result: nil})

      not is_nil(state.deferred_result) ->
        {[], [], state}

      not is_nil(state.pending_prompt_id) and MapSet.size(state.background_subagents) > 0 ->
        defer_result(result, state)

      true ->
        settle_result(result, state)
    end
  end

  defp defer_result(result, state) do
    acp_session_id = session_id(state)
    claude_session_id = result["session_id"] || state.claude_session_id

    usage = format_usage(result["usage"] || %{})

    text =
      case state.text_acc do
        [] -> result["result"] || ""
        acc -> IO.iodata_to_binary(Enum.reverse(acc))
      end

    messages =
      [
        usage_update(acp_session_id, usage, result, state),
        config_option_update(state),
        AdapterEvents.session_info_update(acp_session_id, %{
          "_meta" => %{"ex_mcp" => %{"claude_sdk" => %{"status" => "waiting_for_subagents"}}}
        }),
        result_text_chunk(acp_session_id, text, state)
      ]
      |> Enum.reject(&is_nil/1)

    state = %{
      state
      | deferred_result: result,
        session_id: acp_session_id,
        claude_session_id: claude_session_id,
        text_acc: if(state.text_acc == [] and text != "", do: [text], else: state.text_acc)
    }

    {messages, [], state}
  end

  defp settle_result(result, state) do
    # Provider metadata carries Claude Code's UUID for correlation while every
    # ACP envelope keeps the client-visible id returned by session/new.
    acp_session_id = session_id(state)
    claude_session_id = result["session_id"] || state.claude_session_id

    usage = format_usage(result["usage"] || %{})

    text =
      case state.text_acc do
        [] -> result["result"] || ""
        acc -> IO.iodata_to_binary(Enum.reverse(acc))
      end

    response =
      %{
        "stopReason" => stop_reason(result),
        "usage" => usage,
        "_meta" => %{
          "quota" => turn_quota(usage, state),
          "ex_mcp" => %{
            "claude_sdk" =>
              %{
                "text" => text,
                "sessionId" => claude_session_id,
                "modelUsage" => result["modelUsage"],
                "totalCostUsd" => result["total_cost_usd"],
                "errors" => result["errors"]
              }
              |> compact()
          }
        }
      }
      |> maybe_put_error_meta(result)

    messages =
      [
        usage_update(acp_session_id, usage, result, state),
        config_option_update(state),
        AdapterEvents.session_info_update(acp_session_id, %{
          "_meta" => %{"ex_mcp" => %{"claude_sdk" => %{"status" => "completed"}}}
        }),
        result_text_chunk(acp_session_id, text, state)
      ]
      |> Enum.reject(&is_nil/1)

    messages =
      if state.pending_prompt_id do
        [Envelope.response(state.pending_prompt_id, response) | messages]
      else
        messages
      end

    state = %{
      state
      | pending_prompt_id: nil,
        active_prompt_session_id: nil,
        text_acc: [],
        thinking_acc: [],
        thinking_blocks: [],
        current_block_type: nil,
        current_assistant_text_streamed?: false,
        stream_message_id: nil,
        session_id: acp_session_id,
        claude_session_id: claude_session_id,
        deferred_result: nil,
        background_subagents: MapSet.new(),
        turn_model_usage: %{}
    }

    {writes, state} = start_next_queued_prompt(state)

    {Enum.reverse(messages), writes, state}
  end

  defp result_text_chunk(session_id, text, %{pending_prompt_id: pending_prompt_id, text_acc: []})
       when not is_nil(pending_prompt_id) and is_binary(text) and text != "" do
    AdapterEvents.agent_message_chunk(session_id, text)
  end

  defp result_text_chunk(_session_id, _text, _state), do: nil

  defp handle_system(%{"subtype" => "init"} = event, state) do
    state =
      state
      |> maybe_set_session(event)
      |> maybe_set(:model, event["model"])
      |> maybe_set(:permission_mode, event["permissionMode"])
      |> Map.put(
        :fast_mode_enabled,
        fast_mode_enabled?(event["fast_mode_state"], state.fast_mode_enabled)
      )

    updates =
      [
        AdapterEvents.session_info_update(session_id(state), %{
          "_meta" => %{
            "ex_mcp" => %{
              "claude_sdk" =>
                %{
                  "status" => "initialized",
                  "sessionId" => state.claude_session_id,
                  "claudeCodeVersion" => event["claude_code_version"],
                  "cwd" => event["cwd"],
                  "tools" => event["tools"],
                  "mcpServers" => event["mcp_servers"]
                }
                |> compact()
            }
          }
        }),
        current_mode_update(state),
        config_option_update(state),
        available_commands_update(state, event["slash_commands"] || [])
      ]
      |> Enum.reject(&is_nil/1)

    {updates, [], state}
  end

  defp handle_system(%{"subtype" => "status"} = event, state) do
    state = maybe_set(state, :permission_mode, event["permissionMode"])

    update =
      %{
        "_meta" => %{
          "ex_mcp" => %{
            "claude_sdk" =>
              %{
                "status" => event["status"],
                "compactResult" => event["compact_result"],
                "compactError" => event["compact_error"]
              }
              |> compact()
          }
        }
      }

    messages =
      [AdapterEvents.session_info_update(session_id(state), update), current_mode_update(state)]
      |> Enum.reject(&is_nil/1)

    {messages, [], state}
  end

  defp handle_system(%{"subtype" => "session_state_changed"} = event, state) do
    update = %{"_meta" => %{"ex_mcp" => %{"claude_sdk" => %{"sessionState" => event["state"]}}}}
    info = AdapterEvents.session_info_update(session_id(state), update)

    if event["state"] == "idle" and not is_nil(state.deferred_result) and
         MapSet.size(state.background_subagents) == 0 do
      {messages, writes, state} = settle_result(state.deferred_result, state)
      {[info | messages], writes, state}
    else
      {[info], [], state}
    end
  end

  defp handle_system(%{"subtype" => "commands_changed", "commands" => commands}, state) do
    {[available_commands_update(state, commands)], [], state}
  end

  defp handle_system(%{"subtype" => subtype} = event, state)
       when subtype in [
              "task_started",
              "task_progress",
              "task_updated",
              "task_notification",
              "background_tasks_changed"
            ] do
    state = track_background_subagents(event, state)
    entries = task_plan_entries(event)
    messages = if entries == [], do: [], else: [AdapterEvents.plan(session_id(state), entries)]
    {messages, [], state}
  end

  defp handle_system(%{"subtype" => "permission_denied"} = event, state) do
    update =
      %{
        "toolCallId" => event["tool_use_id"],
        "status" => "failed",
        "rawOutput" => event["message"],
        "_meta" => %{
          "ex_mcp" => %{
            "claude_sdk" =>
              %{
                "toolName" => event["tool_name"],
                "decisionReason" => event["decision_reason"],
                "decisionReasonType" => event["decision_reason_type"]
              }
              |> compact()
          }
        }
      }

    {[AdapterEvents.tool_call_update(session_id(state), update)], [], state}
  end

  defp handle_system(%{"subtype" => subtype} = event, state) do
    update = %{
      "_meta" => %{"ex_mcp" => %{"claude_sdk" => %{"systemSubtype" => subtype, "event" => event}}}
    }

    {[AdapterEvents.session_info_update(session_id(state), update)], [], state}
  end

  defp emit_tool_pending(%{"id" => id, "name" => name, "input" => input}, state) do
    if Map.has_key?(state.tool_calls, id) do
      {[], state}
    else
      info = ToolInfo.from_use(name, input || %{}, id, state.cwd)

      update =
        info
        |> Map.take(["title", "kind", "content", "locations", "rawInput", "_meta"])
        |> Map.put("toolCallId", id)
        |> Map.put("status", "pending")
        |> compact()

      state = %{
        state
        | tool_calls: Map.put(state.tool_calls, id, %{name: name, input: input || %{}})
      }

      {[AdapterEvents.tool_call(session_id(state), update)], state}
    end
  end

  defp emit_tool_pending(_block, state), do: {[], state}

  defp emit_tool_update(%{"id" => id, "name" => name, "input" => input}, state) do
    info = ToolInfo.from_use(name, input || %{}, id, state.cwd)

    update =
      info
      |> Map.take(["title", "kind", "content", "locations", "rawInput", "_meta"])
      |> Map.put("toolCallId", id)
      |> Map.put("status", "in_progress")
      |> compact()

    {[AdapterEvents.tool_call_update(session_id(state), update)], state}
  end

  defp emit_tool_update(_block, state), do: {[], state}

  defp tool_result_update(result, %{name: "Bash"}) do
    is_error = result["is_error"] || false
    output = parse_tool_result_raw(result["content"]) || ""
    exit_code = bash_exit_code(result["content"], is_error)
    tool_call_id = result["tool_use_id"]

    %{
      "toolCallId" => tool_call_id,
      "status" => if(is_error, do: "failed", else: "completed"),
      "content" => [%{"type" => "terminal", "terminalId" => tool_call_id}],
      "rawOutput" => output,
      "_meta" => %{
        "terminal_output" => %{"terminal_id" => tool_call_id, "data" => output},
        "terminal_exit" => %{
          "terminal_id" => tool_call_id,
          "exit_code" => exit_code,
          "signal" => nil
        },
        "ex_mcp" => %{"claude_sdk" => %{"isError" => is_error}}
      }
    }
    |> compact()
  end

  defp tool_result_update(result, tool) do
    is_error = result["is_error"] || false

    %{
      "toolCallId" => result["tool_use_id"],
      "status" => if(is_error, do: "failed", else: "completed"),
      "content" => parse_tool_result_content(result["content"]),
      "rawOutput" => parse_tool_result_raw(result["content"]),
      "_meta" =>
        %{
          "ex_mcp" => %{
            "claude_sdk" => %{
              "isError" => is_error,
              "toolName" => tool[:name],
              "toolInput" => tool[:input]
            }
          }
        }
        |> compact()
    }
    |> compact()
  end

  defp initialization_updates(%{session_id: nil}), do: []

  defp initialization_updates(state) do
    [
      available_commands_update(state, state.available_commands),
      config_option_update(state),
      current_mode_update(state)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp put_init_response(state, response) do
    %{
      state
      | init_response: response,
        available_commands: normalize_commands(response["commands"] || []),
        available_models: response["models"] || [],
        available_agents:
          normalize_agents(response["agents"] || response["supportedAgents"] || []),
        fast_mode_enabled:
          fast_mode_enabled?(response["fast_mode_state"], state.fast_mode_enabled)
    }
  end

  defp mode_option(state) do
    %{
      "id" => "mode",
      "name" => "Mode",
      "description" => "Session permission mode",
      "category" => "mode",
      "type" => "select",
      "currentValue" => effective_mode(state),
      "options" =>
        Enum.map(modes(state), fn mode ->
          %{
            "name" => mode["name"],
            "value" => mode["id"],
            "description" => mode["description"],
            "_meta" => mode["_meta"]
          }
          |> compact()
        end)
    }
  end

  defp model_option(state) do
    options =
      case state.available_models do
        [] ->
          [
            %{"name" => "Default", "value" => "default"},
            %{"name" => "Sonnet", "value" => "sonnet"},
            %{"name" => "Opus", "value" => "opus"}
          ]

        models ->
          Enum.map(models, fn model ->
            %{
              "name" =>
                model["displayName"] || model["display_name"] || model["name"] || model["id"] ||
                  model["value"],
              "value" => model["value"] || model["id"] || model["name"],
              "description" => model["description"]
            }
            |> compact()
          end)
      end

    %{
      "id" => "model",
      "name" => "Model",
      "description" => "AI model to use",
      "category" => "model",
      "type" => "select",
      "currentValue" => state.model || "default",
      "options" => options
    }
  end

  defp effort_option(state) do
    model = current_model_info(state)
    levels = model["supportedEffortLevels"] || model["supported_effort_levels"] || []

    options =
      if levels == [] do
        [
          %{"name" => "Default", "value" => "default"},
          %{"name" => "Low", "value" => "low"},
          %{"name" => "Medium", "value" => "medium"},
          %{"name" => "High", "value" => "high"}
        ]
      else
        [%{"name" => "Default", "value" => "default"}] ++
          Enum.map(levels, fn level ->
            %{"name" => humanize_config_value(level), "value" => level}
          end)
      end

    %{
      "id" => "effort",
      "name" => "Effort",
      "description" => "Available effort levels for this model",
      "category" => "thought_level",
      "type" => "select",
      "currentValue" => state.effort || "default",
      "options" => options
    }
  end

  defp fast_mode_option(state) do
    model = current_model_info(state)

    if model["supportsFastMode"] == true or model["supports_fast_mode"] == true do
      if Capabilities.supported?(state.client_capabilities, :boolean_config_options) do
        %{
          "id" => "fast",
          "name" => "Fast mode",
          "description" => "Faster responses on supported models",
          "category" => "model_config",
          "type" => "boolean",
          "currentValue" => state.fast_mode_enabled == true
        }
      else
        %{
          "id" => "fast",
          "name" => "Fast mode",
          "description" => "Faster responses on supported models",
          "category" => "model_config",
          "type" => "select",
          "currentValue" => if(state.fast_mode_enabled == true, do: "on", else: "off"),
          "options" => [
            %{"name" => "On", "value" => "on"},
            %{"name" => "Off", "value" => "off"}
          ]
        }
      end
    end
  end

  defp agent_option(%{available_agents: agents} = state) when is_list(agents) and agents != [] do
    %{
      "id" => "agent",
      "name" => "Agent",
      "description" => "Main-thread agent persona",
      "type" => "select",
      "currentValue" => state.current_agent || "default",
      "options" =>
        [
          %{
            "name" => "Default",
            "value" => "default",
            "description" => "Standard Claude Code agent"
          }
        ] ++
          Enum.map(agents, fn agent ->
            %{
              "name" => agent["name"],
              "value" => agent["name"],
              "description" => agent["description"]
            }
            |> compact()
          end)
    }
  end

  defp agent_option(_state), do: nil

  defp current_mode_update(state) do
    AdapterEvents.current_mode_update(
      session_id(state),
      effective_mode(state)
    )
  end

  defp config_option_update(state) do
    AdapterEvents.config_option_update(session_id(state), config_options(state))
  end

  defp available_commands_update(_state, []), do: nil

  defp available_commands_update(state, commands) do
    AdapterEvents.available_commands_update(session_id(state), normalize_commands(commands))
  end

  defp normalize_commands(commands) do
    Enum.map(commands, fn
      command when is_binary(command) ->
        %{"name" => command, "description" => command}

      %{"name" => _} = command ->
        command

      %{"id" => id} = command ->
        Map.put_new(command, "name", id)

      other ->
        %{"name" => inspect(other), "description" => inspect(other)}
    end)
  end

  defp normalize_agents(agents) do
    agents
    |> Enum.map(fn
      %{"name" => name} = agent when is_binary(name) ->
        agent

      %{name: name} = agent when is_binary(name) ->
        agent
        |> Enum.map(fn {key, value} -> {to_string(key), value} end)
        |> Map.new()

      name when is_binary(name) ->
        %{"name" => name}

      _other ->
        nil
    end)
    |> Enum.reject(fn
      nil ->
        true

      agent ->
        agent["name"] in [
          "claude",
          "general-purpose",
          "Explore",
          "Plan",
          "statusline-setup",
          "default"
        ]
    end)
  end

  defp current_model_info(state) do
    current = state.model || "default"

    Enum.find(state.available_models || [], fn model ->
      (model["value"] || model["id"] || model["name"]) == current
    end) || %{}
  end

  defp fast_mode_enabled?("off", _fallback), do: false
  defp fast_mode_enabled?(state, _fallback) when state in ["on", "cooldown"], do: true
  defp fast_mode_enabled?(nil, fallback), do: fallback == true
  defp fast_mode_enabled?(_, fallback), do: fallback == true

  defp humanize_config_value(value) when is_binary(value) do
    value
    |> String.split(~r/[_-]+/, trim: true)
    |> Enum.map_join(" ", fn
      <<first::binary-size(1), rest::binary>> -> String.upcase(first) <> rest
      "" -> ""
    end)
  end

  defp humanize_config_value(value), do: to_string(value)

  defp track_background_subagents(
         %{"subtype" => "task_started", "task_id" => task_id, "subagent_type" => subagent_type},
         %{pending_prompt_id: pending_prompt_id} = state
       )
       when is_binary(task_id) and task_id != "" and is_binary(subagent_type) and
              subagent_type != "" and
              not is_nil(pending_prompt_id) do
    %{state | background_subagents: MapSet.put(state.background_subagents, task_id)}
  end

  defp track_background_subagents(
         %{"subtype" => "task_notification", "task_id" => task_id},
         state
       )
       when is_binary(task_id) do
    %{state | background_subagents: MapSet.delete(state.background_subagents, task_id)}
  end

  defp track_background_subagents(
         %{"subtype" => "task_updated", "task_id" => task_id, "patch" => %{"status" => status}},
         state
       )
       when is_binary(task_id) and status in ["completed", "failed", "killed", "cancelled"] do
    %{state | background_subagents: MapSet.delete(state.background_subagents, task_id)}
  end

  defp track_background_subagents(
         %{"subtype" => "background_tasks_changed", "tasks" => tasks},
         state
       )
       when is_list(tasks) do
    live_ids =
      tasks
      |> Enum.flat_map(fn
        %{"task_id" => task_id} when is_binary(task_id) -> [task_id]
        _ -> []
      end)
      |> MapSet.new()

    %{state | background_subagents: MapSet.intersection(state.background_subagents, live_ids)}
  end

  defp track_background_subagents(_event, state), do: state

  defp task_plan_entries(%{"subtype" => "task_started"} = event) do
    [
      %{
        "content" => event["description"] || event["prompt"] || "Task started",
        "priority" => "medium",
        "status" => "in_progress"
      }
    ]
  end

  defp task_plan_entries(%{"subtype" => "task_progress"} = event) do
    [
      %{
        "content" => event["summary"] || event["description"] || "Task running",
        "priority" => "medium",
        "status" => "in_progress"
      }
    ]
  end

  defp task_plan_entries(%{"subtype" => "task_notification"} = event) do
    status = if event["status"] == "completed", do: "completed", else: "pending"

    [
      %{
        "content" => event["summary"] || "Task #{event["status"]}",
        "priority" => "medium",
        "status" => status
      }
    ]
  end

  defp task_plan_entries(%{"patch" => patch}) do
    status = if patch["status"] == "completed", do: "completed", else: "in_progress"

    [
      %{
        "content" => patch["description"] || patch["error"] || "Task updated",
        "priority" => "medium",
        "status" => status
      }
    ]
  end

  defp task_plan_entries(%{"subtype" => "background_tasks_changed"}), do: []
  defp task_plan_entries(_event), do: []

  defp finalize_block(%{current_block_type: "thinking", thinking_acc: acc} = state)
       when acc != [] do
    text = IO.iodata_to_binary(Enum.reverse(acc))

    %{
      state
      | thinking_blocks: [%{text: text, signature: nil} | state.thinking_blocks],
        thinking_acc: [],
        current_block_type: nil
    }
  end

  defp finalize_block(state), do: %{state | current_block_type: nil}

  defp parse_tool_result_content(content) when is_list(content) do
    Enum.map(content, fn
      %{"type" => "text", "text" => text} ->
        %{"type" => "content", "content" => %{"type" => "text", "text" => text}}

      %{"text" => text} ->
        %{"type" => "content", "content" => %{"type" => "text", "text" => text}}

      other ->
        %{"type" => "content", "content" => %{"type" => "text", "text" => inspect(other)}}
    end)
  end

  defp parse_tool_result_content(content) when is_binary(content) do
    [%{"type" => "content", "content" => %{"type" => "text", "text" => content}}]
  end

  defp parse_tool_result_content(_), do: []

  defp parse_tool_result_raw(content) when is_binary(content), do: content

  defp parse_tool_result_raw(%{"type" => "bash_code_execution_result"} = content) do
    [content["stdout"], content["stderr"]]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join("\n")
  end

  defp parse_tool_result_raw(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"text" => text} -> text
      other -> inspect(other)
    end)
  end

  defp parse_tool_result_raw(_), do: nil

  defp bash_exit_code(%{"type" => "bash_code_execution_result", "return_code" => code}, _is_error)
       when is_integer(code),
       do: code

  defp bash_exit_code(_content, true), do: 1
  defp bash_exit_code(_content, _is_error), do: 0

  defp format_usage(raw) do
    %{
      "inputTokens" => raw["input_tokens"] || 0,
      "outputTokens" => raw["output_tokens"] || 0,
      "cacheReadTokens" => raw["cache_read_input_tokens"] || 0,
      "cacheCreationTokens" => raw["cache_creation_input_tokens"] || 0
    }
  end

  # `_meta.quota` for a prompt response: what this turn spent, in the shape
  # claude-agent-acp #1037 settled on (snake_case containers, camelCase
  # counters) so a client reads one shape from Claude and from Codex.
  #
  # The two halves have different scopes and need not add up. `token_count`
  # mirrors the response's own `usage`, which Claude reports for the main
  # agent loop only. The `model_usage` rows come from `result.modelUsage`,
  # which also counts Task subagents, sidechains and internal calls such as
  # compaction, so they can total more than `token_count`.
  defp turn_quota(usage, state) do
    %{
      "token_count" => quota_token_count(usage),
      "model_usage" =>
        state
        |> Map.get(:turn_model_usage, %{})
        |> Enum.sort_by(fn {model, _tally} -> model end)
        |> Enum.map(fn {model, tally} ->
          %{"model" => model, "token_count" => quota_token_count(tally)}
        end)
    }
  end

  # One `token_count`. `cachedInputTokens` is cache reads, matching Codex's
  # field; Claude also reports cache writes, which Codex has no slot for, so
  # those ride along under the name the ACP `usage` field already uses and are
  # counted in `totalTokens`. `reasoningOutputTokens` is always 0: Claude bills
  # thinking inside its output tokens and never breaks it out, and the key is
  # kept so the shape stays uniform across agents.
  defp quota_token_count(tally) do
    input = tally["inputTokens"] || 0
    output = tally["outputTokens"] || 0
    cache_read = tally["cacheReadTokens"] || 0
    cache_write = tally["cacheCreationTokens"] || 0

    %{
      "totalTokens" => input + output + cache_read + cache_write,
      "inputTokens" => input,
      "cachedInputTokens" => cache_read,
      "cachedWriteTokens" => cache_write,
      "outputTokens" => output,
      "reasoningOutputTokens" => 0
    }
  end

  # `result.modelUsage` is a running total for the whole Claude process, not a
  # per-result figure, so a result's own spend is what it added to the previous
  # reading. Advance the reading on every result and fold the increment into
  # the turn tally that `settle_result/2` reports and resets.
  defp accumulate_model_usage(state, result) do
    reading = normalize_model_usage(result["modelUsage"])
    increment = model_usage_increment(reading, Map.get(state, :last_model_usage, %{}))

    %{
      state
      | last_model_usage: reading,
        turn_model_usage: add_model_usage(Map.get(state, :turn_model_usage, %{}), increment)
    }
  end

  defp normalize_model_usage(model_usage) when is_map(model_usage) do
    Map.new(model_usage, fn {model, usage} ->
      usage = if is_map(usage), do: usage, else: %{}

      {to_string(model),
       %{
         "inputTokens" => finite_count(usage["inputTokens"] || usage["input_tokens"]),
         "outputTokens" => finite_count(usage["outputTokens"] || usage["output_tokens"]),
         "cacheReadTokens" =>
           finite_count(usage["cacheReadInputTokens"] || usage["cache_read_input_tokens"]),
         "cacheCreationTokens" =>
           finite_count(usage["cacheCreationInputTokens"] || usage["cache_creation_input_tokens"])
       }}
    end)
  end

  defp normalize_model_usage(_model_usage), do: %{}

  defp finite_count(value) when is_integer(value) and value >= 0, do: value
  defp finite_count(value) when is_float(value) and value >= 0.0, do: trunc(value)
  defp finite_count(_value), do: 0

  # `current - previous` per model, dropping models with nothing to report so a
  # turn only lists the models it actually ran on. A reading below the previous
  # one means the running total restarted (a resumed session, a cleared
  # context, a zeroed crash result): there is no usable reference left to
  # subtract, so the reading itself is the increment.
  defp model_usage_increment(current, previous) do
    current
    |> Enum.flat_map(fn {model, usage} ->
      resolved =
        case Map.get(previous, model) do
          nil ->
            usage

          base ->
            subtracted = Map.new(usage, fn {key, value} -> {key, value - (base[key] || 0)} end)

            if Enum.any?(subtracted, fn {_key, value} -> value < 0 end),
              do: usage,
              else: subtracted
        end

      if tally_total(resolved) > 0, do: [{model, resolved}], else: []
    end)
    |> Map.new()
  end

  defp add_model_usage(base, increment) do
    Map.merge(base, increment, fn _model, left, right ->
      Map.new(left, fn {key, value} -> {key, value + (right[key] || 0)} end)
    end)
  end

  defp tally_total(tally), do: tally |> Map.values() |> Enum.sum()

  defp usage_update(session_id, usage, result, state) do
    used =
      usage
      |> Map.values()
      |> Enum.filter(&is_integer/1)
      |> Enum.sum()

    size = context_window_size(result, state)

    if used > 0 and is_integer(size) and size > 0 do
      AdapterEvents.session_update_type(session_id, "usage_update", %{
        "used" => used,
        "size" => size
      })
    end
  end

  defp context_window_size(%{"modelUsage" => model_usage}, state) when is_map(model_usage) do
    current_model = state.model || "default"

    model_usage
    |> Enum.find_value(fn {model, usage} ->
      if String.starts_with?(to_string(model), to_string(current_model)) and is_map(usage) do
        usage["contextWindow"] || usage["context_window"]
      end
    end)
    |> case do
      nil ->
        model_usage
        |> Map.values()
        |> Enum.find_value(fn
          %{"contextWindow" => size} -> size
          %{"context_window" => size} -> size
          _ -> nil
        end)

      size ->
        size
    end
  end

  defp context_window_size(_result, state) do
    model = current_model_info(state)

    [state.model, model["displayName"], model["display_name"], model["description"]]
    |> Enum.any?(fn text -> is_binary(text) and String.match?(text, ~r/\b1m\b/i) end)
    |> if(do: 1_000_000, else: nil)
  end

  defp maybe_put_error_meta(response, %{"error" => error}) when error in @auth_errors do
    put_in(response, ["_meta", "ex_mcp", "claude_sdk", "authError"], error)
  end

  defp maybe_put_error_meta(response, %{"subtype" => subtype}) when is_binary(subtype) do
    put_in(response, ["_meta", "ex_mcp", "claude_sdk", "resultSubtype"], subtype)
  end

  defp maybe_put_error_meta(response, _result), do: response

  defp put_pending_client_request(state, acp_id, request_id, kind, request) do
    pending =
      PendingRequests.put(state.pending_client_requests, acp_id, %{
        request_id: request_id,
        kind: kind,
        request: request
      })

    %{state | pending_client_requests: pending}
  end

  defp pop_pending_client_request(state, acp_id) do
    {request, pending} = PendingRequests.pop(state.pending_client_requests, acp_id)
    {request, %{state | pending_client_requests: pending}}
  end

  defp cancel_pending_client_request(state, request_id) do
    pending =
      state.pending_client_requests
      |> Enum.reject(fn {_id, pending} -> pending.request_id == request_id end)
      |> Map.new()

    %{state | pending_client_requests: pending}
  end

  defp start_next_queued_prompt(state) do
    case PromptQueue.pop(state.prompt_queue) do
      {:value, queued, rest} ->
        state =
          %{
            state
            | pending_prompt_id: queued.id,
              active_prompt_session_id: queued.session_id || state.session_id,
              session_id: queued.session_id || state.session_id,
              prompt_queue: rest,
              text_acc: [],
              thinking_acc: [],
              thinking_blocks: [],
              current_block_type: nil,
              current_assistant_text_streamed?: false,
              tool_calls: %{},
              background_subagents: MapSet.new(),
              deferred_result: nil,
              turn_model_usage: %{}
          }

        {[ClaudeProtocol.line(queued.message)], state}

      :empty ->
        {[], state}
    end
  end

  defp session_id(%{session_id: nil}), do: "default"
  defp session_id(%{session_id: session_id}), do: session_id

  # The ACP-facing session id is the one `session/new` returned to the client
  # (`claude_sdk_<n>` unless the caller supplied one). Claude Code mints its own
  # UUID for the process and stamps every stream-json event with it; adopting
  # that UUID here re-labelled every `session/update` with an id the ACP client
  # never registered, so `ExMCP.ACP.Client` dropped all of them ("ignored an
  # update for an unknown session") and the turn came back empty (seen with
  # Claude Code 2.1.215, 2026-08-25). Keep the ACP id stable once set; remember
  # the CLI's id separately for provider metadata and correlation.
  defp maybe_set_session(%{session_id: nil} = state, %{"session_id" => session_id})
       when is_binary(session_id) and session_id != "" do
    %{state | session_id: session_id, claude_session_id: session_id}
  end

  defp maybe_set_session(state, %{"session_id" => session_id})
       when is_binary(session_id) and session_id != "" do
    %{state | claude_session_id: session_id}
  end

  defp maybe_set_session(state, _event), do: state

  defp permission_mode_to_mode("acceptEdits"), do: "acceptEdits"
  defp permission_mode_to_mode("plan"), do: "plan"
  defp permission_mode_to_mode("auto"), do: "auto"
  defp permission_mode_to_mode("dontAsk"), do: "dontAsk"
  defp permission_mode_to_mode("bypassPermissions"), do: "bypassPermissions"
  defp permission_mode_to_mode(_), do: "default"

  defp effective_mode(state) do
    current = permission_mode_to_mode(state.permission_mode || "default")

    cond do
      current == "auto" and auto_unavailable?(state) -> @auto_mode_fallback
      Enum.any?(modes(state), &(&1["id"] == current)) -> current
      true -> "default"
    end
  end

  defp auto_unavailable?(state) do
    case current_model_info(state) do
      model when map_size(model) > 0 ->
        not (model["supportsAutoMode"] == true or model["supports_auto_mode"] == true)

      _ ->
        false
    end
  end

  defp maybe_set(state, _key, nil), do: state
  defp maybe_set(state, key, value), do: Map.put(state, key, value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, [], %{}] end)
    |> Map.new()
  end
end
