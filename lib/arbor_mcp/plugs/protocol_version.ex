defmodule Arbor.MCP.Plugs.ProtocolVersion do
  @moduledoc """
  Plug for validating and extracting the MCP-Protocol-Version header.

  This plug ensures that incoming HTTP requests carry a protocol version the
  server actually supports.

  ## Behavior

  - If no header is present, the configured default
    (also returned by `Arbor.MCP.protocol_version/0`) is assumed
  - If an unsupported version is provided, returns 400 Bad Request
  - Adds the validated version to conn.assigns[:mcp_version]

  The supported list and default come from ArborMCP's canonical internal version
  registry, so clients, server transports, and this plug cannot drift.

  ## Usage

      plug Arbor.MCP.Plugs.ProtocolVersion
  """

  import Plug.Conn
  require Logger

  alias Arbor.MCP.Internal.VersionRegistry

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    values = get_req_header(conn, "mcp-protocol-version")

    case {values, Keyword.get(opts, :protocol_mode)} do
      {[version], _mode} when version == "2026-07-28" ->
        validate_modern_protocol_version(conn, version)

      {values, :modern_only} ->
        validate_modern_only_header(conn, values)

      {_legacy_or_missing, _mode} ->
        # This standalone Plug cannot determine whether a request is the
        # lifecycle's header-optional initialize request. It therefore keeps
        # the specification's backwards-compatible missing-header default,
        # while always rejecting any explicit malformed, duplicate, or
        # unsupported value. HttpPlug additionally enforces the negotiated
        # per-session version on subsequent requests.
        validate_protocol_version(conn)
    end
  end

  defp validate_modern_protocol_version(conn, version) do
    if VersionRegistry.modern?(version) and VersionRegistry.known?(version) do
      assign(conn, :mcp_version, version)
    else
      reject_version(conn, version, VersionRegistry.known_versions())
    end
  end

  defp validate_modern_only_header(conn, [version]) do
    validate_modern_protocol_version(conn, version)
  end

  defp validate_modern_only_header(conn, []),
    do: reject_version(conn, "missing", VersionRegistry.supported_versions(:modern_only))

  defp validate_modern_only_header(conn, _duplicates),
    do: reject_version(conn, "duplicate", VersionRegistry.supported_versions(:modern_only))

  defp validate_protocol_version(conn) do
    default = default_version()

    case get_req_header(conn, "mcp-protocol-version") do
      [] ->
        Logger.debug("No MCP-Protocol-Version header found, using default: #{default}")
        assign(conn, :mcp_version, default)

      [version] ->
        if VersionRegistry.supported?(version) do
          Logger.debug("Valid MCP-Protocol-Version: #{version}")
          assign(conn, :mcp_version, version)
        else
          reject_version(conn, version)
        end

      _duplicates ->
        reject_version(conn, "duplicate")
    end
  end

  defp reject_version(conn, _invalid_version, supported \\ supported_versions()) do
    Logger.warning("Invalid MCP-Protocol-Version header")

    error_response = %{
      jsonrpc: "2.0",
      error: %{
        code: -32600,
        message: "Invalid Request",
        data: %{
          reason: "Unsupported protocol version",
          supported_versions: supported
        }
      }
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(error_response))
    |> halt()
  end

  @doc """
  Get the list of supported protocol versions.
  """
  @spec supported_versions() :: [String.t()]
  defdelegate supported_versions, to: VersionRegistry

  @doc """
  Get the default protocol version.
  """
  @spec default_version() :: String.t()
  defdelegate default_version, to: VersionRegistry, as: :preferred_version
end
