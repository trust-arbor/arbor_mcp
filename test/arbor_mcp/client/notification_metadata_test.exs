defmodule Arbor.MCP.Client.NotificationMetadataTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Arbor.MCP.Client.RequestHandler
  alias Arbor.MCP.Protocol.Meta
  alias Arbor.MCP.Transport.HTTP
  alias Arbor.MCP.Transport.HTTP.RequestHeaders

  defmodule CaptureTransport do
    def send_message(message, %{owner: owner} = state) do
      send(owner, {:notification_wire, Jason.decode!(message)})
      {:ok, %{state | count: state.count + 1}}
    end
  end

  defp state(version) do
    %{
      protocol_version: version,
      client_capabilities: %{sampling: %{}},
      client_info: %{name: "notification-metadata-test", version: "1.0.0"},
      generation: make_ref(),
      transport_mod: CaptureTransport,
      transport_state: %{owner: self(), count: 0}
    }
  end

  for {method, params} <- [
        {"notifications/initialized", %{}},
        {"notifications/cancelled", %{"requestId" => "cancel-me", "reason" => "test"}},
        {"notifications/progress", %{"progressToken" => "progress", "progress" => 1}},
        {"notifications/tools/list_changed", %{}}
      ] do
    @method method
    @params params

    test "modern #{@method} satisfies routing and metadata validation without an id" do
      before = state("2026-07-28")

      assert {:noreply, after_state} =
               RequestHandler.handle_cast_notification(@method, @params, before)

      assert after_state.generation == before.generation
      assert after_state.transport_state.count == 1
      assert_receive {:notification_wire, request}
      refute Map.has_key?(request, "id")
      assert request["method"] == @method
      assert Map.drop(request["params"], ["_meta"]) == @params
      assert {:ok, parsed} = Meta.parse_request_meta(request["params"]["_meta"])
      assert parsed.protocol_version == "2026-07-28"
      assert parsed.client_capabilities == %{"sampling" => %{}}
      assert parsed.client_info == %{"name" => "notification-metadata-test", "version" => "1.0.0"}

      transport = %HTTP{
        protocol_version: "2026-07-28",
        headers: [],
        security: %{},
        origin: nil
      }

      headers = RequestHeaders.build(Jason.encode!(request), transport)
      assert {"Mcp-Method", @method} in headers
      assert :ok == RequestHeaders.validate(headers, request)
    end

    test "legacy #{@method} retains the exact notification shape" do
      before = state("2025-03-26")

      assert {:noreply, _after_state} =
               RequestHandler.handle_cast_notification(@method, @params, before)

      assert_receive {:notification_wire, request}
      assert request == %{"jsonrpc" => "2.0", "method" => @method, "params" => @params}
    end
  end

  test "connection metadata replaces caller-reserved fields and preserves application metadata" do
    before = state("2026-07-28")

    params = %{
      "_meta" => %{
        "app.example/trace" => "kept",
        "io.modelcontextprotocol/protocolVersion" => "wrong",
        "io.modelcontextprotocol/clientCapabilities" => %{"wrong" => %{}}
      }
    }

    assert {:noreply, _} =
             RequestHandler.handle_cast_notification("notifications/initialized", params, before)

    assert_receive {:notification_wire, %{"params" => %{"_meta" => meta}}}
    assert meta["app.example/trace"] == "kept"
    assert meta["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"
    assert meta["io.modelcontextprotocol/clientCapabilities"] == %{"sampling" => %{}}
  end

  test "invalid modern metadata is rejected before transport effects and leaves state unchanged" do
    before = state("2026-07-28")

    log =
      capture_log(fn ->
        assert {:noreply, ^before} =
                 RequestHandler.handle_cast_notification(
                   "notifications/initialized",
                   %{"_meta" => %{"invalid/key/shape" => true}},
                   before
                 )
      end)

    assert log =~ "Failed to send notification"
    refute_receive {:notification_wire, _}
  end

  test "disconnected notification preserves the disconnected state" do
    before = %{state("2026-07-28") | transport_mod: nil, transport_state: nil}

    capture_log(fn ->
      assert {:noreply, ^before} =
               RequestHandler.handle_cast_notification("notifications/initialized", %{}, before)
    end)

    refute_receive {:notification_wire, _}
  end
end
