defmodule Arbor.MCP.Protocol.Meta do
  @moduledoc """
  Builds and validates MCP `_meta` objects.

  MCP 2026-07-28 moves protocol version and client capabilities into every
  request. This module owns those reserved fields and the common metadata key
  grammar so outbound and inbound paths cannot drift.
  """

  alias Arbor.MCP.Protocol.TraceContext

  @protocol_version_key "io.modelcontextprotocol/protocolVersion"
  @client_info_key "io.modelcontextprotocol/clientInfo"
  @client_capabilities_key "io.modelcontextprotocol/clientCapabilities"
  @log_level_key "io.modelcontextprotocol/logLevel"
  @server_info_key "io.modelcontextprotocol/serverInfo"
  @subscription_id_key "io.modelcontextprotocol/subscriptionId"
  @log_levels ~w(debug info notice warning error critical alert emergency)

  @label_pattern ~r/^[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/
  @name_pattern ~r/^[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?$/

  @type kind :: :request | :notification | :result
  @type validation_error ::
          {:invalid_meta, :not_an_object}
          | {:invalid_meta_key, term()}
          | {:missing_meta_field, String.t()}
          | {:invalid_meta_field, String.t()}

  @doc "Returns the reserved request protocol-version key."
  @spec protocol_version_key() :: String.t()
  def protocol_version_key, do: @protocol_version_key

  @doc "Returns the reserved per-request client-capabilities key."
  @spec client_capabilities_key() :: String.t()
  def client_capabilities_key, do: @client_capabilities_key

  @doc "Returns whether a metadata key follows the MCP key grammar."
  @spec valid_key?(term()) :: boolean()
  def valid_key?(key) when is_binary(key) do
    case String.split(key, "/", parts: 2) do
      [name] -> valid_name?(name)
      [prefix, name] -> valid_prefix?(prefix) and valid_name?(name)
    end
  end

  def valid_key?(_key), do: false

  @doc "Returns whether a key's prefix is reserved for MCP protocol use."
  @spec reserved_key?(term()) :: boolean()
  def reserved_key?(key) when is_binary(key) do
    case String.split(key, "/", parts: 2) do
      [prefix, _name] ->
        prefix
        |> String.split(".")
        |> Enum.at(1)
        |> then(&(&1 in ["modelcontextprotocol", "mcp"]))

      [_name] ->
        false
    end
  end

  def reserved_key?(_key), do: false

  @doc "Validates the keys of a metadata object."
  @spec validate(map()) :: :ok | {:error, validation_error()}
  def validate(meta) when is_map(meta) do
    case Enum.find(Map.keys(meta), &(not valid_key?(&1))) do
      nil -> :ok
      invalid_key -> {:error, {:invalid_meta_key, invalid_key}}
    end
  end

  def validate(_meta), do: {:error, {:invalid_meta, :not_an_object}}

  @doc """
  Builds the metadata required on a modern request.

  Caller metadata is preserved after key validation. ArborMCP always overwrites
  `protocolVersion`, `clientCapabilities`, and `clientInfo` with the connection
  values supplied here. Optional W3C trace-context fields may be supplied via
  `:trace_context`.
  """
  @spec build_request_meta(map(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, validation_error()}
  def build_request_meta(meta, protocol_version, client_capabilities, opts \\ []) do
    client_info = Keyword.get(opts, :client_info)
    trace_context = Keyword.get(opts, :trace_context, %{})

    with :ok <- validate(meta),
         log_level = Keyword.get(opts, :log_level, Map.get(meta, @log_level_key)),
         :ok <- validate_protocol_version(protocol_version),
         :ok <- validate_object(@client_capabilities_key, client_capabilities),
         :ok <- validate_optional_implementation(@client_info_key, client_info),
         :ok <- validate_optional_log_level(log_level),
         {:ok, trace_context} <- merged_trace_context(meta, trace_context) do
      built =
        meta
        |> Map.drop(TraceContext.keys())
        |> Map.merge(trace_context)
        |> Map.put(@protocol_version_key, protocol_version)
        |> Map.put(@client_capabilities_key, stringify_keys(client_capabilities))
        |> put_optional(@client_info_key, stringify_keys(client_info))
        |> put_optional(@log_level_key, normalize_log_level(log_level))

      {:ok, built}
    end
  end

  @doc "Parses a `_meta` object according to its message kind."
  @spec parse(map() | nil, kind()) :: {:ok, map()} | {:error, validation_error()}
  def parse(meta, :request), do: parse_request_meta(meta)
  def parse(meta, :notification), do: parse_notification_meta(meta)
  def parse(meta, :result), do: parse_result_meta(meta)

  @doc "Parses and validates metadata on a modern request."
  @spec parse_request_meta(map()) :: {:ok, map()} | {:error, validation_error()}
  def parse_request_meta(meta) when is_map(meta) do
    with :ok <- validate(meta),
         {:ok, protocol_version} <- required_binary(meta, @protocol_version_key),
         {:ok, client_capabilities} <- required_object(meta, @client_capabilities_key),
         :ok <-
           validate_optional_implementation(@client_info_key, Map.get(meta, @client_info_key)),
         :ok <- validate_optional_log_level(Map.get(meta, @log_level_key)),
         :ok <- validate_optional_progress_token(Map.get(meta, "progressToken")),
         {:ok, sanitized_meta, trace_context} <- sanitize_trace_meta(meta) do
      {:ok,
       %{
         meta: sanitized_meta,
         protocol_version: protocol_version,
         client_capabilities: client_capabilities,
         client_info: Map.get(meta, @client_info_key),
         log_level: Map.get(meta, @log_level_key),
         progress_token: Map.get(meta, "progressToken"),
         trace_context: trace_context
       }}
    end
  end

  def parse_request_meta(_meta), do: {:error, {:invalid_meta, :not_an_object}}

  @doc "Parses optional notification metadata."
  @spec parse_notification_meta(map() | nil) :: {:ok, map()} | {:error, validation_error()}
  def parse_notification_meta(nil), do: {:ok, %{meta: %{}}}

  def parse_notification_meta(meta) when is_map(meta) do
    with :ok <- validate(meta),
         :ok <- validate_optional_request_id(Map.get(meta, @subscription_id_key)),
         {:ok, sanitized_meta, trace_context} <- sanitize_trace_meta(meta) do
      {:ok,
       %{
         meta: sanitized_meta,
         subscription_id: Map.get(meta, @subscription_id_key),
         trace_context: trace_context
       }}
    end
  end

  def parse_notification_meta(_meta), do: {:error, {:invalid_meta, :not_an_object}}

  @doc "Parses optional result metadata."
  @spec parse_result_meta(map() | nil) :: {:ok, map()} | {:error, validation_error()}
  def parse_result_meta(nil), do: {:ok, %{meta: %{}}}

  def parse_result_meta(meta) when is_map(meta) do
    with :ok <- validate(meta),
         :ok <-
           validate_optional_implementation(@server_info_key, Map.get(meta, @server_info_key)),
         {:ok, sanitized_meta, trace_context} <- sanitize_trace_meta(meta) do
      {:ok,
       %{
         meta: sanitized_meta,
         server_info: Map.get(meta, @server_info_key),
         trace_context: trace_context
       }}
    end
  end

  def parse_result_meta(_meta), do: {:error, {:invalid_meta, :not_an_object}}

  defp valid_prefix?(prefix) do
    labels = String.split(prefix, ".", trim: false)
    labels != [] and Enum.all?(labels, &Regex.match?(@label_pattern, &1))
  end

  defp valid_name?(""), do: true
  defp valid_name?(name), do: Regex.match?(@name_pattern, name)

  defp validate_protocol_version(version) when is_binary(version) and version != "", do: :ok

  defp validate_protocol_version(_version),
    do: {:error, {:invalid_meta_field, @protocol_version_key}}

  defp required_binary(meta, key) do
    case Map.fetch(meta, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_meta_field, key}}
      :error -> {:error, {:missing_meta_field, key}}
    end
  end

  defp required_object(meta, key) do
    case Map.fetch(meta, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_meta_field, key}}
      :error -> {:error, {:missing_meta_field, key}}
    end
  end

  defp validate_object(_key, value) when is_map(value), do: :ok
  defp validate_object(key, _value), do: {:error, {:invalid_meta_field, key}}

  defp validate_optional_implementation(_key, nil), do: :ok

  defp validate_optional_implementation(key, implementation) when is_map(implementation) do
    implementation = stringify_keys(implementation)

    if is_binary(implementation["name"]) and implementation["name"] != "" and
         is_binary(implementation["version"]) and implementation["version"] != "" do
      :ok
    else
      {:error, {:invalid_meta_field, key}}
    end
  end

  defp validate_optional_implementation(key, _value),
    do: {:error, {:invalid_meta_field, key}}

  defp validate_optional_log_level(nil), do: :ok

  defp validate_optional_log_level(level) when is_atom(level),
    do: validate_optional_log_level(Atom.to_string(level))

  defp validate_optional_log_level(level) when level in @log_levels, do: :ok
  defp validate_optional_log_level(_level), do: {:error, {:invalid_meta_field, @log_level_key}}

  defp validate_optional_progress_token(nil), do: :ok

  defp validate_optional_progress_token(token) when is_binary(token) or is_integer(token),
    do: :ok

  defp validate_optional_progress_token(_token),
    do: {:error, {:invalid_meta_field, "progressToken"}}

  defp validate_optional_request_id(nil), do: :ok
  defp validate_optional_request_id(id) when is_binary(id) or is_integer(id), do: :ok

  defp validate_optional_request_id(_id),
    do: {:error, {:invalid_meta_field, @subscription_id_key}}

  @doc false
  @spec sanitize_trace_meta(map()) ::
          {:ok, map(), map()} | {:error, validation_error()}
  def sanitize_trace_meta(meta) when is_map(meta) do
    case TraceContext.normalize(Map.take(meta, TraceContext.keys())) do
      {:ok, trace_context} ->
        sanitized_meta =
          meta
          |> Map.drop(TraceContext.keys())
          |> Map.merge(trace_context)

        {:ok, sanitized_meta, trace_context}

      {:error, key} ->
        {:error, {:invalid_meta_field, key}}
    end
  end

  def sanitize_trace_meta(_meta), do: {:error, {:invalid_meta, :not_an_object}}

  defp merged_trace_context(meta, trace_context) when is_map(trace_context) do
    from_meta = Map.take(meta, TraceContext.keys())

    with {:ok, trace_context} <- TraceContext.select(trace_context),
         {:ok, normalized} <- TraceContext.normalize(Map.merge(from_meta, trace_context)) do
      {:ok, normalized}
    else
      {:error, key} -> {:error, {:invalid_meta_field, key}}
    end
  end

  defp merged_trace_context(_meta, _trace_context),
    do: {:error, {:invalid_meta_field, "trace-context"}}

  defp normalize_log_level(nil), do: nil
  defp normalize_log_level(level) when is_atom(level), do: Atom.to_string(level)
  defp normalize_log_level(level), do: level

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(nil), do: nil
  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)

  defp stringify_keys(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(value), do: value
end
