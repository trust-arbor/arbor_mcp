defmodule Arbor.MCP.Server.RequestContext do
  @moduledoc """
  Validated protocol context for one inbound MCP message.

  The context separates transport/protocol metadata from application params.
  Legacy messages remain valid without modern metadata; a message that uses
  either required modern field must provide the complete modern `_meta`
  object.
  """

  alias Arbor.MCP.Error
  alias Arbor.MCP.Internal.VersionRegistry
  alias Arbor.MCP.Protocol.{ErrorCodes, Meta, Methods}
  alias Arbor.MCP.Tasks.Extension, as: TasksExtension
  alias Arbor.RPC.JSONRPC

  @enforce_keys [:method, :request_id, :request?, :era]
  defstruct [
    :method,
    :request_id,
    :request?,
    :era,
    :protocol_version,
    :client_capabilities,
    :client_info,
    :log_level,
    :progress_token,
    :input_responses,
    :request_state,
    :sealed_request_state,
    :mrtr_round,
    :mrtr_jti,
    :delivery_semantics,
    :principal_id,
    :tenant_id,
    :endpoint,
    :notification_target,
    :application_context,
    meta: %{},
    trace_context: %{}
  ]

  @type t :: %__MODULE__{
          method: String.t(),
          request_id: Arbor.MCP.Types.request_id() | nil,
          request?: boolean(),
          era: :legacy | :modern | :unknown,
          protocol_version: String.t() | nil,
          client_capabilities: map() | nil,
          client_info: map() | nil,
          log_level: String.t() | nil,
          progress_token: Arbor.MCP.Types.progress_token() | nil,
          input_responses: map() | nil,
          request_state: term(),
          sealed_request_state: String.t() | nil,
          mrtr_round: non_neg_integer() | nil,
          mrtr_jti: String.t() | nil,
          delivery_semantics: :at_least_once | :single_use | nil,
          principal_id: String.t() | nil,
          tenant_id: String.t() | nil,
          endpoint: String.t() | nil,
          notification_target: term(),
          application_context: term(),
          meta: map(),
          trace_context: map()
        }

  @type context_error ::
          Meta.validation_error()
          | {:unsupported_protocol_version, String.t()}
          | {:protocol_mode_mismatch, Arbor.MCP.Types.protocol_mode(), :legacy | :modern}
          | {:method_not_available, String.t(), String.t()}

  @doc "Extracts context from a JSON-RPC request or notification."
  @spec from_message(map()) :: {:ok, t()} | {:error, context_error()}
  def from_message(%{"method" => method} = message) when is_binary(method) do
    params = Map.get(message, "params", %{})

    cond do
      not is_map(params) ->
        {:error, {:invalid_meta, :not_an_object}}

      Map.has_key?(message, "id") ->
        from_request(message, params)

      true ->
        from_notification(message, params)
    end
  end

  def from_message(_message), do: {:error, {:invalid_meta, :not_an_object}}

  @doc "Builds a JSON-RPC error response for a context-validation failure."
  @spec error_response(
          context_error(),
          Arbor.MCP.Types.request_id() | nil,
          Arbor.MCP.Types.protocol_mode() | nil
        ) :: map()
  def error_response(reason, id, protocol_mode \\ nil)

  def error_response({:unsupported_protocol_version, requested}, id, protocol_mode) do
    JSONRPC.error(
      id,
      ErrorCodes.unsupported_protocol_version(),
      "Unsupported protocol version",
      %{
        "supported" => supported_versions(protocol_mode),
        "requested" => requested
      }
    )
  end

  def error_response({:protocol_mode_mismatch, :legacy_only, :modern}, id, _protocol_mode) do
    JSONRPC.error(
      id,
      ErrorCodes.unsupported_protocol_version(),
      "Unsupported protocol version",
      %{
        "supported" => VersionRegistry.enabled_versions(:legacy_only),
        "requested" => VersionRegistry.preferred_version(:modern_only)
      }
    )
  end

  def error_response({:protocol_mode_mismatch, :modern_only, :legacy}, id, _protocol_mode) do
    JSONRPC.error(
      id,
      ErrorCodes.unsupported_protocol_version(),
      "Unsupported protocol version",
      %{
        "supported" => VersionRegistry.enabled_versions(:modern_only),
        "requested" => "legacy"
      }
    )
  end

  def error_response({:method_not_available, method, version}, id, _protocol_mode) do
    JSONRPC.error(
      id,
      ErrorCodes.method_not_found(),
      "Method not found",
      %{"method" => method, "protocolVersion" => version}
    )
  end

  def error_response(reason, id, _protocol_mode) do
    JSONRPC.error(
      id,
      ErrorCodes.invalid_params(),
      "Invalid request metadata",
      validation_error_data(reason)
    )
  end

  @doc "Returns the HTTP status required for context-validation errors."
  @spec http_status(context_error()) :: 400
  def http_status(_error), do: 400

  @doc "Validates an extracted context against an explicitly configured server mode."
  @spec validate_protocol_mode(t(), Arbor.MCP.Types.protocol_mode() | nil) ::
          :ok | {:error, context_error()}
  def validate_protocol_mode(_context, nil), do: :ok

  def validate_protocol_mode(%__MODULE__{era: :modern}, mode)
      when mode in [:modern_only, :prefer_modern, :prefer_legacy],
      do: :ok

  def validate_protocol_mode(%__MODULE__{era: :legacy}, mode)
      when mode in [:legacy_only, :prefer_modern, :prefer_legacy],
      do: :ok

  def validate_protocol_mode(%__MODULE__{era: era}, mode)
      when mode in [:legacy_only, :modern_only] and era in [:legacy, :modern],
      do: {:error, {:protocol_mode_mismatch, mode, era}}

  def validate_protocol_mode(_context, _mode), do: :ok

  @doc "Validates that a method belongs to the selected protocol revision."
  @spec validate_method(t()) :: :ok | {:error, context_error()}
  def validate_method(%__MODULE__{} = context) do
    version =
      if context.era == :modern,
        do: context.protocol_version,
        else: VersionRegistry.latest_version()

    if Methods.available?(context.method, version) do
      validate_method_capabilities(context)
    else
      {:error, {:method_not_available, context.method, version}}
    end
  end

  @doc """
  Verifies that a modern request declared every capability an operation needs.

  Empty capability objects require presence of that capability. Nested maps
  require the corresponding nested keys. On failure, the returned protocol
  error can be returned directly as a handler error reason.
  """
  @spec require_client_capabilities(t(), map()) ::
          :ok | {:error, Error.ProtocolError.t()}
  def require_client_capabilities(%__MODULE__{} = context, required)
      when is_map(required) do
    declared = context.client_capabilities || %{}

    if capabilities_satisfy?(declared, required) do
      :ok
    else
      {:error, Error.missing_required_client_capability(required)}
    end
  end

  defp validate_method_capabilities(%__MODULE__{era: :modern, request?: true} = context) do
    if context.method in TasksExtension.request_methods(),
      do: require_client_capabilities(context, TasksExtension.required_capabilities()),
      else: :ok
  end

  defp validate_method_capabilities(_context), do: :ok

  defp from_request(message, params) do
    meta = Map.get(params, "_meta")

    cond do
      is_nil(meta) ->
        {:ok, legacy_context(message, params, %{})}

      not is_map(meta) ->
        {:error, {:invalid_meta, :not_an_object}}

      modern_metadata?(meta) ->
        parse_modern_request(message, params, meta)

      true ->
        build_legacy_context(message, params, meta)
    end
  end

  defp from_notification(message, params) do
    meta = Map.get(params, "_meta")

    case Meta.parse_notification_meta(meta) do
      {:ok, parsed} ->
        {:ok,
         %__MODULE__{
           method: message["method"],
           request_id: nil,
           request?: false,
           era: :unknown,
           meta: parsed.meta,
           trace_context: Map.get(parsed, :trace_context, %{})
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_modern_request(message, params, meta) do
    with {:ok, parsed} <- Meta.parse_request_meta(meta),
         :ok <- validate_modern_version(parsed.protocol_version) do
      {:ok,
       %__MODULE__{
         method: message["method"],
         request_id: message["id"],
         request?: true,
         era: :modern,
         protocol_version: parsed.protocol_version,
         client_capabilities: parsed.client_capabilities,
         client_info: parsed.client_info,
         log_level: parsed.log_level,
         progress_token: parsed.progress_token,
         input_responses: Map.get(params, "inputResponses"),
         request_state: Map.get(params, "requestState"),
         sealed_request_state: Map.get(params, "requestState"),
         meta: parsed.meta,
         trace_context: parsed.trace_context
       }}
    end
  end

  defp legacy_context(message, params, meta) do
    %__MODULE__{
      method: message["method"],
      request_id: message["id"],
      request?: true,
      era: :legacy,
      protocol_version: Map.get(params, "protocolVersion"),
      progress_token: Map.get(meta, "progressToken"),
      input_responses: Map.get(params, "inputResponses"),
      request_state: Map.get(params, "requestState"),
      sealed_request_state: Map.get(params, "requestState"),
      meta: meta,
      trace_context: Map.take(meta, ~w(traceparent tracestate baggage))
    }
  end

  defp build_legacy_context(message, params, meta) do
    with {:ok, sanitized_meta, trace_context} <- Meta.sanitize_trace_meta(meta) do
      context = legacy_context(message, params, sanitized_meta)
      {:ok, %{context | trace_context: trace_context}}
    end
  end

  defp modern_metadata?(meta) do
    Map.has_key?(meta, Meta.protocol_version_key()) or
      Map.has_key?(meta, Meta.client_capabilities_key())
  end

  defp capabilities_satisfy?(declared, required) do
    Enum.all?(required, fn {key, requirement} ->
      case capability_value(declared, key) do
        {:ok, value} -> capability_value_satisfies?(value, requirement)
        :error -> false
      end
    end)
  end

  defp capability_value_satisfies?(declared, required)
       when is_map(declared) and is_map(required) do
    capabilities_satisfy?(declared, required)
  end

  defp capability_value_satisfies?(declared, required), do: declared == required

  defp capability_value(capabilities, key) do
    case Map.fetch(capabilities, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        Enum.find_value(capabilities, :error, fn {candidate, value} ->
          if to_string(candidate) == to_string(key), do: {:ok, value}, else: false
        end)
    end
  end

  defp validate_modern_version(version) do
    if VersionRegistry.modern?(version),
      do: :ok,
      else: {:error, {:unsupported_protocol_version, version}}
  end

  defp validation_error_data({:missing_meta_field, field}),
    do: %{"reason" => "missing_required_field", "field" => field}

  defp validation_error_data({:invalid_meta_field, field}),
    do: %{"reason" => "invalid_field", "field" => field}

  defp validation_error_data({:invalid_meta_key, key}) when is_binary(key),
    do: %{"reason" => "invalid_key", "key" => key}

  defp validation_error_data({:invalid_meta_key, _key}),
    do: %{"reason" => "invalid_key"}

  defp validation_error_data({:invalid_meta, :not_an_object}),
    do: %{"reason" => "meta_must_be_object"}

  defp validation_error_data(_reason), do: %{"reason" => "invalid_metadata"}

  defp supported_versions(mode)
       when mode in [:legacy_only, :modern_only, :prefer_legacy, :prefer_modern] do
    VersionRegistry.supported_versions(mode)
  end

  defp supported_versions(_mode) do
    VersionRegistry.supported_versions(VersionRegistry.protocol_mode())
  end
end
