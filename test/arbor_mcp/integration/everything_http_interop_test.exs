defmodule Arbor.MCP.Integration.EverythingHTTPInteropTest do
  @moduledoc """
  Cross-language HTTP interop tests between Arbor.MCP and the official MCP "everything" server.

  Tests Arbor.MCP's HTTP transport against @modelcontextprotocol/server-everything,
  the canonical reference implementation that exercises all MCP protocol features.

  The everything server exposes tools (echo, get-sum, etc.), prompts, resources,
  and resource templates over streamable HTTP transport, in both protocol eras.

  Run with: mix test test/arbor_mcp/integration/everything_http_interop_test.exs --include interop
  One era: mix test --only interop_everything_legacy (or interop_everything_modern)
  """

  use ExUnit.Case, async: false

  @moduletag :interop
  @moduletag timeout: 60_000

  defmodule ProgressRecorder do
    @moduledoc false
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}
    @impl true
    def handle_ping(state), do: {:ok, %{}, state}
    @impl true
    def handle_list_roots(state), do: {:ok, [], state}
    @impl true
    def handle_create_message(_params, state), do: {:error, "unused", state}

    @impl true
    def handle_progress(_request_id, params, state) do
      send(state.owner, {:progress, params})
      {:ok, state}
    end
  end

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

  # The same server process serves both eras: 2025-era sessions (initialize,
  # GET stream, DELETE) and session-less 2026-07-28 requests.
  for {era, mode, version} <- [
        {:legacy, :legacy_only, "2025-11-25"},
        {:modern, :modern_only, "2026-07-28"}
      ] do
    describe "Arbor.MCP #{era} client -> Everything Server" do
      @describetag :"interop_everything_#{era}"

      test "connects and settles the #{era} era", %{server_port: port} do
        {:ok, client} = connect_client(port, mode: unquote(mode))

        try do
          assert {:ok, unquote(version)} = Arbor.MCP.Client.negotiated_version(client)
        after
          Arbor.MCP.Client.disconnect(client)
        end
      end

      test "lists tools", %{server_port: port} do
        {:ok, client} = connect_client(port, mode: unquote(mode))

        try do
          {:ok, result} = Arbor.MCP.Client.list_tools(client, timeout: 10_000, format: :map)
          tools = result["tools"] || []
          tool_names = Enum.map(tools, fn t -> t["name"] end)

          # The everything server exposes many tools
          assert "echo" in tool_names
          assert "get-sum" in tool_names
          assert "trigger-long-running-operation" in tool_names
          assert "get-tiny-image" in tool_names
          assert "get-annotated-message" in tool_names
          assert length(tools) >= 10
        after
          Arbor.MCP.Client.disconnect(client)
        end
      end

      test "calls echo tool", %{server_port: port} do
        {:ok, client} = connect_client(port, mode: unquote(mode))

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

      # The server sends each step's progress on the call's POST stream, ahead
      # of the result.
      test "receives a long-running tool's progress while it runs", %{server_port: port} do
        {:ok, client} =
          connect_client(port,
            mode: unquote(mode),
            handler: {ProgressRecorder, [owner: self()]}
          )

        try do
          call =
            Task.async(fn ->
              Arbor.MCP.Client.call_tool(
                client,
                "trigger-long-running-operation",
                %{"duration" => 2, "steps" => 4},
                timeout: 10_000,
                format: :map,
                meta: %{"progressToken" => "long-running"}
              )
            end)

          assert_receive {:progress, %{"progress" => 1, "total" => 4}}, 5_000
          assert Task.yield(call, 0) == nil

          assert {:ok, result} = Task.await(call, 10_000)
          assert get_content_text(result) =~ "Long running operation completed"
          for step <- 2..4, do: assert_received({:progress, %{"progress" => ^step}})
        after
          Arbor.MCP.Client.disconnect(client)
        end
      end

      # Six steps half a second apart: longer than the timeout, but never
      # that long without progress.
      test "progress keeps a long-running call alive past its timeout", %{server_port: port} do
        {:ok, client} =
          connect_client(port,
            mode: unquote(mode),
            handler: {ProgressRecorder, [owner: self()]}
          )

        args = %{"duration" => 3, "steps" => 6}

        try do
          assert {:ok, result} =
                   Arbor.MCP.Client.call_tool(client, "trigger-long-running-operation", args,
                     timeout: 1_000,
                     reset_timeout_on_progress: true,
                     format: :map
                   )

          assert get_content_text(result) =~ "Long running operation completed"

          assert {:error, :timeout} =
                   Arbor.MCP.Client.call_tool(client, "trigger-long-running-operation", args,
                     timeout: 1_000,
                     format: :map
                   )
        after
          Arbor.MCP.Client.disconnect(client)
        end
      end

      test "calls get-sum tool", %{server_port: port} do
        {:ok, client} = connect_client(port, mode: unquote(mode))

        try do
          {:ok, result} =
            Arbor.MCP.Client.call_tool(client, "get-sum", %{"a" => 10, "b" => 32},
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
        {:ok, client} = connect_client(port, mode: unquote(mode))

        try do
          {:ok, result} = Arbor.MCP.Client.list_resources(client, timeout: 10_000, format: :map)
          resources = result["resources"] || []
          uris = Enum.map(resources, fn r -> r["uri"] end)

          # The static resources are the server's own documentation files.
          assert "demo://resource/static/document/architecture.md" in uris
          assert Enum.all?(uris, &String.starts_with?(&1, "demo://resource/static/document/"))
        after
          Arbor.MCP.Client.disconnect(client)
        end
      end

      test "reads a resource", %{server_port: port} do
        {:ok, client} = connect_client(port, mode: unquote(mode))

        try do
          {:ok, result} =
            Arbor.MCP.Client.read_resource(client, "demo://resource/dynamic/text/1",
              timeout: 10_000,
              format: :map
            )

          contents = result["contents"] || []
          assert contents != []

          first = hd(contents)
          assert first["uri"] == "demo://resource/dynamic/text/1"
          assert first["text"] =~ "Resource 1"
        after
          Arbor.MCP.Client.disconnect(client)
        end
      end

      test "lists resource templates", %{server_port: port} do
        {:ok, client} = connect_client(port, mode: unquote(mode))

        try do
          {:ok, result} =
            Arbor.MCP.Client.list_resource_templates(client, timeout: 10_000, format: :map)

          templates = result["resourceTemplates"] || []

          assert %{"name" => "Dynamic Text Resource"} =
                   Enum.find(
                     templates,
                     &(&1["uriTemplate"] == "demo://resource/dynamic/text/{resourceId}")
                   )
        after
          Arbor.MCP.Client.disconnect(client)
        end
      end

      test "lists prompts", %{server_port: port} do
        {:ok, client} = connect_client(port, mode: unquote(mode))

        try do
          {:ok, result} = Arbor.MCP.Client.list_prompts(client, timeout: 10_000, format: :map)
          prompts = result["prompts"] || []
          prompt_names = Enum.map(prompts, fn p -> p["name"] end)

          assert "simple-prompt" in prompt_names
          assert "args-prompt" in prompt_names
          assert "resource-prompt" in prompt_names
          assert length(prompts) >= 3
        after
          Arbor.MCP.Client.disconnect(client)
        end
      end

      test "gets a prompt", %{server_port: port} do
        {:ok, client} = connect_client(port, mode: unquote(mode))

        try do
          {:ok, result} =
            Arbor.MCP.Client.get_prompt(client, "simple-prompt", %{},
              timeout: 10_000,
              format: :map
            )

          messages = result["messages"] || []
          assert messages != []

          first = hd(messages)
          assert first["role"] == "user"
          assert get_in(first, ["content", "text"]) =~ "simple prompt"
        after
          Arbor.MCP.Client.disconnect(client)
        end
      end

      test "ping succeeds", %{server_port: port} do
        {:ok, client} = connect_client(port, mode: unquote(mode))

        try do
          assert {:ok, _} = Arbor.MCP.Client.ping(client, timeout: 10_000)
        after
          Arbor.MCP.Client.disconnect(client)
        end
      end

      test "calls get-annotated-message tool", %{server_port: port} do
        {:ok, client} = connect_client(port, mode: unquote(mode))

        try do
          {:ok, result} =
            Arbor.MCP.Client.call_tool(
              client,
              "get-annotated-message",
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
  end

  # 2026-07-28 has no GET stream, so this is the legacy era only.
  describe "Arbor.MCP legacy client -> Everything Server (SSE GET stream)" do
    @describetag :interop_everything_legacy

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
        {:ok, result} = Arbor.MCP.Client.list_tools(client, timeout: 10_000, format: :map)
        tool_names = Enum.map(result["tools"] || [], fn t -> t["name"] end)

        assert "echo" in tool_names
        assert "get-sum" in tool_names
        assert length(tool_names) >= 10
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end

    test "calls tool via SSE", %{server_port: port} do
      {:ok, client} = connect_client(port, use_sse: true)

      try do
        {:ok, result} =
          Arbor.MCP.Client.call_tool(client, "echo", %{"message" => "hello SSE"},
            timeout: 10_000,
            format: :map
          )

        assert get_content_text(result) =~ "Echo: hello SSE"
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end
  end

  # --- Helpers ---

  defp connect_client(port, opts) do
    use_sse = Keyword.get(opts, :use_sse, false)

    Arbor.MCP.Client.start_link(
      [
        transport: :http,
        url: "http://127.0.0.1:#{port}",
        endpoint: "/mcp",
        use_sse: use_sse,
        protocol_mode: Keyword.get(opts, :mode, :legacy_only),
        timeout: 10_000,
        request_timeout: 10_000,
        stream_handshake_timeout: 10_000
      ] ++ Keyword.take(opts, [:handler])
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
