defmodule Arbor.MCP.Transport.Local do
  @moduledoc """
  Local BEAM transport for Arbor.MCP.

  This module provides a high-performance transport for BEAM-based communication.
  It carries MCP-shaped JSON-RPC messages as Elixir terms between local
  processes. The transport itself does not JSON encode or decode messages.

  ## Features

  - MCP-shaped message passing without JSON serialization
  - Direct process-to-process communication
  - Built-in fault tolerance
  - Low latency for local communication

  ## Configuration

  This transport is configured via `Arbor.MCP.Client.start_link/1`:

      {:ok, client} = Arbor.MCP.Client.start_link(
        transport: :beam,
        server: server_pid
      )

  Options:
  - `:server` - Required for client mode if connecting to a server process.
  - `:timeout` - Optional. Call timeout in milliseconds (default: 5000).
  """

  @behaviour Arbor.MCP.Transport

  alias Arbor.MCP.Client.{Deadline, Lifetime}
  alias Arbor.MCP.Server.HandlerServer
  alias Arbor.MCP.Transport.Error

  defstruct [
    :server_pid,
    :role,
    :connected,
    :timeout,
    :subscriber,
    :forwarder_pid,
    :runtime,
    :connection,
    :peer_event_context
  ]

  @type t :: %__MODULE__{
          server_pid: pid() | nil,
          role: :client | :server,
          connected: boolean(),
          timeout: pos_integer()
        }

  @default_timeout 5_000

  @impl true
  def connect(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Determine if this is client or server mode
    cond do
      # Client mode - connecting to a server
      Keyword.has_key?(opts, :server) ->
        server_pid = Keyword.fetch!(opts, :server)

        case HandlerServer.connect(server_pid, self(),
               peer_event_context: Lifetime.peer_context()
             ) do
          {:ok, edge, runtime, connection} ->
            transport = %__MODULE__{
              server_pid: edge,
              role: :client,
              connected: true,
              timeout: timeout,
              runtime: runtime,
              connection: connection
            }

            :telemetry.execute([:arbor_mcp, :transport, :connection, :opened], %{}, %{
              transport: :beam
            })

            {:ok, transport}

          {:error, _reason} ->
            Error.connection_error(:server_not_available)
        end

      # Client mode - using service_name (for backward compatibility)
      Keyword.has_key?(opts, :service_name) ->
        # This is the problematic case - client trying to connect directly to service
        # Return an error to force the test to be updated
        {:error,
         {:not_supported,
          "BEAM transport requires a server process. Use :server option to specify the server PID."}}

      # Server mode - listening for connections
      true ->
        transport = %__MODULE__{
          server_pid: nil,
          role: :server,
          connected: false,
          timeout: timeout
        }

        {:ok, transport}
    end
  end

  @impl true
  def close(%__MODULE__{}) do
    :ok
  end

  @impl true
  def connected?(%__MODULE__{role: :client, server_pid: pid}) when is_pid(pid) do
    Process.alive?(pid)
  end

  def connected?(%__MODULE__{role: :server, server_pid: pid}) when is_pid(pid) do
    Process.alive?(pid)
  end

  def connected?(%__MODULE__{}) do
    false
  end

  @doc """
  Subscribe to receive transport events (push model).

  For the Local transport, the peer already sends `{:transport_message, msg}`
  to the client process. The Client GenServer handles these directly,
  so subscribe just signals that no receiver task is needed.
  """
  @impl true
  def subscribe(_pid, %__MODULE__{} = state) do
    {:ok, state}
  end

  @impl true
  def capabilities(_state), do: [:push]

  @impl true
  def send_message(message, %__MODULE__{} = transport) do
    case Error.validate_connection(transport, &connected?/1) do
      :ok ->
        case transport.role do
          :client ->
            # Client sending to server
            :telemetry.execute([:arbor_mcp, :transport, :message, :sent], %{}, %{
              transport: :beam,
              role: transport.role
            })

            case HandlerServer.ingress(
                   transport.runtime,
                   transport.server_pid,
                   transport.connection,
                   message
                 ) do
              :ok -> {:ok, transport}
              {:error, reason} -> Error.transport_error(reason)
            end

          :server ->
            # Server sending to client
            if transport.server_pid do
              :telemetry.execute([:arbor_mcp, :transport, :message, :sent], %{}, %{
                transport: :beam,
                role: transport.role
              })

              case transport.peer_event_context do
                %{owner: peer, epoch: epoch} when peer == transport.server_pid ->
                  Kernel.send(
                    peer,
                    {:client_lifetime_event, epoch, {:transport_message, message}}
                  )

                nil ->
                  Kernel.send(transport.server_pid, {:transport_message, message})
              end

              {:ok, transport}
            else
              # No client connected yet
              {:ok, transport}
            end
        end

      error ->
        error
    end
  end

  @impl true
  def receive_message(%__MODULE__{} = transport) do
    receive_message(transport, transport.timeout)
  end

  def receive_message(%__MODULE__{} = transport, timeout) do
    case Error.validate_connection(transport, &connected?/1) do
      :ok -> receive_until(transport, Deadline.after_ms(timeout || :infinity))
      error -> error
    end
  end

  defp receive_until(transport, deadline) do
    receive do
      {:client_lifetime_event, epoch, {:transport_message, message}} ->
        if Lifetime.event?(epoch),
          do: received(message, transport),
          else: receive_until(transport, deadline)

      {:transport_message, message} ->
        if Lifetime.peer_context(),
          do: receive_until(transport, deadline),
          else: received(message, transport)

      {:test_transport_connect, client_pid} when transport.role == :server ->
        new_transport = %{transport | server_pid: client_pid, connected: true}
        receive_until(new_transport, deadline)

      {:transport_error, reason} ->
        Error.transport_error(reason)
    after
      Deadline.remaining(deadline) -> Error.timeout_error(:receive_timeout)
    end
  end

  defp received(message, transport) do
    :telemetry.execute([:arbor_mcp, :transport, :message, :received], %{}, %{transport: :beam})
    {:ok, message, transport}
  end
end
