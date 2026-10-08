defmodule Arbor.MCP.Client.ToolsHeaderRetryTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client.Operations.Tools

  defmodule FakeClient do
    use GenServer

    def start_link({owner, first_error}),
      do: GenServer.start_link(__MODULE__, {owner, first_error})

    @impl true
    def init({owner, first_error}) do
      {:ok, %{owner: owner, first_error: first_error, tool_calls: 0}}
    end

    @impl true
    def handle_call(:get_default_retry_policy, _from, state), do: {:reply, {:ok, []}, state}
    def handle_call(:get_default_timeout, _from, state), do: {:reply, {:ok, 1_000}, state}

    def handle_call({:request, "tools/call", _params, _meta}, _from, state) do
      attempt = state.tool_calls + 1
      send(state.owner, {:request, "tools/call", attempt})

      if attempt == 1 do
        {:reply, {:error, state.first_error}, %{state | tool_calls: attempt}}
      else
        result = %{"resultType" => "complete", "content" => []}
        {:reply, {:ok, result}, %{state | tool_calls: attempt}}
      end
    end

    def handle_call({:request, "tools/list", _params, _meta}, _from, state) do
      send(state.owner, {:request, "tools/list"})
      {:reply, {:ok, %{"resultType" => "complete", "tools" => []}}, state}
    end
  end

  test "refreshes tools/list and retries one time after HeaderMismatch" do
    {:ok, client} =
      start_supervised({FakeClient, {self(), %{"code" => -32_020, "message" => "mismatch"}}})

    assert {:ok, %{"content" => []}} =
             Tools.call_tool(client, "routed", %{}, timeout: 1_000, format: :map)

    assert_receive {:request, "tools/call", 1}
    assert_receive {:request, "tools/list"}
    assert_receive {:request, "tools/call", 2}
    refute_receive {:request, _method, _attempt}
  end

  test "does not refresh or retry another JSON-RPC error" do
    {:ok, client} =
      start_supervised({FakeClient, {self(), %{"code" => -32_021, "message" => "capability"}}})

    assert {:error, %{"code" => -32_021}} =
             Tools.call_tool(client, "routed", %{}, timeout: 1_000, format: :map)

    assert_receive {:request, "tools/call", 1}
    refute_receive {:request, "tools/list"}
    refute_receive {:request, "tools/call", 2}
  end
end
