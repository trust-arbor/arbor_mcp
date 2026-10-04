defmodule Arbor.MCP.Server.Runtime.Deadline do
  @moduledoc false

  @type t :: integer() | :infinity
  @min_integer -9_223_372_036_854_775_808
  @max_integer 9_223_372_036_854_775_807

  def now, do: System.monotonic_time(:millisecond)
  def after_ms(:infinity), do: :infinity
  def after_ms(milliseconds), do: now() + milliseconds
  def remaining(:infinity), do: :infinity
  def remaining(deadline), do: max(0, deadline - now())

  def validate(:infinity), do: :ok

  def validate(deadline)
      when is_integer(deadline) and deadline >= @min_integer and deadline <= @max_integer,
      do: :ok

  def validate(_invalid), do: {:error, :invalid_admission_deadline}

  def admission_limit(reservation) do
    server = reservation.deadline
    caller = Map.get(reservation, :admission_deadline, :infinity)

    if caller == :infinity or server <= caller,
      do: {server, :handler_timeout},
      else: {caller, :await_timeout}
  end

  def admission_error(reservation) do
    {deadline, reason} = admission_limit(reservation)
    if now() >= deadline, do: reason
  end

  def confirmation_budget(reservation) do
    {deadline, reason} = admission_limit(reservation)
    control_deadline = now() + 5_000

    if control_deadline < deadline,
      do: {remaining(control_deadline), :runtime_unavailable},
      else: {remaining(deadline), reason}
  end
end
