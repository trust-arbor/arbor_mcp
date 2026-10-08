defmodule Arbor.MCP.TestSupport.LegacyInitialize do
  @moduledoc false

  alias Arbor.MCP.Protocol.Initialize
  alias Arbor.MCP.Server.Capabilities

  def result(requested_version) do
    result =
      Initialize.build_initialize_result(%{"protocolVersion" => requested_version}, %{
        serverInfo: %{
          name: "Arbor.MCP",
          version: Application.spec(:arbor_mcp, :vsn) |> to_string()
        }
      })

    Map.put(
      result,
      "capabilities",
      Capabilities.build_capabilities(nil, result["protocolVersion"])
    )
  end
end
