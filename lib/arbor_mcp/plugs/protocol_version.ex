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
  alias Arbor.MCP.Server.RequestContext

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    mode = Keyword.get(opts, :protocol_mode)
    values = get_req_header(conn, "mcp-protocol-version")

    # This standalone Plug cannot tell a header-optional initialize from any
    # other request. A missing header keeps the legacy default. An explicit
    # value is accepted only when the mount's protocol mode enables it, and
    # the rejection lists that same set. HttpPlug enforces the negotiated
    # per-session version on later requests.
    case {values, mode} do
      {values, :modern_only} ->
        validate_modern_only_header(conn, values)

      {[], _mode} ->
        default = default_version()
        Logger.debug("No MCP-Protocol-Version header found, using default: #{default}")
        assign(conn, :mcp_version, default)

      {[version], mode} ->
        if explicit_version_accepted?(version, mode) do
          Logger.debug("Valid MCP-Protocol-Version: #{version}")
          assign(conn, :mcp_version, version)
        else
          reject_version(conn, version, advertised_versions(mode))
        end

      {_duplicates, mode} ->
        reject_version(conn, "duplicate", advertised_versions(mode))
    end
  end

  defp validate_modern_only_header(conn, [version]) do
    if explicit_version_accepted?(version, :modern_only) do
      assign(conn, :mcp_version, version)
    else
      reject_version(conn, version, advertised_versions(:modern_only))
    end
  end

  defp validate_modern_only_header(conn, []),
    do: reject_version(conn, "missing", advertised_versions(:modern_only))

  defp validate_modern_only_header(conn, _duplicates),
    do: reject_version(conn, "duplicate", advertised_versions(:modern_only))

  # The versions a mount accepts and the ones a rejection lists come from
  # the same place as the rest of the server's validation. No configured
  # mode restricts nothing: every version of both eras.
  defp explicit_version_accepted?(version, mode),
    do: version in RequestContext.accepted_versions(mode)

  defp advertised_versions(mode), do: RequestContext.accepted_versions(mode)

  defp reject_version(conn, _invalid_version, supported) do
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
