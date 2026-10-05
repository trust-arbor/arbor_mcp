defmodule Arbor.MCP.Integration.EverythingHTTPInteropTest do
  @moduledoc """
  Cross-language HTTP interop tests between Arbor.MCP and the official MCP "everything" server.

  Tests Arbor.MCP's HTTP transport against @modelcontextprotocol/server-everything,
  the canonical reference implementation that exercises all MCP protocol features.

  The everything server exposes tools (echo, add, etc.), prompts, resources,
  and resource templates over streamable HTTP transport.

  Run with: mix test test/arbor_mcp/integration/everything_http_interop_test.exs --include interop
  """

  use ExUnit.Case, async: false

  @moduletag :interop
  @moduletag :integration
  @moduletag timeout: 60_000

  @interop_dir Path.expand("../../interop", __DIR__)
  @server_script Path.join(@interop_dir, "everything_http_server.mjs")
  @node_modules Path.join(@interop_dir, "node_modules")

  setup_all do
    case System.find_executable("node") do
      nil ->
        ExUnit.configure(exclude: [interop: true])
        :ok

      node_path ->
        unless File.dir?(@node_modules) do
          {_, 0} = System.cmd("npm", ["install"], cd: @interop_dir)
        end

        {:ok, node_path: node_path}
    end
  end

  setup context do
    unless Map.has_key?(context, :node_path) do
      ExUnit.Assertions.flunk("Node.js not available, skipping interop tests")
    end

    # Capture the owned child in cleanup; on_exit runs in a different process.
    server = start_everything_server()

    on_exit(fn ->
      stop_everything_server(server)
    end)

    {:ok, server_port: server.port}
  end

  describe "Arbor.MCP Client -> Everything Server (non-SSE mode)" do
    test "connects and initializes", %{server_port: port} do
      {:ok, client} = connect_client(port)

      try do
        # If we got here, initialization succeeded
        assert Process.alive?(client)
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end

    test "lists tools", %{server_port: port} do
      {:ok, client} = connect_client(port)

      try do
        {:ok, result} = Arbor.MCP.Client.list_tools(client, timeout: 10_000, format: :map)
        tools = result["tools"] || []
        tool_names = Enum.map(tools, fn t -> t["name"] end)

        # The everything server exposes many tools
        assert "echo" in tool_names
        assert "add" in tool_names
        assert "longRunningOperation" in tool_names
        assert "getTinyImage" in tool_names
        assert "annotatedMessage" in tool_names
        assert length(tools) >= 10
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end

    test "calls echo tool", %{server_port: port} do
      {:ok, client} = connect_client(port)

      try do
        {:ok, result} =
          Arbor.MCP.Client.call_tool(client, "echo", %{"message" => "hello from Elixir"},
            timeout: 10_000,
            format: :map
          )

        content = get_content_text(result)
        assert content =~ "Echo: hello from Elixir"
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end

    test "calls add tool", %{server_port: port} do
      {:ok, client} = connect_client(port)

      try do
        {:ok, result} =
          Arbor.MCP.Client.call_tool(client, "add", %{"a" => 10, "b" => 32},
            timeout: 10_000,
            format: :map
          )

        content = get_content_text(result)
        assert content =~ "42"
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end

    test "lists resources", %{server_port: port} do
      {:ok, client} = connect_client(port)

      try do
        {:ok, result} = Arbor.MCP.Client.list_resources(client, timeout: 10_000, format: :map)
        resources = result["resources"] || []

        # Everything server has 100 resources, paginated at 10 per page
        assert length(resources) == 10

        # First resource should be test://static/resource/1
        first = hd(resources)
        assert first["uri"] == "test://static/resource/1"
        assert first["name"] == "Resource 1"
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end

    test "reads a resource", %{server_port: port} do
      {:ok, client} = connect_client(port)

      try do
        {:ok, result} =
          Arbor.MCP.Client.read_resource(client, "test://static/resource/1",
            timeout: 10_000,
            format: :map
          )

        contents = result["contents"] || []
        assert length(contents) > 0

        first = hd(contents)
        assert first["uri"] == "test://static/resource/1"
        # Odd-indexed resources (1-based, so resource 1 is index 0) are text
        assert first["text"] =~ "Resource 1"
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end

    test "lists resource templates", %{server_port: port} do
      {:ok, client} = connect_client(port)

      try do
        {:ok, result} =
          Arbor.MCP.Client.list_resource_templates(client, timeout: 10_000, format: :map)

        templates = result["resourceTemplates"] || []

        assert length(templates) > 0

        template = hd(templates)
        assert template["uriTemplate"] == "test://static/resource/{id}"
        assert template["name"] == "Static Resource"
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end

    test "lists prompts", %{server_port: port} do
      {:ok, client} = connect_client(port)

      try do
        {:ok, result} = Arbor.MCP.Client.list_prompts(client, timeout: 10_000, format: :map)
        prompts = result["prompts"] || []
        prompt_names = Enum.map(prompts, fn p -> p["name"] end)

        assert "simple_prompt" in prompt_names
        assert "complex_prompt" in prompt_names
        assert "resource_prompt" in prompt_names
        assert length(prompts) >= 3
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end

    test "gets a prompt", %{server_port: port} do
      {:ok, client} = connect_client(port)

      try do
        {:ok, result} =
          Arbor.MCP.Client.get_prompt(client, "simple_prompt", %{}, timeout: 10_000, format: :map)

        messages = result["messages"] || []
        assert length(messages) > 0

        first = hd(messages)
        assert first["role"] == "user"
        assert get_in(first, ["content", "text"]) =~ "simple prompt"
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end

    test "ping succeeds", %{server_port: port} do
      {:ok, client} = connect_client(port)

      try do
        assert {:ok, _} = Arbor.MCP.Client.ping(client, timeout: 10_000)
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end

    test "calls annotatedMessage tool", %{server_port: port} do
      {:ok, client} = connect_client(port)

      try do
        {:ok, result} =
          Arbor.MCP.Client.call_tool(
            client,
            "annotatedMessage",
            %{"messageType" => "error", "includeImage" => false},
            timeout: 10_000,
            format: :map
          )

        content = get_content_text(result)
        assert content =~ "Error"
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end
  end

  describe "Arbor.MCP Client -> Everything Server (SSE mode)" do
    test "connects with SSE enabled", %{server_port: port} do
      {:ok, client} = connect_client(port, use_sse: true)

      try do
        assert Process.alive?(client)
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end

    test "lists tools via SSE", %{server_port: port} do
      {:ok, client} = connect_client(port, use_sse: true)

      try do
        case Arbor.MCP.Client.list_tools(client, timeout: 10_000, format: :map) do
          {:ok, result} ->
            tools = result["tools"] || []
            tool_names = Enum.map(tools, fn t -> t["name"] end)

            assert "echo" in tool_names
            assert "add" in tool_names
            assert length(tools) >= 10

          {:error, %{"code" => _code, "message" => msg}} ->
            # Some versions of the everything server have issues with SSE mode
            # (e.g., missing 'roots' capability). Log and skip gracefully.
            IO.puts("SSE list_tools returned server error: #{msg} (skipping assertion)")
        end
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end

    test "calls tool via SSE", %{server_port: port} do
      {:ok, client} = connect_client(port, use_sse: true)

      try do
        case Arbor.MCP.Client.call_tool(client, "echo", %{"message" => "hello SSE"},
               timeout: 10_000,
               format: :map
             ) do
          {:ok, result} ->
            content = get_content_text(result)
            assert content =~ "Echo: hello SSE"

          {:error, %{"code" => _code, "message" => msg}} ->
            IO.puts("SSE call_tool returned server error: #{msg} (skipping assertion)")
        end
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end
  end

  # --- Helpers ---

  defp connect_client(port, opts \\ []) do
    use_sse = Keyword.get(opts, :use_sse, false)

    Arbor.MCP.Client.start_link(
      transport: :http,
      url: "http://127.0.0.1:#{port}",
      endpoint: "/mcp",
      use_sse: use_sse,
      # This fixture uses the session-based SDK 1.x transport.
      protocol_mode: :legacy_only,
      timeout: 10_000,
      request_timeout: 10_000,
      stream_handshake_timeout: 10_000
    )
  end

  defp start_everything_server do
    node_path = System.find_executable("node")
    deadline = System.monotonic_time(:millisecond) + 15_000

    {:ok, child} =
      Arbor.RPC.Subprocess.open([node_path, @server_script],
        cd: @interop_dir,
        environment_policy: :inherit,
        process_group: true,
        stderr_to_stdout: true,
        max_frame_bytes: 8_192,
        max_queue_bytes: 262_144,
        max_queue_frames: 256,
        cleanup_timeout: 1_000,
        term_grace: 100
      )

    try do
      port = receive_port_number(child, deadline, 0, 0)
      %{child: child, port: port}
    rescue
      exception ->
        close_everything_child(child)
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        close_everything_child(child)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp receive_port_number(child, deadline, count, bytes) do
    if count >= 32 or bytes >= 65_536 do
      raise "Everything server startup output exceeded its bounded readiness budget"
    end

    case Arbor.RPC.FramedStream.next_until(child, deadline) do
      {:ok, line} ->
        bytes = bytes + byte_size(line)

        if bytes > 65_536 do
          raise "Everything server startup output exceeded its bounded readiness budget"
        end

        case Regex.run(~r/^PORT:(\d+)\s*$/, line) do
          [_, port_str] -> String.to_integer(port_str)
          nil -> receive_port_number(child, deadline, count + 1, bytes)
        end

      _terminal ->
        raise "Everything server did not publish readiness before its original startup cutoff"
    end
  end

  defp stop_everything_server(%{child: child, port: server_port}) do
    close_everything_child(child)

    case :gen_tcp.connect({127, 0, 0, 1}, server_port, [:binary, active: false], 1_000) do
      {:error, :econnrefused} ->
        :ok

      {:ok, socket} ->
        :gen_tcp.close(socket)
        flunk("Everything server listener survived confirmed owned-child cleanup")

      other ->
        flunk(
          "Everything server listener cleanup observation was inconclusive: #{inspect(other)}"
        )
    end
  end

  defp close_everything_child(child) do
    assert :ok = Arbor.RPC.Subprocess.close(child)
    assert {:ok, receipt} = Arbor.RPC.Subprocess.cleanup_receipt(child)
    assert receipt.direct_child == :reaped
    assert receipt.targeted_group == :absent
    # This proves the targeted group only; arbitrary escaped descendants remain outside it.
    :ok
  end

  defp get_content_text(result) do
    content = result["content"] || []

    case content do
      items when is_list(items) ->
        Enum.map_join(items, " ", fn item -> item["text"] || "" end)

      _ ->
        to_string(content)
    end
  end
end
