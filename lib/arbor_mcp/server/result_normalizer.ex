defmodule Arbor.MCP.Server.ResultNormalizer do
  @moduledoc """
  Shared result and error normalization for every server dispatch path.

  `Arbor.MCP.Server.Dispatch` (handler-process transports and stdio),
  the HTTP message processor, and `Arbor.MCP.Protocol.RequestProcessor` (DSL
  servers) all convert handler return
  values into JSON-RPC results. Keeping that conversion here guarantees the
  transports agree on tool-result shape, key stringification and, most
  importantly, on what is safe to send back to a client.

  ## Client-facing error messages

  `error_message/2` never runs `inspect/1` over an arbitrary term into a
  response. Handler-authored detail (a binary reason, or a map/struct with a
  `message` field) is preserved because MCP servers are expected to explain
  themselves; anything else is logged with `Logger.error/1` and replaced by a
  generic message so internal structs, pids, or file paths cannot leak.
  """

  require Logger

  alias Arbor.MCP.Internal.VersionInfo
  alias Arbor.MCP.Protocol.CacheableResult
  alias Arbor.MCP.Protocol.ErrorCodes
  alias Arbor.MCP.Tasks.Extension, as: TasksExtension
  alias Arbor.MCP.Transport.HTTP.ToolHeaders

  @server_info_key "io.modelcontextprotocol/serverInfo"

  @doc """
  Recursively converts atom keys to strings.

  Known MCP protocol fields such as `:input_schema`, `:mime_type` and
  `:is_error` are mapped to their lower-camel-case wire names so raw Handler
  implementations may use idiomatic Elixir keys. A plain map with keys that
  normalize to the same wire key raises a fixed `ArgumentError`, including
  nested maps. Malformed callback results must fail before state commit.
  """
  @spec stringify_keys(term()) :: term()
  def stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)

  def stringify_keys(map) when is_map(map) and not is_struct(map) do
    Enum.reduce(map, %{}, fn {key, value}, normalized ->
      key = if is_atom(key), do: stringify_key(key), else: key

      if Map.has_key?(normalized, key),
        do: raise(ArgumentError, "Conflicting normalized result keys")

      Map.put(normalized, key, stringify_keys(value))
    end)
  end

  def stringify_keys(value), do: value

  @doc """
  Prepares the complete source collection for a modern `tools/list` page.

  Custom handlers that paginate tools must call this function before slicing
  a page or calculating an opaque cursor. It stringifies protocol keys,
  excludes invalid `x-mcp-header` definitions, removes Arbor.MCP-only execution
  metadata, and applies the deterministic modern ordering.

  The normal result path applies the same operation defensively, but at that
  point it cannot repair a cursor that a custom handler calculated from an
  unfiltered collection.
  """
  @spec prepare_tools_list([map()]) :: [map()]
  def prepare_tools_list(tools) when is_list(tools) do
    tools
    |> stringify_keys()
    |> ToolHeaders.filter_valid_tools()
    |> Enum.map(&Map.drop(&1, ["execution"]))
    |> Enum.sort_by(&tool_sort_key/1)
  end

  @doc """
  Applies the result envelope required by the request's protocol era.

  Legacy results are returned unchanged. Modern results receive a
  `resultType` discriminator and result metadata identifying the server.
  Handler-supplied `input_required` (or extension) result types are preserved.
  """
  @spec protocol_result(map(), map(), keyword()) :: map()
  def protocol_result(result, request_context, opts \\ []) when is_map(result) do
    if Map.get(request_context, :era) == :modern do
      result = result |> stringify_keys() |> normalize_tools_list(request_context)
      server_info = Keyword.get(opts, :server_info) || default_server_info()

      result_type =
        result
        |> Map.get("resultType")
        |> normalize_result_type()
        |> normalize_method_result_type(request_context)

      result =
        result
        |> Map.put("resultType", result_type)
        |> normalize_cache_hints(request_context, result_type)

      meta =
        case Map.get(result, "_meta") do
          existing when is_map(existing) -> existing
          _other -> %{}
        end

      result
      |> Map.put("_meta", Map.put(meta, @server_info_key, stringify_keys(server_info)))
    else
      result
    end
  end

  defp normalize_tools_list(%{"tools" => tools} = result, %{method: "tools/list"})
       when is_list(tools) do
    Map.put(result, "tools", prepare_tools_list(tools))
  end

  defp normalize_tools_list(result, _request_context), do: result

  # Tool names are required and unique on the wire. The full tool term is a
  # defensive tie-breaker for malformed/duplicate definitions so even those
  # inputs cannot reintroduce handler iteration order into a modern response.
  defp tool_sort_key(%{"name" => name} = tool) when is_binary(name), do: {0, name, tool}
  defp tool_sort_key(tool), do: {1, "", tool}

  defp normalize_cache_hints(result, %{method: method}, "complete") do
    if CacheableResult.cacheable_method?(method) do
      result
      |> normalize_ttl_ms(method)
      |> normalize_cache_scope(method)
    else
      result
    end
  end

  defp normalize_cache_hints(result, %{method: method}, _result_type) do
    if CacheableResult.cacheable_method?(method) do
      Map.drop(result, ["ttlMs", "cacheScope"])
    else
      result
    end
  end

  defp normalize_cache_hints(result, _request_context, _result_type), do: result

  defp normalize_ttl_ms(%{"ttlMs" => ttl_ms} = result, _method)
       when is_integer(ttl_ms) and ttl_ms >= 0,
       do: result

  defp normalize_ttl_ms(%{"ttlMs" => _invalid} = result, method) do
    Logger.warning("Replacing invalid ttlMs on #{method} with the safe default 0")
    Map.put(result, "ttlMs", 0)
  end

  defp normalize_ttl_ms(result, _method), do: Map.put(result, "ttlMs", 0)

  defp normalize_cache_scope(%{"cacheScope" => scope} = result, _method)
       when scope in ["public", "private"],
       do: result

  defp normalize_cache_scope(%{"cacheScope" => scope} = result, _method)
       when scope in [:public, :private],
       do: Map.put(result, "cacheScope", Atom.to_string(scope))

  defp normalize_cache_scope(%{"cacheScope" => _invalid} = result, method) do
    Logger.warning("Replacing invalid cacheScope on #{method} with the safe default private")
    Map.put(result, "cacheScope", "private")
  end

  defp normalize_cache_scope(result, _method), do: Map.put(result, "cacheScope", "private")

  defp normalize_result_type(type) when is_binary(type) and type != "", do: type

  defp normalize_result_type(type) when is_atom(type) and not is_nil(type),
    do: Atom.to_string(type)

  defp normalize_result_type(_type), do: "complete"

  defp normalize_method_result_type(_result_type, %{method: "tasks/get"}), do: "complete"
  defp normalize_method_result_type(result_type, _request_context), do: result_type

  @doc "Validates that an extension result was enabled by per-request capabilities."
  @spec validate_result_capabilities(map(), map()) ::
          :ok | {:error, Arbor.MCP.Error.ProtocolError.t()}
  def validate_result_capabilities(result, %{era: :modern} = request_context)
      when is_map(result) do
    task_result? =
      normalize_result_type(field(result, "resultType")) == TasksExtension.result_type() or
        Map.get(request_context, :method) == "tasks/get"

    if task_result? do
      if TasksExtension.declared?(Map.get(request_context, :client_capabilities)) do
        validate_task_result(result, request_context)
      else
        {:error,
         Arbor.MCP.Error.missing_required_client_capability(
           TasksExtension.required_capabilities()
         )}
      end
    else
      :ok
    end
  end

  def validate_result_capabilities(_result, _request_context), do: :ok

  defp field(map, "resultType"), do: Map.get(map, "resultType") || Map.get(map, :resultType)

  defp validate_task_result(result, request_context) do
    mode = if Map.get(request_context, :method) == "tasks/get", do: :detailed, else: :create

    case TasksExtension.validate_task_result(result, mode) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Handler returned an invalid Tasks extension result: #{inspect(reason)}")
        {:error, Arbor.MCP.Error.protocol_error(-32603, "Invalid task result")}
    end
  end

  defp default_server_info do
    %{"name" => "Arbor.MCP", "version" => VersionInfo.version()}
  end

  defp stringify_key(:input_schema), do: "inputSchema"
  defp stringify_key(:output_schema), do: "outputSchema"
  defp stringify_key(:mime_type), do: "mimeType"
  defp stringify_key(:uri_template), do: "uriTemplate"
  defp stringify_key(:list_pattern), do: "listPattern"
  defp stringify_key(:is_error), do: "isError"
  defp stringify_key(:is_error?), do: "isError"
  defp stringify_key(:ttl_ms), do: "ttlMs"
  defp stringify_key(:cache_scope), do: "cacheScope"
  defp stringify_key(key), do: Atom.to_string(key)

  @doc """
  Normalizes a `handle_call_tool/3` result into an MCP `tools/call` result.

  Accepts a bare content list, a binary (wrapped as a text content item), or a
  map that already carries `content`.

  ## Options

    * `:wrap_bare_map` - when `true`, a map that carries no `content` key is
      wrapped as `%{"content" => map}` instead of being used as the result
      verbatim. The handler-process transports (`Arbor.MCP.Server.Dispatch`) have
      always done this; the HTTP path has not, and both behaviours are relied
      on by existing servers.
  """
  @spec tool_result(term(), keyword()) :: map()
  def tool_result(result, opts \\ [])

  def tool_result(result, _opts) when is_list(result) do
    %{"content" => stringify_keys(result)}
  end

  def tool_result(result, _opts) when is_binary(result) do
    %{"content" => [%{"type" => "text", "text" => result}]}
  end

  def tool_result(%{content: _content} = result, _opts), do: content_result(result)
  def tool_result(%{"content" => _content} = result, _opts), do: content_result(result)

  def tool_result(result, _opts)
      when is_map(result) and
             (is_map_key(result, "resultType") or is_map_key(result, :resultType)) do
    stringify_keys(result)
  end

  def tool_result(result, opts) when is_map(result) do
    if Keyword.get(opts, :wrap_bare_map, false) do
      %{"content" => stringify_keys(result)}
    else
      stringify_keys(result)
    end
  end

  defp content_result(result) do
    # Normalize before replacing content: deleting the atom key first would
    # erase an atom/string collision before the generic guard could reject it.
    result
    |> stringify_keys()
    |> Map.update!("content", &List.wrap/1)
  end

  @doc """
  Builds an MCP tool result that reports a failure through `isError`.
  """
  @spec tool_error_result(term()) :: map()
  def tool_error_result(reason) do
    text = error_message("Tool execution failed", reason)

    %{
      "content" => [%{"type" => "text", "text" => text}],
      "isError" => true
    }
  end

  @doc """
  Builds a paginated list result such as `%{"tools" => [...], "nextCursor" => ...}`.
  """
  @spec paginated(String.t(), list(), String.t() | nil) :: map()
  def paginated(key, entries, next_cursor \\ nil)
  def paginated(key, entries, nil), do: %{key => entries}
  def paginated(key, entries, next_cursor), do: %{key => entries, "nextCursor" => next_cursor}

  @doc """
  Builds a client-safe error message from a handler error reason.

  Detail that the handler clearly authored (a binary, an atom, or a
  `:message` / `"message"` field) is kept. Everything else is logged and
  omitted from the response.
  """
  @spec error_message(String.t(), term()) :: String.t()
  def error_message(prefix, reason) do
    case client_safe_detail(reason) do
      nil ->
        Logger.error("#{prefix}: #{inspect(reason)}")
        prefix

      detail ->
        "#{prefix}: #{detail}"
    end
  end

  @doc """
  Returns the JSON-RPC error code a handler error reason should map to.

  Cursor complaints map to invalid params (`-32602`); everything else uses
  `default`. Codes embedded in the reason are deliberately *not* honoured:
  handlers have historically returned `%{"code" => ...}` maps whose codes do
  not match the transport-level meaning of the failure.
  """
  @spec error_code(term(), integer()) :: integer()
  def error_code(reason, default \\ -32000)
  def error_code("Invalid cursor" <> _, _default), do: -32602

  def error_code(reason, default) when is_binary(reason) do
    case classify_name_error(reason) do
      {:unknown_name, code} -> code
      :other -> default
    end
  end

  def error_code(_reason, default), do: default

  @doc false
  @spec unknown_name_reason?(term()) :: boolean()
  def unknown_name_reason?(reason) when is_binary(reason) do
    match?({:unknown_name, _}, classify_name_error(reason))
  end

  def unknown_name_reason?(_reason), do: false

  defp classify_name_error(reason) do
    lowered = String.downcase(reason)

    cond do
      String.contains?(lowered, "unknown tool") or
          String.contains?(lowered, "tool not found") ->
        {:unknown_name, -32602}

      String.contains?(lowered, "unknown prompt") or
          String.contains?(lowered, "prompt not found") ->
        {:unknown_name, -32602}

      String.contains?(lowered, "unknown resource") or
          String.contains?(lowered, "resource not found") ->
        {:unknown_name, ErrorCodes.resource_not_found(:modern)}

      true ->
        :other
    end
  end

  defp client_safe_detail(reason) when is_binary(reason), do: reason
  defp client_safe_detail(reason) when is_boolean(reason) or is_nil(reason), do: nil
  defp client_safe_detail(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp client_safe_detail(%{"message" => message}) when is_binary(message), do: message
  defp client_safe_detail(%{message: message}) when is_binary(message), do: message
  defp client_safe_detail(_reason), do: nil
end
