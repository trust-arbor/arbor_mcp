defmodule ExMCP.ACP.Adapters.ZCode.Config do
  @moduledoc false

  # Pure config and mode helpers for the ZCode ACP adapter.
  #
  # ZCode has five operational modes (plan, build, edit, auto, yolo) that
  # correspond to ACP `SessionMode` IDs. Config options expose model selection
  # and thought-level (reasoning effort) control.

  @default_mode "build"

  @modes %{
    "plan" => %{
      "id" => "plan",
      "name" => "Plan",
      "description" => "Planning mode — no tool execution, analysis only."
    },
    "build" => %{
      "id" => "build",
      "name" => "Build",
      "description" => "Standard mode — full tool access with permission prompts."
    },
    "edit" => %{
      "id" => "edit",
      "name" => "Edit",
      "description" => "Auto-accept file edit operations."
    },
    "auto" => %{
      "id" => "auto",
      "name" => "Auto",
      "description" => "Use a model classifier to auto-approve permission prompts."
    },
    "yolo" => %{
      "id" => "yolo",
      "name" => "Yolo",
      "description" => "No permission prompts — all operations allowed without asking."
    }
  }

  @default_thought_level "medium"

  @thought_levels [
    %{"value" => "off", "label" => "Off"},
    %{"value" => "minimal", "label" => "Minimal"},
    %{"value" => "low", "label" => "Low"},
    %{"value" => "medium", "label" => "Medium"},
    %{"value" => "high", "label" => "High"}
  ]

  @spec default_mode() :: String.t()
  def default_mode, do: @default_mode

  @spec default_thought_level() :: String.t()
  def default_thought_level, do: @default_thought_level

  @mode_order ["plan", "build", "edit", "auto", "yolo"]

  @doc "Returns the static mode list for ZCode in canonical order."
  @spec modes() :: [map()]
  def modes, do: Enum.map(@mode_order, &Map.fetch!(@modes, &1))

  @doc "Normalizes a requested mode ID, returning an error for unknown modes."
  @spec normalize_requested_mode(any()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_requested_mode(mode_id) do
    normalized = normalize_mode_id(mode_id)

    if Map.has_key?(@modes, normalized) do
      {:ok, normalized}
    else
      {:error, "Unsupported ZCode mode: #{inspect(mode_id)}"}
    end
  end

  @doc "Normalizes a mode ID to a string, defaulting to the built-in default."
  @spec normalize_mode_id(any()) :: String.t()
  def normalize_mode_id(nil), do: @default_mode
  def normalize_mode_id(mode_id) when is_binary(mode_id), do: mode_id
  def normalize_mode_id(mode_id), do: to_string(mode_id)

  @doc "Builds the dynamic ACP config options from adapter state."
  @spec config_options(map()) :: [map()]
  def config_options(state) do
    [mode_option(state), model_option(state), thought_level_option(state)]
    |> Enum.reject(&is_nil/1)
  end

  @doc "Applies full snapshot settings or a current-model-only settings patch to one session."
  @spec apply_settings(map(), map(), :full | :partial) :: map()
  def apply_settings(session, settings, kind \\ :full) do
    model = if is_map(settings["model"]), do: settings["model"], else: settings

    session = update_model_catalog(session, model, kind)

    session =
      if Map.has_key?(model, "current"),
        do: put_current_model(session, model["current"]),
        else: session

    session =
      case settings["mode"] do
        %{"current" => mode} -> Map.put(session, :mode_id, mode)
        mode when is_binary(mode) -> Map.put(session, :mode_id, mode)
        _ -> session
      end

    case settings["thoughtLevel"] do
      thought when is_map(thought) ->
        session
        |> put_setting(thought, "available", :thought_levels)
        |> put_setting(thought, "current", :thought_level)
        |> put_setting(thought, "defaultLevel", :default_thought_level)
        |> put_setting(thought, "enabled", :thought_level_enabled)

      _ ->
        session
    end
  end

  defp update_model_catalog(session, model, kind) do
    case model["available"] || model["models"] do
      models when is_list(models) ->
        models = normalize_model_catalog(%{"available" => models})
        previous = Map.get(session, :models) || []
        models = if kind == :full, do: models, else: merge_models(previous, models)
        Map.put(session, :models, models)

      _ ->
        session
    end
  end

  @doc "Normalizes the legacy catalog and current snapshot model catalog."
  @spec normalize_model_catalog(map()) :: [map()]
  def normalize_model_catalog(catalog) when is_map(catalog) do
    catalog = if is_map(catalog["model"]), do: catalog["model"], else: catalog

    case catalog["available"] || catalog["models"] do
      models when is_list(models) ->
        Enum.flat_map(models, fn
          model when is_map(model) ->
            case model["ref"] || model do
              %{"providerId" => provider, "modelId" => id} = ref
              when is_binary(provider) and is_binary(id) ->
                ref = Map.take(ref, ["providerId", "modelId", "options"])
                [model |> Map.put("ref", ref) |> Map.put_new("label", model["name"] || id)]

              _ ->
                []
            end

          _ ->
            []
        end)

      _ ->
        []
    end
  end

  def normalize_model_catalog(_), do: []

  @doc "Adds a supported reasoning level when the selected model requires one."
  @spec with_reasoning_level(map(), map()) :: map()
  def with_reasoning_level(ref, session) do
    model =
      Enum.find(
        Map.get(session, :models) || [],
        &(Map.drop(&1["ref"], ["options"]) == Map.drop(ref, ["options"]))
      )

    reasoning = if model, do: model["reasoning"] || %{}, else: %{}
    levels = Enum.map(reasoning["levels"] || [], & &1["value"])

    if levels == [] do
      ref
    else
      current = Map.get(session, :thought_level)
      default = reasoning["defaultLevel"]
      explicit = get_in(ref, ["options", "reasoningLevel"])
      level = Enum.find([explicit, current, default | levels], &(&1 in levels))
      Map.put(ref, "options", %{"reasoningLevel" => level})
    end
  end

  @doc "Rejects an explicit model reasoning choice outside its known catalog."
  @spec validate_model_reasoning(map(), map()) :: :ok | {:error, String.t()}
  def validate_model_reasoning(ref, session) do
    model =
      Enum.find(
        Map.get(session, :models) || [],
        &(Map.drop(&1["ref"], ["options"]) == Map.drop(ref, ["options"]))
      )

    level = get_in(ref, ["options", "reasoningLevel"])

    case model do
      %{"reasoning" => %{"levels" => levels}} when is_list(levels) and not is_nil(level) ->
        if Enum.any?(levels, &(&1["value"] == level)),
          do: :ok,
          else: {:error, "Unsupported ZCode model reasoning level: #{inspect(level)}"}

      _ ->
        :ok
    end
  end

  @doc "Checks a reasoning choice against the selected session's advertised levels."
  @spec valid_thought_level?(map(), term()) :: boolean()
  def valid_thought_level?(session, value) do
    levels = Map.get(session, :thought_levels) || reasoning_levels(session)

    Map.get(session, :thought_level_enabled) != false and Map.get(session, :thought_levels) != [] and
      is_binary(value) and value != "" and
      (levels == [] or Enum.any?(levels, &((&1["value"] || &1[:value]) == value)))
  end

  defp put_current_model(session, ref) do
    session = Map.put(session, :model_ref, ref)

    case current_model_entry(session) do
      %{"reasoning" => %{"levels" => levels} = reasoning} when is_list(levels) ->
        values = Enum.map(levels, & &1["value"])
        selected = if is_map(ref), do: get_in(ref, ["options", "reasoningLevel"])
        candidates = [selected, session[:thought_level], reasoning["defaultLevel"] | values]

        session
        |> Map.put(:thought_levels, levels)
        |> Map.put(:thought_level_enabled, levels != [])
        |> Map.put(:default_thought_level, reasoning["defaultLevel"])
        |> Map.put(:thought_level, Enum.find(candidates, &(&1 in values)))

      _ ->
        session
    end
  end

  defp put_setting(session, source, key, field) do
    if Map.has_key?(source, key), do: Map.put(session, field, source[key]), else: session
  end

  defp merge_models(previous, models) do
    Enum.reduce(models, previous, fn model, merged ->
      case Enum.find_index(merged, &(model_key(&1) == model_key(model))) do
        nil -> merged ++ [model]
        index -> List.replace_at(merged, index, Map.merge(Enum.at(merged, index), model))
      end
    end)
  end

  defp mode_option(state) do
    current = Map.get(state, :mode_id) || @default_mode

    %{
      "id" => "mode",
      "name" => "Mode",
      "description" => "Session operational mode",
      "category" => "mode",
      "type" => "select",
      "currentValue" => current,
      "options" =>
        Enum.map(modes(), fn mode ->
          %{"value" => mode["id"], "name" => mode["name"], "description" => mode["description"]}
        end)
    }
  end

  defp model_option(%{models: []}), do: nil
  defp model_option(%{models: nil}), do: nil

  defp model_option(state) do
    models = Map.get(state, :models) || []

    if models == [] do
      nil
    else
      current = current_model_id(state)

      %{
        "id" => "model",
        "name" => "Model",
        "description" => "AI model to use",
        "category" => "model",
        "type" => "select",
        "currentValue" => current,
        "options" => Enum.map(models, &model_select_option/1)
      }
    end
  end

  defp thought_level_option(%{thought_level_enabled: false}), do: nil
  defp thought_level_option(%{thought_levels: []}), do: nil

  defp thought_level_option(state) do
    levels = Map.get(state, :thought_levels) || reasoning_levels(state)

    options =
      if levels == [] do
        @thought_levels
      else
        levels
      end

    %{
      "id" => "thought_level",
      "name" => "Thought Level",
      "description" => "Reasoning effort for this session",
      "category" => "thought_level",
      "type" => "select",
      "currentValue" =>
        Map.get(state, :thought_level) || Map.get(state, :default_thought_level) ||
          if(levels == [], do: @default_thought_level, else: hd(levels)["value"]),
      "options" =>
        Enum.map(options, fn level ->
          %{
            "value" => level["value"] || level[:value],
            "name" => level["label"] || level[:label] || humanize(level["value"] || level[:value])
          }
        end)
    }
  end

  defp model_select_option(model) do
    ref = model["ref"] || model[:ref] || %{}
    provider_id = ref["providerId"] || ref[:providerId] || ""
    model_id = ref["modelId"] || ref[:modelId] || ""
    model_key = if provider_id != "", do: "#{provider_id}/#{model_id}", else: model_id

    %{
      "value" => model_key,
      "name" => model["label"] || model[:label] || model_key,
      "description" => model["description"] || model[:description]
    }
  end

  defp current_model_id(state) do
    case Map.get(state, :model_ref) || Map.get(state, :current_model) || Map.get(state, :model) do
      %{"providerId" => p, "modelId" => m} -> "#{p}/#{m}"
      %{providerId: p, modelId: m} -> "#{p}/#{m}"
      id when is_binary(id) -> id
      _ -> "default"
    end
  end

  defp reasoning_levels(state) do
    state
    |> current_model_entry()
    |> case do
      %{"reasoning" => %{"levels" => levels}} when is_list(levels) -> levels
      %{reasoning: %{levels: levels}} when is_list(levels) -> levels
      _ -> []
    end
  end

  defp current_model_entry(state) do
    current = current_model_id(state)
    models = Map.get(state, :models) || []

    Enum.find(models, fn model ->
      model_key(model) == current
    end)
  end

  defp model_key(model) do
    ref = model["ref"] || model[:ref] || %{}
    p = ref["providerId"] || ref[:providerId] || ""
    m = ref["modelId"] || ref[:modelId] || ""
    if p != "", do: "#{p}/#{m}", else: m
  end

  defp humanize(value) when is_binary(value) do
    value
    |> String.split(~r/[_-]+/, trim: true)
    |> Enum.map_join(" ", fn
      <<first::binary-size(1), rest::binary>> -> String.upcase(first) <> rest
      "" -> ""
    end)
  end

  defp humanize(value), do: to_string(value)
end
