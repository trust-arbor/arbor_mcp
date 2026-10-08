defmodule Arbor.MCP.Client.Operations.Tools do
  @moduledoc """
  Tool operations for ArborMCP client.

  This module handles all tool-related operations including listing available tools,
  calling specific tools, and finding tools by name or pattern.
  """

  alias Arbor.MCP.Client.Internal.Request, as: ClientRequest

  alias Arbor.MCP.Client.Types
  alias Arbor.MCP.Error
  alias Arbor.MCP.Internal.RequestParams
  alias Arbor.MCP.Response

  @doc """
  Lists all available tools from the MCP server.

  ## Options

  - `:timeout` - Request timeout (default: 5000)
  - `:format` - Response format (default: :struct)

  ## Examples

      {:ok, tools} = Arbor.MCP.Client.Operations.Tools.list_tools(client)
      {:ok, tools} = Arbor.MCP.Client.Operations.Tools.list_tools(client, timeout: 10_000)
  """
  @spec list_tools(Types.client(), Types.request_opts()) :: Types.mcp_response()
  def list_tools(client, opts \\ []) do
    ClientRequest.make_request(
      client,
      "tools/list",
      RequestParams.cursor_from_opts(opts),
      opts,
      5_000
    )
  end

  @doc """
  Alias for `list_tools/2`.
  """
  @spec tools(Types.client(), Types.request_opts()) :: Types.mcp_response()
  def tools(client, opts \\ []) do
    list_tools(client, opts)
  end

  @doc """
  Calls a tool on the MCP server.

  ## Options

  - `:timeout` - Request timeout (default: 30000)
  - `:format` - Response format (default: :struct)
  - `:progress_token` - Token sent as `_meta.progressToken`, which the server
    handler can use with `Arbor.MCP.Server.Context.report_progress/3`; modern HTTP
    clients receive events through `c:Arbor.MCP.Client.Handler.handle_progress/3`
  - `:meta` - Additional `_meta` entries; merged with `:progress_token`
  - `:http_stream_retry` - `:at_least_once` (default) retries one ambiguous
    modern HTTP response-stream break; `:safe_only` returns
    `:outcome_unknown` for tools unless `:retry_safe` is explicitly `true`
  - `:retry_safe` - Caller attestation that reissuing this operation is safe.
    Tool `readOnlyHint` is intentionally not treated as a security boundary.
  - `:idempotency_key` - Non-empty application key injected into the tool
    arguments once, before any retry. The tool must implement deduplication.
  - `:idempotency_key_path` - String or list path for the injected key
    (default: `["idempotencyKey"]`). If the path already contains a different
    value, the call fails instead of silently changing it.

  ## Examples

      Arbor.MCP.Client.Operations.Tools.call_tool(client, "my_tool", %{arg1: "value"})
      Arbor.MCP.Client.Operations.Tools.call_tool(client, "my_tool", %{arg1: "value"}, timeout: 60_000)

      Arbor.MCP.Client.Operations.Tools.call_tool(client, "slow_tool", %{},
        progress_token: "job-42"
      )

      Arbor.MCP.Client.Operations.Tools.call_tool(client, "charge", %{amount: 100},
        idempotency_key: order_id,
        idempotency_key_path: ["request", "idempotencyKey"]
      )
  """
  @spec call_tool(
          Types.client(),
          Types.tool_name(),
          Types.tool_arguments(),
          Types.request_opts_or_timeout()
        ) :: Types.mcp_response()
  def call_tool(client, tool_name, arguments, timeout_or_opts \\ 30_000)

  def call_tool(client, tool_name, arguments, timeout) when is_integer(timeout) do
    call_tool(client, tool_name, arguments, timeout: timeout)
  end

  def call_tool(client, tool_name, arguments, opts) when is_list(opts) do
    with {:ok, arguments} <- inject_idempotency_key(arguments, opts) do
      do_call_tool(client, tool_name, arguments, opts)
    end
  end

  defp do_call_tool(client, tool_name, arguments, opts) do
    started_at = System.monotonic_time(:millisecond)

    params =
      tool_name
      |> RequestParams.named(arguments)
      |> RequestParams.with_opts_meta(opts)

    # Add tool_name to opts for proper Response struct construction
    enhanced_opts = Keyword.put(opts, :tool_name, tool_name)

    result =
      ClientRequest.make_request(
        client,
        "tools/call",
        params,
        enhanced_opts,
        30_000
      )

    deadline = started_at + Keyword.get(opts, :timeout, 30_000)

    maybe_retry_header_mismatch(
      result,
      client,
      params,
      enhanced_opts,
      deadline
    )
  end

  defp inject_idempotency_key(arguments, opts) do
    case Keyword.get(opts, :idempotency_key) do
      nil ->
        {:ok, arguments}

      key when is_binary(key) and key != "" ->
        case idempotency_key_path(opts) do
          {:ok, path} -> put_stable_key(arguments, path, key)
          {:error, _reason} = error -> error
        end

      invalid ->
        {:error,
         Error.validation_error(
           :idempotency_key,
           invalid,
           "must be a non-empty string"
         )}
    end
  end

  defp idempotency_key_path(opts) do
    case Keyword.get(opts, :idempotency_key_path, ["idempotencyKey"]) do
      path when is_binary(path) and path != "" -> {:ok, [path]}
      path when is_list(path) and path != [] -> validate_key_path(path)
      invalid -> invalid_key_path(invalid)
    end
  end

  defp validate_key_path(path) do
    if Enum.all?(path, &(is_binary(&1) and &1 != "")),
      do: {:ok, path},
      else: invalid_key_path(path)
  end

  defp invalid_key_path(path) do
    {:error,
     Error.validation_error(
       :idempotency_key_path,
       path,
       "must be a non-empty string or a non-empty list of strings"
     )}
  end

  defp put_stable_key(arguments, path, key) when is_map(arguments) do
    do_put_stable_key(arguments, path, key)
  end

  defp put_stable_key(arguments, _path, _key) do
    {:error, Error.validation_error(:arguments, arguments, "tool arguments must be a map")}
  end

  defp do_put_stable_key(map, [segment], value) do
    case semantic_key(map, segment) do
      nil ->
        {:ok, Map.put(map, segment, value)}

      existing_key ->
        if Map.fetch!(map, existing_key) == value do
          {:ok, map}
        else
          {:error,
           Error.validation_error(
             :idempotency_key,
             value,
             "conflicts with the existing value at the configured path"
           )}
        end
    end
  end

  defp do_put_stable_key(map, [segment | rest], value) do
    case semantic_key(map, segment) do
      nil ->
        with {:ok, nested} <- do_put_stable_key(%{}, rest, value) do
          {:ok, Map.put(map, segment, nested)}
        end

      existing_key ->
        case Map.fetch!(map, existing_key) do
          nested when is_map(nested) ->
            with {:ok, nested} <- do_put_stable_key(nested, rest, value) do
              {:ok, Map.put(map, existing_key, nested)}
            end

          existing ->
            {:error,
             Error.validation_error(
               :idempotency_key_path,
               existing,
               "crosses an existing non-object argument"
             )}
        end
    end
  end

  defp semantic_key(map, segment) do
    Enum.find(Map.keys(map), &(to_string(&1) == segment))
  end

  defp maybe_retry_header_mismatch(result, client, params, opts, deadline) do
    if header_mismatch?(result) do
      with {:ok, remaining} <- remaining_timeout(deadline),
           {:ok, _tools} <-
             list_tools(client,
               timeout: remaining,
               format: :map,
               retry_policy: false
             ),
           {:ok, remaining} <- remaining_timeout(deadline) do
        retry_opts =
          opts
          |> Keyword.put(:timeout, remaining)
          |> Keyword.put(:retry_policy, false)

        ClientRequest.make_request(
          client,
          "tools/call",
          params,
          retry_opts,
          30_000
        )
      else
        _refresh_or_timeout_error -> result
      end
    else
      result
    end
  end

  defp header_mismatch?({:error, %Error.ProtocolError{code: -32_020}}), do: true
  defp header_mismatch?({:error, %{"code" => -32_020}}), do: true
  defp header_mismatch?(_result), do: false

  defp remaining_timeout(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> {:ok, remaining}
      _expired -> {:error, :timeout}
    end
  end

  @doc """
  Finds a tool by name or pattern.

  If `name_or_pattern` is nil, it returns the first tool from the list.

  Handles both response formats: the default `:struct` format
  (`%Arbor.MCP.Response{}`) and the raw `:map` format.

  ## Options

  - `:fuzzy` - If true, performs a fuzzy search (default: false)
  - `:timeout` - Request timeout (default: 5000)
  - `:format` - Response format (default: :struct)

  ## Examples

      {:ok, tool} = Arbor.MCP.Client.Operations.Tools.find_tool(client, "my_tool")
      {:ok, tool} = Arbor.MCP.Client.Operations.Tools.find_tool(client, "tool", fuzzy: true)
  """
  @spec find_tool(Types.client(), String.t() | nil, Types.request_opts()) ::
          {:ok, map()} | {:error, :not_found} | {:error, any()}
  def find_tool(client, name_or_pattern \\ nil, opts \\ []) do
    case list_tools(client, opts) do
      {:ok, %Response{tools: tools}} ->
        do_find_matching_tool(List.wrap(tools), name_or_pattern, opts)

      {:ok, %{"tools" => tools}} when is_list(tools) ->
        do_find_matching_tool(tools, name_or_pattern, opts)

      {:ok, %{tools: tools}} when is_list(tools) ->
        do_find_matching_tool(tools, name_or_pattern, opts)

      {:ok, _other} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  # Private helpers

  defp do_find_matching_tool(tools, nil, _opts) do
    case List.first(tools) do
      nil -> {:error, :not_found}
      tool -> {:ok, tool}
    end
  end

  defp do_find_matching_tool(tools, name, opts) do
    fuzzy? = Keyword.get(opts, :fuzzy, false)

    result =
      if fuzzy? do
        Enum.find(tools, fn tool ->
          String.contains?(
            String.downcase(tool_name(tool) || ""),
            String.downcase(name)
          )
        end)
      else
        Enum.find(tools, &(tool_name(&1) == name))
      end

    case result do
      nil -> {:error, :not_found}
      tool -> {:ok, tool}
    end
  end

  # Tool entries carry string keys in :map format and may carry atom keys
  # after struct normalization.
  defp tool_name(%{"name" => name}), do: name
  defp tool_name(%{name: name}), do: name
  defp tool_name(_tool), do: nil
end
