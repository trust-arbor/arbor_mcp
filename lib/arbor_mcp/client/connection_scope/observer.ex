defmodule Arbor.MCP.Client.ConnectionScope.Observer do
  @moduledoc false
  use GenServer

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.ConnectionScope
  alias Arbor.MCP.Client.ConnectionScope.Ref
  alias Arbor.MCP.Client.Deadline
  alias Arbor.MCP.Transport.{HTTP, ReliabilityWrapper, Stdio}
  alias Arbor.RPC.Subprocess
  alias Arbor.RPC.Subprocess.Receipt

  def start(owner, opts, deadline, cleanup, workers, token) do
    GenServer.start(__MODULE__, {owner, opts, deadline, cleanup, workers, token},
      timeout: Deadline.remaining(deadline)
    )
  end

  @impl true
  def init({owner, opts, deadline, cleanup, workers, token}) do
    scope = Ref.new(self(), token, deadline, cleanup)
    observer = self()

    {guardian, guardian_monitor} =
      spawn_monitor(fn -> guardian(observer, scope, opts, deadline) end)

    timer = Process.send_after(self(), :establish_cutoff, Deadline.remaining(deadline))

    {:ok,
     %{
       owner: owner,
       owner_monitor: Process.monitor(owner),
       token: token,
       deadline: deadline,
       cleanup_ms: cleanup,
       cleanup_deadline: nil,
       max_workers: workers,
       guardian: guardian,
       guardian_monitor: guardian_monitor,
       client: nil,
       client_monitor: nil,
       phase: :starting,
       ready: nil,
       ready_waiter: nil,
       finish_waiter: nil,
       workers: %{},
       transports: %{},
       transport_failures: [],
       opening: false,
       cleanup: nil,
       proof_result: nil,
       timer: timer
     }}
  end

  defp guardian(observer, scope, opts, deadline) do
    Process.flag(:trap_exit, true)
    ConnectionScope.watch_guardian(self(), observer)
    monitor = Process.monitor(observer)
    result = Client.start_scoped(opts, scope, deadline)
    send(observer, {:native_result, self(), result})
    guardian_loop(observer, monitor, result)
  end

  defp guardian_loop(observer, monitor, result) do
    receive do
      {:cleanup, deadline} ->
        cleanup = cleanup_client(result, deadline)
        send(observer, {:cleanup_result, self(), cleanup})

      {:DOWN, ^monitor, :process, ^observer, _reason} ->
        cleanup_client(result, Deadline.after_ms(1_000))

      {:EXIT, _pid, _reason} ->
        guardian_loop(observer, monitor, result)
    end
  end

  defp cleanup_client({:ok, client}, deadline) do
    result = GenServer.call(client, {:scope_disconnect, deadline}, Deadline.remaining(deadline))
    GenServer.stop(client, :normal, Deadline.remaining(deadline))
    result
  catch
    :exit, {:noproc, _call} -> :ok
    :exit, reason -> {:error, {:client_cleanup_exit, reason}}
  end

  defp cleanup_client(_failed_start, _deadline), do: :ok

  @impl true
  def handle_info({:scope_call, token, caller, reply, message}, %{token: token} = state) do
    handle_scope_call(message, caller, reply, state)
  end

  def handle_info({:native_result, guardian, result}, %{guardian: guardian} = state) do
    if state.phase == :starting and not Deadline.expired?(state.deadline) do
      reply(state.ready_waiter, result)
      {:noreply, %{state | ready: result, ready_waiter: nil}}
    else
      {:noreply, begin_cleanup(state, state.cleanup_deadline)}
    end
  end

  def handle_info({:cleanup_result, guardian, result}, %{guardian: guardian} = state) do
    state = %{state | cleanup: result}
    start_receipt_check(state)
  end

  def handle_info({:receipt_result, result}, state),
    do: maybe_complete(%{state | proof_result: result})

  def handle_info(:establish_cutoff, %{phase: :starting} = state) do
    reply(state.ready_waiter, {:error, :establish_timeout})
    {:noreply, begin_cleanup(%{state | ready_waiter: nil}, nil)}
  end

  def handle_info(:establish_cutoff, state), do: {:noreply, state}

  def handle_info(:cleanup_cutoff, state) do
    kill(state.client)
    kill(state.guardian)
    Enum.each(state.workers, fn {_ref, pid} -> kill(pid) end)
    complete(state, {:error, :cleanup_timeout})
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    cond do
      monitor == state.owner_monitor ->
        {:noreply, begin_cleanup(state, nil)}

      monitor == state.client_monitor ->
        maybe_complete(%{state | client_monitor: nil})

      monitor == state.guardian_monitor ->
        guardian_down(state)

      Map.has_key?(state.workers, monitor) ->
        maybe_complete(%{state | workers: Map.delete(state.workers, monitor)})

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_scope_call(:ready, caller, target, %{owner: caller} = state) do
    cond do
      state.phase != :starting ->
        reply(target, {:error, :establish_timeout})
        {:noreply, state}

      state.ready ->
        reply(target, state.ready)
        {:noreply, state}

      true ->
        {:noreply, %{state | ready_waiter: target}}
    end
  end

  defp handle_scope_call(:activate, caller, target, %{owner: caller} = state) do
    if state.phase == :starting and match?({:ok, _pid}, state.ready) and
         not Deadline.expired?(state.deadline) do
      Process.cancel_timer(state.timer)
      reply(target, :ok)
      {:noreply, %{state | phase: :active}}
    else
      reply(target, {:error, :establish_timeout})
      {:noreply, begin_cleanup(state, nil)}
    end
  end

  defp handle_scope_call({:finish, deadline}, caller, target, %{owner: caller} = state) do
    {:noreply, begin_cleanup(%{state | finish_waiter: target}, deadline)}
  end

  defp handle_scope_call({:register_client, caller}, caller, target, state) do
    # The claim is checked against the actual native client's proc_lib parent,
    # not a caller-supplied PID or a traversal of arbitrary links.
    dictionary = Process.info(caller, :dictionary)

    valid =
      case dictionary do
        {:dictionary, values} ->
          List.keyfind(values, :"$initial_call", 0) ==
            {:"$initial_call", {Client, :init, 1}} and
            match?(
              {:"$ancestors", [guardian | _]} when guardian == state.guardian,
              List.keyfind(values, :"$ancestors", 0)
            )

        _missing ->
          false
      end

    if valid and state.client == nil and state.phase == :starting and
         not Deadline.expired?(state.deadline) do
      reply(target, {:ok, state.guardian})
      {:noreply, %{state | client: caller, client_monitor: Process.monitor(caller)}}
    else
      reply(target, {:error, :connection_scope_closed})
      {:noreply, state}
    end
  end

  defp handle_scope_call(:opening, caller, target, %{client: caller} = state) do
    reply(target, if(state.phase in [:starting, :active], do: :ok, else: {:error, :closed}))
    {:noreply, %{state | opening: true}}
  end

  defp handle_scope_call({:transport, mod, transport}, caller, target, %{client: caller} = state) do
    if state.phase in [:starting, :active] do
      key = transport_key(mod, transport)

      if Map.has_key?(state.transports, key) or map_size(state.transports) < 32 do
        reply(target, :ok)

        {:noreply,
         %{
           state
           | transports:
               Map.put(state.transports, key, %{
                 transport: {mod, transport},
                 closed:
                   if(state.opening, do: nil, else: get_in(state.transports, [key, :closed]))
               }),
             opening: false
         }}
      else
        reply(target, {:error, :transport_history_exhausted})
        {:noreply, %{state | opening: true, transport_failures: [:transport_history_exhausted]}}
      end
    else
      reply(target, {:error, :closed})
      {:noreply, state}
    end
  end

  defp handle_scope_call(
         {:closed, mod, transport, result},
         caller,
         target,
         %{client: caller} = state
       ) do
    key = transport_key(mod, transport)
    reply(target, :ok)

    transports =
      if Map.has_key?(state.transports, key) or map_size(state.transports) < 32 do
        Map.update(
          state.transports,
          key,
          %{transport: {mod, transport}, closed: result},
          &Map.put(&1, :closed, result)
        )
      else
        state.transports
      end

    proof = close_observation(mod, transport, result)

    failures =
      if proof == :ok,
        do: state.transport_failures,
        else: [proof | Enum.take(state.transport_failures, 31)]

    {:noreply, %{state | transports: transports, transport_failures: failures}}
  end

  defp handle_scope_call({:native_worker, caller}, caller, target, state) do
    if worker_slot_available?(state) and native_owned_worker?(caller, state) do
      monitor = Process.monitor(caller)
      reply(target, {:ok, state.client})
      {:noreply, %{state | workers: Map.put(state.workers, monitor, caller)}}
    else
      reply(target, {:error, :connection_scope_closed})
      {:noreply, state}
    end
  end

  defp handle_scope_call({:worker, pid}, caller, target, state) do
    if worker_slot_available?(state) and
         (caller == state.client or caller in Map.values(state.workers)) and node(pid) == node() do
      monitor = Process.monitor(pid)
      reply(target, :ok)
      {:noreply, %{state | workers: Map.put(state.workers, monitor, pid)}}
    else
      reply(target, {:error, :connection_scope_closed})
      {:noreply, state}
    end
  end

  defp handle_scope_call(_message, _caller, target, state) do
    reply(target, {:error, :invalid_connection_scope_caller})
    {:noreply, state}
  end

  defp worker_slot_available?(state) do
    state.phase in [:starting, :active] and map_size(state.workers) < state.max_workers and
      (state.phase == :active or not Deadline.expired?(state.deadline))
  end

  defp native_owned_worker?(pid, state) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        initial = List.keyfind(dictionary, :"$initial_call", 0)
        ancestors = List.keyfind(dictionary, :"$ancestors", 0)

        module_ok =
          initial in [
            {:"$initial_call", {Arbor.MCP.Transport.HTTP.ModernStreamClient, :init, 1}},
            {:"$initial_call", {Arbor.MCP.Transport.SSEClient, :init, 1}}
          ]

        parent_ok =
          case ancestors do
            {:"$ancestors", [parent | _]} ->
              parent == state.client or parent in Map.values(state.workers)

            _missing ->
              false
          end

        module_ok and parent_ok

      _missing ->
        false
    end
  end

  defp close_observation(ReliabilityWrapper, state, result) do
    {mod, transport} = ReliabilityWrapper.unwrap(state)
    close_observation(mod, transport, result)
  end

  defp close_observation(HTTP, %HTTP{session_id: id}, :ok) when is_binary(id),
    do: {:error, :remote_session_cleanup_unconfirmed}

  defp close_observation(_mod, _state, result), do: normalize_cleanup(result)

  defp normalize_cleanup(:ok), do: :ok
  defp normalize_cleanup({:error, _reason} = error), do: error
  defp normalize_cleanup(other), do: {:error, {:invalid_close_result, other}}

  defp transport_key(ReliabilityWrapper, state) do
    {mod, transport} = ReliabilityWrapper.unwrap(state)
    transport_key(mod, transport)
  end

  defp transport_key(Stdio, %Stdio{subprocess: handle}), do: {Stdio, handle}
  defp transport_key(HTTP, _state), do: HTTP
  defp transport_key(mod, _state), do: mod

  defp begin_cleanup(%{phase: :cleaning} = state, _deadline), do: state

  defp begin_cleanup(state, deadline) do
    Process.cancel_timer(state.timer)
    deadline = deadline || Deadline.after_ms(state.cleanup_ms)
    deadline = min(deadline, Deadline.after_ms(state.cleanup_ms))
    Enum.each(state.workers, fn {_monitor, pid} -> kill(pid) end)
    send(state.guardian, {:cleanup, deadline})
    timer = Process.send_after(self(), :cleanup_cutoff, Deadline.remaining(deadline))
    %{state | phase: :cleaning, cleanup_deadline: deadline, timer: timer}
  end

  defp guardian_down(%{phase: :cleaning, cleanup: nil} = state) do
    kill(state.client)
    start_receipt_check(%{state | cleanup: {:error, :scope_guardian_down}})
  end

  defp guardian_down(%{phase: :cleaning} = state), do: {:noreply, state}

  defp guardian_down(state) do
    reply(state.ready_waiter, {:error, :connection_scope_guardian_down})
    {:noreply, begin_cleanup(%{state | ready_waiter: nil}, nil)}
  end

  defp start_receipt_check(state) do
    observer = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        result = all_cleanup_proofs(state)
        send(observer, {:receipt_result, result})
      end)

    {:noreply, %{state | workers: Map.put(state.workers, monitor, pid)}}
  end

  defp all_cleanup_proofs(state) do
    results =
      Enum.map(state.transports, fn {_key, record} ->
        cleanup_proof(record.transport, record.closed)
      end)

    results = [state.cleanup | state.transport_failures ++ results]

    results =
      if state.opening,
        do: [{:error, :transport_start_cleanup_unconfirmed} | results],
        else: results

    results |> Enum.find(:ok, &(&1 != :ok)) |> normalize_cleanup()
  end

  defp cleanup_proof({ReliabilityWrapper, state}, cleanup),
    do: cleanup_proof(ReliabilityWrapper.unwrap(state), cleanup)

  defp cleanup_proof({Stdio, %Stdio{subprocess: subprocess}}, _cleanup) do
    with {:ok, receipt} <- Subprocess.cleanup_receipt(subprocess), do: Receipt.result(receipt)
  end

  defp cleanup_proof({HTTP, %HTTP{session_id: id}}, :ok) when is_binary(id),
    do: {:error, :remote_session_cleanup_unconfirmed}

  defp cleanup_proof(_transport, nil), do: {:error, :transport_cleanup_unconfirmed}
  defp cleanup_proof(_transport, cleanup), do: cleanup

  defp maybe_complete(%{proof_result: nil} = state), do: {:noreply, state}

  defp maybe_complete(state) do
    live_worker = Enum.any?(state.workers, fn {_monitor, pid} -> Process.alive?(pid) end)
    live_client = is_pid(state.client) and Process.alive?(state.client)

    if live_worker or live_client,
      do: {:noreply, state},
      else: complete(state, state.proof_result)
  end

  defp complete(state, result) do
    result =
      if result == :ok and is_pid(state.client) and Process.alive?(state.client),
        do: {:error, :client_cleanup_unconfirmed},
        else: result

    kill(state.client)
    kill(state.guardian)
    Enum.each(state.workers, fn {_monitor, pid} -> kill(pid) end)
    Process.cancel_timer(state.timer)
    reply(state.finish_waiter, {:cleanup, result})
    {:stop, :normal, state}
  end

  defp reply(nil, _result), do: :ok
  defp reply(target, result), do: send(target, {target, result})
  defp kill(nil), do: :ok
  defp kill(pid), do: Process.exit(pid, :kill)

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, %{scope: :connection_lifecycle})
    |> Map.put(:message, :redacted)
    |> Map.put(:reason, :redacted)
    |> Map.put(:log, [])
  end
end
