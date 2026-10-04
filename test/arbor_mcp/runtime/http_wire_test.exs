defmodule Arbor.MCP.Server.Runtime.HTTPWireTest do
  use ExUnit.Case, async: false
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.HTTPMountedTest.Handler
  alias Arbor.MCP.Server.Runtime.{HTTPWriterProxy, HTTPWriterRegistry}

  setup do
    for app <- [:inets, :plug_cowboy], do: Application.ensure_all_started(app)
    :ok
  end

  test "physical modern POST reuses root state and GET/DELETE remain stateless405" do
    {runtime, port} = host(:modern_only)
    assert_receive :mounted_init

    for {id, count} <- [{1, 0}, {2, 1}] do
      {200, headers, body} = request(port, :post, modern(id))
      assert Jason.decode!(body)["result"]["structuredContent"]["count"] == count
      refute List.keymember?(headers, ~c"mcp-session-id", 0)
    end

    assert {405, _, _} = request(port, :get, nil)
    assert {405, _, _} = request(port, :delete, nil)
    refute_receive :mounted_init, 5
    settled(runtime)
  end

  test "physical request SSE delivers progress/log/final with actual socket ACKs" do
    {runtime, port} = host(:modern_only)

    value =
      modern(1)
      |> put_in(["params", "name"], "progress")
      |> put_in(["params", "_meta", "progressToken"], "progress")
      |> put_in(["params", "_meta", "io.modelcontextprotocol/logLevel"], "info")

    {200, _, body} = request(port, :post, value, [{~c"accept", ~c"text/event-stream"}])

    frames =
      body
      |> String.split("\r\n\r\n", trim: true)
      |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)

    assert [
             %{"method" => "notifications/progress"},
             %{"method" => "notifications/message"},
             %{"id" => 1, "result" => _}
           ] = frames

    settled(runtime)
  end

  test "physical legacy initialization and complete arrays use root-owned session authority" do
    {runtime, port} = host(:legacy_only, services: [sessions: []])

    init = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "wire", "version" => "1"}
      }
    }

    {200, headers, body} = request(port, :post, init)
    assert Jason.decode!(body)["result"]["protocolVersion"] == "2025-11-25"
    {_, session} = List.keyfind(headers, ~c"mcp-session-id", 0)
    request_headers = [{~c"mcp-session-id", session}, {~c"mcp-protocol-version", ~c"2025-11-25"}]

    members =
      Enum.map([2, 3], fn id ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "method" => "tools/call",
          "params" => %{"name" => "count", "arguments" => %{}}
        }
      end)

    {200, _, body} = request(port, :post, members, request_headers)

    assert [
             %{"id" => 2, "result" => %{"structuredContent" => %{"count" => 0}}},
             %{"id" => 3, "result" => %{"structuredContent" => %{"count" => 1}}}
           ] = Jason.decode!(body)

    settled(runtime)
  end

  test "stopping the runtime leaves its borrowed HTTP host listener alive" do
    {runtime, port} = host(:modern_only)
    assert {200, _, _} = request(port, :post, modern(1))
    assert :ok = Runtime.stop(runtime)
    assert {500, _, _} = request(port, :post, modern(2))
    assert {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1000)
    :gen_tcp.close(socket)
  end

  test "global IO pressure rejects a proposal before state commit and never promises untracked503" do
    {runtime, port} =
      host(:modern_only, max_http_io_frames: 1, request_timeout_ms: 100, output_timeout_ms: 100)

    {:ok, binding} = HTTPWriterProxy.capture(runtime)
    {:ok, held} = HTTPWriterRegistry.prepare(binding, "held")
    assert {500, _, _} = request(port, :post, modern(1))
    :ok = HTTPWriterRegistry.release(held)
    wait(fn -> match?(%{frames: 0}, domain_stats(runtime)) end)
    {200, _, body} = request(port, :post, modern(2))
    assert Jason.decode!(body)["result"]["structuredContent"]["count"] == 0
    settled(runtime)
  end

  defp host(mode, extra \\ []) do
    root =
      start_supervised!(
        {Runtime,
         Keyword.merge(
           [handler: Handler, handler_args: [test: self()], request_timeout_ms: 2000],
           extra
         )}
      )

    {:ok, runtime} = Runtime.ref(root)
    ref = make_ref()

    {:ok, _listener} =
      Plug.Cowboy.http(
        Arbor.MCP.HttpPlug,
        [runtime: runtime, protocol_mode: mode],
        port: 0,
        ip: {127, 0, 0, 1},
        ref: ref
      )

    on_exit(fn -> :ranch.stop_listener(ref) end)
    {{127, 0, 0, 1}, port} = :ranch.get_addr(ref)
    {runtime, port}
  end

  defp request(port, method, value, headers \\ []) do
    url = String.to_charlist("http://127.0.0.1:#{port}/mcp")
    headers = wire_headers(value) ++ headers

    request =
      if method == :post,
        do: {url, headers, ~c"application/json", Jason.encode!(value)},
        else: {url, headers}

    {:ok, {{_, status, _}, headers, body}} =
      :httpc.request(method, request, [timeout: 5000, connect_timeout: 1000],
        body_format: :binary
      )

    {status, headers, body}
  end

  defp wire_headers(
         %{"params" => %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => version}}} =
           value
       ),
       do: [
         {~c"mcp-protocol-version", String.to_charlist(version)},
         {~c"mcp-method", String.to_charlist(value["method"])},
         {~c"mcp-name", String.to_charlist(value["params"]["name"])}
       ]

  defp wire_headers(_legacy), do: []

  defp modern(id),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{
        "name" => "count",
        "arguments" => %{},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

  defp domain_stats(runtime) do
    {:ok, domain} = HTTPWriterProxy.domain(runtime)
    HTTPWriterRegistry.stats(domain)
  end

  defp settled(runtime),
    do:
      wait(fn ->
        match?(%{frames: 0, bytes: 0}, domain_stats(runtime)) and
          match?(%{reserved: 0}, Runtime.stats(runtime))
      end)

  defp wait(fun, attempts \\ 200)
  defp wait(_fun, 0), do: flunk("physical HTTP credit did not settle")

  defp wait(fun, attempts),
    do:
      if(fun.(),
        do: :ok,
        else:
          (
            Process.sleep(5)
            wait(fun, attempts - 1)
          )
      )
end
