defmodule Arbor.MCP.Server.Subscriptions.Origin do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime.{Admission, CallbackContext, Deadline}

  defstruct [:table, :edge, :connection, :generation, :proof, :deadline]
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
  def proof(nil), do: nil
  def proof(%__MODULE__{proof: proof}), do: proof
  def target(nil, target), do: target
  def target(%__MODULE__{edge: edge}, nil), do: edge
  def target(_origin, target), do: target

  def limit(%__MODULE__{} = origin, deadline),
    do: %{origin | deadline: min(origin.deadline, deadline)}

  def compatible?(%__MODULE__{} = origin, %__MODULE__{} = registration),
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

  # Only a registration (no callback proof) can get the separate finite,
  # server-authored completion lease. Retired peer/generation is never reopened.
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

  defp capture_callback(%{table: table, token: token, generation: generation, scope: scope}) do
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

  defp capture_callback(_invalid), do: {:error, :invalid_subscription_origin}

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
