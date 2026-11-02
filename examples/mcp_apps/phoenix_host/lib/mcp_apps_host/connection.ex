defmodule McpAppsHost.Connection do
  @moduledoc "The local example's one-server, one-browser connection policy."
  alias Arbor.MCP.{Apps, Client}

  @domains ~w(connectDomains resourceDomains frameDomains baseUriDomains)

  def validate_url(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "http", host: "127.0.0.1", port: port, userinfo: nil, fragment: nil}}
      when port in 1..65_535 ->
        :ok

      _other ->
        {:error, :use_a_literal_loopback_http_server}
    end
  end

  def open do
    url = Application.fetch_env!(:mcp_apps_host, :server_url)

    with :ok <- validate_url(url),
         {:ok, client} <-
           Client.start_link(
             transport: :http,
             url: url,
             protocol_mode: :modern_only,
             capabilities: Apps.put_capability(),
             use_sse: false,
             health_check_interval: nil,
             reconnect: false,
             establish_timeout: 5_000,
             max_response_bytes: 2_097_152
           ) do
      :telemetry.execute([:mcp_apps_host, :client, :opened], %{}, %{client: client})

      case Client.all_tools(client,
             timeout: 5_000,
             max_items: 64,
             max_pages: 8,
             max_bytes: 262_144
           ) do
        {:ok, tools} ->
          {:ok, %{client: client, tools: tools}}

        {:error, reason} ->
          Client.stop(client)
          {:error, reason}
      end
    end
  end

  def model_tools(connection), do: Enum.filter(connection.tools, &Apps.visible_to?(&1, :model))

  def call(connection, name, args, audience) when is_binary(name) and is_map(args) do
    tool = Enum.find(connection.tools, &(&1["name"] == name))

    with true <- tool != nil and Apps.visible_to?(tool, audience),
         {:ok, encoded} <- Jason.encode(args),
         true <- byte_size(encoded) <= 65_536 do
      Client.call_tool(connection.client, name, args, format: :map, timeout: 5_000)
    else
      _denied -> {:error, :tool_not_available}
    end
  end

  def call(_connection, _name, _args, _audience), do: {:error, :invalid_tool_call}

  def uri(tool) do
    case Apps.tool(tool, %{}) do
      {:ok, normalized} -> get_in(normalized, ["_meta", "ui", "resourceUri"])
      _invalid -> nil
    end
  end

  def read(connection, uri) when is_binary(uri) do
    allowed = Enum.any?(connection.tools, &(uri(&1) == uri))

    with true <- allowed,
         {:ok, result} <-
           Client.read_resource(connection.client, uri, format: :map, timeout: 5_000),
         {:ok, document} <- document(result, uri) do
      {:ok, result, document}
    else
      _denied -> {:error, :resource_not_available_in_local_profile}
    end
  end

  def read(_connection, _uri), do: {:error, :invalid_resource}

  def document(%{"contents" => [content]}, uri) when is_map(content) do
    meta = Map.get(content, "_meta", %{})

    with true <- is_map(meta),
         ui = Map.get(meta, "ui", %{}),
         true <- content["uri"] == uri and content["mimeType"] == Apps.mime_type(),
         {:ok, html} <- html(content),
         true <- byte_size(html) <= 1_048_576,
         {:ok, _wire} <- Apps.html(uri, html, ui),
         :ok <- local_policy(ui) do
      {:ok, %{html: html, ui: ui}}
    else
      _unsupported -> {:error, :unsupported_resource}
    end
  end

  def document(_result, _uri), do: {:error, :unsupported_resource}

  def local_policy(ui) when is_map(ui) do
    csp = Map.get(ui, "csp", %{})

    if Map.keys(ui) -- ~w(csp permissions prefersBorder) == [] and
         is_map(csp) and Map.keys(csp) -- @domains == [] and
         Enum.all?(@domains, &(Map.get(csp, &1, []) == [])) and
         Map.get(ui, "permissions", %{}) == %{} do
      :ok
    else
      {:error, :this_example_requires_self_contained_html}
    end
  end

  def local_policy(_ui), do: {:error, :invalid_resource_policy}

  def text(result) do
    result
    |> Map.get("content", [])
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _other -> []
    end)
    |> Enum.join("\n")
  end

  defp html(%{"text" => text} = content) when is_binary(text) do
    if Map.has_key?(content, "blob"), do: {:error, :ambiguous_content}, else: {:ok, text}
  end

  defp html(%{"blob" => blob} = content) when is_binary(blob) do
    if Map.has_key?(content, "text"), do: {:error, :ambiguous_content}, else: Base.decode64(blob)
  end

  defp html(_content), do: {:error, :missing_html}
end
