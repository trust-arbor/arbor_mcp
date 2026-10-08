defmodule Arbor.MCP.Server.Runtime.HTTPNotificationTarget do
  @moduledoc false
  alias Arbor.MCP.Server.Runtime.{
    Admission,
    CallbackContext,
    Deadline,
    HTTPNotifications,
    HTTPOutput,
    HTTPWriterBinding,
    HTTPWriterRegistry,
    HTTPWriteTicket,
    OutputController,
    OutputTicket,
    Ref
  }

  @enforce_keys [:runtime, :binding]
  defstruct [:runtime, :binding, :lease, mode: :request]

  @opaque t :: %__MODULE__{
            runtime: Ref.t(),
            binding: HTTPWriterBinding.t(),
            mode: :request | :legacy_session,
            lease: term()
          }

  def new(runtime, binding), do: new(runtime, binding, :sse)

  def new(runtime, binding, format) when format in [:sse, :legacy_sse] do
    with {:ok, proof} <- HTTPWriterBinding.validate(binding, runtime),
         true <- proof.owner == self() do
      {:ok,
       %__MODULE__{
         runtime: runtime,
         binding: binding,
         lease: proof.lease,
         mode: if(format == :legacy_sse, do: :legacy_session, else: :request)
       }}
    else
      _invalid -> {:error, :request_not_streaming}
    end
  end

  def target?(%__MODULE__{}), do: true
  def target?(_target), do: false

  # The response term is prepared in producer-side ETS under the original
  # callback authority. The Controller receives only handles and wake tokens.
  def deliver(%__MODULE__{mode: :legacy_session} = target, value),
    do: HTTPNotifications.deliver(target.runtime, target.lease, value)

  def deliver(%__MODULE__{} = target, value) do
    with %{table: table, token: source, generation: generation, scope: scope, output_phase: phase} <-
           CallbackContext.current(),
         true <- table == Ref.table(target.runtime),
         {:ok, %{generation: ^generation, scope: ^scope, output_phase: ^phase} = invocation} <-
           Admission.current(table, source),
         true <- HTTPWriterRegistry.source_valid?(target.binding, source),
         {:ok, token, context} <-
           OutputController.http_notification(table, source, target.binding, invocation.deadline),
         {:ok, ticket} <- OutputController.prepare(context, value) do
      case OutputController.http_notification_prepared(table, token, ticket, invocation.deadline) do
        :ok ->
          await(OutputTicket.http(ticket), invocation.deadline)

        _closed ->
          HTTPOutput.release_all(ticket)
          {:error, :stream_closed}
      end
    else
      _invalid -> {:error, :stream_closed}
    end
  end

  def deliver(_target, _value), do: {:error, :request_not_streaming}

  defp await(ticket, deadline) do
    case HTTPWriteTicket.receipt(ticket) do
      1 ->
        :ok

      result when result in [2, 3] ->
        {:error, :stream_closed}

      0 ->
        if Deadline.now() < deadline do
          Process.sleep(min(5, Deadline.remaining(deadline)))
          await(ticket, deadline)
        else
          HTTPWriterRegistry.release(ticket)
          {:error, :stream_timeout}
        end
    end
  end
end
