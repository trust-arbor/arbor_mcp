defmodule ExMCP.ACP.Adapters.ZCode do
  @moduledoc """
  ACP adapter for ZCode using `zcode app-server` persistent mode.

  Translates between ACP JSON-RPC and ZCode's `app-server` NDJSON protocol
  (ZCode Protocol v1). The adapter keeps ZCode app-server as the subprocess
  boundary and owns the pure protocol mapping needed to present a stable ACP
  surface.

  Session-supplied workspace paths and MCP servers are treated as untrusted.
  `:workspace_roots` defaults to the adapter working directory. Deployments
  may provide `:authorize_workspace` and `:authorize_mcp_server` callbacks.
  `:trusted_mcp_servers` accepts exact server maps; `:all` is an explicit
  unsafe compatibility escape hatch. Names alone never authorize
  caller-controlled connection details.
  """

  @behaviour ExMCP.ACP.Adapter

  @impl true
  def name, do: "zcode"

  require Logger

  alias ExMCP.ACP.Adapters.ZCode.{Config, Mapper, Protocol, Sessions}
  alias ExMCP.ACP.{AdapterEvents, Envelope, PendingRequests, PromptQueue}
  alias ExMCP.Internal.Maps

  defstruct [
    :model,
    :mode_id,
    :thought_level,
    :cwd,
    models: [],
    next_id: 1,
    phase: :initializing,
    pending_requests: %{},
    pending_client_requests: %{},
    sessions: %{},
    prompt_queue: PromptQueue.new(),
    opts: []
  ]

  @impl true
  def init(opts) do
    cwd = Keyword.get(opts, :cwd) || File.cwd!()

    {:ok,
     %__MODULE__{
       opts: opts,
       model: Keyword.get(opts, :model),
       mode_id: Config.normalize_mode_id(Keyword.get(opts, :mode_id, Config.default_mode())),
       thought_level: Keyword.get(opts, :thought_level, Config.default_thought_level()),
       cwd: cwd
     }}
  end

  @impl true
  def command(opts), do: Protocol.command(opts)

  @impl true
  def env(opts), do: Protocol.env(opts)

  @impl true
  def post_connect(state) do
    {id, state} = next_request_id(state)

    request =
      Protocol.encode_request(id, "workspace/readState", %{
        "workspace" => Protocol.workspace_ref(state.cwd)
      })

    state = track_request(state, id, :workspace_read_state, nil)
    {:ok, Protocol.line(request), state}
  end

  @impl true
  def capabilities do
    %{
      "loadSession" => true,
      "promptCapabilities" => %{"image" => false, "embeddedContext" => false},
      "mcpCapabilities" => %{
        "acp" => false,
        "http" => true,
        "sse" => true,
        "_meta" => %{"ex_mcp" => %{"zcode" => %{"stdioMcpServers" => true}}}
      },
      "sessionCapabilities" => %{
        "list" => %{},
        "resume" => %{},
        "close" => %{},
        "setModel" => %{},
        "fork" => %{}
      },
      "_meta" => %{
        "ex_mcp" => %{
          "zcode" => %{
            "streaming" => true,
            "serverRequests" => true
          }
        }
      }
    }
  end

  @impl true
  def auth_methods(opts) do
    cli_path = Protocol.cli_path(opts)

    [
      %{
        "id" => "zcode-login",
        "name" => "Log in with ZCode",
        "description" => "Run `zcode login` in the terminal",
        "type" => "terminal",
        "args" => ["login"],
        "_meta" => %{
          "terminal-auth" => %{
            "command" => cli_path,
            "args" => ["login"],
            "label" => "ZCode Login"
          }
        }
      }
    ]
  end

  @impl true
  def modes, do: Config.modes()

  @impl true
  def config_options do
    Config.config_options(%{models: [], mode_id: Config.default_mode()})
  end

  # -------------------------------------------------------------------------
  # Outbound: ACP → ZCode
  # -------------------------------------------------------------------------

  @impl true
  def translate_outbound(%{"method" => "initialize"}, state), do: {:ok, :skip, state}

  def translate_outbound(%{"method" => "authenticate"}, state), do: {:reply, %{}, state}

  def translate_outbound(%{"method" => "session/new", "id" => acp_id, "params" => params}, state) do
    cwd = params["cwd"] || state.cwd || Keyword.get(state.opts, :cwd)

    with :ok <- authorize_workspace(cwd, :session_new, state),
         :ok <- reject_additional_directories(params),
         {:ok, mcp_servers} <- authorize_mcp_servers(params["mcpServers"], state) do
      mode_id = Config.normalize_mode_id(params["modeId"] || params["mode"] || state.mode_id)

      wire_params =
        %{}
        |> Maps.put_present("workspace", Protocol.workspace_ref(cwd))
        |> Maps.put_present("mode", mode_id)
        |> Maps.put_present("mcpServers", mcp_servers)
        |> Maps.put_present("model", model_ref(params["model"] || state.model))

      {id, state} = next_request_id(state)
      request = Protocol.encode_request(id, "session/create", wire_params)
      state = track_request(state, id, :session_create, acp_id)

      {:ok, Protocol.line(request), state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def translate_outbound(%{"method" => "session/load", "id" => acp_id, "params" => params}, state) do
    case Sessions.fetch_id(params) do
      {:ok, session_id} ->
        cwd = params["cwd"] || state.cwd || Keyword.get(state.opts, :cwd)

        with :ok <- authorize_workspace(cwd, :session_load, state),
             :ok <- reject_additional_directories(params) do
          send_session_resume(acp_id, session_id, cwd, true, params, state)
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  def translate_outbound(
        %{"method" => "session/resume", "id" => acp_id, "params" => params},
        state
      ) do
    case Sessions.fetch_id(params) do
      {:ok, session_id} ->
        cwd = params["cwd"] || state.cwd || Keyword.get(state.opts, :cwd)

        with :ok <- authorize_workspace(cwd, :session_resume, state),
             :ok <- reject_additional_directories(params) do
          send_session_resume(acp_id, session_id, cwd, false, params, state)
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  def translate_outbound(
        %{"method" => "session/prompt", "id" => acp_id, "params" => params},
        state
      ) do
    with {:ok, session_id} <- Sessions.fetch_id(params),
         {:ok, session} <- Sessions.fetch(state, session_id),
         {:ok, content} <- Protocol.prompt_content(params["prompt"]),
         {:ok, wire_params} <- prompt_wire_params(session_id, content, params, session) do
      if session.active_prompt_acp_id do
        enqueue_prompt(state, acp_id, session_id, wire_params)
      else
        start_prompt(acp_id, session_id, wire_params, state)
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def translate_outbound(%{"method" => "session/cancel", "params" => params}, state) do
    session_id = params["sessionId"] || Sessions.current_id(state)

    {cancelled_messages, state} = cancel_queued_prompts(state, session_id)

    {id, state} = next_request_id(state)
    request = Protocol.encode_request(id, "session/stop", %{"sessionId" => session_id})
    state = track_request(state, id, :session_stop, nil)

    if cancelled_messages == [] do
      {:ok, Protocol.line(request), state}
    else
      {:messages_and_write, cancelled_messages, Protocol.line(request), state}
    end
  end

  def translate_outbound(%{"method" => "session/list", "id" => acp_id, "params" => params}, state) do
    cwd = params["cwd"] || state.cwd || Keyword.get(state.opts, :cwd)

    with :ok <- authorize_optional_workspace(cwd, :session_list, state) do
      wire_params =
        %{}
        |> Maps.put_present("workspace", workspace_ref(cwd))
        |> Maps.put_present("cursor", params["cursor"])
        |> Maps.put_present("limit", params["limit"])

      {id, state} = next_request_id(state)
      request = Protocol.encode_request(id, "session/list", wire_params)
      state = track_request(state, id, :session_list, acp_id)
      {:ok, Protocol.line(request), state}
    end
  end

  def translate_outbound(%{"method" => "session/close", "params" => params}, state) do
    case Sessions.fetch_id(params) do
      {:ok, session_id} ->
        {id, state} = next_request_id(state)
        request = Protocol.encode_request(id, "session/close", %{"sessionId" => session_id})
        state = track_request(state, id, :session_close, nil)
        state = %{state | sessions: Map.delete(state.sessions, session_id)}
        {:reply_and_write, %{}, Protocol.line(request), state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  def translate_outbound(%{"method" => "session/fork", "id" => acp_id, "params" => params}, state) do
    with :ok <- reject_additional_directories(params),
         {:ok, session_id} <- Sessions.fetch_id(params) do
      wire_params =
        %{"sessionId" => session_id}
        |> Maps.put_present("target", %{"kind" => params["targetKind"] || "latestCheckpoint"})

      {id, state} = next_request_id(state)
      request = Protocol.encode_request(id, "session/fork", wire_params)
      state = track_request(state, id, :session_fork, acp_id)
      {:ok, Protocol.line(request), state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def translate_outbound(%{"method" => "session/set_mode", "params" => params} = msg, state),
    do: set_mode(params, msg["id"], :empty, state)

  def translate_outbound(%{"method" => "session/set_model", "params" => params} = msg, state),
    do: set_model(params, msg["id"], :empty, state)

  def translate_outbound(
        %{"method" => "session/set_config_option", "params" => params} = msg,
        state
      ) do
    translate_config_option(params, msg["id"], state)
  end

  # Client response to a permission request we forwarded
  def translate_outbound(%{"id" => acp_id, "result" => result}, state) do
    case PendingRequests.pop(state.pending_client_requests, acp_id) do
      {nil, _pending} ->
        {:ok, :skip, state}

      {%{zcode_id: zcode_id, request: request, kind: :permission}, pending} ->
        options = request["options"] || []
        outcome = normalize_permission_outcome(result)
        response = Protocol.permission_result(outcome, options)
        zcode_response = Protocol.encode_response(zcode_id, response)
        {:ok, Protocol.line(zcode_response), %{state | pending_client_requests: pending}}
    end
  end

  def translate_outbound(%{"id" => acp_id, "error" => _error}, state) do
    case PendingRequests.pop(state.pending_client_requests, acp_id) do
      {nil, _pending} ->
        {:ok, :skip, state}

      {%{zcode_id: zcode_id}, pending} ->
        zcode_response =
          Protocol.encode_response(zcode_id, %{"decision" => "deny", "reason" => "Rejected"})

        {:ok, Protocol.line(zcode_response), %{state | pending_client_requests: pending}}
    end
  end

  def translate_outbound(
        %{"method" => "$/cancel_request", "params" => %{"requestId" => id}},
        state
      ),
      do: {:ok, :skip, retire_setting_request(state, id)}

  def translate_outbound(_msg, state), do: {:ok, :skip, state}

  @impl true
  def outbound_write_failed(message, _reason, state),
    do: retire_setting_request(state, message["id"])

  defp retire_setting_request(state, acp_id) do
    pending =
      Map.reject(state.pending_requests, fn {_id, entry} ->
        entry.acp_id == acp_id and
          entry.type in [:session_set_mode, :session_set_model, :session_set_thought_level]
      end)

    %{state | pending_requests: pending}
  end

  # -------------------------------------------------------------------------
  # Inbound: ZCode → ACP
  # -------------------------------------------------------------------------

  @impl true
  def translate_inbound(line, state) do
    trimmed = String.trim(line)

    with false <- trimmed == "",
         {:ok, msg} <- Jason.decode(trimmed) do
      {messages, writes, state} = Mapper.reduce_message(msg, state)
      return_inbound(messages, writes, state)
    else
      true ->
        {:skip, state}

      {:error, _reason} ->
        Logger.debug("[ZCode Adapter] Non-JSON line: #{String.slice(trimmed, 0, 120)}")
        {:skip, state}
    end
  end

  defp return_inbound([], [], state), do: {:skip, state}
  defp return_inbound([], [write], state), do: {:skip_and_write, write, state}
  defp return_inbound([], writes, state), do: {:skip_and_write, writes, state}
  defp return_inbound(messages, [], state), do: {:messages, messages, state}
  defp return_inbound(messages, writes, state), do: {:messages_and_write, messages, writes, state}

  # -------------------------------------------------------------------------
  # Private: session resume helper
  # -------------------------------------------------------------------------

  defp send_session_resume(acp_id, session_id, cwd, replay?, params, state) do
    case authorize_mcp_servers(params["mcpServers"], state) do
      {:ok, mcp_servers} ->
        wire_params =
          %{"sessionId" => session_id}
          |> Maps.put_present("workspace", Protocol.workspace_ref(cwd))
          |> Maps.put_present("mcpServers", mcp_servers)

        {id, state} = next_request_id(state)
        request = Protocol.encode_request(id, "session/resume", wire_params)

        state =
          state
          |> track_request(id, :session_resume, acp_id, %{
            session_id: session_id,
            replay?: replay?
          })

        # Also subscribe to events
        {sub_id, state} = next_request_id(state)

        subscribe_request =
          Protocol.encode_request(sub_id, "session/subscribe", %{
            "sessionId" => session_id,
            "deliveryKind" => "desktop-continuous",
            "includeSnapshot" => replay?
          })

        state =
          state
          |> track_request(sub_id, :session_subscribe, nil, %{session_id: session_id})

        {:ok, Protocol.line(request) <> Protocol.line(subscribe_request), state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # -------------------------------------------------------------------------
  # Private: prompt lifecycle
  # -------------------------------------------------------------------------

  defp start_prompt(acp_id, session_id, wire_params, state) do
    {id, state} = next_request_id(state)
    request = Protocol.encode_request(id, "session/send", wire_params)

    state =
      state
      |> track_request(id, :session_send, acp_id, %{session_id: session_id})
      |> Sessions.update(session_id, &Sessions.reset_prompt_accumulators(&1, acp_id))

    {:ok, Protocol.line(request), state}
  end

  defp enqueue_prompt(state, acp_id, session_id, wire_params) do
    queued = %{
      acp_id: acp_id,
      session_id: session_id,
      wire_params: wire_params
    }

    queue = PromptQueue.enqueue(state.prompt_queue, queued)
    queue_depth = PromptQueue.len(queue)

    notice =
      AdapterEvents.agent_message_chunk(session_id, "Queued message (position #{queue_depth}).")

    info =
      AdapterEvents.session_info_update(session_id, %{
        "_meta" => %{"ex_mcp" => %{"zcode" => %{"queueDepth" => queue_depth, "running" => true}}}
      })

    {:messages, [notice, info], %{state | prompt_queue: queue}}
  end

  defp prompt_wire_params(session_id, content, params, session) do
    # The native session owns its selected model; an initial adapter default must
    # not override a later successful per-session model change on every prompt.
    with {:ok, selection} <- prompt_model_selection(params["model"], session) do
      {:ok,
       %{"sessionId" => session_id, "content" => content}
       |> Maps.put_present("modelSelection", selection)}
    end
  end

  defp cancel_queued_prompts(state, nil), do: {[], state}

  defp cancel_queued_prompts(state, session_id) do
    {cancelled, remaining} = PromptQueue.split(state.prompt_queue, &(&1.session_id == session_id))

    messages =
      Enum.map(cancelled, fn %{acp_id: acp_id} ->
        Envelope.response(acp_id, %{"stopReason" => "cancelled"})
      end)

    {messages, %{state | prompt_queue: remaining}}
  end

  # -------------------------------------------------------------------------
  # Private: config option translation
  # -------------------------------------------------------------------------

  defp translate_config_option(%{"configId" => "mode", "value" => value} = params, acp_id, state),
    do: set_mode(Map.put(params, "modeId", value), acp_id, :config, state)

  defp translate_config_option(
         %{"configId" => "model", "value" => value} = params,
         acp_id,
         state
       ),
       do: set_model(Map.put(params, "modelId", value), acp_id, :config, state)

  defp translate_config_option(
         %{"configId" => "thought_level", "value" => value} = params,
         acp_id,
         state
       ) do
    with {:ok, session_id} <- Sessions.fetch_id(params),
         {:ok, session} <- Sessions.fetch(state, session_id),
         true <- Config.valid_thought_level?(session, value) do
      queue_setting_request(
        "session/setThoughtLevel",
        %{"sessionId" => session_id, "thoughtLevel" => value},
        :session_set_thought_level,
        %{"thoughtLevel" => %{"current" => value}},
        acp_id,
        :config,
        state
      )
    else
      false -> {:error, "Unsupported ZCode thought level: #{inspect(value)}", state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp translate_config_option(params, _acp_id, state),
    do: {:error, "Unknown ZCode config option: #{params["configId"]}", state}

  defp set_mode(params, acp_id, reply_type, state) do
    with {:ok, session_id} <- Sessions.fetch_id(params),
         {:ok, _session} <- Sessions.fetch(state, session_id),
         {:ok, mode_id} <- Config.normalize_requested_mode(params["modeId"]) do
      queue_setting_request(
        "session/setMode",
        %{"sessionId" => session_id, "mode" => mode_id},
        :session_set_mode,
        %{"mode" => %{"current" => mode_id}},
        acp_id,
        reply_type,
        state
      )
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp set_model(params, acp_id, reply_type, state) do
    with {:ok, session_id} <- Sessions.fetch_id(params),
         {:ok, session} <- Sessions.fetch(state, session_id),
         {:ok, model_ref} <- resolve_model_ref(params["modelId"], session) do
      model_ref = Config.with_reasoning_level(model_ref, session)

      queue_setting_request(
        "session/setModel",
        %{"sessionId" => session_id, "model" => model_ref},
        :session_set_model,
        %{"model" => %{"current" => model_ref}},
        acp_id,
        reply_type,
        state
      )
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp queue_setting_request(method, params, type, settings, acp_id, reply_type, state) do
    {id, state} = next_request_id(state)
    request = Protocol.encode_request(id, method, params)

    state =
      track_request(state, id, type, acp_id, %{
        session_id: params["sessionId"],
        requested_settings: settings,
        reply_type: reply_type
      })

    {:pending_and_write, Protocol.line(request), state}
  end

  # -------------------------------------------------------------------------
  # Private: workspace / MCP authorization
  # -------------------------------------------------------------------------

  defp authorize_workspace(nil, _context, state),
    do: authorize_workspace(state.cwd || Keyword.get(state.opts, :cwd), :session_new, state)

  defp authorize_workspace(cwd, context, state) do
    if is_binary(cwd) and cwd != "" and Path.type(cwd) == :absolute do
      result =
        case Keyword.get(state.opts, :authorize_workspace) do
          callback when is_function(callback, 3) ->
            safe_authorize(callback, [cwd, context, state.opts])

          callback when is_function(callback, 2) ->
            safe_authorize(callback, [cwd, context])

          callback when is_function(callback, 1) ->
            safe_authorize(callback, [cwd])

          nil ->
            within_workspace_roots?(cwd, state)

          _invalid ->
            false
        end

      authorization_result(result, "Workspace path is not authorized")
    else
      {:error, "Workspace paths must be absolute"}
    end
  end

  defp authorize_optional_workspace(cwd, _context, _state) when is_nil(cwd), do: :ok

  defp authorize_optional_workspace(cwd, context, state),
    do: authorize_workspace(cwd, context, state)

  defp reject_additional_directories(params) do
    case params["additionalDirectories"] do
      nil -> :ok
      [] -> :ok
      _directories -> {:error, "ZCode does not support additionalDirectories"}
    end
  end

  defp workspace_ref(nil), do: nil
  defp workspace_ref(cwd), do: Protocol.workspace_ref(cwd)

  defp within_workspace_roots?(path, state) do
    roots =
      case Keyword.get(state.opts, :workspace_roots) do
        roots when is_list(roots) -> roots
        nil -> [state.cwd]
        root -> [root]
      end

    path = canonical_path(path)

    Enum.any?(roots, fn
      root when is_binary(root) and root != "" ->
        Path.type(root) == :absolute and path_within?(path, canonical_path(root))

      _invalid ->
        false
    end)
  end

  defp path_within?(path, root) do
    relative = Path.relative_to(path, root)

    relative == "." or
      (Path.type(relative) == :relative and relative != ".." and
         not String.starts_with?(relative, "../"))
  end

  defp canonical_path(path), do: resolve_path_components(Path.expand(path), 0)

  defp resolve_path_components(path, depth) when depth >= 40, do: path

  defp resolve_path_components(path, depth) do
    case Path.split(path) do
      [base | components] ->
        Enum.reduce(components, base, &resolve_path_component(&1, &2, depth))

      [] ->
        path
    end
  end

  defp resolve_path_component(component, resolved_parent, depth) do
    candidate = Path.join(resolved_parent, component)

    case :file.read_link(to_charlist(candidate)) do
      {:ok, target} -> resolve_link_target(to_string(target), candidate, depth)
      {:error, _reason} -> candidate
    end
  end

  defp resolve_link_target(target, candidate, depth) do
    target =
      if Path.type(target) == :absolute,
        do: target,
        else: Path.join(Path.dirname(candidate), target)

    target
    |> Path.expand()
    |> resolve_path_components(depth + 1)
  end

  defp authorize_mcp_servers(nil, _state), do: {:ok, nil}
  defp authorize_mcp_servers([], _state), do: {:ok, nil}

  defp authorize_mcp_servers(servers, state) when is_list(servers) do
    trusted = Keyword.get(state.opts, :trusted_mcp_servers, [])

    if trusted == :all do
      {:ok, servers}
    else
      Enum.reduce_while(servers, {:ok, []}, fn server, {:ok, acc} ->
        case authorize_mcp_server(server, trusted, state) do
          :ok -> {:cont, {:ok, [server | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, authorized} -> {:ok, Enum.reverse(authorized)}
        error -> error
      end
    end
  end

  defp authorize_mcp_servers(_servers, _state), do: {:error, "mcpServers must be a list"}

  defp authorize_mcp_server(server, trusted, state) do
    cond do
      trusted == :all ->
        :ok

      server in trusted ->
        :ok

      true ->
        case Keyword.get(state.opts, :authorize_mcp_server) do
          nil ->
            {:error, "MCP server is not authorized"}

          callback when is_function(callback, 2) ->
            callback
            |> safe_authorize([server, state.opts])
            |> authorization_result("MCP server is not authorized")

          callback when is_function(callback, 1) ->
            callback
            |> safe_authorize([server])
            |> authorization_result("MCP server is not authorized")

          _invalid ->
            {:error, "Invalid MCP server authorization callback"}
        end
    end
  end

  defp safe_authorize(callback, arguments) do
    apply(callback, arguments)
  rescue
    exception ->
      Logger.warning("ZCode authorization callback failed", error_class: exception.__struct__)
      false
  catch
    _kind, _reason -> false
  end

  defp authorization_result(result, _message) when result in [:ok, true], do: :ok
  defp authorization_result({:ok, _value}, _message), do: :ok
  defp authorization_result(_result, message), do: {:error, message}

  # -------------------------------------------------------------------------
  # Private: model ref helpers
  # -------------------------------------------------------------------------

  defp prompt_model_selection(nil, _session), do: {:ok, nil}

  defp prompt_model_selection(model_id, session) when is_binary(model_id) do
    with {:ok, ref} <- resolve_model_ref(model_id, session) do
      prompt_model_selection(ref, session)
    end
  end

  defp prompt_model_selection(%{"providerId" => provider, "modelId" => model} = ref, session)
       when is_binary(provider) and is_binary(model) do
    provider = String.trim(provider)
    model = String.trim(model)

    with true <-
           provider != "" and model != "" and
             Map.keys(ref) -- ["providerId", "modelId", "options"] == [],
         {:ok, options} <- prompt_model_options(Map.get(ref, "options", %{})) do
      ref = %{"providerId" => provider, "modelId" => model}
      ref = if options == %{}, do: ref, else: Map.put(ref, "options", options)

      with :ok <- Config.validate_model_reasoning(ref, session) do
        {:ok, Config.with_reasoning_level(ref, session)}
      end
    else
      _ -> {:error, "Invalid ZCode prompt model selection"}
    end
  end

  defp prompt_model_selection(_value, _session),
    do: {:error, "Invalid ZCode prompt model selection"}

  defp prompt_model_options(options) when options == %{}, do: {:ok, %{}}

  defp prompt_model_options(%{"reasoningLevel" => level} = options)
       when map_size(options) == 1 and is_binary(level) do
    case String.trim(level) do
      "" -> {:error, :empty_reasoning_level}
      level -> {:ok, %{"reasoningLevel" => level}}
    end
  end

  defp prompt_model_options(_options), do: {:error, :invalid_model_options}

  defp model_ref(nil), do: nil

  defp model_ref(%{"providerId" => _, "modelId" => _} = ref), do: ref

  defp model_ref(model_id) when is_binary(model_id) do
    resolve_model_ref(model_id, %{models: []})
    |> case do
      {:ok, ref} -> ref
      _ -> nil
    end
  end

  defp resolve_model_ref(model_id, state) when is_binary(model_id) do
    case find_model_in_catalog(model_id, Map.get(state, :models) || []) do
      {:ok, ref} ->
        {:ok, ref}

      :error ->
        case String.split(model_id, "/", parts: 2) do
          [provider, model] when provider != "" and model != "" ->
            {:ok, %{"providerId" => provider, "modelId" => model}}

          _ ->
            {:error, "Unknown modelId: #{model_id}"}
        end
    end
  end

  defp resolve_model_ref(nil, _state), do: {:error, "modelId is required"}
  defp resolve_model_ref(_other, _state), do: {:error, "Invalid modelId"}

  defp find_model_in_catalog(model_id, models) when is_list(models) do
    Enum.find_value(models, :error, fn model ->
      ref = model["ref"] || model

      advertised_id =
        case ref do
          %{"providerId" => p, "modelId" => m} -> "#{p}/#{m}"
          _ -> nil
        end

      cond do
        advertised_id == model_id ->
          {:ok, ref}

        is_binary(advertised_id) and List.last(String.split(advertised_id, "/")) == model_id ->
          {:ok, ref}

        true ->
          false
      end
    end)
  end

  defp find_model_in_catalog(_model_id, _models), do: :error

  # -------------------------------------------------------------------------
  # Private: ID and request tracking
  # -------------------------------------------------------------------------

  defp next_request_id(%{next_id: id} = state),
    do: {id, %{state | next_id: id + 1}}

  defp track_request(state, id, type, acp_id, meta \\ %{}) do
    entry = %{type: type, acp_id: acp_id, meta: meta}

    %{state | pending_requests: PendingRequests.put(state.pending_requests, id, entry)}
  end

  defp normalize_permission_outcome(%{"outcome" => outcome} = _result) when is_map(outcome),
    do: outcome

  defp normalize_permission_outcome(%{"outcome" => _} = result), do: result
  defp normalize_permission_outcome(result), do: result
end
