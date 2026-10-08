defmodule Arbor.MCP do
  @moduledoc """
  ArborMCP - Complete Elixir implementation of the Model Context Protocol.

  ArborMCP enables AI models to securely interact with local and remote resources through
  a standardized protocol. It provides both client and server implementations with
  multiple transport options.

  ## Public API

  ArborMCP provides a clean, focused public API. Start with these modules in your applications:

  ### Core Modules
  - `Arbor.MCP` - Package metadata and compatibility/startup shorthand
  - `Arbor.MCP.Client` - MCP client implementation
  - `Arbor.MCP.Server` - MCP server lifecycle and controls
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
  > **Public v2 API:** Client, Server lifecycle and Handler/DSL, documented transports, HttpPlug,
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
      {:ok, client} = Arbor.MCP.Client.start_link(
        transport: :stdio,
        command: ["python", "mcp-server.py"],
        protocol_mode: :prefer_modern
      )

      # Connect with HTTP
      {:ok, client} = Arbor.MCP.Client.start_link(
        transport: :http,
        url: "https://api.example.com",
        protocol_mode: :prefer_modern
      )

  ### Start a Server

      {:ok, server} = Arbor.MCP.Server.start_link(
        handler: MyApp.MCPHandler,
        transport: :stdio,
        protocol_mode: :prefer_modern
      )

  ### BEAM-Local Communication

      {:ok, server} = MyServer.start_link(transport: :beam)

      {:ok, client} = Arbor.MCP.Client.start_link(
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
        Arbor.MCP.Client.start_link(
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
        Arbor.MCP.Server.start_link(
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
        Arbor.MCP.Client.start_link(
          transport: :beam,
          server: server,
          protocol_mode: :prefer_modern
        )
      {:ok, result} = Arbor.MCP.Client.call_tool(client, "ping", %{})
  """

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.Internal.Convenience
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

  Shorthand for `Arbor.MCP.Server.start_link/1`, retaining the legacy `:test`
  transport default. Select `:beam`, `:stdio` or `:http` explicitly. The returned
  process is a linked runtime supervisor.

  ## Examples

      {:ok, server} = Arbor.MCP.start_server(
        handler: MyApp.Handler,
        transport: :stdio
      )

  """
  @spec start_server(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_server(opts) do
    opts |> Keyword.put_new(:transport, :test) |> Arbor.MCP.Server.start_link()
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

  @type client :: Client.t()
  @type connection_spec :: String.t() | {atom(), keyword()} | [any()] | Arbor.MCP.ClientConfig.t()

  @doc """
  Compatibility connection wrapper. Prefer `Arbor.MCP.Client.connect/2` in new code.

  This wrapper retains its original command-string parsing and first-spec-only behavior.

  This function provides a simplified interface to the MCP client with
  automatic connection configuration and transport selection.

  A list of connection specs is accepted for
  compatibility, but only the first spec is used. Remaining specs are
  ignored. This is not a failover. Multi-transport fallback is not
  implemented by this facade.

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
  def connect(connection_spec, opts \\ []), do: Convenience.connect(connection_spec, opts)

  @doc """
  Compatibility shutdown wrapper; this stops the client process.

  Prefer `Arbor.MCP.Client.stop/1` for termination.
  `Arbor.MCP.Client.disconnect/1` closes the transport and retains the process.

  Already-stopped clients return `:ok`. A cleanup timeout or failure is
  returned explicitly; client process death alone does not confirm physical IO cleanup.
  """
  @spec disconnect(client()) :: :ok | {:error, term()}
  def disconnect(client), do: Convenience.disconnect(client)

  @doc """
  Compatibility wrapper for `Arbor.MCP.Client.tool_definitions/2`.

  Returns `{:ok, tools}` where `tools` is a list of tool definitions with
  their schemas and descriptions, or `{:error, reason}` if the request fails
  or the client is dead/unresponsive. `format: :map` or `:struct` returns the
  complete page, retaining its cursor and metadata. `:cursor` and supported
  Client request controls are forwarded.
  """
  @spec tools(client(), keyword()) :: {:ok, [map()] | map() | Response.t()} | {:error, any()}
  def tools(client, opts \\ []), do: Client.tool_definitions(client, opts)

  @doc """
  Compatibility wrapper for `Arbor.MCP.Client.call_content/4`.

  `Arbor.MCP.Client.call/4` and `call_tool/4` preserve the complete response.

  Returns `{:ok, result}` on success or `{:error, reason}` if the request
  fails or the client is dead/unresponsive. With `normalize: true` (the
  default) `result` is the extracted text content; with `normalize: false`
  it is the complete Response struct. `format: :map` returns the wire result map;
  `format: :struct` returns the complete struct. Either format disables implicit
  text extraction. Normalized tool failures return `{:error, ToolError}` with
  the full result retained in its reason.

  ## Options

  - `:timeout` - Request timeout in milliseconds (default: 30_000)
  - `:normalize` - Extract text (default: true unless `:format` is supplied)
  - `:format` - Complete `:map` or `:struct` result
  - Request controls from `Arbor.MCP.Client.call_tool/4`, including progress,
    metadata, retry policy and idempotency keys, are forwarded unchanged.
    Unknown options raise `ArgumentError`.

  ## Examples

      # Simple call
      {:ok, result} = Arbor.MCP.call(client, "calculator", %{op: "add", a: 1, b: 2})

      # With options
      {:ok, result} = Arbor.MCP.call(client, "slow_tool", %{data: "..."}, timeout: 60_000)
  """
  @spec call(client(), String.t(), map(), keyword()) :: {:ok, any()} | {:error, any()}
  def call(client, tool_name, args \\ %{}, opts \\ []),
    do: Client.call_content(client, tool_name, args, opts)

  @doc """
  Compatibility wrapper for `Arbor.MCP.Client.resource_definitions/2`.

  Returns `{:ok, resources}` on success, or `{:error, reason}` if the
  request fails or the client is dead/unresponsive. `format: :map` or `:struct`
  returns the complete page, retaining its cursor and metadata. `:cursor` and
  supported Client request controls are forwarded.
  """
  @spec resources(client(), keyword()) :: {:ok, [map()] | map() | Response.t()} | {:error, any()}
  def resources(client, opts \\ []), do: Client.resource_definitions(client, opts)

  @doc """
  Compatibility wrapper for `Arbor.MCP.Client.read_content/3`.

  Returns `{:ok, content}` on success, or `{:error, reason}` if the request
  fails or the client is dead/unresponsive.

  ## Options

  - `:timeout` - Request timeout in milliseconds (default: 10_000)
  - `:parse_json` - Parse extracted text as JSON (default: false)
  - `:format` - Return the complete `:map` or `:struct` result. Cannot be
    combined with `parse_json: true`. The default extracts text from `contents`;
    nontext-only resources retain the complete result.
  - Supported Client request controls are forwarded. Unknown options raise.

  ## Examples

      # Read text content
      {:ok, content} = Arbor.MCP.read(client, "file://data.txt")

      # Read and parse JSON
      {:ok, data} = Arbor.MCP.read(client, "file://config.json", parse_json: true)
  """
  @spec read(client(), String.t(), keyword()) :: {:ok, any()} | {:error, any()}
  def read(client, uri, opts \\ []), do: Client.read_content(client, uri, opts)

  @doc """
  Compatibility status wrapper. Prefer `Arbor.MCP.Client.status/2`.

  Returns `{:ok, status}` on success, or `{:error, reason}` if the client
  is dead/unresponsive.
  """
  @spec status(client()) :: {:ok, map()} | {:error, any()}
  def status(client), do: Convenience.status(client)

  @doc """
  Compatibility connectivity probe. Prefer `Arbor.MCP.Client.probe/2` in new code.

  `Arbor.MCP.Client.ping/2` sends a protocol ping on an existing connection.
  """
  @spec ping(connection_spec(), keyword()) :: :ok | {:error, any()}
  def ping(connection_spec, opts \\ []), do: Convenience.ping(connection_spec, opts)

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
        :type_safety
      ]
    }
  end

  # Private Helper Functions
end
