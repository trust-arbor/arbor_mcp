defmodule Arbor.MCP.Telemetry do
  @moduledoc """
  Telemetry integration for ArborMCP.

  This module defines telemetry events emitted by ArborMCP components and provides
  convenience functions for attaching handlers.

  ## Events

  All events follow the naming convention `[:arbor_mcp, :component, :action, :status]`.

  ### Client Events

  #### Connection
  * `[:arbor_mcp, :client, :connected]` - Client connection established
    * Metadata: `%{transport: module()}`
  * `[:arbor_mcp, :client, :disconnected]` - Client disconnected
    * Metadata: `%{}`

  #### Request Lifecycle
  * `[:arbor_mcp, :client, :request, :sent]` - Request sent to server
    * Metadata: `%{method: String.t()}`
  * `[:arbor_mcp, :client, :request, :completed]` - Response matched to pending request
    * Metadata: `%{method: String.t() | nil, request_id: integer()}`

  #### Receiver
  * `[:arbor_mcp, :client, :receiver, :started]` - Receiver task started
    * Metadata: `%{mode: :push | :pull}`
  * `[:arbor_mcp, :client, :receiver, :message]` - Message received in receive loop
    * Metadata: `%{}`

  #### MCP 2026-07-28 Operations
  * `[:arbor_mcp, :client, :era, :settled]` - Connection era/version selected
  * `[:arbor_mcp, :client, :era, :fallback]` - Modern probe fell back to legacy
  * `[:arbor_mcp, :client, :era, :downgrade_attempt]` - A pinned modern endpoint was observed as legacy
  * `[:arbor_mcp, :client, :era, :unsupported_version_retry]` - Discovery retried a supported modern version
  * `[:arbor_mcp, :client, :mrtr, :round | :failure]` - MRTR progress or bounded failure class
  * `[:arbor_mcp, :client, :subscription, :reconnect]` - Subscription reconnect scheduled/completed
  * `[:arbor_mcp, :client, :http, :request, :retry]` - Ambiguous HTTP stream reissue

  These events use protocol method/version enums and classified reasons. They
  never contain request parameters, `_meta`, `inputResponses`, request state,
  credentials, or subscription identifiers.

  #### State & Progress (via `span/3`)
  * `[:arbor_mcp, :request, :start]` - Request processing starts
    * Measurements: `%{system_time: integer()}`
    * Metadata: `%{request_id: String.t(), method: String.t(), server: atom()}`
  * `[:arbor_mcp, :request, :stop]` - Request processing completes
    * Measurements: `%{duration: integer()}`
    * Metadata: `%{request_id: String.t(), method: String.t(), server: atom(), status: :ok | :error}`
  * `[:arbor_mcp, :request, :exception]` - Request processing fails
    * Measurements: `%{duration: integer()}`
    * Metadata: `%{request_id: String.t(), method: String.t(), server: atom(), kind: atom(), error: term(), stacktrace: list()}`

  ### Server Events

  #### Request Processing
  * `[:arbor_mcp, :server, :request, :admitted]` - Managed Runtime admission confirmed
    * Measurements: `%{count: 1, request_bytes: non_neg_integer()}`
    * Metadata: `%{runtime: pid()}`
    * `count` counts reservation envelopes, including a legacy batch envelope.
      `request_bytes` is the retained reservation charge for input, dispatch
      context and admission metadata; it is not the raw HTTP/JSON body length.
  * `[:arbor_mcp, :server, :request, :completed]` - Managed Runtime reservation settles
    * Measurements: `%{count: 1, duration_ms: non_neg_integer()}`
    * Metadata: `%{runtime: pid(), outcome: atom()}`
    * This reports terminal settlement, including failure or notification-only
      work. It does not prove peer processing or remote consumption.
  * `[:arbor_mcp, :server, :request, :processed]` - MessageProcessor.process/2 completes
    * Metadata: `%{method: String.t(), has_response: boolean()}`
  * `[:arbor_mcp, :server, :initialize, :completed]` - Server initialization completes
    * Metadata: `%{server_name: String.t()}`

  #### Tool Execution
  * `[:arbor_mcp, :server, :tool, :called]` - Tool call dispatched
    * Metadata: `%{tool_name: String.t(), mode: :handler}`
  * `[:arbor_mcp, :tool, :start]` - Tool execution starts (via `span/3`)
    * Measurements: `%{system_time: integer()}`
    * Metadata: `%{tool_name: String.t(), request_id: String.t()}`
  * `[:arbor_mcp, :tool, :stop]` - Tool execution completes (via `span/3`)
    * Measurements: `%{duration: integer()}`
    * Metadata: `%{tool_name: String.t(), request_id: String.t(), status: :ok | :error}`

  #### Resource Operations
  * `[:arbor_mcp, :server, :resource, :read]` - Resource read dispatched
    * Metadata: `%{uri: String.t(), mode: :handler}`
  * `[:arbor_mcp, :resource, :read, :start]` - Resource read starts (via `span/3`)
    * Measurements: `%{system_time: integer()}`
    * Metadata: `%{uri: String.t(), request_id: String.t()}`
  * `[:arbor_mcp, :resource, :read, :stop]` - Resource read completes (via `span/3`)
    * Measurements: `%{duration: integer(), bytes: integer() | nil}`
    * Metadata: `%{uri: String.t(), request_id: String.t(), status: :ok | :error}`

  #### Prompt Rendering
  * `[:arbor_mcp, :server, :prompt, :rendered]` - Prompt get dispatched
    * Metadata: `%{name: String.t(), mode: :handler}`

  #### HTTP Transport
  * `[:arbor_mcp, :server, :http, :request]` - HTTP request received
    * Metadata: `%{method: String.t(), path: String.t()}`
  * `[:arbor_mcp, :server, :http, :response]` - HTTP response sent
    * Metadata: `%{status: integer()}`

  #### MCP 2026-07-28 Operations
  * `[:arbor_mcp, :server, :mrtr, :failure]` - Sealing/resume/replay failure class
  * `[:arbor_mcp, :server, :subscription, :queue_pressure]` - Coalescing or slow-consumer closure
  * `[:arbor_mcp, :server, :subscription, :fanout]` - PubSub fan-out failure class

  MRTR key IDs, JTIs and sealed tokens are deliberately omitted. Subscription
  filters, resource URIs, task IDs, principals and wire IDs are also omitted.

  ### Transport Events (via `span/3`)

  * `[:arbor_mcp, :connection, :established]` - Connection established
    * Measurements: `%{system_time: integer()}`
    * Metadata: `%{transport: atom(), server: atom()}`
  * `[:arbor_mcp, :connection, :lost]` - Connection lost
    * Measurements: `%{system_time: integer(), uptime: integer()}`
    * Metadata: `%{transport: atom(), server: atom(), reason: term()}`

  ### TLS Trust Store Events

  * `[:arbor_mcp, :cacerts, :os_load, :failed]` - The OS CA certificate store
    could not be loaded for outbound HTTPS
    * Metadata: `%{reason: :timeout | :no_certificates | :error, fallback: :none | :castore}`.
      With `fallback: :none` (the default), HTTPS requests fail until the
      store loads; with `:castore`, the CAStore bundle is trusted instead.
      Alert on this event: a fallback changes which CAs are trusted.
  * `[:arbor_mcp, :cacerts, :os_load, :recovered]` - The OS store loaded after a
    failure or fallback
    * Metadata: `%{previous: :failed | :fallback}`

  ### Authorization Events

  Authorization events are emitted by the OAuth 2.1 subsystem:

  * `[:arbor_mcp, :authorization, :flow, :start | :stop]` - OAuth flow lifecycle
  * `[:arbor_mcp, :authorization, :discovery, :start | :stop]` - Metadata discovery
  * `[:arbor_mcp, :authorization, :token, :start | :stop]` - Token exchange
  * `[:arbor_mcp, :authorization, :authorize, :start | :stop]` - Authorization request

  """

  require Logger

  alias Arbor.RPC.LogSummary

  @doc """
  Attaches a default logger that logs all ArborMCP events.

  This is useful for debugging and development.
  """
  def attach_default_logger do
    events = [
      [:arbor_mcp, :request, :start],
      [:arbor_mcp, :request, :stop],
      [:arbor_mcp, :request, :exception],
      [:arbor_mcp, :tool, :start],
      [:arbor_mcp, :tool, :stop],
      [:arbor_mcp, :resource, :read, :start],
      [:arbor_mcp, :resource, :read, :stop],
      [:arbor_mcp, :connection, :established],
      [:arbor_mcp, :connection, :lost]
    ]

    :telemetry.attach_many(
      "ex-mcp-default-logger",
      events,
      &handle_event/4,
      nil
    )
  end

  @doc """
  Detaches the default logger.
  """
  def detach_default_logger do
    :telemetry.detach("ex-mcp-default-logger")
  end

  # Default event handler that logs events
  defp handle_event([:arbor_mcp, :request, :start], _measurements, metadata, _config) do
    Logger.debug("Starting request",
      request_id_hash: LogSummary.fingerprint(metadata.request_id),
      method: metadata.method
    )
  end

  defp handle_event([:arbor_mcp, :request, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.info("Request completed",
      request_id_hash: LogSummary.fingerprint(metadata.request_id),
      method: metadata.method,
      duration_ms: duration_ms,
      status: metadata.status
    )
  end

  defp handle_event([:arbor_mcp, :request, :exception], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.error("Request failed",
      request_id_hash: LogSummary.fingerprint(metadata.request_id),
      method: metadata.method,
      duration_ms: duration_ms,
      error: LogSummary.describe(metadata.error)
    )
  end

  defp handle_event([:arbor_mcp, :tool | _], _measurements, metadata, _config) do
    Logger.debug("Tool event", metadata_keys: metadata_keys(metadata))
  end

  defp handle_event([:arbor_mcp, :resource | _], _measurements, metadata, _config) do
    Logger.debug("Resource event", metadata_keys: metadata_keys(metadata))
  end

  defp handle_event([:arbor_mcp, :connection, :established], _measurements, metadata, _config) do
    Logger.info("Connection established",
      transport: metadata.transport,
      server_hash: LogSummary.fingerprint(metadata.server)
    )
  end

  defp handle_event([:arbor_mcp, :connection, :lost], measurements, metadata, _config) do
    uptime_s = System.convert_time_unit(measurements.uptime, :native, :second)

    Logger.warning("Connection lost",
      uptime_seconds: uptime_s,
      transport: metadata.transport,
      reason: LogSummary.describe(metadata.reason)
    )
  end

  defp handle_event(_event, _measurements, _metadata, _config) do
    :ok
  end

  defp metadata_keys(metadata) when is_map(metadata),
    do: metadata |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

  defp metadata_keys(_metadata), do: []

  @doc """
  Executes a function and emits telemetry events.

  This is a convenience function for wrapping operations with telemetry.

  ## Examples

      Arbor.MCP.Telemetry.span([:arbor_mcp, :custom, :operation], %{id: "123"}, fn ->
        # Do some work
        {:ok, result}
      end)
  """
  def span(event_prefix, metadata, fun)
      when is_list(event_prefix) and is_map(metadata) and is_function(fun, 0) do
    start_time = System.monotonic_time()
    start_metadata = Map.put(metadata, :system_time, System.system_time())

    :telemetry.execute(event_prefix ++ [:start], %{system_time: start_time}, start_metadata)

    try do
      result = fun.()
      duration = System.monotonic_time() - start_time

      status =
        case result do
          {:ok, _, _} ->
            :ok

          {:error, _, _} ->
            :error

          {:ok, _} ->
            :ok

          {:error, _} ->
            :error

          {:response, response, _} ->
            # Check if the response contains an error
            if Arbor.MCP.Protocol.ResponseBuilder.error_response?(response), do: :error, else: :ok

          _ ->
            :ok
        end

      stop_metadata = Map.put(metadata, :status, status)
      :telemetry.execute(event_prefix ++ [:stop], %{duration: duration}, stop_metadata)

      result
    rescue
      error ->
        duration = System.monotonic_time() - start_time

        exception_metadata =
          metadata
          |> Map.put(:kind, :error)
          |> Map.put(:error, error)
          |> Map.put(:stacktrace, __STACKTRACE__)

        :telemetry.execute(
          event_prefix ++ [:exception],
          %{duration: duration},
          exception_metadata
        )

        reraise error, __STACKTRACE__
    end
  end
end
