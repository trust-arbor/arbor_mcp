defmodule McpAppsHostWeb.HostLive do
  use Phoenix.LiveView
  alias McpAppsHost.Connection

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        connection: nil,
        tools: [],
        active: nil,
        theme: "light",
        status: "Connecting to the local MCP server…",
        error: nil,
        model_text: "Choose a tool to begin. Only its text content appears here.",
        activity: [],
        server_url: Application.fetch_env!(:mcp_apps_host, :server_url)
      )

    if connected?(socket) do
      case Connection.open() do
        {:ok, connection} ->
          {:ok,
           assign(socket,
             connection: connection,
             tools: Connection.model_tools(connection),
             status: "Connected · MCP 2026-07-28"
           )}

        {:error, _reason} ->
          {:ok,
           assign(socket,
             status: "Server unavailable",
             error: "Start the MCP calculator server, then reload this page."
           )}
      end
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("run_tool", %{"name" => name}, socket) do
    args = if name == "plan", do: %{"seats" => 8, "storageGb" => 100}, else: %{}

    with connection when not is_nil(connection) <- socket.assigns.connection,
         {:ok, result} <- Connection.call(connection, name, args, :model) do
      socket =
        socket
        |> assign(model_text: Connection.text(result), error: nil)
        |> activity("Model → #{name}")

      tool = Enum.find(connection.tools, &(&1["name"] == name))

      case Connection.uri(tool) do
        nil -> {:noreply, socket}
        uri -> mount_app(socket, tool, uri, args, result)
      end
    else
      _error -> {:noreply, assign(socket, error: "The tool call could not complete.")}
    end
  end

  def handle_event("theme", _params, socket) do
    theme = if socket.assigns.theme == "light", do: "dark", else: "light"
    {:noreply, socket |> assign(theme: theme) |> push_event("app:theme", %{theme: theme})}
  end

  def handle_event("close_app", %{"binding" => binding}, socket) do
    if binding == socket.assigns.active do
      {:reply, %{}, socket |> assign(active: nil) |> activity("View closed")}
    else
      {:reply, %{}, socket}
    end
  end

  def handle_event(
        "app_rpc",
        %{"binding" => binding, "operation" => operation, "params" => params},
        socket
      ) do
    with true <- is_binary(binding) and binding == socket.assigns.active,
         true <- is_map(params),
         connection when not is_nil(connection) <- socket.assigns.connection,
         {:ok, result} <- app_request(connection, operation, params) do
      {:reply, %{ok: result}, activity(socket, "View → #{operation}")}
    else
      _denied ->
        {:reply, %{error: "Request is outside this View's connection or capability profile."},
         socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:reply, %{error: "Unsupported event"}, socket}

  defp app_request(connection, "tools/call", params),
    do: Connection.call(connection, params["name"], Map.get(params, "arguments", %{}), :app)

  defp app_request(connection, "resources/read", params) do
    case Connection.read(connection, params["uri"]) do
      {:ok, result, _document} -> {:ok, result}
      error -> error
    end
  end

  defp app_request(_connection, _operation, _params), do: {:error, :unsupported_operation}

  defp mount_app(socket, tool, uri, args, result) do
    case Connection.read(socket.assigns.connection, uri) do
      {:ok, _response, document} ->
        binding = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

        payload = %{
          binding: binding,
          tool: tool,
          html: document.html,
          ui: document.ui,
          args: args,
          result: result,
          theme: socket.assigns.theme,
          sandboxOrigin: McpAppsHostWeb.Origins.sandbox()
        }

        {:noreply,
         socket
         |> assign(active: binding)
         |> push_event("app:mount", payload)
         |> activity("UI resource loaded")}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           error: "This host accepts self-contained HTML with no external domains or permissions."
         )}
    end
  end

  defp activity(socket, message),
    do: assign(socket, :activity, Enum.take([message | socket.assigns.activity], 8))

  @impl true
  def render(assigns) do
    ~H"""
    <div id="apps-studio" phx-hook="AppsHost" data-theme={@theme}>
      <header class="masthead">
        <a href="/" class="wordmark">ARBOR <span>/ APPS STUDIO</span></a>
        <div class="header-actions">
          <span class="local-tag">LOCAL EXAMPLE</span><button
            id="theme-toggle"
            phx-click="theme"
            aria-label="Toggle theme"
          >{if @theme == "light", do: "Dark mode ↗", else: "Light mode ↗"}</button>
        </div>
      </header>
      <main>
        <section class="introduction">
          <div>
            <p class="eyebrow">PHOENIX × MCP APPS</p><h1>
              Tools, with a<br /><em>view of their own.</em>
            </h1>
          </div><p class="intro-note">
            A small host for interactive tools.<br />Phoenix owns the connection.<br />The app gets room to work.
          </p>
        </section>
        <section class="studio-grid">
          <aside class="control-column">
            <section class="connection-card">
              <p class="eyebrow">01 / CONNECTION</p><p
                id="connection-status"
                class="connection-status"
              >
                <span class={if @connection, do: "status-dot connected", else: "status-dot"}></span>{@status}
              </p><code>{@server_url}</code>
            </section>
            <section class="tool-card">
              <p class="eyebrow">02 / MODEL TOOLS</p><p class="section-note">
                Public tools from this connection.
              </p><div class="tool-list">
                <button
                  :for={tool <- @tools}
                  id={"tool-#{tool["name"]}"}
                  class="tool-button"
                  phx-click="run_tool"
                  phx-value-name={tool["name"]}
                ><span><strong>{tool["name"]}</strong><small>{if Connection.uri(tool),
                  do: "Interactive view",
                  else: "Text response"}</small></span><span aria-hidden="true">↗</span></button>
              </div><p class="section-note small-note">View-only tools stay out of this list.</p>
            </section>
            <section class="model-card">
              <p class="eyebrow">03 / MODEL CONTEXT</p><p id="model-context">{@model_text}</p>
            </section>
          </aside>
          <section class="canvas-column">
            <div class="canvas-heading">
              <div>
                <p class="eyebrow">THE APP CANVAS</p><h2>A separate space.</h2>
              </div><button
                id="close-view"
                type="button"
                class="quiet-button"
                disabled={is_nil(@active)}
              >Close view ×</button>
            </div>
            <p :if={@error} id="host-error" class="error" role="alert">{@error}</p>
            <div id="app-canvas" phx-update="ignore">
              <div class="empty-state">
                <span class="empty-mark" aria-hidden="true">↗</span><h3>Make space for a tool.</h3><p>
                  Choose <strong>plan</strong>
                  to open the workspace calculator.<br />Its text result stays alongside the interactive view.
                </p>
              </div>
            </div>
            <div class="canvas-caption">
              <span><span class="tiny-square"></span> ISOLATED VIEW</span><span>Same server. Its own sandbox.</span>
            </div>
            <section class="activity">
              <p class="eyebrow">ACTIVITY</p><ol id="activity">
                <li :for={message <- Enum.reverse(@activity)}>{message}</li>
              </ol>
            </section>
          </section>
        </section>
      </main>
      <footer>
        <span>An ArborMCP example · Phoenix LiveView + official Apps SDK</span><span>Illustrative pricing. Nothing is purchased.</span>
      </footer>
    </div>
    """
  end
end
