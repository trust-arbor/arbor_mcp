defmodule ExMCP.Client.ModernStdioTest do
  use ExUnit.Case, async: false

  alias ExMCP.Client
  alias ExMCP.Client.Subscription
  alias ExMCP.Tasks.Extension

  @fixture Path.expand("../../../priv/test/modern_stdio_server.exs", __DIR__)
  @project_root Path.expand("../../..", __DIR__)

  defmodule Handler do
    @behaviour ExMCP.Client.Handler

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
      send(state.owner, {:stdio_elicitation, message})
      {:ok, %{"action" => "accept", "content" => %{"name" => "Mina"}}, state}
    end
  end

  # The stdio transport isolates the child environment, so forward the parent's
  # Mix paths: a version manager (mise/asdf) child must load the same Hex archive
  # as the parent instead of a stale global one.
  defp mix_child_env do
    [{"MIX_ENV", "test"}] ++
      for name <- ["MIX_HOME", "MIX_ARCHIVES", "MIX_BUILD_PATH", "MIX_DEPS_PATH"],
          value = System.get_env(name),
          do: {name, value}
  end

  test "modern client completes discovery and tool calls over stdio without initialize" do
    mix = System.find_executable("mix") || flunk("mix executable is required")

    {:ok, client} =
      Client.start_link(
        transport: :stdio,
        command: [mix, "run", "--no-compile", "--no-start", @fixture],
        cd: @project_root,
        env: mix_child_env(),
        protocol_mode: :modern_only,
        capabilities: Extension.put_capability(%{"elicitation" => %{"form" => %{}}}),
        handler: {Handler, [owner: self()]},
        era_probe_timeout: 10_000,
        health_check_interval: nil
      )

    on_exit(fn ->
      try do
        Client.disconnect(client)
      catch
        :exit, _reason -> :ok
      end
    end)

    assert {:ok, "2026-07-28"} = Client.negotiated_version(client)

    assert {:ok, %{"name" => "modern-stdio-server", "version" => "1.0.0"}} =
             Client.server_info(client)

    assert {:ok, %{"resultType" => "complete", "tools" => tools}} =
             Client.list_tools(client, format: :map, timeout: 5_000)

    tool = Enum.find(tools, &(&1["name"] == "echo"))
    assert tool["name"] == "echo"

    assert {:ok, result} =
             Client.call_tool(client, "echo", %{"text" => "stdio"},
               format: :map,
               timeout: 5_000
             )

    assert result["resultType"] == "complete"
    assert result["content"] == [%{"type" => "text", "text" => "stdio"}]

    assert {:ok, mrtr_result} =
             Client.call_tool(client, "onboard", %{}, format: :map, timeout: 5_000)

    assert mrtr_result["resultType"] == "complete"
    assert mrtr_result["content"] == [%{"type" => "text", "text" => "Mina:stdio"}]
    assert_receive {:stdio_elicitation, "Choose a stdio display name"}

    assert {:ok, subscription} =
             Client.listen(
               client,
               %{
                 "toolsListChanged" => true,
                 "resourceSubscriptions" => ["test://stdio-resource"]
               },
               timeout: 5_000
             )

    assert {:ok, publish_result} =
             Client.call_tool(
               client,
               "publish_resource_update",
               %{"uri" => "test://stdio-resource"},
               format: :map,
               timeout: 5_000
             )

    assert publish_result["content"] == [%{"type" => "text", "text" => "published"}]

    assert_receive {:ex_mcp_subscription, ^subscription, "notifications/resources/updated",
                    subscription_params}

    assert subscription_params["uri"] == "test://stdio-resource"

    assert {:ok, _publish_result} =
             Client.call_tool(client, "publish_tools_changed", %{},
               format: :map,
               timeout: 5_000
             )

    assert_receive {:ex_mcp_subscription, ^subscription, "notifications/tools/list_changed",
                    tools_params}

    assert tools_params["_meta"]["io.modelcontextprotocol/subscriptionId"] ==
             subscription.request_id

    assert {:ok, task_subscription} =
             Client.listen(client, %{"taskIds" => ["stdio-task"]}, timeout: 5_000)

    assert {:ok, _complete_result} =
             Client.call_tool(client, "complete_task", %{}, format: :map, timeout: 5_000)

    assert_receive {:ex_mcp_subscription, ^task_subscription, "notifications/tasks", task_params}

    assert task_params["taskId"] == "stdio-task"
    assert task_params["status"] == "completed"

    assert task_params["result"] == %{
             "content" => [%{"type" => "text", "text" => "stdio task complete"}]
           }

    assert :ok = Subscription.cancel(subscription)
    assert :ok = Subscription.cancel(task_subscription)
  end
end
