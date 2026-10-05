defmodule Arbor.MCP.Server.Transport do
  @moduledoc """
  Transport configuration and lifecycle management for Arbor.MCP servers.

  This module provides unified transport startup and configuration for MCP servers,
  supporting stdio, HTTP, BEAM-local, and test transports.

  ## Usage

      # Start with HTTP transport
      {:ok, _pid} = Arbor.MCP.Server.Transport.start_server(MyServer, server_info, tools, transport: :http, port: 4000)

      # Start with stdio transport
      {:ok, _pid} = Arbor.MCP.Server.Transport.start_server(MyServer, server_info, tools, transport: :stdio)

      # Explicitly retain the deprecated 2024-11-05 HTTP+SSE transport
      {:ok, _pid} = Arbor.MCP.Server.Transport.start_server(MyServer, server_info, tools,
        transport: :http,
        legacy_http_sse: true,
        port: 8080
      )
  """

  require Logger

  alias Arbor.MCP.Server.{Runtime, StdioServer}
  alias Arbor.MCP.Server.HTTP.{Bandit, Config, Cowboy, CowboyClaims}
  alias Arbor.MCP.Server.Runtime.{Admission, Initialization, Ref}

  @doc """
  Starts a server with the specified transport configuration.

  HTTP and stdio startup return the runtime supervisor PID. The HTTP runtime
  owns its optional listener and initializes the handler once. `:name` names
  the runtime root. `http: [adapter: :bandit, port: 4000]` is also supported.

  ## Options

  * `:transport` - The transport type (`:stdio`, `:http`, `:beam`, `:test`)
  * `:port` - Port number for HTTP transports (default: 4000)
  * `:host` - Host for HTTP transports (default: "localhost")
  * `:http_adapter` - Explicit standalone listener, `:cowboy` (default) or
    `:bandit`. The selected listener package must be installed by the host
  * `:http_listener_options` - Backend-specific listener options. The top-level
    `:port`, `:host`, and `:ranch_ref` keep precedence
  * `:ranch_ref` - Cowboy listener reference; rejected by the Bandit adapter
  * `:cors_enabled` - Enable CORS for HTTP transports (default: `false`, the
    same default `Arbor.MCP.HttpPlug` uses)
  * `:legacy_http_sse` - Enable the deprecated MCP 2024-11-05 HTTP+SSE
    transport (default: `false`). Available for explicitly selected legacy routes
  * `:sse_enabled` / `:use_sse` - Removed server constructor aliases; use `:legacy_http_sse`
  * `:allowed_hosts` - Host-header allow-list passed to `Arbor.MCP.HttpPlug`.
    Defaults to the localhost names when binding to a localhost address
    (DNS rebinding protection), otherwise `:any`
  * `:allowed_origins` - Origin allow-list passed to `Arbor.MCP.HttpPlug`.
    Defaults to localhost origins for the bound port when binding to a
    localhost address, otherwise `[]` (reject all cross-origin browsers)

  ## Examples

      # HTTP server
      Arbor.MCP.Server.Transport.start_server(MyServer, %{name: "my-server", version: "1.0.0"}, [],
        transport: :http, port: 4000)

      # Stdio server
      Arbor.MCP.Server.Transport.start_server(MyServer, %{name: "my-server", version: "1.0.0"}, [],
        transport: :stdio)
  """
  @spec start_server(module(), map(), list(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_server(module, server_info, tools, opts \\ []) do
    transport = Keyword.get(opts, :transport, :http)

    case transport do
      :stdio ->
        start_stdio_server(module, server_info, tools, opts)

      :http ->
        Runtime.start_link(Keyword.merge(opts, handler: module, transport: :http))

      :beam ->
        start_beam_server(module, server_info, tools, opts)

      :test ->
        start_test_server(module, server_info, tools, opts)

      _ ->
        {:error, {:unsupported_transport, transport}}
    end
  end

  @doc """
  Starts a stdio-based MCP server.

  The stdio transport communicates via standard input/output, making it suitable
  for command-line tools and scripting environments.
  """
  @spec start_stdio_server(module(), map(), list(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_stdio_server(module, _server_info, _tools, opts) do
    StdioServer.start_link([module: module] ++ opts)
  end

  @doc """
  Starts an HTTP listener borrowing an existing initialized runtime.

  `:runtime` must be that runtime's root PID, registered name or opaque reference,
  and its handler must match `module`. This helper returns the actual listener
  PID and does not stop the runtime when its listener stops. For an endpoint
  whose runtime owns the listener, use `start_server/4` or
  `Runtime.start_link(handler: module, transport: :http, http: [...])`.

  The retained `server_info` and `tools` arguments do not initialize a handler;
  initialization metadata and tool callbacks come from the runtime's handler.

  Cowboy remains the default. Missing listener dependencies return
  `{:error, {:missing_http_listener_dependency, backend, package}}`.
  Mounting `Arbor.MCP.HttpPlug` in an existing host requires no standalone
  listener dependency.

  The HTTP transport allows integration with web applications and provides
  REST-like access to MCP functionality.
  """
  @spec start_http_server(module(), map(), list(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_http_server(module, _server_info, _tools, opts) do
    with {:ok, http} <- Config.new(opts, :borrowed),
         {:ok, runtime} <- borrowed_runtime(opts, module),
         :ok <- borrowed_reference(http) do
      borrowed_start(http, runtime)
    end
  end

  defp borrowed_reference(%{backend: :cowboy, ranch_ref: ref}),
    do: CowboyClaims.borrowed_available?(ref)

  defp borrowed_reference(_http), do: :ok

  defp borrowed_start(http, runtime) do
    result =
      http.adapter.start(
        Arbor.MCP.HttpPlug,
        Keyword.put(http.plug_options, :runtime, runtime),
        http.listener_options
      )

    if http.backend == :cowboy, do: normalize_borrowed_result(result), else: result
  end

  defp normalize_borrowed_result({:error, {:already_started, pid}}), do: {:ok, pid}
  defp normalize_borrowed_result(result), do: result

  defp borrowed_runtime(opts, module) do
    with {:ok, runtime} <- Runtime.ref(Keyword.get(opts, :runtime)),
         {:ok, route} <- Admission.route(Ref.table(runtime)),
         true <- Initialization.ready?(Ref.table(runtime)),
         true <- route.config.handler == module do
      {:ok, runtime}
    else
      false -> {:error, :http_runtime_handler_mismatch}
      _unavailable -> {:error, :http_runtime_required}
    end
  end

  @doc """
  Returns the actual listener identity owned by an HTTP runtime.

  The map contains `:listener` (PID), `:adapter`, and Cowboy's `:ranch_ref`.
  Stop the owned endpoint through `Runtime.stop/1` or its supervising parent.
  Borrowed standalone listeners are returned directly by `start_http_server/4`.
  """
  @spec http_listener(Runtime.server()) :: {:ok, map()} | {:error, atom()}
  def http_listener(server) do
    with {:ok, runtime} <- Runtime.ref(server),
         true <- Initialization.ready?(Ref.table(runtime)),
         [{:http_listener, %{listener: listener} = info}] <-
           :ets.lookup(Ref.table(runtime), :http_listener),
         true <- Process.alive?(listener) do
      {:ok, info}
    else
      _unavailable -> {:error, :http_listener_unavailable}
    end
  rescue
    ArgumentError -> {:error, :http_listener_unavailable}
  end

  @doc """
  Stops a standalone HTTP listener using its selected backend.

  Cowboy accepts the returned PID or its Ranch reference. Bandit accepts its
  returned PID. This closes only that listener; a mounted HTTP host must stop
  its own listener through its existing supervision tree.

  `:http_shutdown_timeout` is a positive finite budget in milliseconds (default
  `5_000`). A timeout returns an error; the host should retain the listener
  identity and check or complete cleanup rather than assume it has stopped.
  """
  @spec stop_http_server(term(), keyword()) :: :ok | {:error, term()}
  def stop_http_server(listener, opts \\ []) do
    with {:ok, adapter} <- http_adapter(opts),
         do: adapter.stop(listener, Keyword.get(opts, :http_shutdown_timeout, 5_000))
  end

  defp http_adapter(opts) do
    case Keyword.get(opts, :http_adapter, :cowboy) do
      :cowboy -> {:ok, Cowboy}
      :bandit -> {:ok, Bandit}
      adapter -> {:error, {:unsupported_http_adapter, adapter}}
    end
  end

  @doc """
  Starts a BEAM-local MCP server.

  The BEAM transport uses Erlang message passing for high-performance local
  communication between processes while preserving MCP-shaped messages.
  """
  @spec start_beam_server(module(), map(), list(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_beam_server(module, _server_info, _tools, opts) do
    Logger.info("Starting MCP BEAM server: #{module}")

    # Start the server module directly as a GenServer
    case module.start_link(opts) do
      {:ok, pid} ->
        Logger.info("MCP BEAM server started successfully")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.info("MCP BEAM server already running")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to start MCP BEAM server: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Starts a test transport-based MCP server.

  The test transport uses in-memory communication for efficient
  testing without external processes or network connections.
  """
  @spec start_test_server(module(), map(), list(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_test_server(module, _server_info, _tools, opts) do
    Logger.debug("Starting MCP test server: #{module}")

    # Start the server module directly as a GenServer with test transport
    case module.start_link(opts) do
      {:ok, pid} ->
        Logger.debug("MCP test server started successfully")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.debug("MCP test server already running")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to start MCP test server: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Stops a running MCP server.

  Runtime roots, registered names and references use the runtime's overall
  shutdown budget and cleanup of explicitly owned descendants. A parent still
  applies its restart policy; terminate a managed child through its parent when
  the endpoint should remain stopped. Legacy GenServers keep their stop behavior.
  """
  @spec stop_server(Runtime.server()) :: :ok | {:error, term()}
  def stop_server(server) do
    case Runtime.ref(server) do
      {:ok, runtime} -> Runtime.stop(runtime)
      {:error, _reason} -> stop_transport_server(server)
    end
  end

  defp stop_transport_server(server) when is_pid(server) do
    case Cowboy.reference(server) do
      {:ok, ref} ->
        Cowboy.stop(ref)

      {:error, :not_found} ->
        if Bandit.listener?(server), do: Bandit.stop(server), else: GenServer.stop(server)

      {:error, _reason} = error ->
        error
    end
  end

  defp stop_transport_server(server) when is_atom(server) do
    case Process.whereis(server) do
      nil -> :ok
      pid -> stop_server(pid)
    end
  end

  defp stop_transport_server(_unavailable), do: {:error, :runtime_unavailable}

  @doc """
  Gets information about a running server.
  """
  @spec server_info(Runtime.server()) :: {:ok, map()} | {:error, term()}
  def server_info(server) do
    case Arbor.MCP.Server.call(server, :get_server_info, 5000) do
      info when is_map(info) -> {:ok, info}
      _ -> {:error, :no_server_info}
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Lists all available transports and their status.
  """
  @spec list_transports() :: map()
  def list_transports do
    %{
      stdio: %{
        available: Code.ensure_loaded?(StdioServer),
        description: "Standard input/output transport for CLI tools"
      },
      http: %{
        available: Cowboy.available?() or Bandit.available?(),
        adapters: %{cowboy: Cowboy.available?(), bandit: Bandit.available?()},
        description: "HTTP transport through an optional listener or mounted Plug"
      },
      beam: %{
        available: true,
        description: "BEAM-local MCP transport"
      },
      test: %{
        available: true,
        description: "In-memory transport for testing"
      }
    }
  end
end
