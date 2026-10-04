defmodule Arbor.MCP.Server.Runtime.ServiceInvocation do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime.{Admission, Deadline, Ref, Services}

  @enforce_keys [:runtime, :kind, :generation, :owner, :deadline, :origin]
  defstruct [:runtime, :kind, :generation, :owner, :deadline, :origin]

  @opaque t :: %__MODULE__{
            runtime: Ref.t(),
            kind: atom(),
            generation: reference(),
            owner: pid(),
            deadline: integer(),
            origin: map() | nil
          }

  @spec capture(map(), Deadline.t()) :: {:ok, t()} | {:error, atom()}
  def capture(%{origin: nil} = context, _supplied_deadline),
    do: {:ok, snapshot(context, nil, context.deadline)}

  def capture(context, supplied_deadline) do
    table = Ref.table(context.runtime)
    origin = context.origin

    with true <- origin.runtime == context.runtime,
         true <- Admission.origin_active?(table, origin),
         {:ok, reservation} <- Admission.current(table, origin.token),
         true <- reservation.output_phase == origin.output_phase,
         true <- reservation.owner == context.owner do
      deadline =
        if supplied_deadline == :infinity,
          do: reservation.deadline,
          else: min(reservation.deadline, supplied_deadline)

      authority = %{
        token: reservation.token,
        generation: reservation.generation,
        scope: reservation.scope,
        phase: reservation.output_phase,
        deadline: deadline
      }

      {:ok, snapshot(context, authority, deadline)}
    else
      false -> {:error, :invalid_initialization_owner_or_origin}
      _retired -> {:error, :operation_timeout}
    end
  rescue
    ArgumentError -> {:error, :operation_timeout}
  end

  defp snapshot(context, origin, deadline) do
    %__MODULE__{
      runtime: context.runtime,
      kind: context.kind,
      generation: context.generation,
      owner: context.owner,
      deadline: deadline,
      origin: origin
    }
  end

  @spec owner(t()) :: pid()
  def owner(%__MODULE__{owner: owner}), do: owner

  @spec deadline(t()) :: integer()
  def deadline(%__MODULE__{deadline: deadline}), do: deadline

  @spec current?(t()) :: boolean()
  def current?(%__MODULE__{} = invocation) do
    with true <- Deadline.now() < invocation.deadline and Process.alive?(invocation.owner),
         {:ok, binding} <- Services.resolve(invocation.runtime, invocation.kind),
         true <- binding.generation == invocation.generation do
      origin_current?(invocation)
    else
      _retired -> false
    end
  rescue
    ArgumentError -> false
  end

  defp origin_current?(%__MODULE__{origin: nil}), do: true

  defp origin_current?(invocation) do
    table = Ref.table(invocation.runtime)
    Admission.output_origin_valid?(table, invocation.origin)
  end
end
