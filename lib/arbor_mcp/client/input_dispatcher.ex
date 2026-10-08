defmodule Arbor.MCP.Client.InputDispatcher do
  @moduledoc false

  require Logger

  alias Arbor.MCP.Client.ElicitationHandler
  alias Arbor.MCP.Error
  alias Arbor.MCP.Protocol.ErrorCodes

  @input_methods ["elicitation/create", "sampling/createMessage", "roots/list"]

  @spec dispatch(String.t(), map(), module() | :none, term(), map(), keyword()) ::
          {:ok, map(), term()} | {:error, term(), term()}
  def dispatch(method, params, handler, handler_state, capabilities, opts \\ [])

  def dispatch(method, params, handler, handler_state, capabilities, opts)
      when method in @input_methods and is_map(params) do
    case maybe_require_capability(method, params, capabilities, opts) do
      :ok -> do_dispatch(method, params, handler, handler_state, capabilities)
      {:error, reason} -> {:error, reason, handler_state}
    end
  end

  def dispatch(method, _params, _handler, handler_state, _capabilities, _opts) do
    {:error, protocol_error("Unsupported MRTR input method", %{"method" => method}),
     handler_state}
  end

  defp do_dispatch("roots/list", _params, handler, state, _capabilities) do
    if callback?(handler, :handle_list_roots, 1) do
      case handler.handle_list_roots(state) do
        {:ok, roots, new_state} when is_list(roots) ->
          {:ok, %{"roots" => roots}, new_state}

        other ->
          normalize_callback_error(other, state)
      end
    else
      {:error, method_not_found("roots/list"), state}
    end
  end

  defp do_dispatch("sampling/createMessage", params, handler, state, _capabilities) do
    if callback?(handler, :handle_create_message, 2) do
      normalize_callback_return(handler.handle_create_message(params, state), state)
    else
      {:error, method_not_found("sampling/createMessage"), state}
    end
  end

  defp do_dispatch("elicitation/create", %{"mode" => "url"} = params, handler, state, caps) do
    message = Map.get(params, "message", "")
    url = Map.get(params, "url", "")
    elicitation_id = Map.get(params, "elicitationId")

    cond do
      callback?(handler, :handle_url_elicitation, 4) ->
        normalize_callback_return(
          handler.handle_url_elicitation(message, url, elicitation_id, state),
          state
        )

      callback?(handler, :handle_url_elicitation, 3) ->
        normalize_callback_return(
          handler.handle_url_elicitation(message, url, state),
          state
        )

      callback?(handler, :handle_elicitation_create, 3) ->
        warn_url_elicitation_fallback(handler)

        normalize_callback_return(
          handler.handle_elicitation_create(message, elicitation_payload(params), state),
          state
        )

      capability_present?(caps, "elicitation") ->
        {:ok, ElicitationHandler.handle(message, elicitation_payload(params)), state}

      true ->
        {:error, method_not_found("elicitation/create"), state}
    end
  end

  defp do_dispatch("elicitation/create", params, handler, state, caps) do
    message = Map.get(params, "message", "")
    schema = elicitation_payload(params)

    cond do
      callback?(handler, :handle_elicitation_create, 3) ->
        normalize_callback_return(
          handler.handle_elicitation_create(message, schema, state),
          state
        )

      capability_present?(caps, "elicitation") ->
        {:ok, ElicitationHandler.handle(message, schema), state}

      true ->
        {:error, method_not_found("elicitation/create"), state}
    end
  end

  defp normalize_callback_return({:ok, result, new_state}, _state) when is_map(result),
    do: {:ok, result, new_state}

  defp normalize_callback_return(other, state), do: normalize_callback_error(other, state)

  defp normalize_callback_error({:error, reason, new_state}, _state),
    do: {:error, reason, new_state}

  defp normalize_callback_error(other, state),
    do: {:error, {:invalid_client_handler_reply, other}, state}

  defp maybe_require_capability(method, params, capabilities, opts) do
    if Keyword.get(opts, :require_capability, false) do
      required = required_capability(method, params)

      if capability_satisfied?(capabilities, required) do
        :ok
      else
        {:error, Error.missing_required_client_capability(required)}
      end
    else
      :ok
    end
  end

  defp required_capability("roots/list", _params), do: %{"roots" => %{}}
  defp required_capability("sampling/createMessage", _params), do: %{"sampling" => %{}}

  defp required_capability("elicitation/create", %{"mode" => "url"}),
    do: %{"elicitation" => %{"url" => %{}}}

  defp required_capability("elicitation/create", _params),
    do: %{"elicitation" => %{"form" => %{}}}

  defp capability_satisfied?(capabilities, %{"elicitation" => %{"form" => %{}}}) do
    case capability_value(capabilities, "elicitation") do
      {:ok, value} when is_map(value) ->
        map_size(value) == 0 or capability_present?(value, "form")

      _ ->
        false
    end
  end

  defp capability_satisfied?(capabilities, required) do
    Enum.all?(required, fn {key, nested} ->
      case capability_value(capabilities, key) do
        {:ok, value} when map_size(nested) == 0 -> is_map(value)
        {:ok, value} when is_map(value) -> capability_satisfied?(value, nested)
        _ -> false
      end
    end)
  end

  defp capability_present?(map, key), do: match?({:ok, _}, capability_value(map, key))

  defp capability_value(map, key) when is_map(map) do
    atom_key = String.to_existing_atom(key)

    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, atom_key) -> {:ok, Map.get(map, atom_key)}
      true -> :error
    end
  rescue
    ArgumentError ->
      if Map.has_key?(map, key), do: {:ok, Map.get(map, key)}, else: :error
  end

  defp capability_value(_map, _key), do: :error

  defp elicitation_payload(%{"mode" => "url"} = params) do
    Map.take(params, ["mode", "url", "elicitationId"])
  end

  defp elicitation_payload(params), do: Map.get(params, "requestedSchema", %{})

  defp callback?(:none, _fun, _arity), do: false

  defp callback?(handler, fun, arity) when is_atom(handler) do
    function_exported?(handler, fun, arity) or
      (Code.ensure_loaded?(handler) and function_exported?(handler, fun, arity))
  end

  defp warn_url_elicitation_fallback(handler) do
    warning_key = {__MODULE__, :url_elicitation_fallback, handler}

    unless :persistent_term.get(warning_key, false) do
      :persistent_term.put(warning_key, true)

      Logger.warning(
        "#{inspect(handler)} does not implement handle_url_elicitation/3; " <>
          "routing URL-mode elicitation to handle_elicitation_create/3 with the URL payload"
      )
    end
  end

  defp method_not_found(method) do
    Error.protocol_error(
      ErrorCodes.method_not_found(),
      "No client handler is available for #{method}"
    )
  end

  defp protocol_error(message, data) do
    Error.protocol_error(ErrorCodes.invalid_params(), message, data)
  end
end
