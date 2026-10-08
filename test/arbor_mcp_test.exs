defmodule Arbor.MCPTest do
  # Can't be async since we're using real servers
  use ExUnit.Case, async: false

  alias Arbor.MCP.Response
  import Arbor.MCP.TestHelpers

  describe "version and metadata functions" do
    test "protocol_version/0 returns current protocol version" do
      assert Arbor.MCP.protocol_version() == "2025-11-25"
    end

    test "version/0 returns library version" do
      version = Arbor.MCP.version()
      assert is_binary(version)
      assert String.match?(version, ~r/\d+\.\d+\.\d+/)
    end

    test "supported_versions/0 returns list of supported versions" do
      versions = Arbor.MCP.supported_versions()
      assert is_list(versions)
      assert "2025-11-25" in versions
      assert "2025-06-18" in versions
      assert "2025-03-26" in versions
    end

    test "info/0 returns library information" do
      info = Arbor.MCP.info()
      assert %{version: _, protocol_versions: _, transports: _, features: _} = info
      assert is_list(info.transports)
      assert :http in info.transports
      assert :stdio in info.transports
      assert is_list(info.features)
      assert :structured_responses in info.features
    end
  end

  describe "v2 convenience functions with real servers" do
    setup context do
      start_test_servers_for_api(context)
    end

    test "connect/2 with HTTP URL", %{http_url: http_url} do
      assert {:ok, client} = Arbor.MCP.connect(http_url, client_type: :simple, use_sse: false)
      assert is_pid(client)
      Arbor.MCP.disconnect(client)
    end

    test "connect/2 with HTTP URL and v2 client", %{http_url: http_url} do
      assert {:ok, client} = Arbor.MCP.connect(http_url, client_type: :v2, use_sse: false)
      assert is_pid(client)
      Arbor.MCP.disconnect(client)
    end

    test "tools/2 returns actual tool list", %{http_url: http_url} do
      {:ok, client} = Arbor.MCP.connect(http_url, client_type: :simple, use_sse: false)

      assert {:ok, tools} = Arbor.MCP.tools(client)
      assert is_list(tools)

      # Check for our test tools
      tool_names = Enum.map(tools, & &1["name"])
      assert "echo" in tool_names
      assert "add" in tool_names
      assert "greet" in tool_names

      Arbor.MCP.disconnect(client)
    end

    test "call/4 executes tool and normalizes response", %{http_url: http_url} do
      {:ok, client} = Arbor.MCP.connect(http_url, client_type: :simple, use_sse: false)

      assert {:ok, result} = Arbor.MCP.call(client, "echo", %{"message" => "Hello World"})
      assert result == "Echo: Hello World"

      Arbor.MCP.disconnect(client)
    end

    test "call/4 with add tool", %{http_url: http_url} do
      {:ok, client} = Arbor.MCP.connect(http_url, client_type: :simple, use_sse: false)

      assert {:ok, result} = Arbor.MCP.call(client, "add", %{"a" => 5, "b" => 3})
      assert result == "5 + 3 = 8"

      Arbor.MCP.disconnect(client)
    end

    test "call/4 with normalize: false returns raw response", %{http_url: http_url} do
      {:ok, client} = Arbor.MCP.connect(http_url, client_type: :simple, use_sse: false)

      assert {:ok, result} =
               Arbor.MCP.call(client, "echo", %{"message" => "test"}, normalize: false)

      assert %Response{} = result
      assert Response.text_content(result) == "Echo: test"

      Arbor.MCP.disconnect(client)
    end

    test "status/1 returns connection status", %{http_url: http_url} do
      {:ok, client} = Arbor.MCP.connect(http_url, client_type: :simple, use_sse: false)

      {:ok, status} = Arbor.MCP.status(client)
      assert is_map(status)
      assert Map.has_key?(status, :connection_status)

      Arbor.MCP.disconnect(client)
    end

    test "disconnect/1 stops the client", %{http_url: http_url} do
      {:ok, client} = Arbor.MCP.connect(http_url, client_type: :simple, use_sse: false)

      assert :ok = Arbor.MCP.disconnect(client)
      # Give it a moment to stop
      Process.sleep(100)
      refute Process.alive?(client)
    end
  end

  describe "connection specification normalization" do
    setup context do
      start_test_servers_for_api(context)
    end

    test "handles HTTP URLs", %{http_url: http_url} do
      assert {:ok, client1} = Arbor.MCP.connect(http_url, client_type: :simple, use_sse: false)
      Arbor.MCP.disconnect(client1)

      # Test with explicit http:// URL as well
      assert {:ok, client2} = Arbor.MCP.connect(http_url, client_type: :simple, use_sse: false)
      Arbor.MCP.disconnect(client2)
    end

    test "handles transport tuples", %{http_url: http_url} do
      assert {:ok, client} =
               Arbor.MCP.connect({:http, url: http_url}, client_type: :simple, use_sse: false)

      Arbor.MCP.disconnect(client)
    end

    test "client_type option selects appropriate client", %{http_url: http_url} do
      assert {:ok, client1} = Arbor.MCP.connect(http_url, client_type: :simple, use_sse: false)
      assert {:ok, client2} = Arbor.MCP.connect(http_url, client_type: :v2, use_sse: false)
      # Note: convenience client with fallback may not work with our simple test setup

      Arbor.MCP.disconnect(client1)
      Arbor.MCP.disconnect(client2)
    end
  end

  describe "error handling" do
    setup context do
      start_test_servers_for_api(context)
    end

    @tag timeout: 10_000
    test "handles connection errors gracefully" do
      # Try to connect to a non-existent server (use 192.0.2.1 - reserved test address)
      # Note: We need to use a short request_timeout to avoid test timeout
      # Also trap exits to handle the client process dying
      Process.flag(:trap_exit, true)

      result =
        Arbor.MCP.connect("http://192.0.2.1:99999",
          client_type: :simple,
          timeout: 1_000,
          request_timeout: 1_000,
          use_sse: false
        )

      # Handle potential EXIT messages
      receive do
        {:EXIT, _pid, _reason} -> :ok
      after
        500 -> :ok
      end

      assert {:error, _reason} = result
    end

    test "handles invalid tool calls gracefully", %{http_url: http_url} do
      {:ok, client} = Arbor.MCP.connect(http_url, client_type: :simple, use_sse: false)

      # Unknown tool names are a JSON-RPC invalid-params error, not isError.
      result = Arbor.MCP.call(client, "nonexistent_tool", %{})

      case result do
        {:error, %{code: -32602}} ->
          :ok

        {:error, %{"code" => -32602}} ->
          :ok

        {:error, %_{code: -32602}} ->
          :ok

        {:error, error} ->
          code = Map.get(error, :code) || Map.get(error, "code")
          assert code == -32602

        other ->
          flunk("Expected JSON-RPC error -32602, got: #{inspect(other)}")
      end

      Arbor.MCP.disconnect(client)
    end
  end

  describe "server DSL composition" do
    test "allows composing Handler and Server.DSL" do
      code = """
      defmodule TestServerDSLComposition do
        use Arbor.MCP.Server.Handler
        use Arbor.MCP.Server.DSL

        tool "test", "Test tool" do
          input_schema %{type: "object"}
          run fn _args, state -> {:ok, %{content: []}, state} end
        end
      end
      """

      [{module, _}] = Code.compile_string(code)

      assert function_exported?(module, :handle_list_tools, 2)
      assert {:ok, [%{name: "test"}], nil, %{}} = module.handle_list_tools(nil, %{})
    end
  end
end
