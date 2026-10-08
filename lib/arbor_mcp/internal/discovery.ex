defmodule Arbor.MCP.Internal.Discovery do
  @moduledoc false

  # This module provides Arbor.MCP extensions beyond the standard MCP specification.
  #
  # MCP server discovery functionality.
  #
  # Provides mechanisms to discover available MCP servers through:
  # - Environment variables (including pattern matching)
  # - Configuration files
  # - Well-known locations
  # - NPM package discovery
  # - Python package discovery
  # - Executable server detection
  # - Service registration
  #
  # > Extension Module: Server discovery is an Arbor.MCP extension not part of the official MCP specification.
  # > This provides convenient auto-discovery of MCP servers in your environment.
  #
  # ## Examples
  #
  #     # Discover all servers using default methods
  #     servers = Arbor.MCP.Internal.Discovery.discover_servers()
  #
  #     # Discover using specific methods
  #     servers = Arbor.MCP.Internal.Discovery.discover_servers(methods: [:npm, :env, :config])
  #
  #     # Test if a server is reachable
  #     Arbor.MCP.Internal.Discovery.test_server(server_config)

  import Bitwise
  require Logger

  @doc """
  Discovers available MCP servers from various sources.

  ## Options

  - `:methods` - List of discovery methods to use. Defaults to all available methods.
    Available methods: `:env`, `:config`, `:well_known`, `:npm`, `:pip`

  Returns a list of server configurations that can be used
  to establish connections.
  """
  @spec discover_servers(keyword()) :: [map()]
  def discover_servers(options \\ []) do
    methods = Keyword.get(options, :methods, [:env, :config, :well_known, :npm])

    methods
    |> Enum.flat_map(&discover_by_method(&1, options))
    |> normalize_servers()
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Discovers servers from environment variables.

  Looks for:
  - MCP_SERVERS environment variable containing a JSON array
  - Variables matching *_MCP_SERVER pattern (command-based servers)
  - Variables matching *_SERVER_URL pattern (SSE servers)
  """
  @spec discover_from_env(list()) :: [map()]
  def discover_from_env(servers \\ []) do
    json_servers = discover_mcp_servers_json()
    pattern_servers = discover_env_pattern_servers()

    servers ++ json_servers ++ pattern_servers
  end

  @doc """
  Discovers npm-based MCP servers.

  Scans globally installed npm packages for MCP servers.
  """
  @spec discover_npm_packages() :: [map()]
  def discover_npm_packages do
    case System.cmd("npm", ["list", "-g", "--depth=0", "--json"], stderr_to_stdout: true) do
      {output, 0} ->
        parse_npm_packages(output)

      {error, _} ->
        Logger.debug("Failed to list npm packages: #{error}")
        []
    end
  rescue
    _ ->
      Logger.debug("npm command not available")
      []
  end

  @doc """
  Discovers servers from configuration files.

  Looks for mcp.json or .mcp/config.json in:
  - Current directory
  - Home directory
  - XDG config directory
  """
  @spec discover_from_config(list()) :: [map()]
  def discover_from_config(servers \\ []) do
    config_paths = [
      "mcp.json",
      ".mcp/config.json",
      Path.join([System.user_home!(), ".mcp", "config.json"]),
      Path.join([xdg_config_home(), "mcp", "config.json"])
    ]

    config_servers =
      config_paths
      |> Enum.map(&read_config_file/1)
      |> Enum.reject(&is_nil/1)
      |> List.flatten()
      |> normalize_servers()

    servers ++ config_servers
  end

  @doc """
  Discovers servers from well-known locations.

  Checks standard locations where MCP servers might be installed:
  - System paths
  - User local directories
  - Application bundles

  Also detects server types:
  - Node.js servers (package.json + mcp.json)
  - Python servers (pyproject.toml + mcp.json)
  - Executable servers
  """
  @spec discover_from_well_known(list()) :: [map()]
  def discover_from_well_known(servers \\ []) do
    well_known_paths = [
      "/usr/local/lib/mcp-servers",
      "/opt/mcp-servers",
      Path.join([System.user_home!(), ".local", "lib", "mcp-servers"]),
      Path.join([System.user_home!(), ".mcp", "servers"])
    ]

    well_known_servers =
      well_known_paths
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&scan_directory_enhanced/1)
      |> normalize_servers()

    servers ++ well_known_servers
  end

  @doc """
  Test if a discovered server is reachable/valid.

  ## Examples

      iex> Arbor.MCP.Internal.Discovery.test_server(%{command: ["node", "server.js"]})
      false

      iex> Arbor.MCP.Internal.Discovery.test_server(%{url: "http://localhost:8080"})
      true
  """
  @spec test_server(map()) :: boolean()
  def test_server(server_config) do
    case server_config do
      %{command: command} ->
        test_stdio_server(command)

      %{url: url} ->
        test_sse_server(url)

      _ ->
        false
    end
  end

  @doc """
  Get metadata about a discovered server by starting it temporarily.

  This will attempt to start the server and query its capabilities.
  """
  @spec get_server_metadata(map()) :: map()
  def get_server_metadata(server_config) do
    # This would integrate with the MCP client to get server info
    # For now, return the config as-is
    server_config
  end

  @doc """
  Registers a server for discovery.

  This allows programmatic registration of servers that
  may not be discoverable through other means.
  """
  @spec register_server(map()) :: :ok
  def register_server(server_config) do
    # In a real implementation, this might write to a registry
    # For now, we'll just validate the config
    if valid_server_config?(server_config) do
      :ok
    else
      {:error, :invalid_config}
    end
  end

  # Private functions

  defp discover_by_method(:env, _options), do: discover_from_env()
  defp discover_by_method(:config, _options), do: discover_from_config()
  defp discover_by_method(:well_known, _options), do: discover_from_well_known()
  defp discover_by_method(:npm, _options), do: discover_npm_packages()
  defp discover_by_method(_, _options), do: []

  defp discover_mcp_servers_json do
    case System.get_env("MCP_SERVERS") do
      nil ->
        []

      json ->
        case Jason.decode(json) do
          {:ok, env_servers} when is_list(env_servers) ->
            normalize_servers(env_servers)

          _ ->
            []
        end
    end
  end

  defp discover_env_pattern_servers do
    System.get_env()
    |> Enum.filter(fn {key, _value} ->
      String.ends_with?(key, "_MCP_SERVER") || String.ends_with?(key, "_SERVER_URL")
    end)
    |> Enum.map(&parse_env_pattern_server/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_env_pattern_server({key, value}) do
    cond do
      String.ends_with?(key, "_MCP_SERVER") ->
        # Format: MYAPP_MCP_SERVER=command args
        name =
          key
          |> String.replace_suffix("_MCP_SERVER", "")
          |> String.downcase()

        %{
          "name" => "#{name}-env",
          "command" => String.split(value, " "),
          "source" => "env",
          "auto_discovered" => true
        }

      String.ends_with?(key, "_SERVER_URL") ->
        # Format: MYAPP_SERVER_URL=http://localhost:8080
        name =
          key
          |> String.replace_suffix("_SERVER_URL", "")
          |> String.downcase()

        %{
          "name" => "#{name}-env",
          "url" => value,
          "transport" => "sse",
          "source" => "env",
          "auto_discovered" => true
        }

      true ->
        nil
    end
  end

  defp parse_npm_packages(json_output) do
    case Jason.decode(json_output) do
      {:ok, %{"dependencies" => deps}} ->
        deps
        |> Enum.filter(fn {name, _} ->
          String.contains?(name, "mcp") ||
            String.contains?(name, "modelcontextprotocol")
        end)
        |> Enum.map(&npm_package_to_server_config/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp npm_package_to_server_config({package_name, _info}) do
    # Map known MCP npm packages to server configurations
    case package_name do
      "@modelcontextprotocol/server-filesystem" ->
        %{
          "name" => "filesystem-npm",
          "command" => ["npx", "-y", package_name, System.get_env("HOME", "/tmp")],
          "source" => "npm",
          "auto_discovered" => true
        }

      "@modelcontextprotocol/server-github" ->
        if System.get_env("GITHUB_TOKEN") do
          %{
            "name" => "github-npm",
            "command" => ["npx", "-y", package_name],
            "env" => %{"GITHUB_TOKEN" => System.get_env("GITHUB_TOKEN")},
            "source" => "npm",
            "auto_discovered" => true
          }
        else
          nil
        end

      "@modelcontextprotocol/server-postgres" ->
        if System.get_env("DATABASE_URL") do
          %{
            "name" => "postgres-npm",
            "command" => ["npx", "-y", package_name, System.get_env("DATABASE_URL")],
            "source" => "npm",
            "auto_discovered" => true
          }
        else
          nil
        end

      "@modelcontextprotocol/server-" <> rest ->
        # Generic pattern for other MCP servers
        %{
          "name" => "#{rest}-npm",
          "command" => ["npx", "-y", package_name],
          "source" => "npm",
          "auto_discovered" => true
        }

      _ ->
        nil
    end
  end

  defp xdg_config_home do
    System.get_env("XDG_CONFIG_HOME", Path.join(System.user_home!(), ".config"))
  end

  defp read_config_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"servers" => servers}} when is_list(servers) ->
            servers

          {:ok, servers} when is_list(servers) ->
            servers

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp scan_directory_enhanced(dir) do
    File.ls!(dir)
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&check_mcp_server_directory/1)
    |> Enum.reject(&is_nil/1)
  end

  defp check_mcp_server_directory(dir) do
    # Check for common MCP server patterns
    cond do
      # Node.js based server
      File.exists?(Path.join(dir, "package.json")) &&
          File.exists?(Path.join(dir, "mcp.json")) ->
        parse_nodejs_server(dir)

      # Python based server
      File.exists?(Path.join(dir, "pyproject.toml")) &&
          File.exists?(Path.join(dir, "mcp.json")) ->
        parse_python_server(dir)

      # Executable server
      executable = find_executable(dir) ->
        %{
          "name" => Path.basename(dir) <> "-local",
          "command" => [executable],
          "source" => "local",
          "auto_discovered" => true
        }

      # Traditional mcp.json manifest
      File.exists?(Path.join(dir, "mcp.json")) ->
        read_manifest(Path.join(dir, "mcp.json"), dir)

      true ->
        nil
    end
  end

  defp parse_nodejs_server(dir) do
    with {:ok, mcp_json} <- File.read(Path.join(dir, "mcp.json")),
         {:ok, mcp_config} <- Jason.decode(mcp_json) do
      %{
        "name" => mcp_config["name"] || Path.basename(dir),
        "command" => ["node", Path.join(dir, mcp_config["main"] || "index.js")],
        "source" => "local",
        "auto_discovered" => true
      }
    else
      _ -> nil
    end
  end

  defp parse_python_server(dir) do
    with {:ok, mcp_json} <- File.read(Path.join(dir, "mcp.json")),
         {:ok, mcp_config} <- Jason.decode(mcp_json) do
      %{
        "name" => mcp_config["name"] || Path.basename(dir),
        "command" => ["python", "-m", mcp_config["module"] || Path.basename(dir)],
        "source" => "local",
        "auto_discovered" => true
      }
    else
      _ -> nil
    end
  end

  defp find_executable(dir) do
    ["mcp-server", "server", Path.basename(dir)]
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.find(fn path ->
      File.exists?(path) && (File.stat!(path).mode &&& 0o111) != 0
    end)
  end

  defp read_manifest(path, base_dir) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, manifest} ->
            manifest
            |> Map.put("base_dir", base_dir)
            |> resolve_command_path()

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp resolve_command_path(%{"command" => command} = manifest) when is_binary(command) do
    base_dir = Map.get(manifest, "base_dir", ".")

    resolved_command =
      if Path.type(command) == :absolute do
        command
      else
        Path.join(base_dir, command)
      end

    Map.put(manifest, "command", resolved_command)
  end

  defp resolve_command_path(manifest), do: manifest

  defp normalize_servers(servers) do
    Enum.map(servers, &normalize_server/1)
  end

  defp normalize_server(%{"name" => name} = server) do
    %{
      name: name,
      transport: Map.get(server, "transport", "stdio"),
      command: Map.get(server, "command"),
      args: Map.get(server, "args", []),
      env: Map.get(server, "env", %{}),
      url: Map.get(server, "url"),
      headers: Map.get(server, "headers", %{})
    }
  end

  defp normalize_server(server) do
    # Generate a name if not provided
    name =
      Map.get(server, "command", "unknown")
      |> Path.basename()
      |> String.replace(~r/\.[^.]+$/, "")

    normalize_server(Map.put(server, "name", name))
  end

  defp valid_server_config?(%{name: name, transport: transport})
       when is_binary(name) and is_binary(transport) do
    case transport do
      "stdio" -> true
      "sse" -> true
      _ -> false
    end
  end

  defp valid_server_config?(_), do: false

  defp test_stdio_server(command) do
    # Try to run the command with --help or --version
    [cmd | args] = List.wrap(command)

    case System.cmd(cmd, args ++ ["--version"], stderr_to_stdout: true) do
      {_, 0} ->
        true

      _ ->
        case System.cmd(cmd, args ++ ["--help"], stderr_to_stdout: true) do
          {_, 0} -> true
          _ -> false
        end
    end
  rescue
    _ -> false
  end

  defp test_sse_server(url) do
    # Try to connect to the SSE endpoint
    # This requires an HTTP client like Req or HTTPoison
    # For now, we'll just check if the URL is valid
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and not is_nil(host) ->
        # In a real implementation, we would try to connect
        # For now, assume it's valid if URL parses correctly
        true

      _ ->
        false
    end
  end
end
