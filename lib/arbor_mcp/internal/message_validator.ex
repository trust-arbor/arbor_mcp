defmodule Arbor.MCP.Internal.MessageValidator do
  @moduledoc false

  # Provides comprehensive MCP message validation as required by the specification.
  #
  # This module implements the validation layer identified as missing in
  # SPEC_ALIGNMENT_PLAN.md. It validates:
  #
  # - Request ID validation (null IDs are rejected per spec)
  # - Request ID uniqueness tracking within sessions
  # - Response format validation (result XOR error requirement)
  # - JSON-RPC 2.0 compliance
  # - Method availability for protocol versions
  # - Parameter validation for specific methods
  #
  # The validator maintains session state to track request IDs and detect
  # duplicates as required by the MCP specification.

  @type validation_result :: {:ok, map()} | {:error, map()}
  @type session_state :: %{
          seen_request_ids: MapSet.t(String.t() | integer()),
          max_request_ids: pos_integer(),
          protocol_version: String.t() | nil
        }

  alias Arbor.MCP.Protocol.ErrorCodes

  @invalid_request ErrorCodes.invalid_request()
  @invalid_params ErrorCodes.invalid_params()
  @internal_error ErrorCodes.internal_error()
  @default_max_request_ids 10_000

  @doc """
  Creates a new validation session state.
  """
  def new_session(protocol_version \\ nil, opts \\ []) do
    max_request_ids = Keyword.get(opts, :max_request_ids, @default_max_request_ids)

    unless is_integer(max_request_ids) and max_request_ids > 0 do
      raise ArgumentError, ":max_request_ids must be a positive integer"
    end

    %{
      seen_request_ids: MapSet.new(),
      max_request_ids: max_request_ids,
      protocol_version: protocol_version
    }
  end

  @doc """
  Validates a request message against MCP specification requirements.
  """
  @spec validate_request(map()) :: validation_result()
  def validate_request(request) when is_map(request) do
    with :ok <- validate_jsonrpc_version(request),
         :ok <- validate_request_structure(request),
         :ok <- validate_request_id(request),
         :ok <- validate_method_exists(request),
         :ok <- validate_request_method_params(request) do
      {:ok, request}
    else
      {:error, error_data} -> {:error, error_data}
    end
  end

  def validate_request(_), do: {:error, create_error(@invalid_request, "Invalid request format")}

  @doc """
  Validates a response message against MCP specification requirements.
  """
  @spec validate_response(map()) :: validation_result()
  def validate_response(response) when is_map(response) do
    with :ok <- validate_jsonrpc_version(response),
         :ok <- validate_response_structure(response),
         :ok <- validate_response_format(response) do
      {:ok, response}
    else
      {:error, error_data} -> {:error, error_data}
    end
  end

  def validate_response(_),
    do: {:error, create_error(@invalid_request, "Invalid response format")}

  @doc """
  Validates any MCP message (request, response, or notification) with session tracking.
  """
  @spec validate_message(map() | list(), session_state()) ::
          {validation_result(), session_state()}
  def validate_message(messages, state) when is_list(messages) do
    # Handle batch requests
    if Enum.empty?(messages) do
      {{:error, create_error(@invalid_request, "Empty batch array is invalid")}, state}
    else
      # Validate each message in the batch
      {results, final_state} =
        Enum.reduce(messages, {[], state}, fn message, {acc_results, acc_state} ->
          {result, new_state} = validate_message(message, acc_state)
          {[result | acc_results], new_state}
        end)

      # Reverse to maintain original order
      results = Enum.reverse(results)

      # Check if any validation failed and extract validated messages
      case Enum.find(results, fn {status, _} -> status == :error end) do
        nil ->
          # All validations succeeded - extract the validated messages
          validated_messages = Enum.map(results, fn {:ok, msg} -> msg end)
          {{:ok, validated_messages}, final_state}

        {_, error} ->
          {{:error, error}, final_state}
      end
    end
  end

  def validate_message(message, state) when is_map(message) do
    cond do
      # Check if it's missing jsonrpc field entirely - invalid message structure
      not Map.has_key?(message, "jsonrpc") ->
        {{:error, create_error(@invalid_request, "Invalid message structure")}, state}

      # Request: has method and id
      Map.has_key?(message, "method") and Map.has_key?(message, "id") ->
        validate_request_with_state(message, state)

      # Notification: has method but no id
      Map.has_key?(message, "method") ->
        validate_notification_with_state(message, state)

      # Response: has result or error with id
      Map.has_key?(message, "id") and
          (Map.has_key?(message, "result") or Map.has_key?(message, "error")) ->
        validate_response_with_state(message, state)

      # Has id but no result/error - incomplete response
      Map.has_key?(message, "id") ->
        {{:error, create_error(@internal_error, "Response must contain either result or error")},
         state}

      true ->
        {{:error, create_error(@invalid_request, "Invalid message structure")}, state}
    end
  end

  def validate_message(_, state) do
    {{:error, create_error(@invalid_request, "Message must be a JSON object or array")}, state}
  end

  # Private validation functions

  defp validate_jsonrpc_version(%{"jsonrpc" => "2.0"}), do: :ok

  defp validate_jsonrpc_version(%{"jsonrpc" => version}) do
    {:error,
     create_error(@invalid_request, "Invalid JSON-RPC version", %{
       received_type: type_of(version),
       expected: "2.0"
     })}
  end

  defp validate_jsonrpc_version(_) do
    {:error, create_error(@invalid_request, "Missing JSON-RPC version field")}
  end

  defp validate_request_structure(request) do
    required_fields = ["jsonrpc", "method", "id"]
    missing_fields = Enum.reject(required_fields, &Map.has_key?(request, &1))

    cond do
      missing_fields != [] ->
        {:error,
         create_error(@invalid_request, "Missing required fields", %{missing: missing_fields})}

      # Validate params field if present
      Map.has_key?(request, "params") and not is_map(Map.get(request, "params")) ->
        {:error, create_error(@invalid_request, "Parameters must be an object")}

      true ->
        :ok
    end
  end

  defp validate_response_structure(response) do
    required_fields = ["jsonrpc", "id"]
    missing_fields = Enum.reject(required_fields, &Map.has_key?(response, &1))

    if missing_fields == [] do
      :ok
    else
      {:error,
       create_error(@invalid_request, "Missing required fields", %{missing: missing_fields})}
    end
  end

  defp validate_request_id(%{"id" => nil}) do
    {:error, create_error(@invalid_request, "Request ID must not be null")}
  end

  defp validate_request_id(%{"id" => id}) when is_binary(id) or is_integer(id) do
    :ok
  end

  defp validate_request_id(%{"id" => id}) do
    {:error,
     create_error(@invalid_request, "Request ID must be string or integer", %{
       received_type: type_of(id)
     })}
  end

  defp validate_request_id(_) do
    {:error, create_error(@invalid_request, "Missing request ID")}
  end

  defp validate_method_exists(%{"method" => method})
       when is_binary(method) and byte_size(method) > 0 do
    :ok
  end

  defp validate_method_exists(%{"method" => method}) do
    {:error,
     create_error(@invalid_request, "Method must be non-empty string", %{
       received_type: type_of(method)
     })}
  end

  defp validate_method_exists(_) do
    {:error, create_error(@invalid_request, "Missing method field")}
  end

  defp validate_response_format(response) do
    has_result = Map.has_key?(response, "result")
    has_error = Map.has_key?(response, "error")

    cond do
      has_result and has_error ->
        {:error, create_error(@internal_error, "Response cannot contain both result and error")}

      not has_result and not has_error ->
        {:error, create_error(@internal_error, "Response must contain either result or error")}

      has_error ->
        # Validate error object structure
        validate_error_object(Map.get(response, "error"))

      true ->
        :ok
    end
  end

  defp validate_error_object(error) when is_map(error) do
    required_fields = ["code", "message"]
    missing_fields = Enum.reject(required_fields, &Map.has_key?(error, &1))

    cond do
      missing_fields != [] ->
        {:error,
         create_error(@internal_error, "Error object missing required fields", %{
           missing: missing_fields
         })}

      # Check if we have code field but it's invalid type - treat as missing field
      Map.has_key?(error, "code") and not is_integer(Map.get(error, "code")) ->
        {:error,
         create_error(@internal_error, "Error object missing required fields", %{
           missing: ["code"],
           note: "code must be integer"
         })}

      Map.has_key?(error, "message") and not is_binary(Map.get(error, "message")) ->
        {:error,
         create_error(@internal_error, "Error object missing required fields", %{
           missing: ["message"],
           note: "message must be string"
         })}

      true ->
        :ok
    end
  end

  defp validate_error_object(_) do
    {:error, create_error(@internal_error, "Error must be an object")}
  end

  defp validate_request_with_state(request, state) do
    case validate_request(request) do
      {:ok, validated_request} ->
        # Check for duplicate request ID
        request_id = Map.get(request, "id")

        cond do
          MapSet.member?(state.seen_request_ids, request_id) ->
            error =
              create_error(
                @invalid_request,
                "Request ID has already been used in this session",
                %{type: "duplicate_request_id", duplicate_id: request_id}
              )

            {{:error, error}, state}

          MapSet.size(state.seen_request_ids) >=
              Map.get(state, :max_request_ids, @default_max_request_ids) ->
            error =
              create_error(@invalid_request, "Request ID tracking capacity exceeded", %{
                type: "request_id_capacity_exceeded",
                limit: Map.get(state, :max_request_ids, @default_max_request_ids)
              })

            {{:error, error}, state}

          true ->
            new_state = %{
              state
              | seen_request_ids: MapSet.put(state.seen_request_ids, request_id)
            }

            {{:ok, validated_request}, new_state}
        end

      {:error, error} ->
        {{:error, error}, state}
    end
  end

  defp validate_notification_with_state(notification, state) do
    with :ok <- validate_jsonrpc_version(notification),
         :ok <- validate_method_exists(notification),
         :ok <- validate_request_method_params(notification) do
      {{:ok, notification}, state}
    else
      {:error, error} -> {{:error, error}, state}
    end
  end

  defp validate_response_with_state(response, state) do
    case validate_response(response) do
      {:ok, validated_response} -> {{:ok, validated_response}, state}
      {:error, error} -> {{:error, error}, state}
    end
  end

  defp create_error(code, message, data \\ nil) do
    error = %{
      code: code,
      message: message
    }

    if data do
      Map.put(error, :data, data)
    else
      error
    end
  end

  defp type_of(value) when is_binary(value), do: "string"
  defp type_of(value) when is_integer(value), do: "integer"
  defp type_of(value) when is_float(value), do: "float"
  defp type_of(value) when is_boolean(value), do: "boolean"
  defp type_of(value) when is_list(value), do: "array"
  defp type_of(value) when is_map(value), do: "object"
  defp type_of(value) when is_atom(value), do: "atom"
  defp type_of(_), do: "unknown"

  @doc """
  Validates that required parameters are present for specific methods.
  """
  @spec validate_method_params(String.t(), map()) :: :ok | {:error, map()}
  def validate_method_params("tools/call", params) when is_map(params),
    do: validate_tool_call_params(params)

  def validate_method_params("tools/execute", params) when is_map(params),
    do: require_nonempty_string(params, "tool_name")

  def validate_method_params("resources/read", params) when is_map(params),
    do: validate_resource_read_params(params)

  def validate_method_params("prompts/get", params) when is_map(params),
    do: validate_prompt_get_params(params)

  def validate_method_params("resources/subscribe", params) when is_map(params),
    do: validate_resource_subscribe_params(params)

  def validate_method_params("resources/unsubscribe", params) when is_map(params),
    do: validate_resource_unsubscribe_params(params)

  def validate_method_params("completion/complete", params) when is_map(params),
    do: validate_completion_params(params)

  def validate_method_params("subscriptions/listen", params) when is_map(params),
    do: require_object(params, "notifications")

  def validate_method_params(method, params)
      when is_map(params) and
             method in ["tasks/get", "tasks/result", "tasks/cancel", "tasks/update"],
      do: require_nonempty_string(params, "taskId")

  def validate_method_params("logging/setLevel", params) when is_map(params),
    do: validate_log_level(params)

  def validate_method_params("notifications/cancelled", params) when is_map(params),
    do: require_request_id(params, "requestId")

  def validate_method_params("notifications/elicitation/complete", params) when is_map(params),
    do: require_nonempty_string(params, "elicitationId")

  def validate_method_params(_method, params) when is_map(params), do: :ok

  def validate_method_params(_, _) do
    {:error, create_error(@invalid_params, "Parameters must be an object")}
  end

  defp validate_tool_call_params(params) do
    with :ok <- require_nonempty_string(params, "name") do
      validate_optional_object(params, "arguments")
    end
  end

  defp validate_resource_read_params(params) do
    validate_uri_field(params, "uri")
  end

  defp validate_prompt_get_params(params) do
    with :ok <- require_nonempty_string(params, "name") do
      validate_optional_object(params, "arguments")
    end
  end

  defp validate_resource_subscribe_params(params) do
    validate_uri_field(params, "uri")
  end

  defp validate_resource_unsubscribe_params(params) do
    validate_uri_field(params, "uri")
  end

  defp validate_request_method_params(%{"method" => method} = request) do
    params = if Map.has_key?(request, "params"), do: Map.get(request, "params"), else: %{}
    validate_method_params(method, params)
  end

  defp validate_request_method_params(_request), do: :ok

  defp validate_uri_field(params, key), do: require_nonempty_string(params, key)

  defp validate_completion_params(params) do
    with :ok <- require_object(params, "ref"),
         :ok <- require_object(params, "argument"),
         :ok <- require_nonempty_string(Map.get(params, "argument", %{}), "name") do
      require_string(Map.get(params, "argument", %{}), "value")
    end
  end

  defp validate_log_level(params) do
    case Map.get(params, "level") do
      level
      when level in [
             "debug",
             "info",
             "notice",
             "warning",
             "error",
             "critical",
             "alert",
             "emergency"
           ] ->
        :ok

      nil ->
        missing_parameter("level")

      _invalid ->
        invalid_parameter("level", "must be a valid logging level")
    end
  end

  defp require_request_id(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) or is_integer(value) -> :ok
      nil -> missing_parameter(key)
      _invalid -> invalid_parameter(key, "must be a string or integer")
    end
  end

  defp require_nonempty_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and byte_size(value) > 0 -> :ok
      nil -> missing_parameter(key)
      _invalid -> invalid_parameter(key, "must be a non-empty string")
    end
  end

  defp require_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) -> :ok
      nil -> missing_parameter(key)
      _invalid -> invalid_parameter(key, "must be a string")
    end
  end

  defp require_object(params, key) do
    case Map.get(params, key) do
      value when is_map(value) -> :ok
      nil -> missing_parameter(key)
      _invalid -> invalid_parameter(key, "must be an object")
    end
  end

  defp validate_optional_object(params, key) do
    case Map.fetch(params, key) do
      :error -> :ok
      {:ok, value} when is_map(value) -> :ok
      {:ok, _invalid} -> invalid_parameter(key, "must be an object")
    end
  end

  defp missing_parameter(key) do
    {:error, create_error(@invalid_params, "Missing required parameters", %{missing: [key]})}
  end

  defp invalid_parameter(key, reason) do
    {:error, create_error(@invalid_params, "Invalid parameters", %{field: key, reason: reason})}
  end

  @doc """
  Validates JSON-RPC error codes according to the specification.

  Standard codes: -32768 to -32000 (reserved)
  Server-defined codes: -32099 to -32000 (custom application errors)
  """
  @spec validate_error_code(integer()) :: {:ok, integer()} | {:error, map()}
  def validate_error_code(code) when is_integer(code) do
    cond do
      # Standard JSON-RPC codes (always valid)
      code in [-32700, -32600, -32601, -32602, -32603] ->
        {:ok, code}

      # Server-defined application error codes
      code >= -32099 and code <= -32000 ->
        {:ok, code}

      # Other reserved codes (JSON-RPC spec reserves -32768 to -32000)
      code >= -32768 and code <= -32000 ->
        {:ok, code}

      # Invalid codes outside allowed ranges
      true ->
        {:error,
         create_error(@internal_error, "Invalid error code", %{
           code: code,
           valid_ranges: ["-32768 to -32000 (reserved)", "-32099 to -32000 (application)"]
         })}
    end
  end

  def validate_error_code(_) do
    {:error, create_error(@invalid_params, "Error code must be an integer")}
  end
end
