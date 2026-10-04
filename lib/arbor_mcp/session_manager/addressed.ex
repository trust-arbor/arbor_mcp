defmodule Arbor.MCP.SessionManager.Addressed do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime.ServiceOperation
  alias Arbor.MCP.SessionManager.{InitializationClaim, SessionLease}

  def create(service, metadata, opts) when is_map(metadata) do
    with {:ok, %{id: id, epoch: epoch}} <-
           call(service, :create, [metadata, Keyword.get(opts, :session_id)], opts),
         do: SessionLease.new(service, id, epoch)
  end

  def create(_service, _metadata, _opts), do: {:error, :invalid_session_metadata}

  def ensure(service, id, metadata, initialized?, opts) when is_binary(id) and is_map(metadata) do
    with {:ok, %{id: id, epoch: epoch}} <-
           call(service, :ensure, [id, metadata, initialized?], opts),
         do: SessionLease.new(service, id, epoch)
  end

  def ensure(_service, _id, _metadata, _initialized, _opts),
    do: {:error, :invalid_session_metadata}

  def claim_initialization(service, lease, opts) do
    with {:ok, key} <- SessionLease.validate(lease, service, :sessions),
         {:ok, token, owner, deadline} <- call(service, :claim_initialization, [key], opts),
         do: {:ok, InitializationClaim.new(lease, token, owner, deadline)}
  end

  def complete_initialization(service, claim, version, opts) do
    with {:ok, key, token, owner, deadline} <- InitializationClaim.validate(claim, service),
         do:
           call(
             service,
             :complete_initialization,
             [key, token, owner, deadline, version],
             Keyword.put(opts, :deadline, deadline)
           )
  end

  def leased(service, lease, operation, args, opts) do
    with {:ok, key} <- SessionLease.validate(lease, service, :sessions),
         do: call(service, operation, [key | args], opts)
  end

  def call(service, operation, args, opts),
    do: ServiceOperation.call(service, :sessions, operation, args, opts)
end
