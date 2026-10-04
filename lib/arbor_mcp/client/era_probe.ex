defmodule Arbor.MCP.Client.EraProbe do
  @moduledoc """
  Performs the side-effect-free `server/discover` probe used to establish a
  modern MCP connection before any application request is sent.

  The probe owns its short timeout and returns the post-probe transport state,
  allowing the connection manager to either settle on modern or make an
  explicit, policy-controlled legacy fallback decision.
  """

  alias Arbor.MCP.Client.Deadline
  alias Arbor.MCP.Internal.{Protocol, RequestParams, VersionInfo, VersionRegistry}
  alias Arbor.MCP.Protocol.ResultEnvelope
  alias Arbor.MCP.Server.Discover
  alias Arbor.MCP.Transport.Local
  alias Arbor.RPC.JSONRPC

  @default_timeout 2_000

  @type failure ::
          {:invalid_probe_request, term()}
          | {:transport_error, term()}
          | {:probe_timeout, term()}
          | {:http_probe_rejected, map()}
          | {:json_rpc_error, map()}
          | {:unexpected_response, term()}
          | {:invalid_discover_result, term()}
          | {:no_mutually_supported_modern_version, map()}

  @type result :: %{
          protocol_version: String.t(),
          server_info: map() | nil,
          server_capabilities: map(),
          discovery: map()
        }

  @doc "The probe's own timeout: `:era_probe_timeout`, default #{@default_timeout} ms."
  @spec timeout(keyword()) :: timeout()
  def timeout(opts), do: Keyword.get(opts, :era_probe_timeout, @default_timeout)

  @doc """
  Runs a bounded modern discovery probe over a connected transport.

  `:era_probe_timeout` bounds each probe exchange as a whole, the send (a
  synchronous HTTP POST included) as well as the wait for the response, and
  the connection's `:establish_deadline` caps it further. A send cut short by
  that bound is a `{:probe_timeout, reason}`, like a response that never came.
  """
  @spec probe(module(), term(), keyword()) ::
          {:ok, result(), term()} | {:error, failure(), term()}
  def probe(transport_mod, transport_state, opts) do
    mode = Keyword.get(opts, :protocol_mode) || :prefer_modern
    protocol_version = probe_version(mode, Keyword.get(opts, :protocol_version))
    probe_version(transport_mod, transport_state, opts, mode, protocol_version, [])
  end

  @spec probe_version(
          module(),
          term(),
          keyword(),
          VersionRegistry.protocol_mode(),
          String.t(),
          [String.t()]
        ) :: {:ok, result(), term()} | {:error, failure(), term()}
  defp probe_version(transport_mod, transport_state, opts, mode, version, attempted) do
    attempted = [version | attempted]

    case probe_once(transport_mod, transport_state, opts, mode, version) do
      {:error, {:json_rpc_error, error}, updated_state} = failure ->
        case retry_version(error, mode, attempted) do
          {:ok, retry_version} ->
            :telemetry.execute(
              [:arbor_mcp, :client, :era, :unsupported_version_retry],
              %{attempt: length(attempted) + 1},
              %{
                from_version: telemetry_version(version),
                to_version: telemetry_version(retry_version)
              }
            )

            probe_version(transport_mod, updated_state, opts, mode, retry_version, attempted)

          :not_modern_error ->
            failure

          {:error, reason} ->
            {:error, reason, updated_state}
        end

      result ->
        result
    end
  end

  defp probe_once(transport_mod, transport_state, opts, mode, protocol_version) do
    request_id = Protocol.generate_id()

    context = %{
      protocol_version: protocol_version,
      client_capabilities: Keyword.get(opts, :capabilities, %{}),
      client_info: VersionInfo.client_info(),
      log_level: Keyword.get(opts, :log_level),
      trace_context: Keyword.get(opts, :trace_context, %{})
    }

    with {:ok, params} <- RequestParams.for_request(%{}, context),
         request = JSONRPC.request("server/discover", params, request_id),
         {:ok, outbound} <- encode_for_transport(transport_mod, request),
         {:ok, response, updated_state} <-
           bounded_send_and_receive(transport_mod, outbound, transport_state, opts) do
      parse_response(response, request_id, mode, updated_state)
    else
      {:error, {:probe_timeout, reason}} ->
        {:error, {:probe_timeout, reason}, transport_state}

      # MCP's backwards-compatibility guidance: a server that predates
      # server/discover rejects the POST with 400, 404 or 405.
      {:error, {:http_error, status, body}} when status in [400, 404, 405] ->
        parse_http_probe_error(status, body, transport_state)

      {:error, {kind, _detail} = reason}
      when kind in [:invalid_meta, :invalid_meta_key, :invalid_meta_field, :missing_meta_field] ->
        {:error, {:invalid_probe_request, reason}, transport_state}

      {:error, reason} ->
        {:error, {:transport_error, reason}, transport_state}
    end
  end

  defp parse_http_probe_error(status, body, transport_state) do
    case Protocol.parse_message(body) do
      {:error, error, _id} when is_map(error) ->
        {:error, {:json_rpc_error, error}, transport_state}

      other ->
        {:error, {:http_probe_rejected, %{status: status, response: other}}, transport_state}
    end
  end

  defp retry_version(%{"code" => -32022, "data" => data}, mode, attempted)
       when is_map(data) do
    supported = Map.get(data, "supported")
    requested = Map.get(data, "requested")

    if is_list(supported) and Enum.all?(supported, &is_binary/1) and is_binary(requested) do
      candidate =
        mode
        |> VersionRegistry.enabled_versions()
        |> Enum.filter(&VersionRegistry.modern?/1)
        |> Enum.find(fn version ->
          version in supported and retryable_version?(version, requested, attempted)
        end)

      if candidate do
        {:ok, candidate}
      else
        {:error,
         {:no_mutually_supported_modern_version,
          %{server: supported, client: VersionRegistry.enabled_versions(mode)}}}
      end
    else
      :not_modern_error
    end
  end

  defp retry_version(_error, _mode, _attempted), do: :not_modern_error

  # A server may reject a supported version transiently and advertise that
  # same version in UnsupportedProtocolVersionError. Retrying it once is part
  # of version negotiation; the attempted-count bound prevents an error loop.
  defp retryable_version?(version, requested, attempted) do
    attempts = Enum.count(attempted, &(&1 == version))
    attempts == 0 or (version == requested and attempts == 1)
  end

  defp telemetry_version(version) do
    if VersionRegistry.known?(version), do: version, else: :unknown
  end

  defp parse_response(response, request_id, mode, transport_state) do
    case Protocol.parse_message(response) do
      {:result, result, ^request_id} ->
        with {:ok, :complete, _result} <-
               ResultEnvelope.validate(result, :modern, method: "server/discover"),
             {:ok, discovery} <- Discover.parse_result(result),
             {:ok, selected_version} <- select_version(discovery.supported_versions, mode) do
          {:ok,
           %{
             protocol_version: selected_version,
             server_info: discovery.server_info,
             server_capabilities: discovery.capabilities,
             discovery: result
           }, transport_state}
        else
          {:error, reason} ->
            {:error, {:invalid_discover_result, reason}, transport_state}
        end

      {:error, error, ^request_id} when is_map(error) ->
        {:error, {:json_rpc_error, error}, transport_state}

      other ->
        {:error, {:unexpected_response, %{expected_id: request_id, response: other}},
         transport_state}
    end
  end

  defp select_version(server_versions, mode) do
    client_versions =
      mode
      |> VersionRegistry.enabled_versions()
      |> Enum.filter(&VersionRegistry.modern?/1)

    case Enum.find(client_versions, &(&1 in server_versions)) do
      nil ->
        {:error,
         {:no_mutually_supported_modern_version,
          %{server: server_versions, client: client_versions}}}

      version ->
        {:ok, version}
    end
  end

  defp bounded_send_and_receive(transport_mod, outbound, transport_state, opts) do
    establish_deadline = Deadline.on_transport(transport_mod, transport_state)

    exchange_deadline =
      Deadline.earliest(Deadline.after_ms(timeout(opts)), Keyword.get(opts, :establish_deadline))

    bounded_state = Deadline.put_on_transport(transport_mod, transport_state, exchange_deadline)

    case send_and_receive(transport_mod, outbound, bounded_state, exchange_deadline) do
      {:ok, response, updated_state} ->
        {:ok, response,
         Deadline.put_on_transport(transport_mod, updated_state, establish_deadline)}

      {:error, _reason} = error ->
        error
    end
  end

  defp send_and_receive(transport_mod, outbound, transport_state, deadline) do
    case transport_mod.send_message(outbound, transport_state) do
      {:ok, updated_state, response} ->
        {:ok, response, updated_state}

      {:ok, updated_state} ->
        receive_response(transport_mod, updated_state, Deadline.remaining(deadline))

      {:error, reason} ->
        if Deadline.expired?(deadline),
          do: {:error, {:probe_timeout, reason}},
          else: {:error, reason}
    end
  end

  defp receive_response(transport_mod, transport_state, timeout) do
    result =
      if function_exported?(transport_mod, :receive_message, 2) do
        transport_mod.receive_message(transport_state, timeout)
      else
        receive_via_task(transport_mod, transport_state, timeout)
      end

    case result do
      {:ok, response, updated_state} -> {:ok, response, updated_state}
      {:error, {:timeout_error, reason}} -> {:error, {:probe_timeout, reason}}
      {:error, :probe_timeout} -> {:error, {:probe_timeout, :timeout}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp receive_via_task(transport_mod, transport_state, timeout) do
    task =
      Arbor.MCP.Client.ConnectionScope.async(fn ->
        transport_mod.receive_message(transport_state)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:probe_receive_failed, reason}}
      nil -> {:error, :probe_timeout}
    end
  end

  defp probe_version(mode, configured_version) do
    if VersionRegistry.modern?(configured_version) and
         VersionRegistry.enabled?(configured_version, mode) do
      configured_version
    else
      mode
      |> VersionRegistry.enabled_versions()
      |> Enum.find(&VersionRegistry.modern?/1)
    end
  end

  defp encode_for_transport(Local, request), do: {:ok, request}
  defp encode_for_transport(_transport_mod, request), do: Protocol.encode_to_string(request)
end
