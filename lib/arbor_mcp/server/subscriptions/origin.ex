defmodule Arbor.MCP.Server.Subscriptions.Origin do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    CallbackContext,
    Deadline,
    HTTPListenerBinding,
    HTTPListenerCompletion,
    HTTPWriterRegistry,
    Ref,
    ServiceRef
  }

  alias Arbor.MCP.SessionManager.SessionLease

  defstruct [:table, :edge, :connection, :generation, :proof, :deadline, :http]
  @opaque t :: %__MODULE__{}

  # Public publication options never accept a caller-authored proof. The edge
  # supplies a control token owned by itself; callback publications capture the
  # current authoritative reservation before service address resolution.
  def capture(opts) do
    case Keyword.get(opts, :subscription_control) do
      {table, token, connection} -> capture_control(table, token, connection)
      nil -> capture_callback(CallbackContext.current())
      _ -> {:error, :invalid_subscription_origin}
    end
  end

  def valid?(nil), do: true

  def valid?(%__MODULE__{http: %{kind: :source}} = origin) do
    http_current?(origin) and Admission.output_origin_valid?(origin.table, origin.proof)
  rescue
    ArgumentError -> false
  end

  def valid?(%__MODULE__{http: %{kind: :completion, completion: completion}}),
    do: match?({:ok, _proof}, HTTPListenerCompletion.validate(completion))

  def valid?(%__MODULE__{http: %{kind: :listener, binding: binding, runtime: runtime}}) do
    match?({:ok, _proof}, HTTPListenerBinding.validate(binding, runtime))
  end

  def valid?(%__MODULE__{} = origin) do
    with [{:edge_connection, edge, connection}] <- :ets.lookup(origin.table, :edge_connection),
         true <- edge == origin.edge and connection == origin.connection,
         true <- Process.alive?(edge),
         {:ok, %{generation: generation}} <- Admission.route(origin.table),
         true <- generation == origin.generation,
         true <- Deadline.remaining(origin.deadline) > 0,
         do: Admission.output_origin_valid?(origin.table, origin.proof),
         else: (_ -> false)
  rescue
    ArgumentError -> false
  end

  def valid?(_invalid), do: false

  def valid_for?(nil, _table, _connection, _edge), do: true

  def valid_for?(%__MODULE__{} = origin, table, connection, edge),
    do:
      origin.table == table and origin.connection == connection and origin.edge == edge and
        valid?(origin)

  def valid_for?(_origin, _table, _connection, _edge), do: false

  def deadline(nil, fallback), do: fallback
  def deadline(%__MODULE__{deadline: deadline}, fallback), do: min(deadline, fallback)
  def completion(%__MODULE__{http: %{kind: :completion, completion: completion}}), do: completion
  def completion(_origin), do: nil
  def proof(nil), do: nil
  def proof(%__MODULE__{proof: proof}), do: proof
  def target(nil, target), do: target
  def target(%__MODULE__{http: http}, nil) when not is_nil(http), do: nil
  def target(%__MODULE__{edge: edge}, nil), do: edge
  def target(_origin, target), do: target

  def limit(%__MODULE__{} = origin, deadline),
    do: %{origin | deadline: min(origin.deadline, deadline)}

  def compatible?(
        %__MODULE__{http: %{kind: :source}} = source,
        %__MODULE__{http: %{kind: :listener}} = target
      ) do
    source.table == target.table and source.edge == target.edge and
      source.generation == target.generation and source.http.endpoint == target.http.endpoint and
      is_nil(source.http.lease) and
      (source.http.identity == target.http.identity or
         (not is_nil(source.http.identity) and not is_nil(target.http.identity) and
            target.http.explicit_authorizer)) and
      valid?(source) and valid?(target)
  end

  def compatible?(
        %__MODULE__{http: %{kind: :listener}} = registration,
        %__MODULE__{http: %{kind: :listener}} = target
      ),
      do: registration == target and valid?(registration)

  def compatible?(%__MODULE__{http: nil} = origin, %__MODULE__{http: nil} = registration),
    do:
      origin.table == registration.table and origin.edge == registration.edge and
        origin.connection == registration.connection and
        origin.generation == registration.generation and valid?(origin)

  def compatible?(_origin, _registration), do: false

  def for_listener(table, edge, deadline) do
    with [{:edge_connection, ^edge, connection}] <- :ets.lookup(table, :edge_connection),
         {:ok, %{generation: generation}} <- Admission.route(table),
         do: build(table, connection, generation, nil, deadline),
         else: (_ -> {:error, :subscription_origin_retired})
  rescue
    ArgumentError -> {:error, :subscription_origin_retired}
  end

  def for_http_listener(binding, runtime, explicit_authorizer \\ false) do
    with {:ok, proof} <- HTTPListenerBinding.validate(binding, runtime) do
      {:ok,
       %__MODULE__{
         table: Ref.table(runtime),
         edge: proof.gateway,
         generation: proof.generation,
         connection: binding,
         deadline: proof.deadline,
         proof: nil,
         http: %{
           kind: :listener,
           binding: binding,
           runtime: runtime,
           endpoint: proof.endpoint,
           identity: proof.identity,
           explicit_authorizer: explicit_authorizer
         }
       }}
    end
  end

  # Only a registration (no callback proof) can get the separate finite,
  # server-authored completion lease. Retired peer/generation is never reopened.
  def terminal(%__MODULE__{http: %{kind: :listener, binding: binding}} = registration, deadline) do
    with {:ok, completion} <- HTTPWriterRegistry.authorize_listener_completion(binding),
         {:ok, proof} <- HTTPListenerCompletion.validate(completion) do
      {:ok,
       %{
         registration
         | deadline: min(deadline, proof.deadline),
           http: Map.merge(registration.http, %{kind: :completion, completion: completion})
       }}
    end
  end

  def terminal(%__MODULE__{proof: nil} = registration, deadline) do
    candidate = %{registration | deadline: deadline}
    if valid?(candidate), do: {:ok, candidate}, else: {:error, :subscription_origin_retired}
  end

  def terminal(_origin, _deadline), do: {:error, :invalid_subscription_origin}

  defp capture_control(table, token, connection) do
    with {:ok, %{kind: :edge_control, owner: owner} = control} <- Admission.current(table, token),
         true <- owner == self(),
         {:ok, proof} <- Admission.control_output_origin(table, token, self()),
         do: build(table, connection, control.generation, proof, control.deadline),
         else: (_ -> {:error, :invalid_subscription_origin})
  rescue
    ArgumentError -> {:error, :invalid_subscription_origin}
  end

  defp capture_callback(nil), do: {:ok, nil}

  defp capture_callback(
         %{table: table, token: token, generation: generation, scope: scope} = context
       ) do
    case :ets.lookup(table, {:http_session_origin, token}) do
      [{_key, source}] -> capture_http(context, source)
      [] -> capture_edge_callback(table, token, generation, scope)
    end
  rescue
    ArgumentError -> {:error, :subscription_origin_retired}
  end

  defp capture_callback(_invalid), do: {:error, :invalid_subscription_origin}

  defp capture_edge_callback(table, token, generation, scope) do
    with {:ok,
          %{
            terminal: false,
            generation: ^generation,
            scope: ^scope,
            output_phase: phase
          } = source} <- Admission.current(table, token),
         [{:edge_connection, _edge, connection}] <- :ets.lookup(table, :edge_connection) do
      proof = %{
        phase: phase,
        token: token,
        generation: generation,
        scope: scope,
        deadline: source.deadline
      }

      build(table, connection, generation, proof, source.deadline)
    else
      _ -> {:error, :subscription_origin_retired}
    end
  rescue
    ArgumentError -> {:error, :subscription_origin_retired}
  end

  defp capture_http(context, source) do
    with {:ok,
          %{terminal: false, generation: generation, scope: scope, output_phase: phase} = current} <-
           Admission.current(context.table, context.token),
         true <- generation == context.generation and scope == context.scope,
         true <-
           source.generation == generation and source.scope == scope and source.phase == phase,
         [{:http_gateway, gateway}] when gateway == source.owner <-
           :ets.lookup(context.table, :http_gateway),
         endpoint when is_binary(endpoint) <- source[:endpoint] do
      proof = %{
        phase: phase,
        token: context.token,
        generation: generation,
        scope: scope,
        deadline: current.deadline
      }

      origin = %__MODULE__{
        table: context.table,
        edge: gateway,
        generation: generation,
        deadline: current.deadline,
        proof: proof,
        http: %{
          kind: :source,
          runtime: source.runtime,
          endpoint: :binary.copy(endpoint),
          lease: source.lease,
          identity: source.identity
        }
      }

      if :erlang.external_size(origin) <= 8_192 and valid?(origin),
        do: {:ok, origin},
        else: {:error, :subscription_origin_retired}
    else
      _invalid -> {:error, :subscription_origin_retired}
    end
  end

  defp http_current?(origin) do
    with [{:http_gateway, gateway}] when gateway == origin.edge <-
           :ets.lookup(origin.table, :http_gateway),
         true <- Process.alive?(gateway),
         {:ok, %{generation: generation}} when generation == origin.generation <-
           Admission.route(origin.table),
         true <- Deadline.remaining(origin.deadline) > 0 do
      lease_current?(origin.http)
    else
      _retired -> false
    end
  end

  defp lease_current?(%{lease: nil}), do: true

  defp lease_current?(%{lease: lease, runtime: runtime}),
    do:
      match?(
        {:ok, _},
        SessionLease.validate(lease, ServiceRef.new(runtime, :sessions), :sessions)
      )

  defp build(table, connection, generation, proof, deadline) do
    case :ets.lookup(table, :edge_connection) do
      [{:edge_connection, edge, ^connection}] ->
        origin = %__MODULE__{
          table: table,
          edge: edge,
          connection: connection,
          generation: generation,
          proof: proof,
          deadline: if(proof, do: min(proof.deadline, deadline), else: deadline)
        }

        if :erlang.external_size(origin) <= 4_096 and valid?(origin),
          do: {:ok, origin},
          else: {:error, :subscription_origin_retired}

      _ ->
        {:error, :subscription_origin_retired}
    end
  rescue
    ArgumentError -> {:error, :subscription_origin_retired}
  end
end
