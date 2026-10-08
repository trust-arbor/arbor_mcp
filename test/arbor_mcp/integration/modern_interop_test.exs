defmodule Arbor.MCP.Integration.ModernInteropTest do
  @moduledoc """
  Bidirectional MCP 2026-07-28 interop with the official TypeScript SDK v2.

  The fixtures pin the modern protocol on both sides. These tests must never
  pass by falling back to `initialize` or another legacy protocol revision.
  """

  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.Subscription
  alias Arbor.MCP.ConsentHandler.Test, as: TestConsentHandler
  alias Arbor.MCP.Server.Runtime

  @moduletag :interop
  @moduletag timeout: 90_000

  @protocol_version "2026-07-28"
  @interop_dir Path.expand("../../interop", __DIR__)
  @project_dir Path.expand("../../..", __DIR__)
  @ts_server_script Path.join(@interop_dir, "modern_ts_server.mjs")
  @ts_client_script Path.join(@interop_dir, "modern_ts_client.mjs")
  @ts_http_server_script Path.join(@interop_dir, "modern_ts_http_server.mjs")
  @ts_http_client_script Path.join(@interop_dir, "modern_ts_http_client.mjs")
  @modern_client_package Path.join(@interop_dir, "node_modules/@modelcontextprotocol/client")
  @modern_node_package Path.join(@interop_dir, "node_modules/@modelcontextprotocol/node")
  @modern_server_package Path.join(@interop_dir, "node_modules/@modelcontextprotocol/server")

  defmodule ClientHandler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state), do: {:error, "not configured", state}

    @impl true
    def handle_elicitation_create(message, _schema, state) do
      send(state.owner, {:modern_interop_elicitation, message})
      {:ok, %{"action" => "accept", "content" => %{"name" => "Arbor.MCP Client"}}, state}
    end
  end

  defmodule ModernHTTPHandler do
    use Arbor.MCP.Server.Handler

    use Arbor.MCP.Server.DSL,
      name: "elixir-modern-http-interop-server",
      version: "1.0.0"

    alias Arbor.MCP.Server.{Context, Subscriptions}
    alias Arbor.MCP.Server.DSL.Result, as: DSLResult

    @impl true
    def init(_opts), do: {:ok, %{}}

    tool "echo", "Echoes a message over modern HTTP" do
      param(:message, :string, required: true)

      run(fn %{message: message}, state ->
        {:ok, "Echo: #{message}", state}
      end)
    end

    tool "inspect_context", "Returns the validated request context" do
      run(fn _arguments, state ->
        context = Context.current()

        result = %{
          "protocolVersion" => context.protocol_version,
          "clientInfo" => context.client_info,
          "clientCapabilities" => context.client_capabilities
        }

        {:ok, Jason.encode!(result), state}
      end)
    end

    tool "onboard", "Collects a display name through MRTR over HTTP" do
      run(fn _arguments, state ->
        case Context.input_responses() do
          nil ->
            requests = %{
              "profile" => %{
                "method" => "elicitation/create",
                "params" => %{
                  "message" => "Choose an Arbor.MCP HTTP interop display name",
                  "requestedSchema" => %{
                    "type" => "object",
                    "properties" => %{"name" => %{"type" => "string"}},
                    "required" => ["name"]
                  }
                }
              }
            }

            {:ok, DSLResult.input_required(requests, %{"server" => "ex_mcp_http"}), state}

          %{"profile" => %{"content" => %{"name" => name}}} ->
            {:ok, "#{name}:#{Context.request_state()["server"]}", state}
        end
      end)
    end

    tool "publish_tools_changed", "Publishes a tools list-changed event" do
      run(fn _arguments, state ->
        Subscriptions.publish("notifications/tools/list_changed", %{})

        {:ok, "published", state}
      end)
    end
  end

  setup_all do
    node_path = System.find_executable("node")

    if node_path do
      unless File.dir?(@modern_client_package) and File.dir?(@modern_node_package) and
               File.dir?(@modern_server_package) do
        {output, exit_code} =
          System.cmd("npm", ["install"], cd: @interop_dir, stderr_to_stdout: true)

        assert exit_code == 0,
               "failed to install modern TypeScript interop dependencies: #{output}"
      end

      Application.ensure_all_started(:arbor_mcp)

      unless Process.whereis(TestConsentHandler) do
        TestConsentHandler.start_link()
      end

      user_id = System.get_env("USER") || System.get_env("USERNAME") || "stdio_user"
      Application.put_env(:arbor_mcp, :security, %{consent_handler: TestConsentHandler})
      TestConsentHandler.set_consent_response(user_id, "test://modern-greeting", :approved)

      on_exit(fn -> Application.delete_env(:arbor_mcp, :security) end)
    end

    {:ok, node_path: node_path}
  end

  describe "Arbor.MCP modern client → TypeScript SDK v2 server" do
    @describetag :interop_modern_ex_mcp_client

    test "uses the 2026-07-28 envelope, MRTR, and subscriptions", %{node_path: node_path} do
      require_node!(node_path)

      {:ok, client} =
        Client.start_link(
          transport: :stdio,
          command: [node_path, @ts_server_script],
          cd: @interop_dir,
          protocol_mode: :modern_only,
          capabilities: %{"elicitation" => %{"form" => %{}}},
          handler: {ClientHandler, [owner: self()]},
          era_probe_timeout: 10_000,
          health_check_interval: nil
        )

      on_exit(fn -> disconnect(client) end)

      assert {:ok, @protocol_version} = Client.negotiated_version(client)

      assert {:ok, %{"name" => "ts-modern-interop-server", "version" => "2.0.0"}} =
               Client.server_info(client)

      assert {:ok, tools_result} = Client.list_tools(client, format: :map, timeout: 10_000)
      assert tools_result["resultType"] == "complete"
      assert tools_result["ttlMs"] == 0
      assert tools_result["cacheScope"] == "private"

      assert get_in(tools_result, ["_meta", "io.modelcontextprotocol/serverInfo", "name"]) ==
               "ts-modern-interop-server"

      tool_names = Enum.map(tools_result["tools"], & &1["name"])

      for name <- ["echo", "add", "inspect_context", "onboard", "publish_tools_changed"] do
        assert name in tool_names
      end

      assert {:ok, echo_result} =
               Client.call_tool(client, "echo", %{"text" => "hello from Arbor.MCP"},
                 format: :map,
                 timeout: 10_000
               )

      assert echo_result["resultType"] == "complete"
      assert content_text(echo_result) == "Echo: hello from Arbor.MCP"

      assert {:ok, add_result} =
               Client.call_tool(client, "add", %{"a" => 10, "b" => 20},
                 format: :map,
                 timeout: 10_000
               )

      assert add_result["structuredContent"] == %{"sum" => 30}

      assert {:ok, context_result} =
               Client.call_tool(client, "inspect_context", %{},
                 format: :map,
                 timeout: 10_000
               )

      envelope = context_result["structuredContent"]

      assert envelope["io.modelcontextprotocol/protocolVersion"] == @protocol_version

      assert envelope["io.modelcontextprotocol/clientInfo"]["name"] == "Arbor.MCP"

      assert envelope["io.modelcontextprotocol/clientCapabilities"]["elicitation"] == %{
               "form" => %{}
             }

      assert {:ok, onboard_result} =
               Client.call_tool(client, "onboard", %{}, format: :map, timeout: 10_000)

      assert content_text(onboard_result) == "Arbor.MCP Client:ts-modern-interop"
      assert_receive {:modern_interop_elicitation, "Choose a TypeScript interop display name"}

      assert {:ok, resources_result} =
               Client.list_resources(client, format: :map, timeout: 10_000)

      assert "test://modern-greeting" in Enum.map(resources_result["resources"], & &1["uri"])

      assert {:ok, resource_result} =
               Client.read_resource(client, "test://modern-greeting",
                 format: :map,
                 timeout: 10_000
               )

      assert resource_result["resultType"] == "complete"
      assert hd(resource_result["contents"])["text"] == "Hello from TypeScript MCP 2026-07-28!"

      assert {:ok, prompts_result} = Client.list_prompts(client, format: :map, timeout: 10_000)
      assert "modern_prompt" in Enum.map(prompts_result["prompts"], & &1["name"])

      assert {:ok, prompt_result} =
               Client.get_prompt(client, "modern_prompt", %{"subject" => "interop"},
                 format: :map,
                 timeout: 10_000
               )

      assert hd(prompt_result["messages"])["role"] == "user"

      assert {:ok, subscription} =
               Client.listen(client, %{"toolsListChanged" => true}, timeout: 10_000)

      assert {:ok, _publish_result} =
               Client.call_tool(client, "publish_tools_changed", %{},
                 format: :map,
                 timeout: 10_000
               )

      assert_receive {:ex_mcp_subscription, ^subscription, "notifications/tools/list_changed",
                      notification_params},
                     10_000

      assert notification_params["_meta"]["io.modelcontextprotocol/subscriptionId"] ==
               subscription.request_id

      assert :ok = Subscription.cancel(subscription)
      assert {:ok, _ping_result} = Client.ping(client, timeout: 10_000)
    end
  end

  describe "TypeScript SDK v2 client → Arbor.MCP modern server" do
    @describetag :interop_modern_ts_client

    test "pins 2026-07-28 and completes modern operations", %{node_path: node_path} do
      require_node!(node_path)
      mix_path = System.find_executable("mix") || flunk("mix executable is required")

      {output, exit_code} =
        System.cmd(
          node_path,
          [
            @ts_client_script,
            mix_path,
            "run",
            "--no-compile",
            "--no-deps-check",
            "-e",
            ~s|Mix.Tasks.InteropServer.run(["modern", "--no-compile"])|
          ],
          cd: @project_dir,
          stderr_to_stdout: true,
          env: [{"MIX_ENV", "test"}]
        )

      results = parse_json_result(output)

      assert results["connected"] == true, "TypeScript v2 client did not connect: #{output}"
      assert results["success"] == true, "TypeScript v2 operations failed: #{output}"
      assert results["negotiated_version"] == @protocol_version
      assert results["protocol_era"] == "modern"
      assert results["server_info"]["name"] == "elixir-interop-server"
      assert @protocol_version in results["discovery"]["supportedVersions"]

      for name <- ["echo", "add", "inspect_context", "onboard", "publish_tools_changed"] do
        assert name in results["tools"]
      end

      assert results["echo"] == "Echo: hello from TypeScript v2"
      assert results["add"] == "30"
      assert results["request_context"]["protocolVersion"] == @protocol_version
      assert results["request_context"]["clientInfo"]["name"] == "ts-modern-interop-client"

      assert results["request_context"]["clientCapabilities"]["elicitation"] == %{
               "form" => %{}
             }

      # Continuation data is fixture protocol state, independent of package naming.
      assert results["onboard"] == "TypeScript Client:ex_mcp"
      assert results["elicitation_message"] == "Choose an Arbor.MCP interop display name"
      assert "test://greeting" in results["resources"]
      assert results["resource_text"] == "Hello from Elixir!"
      assert "simple_prompt" in results["prompts"]
      assert "user" in results["prompt_roles"]
      assert results["subscription_filter"] == %{"toolsListChanged" => true}

      assert is_binary(results["tools_changed_meta"]["io.modelcontextprotocol/subscriptionId"])

      assert results["subscription_closed"] == true
      assert @protocol_version in results["rediscovered_versions"]

      assert get_in(results, ["tools_meta", "io.modelcontextprotocol/serverInfo", "name"]) ==
               "elixir-interop-server"

      assert results["tools_cache"] == %{"ttl_ms" => 0, "cache_scope" => "private"}
      assert exit_code == 0, "TypeScript v2 client exited with #{exit_code}: #{output}"
    end
  end

  describe "Arbor.MCP modern HTTP client → TypeScript SDK v2 HTTP server" do
    @describetag :interop_modern_ex_mcp_http_client

    setup %{node_path: node_path} do
      require_node!(node_path)
      {server_port, os_port} = start_node_http_server(node_path)
      on_exit(fn -> close_port(os_port) end)
      {:ok, server_port: server_port}
    end

    test "uses modern headers and a stateless POST-only endpoint", %{server_port: port} do
      url = "http://127.0.0.1:#{port}/mcp"

      {:ok, client} =
        Client.start_link(
          transport: :http,
          url: url,
          protocol_mode: :modern_only,
          protocol_version: @protocol_version,
          capabilities: %{"elicitation" => %{"form" => %{}}},
          handler: {ClientHandler, [owner: self()]},
          use_sse: false,
          health_check_interval: nil,
          request_timeout: 10_000,
          stream_handshake_timeout: 10_000
        )

      on_exit(fn -> disconnect(client) end)

      assert {:ok, @protocol_version} = Client.negotiated_version(client)
      assert {:ok, tools_result} = Client.list_tools(client, format: :map, timeout: 10_000)
      assert tools_result["resultType"] == "complete"
      assert "echo" in Enum.map(tools_result["tools"], & &1["name"])

      assert {:ok, context_result} =
               Client.call_tool(client, "inspect_context", %{},
                 format: :map,
                 timeout: 10_000
               )

      observed = context_result["structuredContent"]
      assert observed["io.modelcontextprotocol/protocolVersion"] == @protocol_version
      assert observed["httpHeaders"]["mcp-protocol-version"] == @protocol_version
      assert observed["httpHeaders"]["mcp-method"] == "tools/call"
      assert observed["httpHeaders"]["mcp-name"] == "inspect_context"
      refute Map.has_key?(observed["httpHeaders"], "mcp-session-id")

      discover_response = raw_discover(url)
      assert discover_response.status == 200
      assert discover_response.body["result"]["resultType"] == "complete"
      refute response_header?(discover_response, "mcp-session-id")

      for method <- [:get, :delete] do
        response = raw_http_request(method, url)
        assert response.status in [400, 405]
        refute response_header?(response, "mcp-session-id")
      end
    end
  end

  describe "TypeScript SDK v2 HTTP client → Arbor.MCP modern HTTP server" do
    @describetag :interop_modern_ts_http_client

    test "uses POST-owned SSE without sessions, GET, or DELETE", %{node_path: node_path} do
      require_node!(node_path)

      runtime =
        start_supervised!(
          {Runtime,
           handler: ModernHTTPHandler, transport: :mounted_http, services: [replay_cache: []]}
        )

      port = free_port()
      ranch_ref = {:modern_http_interop, System.unique_integer([:positive])}

      {:ok, _pid} =
        Plug.Cowboy.http(
          Arbor.MCP.HttpPlug,
          [
            runtime: runtime,
            path: "/mcp",
            protocol_mode: :modern_only,
            server_info: %{
              name: "elixir-modern-http-interop-server",
              version: "1.0.0"
            },
            mrtr: true,
            request_state: [
              active_key_id: "interop-http",
              keys: %{"interop-http" => :binary.copy(<<78>>, 32)}
            ],
            subscription_keepalive_interval_ms: 100,
            subscription_max_lifetime_ms: 30_000,
            allowed_origins: ["http://127.0.0.1:#{port}"]
          ],
          ip: {127, 0, 0, 1},
          port: port,
          ref: ranch_ref
        )

      on_exit(fn -> shutdown_cowboy(ranch_ref) end)

      url = "http://127.0.0.1:#{port}/mcp"

      {output, exit_code} =
        System.cmd(
          node_path,
          [@ts_http_client_script, url],
          cd: @project_dir,
          stderr_to_stdout: true
        )

      results = parse_json_result(output)

      assert results["connected"] == true, "TypeScript HTTP client did not connect: #{output}"
      assert results["success"] == true, "TypeScript HTTP operations failed: #{output}"
      assert results["negotiated_version"] == @protocol_version
      assert results["protocol_era"] == "modern"
      assert results["server_info"]["name"] == "elixir-modern-http-interop-server"
      assert is_nil(results["transport_session_id"])
      assert results["echo"] == "Echo: hello over modern HTTP"
      assert results["request_context"]["protocolVersion"] == @protocol_version

      assert results["request_context"]["clientInfo"]["name"] ==
               "ts-modern-http-interop-client"

      assert results["onboard"] == "TypeScript HTTP Client:ex_mcp_http"
      assert results["subscription_filter"] == %{"toolsListChanged" => true}
      assert results["subscription_closed"] == true

      assert is_binary(results["tools_changed_meta"]["io.modelcontextprotocol/subscriptionId"])

      requests = results["requests"]
      assert requests != []
      assert Enum.all?(requests, &(&1["http_method"] == "POST"))
      assert Enum.all?(requests, &is_nil(&1["request_session_id"]))
      assert Enum.all?(requests, &is_nil(&1["response_session_id"]))

      request_messages = Enum.filter(requests, &(&1["rpc_request"] == true))

      assert Enum.all?(request_messages, fn request ->
               request["protocol_version"] == @protocol_version and
                 request["mcp_method"] == request["rpc_method"]
             end)

      assert Enum.any?(requests, fn request ->
               request["rpc_method"] == "tools/call" and
                 request["rpc_name"] == "inspect_context" and
                 request["mcp_name"] == "inspect_context"
             end)

      assert Enum.any?(requests, fn request ->
               request["rpc_method"] == "subscriptions/listen" and
                 String.starts_with?(request["content_type"] || "", "text/event-stream")
             end)

      assert exit_code == 0, "TypeScript HTTP client exited with #{exit_code}: #{output}"
    end
  end

  defp require_node!(nil), do: flunk("Node.js 20 or later is required for modern interop tests")
  defp require_node!(_node_path), do: :ok

  defp disconnect(client) do
    Client.disconnect(client)
  catch
    :exit, _reason -> :ok
  end

  defp content_text(result) do
    result
    |> Map.get("content", [])
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join(" ", & &1["text"])
  end

  defp parse_json_result(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(%{}, fn line ->
      line = String.trim(line)

      if String.starts_with?(line, "{") do
        case Jason.decode(line) do
          {:ok, result} -> result
          {:error, _reason} -> nil
        end
      end
    end)
  end

  defp start_node_http_server(node_path) do
    os_port =
      Port.open(
        {:spawn_executable, node_path},
        [:binary, :stderr_to_stdout, args: [@ts_http_server_script], cd: @interop_dir]
      )

    {receive_node_port(os_port, "", 15_000), os_port}
  end

  defp receive_node_port(os_port, buffer, timeout) do
    receive do
      {^os_port, {:data, data}} ->
        buffer = buffer <> data

        case Regex.run(~r/PORT:(\d+)/, buffer) do
          [_, port] -> String.to_integer(port)
          nil -> receive_node_port(os_port, buffer, timeout)
        end
    after
      timeout ->
        close_port(os_port)
        flunk("timed out waiting for TypeScript HTTP server: #{inspect(buffer)}")
    end
  end

  defp raw_discover(url) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => "raw-discover",
      "method" => "server/discover",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @protocol_version,
          "io.modelcontextprotocol/clientInfo" => %{
            "name" => "ex_mcp-raw-interop",
            "version" => "1.0.0"
          },
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    raw_http_request(:post, url,
      body: Jason.encode!(request),
      headers: [
        {"accept", "application/json, text/event-stream"},
        {"content-type", "application/json"},
        {"mcp-protocol-version", @protocol_version},
        {"mcp-method", "server/discover"}
      ]
    )
  end

  defp response_header?(response, name) do
    response.headers
    |> Enum.any?(fn {key, _value} -> String.downcase(to_string(key)) == name end)
  end

  defp raw_http_request(method, url, opts \\ []) do
    :inets.start()
    headers = Keyword.get(opts, :headers, [])

    charlist_headers =
      Enum.map(headers, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)

    request =
      case Keyword.get(opts, :body) do
        nil -> {to_charlist(url), charlist_headers}
        body -> {to_charlist(url), charlist_headers, ~c"application/json", body}
      end

    {:ok, {{_http_version, status, _reason}, response_headers, body}} =
      :httpc.request(method, request, [], body_format: :binary)

    decoded_body =
      case Jason.decode(body) do
        {:ok, decoded} -> decoded
        {:error, _reason} -> body
      end

    %{status: status, headers: response_headers, body: decoded_body}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp shutdown_cowboy(ref) do
    Plug.Cowboy.shutdown(ref)
  catch
    :exit, _reason -> :ok
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  catch
    :exit, _reason -> :ok
  end
end
