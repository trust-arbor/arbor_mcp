defmodule Arbor.MCP.Server.HTTP.Bandit.Connection do
  @moduledoc false
  use GenServer, restart: :temporary
  alias Arbor.MCP.Server.HTTP.Bandit.ConnectionSlots
  alias Arbor.MCP.Server.Runtime.{Deadline, Diagnostics, Ref, ShutdownGuard}
  @timeout_limit 4_294_967_295

  def child_spec(argument) do
    %{
      id: __MODULE__,
      start: {Diagnostics, :start_child, [fn -> start_link(argument) end]},
      type: :worker,
      restart: :temporary,
      shutdown: 5_000
    }
  end

  def start_link({{runtime, handler_options}, options}) do
    timeout = Keyword.get(options, :timeout, 10_000)

    if is_integer(timeout) and timeout > 0 and timeout <= @timeout_limit do
      deadline = Deadline.now() + timeout

      with {:ok, slot} <- ConnectionSlots.reserve(runtime, deadline) do
        try do
          result =
            GenServer.start_link(
              __MODULE__,
              fn -> {runtime, handler_options, slot, deadline} end,
              Keyword.put(options, :timeout, Deadline.remaining(deadline))
            )

          case result do
            {:ok, pid} ->
              if ConnectionSlots.accepted?(slot, pid, deadline) do
                result
              else
                Process.unlink(pid)
                Process.exit(pid, :kill)
                {:error, :max_children}
              end

            _failed ->
              ConnectionSlots.release(slot)
              result
          end
        catch
          _kind, _reason ->
            ConnectionSlots.release(slot)
            {:error, :http_connection_closed}
        end
      end
    else
      {:error, :max_children}
    end
  end

  @impl true
  def init(constructor) do
    {runtime, options, slot, deadline} = constructor.()

    with {:ok, _} <- ConnectionSlots.bind(slot),
         :ok <- ShutdownGuard.watch(Ref.table(runtime), self(), :worker, deadline),
         true <- Deadline.now() < deadline,
         {:ok, state} <- invoke(:init, [options]) do
      {:ok, %{state: state, slot: slot, deadline: deadline}}
    else
      _ -> {:stop, :http_connection_closed}
    end
  catch
    _kind, _reason -> {:stop, :http_connection_closed}
  end

  @impl true
  def handle_call(message, from, state),
    do: invoke(:handle_call, [message, from, state.state]) |> wrap(state)

  @impl true
  def handle_cast(message, state), do: invoke(:handle_cast, [message, state.state]) |> wrap(state)
  @impl true
  def handle_info(message, state), do: invoke(:handle_info, [message, state.state]) |> wrap(state)
  @impl true
  def handle_continue(message, state),
    do: invoke(:handle_continue, [message, state.state]) |> wrap(state)

  @impl true
  def terminate(reason, state) do
    invoke(:terminate, [reason, state.state])
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

  defp wrap({:stop, reason, next}, state),
    do: {:stop, safe_reason(reason), %{state | state: next}}

  defp wrap({:stop, reason, reply, next}, state),
    do: {:stop, safe_reason(reason), reply, %{state | state: next}}

  defp safe_reason(reason) when reason in [:normal, :shutdown], do: reason
  defp safe_reason(_reason), do: :http_connection_closed

  defp invoke(function, arguments) do
    # Fixed callback is installed only with the qualified optional backend.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(Bandit.DelegatingHandler, function, arguments)
  end
end
