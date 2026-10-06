defmodule Arbor.MCP.Server.MRTR do
  @moduledoc false

  alias Arbor.MCP.Error
  alias Arbor.MCP.Internal.VersionRegistry
  alias Arbor.MCP.Protocol.ErrorCodes
  alias Arbor.MCP.Server.{RequestContext, RequestState, ResultNormalizer}

  @supported_methods ["tools/call", "resources/read", "prompts/get"]
  @input_methods ["elicitation/create", "sampling/createMessage", "roots/list"]
  @default_max_input_requests 16
  @default_max_bytes 1_048_576

  defmodule InputRequired do
    @moduledoc """
    A server result that suspends a modern MCP operation for client input.

    Build this struct with `Arbor.MCP.Server.DSL.Result.input_required/2` or return
    the equivalent `{:input_required, input_requests, state}` handler tuple.
    ArborMCP validates the requested input capabilities and seals application
    state into the modern `requestState` continuation envelope.
    """
    @enforce_keys [:input_requests]
    defstruct [:input_requests, :request_state]

    @type t :: %__MODULE__{input_requests: map(), request_state: term()}
  end

  @spec prepare_context(RequestContext.t(), map(), keyword()) ::
          {:ok, RequestContext.t()} | {:error, Error.ProtocolError.t()}
  def prepare_context(context, params, opts \\ []) do
    context = hydrate_context(context, opts)

    if context.method == "tasks/update" do
      prepare_task_update_context(context)
    else
      prepare_mrtr_context(context, params, opts)
    end
  end

  defp prepare_task_update_context(context) do
    if is_nil(context.sealed_request_state) do
      # Tasks extension inputResponses belong to the durable task state
      # machine, not to an MRTR retry of the original request.
      {:ok, %{context | input_responses: nil, mrtr_round: 0, delivery_semantics: :at_least_once}}
    else
      {:error, invalid("requestState is not valid for tasks/update")}
    end
  end

  defp prepare_mrtr_context(context, params, opts) do
    input_responses = context.input_responses
    sealed_state = context.sealed_request_state

    cond do
      is_nil(input_responses) and is_nil(sealed_state) ->
        {:ok, %{context | mrtr_round: 0, delivery_semantics: :at_least_once}}

      not VersionRegistry.modern?(context.protocol_version) ->
        {:error, invalid("MRTR retry fields require MCP 2026-07-28")}

      context.method not in @supported_methods ->
        {:error, invalid("MRTR retry fields are not valid for this method")}

      is_map(input_responses) and is_nil(sealed_state) ->
        prepare_unsealed_retry(context, input_responses, opts)

      not is_map(input_responses) or not is_binary(sealed_state) ->
        {:error, invalid("inputResponses and requestState must be provided together")}

      true ->
        resume_context(context, params, input_responses, sealed_state, opts)
    end
  end

  # requestState is optional on the wire. Arbor.MCP always emits a sealed value for
  # its own input_required results, but it must still accept a conforming
  # stateless retry from another implementation. Without a sealed envelope the
  # handler is responsible for deciding which response IDs it recognizes and
  # delivery can only be at-least-once.
  defp prepare_unsealed_retry(context, input_responses, opts) do
    input_responses = ResultNormalizer.stringify_keys(input_responses)

    with :ok <- validate_size(input_responses, opts) do
      {:ok,
       %{
         context
         | input_responses: input_responses,
           request_state: nil,
           mrtr_round: 1,
           delivery_semantics: :at_least_once
       }}
    end
  end

  defp resume_context(context, params, input_responses, sealed_state, opts) do
    input_responses = ResultNormalizer.stringify_keys(input_responses)

    with {:ok, payload} <-
           RequestState.unseal(sealed_state, context, params, input_responses, opts),
         {:ok, delivery_semantics} <- consume_replay(payload, opts) do
      {:ok,
       %{
         context
         | input_responses: input_responses,
           request_state: payload["applicationState"],
           mrtr_round: payload["binding"]["round"],
           mrtr_jti: payload["jti"],
           delivery_semantics: delivery_semantics
       }}
    else
      {:error, %Error.ProtocolError{} = error} ->
        emit_failure(context, :resume, :protocol_error)
        {:error, error}

      {:error, reason} ->
        emit_failure(context, :resume, failure_class(reason))
        {:error, request_state_error(reason)}
    end
  end

  @spec build_result(RequestContext.t(), map(), map(), term(), keyword()) ::
          {:ok, map()} | {:error, Error.ProtocolError.t()}
  def build_result(context, params, input_requests, application_state, opts \\ []) do
    context = hydrate_context(context, opts)

    with :ok <- validate_context(context),
         {:ok, requests} <- normalize_input_requests(input_requests),
         :ok <- validate_request_count(requests, opts),
         :ok <- validate_size(requests, opts),
         :ok <- validate_capabilities(requests, context.client_capabilities || %{}),
         round <- (context.mrtr_round || 0) + 1,
         {:ok, binding} <- RequestState.binding(context, params, Map.keys(requests), round, opts),
         {:ok, token} <- RequestState.seal(application_state, binding, opts) do
      {:ok,
       %{
         "resultType" => "input_required",
         "inputRequests" => requests,
         "requestState" => token
       }}
    else
      {:error, %Error.ProtocolError{} = error} ->
        emit_failure(context, :seal, :protocol_error)
        {:error, error}

      {:error, reason} ->
        emit_failure(context, :seal, failure_class(reason))
        {:error, request_state_error(reason)}
    end
  end

  defp validate_context(%RequestContext{method: method, protocol_version: version}) do
    cond do
      method not in @supported_methods ->
        {:error,
         invalid("input_required is only valid for tools/call, resources/read, and prompts/get")}

      not VersionRegistry.modern?(version) ->
        {:error, invalid("input_required requires MCP 2026-07-28")}

      true ->
        :ok
    end
  end

  defp normalize_input_requests(requests) when is_map(requests) do
    normalized = ResultNormalizer.stringify_keys(requests)

    Enum.reduce_while(normalized, {:ok, %{}}, fn
      {id, request}, {:ok, acc} when is_binary(id) and byte_size(id) > 0 and is_map(request) ->
        method = Map.get(request, "method")
        params = Map.get(request, "params", %{})

        if method in @input_methods and is_map(params) do
          clean = %{"method" => method, "params" => params}
          {:cont, {:ok, Map.put(acc, id, clean)}}
        else
          {:halt,
           {:error,
            invalid("Invalid MRTR input request", %{"inputRequestId" => id, "method" => method})}}
        end

      {id, _request}, _acc ->
        {:halt, {:error, invalid("Invalid MRTR input request ID", %{"inputRequestId" => id})}}
    end)
  end

  defp normalize_input_requests(_requests),
    do: {:error, invalid("inputRequests must be an object")}

  defp validate_request_count(requests, opts) do
    maximum = Keyword.get(opts, :max_input_requests, @default_max_input_requests)

    if map_size(requests) <= maximum,
      do: :ok,
      else: {:error, invalid("MRTR input request limit exceeded", %{"maximum" => maximum})}
  end

  defp validate_size(value, opts) do
    maximum = Keyword.get(opts, :max_mrtr_bytes, @default_max_bytes)

    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= maximum -> :ok
      {:ok, _encoded} -> {:error, invalid("MRTR byte limit exceeded", %{"maximum" => maximum})}
      {:error, _reason} -> {:error, invalid("MRTR payload must be JSON encodable")}
    end
  end

  defp validate_capabilities(requests, capabilities) do
    Enum.reduce_while(requests, :ok, fn {_id, request}, :ok ->
      required = required_capability(request)

      if capability_satisfied?(capabilities, required) do
        {:cont, :ok}
      else
        {:halt, {:error, Error.missing_required_client_capability(required)}}
      end
    end)
  end

  defp required_capability(%{"method" => "roots/list"}), do: %{"roots" => %{}}

  defp required_capability(%{"method" => "sampling/createMessage"}),
    do: %{"sampling" => %{}}

  defp required_capability(%{"method" => "elicitation/create", "params" => %{"mode" => "url"}}),
    do: %{"elicitation" => %{"url" => %{}}}

  defp required_capability(%{"method" => "elicitation/create"}),
    do: %{"elicitation" => %{"form" => %{}}}

  defp capability_satisfied?(capabilities, %{"elicitation" => %{"form" => %{}}}) do
    case capability_value(capabilities, "elicitation") do
      {:ok, value} when is_map(value) ->
        map_size(value) == 0 or match?({:ok, _}, capability_value(value, "form"))

      _other ->
        false
    end
  end

  defp capability_satisfied?(capabilities, required) do
    Enum.all?(required, fn {key, nested} ->
      case capability_value(capabilities, key) do
        {:ok, value} when map_size(nested) == 0 -> is_map(value)
        {:ok, value} when is_map(value) -> capability_satisfied?(value, nested)
        _other -> false
      end
    end)
  end

  defp capability_value(map, key) when is_map(map) do
    atom_key = String.to_existing_atom(key)

    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, atom_key) -> {:ok, Map.get(map, atom_key)}
      true -> :error
    end
  rescue
    ArgumentError -> if Map.has_key?(map, key), do: {:ok, Map.get(map, key)}, else: :error
  end

  defp capability_value(_map, _key), do: :error

  defp hydrate_context(context, opts) do
    %{
      context
      | endpoint: context.endpoint || Keyword.get(opts, :endpoint),
        principal_id: context.principal_id || Keyword.get(opts, :principal_id),
        tenant_id: context.tenant_id || Keyword.get(opts, :tenant_id)
    }
  end

  defp consume_replay(payload, opts) do
    case Keyword.get(opts, :replay_cache) do
      nil ->
        if Keyword.get(opts, :require_replay_protection, false) do
          emit_failure(nil, :replay, :replay_cache_required)

          {:error,
           Error.protocol_error(
             ErrorCodes.internal_error(),
             "MRTR replay protection is required but no replay cache is configured"
           )}
        else
          {:ok, :at_least_once}
        end

      {adapter, adapter_opts} when is_atom(adapter) and is_list(adapter_opts) ->
        consume_with_adapter(adapter, payload, adapter_opts)

      adapter when is_atom(adapter) ->
        consume_with_adapter(adapter, payload, [])

      _other ->
        emit_failure(nil, :replay, :invalid_replay_cache)

        {:error,
         Error.protocol_error(
           ErrorCodes.internal_error(),
           "Invalid MRTR replay cache configuration"
         )}
    end
  end

  defp consume_with_adapter(adapter, payload, adapter_opts) do
    case adapter.consume(payload["jti"], payload["exp"], adapter_opts) do
      :ok ->
        {:ok, :single_use}

      {:error, :replayed} ->
        emit_failure(nil, :replay, :replay_rejected)
        {:error, invalid("MRTR requestState has already been consumed")}

      {:error, _reason} ->
        emit_failure(nil, :replay, :replay_cache_failure)
        {:error, Error.protocol_error(ErrorCodes.internal_error(), "MRTR replay cache failed")}
    end
  rescue
    _error ->
      emit_failure(nil, :replay, :replay_cache_failure)
      {:error, Error.protocol_error(ErrorCodes.internal_error(), "MRTR replay cache failed")}
  end

  defp emit_failure(context, stage, reason) do
    method = if context, do: context.method, else: nil

    :telemetry.execute(
      [:arbor_mcp, :server, :mrtr, :failure],
      %{count: 1},
      %{stage: stage, reason: reason, method: method_class(method)}
    )
  end

  defp method_class(method) when method in @supported_methods, do: method
  defp method_class(_method), do: :unknown

  defp failure_class(reason)
       when reason in [
              :request_state_not_configured,
              :invalid_request_state_configuration,
              :invalid_request_state,
              :request_state_expired,
              :request_state_not_yet_valid,
              :request_state_key_revoked,
              :request_state_key_unknown,
              :request_state_too_large,
              :request_state_binding_mismatch,
              :input_response_ids_mismatch,
              :request_state_not_json
            ],
       do: reason

  defp failure_class(_reason), do: :other

  defp request_state_error(:request_state_not_configured) do
    Error.protocol_error(
      ErrorCodes.internal_error(),
      "MRTR requestState key ring is not configured"
    )
  end

  defp request_state_error(:invalid_request_state_configuration) do
    Error.protocol_error(ErrorCodes.internal_error(), "Invalid MRTR requestState key ring")
  end

  defp request_state_error(reason) do
    invalid("Invalid MRTR requestState", %{"reason" => to_string(reason)})
  end

  defp invalid(message, data \\ nil) do
    Error.protocol_error(ErrorCodes.invalid_params(), message, data)
  end
end
