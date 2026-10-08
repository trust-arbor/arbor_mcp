defmodule Arbor.MCP.Plugs.ProtectedResourceMetadata do
  @moduledoc """
  Serves Protected Resource Metadata per RFC 9728.

  This plug serves the `/.well-known/oauth-protected-resource` endpoint,
  allowing clients to discover which authorization servers protect this
  resource and what scopes are supported.

  ## Usage

      plug Arbor.MCP.Plugs.ProtectedResourceMetadata,
        resource: "https://mcp.example.com",
        authorization_servers: ["https://auth.example.com"],
        scopes_supported: ["mcp:tools:list", "mcp:tools:execute"],
        bearer_methods_supported: ["header"]

  ## Options

  - `:resource` (required) - The resource identifier URI.
  - `:authorization_servers` (required) - List of authorization server issuer URIs.
  - `:scopes_supported` - List of supported OAuth scopes. Defaults to MCP standard scopes.
  - `:bearer_methods_supported` - How bearer tokens can be presented.
    Defaults to `["header"]`.
  - `:resource_signing_alg_values_supported` - Supported signing algorithms.
  - `:resource_documentation` - URL to human-readable documentation.
  - `:extra_metadata` - Additional metadata fields as a map.
  """

  @behaviour Plug

  import Plug.Conn

  alias Arbor.MCP.Internal.MapBuilder
  @impl true
  def init(opts) do
    resource = Keyword.get(opts, :resource)
    authorization_servers = Keyword.get(opts, :authorization_servers)

    unless resource do
      raise ArgumentError,
            "Arbor.MCP.Plugs.ProtectedResourceMetadata requires :resource option"
    end

    unless authorization_servers do
      raise ArgumentError,
            "Arbor.MCP.Plugs.ProtectedResourceMetadata requires :authorization_servers option"
    end

    %{
      resource: resource,
      authorization_servers: authorization_servers,
      scopes_supported: Keyword.get(opts, :scopes_supported, default_scopes()),
      bearer_methods_supported: Keyword.get(opts, :bearer_methods_supported, ["header"]),
      resource_signing_alg_values_supported:
        Keyword.get(opts, :resource_signing_alg_values_supported),
      resource_documentation: Keyword.get(opts, :resource_documentation),
      extra_metadata: Keyword.get(opts, :extra_metadata, %{})
    }
  end

  @impl true
  def call(conn, opts) do
    metadata = build_metadata(opts)

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> send_resp(200, Jason.encode!(metadata))
  end

  @doc """
  Builds the protected resource metadata map from the given options.
  """
  @spec build_metadata(map()) :: map()
  def build_metadata(opts) do
    base = %{
      "resource" => opts.resource,
      "authorization_servers" => opts.authorization_servers,
      "scopes_supported" => opts.scopes_supported,
      "bearer_methods_supported" => opts.bearer_methods_supported
    }

    base
    |> MapBuilder.put_if_present(
      "resource_signing_alg_values_supported",
      opts[:resource_signing_alg_values_supported]
    )
    |> MapBuilder.put_if_present("resource_documentation", opts[:resource_documentation])
    |> Map.merge(opts.extra_metadata)
  end

  defp default_scopes do
    Arbor.MCP.Authorization.ScopeValidator.get_all_static_scopes()
  rescue
    _ ->
      [
        "mcp:tools:list",
        "mcp:tools:execute",
        "mcp:resources:list",
        "mcp:resources:get",
        "mcp:prompts:execute"
      ]
  end
end
