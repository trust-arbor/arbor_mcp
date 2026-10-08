defmodule Arbor.MCP.Server.Capabilities do
  @moduledoc """
  Helper module to build server capabilities.

  Uses the VersionRegistry to return appropriate capabilities
  based on the negotiated protocol version.
  """

  alias Arbor.MCP.Internal.VersionRegistry

  @doc """
  Builds server capabilities object based on protocol version.

  Returns version-specific capabilities from the VersionRegistry.
  Handlers can still override this in their handle_initialize/2
  if they want to advertise different capabilities.

  ## Parameters
  - handler_module: The handler module (reserved for future use)
  - version: The negotiated protocol version (defaults to latest)

  ## Examples

      iex> Arbor.MCP.Server.Capabilities.build_capabilities(MyHandler, "2025-03-26")
      %{
        "prompts" => %{"listChanged" => true},
        "resources" => %{"subscribe" => true, "listChanged" => true},
        "tools" => %{},
        "logging" => %{"setLevel" => true},
        "completion" => %{},
        "experimental" => %{}
      }
  """
  @spec build_capabilities(module(), String.t() | nil) :: map()
  def build_capabilities(_handler_module, version \\ nil) do
    version = version || VersionRegistry.latest_version()

    capabilities = VersionRegistry.capabilities_for_version(version)

    # Convert atom keys to string keys for JSON compatibility
    capabilities
    |> Enum.map(fn {key, value} ->
      {to_string(key), convert_capability_value(value)}
    end)
    |> Enum.into(%{})
  end

  defp convert_capability_value(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} ->
      {convert_key(k), v}
    end)
    |> Enum.into(%{})
  end

  defp convert_capability_value(value), do: value

  defp convert_key(key) when is_atom(key) do
    key
    |> to_string()
    |> String.split("_")
    |> Enum.with_index()
    |> Enum.map_join("", fn {part, index} ->
      if index == 0, do: part, else: String.capitalize(part)
    end)
  end

  defp convert_key(key), do: to_string(key)
end
