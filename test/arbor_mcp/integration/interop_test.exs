defmodule Arbor.MCP.Integration.InteropTest do
  @moduledoc """
  Cross-language interop tests between Arbor.MCP and the official TypeScript MCP SDK.

  These tests verify protocol compliance over real stdio transport by:
  1. Arbor.MCP Client → TypeScript MCP Server (ts_server.mjs)
  2. TypeScript MCP Client → Arbor.MCP Server (mix stdio_server)

  Run with: mix test --include interop
  """

  alias Arbor.MCP.ConsentHandler.Test, as: TestConsentHandler

  use ExUnit.Case, async: false

  @moduletag :interop
  @moduletag timeout: 60_000

  @interop_dir Path.expand("../../interop", __DIR__)
  @ts_server_script Path.join(@interop_dir, "ts_server.mjs")
  @ts_client_script Path.join(@interop_dir, "ts_client.mjs")
  @node_modules Path.join(@interop_dir, "node_modules")

  setup_all do
    # Skip if Node.js is not available
    case System.find_executable("node") do
      nil ->
        ExUnit.configure(exclude: [interop: true])
        :ok

      node_path ->
        # Install npm deps if needed
        unless File.dir?(@node_modules) do
          {_, 0} = System.cmd("npm", ["install"], cd: @interop_dir)
        end

        # Ensure Arbor.MCP app is running (ConsentHandler.Test needs it)
        Application.ensure_all_started(:arbor_mcp)

        unless Process.whereis(TestConsentHandler) do
          TestConsentHandler.start_link()
        end

        # Configure security to use the test consent handler and approve test:// URIs
        user_id = System.get_env("USER") || System.get_env("USERNAME") || "stdio_user"
        Application.put_env(:arbor_mcp, :security, %{consent_handler: TestConsentHandler})
        TestConsentHandler.set_consent_response(user_id, "test://greeting", :approved)

        on_exit(fn ->
          Application.delete_env(:arbor_mcp, :security)
        end)

        {:ok, node_path: node_path}
    end
  end

  describe "Arbor.MCP Client → TypeScript Server" do
    @describetag :interop_ex_mcp_client

    test "connects and lists tools", context do
      skip_without_node(context)

      {:ok, client} = start_ts_server_client()

      try do
        {:ok, result} = Arbor.MCP.Client.list_tools(client, timeout: 10_000)
        tools = result["tools"] || result[:tools] || []
        tool_names = Enum.map(tools, fn t -> t["name"] || t[:name] end)

        assert "echo" in tool_names
        assert "add" in tool_names
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end

    test "calls echo tool", context do
      skip_without_node(context)

      {:ok, client} = start_ts_server_client()

      try do
        {:ok, result} =
          Arbor.MCP.Client.call_tool(client, "echo", %{"text" => "hello from Elixir"},
            timeout: 10_000
          )

        content = get_content_text(result)
        assert content =~ "Echo: hello from Elixir"
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end

    test "calls add tool", context do
      skip_without_node(context)

      {:ok, client} = start_ts_server_client()

      try do
        {:ok, result} =
          Arbor.MCP.Client.call_tool(client, "add", %{"a" => 10, "b" => 20}, timeout: 10_000)

        content = get_content_text(result)
        assert content =~ "30"
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end

    test "lists resources", context do
      skip_without_node(context)

      {:ok, client} = start_ts_server_client()

      try do
        {:ok, result} = Arbor.MCP.Client.list_resources(client, timeout: 10_000)
        resources = result["resources"] || result[:resources] || []
        uris = Enum.map(resources, fn r -> r["uri"] || r[:uri] end)

        assert "test://greeting" in uris
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end

    test "reads resource", context do
      skip_without_node(context)

      {:ok, client} = start_ts_server_client()

      try do
        {:ok, result} = Arbor.MCP.Client.read_resource(client, "test://greeting", timeout: 10_000)
        contents = result["contents"] || result[:contents] || []
        text = get_in(hd(contents), ["text"]) || get_in(hd(contents), [:text])

        assert text =~ "Hello from TypeScript!"
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end

    test "lists prompts", context do
      skip_without_node(context)

      {:ok, client} = start_ts_server_client()

      try do
        {:ok, result} = Arbor.MCP.Client.list_prompts(client, timeout: 10_000)
        prompts = result["prompts"] || result[:prompts] || []
        prompt_names = Enum.map(prompts, fn p -> p["name"] || p[:name] end)

        assert "simple_prompt" in prompt_names
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end

    test "gets prompt", context do
      skip_without_node(context)

      {:ok, client} = start_ts_server_client()

      try do
        {:ok, result} = Arbor.MCP.Client.get_prompt(client, "simple_prompt", %{}, timeout: 10_000)
        messages = result["messages"] || result[:messages] || []
        assert length(messages) > 0

        first_message = hd(messages)
        role = first_message["role"] || first_message[:role]
        assert role == "user"
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end

    test "ping succeeds", context do
      skip_without_node(context)

      {:ok, client} = start_ts_server_client()

      try do
        assert {:ok, _} = Arbor.MCP.Client.ping(client, timeout: 10_000)
      after
        Arbor.MCP.Client.disconnect(client)
      end
    end
  end

  describe "TypeScript Client → Arbor.MCP Server" do
    @describetag :interop_ts_client

    test "TS client connects and runs operations against Arbor.MCP server", context do
      skip_without_node(context)

      # The TS client spawns the Arbor.MCP server via stdio
      # We pass the mix command to run the interop_server task
      mix_path = System.find_executable("mix")
      project_dir = Path.expand("../../..", __DIR__)

      {stderr_output, exit_code} =
        System.cmd(
          "node",
          [
            @ts_client_script,
            mix_path,
            "run",
            "--no-compile",
            "--no-deps-check",
            "-e",
            ~s|Mix.Tasks.InteropServer.run(["--no-compile"])|
          ],
          cd: project_dir,
          stderr_to_stdout: true,
          env: [{"MIX_ENV", "test"}]
        )

      # The TS client outputs JSON results
      # Parse the last JSON line from the output
      results = parse_ts_client_results(stderr_output)

      assert results["connected"] == true,
             "TS client failed to connect: #{inspect(results)}"

      assert results["success"] == true,
             "TS client operations failed: #{inspect(results)}"

      # Verify tools were listed
      if results["tools"] do
        assert is_list(results["tools"])
        assert "echo" in results["tools"] or "say_hello" in results["tools"]
      end

      # Verify ping worked
      assert results["ping"] == true || results["ping_error"] == nil

      # Exit code 0 means success
      assert exit_code == 0,
             "TS client exited with code #{exit_code}: #{stderr_output}"
    end
  end

  # --- Helpers ---

  defp skip_without_node(context) do
    unless Map.has_key?(context, :node_path) do
      ExUnit.Assertions.flunk("Node.js not available, skipping interop tests")
    end
  end

  defp start_ts_server_client do
    node_path = System.find_executable("node")

    Arbor.MCP.Client.start_link(
      transport: :stdio,
      command: [node_path, @ts_server_script],
      cd: @interop_dir
    )
  end

  defp get_content_text(result) do
    content = result["content"] || result[:content] || []

    case content do
      items when is_list(items) ->
        Enum.map_join(items, " ", fn item -> item["text"] || item[:text] || "" end)

      _ ->
        to_string(content)
    end
  end

  defp parse_ts_client_results(output) do
    # Find the last JSON line in the output
    output
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find_value(%{}, fn line ->
      line = String.trim(line)

      if String.starts_with?(line, "{") do
        case Jason.decode(line) do
          {:ok, map} -> map
          _ -> nil
        end
      end
    end)
  end
end
