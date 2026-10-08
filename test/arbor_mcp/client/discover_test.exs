defmodule Arbor.MCP.Client.DiscoverTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client

  defmodule SyncDiscoverTransport do
    def send_message(message, state) do
      request = Jason.decode!(message)
      send(state.owner, {:discover_request, request})

      response = %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "result" => state.result
      }

      {:ok, state, Jason.encode!(response)}
    end
  end

  test "discover/2 updates the public client state accessors" do
    discovery_result = %{
      "resultType" => "complete",
      "supportedVersions" => ["2026-07-28"],
      "capabilities" => %{"tools" => %{"listChanged" => true}},
      "ttlMs" => 1_000,
      "cacheScope" => "public",
      "_meta" => %{
        "io.modelcontextprotocol/serverInfo" => %{
          "name" => "modern-server",
          "version" => "2.0"
        }
      }
    }

    {:ok, client} =
      Client.start_link(
        _skip_connect: true,
        protocol_mode: :modern_only,
        capabilities: %{"roots" => %{}}
      )

    owner = self()

    :sys.replace_state(client, fn state ->
      %{
        state
        | connection_status: :ready,
          protocol_version: "2026-07-28",
          transport_mod: SyncDiscoverTransport,
          transport_state: %{owner: owner, result: discovery_result}
      }
    end)

    assert {:ok, ^discovery_result} = Client.discover(client, timeout: 1_000)

    assert_receive {:discover_request, request}

    assert request["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"] ==
             "2026-07-28"

    assert {:ok, "2026-07-28"} = Client.negotiated_version(client)
    assert {:ok, %{"tools" => %{"listChanged" => true}}} = Client.server_capabilities(client)

    assert {:ok, %{"name" => "modern-server", "version" => "2.0"}} =
             Client.server_info(client)
  end

  test "does not mutate client state when discovery has no enabled version" do
    {:ok, client} = Client.start_link(_skip_connect: true, protocol_mode: :modern_only)

    result = %{
      "supportedVersions" => ["2025-11-25"],
      "capabilities" => %{"tools" => %{}},
      "ttlMs" => 1,
      "cacheScope" => "private"
    }

    assert {:error, {:no_mutually_supported_protocol_version, versions}} =
             GenServer.call(client, {:apply_discover_result, result})

    assert versions.server == ["2025-11-25"]
    assert versions.client == ["2026-07-28"]
    assert {:ok, nil} = Client.negotiated_version(client)
    assert {:ok, %{}} = Client.server_capabilities(client)
  end
end
