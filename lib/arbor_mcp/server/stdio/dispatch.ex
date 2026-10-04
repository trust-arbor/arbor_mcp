defmodule Arbor.MCP.Server.Stdio.Dispatch do
  @moduledoc false

  alias Arbor.MCP.Internal.VersionRegistry
  alias Arbor.MCP.Server.{Dispatch, ResultNormalizer}
  alias Arbor.RPC.JSONRPC

  def dispatch(%{"method" => "initialize", "params" => params} = request, handler, state, opts)
      when is_map(params) do
    client_version = Map.get(params, "protocolVersion", VersionRegistry.latest_version())

    version =
      case VersionRegistry.negotiate_version(client_version, VersionRegistry.supported_versions()) do
        {:ok, version} -> version
        {:error, :version_mismatch} -> VersionRegistry.latest_version()
      end

    Dispatch.dispatch(put_in(request["params"]["protocolVersion"], version), handler, state, opts)
  end

  def dispatch(%{"method" => method} = request, handler, state, opts) do
    if not Dispatch.known_method?(method) and function_exported?(handler, :handle_request, 3),
      do: custom(request, handler, state),
      else: Dispatch.dispatch(request, handler, state, opts)
  end

  def dispatch(request, handler, state, opts),
    do: Dispatch.dispatch(request, handler, state, opts)

  defp custom(request, handler, state) do
    case handler.handle_request(request["method"], Map.get(request, "params", %{}), state) do
      {:reply, result, next} ->
        {:response, JSONRPC.response(request["id"], result), next}

      {:error, error, next} ->
        {:response,
         JSONRPC.error(
           request["id"],
           -32000,
           ResultNormalizer.error_message("Request error", error)
         ), next}

      {:noreply, next} ->
        {:notification, next}
    end
  end
end
