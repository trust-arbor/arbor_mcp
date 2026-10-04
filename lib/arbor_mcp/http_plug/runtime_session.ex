defmodule Arbor.MCP.HttpPlug.RuntimeSession do
  @moduledoc false
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{HTTPWriterBinding, HTTPWriterRegistry}
  alias Arbor.MCP.SessionManager
  alias Arbor.MCP.SessionManager.SessionLease

  # Session authority is addressed to this root and bound to the captured
  # socket invocation before an initialization claim can outlive a store RPC.
  def prepare(_runtime, _binding, nil, _request, _metadata),
    do: {:ok, %{service: nil, lease: nil, claim: nil, opts: []}}

  def prepare(runtime, binding, reference, request, metadata) do
    with {:ok, service} <- Runtime.service(runtime, :sessions),
         {:ok, proof} <- HTTPWriterBinding.validate(binding, runtime),
         opts = [deadline: proof.deadline],
         {:ok, lease} <- lease(service, reference, request, metadata, opts),
         :ok <- bind(binding, lease),
         {:ok, claim} <- claim(service, lease, request, Keyword.put(opts, :invocation, binding)),
         :ok <- claim_ids(service, lease, request, opts) do
      {:ok, %{service: service, lease: lease, claim: claim, opts: opts}}
    end
  end

  defp lease(service, :new_session, _request, metadata, opts),
    do: SessionManager.create_session(service, metadata, opts)

  defp lease(service, {:existing_session, id}, %{"method" => "initialize"}, metadata, opts),
    do: SessionManager.ensure_session(service, id, metadata, opts)

  defp lease(service, {:existing_session, id}, _request, metadata, opts),
    do: SessionManager.ensure_initialized_session(service, id, metadata, opts)

  defp bind(binding, lease), do: HTTPWriterRegistry.bind_lease(binding, lease)

  defp claim(service, lease, %{"method" => "initialize"}, opts),
    do: SessionManager.claim_initialization(service, lease, opts)

  defp claim(_service, _lease, _request, _opts), do: {:ok, nil}

  defp claim_ids(service, lease, members, opts) when is_list(members) do
    Enum.reduce_while(members, :ok, fn member, :ok ->
      case claim_ids(service, lease, member, opts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp claim_ids(service, lease, %{"id" => id, "method" => method}, opts)
       when is_binary(id) or is_integer(id) do
    case SessionManager.claim_request_id(service, lease, id, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:request_id_rejected, SessionLease.id(lease), id, reason, method}}
    end
  end

  defp claim_ids(_service, _lease, _notification, _opts), do: :ok

  def id(%{lease: nil}), do: nil
  def id(%{lease: lease}), do: SessionLease.id(lease)

  def version(%{lease: nil}), do: nil

  def version(%{service: service, lease: lease, opts: opts}) do
    case SessionManager.get_session(service, lease, opts) do
      {:ok, session} -> Map.get(session, :protocol_version)
      _closed -> nil
    end
  end

  # Initialization settlement runs under the original authenticated cutoff and
  # lease. A failed initialization closes only this captured session epoch.
  def finalize(%{claim: nil}, _request, _response, _expected), do: :ok
  def finalize(_session, %{"method" => "initialize"}, %{"error" => _error}, _expected), do: :ok

  def finalize(session, %{"method" => "initialize"}, response, expected) do
    version = get_in(response, ["result", "protocolVersion"])

    if version == expected and is_binary(version) do
      case SessionManager.complete_initialization(
             session.service,
             session.claim,
             version,
             session.opts
           ) do
        :ok ->
          :ok

        error ->
          terminate(session)
          error
      end
    else
      terminate(session)
      {:error, :session_manager_unavailable}
    end
  end

  def finalize(_session, _request, _response, _expected), do: :ok

  def terminate(%{lease: nil}), do: :ok

  def terminate(session),
    do: SessionManager.terminate_session(session.service, session.lease, session.opts)
end
