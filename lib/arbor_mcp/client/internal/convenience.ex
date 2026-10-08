defmodule Arbor.MCP.Client.Internal.Convenience do
  @moduledoc false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Error
  alias Arbor.MCP.Response

  def connect(connection_spec, opts \\ [])

  def connect(%Arbor.MCP.ClientConfig{} = config, opts) do
    # ClientConfig provided - convert to client options and connect
    client_opts = Arbor.MCP.ClientConfig.to_client_opts(config)

    # Merge any additional opts (ignore deprecated client_type option)
    final_opts = Keyword.merge(client_opts, Keyword.drop(opts, [:client_type]))

    Client.start_link(final_opts)
  end

  def connect(connection_spec, opts) when is_list(connection_spec) do
    # 1.x compatibility: a list is accepted but only the first spec is used.
    # This is not a failover.
    case List.first(connection_spec) do
      nil -> {:error, :no_connections_specified}
      first_spec -> connect(first_spec, opts)
    end
  end

  def connect(connection_spec, opts) do
    # Convert connection spec to unified Client format (ignore deprecated client_type)
    client_opts =
      normalize_connection_for_client(connection_spec, Keyword.drop(opts, [:client_type]))

    Client.start_link(client_opts)
  end

  def disconnect(client) do
    case Client.stop(client) do
      {:error, :client_not_alive} -> :ok
      result -> result
    end
  end

  def tools(client, opts \\ []) do
    opts = facade_options!(opts, [:cursor])
    full_result? = Keyword.has_key?(opts, :format)
    request_opts = opts |> Keyword.put_new(:timeout, 5_000) |> Keyword.put_new(:format, :map)

    case Client.list_tools(client, request_opts) do
      {:ok, result} when full_result? ->
        {:ok, result}

      {:ok, result} when is_map(result) ->
        {:ok, Map.get(result, "tools") || Map.get(result, :tools) || []}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, _reason -> {:error, Error.connection_error("Client not responding")}
  end

  def call(client, tool_name, args \\ %{}, opts \\ []) do
    opts = call_options!(opts)
    normalize = Keyword.get(opts, :normalize, not Keyword.has_key?(opts, :format))
    request_opts = opts |> Keyword.delete(:normalize) |> Keyword.put_new(:timeout, 30_000)

    case Client.call_tool(client, tool_name, args, request_opts) do
      {:ok, result} ->
        cond do
          normalize and tool_error?(result) ->
            {:error, %Error.ToolError{tool_name: tool_name, reason: result}}

          normalize ->
            {:ok, extract_tool_result_content(result)}

          true ->
            {:ok, result}
        end

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, _reason -> {:error, Error.connection_error("Client not responding")}
  end

  def resources(client, opts \\ []) do
    opts = facade_options!(opts, [:cursor])
    full_result? = Keyword.has_key?(opts, :format)
    request_opts = opts |> Keyword.put_new(:timeout, 5_000) |> Keyword.put_new(:format, :map)

    case Client.list_resources(client, request_opts) do
      {:ok, result} when full_result? ->
        {:ok, result}

      {:ok, result} when is_map(result) ->
        {:ok, Map.get(result, "resources") || Map.get(result, :resources) || []}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, _reason -> {:error, Error.connection_error("Client not responding")}
  end

  def read(client, uri, opts \\ []) do
    opts = facade_options!(opts, [:parse_json])
    parse_json = Keyword.get(opts, :parse_json, false)
    full_result? = Keyword.has_key?(opts, :format)
    if not is_boolean(parse_json), do: raise(ArgumentError, "parse_json must be a boolean")

    if parse_json and full_result?,
      do: raise(ArgumentError, "parse_json cannot be combined with format")

    request_opts =
      opts
      |> Keyword.delete(:parse_json)
      |> Keyword.put_new(:timeout, 10_000)
      |> Keyword.put_new(:format, :map)

    case Client.read_resource(client, uri, request_opts) do
      {:ok, result} when full_result? -> {:ok, result}
      {:ok, response} -> {:ok, process_read_response(response, parse_json)}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _reason -> {:error, Error.connection_error("Client not responding")}
  end

  defp process_read_response(response, parse_json) when is_map(response) do
    content = extract_resource_content(response)

    if parse_json and is_binary(content) do
      parse_json_content(content)
    else
      content
    end
  end

  defp extract_resource_content(%{"contents" => contents} = response) when is_list(contents) do
    texts =
      for item <- contents,
          is_map(item),
          text = Map.get(item, "text", Map.get(item, :text)),
          is_binary(text),
          do: text

    if texts == [], do: response, else: Enum.join(texts, "\n")
  end

  defp extract_resource_content(%{"content" => content} = response) when is_list(content) do
    texts =
      for item <- content,
          is_map(item),
          Map.get(item, "type", Map.get(item, :type)) == "text",
          text = Map.get(item, "text", Map.get(item, :text)),
          is_binary(text),
          do: text

    if texts == [], do: response, else: Enum.join(texts, "\n")
  end

  defp extract_resource_content(%{"text" => text}) when is_binary(text), do: text
  defp extract_resource_content(response), do: response

  defp tool_error?(%Response{is_error: true}), do: true
  defp tool_error?(%{"isError" => true}), do: true
  defp tool_error?(_result), do: false

  defp facade_options!(opts, extra_keys) do
    Keyword.validate!(
      opts,
      extra_keys ++
        [
          :timeout,
          :format,
          :http_stream_retry,
          :http_stream_retry_delay,
          :retry_safe,
          :retry_policy,
          :max_mrtr_rounds,
          :max_input_requests,
          :max_mrtr_bytes,
          :request_id,
          :server_info
        ]
    )
  end

  defp call_options!(opts) do
    opts =
      facade_options!(opts, [
        :normalize,
        :progress_token,
        :meta,
        :idempotency_key,
        :idempotency_key_path
      ])

    if Keyword.has_key?(opts, :normalize) and not is_boolean(Keyword.fetch!(opts, :normalize)),
      do: raise(ArgumentError, "normalize must be a boolean")

    if Keyword.get(opts, :normalize, false) and Keyword.has_key?(opts, :format),
      do: raise(ArgumentError, "format requires normalize: false")

    opts
  end

  defp parse_json_content(content) do
    case Jason.decode(content) do
      {:ok, parsed} -> parsed
      {:error, _} -> content
    end
  end

  defp extract_tool_result_content(%Response{} = response) do
    # Handle Response struct - use the text_content function
    Response.text_content(response)
  end

  defp extract_tool_result_content(result) when is_map(result) do
    # Try to extract text content from the result
    case result do
      %{"content" => [%{"type" => "text", "text" => text} | _]} ->
        text

      %{"content" => content} when is_list(content) ->
        # Extract all text content
        Enum.map_join(
          Enum.filter(content, &(is_map(&1) and Map.get(&1, "type") == "text")),
          "\n",
          &Map.get(&1, "text")
        )

      _ ->
        # Return the full result if we can't extract text
        result
    end
  end

  defp extract_tool_result_content(result), do: result

  def status(client) do
    Client.get_status(client)
  catch
    :exit, _reason -> {:error, Error.connection_error("Client not responding")}
  end

  def ping(connection_spec, opts \\ []) do
    # Quick connection test using unified client
    case connect(connection_spec, opts) do
      {:ok, client} ->
        result =
          case status(client) do
            {:ok, _} -> :ok
            error -> error
          end

        case disconnect(client) do
          :ok -> result
          {:error, reason} -> {:error, {:cleanup_failed, reason, result}}
        end

      error ->
        error
    end
  end

  defp normalize_connection_for_client(connection_spec, opts) when is_binary(connection_spec) do
    # Parse URL and convert to transport options
    uri = URI.parse(connection_spec)

    transport_opts =
      case uri.scheme do
        "http" -> [transport: :http, url: connection_spec]
        "https" -> [transport: :http, url: connection_spec]
        _ -> [transport: :stdio, command: connection_spec]
      end

    Keyword.merge(transport_opts, opts)
  end

  defp normalize_connection_for_client({transport, transport_opts}, opts) do
    [transport: transport] ++ transport_opts ++ opts
  end

  defp normalize_connection_for_client(connection_spec, opts) do
    # For other formats, pass through
    Keyword.merge([connection: connection_spec], opts)
  end
end
