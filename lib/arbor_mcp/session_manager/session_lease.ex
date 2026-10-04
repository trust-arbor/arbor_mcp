defmodule Arbor.MCP.SessionManager.SessionLease do
  @moduledoc """
  Opaque address of one active session epoch in a runtime service cohort.

  A GET disconnect does not retire this lease. Session closure, expiration or
  service-cohort replacement does. Obtain a fresh lease by validating the
  server-issued session ID against its authorization identity.
  """

  alias Arbor.MCP.Server.Runtime.{ServiceRef, Services}

  @enforce_keys [:service, :generation, :namespace, :id, :epoch]
  defstruct [:service, :generation, :namespace, :id, :epoch]

  @opaque t :: %__MODULE__{
            service: ServiceRef.t(),
            generation: reference(),
            namespace: binary(),
            id: binary(),
            epoch: binary()
          }

  @doc "Returns the server-issued wire session ID."
  @spec id(t()) :: binary()
  def id(%__MODULE__{id: id}), do: id

  @doc false
  @spec new(term(), binary(), binary()) :: {:ok, t()} | {:error, term()}
  def new(service, id, epoch) do
    with {:ok, runtime} <- ServiceRef.validate(service, :sessions),
         {:ok, binding} <- Services.resolve(runtime, :sessions) do
      {:ok,
       %__MODULE__{
         service: ServiceRef.new(runtime, :sessions),
         generation: binding.generation,
         namespace: binding.namespace || "owned",
         id: id,
         epoch: epoch
       }}
    end
  end

  @doc false
  @spec validate(term(), term(), atom()) :: {:ok, {binary(), binary()}} | {:error, term()}
  def validate(%__MODULE__{} = lease, service, kind) do
    with {:ok, runtime} <- ServiceRef.validate(service, kind),
         {:ok, ^runtime} <- ServiceRef.validate(lease.service, :sessions),
         {:ok, binding} <- Services.resolve(lease.service, :sessions),
         true <- lease.generation == binding.generation,
         true <- lease.namespace == (binding.namespace || "owned"),
         true <-
           binding.adapter.lease_active?(lease.id, lease.epoch,
             server: binding.server,
             namespace: lease.namespace,
             service_address: binding.address,
             read_address: binding.read_address
           ) do
      {:ok, {lease.id, lease.epoch}}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :stale_session_lease}
    end
  rescue
    ArgumentError -> {:error, :stale_session_lease}
  catch
    :exit, _reason -> {:error, :stale_session_lease}
  end

  def validate(_lease, _service, _kind), do: {:error, :invalid_session_lease}
end
