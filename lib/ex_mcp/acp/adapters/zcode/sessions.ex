defmodule ExMCP.ACP.Adapters.ZCode.Sessions do
  @moduledoc false

  # Pure session helpers for the ZCode ACP adapter.
  #
  # ZCode sessions are keyed by the `sessionId` string returned by
  # `session/create` or `session/resume`. Each session tracks the active turn
  # (for cancellation), accumulated text/usage, and the current mode and model.

  alias ExMCP.ACP.Adapters.ZCode.Config
  alias ExMCP.Internal.Maps

  @type adapter_state :: %{
          required(:sessions) => %{String.t() => session()},
          required(:model) => any(),
          required(:mode_id) => any(),
          optional(any()) => any()
        }

  @type store_state :: %{
          required(:sessions) => %{String.t() => session()},
          optional(any()) => any()
        }
  @type session :: map()

  @spec empty(String.t() | nil, adapter_state()) :: session()
  def empty(session_id, state) do
    %{
      id: session_id,
      workspace: nil,
      mode_id: Map.get(state, :mode_id) || Config.default_mode(),
      model_ref: Map.get(state, :model),
      models: Map.get(state, :models) || [],
      thought_level: Map.get(state, :thought_level) || Config.default_thought_level(),
      turn_id: nil,
      active_prompt_acp_id: nil,
      accumulated_text: [],
      accumulated_usage: nil,
      subscribed: false,
      prompt_activity: false
    }
  end

  @doc """
  Builds a session from a ZCode snapshot (as returned by session/create,
  session/resume, or embedded in event notifications).
  """
  @spec from_snapshot(String.t(), map(), adapter_state()) :: session()
  def from_snapshot(session_id, snapshot, state) do
    session = snapshot["session"] || %{}
    projection = snapshot["projection"] || %{}

    empty(session_id, state)
    |> Map.merge(%{
      id: session_id,
      workspace: workspace_path(session["workspace"] || snapshot["workspace"]),
      mode_id:
        projection["mode"] || session["mode"] || Map.get(state, :mode_id) ||
          Config.default_mode(),
      model_ref: session["model"] || snapshot["model"] || Map.get(state, :model)
    })
    |> Config.apply_settings(snapshot["modelCatalog"] || snapshot["settings"] || %{})
  end

  @doc "Fetches a session ID from ACP params."
  @spec fetch_id(map()) :: {:ok, String.t()} | {:error, String.t()}
  def fetch_id(%{"sessionId" => session_id})
      when is_binary(session_id) and session_id != "",
      do: {:ok, session_id}

  def fetch_id(_params), do: {:error, "sessionId is required"}

  @doc "Fetches a session from state by ID."
  @spec fetch(store_state(), String.t()) :: {:ok, session()} | {:error, String.t()}
  def fetch(state, session_id) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, session} -> {:ok, session}
      :error -> {:error, "Unknown ZCode session: #{session_id}"}
    end
  end

  @spec put(store_state(), String.t() | nil, session()) :: store_state()
  def put(state, nil, _session), do: state
  def put(state, "", _session), do: state

  def put(state, session_id, session),
    do: %{state | sessions: Map.put(state.sessions, session_id, session)}

  @spec update(adapter_state(), String.t() | nil, (session() -> session())) :: adapter_state()
  def update(state, nil, _fun), do: state
  def update(state, "", _fun), do: state

  def update(state, session_id, fun) do
    session = Map.get(state.sessions, session_id, empty(session_id, state))
    put(state, session_id, fun.(session))
  end

  @doc "Returns the current (only) session ID, or nil."
  @spec current_id(store_state()) :: String.t() | nil
  def current_id(%{sessions: sessions}) when map_size(sessions) == 1 do
    sessions |> Map.keys() |> hd()
  end

  def current_id(_state), do: nil

  @doc "Resolves a session ID from notification params."
  @spec id_from_params(map(), store_state()) :: String.t() | nil
  def id_from_params(params, state) do
    params["sessionId"] || params["session_id"] ||
      get_in(params, ["session", "sessionId"]) ||
      get_in(params, ["projection", "sessionId"]) ||
      current_id(state)
  end

  @doc "Resets per-prompt accumulators on a session."
  @spec reset_prompt_accumulators(session(), term()) :: session()
  def reset_prompt_accumulators(session, acp_id) do
    session
    |> Map.put(:active_prompt_acp_id, acp_id)
    |> Map.put(:accumulated_text, [])
    |> Map.put(:accumulated_usage, nil)
    |> Map.put(:prompt_activity, false)
  end

  @doc "Converts a ZCode session list entry to an ACP SessionInfo map."
  @spec to_acp_session_info(map()) :: map()
  def to_acp_session_info(session) do
    session_id = session["sessionId"] || session["session_id"]
    cwd = workspace_path(session["workspace"] || session["cwd"]) || ""

    %{
      "sessionId" => session_id,
      "cwd" => cwd
    }
    |> Maps.put_present("title", session["title"])
    |> Maps.put_present("updatedAt", session["updatedAt"])
    |> Maps.put_present("_meta", session_meta(session))
  end

  defp session_meta(session) do
    meta =
      %{
        "zcode" => %{
          "status" => session["status"],
          "mode" => session["mode"],
          "parentSessionId" => session["parentSessionId"] || session["parent_session_id"],
          "archivedAt" => session["archivedAt"] || session["archived_at"]
        }
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    if meta == %{}, do: nil, else: %{"ex_mcp" => meta}
  end

  defp workspace_path(path) when is_binary(path), do: path
  defp workspace_path(%{"workspacePath" => path}) when is_binary(path), do: path
  defp workspace_path(_workspace), do: nil
end
