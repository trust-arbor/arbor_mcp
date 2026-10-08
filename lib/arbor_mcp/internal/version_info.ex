defmodule Arbor.MCP.Internal.VersionInfo do
  @moduledoc false

  # Single source of truth for the library version reported to MCP servers.
  # Reads the version from the :arbor_mcp application spec so it can never
  # drift from mix.exs.

  @doc """
  Returns the ArborMCP library version string.
  """
  @spec version() :: String.t()
  def version do
    case Application.spec(:arbor_mcp, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  @doc """
  Returns the default MCP `clientInfo` map sent during initialization.
  """
  @spec client_info() :: %{String.t() => String.t()}
  def client_info do
    %{
      "name" => "Arbor.MCP",
      "version" => version()
    }
  end
end
