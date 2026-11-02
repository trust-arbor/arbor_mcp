defmodule McpAppsHostWeb.Origins do
  def host, do: origin(McpAppsHostWeb.Endpoint)
  def sandbox, do: origin(McpAppsHostWeb.SandboxEndpoint)
  def allowed?(%URI{} = origin), do: URI.to_string(origin) == host()

  defp origin(endpoint) do
    {:ok, {_ip, port}} = endpoint.server_info(:http)
    "http://127.0.0.1:#{port}"
  end
end

defmodule McpAppsHostWeb.Loopback do
  import Plug.Conn
  def init(opts), do: opts

  def call(%{host: "127.0.0.1"} = conn, _opts), do: conn
  def call(conn, _opts), do: conn |> send_resp(400, "Use 127.0.0.1") |> halt()
end

defmodule McpAppsHostWeb.Headers do
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, _opts) do
    host = McpAppsHostWeb.Origins.host()
    sandbox = McpAppsHostWeb.Origins.sandbox()
    websocket = String.replace_prefix(host, "http://", "ws://")

    conn
    |> put_resp_header(
      "content-security-policy",
      "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self' #{websocket}; frame-src #{sandbox}; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
    )
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
  end
end

defmodule McpAppsHostWeb.Sandbox do
  import Plug.Conn
  def init(opts), do: opts

  def call(%{request_path: "/assets/sandbox.js"} = conn, _opts) do
    path = Application.app_dir(:mcp_apps_host, "priv/static/assets/sandbox.js")
    conn |> put_resp_content_type("text/javascript") |> send_file(200, path)
  end

  def call(%{request_path: "/"} = conn, _opts) do
    host = McpAppsHostWeb.Origins.host()

    conn
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; media-src 'self' data:; font-src 'self'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'self'; frame-ancestors #{host}"
    )
    |> put_resp_header(
      "permissions-policy",
      "camera=(), microphone=(), geolocation=(), clipboard-write=()"
    )
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("text/html")
    |> send_resp(
      200,
      "<!doctype html><html><head><meta charset=\"utf-8\"><title>Apps sandbox</title><style>html,body{margin:0;width:100%;height:100%}</style></head><body><script src=\"/assets/sandbox.js\"></script></body></html>"
    )
  end

  def call(conn, _opts), do: send_resp(conn, 404, "Not found")
end

defmodule McpAppsHostWeb.Errors do
  def render(_template, _assigns), do: "The local Apps host could not serve this request."
end
