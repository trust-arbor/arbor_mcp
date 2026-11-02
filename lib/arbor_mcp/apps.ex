defmodule Arbor.MCP.Apps do
  @moduledoc """
  Server authoring helpers for MCP Apps (`2026-01-26`).

  Apps associate tools with predeclared `ui://` HTML resources. These helpers
  build ordinary MCP maps for existing Handler/DSL/registration APIs; they do
  not introduce a transport or change ordinary tool dispatch.

      {:ok, tool} = Arbor.MCP.Apps.tool(
        %{"name" => "forecast", "inputSchema" => %{"type" => "object"}},
        %{"resourceUri" => "ui://forecast/view.html"}
      )
      {:ok, resource} = Arbor.MCP.Apps.resource(%{
        "uri" => "ui://forecast/view.html", "name" => "Forecast"
      })
      :ok = Arbor.MCP.Apps.validate_catalog([tool], [resource])
      {:ok, contents} = Arbor.MCP.Apps.html(resource["uri"], "<!doctype html><title>Forecast</title>")

  Use `tools_for_client/2` with the active request's client capabilities to
  advertise UI metadata only to hosts accepting the Apps MIME type. Other
  clients receive model-visible tools without UI metadata. Every tool callback
  must still supply meaningful `content` for text-only use.

  `visible_to?/2` helps a host select model/app tools. It is not authorization:
  the embedding host must bind an app to its originating server connection,
  enforce visibility, sandbox HTML, enforce declared CSP/permissions, keep
  result metadata out of model context, and obtain consent for host actions.
  Browser Views and hosts use the official JavaScript Apps SDK; advertising a
  capability alone does not turn an Elixir MCP client into a rendering host.

  UI maps use the specification's string keys. Unknown UI fields are preserved
  for extensibility; known fields are checked for wire types. HTML helpers do
  not sanitize or parse HTML, fetch assets, or enforce a browser policy. See
  the [Apps guide](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/MCP_APPS.md).
  """

  @identifier "io.modelcontextprotocol/ui"
  @mime_type "text/html;profile=mcp-app"
  @resource_fields ~w(csp permissions domain prefersBorder)
  @csp_fields ~w(connectDomains resourceDomains frameDomains baseUriDomains)
  @permission_fields ~w(camera microphone geolocation clipboardWrite)

  @doc "The registered Apps extension identifier."
  def identifier, do: @identifier

  @doc "The HTML MIME type required by the stable Apps profile."
  def mime_type, do: @mime_type

  @doc "Adds Apps HTML support to an explicit host capability declaration."
  @spec put_capability(map()) :: map()
  def put_capability(capabilities \\ %{}) when is_map(capabilities) do
    extensions = Map.get(capabilities, "extensions", %{})
    extensions = if is_map(extensions), do: extensions, else: %{}
    settings = Map.get(extensions, @identifier, %{})
    settings = if is_map(settings), do: settings, else: %{}
    types = Map.get(settings, "mimeTypes", [])
    types = if is_list(types), do: Enum.filter(types, &is_binary/1), else: []
    settings = Map.put(settings, "mimeTypes", Enum.uniq(types ++ [@mime_type]))
    Map.put(capabilities, "extensions", Map.put(extensions, @identifier, settings))
  end

  @doc "Whether host capabilities explicitly include the Apps HTML MIME type."
  @spec supported?(term()) :: boolean()
  def supported?(%{"extensions" => %{@identifier => %{"mimeTypes" => types}}})
      when is_list(types),
      do: Enum.all?(types, &is_binary/1) and @mime_type in types

  def supported?(_capabilities), do: false

  @doc """
  Adds validated UI metadata to a tool definition, preserving other metadata.

  `resourceUri` is optional for tools called only from a View. Visibility
  defaults to both model and app. A resource URI is also emitted in the
  deprecated `ui/resourceUri` alias for older hosts. Conflicting existing
  aliases are rejected, rather than choosing a different resource silently.
  """
  @spec tool(map(), map()) :: {:ok, map()} | {:error, term()}
  def tool(definition, ui) when is_map(definition) and is_map(ui) do
    with {:ok, meta, existing} <- metadata(definition),
         merged = Map.merge(existing, ui),
         {:ok, normalized} <- normalize_tool_ui(merged, meta) do
      meta = Map.put(meta, "ui", normalized)

      meta =
        if normalized["resourceUri"],
          do: Map.put(meta, "ui/resourceUri", normalized["resourceUri"]),
          else: meta

      {:ok, Map.put(definition, "_meta", meta)}
    end
  end

  def tool(_definition, _ui), do: invalid("tool")

  @doc "Builds a UI resource declaration with the required MIME type."
  @spec resource(map(), map()) :: {:ok, map()} | {:error, term()}
  def resource(definition, ui \\ %{})

  def resource(%{"uri" => uri, "name" => name} = definition, ui) when is_map(ui) do
    with :ok <- uri(uri),
         true <- nonempty?(name),
         :ok <- mime_type(definition),
         {:ok, result} <- resource_metadata(definition, ui) do
      {:ok, Map.put(result, "mimeType", @mime_type)}
    else
      false -> invalid("name")
      error -> error
    end
  end

  def resource(_definition, _ui), do: invalid("resource")

  @doc "Builds a text HTML resource-content item; the caller supplies valid HTML5."
  @spec html(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def html(uri, html, ui \\ %{}) do
    content(uri, "text", html, ui)
  end

  @doc "Builds a base64 HTML resource-content item; the caller supplies valid HTML5 bytes."
  @spec blob(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def blob(uri, encoded, ui \\ %{}) do
    with true <- is_binary(encoded),
         {:ok, html} <- Base.decode64(encoded),
         true <- byte_size(html) > 0 do
      content(uri, "blob", encoded, ui)
    else
      _invalid -> invalid("blob")
    end
  end

  @doc """
  Checks that each tool's UI resource exists in the supplied registered catalog.

  Pass all registered resources, including any intentionally omitted from
  `resources/list`. This is an authoring check; it does not fetch resources or
  prove that a dynamic read callback returns the declared content.
  """
  @spec validate_catalog([map()], [map()]) :: :ok | {:error, term()}
  def validate_catalog(tools, resources) when is_list(tools) and is_list(resources) do
    uris = for %{"uri" => uri} <- resources, do: uri

    Enum.reduce_while(tools, :ok, fn tool, :ok ->
      with {:ok, _meta, ui} <- metadata(tool),
           {:ok, ui} <- normalize_tool_ui(ui, Map.get(tool, "_meta", %{})) do
        if is_nil(ui["resourceUri"]) or ui["resourceUri"] in uris,
          do: {:cont, :ok},
          else: {:halt, {:error, {:missing_ui_resource, ui["resourceUri"]}}}
      else
        error -> {:halt, error}
      end
    end)
  end

  def validate_catalog(_tools, _resources), do: invalid("catalog")

  @doc "Checks declared model/app visibility; malformed declarations fail closed."
  @spec visible_to?(map(), :model | :app) :: boolean()
  def visible_to?(tool, audience) when audience in [:model, :app] do
    with {:ok, meta, ui} <- metadata(tool),
         {:ok, ui} <- normalize_tool_ui(ui, meta) do
      Atom.to_string(audience) in Map.get(ui, "visibility", ["model", "app"])
    else
      _invalid -> false
    end
  end

  def visible_to?(_tool, _audience), do: false

  @doc """
  Selects tool declarations for a host's active capability profile.

  Apps hosts receive all declarations so they can enforce model/app visibility.
  Other clients receive only model-visible tools, with Apps metadata removed.
  Non-UI metadata remains intact. Callback content remains the author's fallback.
  """
  @spec tools_for_client([map()], map()) :: {:ok, [map()]} | {:error, term()}
  def tools_for_client(tools, capabilities) when is_list(tools) do
    Enum.reduce_while(tools, {:ok, []}, fn tool, {:ok, acc} ->
      with {:ok, meta, ui} <- metadata(tool),
           {:ok, _ui} <- normalize_tool_ui(ui, meta) do
        cond do
          supported?(capabilities) -> {:cont, {:ok, [tool | acc]}}
          visible_to?(tool, :model) -> {:cont, {:ok, [without_ui(tool, meta) | acc]}}
          true -> {:cont, {:ok, acc}}
        end
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, selected} -> {:ok, Enum.reverse(selected)}
      error -> error
    end
  end

  def tools_for_client(_tools, _capabilities), do: invalid("tools")

  defp content(uri, key, value, ui) when is_map(ui) do
    with :ok <- uri(uri),
         true <- nonempty?(value) do
      resource_metadata(%{"uri" => uri, "mimeType" => @mime_type, key => value}, ui)
    else
      false -> invalid(key)
      error -> error
    end
  end

  defp content(_uri, _key, _value, _ui), do: invalid("ui")

  defp metadata(definition) when is_map(definition) do
    meta = Map.get(definition, "_meta", %{})

    if is_map(meta) and is_map(Map.get(meta, "ui", %{})),
      do: {:ok, meta, Map.get(meta, "ui", %{})},
      else: invalid("_meta.ui")
  end

  defp metadata(_definition), do: invalid("definition")

  defp normalize_tool_ui(ui, meta) do
    with {:ok, selected} <- tool_resource_uri(ui, meta) do
      cond do
        Enum.any?(@resource_fields, &Map.has_key?(ui, &1)) -> invalid("resource metadata on tool")
        not valid_visibility?(ui) -> invalid("visibility")
        selected -> {:ok, Map.put(ui, "resourceUri", selected)}
        true -> {:ok, ui}
      end
    end
  end

  defp tool_resource_uri(ui, meta) do
    modern = ui["resourceUri"]
    legacy = meta["ui/resourceUri"]

    with :ok <- optional_uri(ui, "resourceUri"),
         :ok <- optional_uri(meta, "ui/resourceUri") do
      if modern && legacy && modern != legacy,
        do: invalid("ui/resourceUri"),
        else: {:ok, modern || legacy}
    end
  end

  defp optional_uri(fields, key) do
    case Map.fetch(fields, key) do
      :error -> :ok
      {:ok, value} -> if nonempty?(value) and uri(value) == :ok, do: :ok, else: invalid(key)
    end
  end

  defp resource_metadata(definition, ui) do
    with {:ok, meta, existing} <- metadata(definition),
         merged = Map.merge(existing, ui),
         :ok <- validate_resource_ui(merged) do
      if map_size(merged) == 0,
        do: {:ok, definition},
        else: {:ok, Map.put(definition, "_meta", Map.put(meta, "ui", merged))}
    end
  end

  defp validate_resource_ui(ui) do
    cond do
      Map.has_key?(ui, "csp") and not valid_csp?(ui["csp"]) ->
        invalid("csp")

      Map.has_key?(ui, "permissions") and not valid_permissions?(ui["permissions"]) ->
        invalid("permissions")

      Map.has_key?(ui, "domain") and not nonempty?(ui["domain"]) ->
        invalid("domain")

      Map.has_key?(ui, "prefersBorder") and not is_boolean(ui["prefersBorder"]) ->
        invalid("prefersBorder")

      true ->
        :ok
    end
  end

  defp valid_visibility?(%{"visibility" => values}) when is_list(values),
    do: Enum.all?(values, &(&1 in ["model", "app"]))

  defp valid_visibility?(ui), do: not Map.has_key?(ui, "visibility")

  defp valid_csp?(csp) when is_map(csp) do
    Enum.all?(@csp_fields, fn field ->
      not Map.has_key?(csp, field) or
        (is_list(csp[field]) and Enum.all?(csp[field], &nonempty?/1))
    end)
  end

  defp valid_csp?(_csp), do: false

  defp valid_permissions?(permissions) when is_map(permissions),
    do:
      Enum.all?(
        @permission_fields,
        &(not Map.has_key?(permissions, &1) or permissions[&1] == %{})
      )

  defp valid_permissions?(_permissions), do: false

  defp mime_type(%{"mimeType" => @mime_type}), do: :ok

  defp mime_type(definition),
    do: if(Map.has_key?(definition, "mimeType"), do: invalid("mimeType"), else: :ok)

  defp uri("ui://" <> rest = value) when byte_size(rest) > 0 do
    case URI.new(value) do
      {:ok, _uri} -> :ok
      _error -> invalid("uri")
    end
  end

  defp uri(_uri), do: invalid("uri")

  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0 and String.valid?(value)

  defp without_ui(tool, meta) do
    cleaned = Map.drop(meta, ["ui", "ui/resourceUri"])

    if map_size(cleaned) == 0,
      do: Map.delete(tool, "_meta"),
      else: Map.put(tool, "_meta", cleaned)
  end

  defp invalid(field), do: {:error, {:invalid_app_field, field}}
end
