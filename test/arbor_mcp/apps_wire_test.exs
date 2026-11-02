defmodule Arbor.MCP.AppsWireTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.{Apps, AppsFixture, Client}

  for {mode, version, label} <- [
        {:modern_only, "2026-07-28", "modern"},
        {:legacy_only, "2025-11-25", "legacy"}
      ] do
    @mode mode
    @version version
    @tag assurance: ["apps.wire.#{label}"]
    test "#{label} transports UI linkage, resource policy, structured data and result metadata" do
      fixture = AppsFixture.start()

      {:ok, client} =
        Client.start_link(
          transport: :http,
          url: fixture.endpoint,
          protocol_mode: @mode,
          protocol_version: @version,
          capabilities: Apps.put_capability(),
          use_sse: false,
          health_check_interval: nil
        )

      try do
        assert {:ok, %{"tools" => tools}} = Client.list_tools(client, format: :map)
        assert Enum.sort(Enum.map(tools, & &1["name"])) == ["plan", "plan_policy", "update_plan"]
        tool = Enum.find(tools, &(&1["name"] == "plan"))
        update = Enum.find(tools, &(&1["name"] == "update_plan"))
        policy = Enum.find(tools, &(&1["name"] == "plan_policy"))
        assert tool["_meta"]["ui"]["resourceUri"] == "ui://arbor/plan.html"
        assert tool["_meta"]["ui/resourceUri"] == "ui://arbor/plan.html"
        refute Apps.visible_to?(update, :model)
        assert Apps.visible_to?(update, :app)
        refute Apps.visible_to?(policy, :app)

        assert {:ok, %{"resources" => [resource]}} = Client.list_resources(client, format: :map)
        assert resource["mimeType"] == Apps.mime_type()

        assert {:ok, %{"contents" => [content]}} =
                 Client.read_resource(client, resource["uri"], format: :map)

        assert content["mimeType"] == Apps.mime_type()
        assert content["text"] =~ "<!doctype html>"
        assert content["_meta"]["ui"]["csp"]["connectDomains"] == []
        assert content["_meta"]["ui"]["prefersBorder"] == false

        assert {:ok, result} =
                 Client.call_tool(client, "plan", %{"seats" => 8, "storageGb" => 100},
                   format: :map
                 )

        assert result["content"] |> hd() |> Map.fetch!("text") =~ "$164.00"

        assert result["structuredContent"] == %{
                 "seats" => 8,
                 "storageGb" => 100,
                 "totalCents" => 16400
               }

        assert result["_meta"]["example/viewLabel"] == "Local estimate"

        assert {:ok, changed} =
                 Client.call_tool(client, "update_plan", %{"seats" => 12, "storageGb" => 200},
                   format: :map
                 )

        assert changed["structuredContent"]["totalCents"] == 25600

        for invalid <- [-1, "8", nil, %{}] do
          assert {:error, error} =
                   Client.call_tool(client, "plan", %{"seats" => invalid}, format: :map)

          assert error["code"] == -32602
        end
      after
        assert :ok = Client.disconnect(client)
      end
    end
  end

  @tag assurance: ["apps.wire.fallback"]
  test "hosts without Apps MIME support receive only a meaningful text-compatible public tool" do
    fixture = AppsFixture.start()

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: fixture.endpoint,
        protocol_mode: :modern_only,
        capabilities: %{},
        use_sse: false,
        health_check_interval: nil
      )

    try do
      assert {:ok, %{"tools" => [tool, policy]}} = Client.list_tools(client, format: :map)
      assert tool["name"] == "plan"
      refute Map.has_key?(tool, "_meta")
      assert policy["name"] == "plan_policy"
      assert {:ok, result} = Client.call_tool(client, "plan", %{}, format: :map)
      assert result["content"] |> hd() |> Map.fetch!("text") =~ "Illustrative pricing"
    after
      assert :ok = Client.disconnect(client)
    end
  end

  @tag assurance: ["apps.wire.profiles"]
  test "legacy client profiles and modern per-call overrides remain isolated" do
    fixture = AppsFixture.start()

    for mode <- [:legacy_only, :modern_only] do
      base = [
        transport: :http,
        url: fixture.endpoint,
        protocol_mode: mode,
        use_sse: false,
        health_check_interval: nil
      ]

      {:ok, ui} = Client.start_link(Keyword.put(base, :capabilities, Apps.put_capability()))
      {:ok, plain} = Client.start_link(Keyword.put(base, :capabilities, %{}))

      try do
        assert {:ok, %{"tools" => tools}} = Client.list_tools(ui, format: :map)
        assert length(tools) == 3
        assert {:ok, %{"tools" => fallback}} = Client.list_tools(plain, format: :map)
        assert length(fallback) == 2
        refute Enum.any?(fallback, &Map.has_key?(&1, "_meta"))

        if mode == :modern_only do
          assert {:ok, %{"tools" => overridden}} =
                   Client.list_tools(ui, format: :map, client_capabilities: %{})

          assert length(overridden) == 2
        end

        assert {:ok, %{"tools" => again}} = Client.list_tools(ui, format: :map, cache: false)
        assert length(again) == 3
      after
        assert :ok = Client.disconnect(ui)
        assert :ok = Client.disconnect(plain)
      end
    end
  end
end
