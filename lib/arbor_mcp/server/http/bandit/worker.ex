defmodule Arbor.MCP.Server.HTTP.Bandit.Worker do
  @moduledoc false
  use GenServer

  alias Arbor.MCP.Server.Runtime.{Diagnostics, Initialization, Ref}

  def start_link(runtime, module, argument),
    do:
      GenServer.start_link(__MODULE__, fn -> {runtime, module, argument} end,
        timeout: Initialization.remaining(Ref.table(runtime))
      )

  @impl true
  def init(constructor) do
    {runtime, module, argument} = constructor.()

    with :ok <- Initialization.watch(Ref.table(runtime), self()),
         result <- invoke(module, :init, [argument]) do
      case result do
        {:ok, state} -> {:ok, %{module: module, state: state}}
        {:ok, state, action} -> {:ok, %{module: module, state: state}, action}
        _ -> {:stop, :http_listener_start_failed}
      end
    else
      _ -> {:stop, :http_listener_start_failed}
    end
  catch
    _kind, _reason -> {:stop, :http_listener_start_failed}
  end

  @impl true
  def handle_call(message, from, state),
    do: state.module |> invoke(:handle_call, [message, from, state.state]) |> wrap(state)

  @impl true
  def handle_continue(action, state),
    do: state.module |> invoke(:handle_continue, [action, state.state]) |> wrap(state)

  @impl true
  def handle_info(message, state),
    do: state.module |> invoke(:handle_info, [message, state.state]) |> wrap(state)

  @impl true
  def terminate(reason, state) do
    invoke(state.module, :terminate, [reason, state.state])
  catch
    _kind, _reason -> :ok
  end

  @impl true
  def format_status(status), do: Diagnostics.format_status(status, __MODULE__)

  defp wrap({:reply, reply, next}, state), do: {:reply, reply, %{state | state: next}}

  defp wrap({:reply, reply, next, action}, state),
    do: {:reply, reply, %{state | state: next}, action}

  defp wrap({:noreply, next}, state), do: {:noreply, %{state | state: next}}
  defp wrap({:noreply, next, action}, state), do: {:noreply, %{state | state: next}, action}

  defp wrap({:stop, _reason, next}, state),
    do: {:stop, :http_listener_closed, %{state | state: next}}

  defp invoke(module, function, arguments) do
    # This callback module is present only for the qualified optional backend.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(module, function, arguments)
  end
end
