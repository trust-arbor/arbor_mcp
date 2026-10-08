defmodule Arbor.MCP.Protocol.Initialize do
  @moduledoc false

  alias Arbor.MCP.Internal.VersionRegistry
  alias Arbor.MCP.Server.ResultNormalizer

  @known_fields [
    "protocolVersion",
    :protocolVersion,
    "serverInfo",
    :serverInfo,
    "capabilities",
    :capabilities,
    "name",
    :name,
    "version",
    :version
  ]

  @doc """
  Builds a canonical, string-keyed legacy `initialize` result.

  `params` is the client's initialize parameter map. `result_fields` contains
  the handler- or transport-specific server information, capabilities, and
  optional result fields such as `instructions`.

  A protocol version explicitly selected by the handler takes precedence over
  the requested version. Staged and unknown versions are never advertised;
  they fall back to the configured supported preference.
  """
  @spec build_initialize_result(map(), map()) :: Arbor.MCP.Types.wire_initialize_result()
  def build_initialize_result(params, result_fields)
      when is_map(params) and is_map(result_fields) do
    protocol_version = select_protocol_version(params, result_fields)
    server_info = server_info(result_fields)
    capabilities = field(result_fields, "capabilities", :capabilities) || %{}

    result_fields
    |> Map.drop(@known_fields)
    |> ResultNormalizer.stringify_keys()
    |> Map.put("protocolVersion", protocol_version)
    |> Map.put("serverInfo", ResultNormalizer.stringify_keys(server_info))
    |> Map.put("capabilities", ResultNormalizer.stringify_keys(capabilities))
  end

  defp select_protocol_version(params, result_fields) do
    selected =
      field(result_fields, "protocolVersion", :protocolVersion) ||
        field(params, "protocolVersion", :protocolVersion) ||
        VersionRegistry.preferred_version()

    if VersionRegistry.supported?(selected),
      do: selected,
      else: VersionRegistry.preferred_version()
  end

  defp server_info(result_fields) do
    field(result_fields, "serverInfo", :serverInfo) ||
      flat_server_info(result_fields) ||
      %{}
  end

  defp flat_server_info(result_fields) do
    name = field(result_fields, "name", :name)
    version = field(result_fields, "version", :version)

    if name && version, do: %{"name" => name, "version" => version}
  end

  defp field(map, string_key, atom_key) do
    case Map.fetch(map, string_key) do
      {:ok, value} -> value
      :error -> Map.get(map, atom_key)
    end
  end
end
