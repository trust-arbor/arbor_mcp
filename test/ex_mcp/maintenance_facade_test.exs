defmodule ExMCP.MaintenanceFacadeTest do
  use ExUnit.Case, async: true
  alias ExMCP.Response

  defmodule Peer do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    @impl true
    def init(opts), do: {:ok, Map.new(opts)}
    @impl true
    def handle_call({:request, method, params, control}, _from, state) do
      send(state.owner, {:request, method, params, control})
      {:reply, state.reply, state}
    end

    def handle_call(:conformance_mode?, _from, state) do
      send(state.owner, :conformance_checked)
      {:reply, false, state}
    end

    def handle_call(:get_default_retry_policy, _from, state), do: {:reply, {:ok, []}, state}
    def handle_call(:get_default_timeout, _from, state), do: {:reply, {:ok, 5_000}, state}
    @impl true
    def handle_cast({:cancel_mrtr_scope, _scope}, state), do: {:noreply, state}
  end

  test "read extracts standard string and BEAM contents with the existing JSON option" do
    for raw <- [
          %{"contents" => [%{"uri" => "file:///data", "text" => "{\"ready\":true}"}]},
          %{contents: [%{uri: "file:///data", text: "{\"ready\":true}"}]}
        ] do
      client = peer({:ok, raw})
      assert {:ok, "{\"ready\":true}"} = ExMCP.read(client, "file:///data")
      assert {:ok, %{"ready" => true}} = ExMCP.read(client, "file:///data", parse_json: true)
      assert_receive {:request, "resources/read", %{"uri" => "file:///data"}, _}
    end
  end

  test "read retains legacy content extraction and nil for a nontext resource" do
    raw = %{"content" => [%{"type" => "text", "text" => "legacy"}]}
    assert {:ok, "legacy"} = ExMCP.read(peer({:ok, raw}), "file:///legacy")
    blob = %{"contents" => [%{"uri" => "file:///image", "blob" => "AAAA"}]}
    assert {:ok, nil} = ExMCP.read(peer({:ok, blob}), "file:///image")
  end

  test "call retains first-text normalization, struct defaults and error-result behaviour" do
    raw = %{
      "content" => [%{type: "text", text: "first"}, %{type: "text", text: "second"}],
      "isError" => true
    }

    client = peer({:ok, raw})
    assert {:ok, "first"} = ExMCP.call(client, "echo")

    assert {:ok, %Response{is_error: true} = response} =
             ExMCP.call(client, "echo", %{}, normalize: false)

    assert Response.text_content(response) == "first"
    # Tool errors remain successful protocol results in 1.x, rather than the v2 ToolError facade.
  end

  test "list facade methods keep returning lists rather than complete pages" do
    assert {:ok, [%{"name" => "echo"}]} =
             ExMCP.tools(peer({:ok, %{"tools" => [%{"name" => "echo"}], "nextCursor" => "next"}}))

    assert {:ok, [%{uri: "file:///data"}]} =
             ExMCP.resources(
               peer({:ok, %{resources: [%{uri: "file:///data"}], nextCursor: "next"}})
             )
  end

  defp peer(reply), do: start_supervised!({Peer, owner: self(), reply: reply}, id: make_ref())
end
