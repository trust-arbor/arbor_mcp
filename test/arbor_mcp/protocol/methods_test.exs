defmodule Arbor.MCP.Protocol.MethodsTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Internal.{Protocol, VersionRegistry}
  alias Arbor.MCP.Protocol.{Methods, RequestProcessor}
  alias Arbor.MCP.Server.{Capabilities, Dispatch}

  @versions VersionRegistry.supported_versions()

  test "wire capability maps match the committed fixture for every supported version" do
    fixture_path = Path.expand("../../fixtures/protocol/capabilities.json", __DIR__)
    expected = fixture_path |> File.read!() |> Jason.decode!()

    actual =
      Map.new(@versions, fn version ->
        {version, Capabilities.build_capabilities(nil, version)}
      end)

    assert actual == expected
  end

  test "all dispatch consumers derive their method sets from the canonical rows" do
    assert Dispatch.methods() == Methods.methods_for(:server_dispatch)

    assert Enum.sort(Arbor.MCP.MessageProcessor.dispatched_methods()) ==
             Enum.sort(Map.keys(Methods.handler_map(:message_processor)))

    assert Enum.sort(RequestProcessor.dispatched_methods()) ==
             Enum.sort(Map.keys(Methods.handler_map(:request_processor)))
  end

  test "version gating and message-format tables reproduce the canonical registry" do
    for {method, _min, _max, _kind, _handlers} <- Methods.rows(), version <- @versions do
      assert Protocol.method_available?(method, version) == Methods.available?(method, version)
    end

    for version <- @versions do
      format = VersionRegistry.message_format(version)
      assert format.notification_methods == Methods.notification_methods(version)
      assert format.request_methods == Methods.introduced_request_methods(version)
    end
  end

  test "unknown methods retain the legacy permissive version gate" do
    for version <- @versions do
      assert Protocol.method_available?("vendor/custom", version)
    end
  end

  test "modern staging methods are bound to the known modern version" do
    for method <- ["server/discover", "subscriptions/listen"] do
      assert Protocol.method_available?(method, "2026-07-28")
      refute Protocol.method_available?(method, "draft")

      for version <- @versions do
        refute Protocol.method_available?(method, version)
      end
    end
  end

  test "the modern method surface includes core operations and excludes removed methods" do
    for method <- ["tools/list", "tools/call", "resources/read", "prompts/get"] do
      assert Protocol.method_available?(method, "2026-07-28")
    end

    for method <- ["initialize", "ping", "logging/setLevel", "resources/subscribe"] do
      refute Protocol.method_available?(method, "2026-07-28")
    end
  end
end
