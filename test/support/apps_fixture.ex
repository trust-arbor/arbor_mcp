defmodule Arbor.MCP.AppsFixture do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime

  @example Path.expand("../../examples/mcp_apps/server.exs", __DIR__)

  defmodule BoundOriginPlug do
    @moduledoc false
    alias Arbor.MCP.HttpPlug

    def init(opts), do: opts

    def call(conn, opts) do
      {ref, opts} = Keyword.pop!(opts, :listener_ref)
      origin = "http://127.0.0.1:#{:ranch.get_port(ref)}"
      HttpPlug.call(conn, HttpPlug.init(Keyword.put(opts, :allowed_origins, [origin])))
    end
  end

  def start(opts \\ []) do
    Code.require_file(@example)

    view =
      Keyword.get(opts, :view_path, Path.expand("../../examples/mcp_apps/view.html", __DIR__))

    runtime =
      ExUnit.Callbacks.start_supervised!(
        {Runtime,
         handler: Arbor.MCP.Examples.McpApps,
         handler_args: [view_path: view],
         execution: :stateful,
         transport: :mounted_http},
        id: make_ref()
      )

    ref = {:apps_fixture, make_ref()}

    {:ok, _listener} =
      Plug.Cowboy.http(
        BoundOriginPlug,
        [runtime: runtime, path: "/mcp", protocol_mode: :prefer_modern, listener_ref: ref],
        ip: {127, 0, 0, 1},
        port: 0,
        ref: ref
      )

    port = :ranch.get_port(ref)
    ExUnit.Callbacks.on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    %{runtime: runtime, endpoint: "http://127.0.0.1:#{port}/mcp"}
  end
end
