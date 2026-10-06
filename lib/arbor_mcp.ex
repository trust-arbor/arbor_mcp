defmodule Arbor.MCP do
  @moduledoc """
  ArborMCP - Complete Elixir implementation of the Model Context Protocol.

  ArborMCP enables AI models to securely interact with local and remote resources through
  a standardized protocol. It provides both client and server implementations with
  multiple transport options.

  ## Public API

  ArborMCP provides a clean, focused public API. Only use these modules in your applications:

  ### Core Modules
  - `Arbor.MCP` - This module (convenience functions and metadata)
  - `Arbor.MCP.Client` - MCP client implementation
  - `Arbor.MCP.Server` - MCP server helper functions
  - `Arbor.MCP.Server.Handler` - Callback behaviour for MCP servers
  - `Arbor.MCP.Server.DSL` - Declarative tool/resource/prompt definitions
  - `Arbor.MCP.Server.Result` - Complete results shared by Handler and DSL callbacks
  - `Arbor.MCP.Transport` - Transport behaviour definition

  ### Optional Features
  - `Arbor.MCP.Authorization` - OAuth 2.1 authorization flows (MCP optional feature)

  ### Supporting Modules
  - `Arbor.MCP.Content` - Content type helpers (builders; advanced transform/sanitize is experimental)
  - `Arbor.MCP.Types` - Type definitions (stable across versions)
  - `Arbor.MCP.HttpPlug` - Phoenix/Plug MCP endpoint
  - `Arbor.MCP.Error` / `Arbor.MCP.Response` - Error and response helpers

  ### Server definitions
  Static tools, resources, templates, and prompts use `Arbor.MCP.Server.DSL`.
  Dynamic tool catalogs belong in application Handler state through
  `handle_list_tools/2` and `handle_call_tool/3`. The old `Server.Tools` family
  was removed in v2; see the
  [application-owned dynamic tool example](https://github.com/trust-arbor/arbor_mcp/blob/master/examples/dynamic_tools.exs).

  > #### Internal Modules {: .warning}
  >
  > All other modules under the `Arbor.MCP` namespace are internal implementation details
  > and may change without notice. Do not depend on them directly in your applications.

  > #### Stability {: .info}
  >
  > **Stable for 1.0:** Client, Server Handler/DSL, documented transports, HttpPlug,
  > Types, Content builders and Authorization entry points. ACP is a separate package.
  >
  > **May change in minors:** experimental content transformers and anything marked
  > deprecated. MCP 2026-07-28 is the latest stable revision and is available through
  > `:prefer_modern` and `:modern_only`. Starting in rc.6, new connections default
  > to `:prefer_modern`; `:legacy_only` preserves the legacy protocol era, not an
  > exact rc.5 package rollback. The zero-arity
  > compatibility helpers continue to report the newest initialize-compatible
  > legacy revision, 2025-11-25.

  ## Quick Start

  ### Start a Client

      # Connect to stdio server
      {:ok, client} = Arbor.MCP.start_client(
        transport: :stdio,
        command: ["python", "mcp-server.py"],
        protocol_mode: :prefer_modern
      )

      # Connect with HTTP
      {:ok, client} = Arbor.MCP.start_client(
        transport: :http,
        url: "https://api.example.com",
        protocol_mode: :prefer_modern
      )

  ### Start a Server

      {:ok, server} = Arbor.MCP.start_server(
        handler: MyApp.MCPHandler,
        transport: :stdio,
        protocol_mode: :prefer_modern
      )

  ### BEAM-Local Communication

      {:ok, server} = MyServer.start_link(transport: :beam)

      {:ok, client} = Arbor.MCP.start_client(
        transport: :beam,
        server: server,
        protocol_mode: :prefer_modern
      )

      {:ok, tools} = Arbor.MCP.Client.list_tools(client)

  ## Protocol Versions

  ArborMCP supports two wire-incompatible MCP eras:
  - **2026-07-28** - Latest stable revision; stateless discovery, per-request
    context, result envelopes, MRTR, and `subscriptions/listen`
  - **2025-11-25** - Newest legacy revision; tasks, icons, and URL elicitation
  - **2025-06-18** - Structured output, OAuth 2.1, elicitation, no batch
  - **2025-03-26** - Subscriptions, roots, logging, and batch support
  - **2024-11-05** - Initial stable MCP revision

  rc.7 defaults to `protocol_mode: :prefer_modern`, which tries the modern
  revision first and retains evidence-based legacy fallback. Use
  `protocol_mode: :modern_only` for a closed modern ecosystem or
  `protocol_mode: :legacy_only` to preserve the legacy protocol era. Exact
  rc.5 wire and session behavior still requires package rollback to
  `1.0.0-rc.5`.

  See the Configuration and Migration guides for the era comparison and
  rollout policy.

  ## Features

  - **Tools** - Register and execute functions with parameters
  - **Resources** - List and read data from various sources
  - **Prompts** - Manage reusable prompt templates
  - **Sampling** - Protocol-deprecated in MCP 2026-07-28; retained throughout
    ArborMCP 1.x for compatibility. Prefer direct LLM provider APIs for new code
  - **Roots** - Protocol-deprecated in MCP 2026-07-28; retained throughout
    ArborMCP 1.x. Prefer tool parameters, resource URIs, or server configuration
  - **Subscriptions** - Monitor resources for changes
  - **Progress** - Track long-running operations
  - **Notifications** - Real-time updates for changes
  - **BEAM-local MCP** - High-performance Elixir-to-Elixir communication

  ## Transport Options

  - **stdio** - Process communication (standard MCP)
  - **Streamable HTTP** - Web-friendly transport (standard MCP)
  - **BEAM-local MCP** - Direct Erlang process communication (ArborMCP extension)

  ## Examples

  ### Basic Client Usage

      {:ok, client} =
        Arbor.MCP.start_client(
          transport: :stdio,
          command: ["mcp-server"],
          protocol_mode: :prefer_modern
        )

      # List and call tools
      {:ok, %{tools: tools}} = Arbor.MCP.Client.list_tools(client)
      {:ok, result} = Arbor.MCP.Client.call_tool(client, "search", %{query: "elixir"})

      # Read resources
      {:ok, content} = Arbor.MCP.Client.read_resource(client, "file:///data.json")

  ### Basic Server Usage

  > #### Tip
  > Most servers are easier to write with the DSL:
  >
  > ```elixir
  > defmodule MyServer do
  >   use Arbor.MCP.Server.Handler
  >   use Arbor.MCP.Server.DSL, name: "my-server", version: "1.0.0"
  >
  >   tool "echo", "Echo the message" do
  >     param :message, :string, required: true
  >     run fn %{message: msg}, state ->
  >       {:ok, %{content: [%{type: "text", text: msg}]}, state}
  >     end
  >   end
  > end
  >
  > {:ok, server} =
  >   MyServer.start_link(transport: :stdio, protocol_mode: :prefer_modern)
  > ```

      defmodule MyHandler do
        use Arbor.MCP.Server.Handler

        @impl true
        def handle_initialize(_params, state) do
          {:ok, %{
            protocolVersion: Arbor.MCP.protocol_version(),
            serverInfo: %{name: "my-handler", version: "1.0.0"},
            capabilities: %{tools: %{}}
          }, state}
        end

        @impl true
        def handle_list_tools(_cursor, state) do
          tools = [%{name: "echo", description: "Echo input", inputSchema: %{type: "object"}}]
          {:ok, tools, nil, state}
        end

        @impl true
        def handle_call_tool("echo", params, state) do
          {:ok, %{content: [%{type: "text", text: params["message"]}]}, state}
        end
      end

      {:ok, server} =
        Arbor.MCP.start_server(
          handler: MyHandler,
          transport: :stdio,
          protocol_mode: :prefer_modern
        )

  ### BEAM-Local Service

      defmodule MyService do
        use Arbor.MCP.Server.Handler
        use Arbor.MCP.Server.DSL

        tool "ping", "Health check" do
          run fn _args, state ->
            {:ok, %{content: [%{type: "text", text: "pong"}]}, state}
          end
        end
      end

      {:ok, server} =
        MyService.start_link(transport: :beam, protocol_mode: :prefer_modern)

      {:ok, client} =
        Arbor.MCP.start_client(
          transport: :beam,
          server: server,
          protocol_mode: :prefer_modern
        )
      {:ok, result} = Arbor.MCP.Client.call_tool(client, "ping", %{})
  """

  alias Arbor.MCP.Client
  alias Arbor.MCP.Error
  alias Arbor.MCP.Internal.VersionRegistry
  alias Arbor.MCP.Response

  @doc """
  Convenience function to start an MCP client.

  This is equivalent to `Arbor.MCP.Client.start_link/1` but provides a simpler
  entry point for common use cases.

  ## Examples

      # stdio transport
      {:ok, client} = Arbor.MCP.start_client(
        transport: :stdio,
        command: ["python", "mcp-server.py"]
      )

      # HTTP transport
      {:ok, client} = Arbor.MCP.start_client(
        transport: :http,
        url: "https://api.example.com"
      )

  """
  @spec start_client(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_client(opts) do
    Client.start_link(opts)
  end

  @doc """
  Convenience function to start an MCP server.

  This is equivalent to `Arbor.MCP.Server.HandlerServer.start_link/1` but provides a simpler
  entry point for common use cases.

  ## Examples

      {:ok, server} = Arbor.MCP.start_server(
        handler: MyApp.Handler,
        transport: :stdio
      )

  """
  @spec start_server(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_server(opts) do
    Arbor.MCP.Server.HandlerServer.start_link(opts)
  end

  @doc """
  Returns the legacy protocol revision used by zero-arity compatibility paths.

  This returns `"2025-11-25"`, the newest initialize-based legacy revision.
  MCP `2026-07-28` is the latest stable revision but is selected through
  `:protocol_mode`, not this scalar helper.
  """
  @spec protocol_version() :: String.t()
  def protocol_version do
    VersionRegistry.latest_version()
  end

  @doc """
  Returns the version of the ArborMCP library.
  """
  @spec version() :: String.t()
  def version do
    Application.spec(:arbor_mcp, :vsn) |> to_string()
  end

  @doc """
  Returns the initialize-compatible legacy protocol revisions.

  Modern `2026-07-28` support is enabled through `:prefer_modern` or
  `:modern_only` and is intentionally not added to this legacy compatibility
  list during the RC soak.
  """
  @spec supported_versions() :: [String.t()]
  def supported_versions do
    VersionRegistry.supported_versions()
  end

  # Convenience Functions

  @type client :: pid()
  @type connection_spec :: String.t() | {atom(), keyword()} | [any()] | Arbor.MCP.ClientConfig.t()

  @doc """
  Connects to an MCP server using the unified client implementation.

  This function provides a simplified interface to the MCP client with
  automatic connection configuration and transport selection.

  A list of connection specs is still accepted throughout 1.x for
  compatibility, but only the first spec is used. Remaining specs are
  ignored. This is not a failover. Multi-transport fallback is not
  implemented in 1.x.

  ## Options

  - `:timeout` - Connection timeout in milliseconds (default: 10_000)
  - `:retry_attempts` - Number of retry attempts (default: 3)
  - Transport-specific options (see Arbor.MCP.Client docs)

  ## Examples

      # HTTP connection
      {:ok, client} = Arbor.MCP.connect("http://localhost:8080")

      # Stdio connection
      {:ok, client} = Arbor.MCP.connect({:stdio, command: "my-server"})

      # A list is accepted throughout 1.x, but only the first spec is used
      {:ok, client} = Arbor.MCP.connect([
        "http://primary:8080",
        "http://backup:8080"
      ])

      # Using ClientConfig for advanced configuration
      config = Arbor.MCP.ClientConfig.new(:production)
      |> Arbor.MCP.ClientConfig.put_transport(:http, url: "https://api.example.com")
      |> Arbor.MCP.ClientConfig.put_auth(:bearer, token: "secret")
      |> Arbor.MCP.ClientConfig.put_retry_policy(max_attempts: 5)
      {:ok, client} = Arbor.MCP.connect(config)
  """
  @spec connect(connection_spec(), keyword()) :: {:ok, client()} | {:error, any()}
  def connect(connection_spec, opts \\ [])

  def connect(%Arbor.MCP.ClientConfig{} = config, opts) do
    # ClientConfig provided - convert to client options and connect
    client_opts = Arbor.MCP.ClientConfig.to_client_opts(config)

    # Merge any additional opts (ignore deprecated client_type option)
    final_opts = Keyword.merge(client_opts, Keyword.drop(opts, [:client_type]))

    Client.start_link(final_opts)
  end

  def connect(connection_spec, opts) when is_list(connection_spec) do
    # 1.x compatibility: a list is accepted but only the first spec is used.
    # This is not a failover.
    case List.first(connection_spec) do
      nil -> {:error, :no_connections_specified}
      first_spec -> connect(first_spec, opts)
    end
  end

  def connect(connection_spec, opts) do
    # Convert connection spec to unified Client format (ignore deprecated client_type)
    client_opts =
      normalize_connection_for_client(connection_spec, Keyword.drop(opts, [:client_type]))

    Client.start_link(client_opts)
  end

  @doc """
  Disconnects from an MCP server.
  """
  @spec disconnect(client()) :: :ok
  def disconnect(client) do
    # Gracefully stop the unified client
    GenServer.stop(client, :normal)
  catch
    # Already stopped
    :exit, _ -> :ok
  end

  @doc """
  Lists available tools from the connected server.

  Returns `{:ok, tools}` where `tools` is a list of tool definitions with
  their schemas and descriptions, or `{:error, reason}` if the request fails
  or the client is dead/unresponsive.
  """
  @spec tools(client(), keyword()) :: {:ok, [map()]} | {:error, any()}
  def tools(client, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    case Client.list_tools(client, timeout: timeout, format: :map) do
      {:ok, result} when is_map(result) ->
        # Extract tools list from the result map (string or atom keys)
        {:ok, Map.get(result, "tools") || Map.get(result, :tools) || []}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, _reason -> {:error, Error.connection_error("Client not responding")}
  end

  @doc """
  Calls a tool on the connected server.

  Returns `{:ok, result}` on success or `{:error, reason}` if the request
  fails or the client is dead/unresponsive. With `normalize: true` (the
  default) `result` is the extracted text content; with `normalize: false`
  it is the raw response.

  ## Options

  - `:timeout` - Request timeout in milliseconds (default: 30_000)
  - `:normalize` - Whether to normalize the response (default: true)

  ## Examples

      # Simple call
      {:ok, result} = Arbor.MCP.call(client, "calculator", %{op: "add", a: 1, b: 2})

      # With options
      {:ok, result} = Arbor.MCP.call(client, "slow_tool", %{data: "..."}, timeout: 60_000)
  """
  @spec call(client(), String.t(), map(), keyword()) :: {:ok, any()} | {:error, any()}
  def call(client, tool_name, args \\ %{}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    normalize = Keyword.get(opts, :normalize, true)

    case Client.call_tool(client, tool_name, args, timeout) do
      {:ok, result} ->
        if normalize do
          {:ok, extract_tool_result_content(result)}
        else
          {:ok, result}
        end

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, _reason -> {:error, Error.connection_error("Client not responding")}
  end

  @doc """
  Lists available resources from the connected server.

  Returns `{:ok, resources}` on success, or `{:error, reason}` if the
  request fails or the client is dead/unresponsive.
  """
  @spec resources(client(), keyword()) :: {:ok, [map()]} | {:error, any()}
  def resources(client, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    case Client.list_resources(client, timeout: timeout, format: :map) do
      {:ok, result} when is_map(result) ->
        # Extract resources list from the result map (string or atom keys)
        {:ok, Map.get(result, "resources") || Map.get(result, :resources) || []}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, _reason -> {:error, Error.connection_error("Client not responding")}
  end

  @doc """
  Reads a resource from the connected server.

  Returns `{:ok, content}` on success, or `{:error, reason}` if the request
  fails or the client is dead/unresponsive.

  ## Options

  - `:timeout` - Request timeout in milliseconds (default: 10_000)
  - `:parse_json` - Automatically parse JSON content (default: false)

  ## Examples

      # Read text content
      {:ok, content} = Arbor.MCP.read(client, "file://data.txt")

      # Read and parse JSON
      {:ok, data} = Arbor.MCP.read(client, "file://config.json", parse_json: true)
  """
  @spec read(client(), String.t(), keyword()) :: {:ok, any()} | {:error, any()}
  def read(client, uri, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    parse_json = Keyword.get(opts, :parse_json, false)

    case Client.read_resource(client, uri, timeout: timeout, format: :map) do
      {:ok, response} -> {:ok, process_read_response(response, parse_json)}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _reason -> {:error, Error.connection_error("Client not responding")}
  end

  defp process_read_response(response, parse_json) when is_map(response) do
    content = extract_resource_content(response)

    if parse_json and is_binary(content) do
      parse_json_content(content)
    else
      content
    end
  end

  defp extract_resource_content(response) when is_map(response) do
    # Try to extract content from the response map
    case response do
      %{"content" => [%{"type" => "text", "text" => text} | _]} ->
        text

      %{"content" => content} when is_list(content) ->
        # Extract and join all text content
        Enum.map_join(
          Enum.filter(content, &(is_map(&1) and Map.get(&1, "type") == "text")),
          "\n",
          &Map.get(&1, "text")
        )

      %{"text" => text} when is_binary(text) ->
        text

      _ ->
        nil
    end
  end

  defp parse_json_content(content) do
    case Jason.decode(content) do
      {:ok, parsed} -> parsed
      {:error, _} -> content
    end
  end

  defp extract_tool_result_content(%Response{} = response) do
    # Handle Response struct - use the text_content function
    Response.text_content(response)
  end

  defp extract_tool_result_content(result) when is_map(result) do
    # Try to extract text content from the result
    case result do
      %{"content" => [%{"type" => "text", "text" => text} | _]} ->
        text

      %{"content" => content} when is_list(content) ->
        # Extract all text content
        Enum.map_join(
          Enum.filter(content, &(is_map(&1) and Map.get(&1, "type") == "text")),
          "\n",
          &Map.get(&1, "text")
        )

      _ ->
        # Return the full result if we can't extract text
        result
    end
  end

  defp extract_tool_result_content(result), do: result

  @doc """
  Gets connection status and server information.

  Returns `{:ok, status}` on success, or `{:error, reason}` if the client
  is dead/unresponsive.
  """
  @spec status(client()) :: {:ok, map()} | {:error, any()}
  def status(client) do
    Client.get_status(client)
  catch
    :exit, _reason -> {:error, Error.connection_error("Client not responding")}
  end

  @doc """
  Tests connectivity to an MCP server without establishing a persistent connection.
  """
  @spec ping(connection_spec(), keyword()) :: :ok | {:error, any()}
  def ping(connection_spec, opts \\ []) do
    # Quick connection test using unified client
    case connect(connection_spec, opts) do
      {:ok, client} ->
        result =
          case status(client) do
            {:ok, _} -> :ok
            error -> error
          end

        disconnect(client)
        result

      error ->
        error
    end
  end

  @doc """
  Gets library configuration and capabilities.
  """
  @spec info() :: map()
  def info do
    %{
      version: version(),
      protocol_versions: supported_versions(),
      transports: [:http, :stdio, :beam],
      features: [
        :structured_responses,
        :backward_compatibility,
        :dsl_syntax,
        :automatic_reconnection,
        :transport_fallback,
        :type_safety
      ]
    }
  end

  # Private Helper Functions

  defp normalize_connection_for_client(connection_spec, opts) when is_binary(connection_spec) do
    # Parse URL and convert to transport options
    uri = URI.parse(connection_spec)

    transport_opts =
      case uri.scheme do
        "http" -> [transport: :http, url: connection_spec]
        "https" -> [transport: :http, url: connection_spec]
        _ -> [transport: :stdio, command: connection_spec]
      end

    Keyword.merge(transport_opts, opts)
  end

  defp normalize_connection_for_client({transport, transport_opts}, opts) do
    [transport: transport] ++ transport_opts ++ opts
  end

  defp normalize_connection_for_client(connection_spec, opts) do
    # For other formats, pass through
    Keyword.merge([connection: connection_spec], opts)
  end
end
