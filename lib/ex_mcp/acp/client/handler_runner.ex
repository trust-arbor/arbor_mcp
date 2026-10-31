defmodule ExMCP.ACP.Client.HandlerRunner do
  @moduledoc false

  use GenServer

  require Logger

  alias ExMCP.ACP.Internal.UpdateQueue

  defstruct [:handler_mod, :handler_state, :owner, async_workers: %{}]

  def start_link(handler_mod, handler_opts, owner) do
    GenServer.start_link(__MODULE__, {handler_mod, handler_opts, owner})
  end

  # rc.6 compatibility: unbounded enqueue used Client defaults after security harden.
  @default_max_update_queue 32
  @default_max_update_queue_bytes 8_388_608

  @doc false
  def session_update(pid, session_id, update) do
    _ =
      session_update(
        pid,
        session_id,
        update,
        @default_max_update_queue,
        @default_max_update_queue_bytes
      )

    :ok
  end

  def session_update(pid, session_id, update, max_queue, max_queue_bytes) do
    session_update(pid, session_id, update, max_queue, max_queue_bytes, nil)
  end

  # `message` is the decoded JSON-RPC envelope, passed only when the handler
  # exports the context-aware callback (the Client checks that). It embeds the
  # update, so its size is the retained size when present.
  def session_update(pid, session_id, update, max_queue, max_queue_bytes, message) do
    case session_update_status(pid, session_id, update, max_queue, max_queue_bytes, message) do
      :ok -> :ok
      {:dropped, _reason} -> :dropped
    end
  end

  def session_update_status(pid, session_id, update, max_queue, max_queue_bytes, message) do
    case UpdateQueue.check(
           pid,
           max_queue,
           max_queue_bytes,
           update_size(update, message),
           :handler
         ) do
      :ok ->
        GenServer.cast(pid, {:session_update, session_id, update, message})
        :ok

      {:error, reason} ->
        {:dropped, reason}
    end
  end

  def session_updates_dropped(pid, session_id, count),
    do: GenServer.cast(pid, {:session_updates_dropped, session_id, count})

  defp update_size(update, nil), do: :erlang.external_size(update)
  defp update_size(_update, message), do: :erlang.external_size(message)

  # The admission bit is visible while a request is still queued behind a
  # synchronous callback. Cancellation must not wait for that mailbox.
  def new_request_ref do
    gate = :atomics.new(1, signed: false)
    :atomics.put(gate, 1, 1)
    {:acp_handler_request, make_ref(), gate}
  end

  def request_gate({:acp_handler_request, _ref, gate}), do: gate
  def request_gate(_ref), do: nil

  defp request_open?(ref) do
    case request_gate(ref) do
      nil -> true
      gate -> :atomics.get(gate, 1) == 1
    end
  end

  def permission_request(pid, ref, session_id, tool_call, options, message) do
    GenServer.cast(pid, {:permission_request, ref, session_id, tool_call, options, message})
  end

  def file_read(pid, ref, session_id, path, opts) do
    GenServer.cast(pid, {:file_read, ref, session_id, path, opts})
  end

  def file_write(pid, ref, session_id, path, content) do
    GenServer.cast(pid, {:file_write, ref, session_id, path, content})
  end

  def terminal_request(pid, ref, method, params, id) do
    GenServer.cast(pid, {:terminal_request, ref, method, params, id})
  end

  def elicitation_request(pid, ref, mode, params) do
    GenServer.cast(pid, {:elicitation_request, ref, mode, params})
  end

  def elicitation_complete(pid, elicitation_id) do
    GenServer.cast(pid, {:elicitation_complete, elicitation_id})
  end

  # Each of these has a legacy arity and a context-aware arity that also takes
  # the decoded JSON-RPC message. Both are optional on the behaviour so a
  # handler can implement just one, but it must export at least one of each
  # or updates and permission requests would fail at first dispatch.
  @callback_pairs [handle_session_update: [3, 4], handle_permission_request: [4, 5]]

  @impl true
  def init({handler_mod, handler_opts, owner}) do
    Process.flag(:trap_exit, true)

    case missing_callback(handler_mod) do
      nil -> init_handler(handler_mod, handler_opts, owner)
      callback -> {:stop, {:handler_init_failed, {:missing_callback, callback}}}
    end
  end

  defp init_handler(handler_mod, handler_opts, owner) do
    case safe_call(fn -> handler_mod.init(handler_opts) end) do
      {:ok, {:ok, handler_state}} ->
        {:ok, %__MODULE__{handler_mod: handler_mod, handler_state: handler_state, owner: owner}}

      {:ok, {:error, reason}} ->
        {:stop, {:handler_init_failed, reason}}

      {:ok, other} ->
        {:stop, {:handler_init_failed, {:invalid_return, other}}}

      {:error, reason} ->
        {:stop, {:handler_init_failed, reason}}
    end
  end

  defp missing_callback(handler_mod) do
    Code.ensure_loaded(handler_mod)

    Enum.find_value(@callback_pairs, fn {callback, arities} ->
      if not Enum.any?(arities, &function_exported?(handler_mod, callback, &1)), do: callback
    end)
  end

  @impl true
  def handle_cast(message, state) do
    if tuple_size(message) > 1 and not request_open?(elem(message, 1)) do
      {:noreply, state}
    else
      cast_message(message, state)
    end
  end

  defp cast_message({:session_update, session_id, update, message}, state) do
    case safe_call(fn ->
           call_with_context(state, :handle_session_update, [session_id, update], message)
         end) do
      {:ok, {:ok, handler_state}} ->
        {:noreply, %{state | handler_state: handler_state}}

      {:ok, other} ->
        Logger.warning("ACP handler returned invalid session update result",
          return_shape: return_shape(other)
        )

        {:noreply, state}

      {:error, reason} ->
        Logger.warning("ACP handler session update failed", error_class: error_class(reason))
        {:noreply, state}
    end
  end

  defp cast_message({:session_updates_dropped, session_id, count}, state) do
    case safe_call(fn ->
           state.handler_mod.handle_session_updates_dropped(
             session_id,
             count,
             state.handler_state
           )
         end) do
      {:ok, {:ok, handler_state}} -> {:noreply, %{state | handler_state: handler_state}}
      _failed -> {:noreply, state}
    end
  end

  defp cast_message({:permission_request, ref, session_id, tool_call, options, message}, state) do
    {result, state} =
      case safe_call(fn ->
             call_with_context(
               state,
               :handle_permission_request,
               [session_id, tool_call, options],
               message
             )
           end) do
        {:ok, {:async, work, handler_state}} when is_function(work, 0) ->
          {{:async, work}, %{state | handler_state: handler_state}}

        {:ok, {:ok, outcome, handler_state}} ->
          {{:ok, outcome}, %{state | handler_state: handler_state}}

        {:ok, {:error, reason, handler_state}} ->
          {{:error, reason}, %{state | handler_state: handler_state}}

        {:ok, other} ->
          {{:error, {:invalid_return, other}}, state}

        {:error, reason} ->
          {{:error, reason}, state}
      end

    reply_or_start_worker(state, ref, :permission, result)
  end

  defp cast_message({:file_read, ref, session_id, path, opts}, state) do
    {result, state} =
      case safe_call(fn ->
             state.handler_mod.handle_file_read(session_id, path, opts, state.handler_state)
           end) do
        {:ok, {:async, work, handler_state}} when is_function(work, 0) ->
          {{:async, work}, %{state | handler_state: handler_state}}

        {:ok, {:ok, content, handler_state}} ->
          {{:ok, content}, %{state | handler_state: handler_state}}

        {:ok, {:error, reason, handler_state}} ->
          {{:error, reason}, %{state | handler_state: handler_state}}

        {:ok, other} ->
          {{:error, {:invalid_return, other}}, state}

        {:error, reason} ->
          {{:error, reason}, state}
      end

    reply_or_start_worker(state, ref, :file_read, result)
  end

  defp cast_message({:file_write, ref, session_id, path, content}, state) do
    {result, state} =
      case safe_call(fn ->
             state.handler_mod.handle_file_write(session_id, path, content, state.handler_state)
           end) do
        {:ok, {:async, work, handler_state}} when is_function(work, 0) ->
          {{:async, work}, %{state | handler_state: handler_state}}

        {:ok, {:ok, handler_state}} ->
          {:ok, %{state | handler_state: handler_state}}

        {:ok, {:error, reason, handler_state}} ->
          {{:error, reason}, %{state | handler_state: handler_state}}

        {:ok, other} ->
          {{:error, {:invalid_return, other}}, state}

        {:error, reason} ->
          {{:error, reason}, state}
      end

    reply_or_start_worker(state, ref, :file_write, result)
  end

  defp cast_message({:terminal_request, ref, method, params, id}, state) do
    {result, state} =
      case safe_call(fn ->
             state.handler_mod.handle_terminal_request(method, params, id, state.handler_state)
           end) do
        {:ok, {:async, work, handler_state}} when is_function(work, 0) ->
          {{:async, work}, %{state | handler_state: handler_state}}

        {:ok, {:ok, response, handler_state}} ->
          {{:ok, response}, %{state | handler_state: handler_state}}

        {:ok, {:error, reason, handler_state}} ->
          {{:error, reason}, %{state | handler_state: handler_state}}

        {:ok, other} ->
          {{:error, {:invalid_return, other}}, state}

        {:error, reason} ->
          {{:error, reason}, state}
      end

    reply_or_start_worker(state, ref, :terminal, result)
  end

  defp cast_message({:elicitation_request, ref, mode, params}, state) do
    callback = if mode == "form", do: :handle_form_elicitation, else: :handle_url_elicitation

    {result, state} =
      case safe_call(fn -> apply(state.handler_mod, callback, [params, state.handler_state]) end) do
        {:ok, {:async, work, handler_state}} when is_function(work, 0) ->
          {{:async, work}, %{state | handler_state: handler_state}}

        {:ok, {:ok, response, handler_state}} ->
          {{:ok, response}, %{state | handler_state: handler_state}}

        {:ok, {:error, reason, handler_state}} ->
          {{:error, reason}, %{state | handler_state: handler_state}}

        {:ok, other} ->
          {{:error, {:invalid_return, other}}, state}

        {:error, reason} ->
          {{:error, reason}, state}
      end

    reply_or_start_worker(state, ref, :elicitation, result)
  end

  defp cast_message({:elicitation_complete, elicitation_id}, state) do
    state =
      case safe_call(fn ->
             state.handler_mod.handle_elicitation_complete(elicitation_id, state.handler_state)
           end) do
        {:ok, {:ok, handler_state}} -> %{state | handler_state: handler_state}
        _invalid_or_failed -> state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:handler_worker_done, ref, outcome}, state) do
    case Map.pop(state.async_workers, ref) do
      {nil, _workers} ->
        {:noreply, state}

      {%{monitor: monitor, kind: kind}, workers} ->
        Process.demonitor(monitor, [:flush])

        if outcome != :skipped and request_open?(ref),
          do: send(state.owner, {:acp_handler_result, ref, {kind, outcome}})

        {:noreply, %{state | async_workers: workers}}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Enum.find(state.async_workers, fn {_ref, worker} -> worker.monitor == monitor end) do
      nil ->
        {:noreply, state}

      {ref, worker} ->
        if request_open?(ref),
          do:
            send(
              state.owner,
              {:acp_handler_result, ref, {worker.kind, {:error, {:exit, reason}}}}
            )

        {:noreply, %{state | async_workers: Map.delete(state.async_workers, ref)}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    Enum.each(state.async_workers, fn {_ref, %{pid: pid}} -> Process.exit(pid, :kill) end)

    if function_exported?(state.handler_mod, :terminate, 2) do
      _ = safe_call(fn -> state.handler_mod.terminate(reason, state.handler_state) end)
    end

    :ok
  end

  defp reply_or_start_worker(state, ref, kind, {:async, work}) do
    runner = self()
    owner = state.owner

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          admitted =
            if request_gate(ref) do
              try do
                GenServer.call(owner, {:handler_worker_admit, ref, self()}, :infinity)
              catch
                :exit, _ -> false
              end
            else
              {:ok, :infinity}
            end

          if request_open?(ref) and admission_current?(admitted) do
            outcome = normalize_work_result(kind, safe_call(work))
            send(runner, {:handler_worker_done, ref, outcome})
          else
            # The Client's timeout/cancellation path owns settlement. Retire
            # normally without converting this skip into a worker failure.
            send(runner, {:handler_worker_done, ref, :skipped})
          end
        end,
        [:link, :monitor]
      )

    worker = %{pid: pid, monitor: monitor, kind: kind}
    {:noreply, %{state | async_workers: Map.put(state.async_workers, ref, worker)}}
  end

  defp reply_or_start_worker(state, ref, kind, result) do
    send(state.owner, {:acp_handler_result, ref, {kind, result}})
    {:noreply, state}
  end

  defp normalize_work_result(:file_write, {:ok, :ok}), do: :ok

  defp normalize_work_result(kind, {:ok, {:ok, value}}) when kind != :file_write,
    do: {:ok, value}

  defp normalize_work_result(_kind, {:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_work_result(_kind, {:error, reason}), do: {:error, reason}
  defp normalize_work_result(_kind, {:ok, other}), do: {:error, {:invalid_return, other}}

  defp admission_current?({:ok, :infinity}), do: true

  defp admission_current?({:ok, deadline}) when is_integer(deadline),
    do: deadline > System.monotonic_time(:millisecond)

  defp admission_current?(_denied), do: false

  # The Client passes `message` only when the handler exports the context
  # variant, so its presence selects the arity.
  defp call_with_context(state, callback, args, nil),
    do: apply(state.handler_mod, callback, args ++ [state.handler_state])

  defp call_with_context(state, callback, args, message),
    do: apply(state.handler_mod, callback, args ++ [message, state.handler_state])

  defp safe_call(fun) do
    {:ok, fun.()}
  catch
    kind, reason ->
      {:error, {kind, reason, __STACKTRACE__}}
  end

  defp return_shape(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp return_shape(value) when is_map(value), do: :map
  defp return_shape(value) when is_list(value), do: :list
  defp return_shape(value) when is_atom(value), do: :atom
  defp return_shape(_value), do: :other

  defp error_class({kind, reason, _stack}) when kind in [:error, :exit, :throw],
    do: {kind, exception_module(reason)}

  defp exception_module(%{__struct__: module}) when is_atom(module), do: module
  defp exception_module(_reason), do: :non_exception
end
