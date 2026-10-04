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
  alias Arbor.MCP.Server.HTTP.{Bandit, Cowboy}

  @doc """
  Starts a server with the specified transport configuration.

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
    transport (default: `false`). Retained throughout Arbor.MCP 1.x
  * `:sse_enabled` - Deprecated rc.5 alias for `:legacy_http_sse`
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
        start_http_server(module, server_info, tools, opts)

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
  Starts an HTTP-based MCP server using the selected optional listener.

  Cowboy remains the default. Missing listener dependencies return
  `{:error, {:missing_http_listener_dependency, backend, package}}`.
  Mounting `Arbor.MCP.HttpPlug` in an existing host requires no standalone
  listener dependency.

  The HTTP transport allows integration with web applications and provides
  REST-like access to MCP functionality.
  """
  @spec start_http_server(module(), map(), list(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_http_server(module, server_info, _tools, opts) do
    port = Keyword.get(opts, :port, 4000)
    host = Keyword.get(opts, :host, "localhost")
    # Preserve the rc.5 server option aliases throughout 1.x, but never enable
    # the deprecated standalone SSE transport on a new server by default.
    legacy_http_sse =
      Keyword.get(
        opts,
        :legacy_http_sse,
        Keyword.get(opts, :sse_enabled, false) || Keyword.get(opts, :use_sse, false)
      )

    # Matches Arbor.MCP.HttpPlug's own default; CORS must be opted into (audit L10).
    cors_enabled = Keyword.get(opts, :cors_enabled, false)

    # Localhost-bound servers are the prime target for DNS rebinding, so
    # they get a Host allow-list (and matching localhost Origin allow-list)
    # by default. Explicit :allowed_hosts / :allowed_origins always win.
    allowed_hosts = Keyword.get(opts, :allowed_hosts, default_allowed_hosts(host))
    allowed_origins = Keyword.get(opts, :allowed_origins, default_allowed_origins(host, port))

    # Configure the HTTP Plug. Tools are read from the handler module, so the
    # `tools` argument is not forwarded (Arbor.MCP.HttpPlug.init/1 ignores it).
    plug_opts =
      [
        handler: module,
        server_info: server_info,
        legacy_http_sse: legacy_http_sse,
        cors_enabled: cors_enabled,
        allowed_hosts: allowed_hosts,
        allowed_origins: allowed_origins
      ] ++
        Keyword.take(opts, [
          :request_state,
          :mrtr,
          :path,
          :legacy_http_sse_path,
          :legacy_http_sse_post_path,
          :protocol_mode,
          :instructions,
          :server_capabilities,
          :handler_call_timeout,
          :max_input_requests,
          :max_mrtr_bytes,
          :replay_cache,
          :require_replay_protection
        ])

    if legacy_http_sse do
      Logger.warning(
        "The MCP 2024-11-05 HTTP+SSE transport is deprecated; migrate clients to Streamable HTTP"
      )
    end

    Logger.info(
      "Starting MCP HTTP server on #{inspect(host)}:#{port} " <>
        "(deprecated HTTP+SSE: #{legacy_http_sse})"
    )

    with {:ok, adapter} <- http_adapter(opts),
         {:ok, listener_opts} <- http_listener_options(adapter, opts, host, port) do
      case adapter.start(Arbor.MCP.HttpPlug, plug_opts, listener_opts) do
        {:ok, pid} ->
          Logger.info("MCP HTTP server started successfully")
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          Logger.info("MCP HTTP server already running")
          {:ok, pid}

        {:error, reason} ->
          Logger.error("Failed to start MCP HTTP server: #{inspect(reason)}")
          {:error, reason}
      end
    end
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

  defp http_listener_options(adapter, opts, host, port) do
    listener_opts = Keyword.get(opts, :http_listener_options, [])

    cond do
      not Keyword.keyword?(listener_opts) ->
        {:error, :invalid_http_listener_options}

      adapter == Bandit and not is_nil(Keyword.get(opts, :ranch_ref)) ->
        {:error, {:unsupported_http_option, :bandit, :ranch_ref}}

      true ->
        listener_opts = Keyword.merge(listener_opts, port: port, ip: parse_host(host))

        case adapter do
          Cowboy ->
            case Keyword.get(opts, :ranch_ref) do
              ref when ref in [nil, false] -> {:ok, listener_opts}
              ref -> {:ok, Keyword.put(listener_opts, :ref, ref)}
            end

          Bandit ->
            {:ok, Keyword.put(listener_opts, :scheme, :http)}
        end
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

  @localhost_hosts ["localhost", "127.0.0.1", "::1", "[::1]"]

  defp localhost_bind?(host) do
    host in @localhost_hosts or host == {127, 0, 0, 1} or host == {0, 0, 0, 0, 0, 0, 0, 1}
  end

  # Host allow-list for Arbor.MCP.HttpPlug: localhost binds get DNS rebinding
  # protection by default; other binds keep :any for backwards compatibility.
  defp default_allowed_hosts(host) do
    if localhost_bind?(host) do
      ["localhost", "127.0.0.1", "[::1]", "::1"]
    else
      :any
    end
  end

  # Origin allow-list for Arbor.MCP.HttpPlug. HttpPlug no longer has a
  # same-origin fallback (Host is attacker-controlled under DNS rebinding),
  # and Arbor.MCP's own HTTP client sends an Origin derived from the server URL,
  # so localhost binds explicitly allow localhost origins for the bound port.
  # This is rebinding-safe: a rebinding attack presents the attacker page's
  # real (non-localhost) origin.
  defp default_allowed_origins(host, port) do
    if localhost_bind?(host) do
      for h <- ["localhost", "127.0.0.1", "[::1]"],
          origin <- ["http://#{h}", "http://#{h}:#{port}"] do
        origin
      end
    else
      []
    end
  end

  # Parse host string to IP tuple
  defp parse_host(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        ip

      {:error, :einval} ->
        # Try resolving hostname
        case :inet.gethostbyname(String.to_charlist(host)) do
          {:ok, {:hostent, _, _, _, _, [ip | _]}} -> ip
          # Default to localhost
          _ -> {127, 0, 0, 1}
        end
    end
  end

  defp parse_host(host) when is_tuple(host), do: host
  defp parse_host(_), do: {127, 0, 0, 1}
end
