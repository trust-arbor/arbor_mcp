defmodule Arbor.MCP.Client.LegacyHttpSseTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.ConnectionManager
  alias Arbor.MCP.HttpPlug
  alias Arbor.MCP.Transport.HTTP.LegacySSE

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "legacy-sse", version: "1.0.0"

    tool "echo", "Echo a message" do
      input_schema(%{
        type: "object",
        properties: %{
          message: %{type: "string"}
        },
        required: ["message"]
      })

      run(fn %{"message" => message}, state ->
        {:ok, %{content: [%{"type" => "text", "text" => "Echo: #{message}"}]}, state}
      end)
    end
  end

  defmodule PathRecorder do
    def init(opts) do
      owner = Keyword.fetch!(opts, :owner)
      {owner, HttpPlug.init(Keyword.delete(opts, :owner))}
    end

    def call(conn, {owner, plug_opts}) do
      send(owner, {:http_request, conn.method, conn.request_path})
      HttpPlug.call(conn, plug_opts)
    end
  end

  setup context do
    if context[:transport_config], do: :ok, else: start_listener()
  end

  defp start_listener do
    runtime = Arbor.MCP.Test.RuntimeHTTPFixture.start(Handler, protocol_mode: :legacy_only)
    port = free_port()
    ranch_ref = {:legacy_http_sse_test, System.unique_integer([:positive])}

    {:ok, listener} =
      Plug.Cowboy.http(
        PathRecorder,
        [
          owner: self(),
          runtime: runtime,
          protocol_mode: :legacy_only,
          legacy_http_sse: true,
          sse_mode: :stream,
          path: "/mcp"
        ],
        ip: {127, 0, 0, 1},
        port: port,
        ref: ranch_ref
      )

    on_exit(fn -> stop_listener(listener, ranch_ref, port) end)

    {:ok, port: port, runtime: runtime}
  end

  test "start_link with transport :sse initializes and calls a tool", %{
    port: port,
    runtime: runtime
  } do
    {:ok, client} =
      Client.start_link(
        transport: :sse,
        url: "http://127.0.0.1:#{port}",
        health_check_interval: nil
      )

    on_exit(fn ->
      try do
        if Process.alive?(client), do: Client.disconnect(client)
      catch
        :exit, _reason -> :ok
      end
    end)

    assert_receive {:http_request, "GET", "/sse"}, 2_000
    refute_received {:http_request, "GET", "/mcp"}

    assert {:ok, %{"tools" => tools}} = Client.list_tools(client, format: :map)
    assert Enum.any?(tools, fn tool -> tool["name"] == "echo" end)

    assert {:ok, result} =
             Client.call_tool(client, "echo", %{"message" => "hello"}, format: :map)

    text = result["content"] |> hd() |> Map.get("text")
    assert text == "Echo: hello"

    assert_received {:http_request, "POST", "/message"}
    refute_received {:http_request, "GET", "/mcp"}
    assert_borrowed_listener_survives(runtime, port)
  end

  test "sse_path override hits the configured GET path, not the MCP endpoint", %{runtime: runtime} do
    custom_port = free_port()
    ranch_ref = {:legacy_http_sse_custom, System.unique_integer([:positive])}

    {:ok, listener} =
      Plug.Cowboy.http(
        PathRecorder,
        [
          owner: self(),
          runtime: runtime,
          protocol_mode: :legacy_only,
          legacy_http_sse: true,
          legacy_http_sse_path: "/events",
          legacy_http_sse_post_path: "/inbox",
          sse_mode: :stream,
          path: "/mcp"
        ],
        ip: {127, 0, 0, 1},
        port: custom_port,
        ref: ranch_ref
      )

    on_exit(fn -> stop_listener(listener, ranch_ref, custom_port) end)

    {:ok, client} =
      Client.start_link(
        transport: :sse,
        url: "http://127.0.0.1:#{custom_port}",
        sse_path: "/events",
        health_check_interval: nil
      )

    on_exit(fn ->
      try do
        if Process.alive?(client), do: Client.disconnect(client)
      catch
        :exit, _reason -> :ok
      end
    end)

    assert_receive {:http_request, "GET", "/events"}, 2_000
    refute_received {:http_request, "GET", "/sse"}
    refute_received {:http_request, "GET", "/mcp"}

    assert {:ok, %{"tools" => tools}} = Client.list_tools(client, format: :map)
    assert Enum.any?(tools, fn tool -> tool["name"] == "echo" end)
    assert_received {:http_request, "POST", "/inbox"}
    assert_borrowed_listener_survives(runtime, custom_port)
  end

  @tag :transport_config
  test "transport :sse is wired as LegacySSE and is not use_sse Streamable HTTP" do
    assert {:ok, [transports: [{LegacySSE, opts}]]} =
             ConnectionManager.prepare_transport_config(
               transport: :sse,
               url: "http://127.0.0.1:4000"
             )

    assert opts[:url] == "http://127.0.0.1:4000"
    refute Keyword.get(opts, :use_sse, false)

    assert {:ok, [transports: [{Arbor.MCP.Transport.HTTP, http_opts}]]} =
             ConnectionManager.prepare_transport_config(
               transport: :http,
               url: "http://127.0.0.1:4000/mcp",
               use_sse: true
             )

    assert http_opts[:use_sse] == true
    assert http_opts[:url] == "http://127.0.0.1:4000/mcp"
  end

  defp assert_borrowed_listener_survives(runtime, port) do
    assert :ok = Arbor.MCP.Server.Runtime.stop(runtime)
    assert {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    assert :ok = :gen_tcp.close(socket)
  end

  defp stop_listener(listener, ranch_ref, port) do
    monitor = Process.monitor(listener)
    assert :ok = Plug.Cowboy.shutdown(ranch_ref)
    assert_receive {:DOWN, ^monitor, :process, ^listener, _reason}, 1_000
    assert_refused(port, System.monotonic_time(:millisecond) + 1_000)
  end

  defp assert_refused(port, deadline) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 50) do
      {:error, :econnrefused} ->
        :ok

      other ->
        if match?({:ok, _}, other), do: :gen_tcp.close(elem(other, 1))
        assert System.monotonic_time(:millisecond) < deadline
        Process.sleep(5)
        assert_refused(port, deadline)
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
