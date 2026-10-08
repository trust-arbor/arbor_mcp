defmodule Arbor.MCP.Server.Runtime.HTTPResources.Source do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    CallbackContext,
    Deadline,
    Ref,
    Scheduler,
    ServiceOperation,
    ServiceRef
  }

  alias Arbor.MCP.SessionManager
  alias Arbor.MCP.SessionManager.SessionLease

  @enforce_keys [
    :runtime,
    :table,
    :token,
    :producer,
    :generation,
    :scope,
    :phase,
    :deadline,
    :gateway,
    :endpoint,
    :identity,
    :lease
  ]
  defstruct @enforce_keys
  @opaque t :: %__MODULE__{}

  def capture do
    case CallbackContext.current() do
      nil -> {:error, :no_request_context}
      %{table: table, token: token} = context -> capture(context, table, token)
      _invalid -> {:error, :resource_source_retired}
    end
  end

  defp capture(context, table, token) do
    with [{_key, http}] <- :ets.lookup(table, {:http_session_origin, token}),
         {:ok, reservation} <- Admission.current(table, token),
         {:ok, _metadata} <- Scheduler.output_producer_metadata(table, reservation),
         true <- http.runtime == context.runtime and http.phase == reservation.output_phase,
         {:ok, identity} <- identity(context.runtime, http),
         source = %__MODULE__{
           runtime: context.runtime,
           table: table,
           token: token,
           producer: self(),
           generation: reservation.generation,
           scope: reservation.scope,
           phase: reservation.output_phase,
           deadline: reservation.deadline,
           gateway: http.owner,
           endpoint: :binary.copy(http.endpoint),
           identity: identity,
           lease: http.lease
         },
         true <- :erlang.external_size(source) <= 16_384,
         true <- current?(source) do
      {:ok, source}
    else
      [] -> {:error, :not_http_request}
      _invalid -> {:error, :resource_source_retired}
    end
  rescue
    ArgumentError -> {:error, :resource_source_retired}
  end

  defp identity(runtime, %{lease: lease}) when not is_nil(lease) do
    service = ServiceRef.new(runtime, :sessions)

    with {:ok, %{metadata: metadata}} <- SessionManager.get_session(service, lease, []) do
      {:ok, {Map.get(metadata, :principal_id), Map.get(metadata, :tenant_id)}}
    end
  end

  defp identity(_runtime, %{identity: {_endpoint, principal, tenant}}),
    do: {:ok, {principal, tenant}}

  defp identity(_runtime, %{identity: nil}), do: {:ok, {nil, nil}}
  defp identity(_runtime, _invalid), do: {:error, :resource_source_retired}

  def current?(%__MODULE__{} = source) do
    with {:ok, reservation} <- reservation(source),
         true <- source.producer == self(),
         {:ok, _metadata} <- Scheduler.output_producer_metadata(source.table, reservation) do
      true
    else
      _invalid -> false
    end
  end

  def current?(_invalid), do: false

  def producer_snapshot(%__MODULE__{} = source) do
    if current?(source),
      do: {:ok, reverse_snapshot(source)},
      else: {:error, :resource_source_retired}
  end

  def producer_snapshot(_invalid), do: {:error, :resource_source_retired}

  def gateway_snapshot(%__MODULE__{} = source) do
    with true <- self() == source.gateway,
         {:ok, current} <- reservation(source),
         {:ok, _metadata} <-
           Scheduler.gateway_producer_metadata(source.table, current, source.producer),
         do: {:ok, reverse_snapshot(source)},
         else: (_retired -> {:error, :resource_source_retired})
  end

  def gateway_snapshot(_invalid), do: {:error, :resource_source_retired}

  def admission_snapshot(%__MODULE__{} = source) do
    with [{:admission, admission}] when admission == self() <-
           :ets.lookup(source.table, :admission),
         {:ok, current} <- reservation(source),
         {:ok, _metadata} <-
           Scheduler.admission_producer_metadata(source.table, current, source.producer),
         do: {:ok, reverse_snapshot(source)},
         else: (_retired -> {:error, :resource_source_retired})
  end

  def admission_snapshot(_invalid), do: {:error, :resource_source_retired}

  defp reverse_snapshot(source),
    do:
      Map.take(source, [
        :runtime,
        :token,
        :producer,
        :generation,
        :scope,
        :phase,
        :deadline,
        :gateway,
        :endpoint,
        :identity,
        :lease
      ])

  # Stores use protected Scheduler metadata; there is no Store -> Scheduler
  # GenServer call and no caller-authored PID proof accepted at mutation.
  def valid?(%__MODULE__{} = source, context, kind) do
    with true <- context.runtime == source.runtime and context.kind == kind,
         true <- context.owner == source.producer,
         true <- ServiceOperation.context_current?(context),
         {:ok, reservation} <- reservation(source),
         {:ok, _metadata} <-
           Scheduler.service_producer_metadata(source.table, reservation, kind, source.producer) do
      true
    else
      _invalid -> false
    end
  rescue
    ArgumentError -> false
  end

  def valid?(_invalid, _context, _kind), do: false

  def matches?(%__MODULE__{} = source, metadata) when is_map(metadata) do
    Map.get(metadata, :transport_endpoint) == source.endpoint and
      {Map.get(metadata, :principal_id), Map.get(metadata, :tenant_id)} == source.identity
  end

  def matches?(_source, _metadata), do: false

  def runtime(%__MODULE__{runtime: runtime}), do: runtime
  def lease(%__MODULE__{lease: lease}), do: lease
  def deadline(%__MODULE__{deadline: deadline}), do: deadline
  def endpoint(%__MODULE__{endpoint: endpoint}), do: endpoint

  defp reservation(source) do
    with true <- source.deadline > Deadline.now() and Process.alive?(source.producer),
         true <- Ref.table(source.runtime) == source.table,
         [{:http_gateway, gateway}] when gateway == source.gateway <-
           :ets.lookup(source.table, :http_gateway),
         true <- Process.alive?(gateway),
         {:ok, current} <- Admission.current(source.table, source.token),
         true <- not current.terminal,
         true <- current.generation == source.generation and current.scope == source.scope,
         true <- current.output_phase == source.phase and current.deadline == source.deadline,
         [{_key, http}] <- :ets.lookup(source.table, {:http_session_origin, source.token}),
         true <- http.owner == gateway and http.generation == source.generation,
         true <- http.phase == source.phase and http.scope == source.scope,
         true <- http.endpoint == source.endpoint and http.lease == source.lease,
         true <- lease_current?(source) do
      {:ok, current}
    else
      _invalid -> {:error, :resource_source_retired}
    end
  rescue
    ArgumentError -> {:error, :resource_source_retired}
  end

  defp lease_current?(%{lease: nil}), do: true

  defp lease_current?(source),
    do:
      match?(
        {:ok, _key},
        SessionLease.validate(source.lease, ServiceRef.new(source.runtime, :sessions), :sessions)
      )
end
