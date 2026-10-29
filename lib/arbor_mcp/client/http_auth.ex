defmodule Arbor.MCP.Client.HTTPAuth do
  @moduledoc false

  alias Arbor.MCP.Client.{ConnectionScope, Deadline, Lifetime}
  alias Arbor.MCP.Transport.HTTP

  @auth_wait_ms 600_000
  @derive {Inspect, except: [:waiters]}
  defstruct worker: nil, waiters: %{}, monitors: %{}

  # The client owns one inline flow. Its challengers retain separate deadlines
  # and monitors; the OAuth worker itself never sends an application request.
  def challenge(state, kind, pid, request_id, ref, challenge) do
    state = reject_token(state, challenge)
    deadline = Deadline.earliest(Map.get(challenge, :deadline), Deadline.after_ms(@auth_wait_ms))

    waiter = %{
      kind: kind,
      pid: pid,
      request_id: request_id,
      ref: ref,
      deadline: deadline,
      challenge: challenge,
      scopes: if(challenge.status == 403, do: challenge.scopes, else: []),
      order: System.unique_integer([:monotonic]),
      flow: nil
    }

    cond do
      Deadline.expired?(deadline) ->
        reply(waiter, {:error, :timeout}, state.transport_state)
        state

      token = cached_token(state.transport_state, challenge) ->
        reply(waiter, {:ok, token}, state.transport_state)
        state

      true ->
        monitor = Process.monitor(pid)

        timer =
          Process.send_after(
            self(),
            {:http_auth_waiter_timeout, ref},
            Deadline.remaining(deadline)
          )

        waiter = Map.merge(waiter, %{monitor: monitor, timer: timer})
        auth = state.http_auth

        auth = %{
          auth
          | waiters: Map.put(auth.waiters, ref, waiter),
            monitors: Map.put(auth.monitors, monitor, ref)
        }

        state = %{state | http_auth: auth}
        state |> join_flow() |> update_bound()
    end
  end

  # A late rejection advances the high-water mark, but only the current
  # generation can retire shared credentials. No token history is retained.
  def reject_token(
        %{transport_state: %HTTP{} = transport} = state,
        %{status: 401, credential_generation: generation}
      )
      when is_integer(generation) and generation > 0 do
    %{state | transport_state: HTTP.retire_credential(transport, generation)}
  end

  def reject_token(state, _challenge), do: state

  def refused?({:auth_refused, _reason}), do: true
  def refused?({:oauth_failed, _reason}), do: true
  def refused?({:stream_error, reason}), do: refused?(reason)
  def refused?({:transport_error, reason}), do: refused?(reason)
  def refused?(%{reason: reason, details: details}), do: refused?(reason) or refused?(details)
  def refused?(%{reason: reason}), do: refused?(reason)
  def refused?(%{cause: reason}), do: refused?(reason)
  def refused?(%{details: details}), do: refused?(details)
  def refused?(_reason), do: false

  def cached_token(%HTTP{access_token: current} = transport, challenge)
      when is_binary(current) do
    if transport.credential_generation != Map.get(challenge, :credential_generation, 0) and
         (challenge.status == 401 or scopes_granted?(granted_scopes(transport), challenge.scopes)),
       do: current
  end

  def cached_token(_transport, _challenge), do: nil

  def reply(waiter, {:ok, token}, transport),
    do: reply(waiter, {:ok, token, transport.credential_generation}, transport)

  def reply(%{kind: :post, pid: pid, ref: ref}, {:ok, token, generation}, transport) do
    context = %{
      session_id: transport.session_id,
      headers: transport.headers,
      credential_generation: generation
    }

    send(pid, {:http_post_auth_result, ref, {:ok, token, context}})
  end

  def reply(%{kind: :post, pid: pid, ref: ref}, result, _transport),
    do: send(pid, {:http_post_auth_result, ref, result})

  def reply(%{kind: :stream, pid: pid, ref: ref}, result, _transport),
    do: send(pid, {:modern_http_stream_auth_result, ref, result})

  def result(%{http_auth: %{worker: %{pid: pid, id: id}}} = state, pid, id, result) do
    state = stop_worker(state)

    result =
      case result do
        {:ok, _token, _scopes, generation} ->
          if generation <= state.transport_state.rejected_generation,
            do: {:error, {:oauth_failed, :stale_credential}},
            else: result

        {:error, _reason} ->
          result
      end

    transport =
      case result do
        {:ok, token, scopes, generation} ->
          if generation > state.transport_state.credential_generation and
               covers?(scopes, state.transport_state.granted_scopes) and
               Enum.any?(state.http_auth.waiters, fn {_ref, waiter} -> live?(waiter, state) end) do
            HTTP.put_oauth_token(
              state.transport_state,
              %{access_token: token, scope: Enum.join(scopes, " ")},
              scopes,
              generation
            )
          else
            state.transport_state
          end

        {:error, _reason} ->
          state.transport_state
      end

    %{state | transport_state: transport}
    |> settle_flow(result, id)
    |> update_bound()
  end

  def result(state, _pid, _id, _result), do: state

  def waiter_timeout(state, ref) do
    case Map.get(state.http_auth.waiters, ref) do
      nil ->
        state

      waiter ->
        reply(waiter, {:error, :timeout}, state.transport_state)
        state |> remove_waiter(ref) |> update_bound()
    end
  end

  def worker_timeout(
        %{http_auth: %{worker: %{id: id, deadline: deadline}}} = state,
        id,
        deadline
      ),
      do: state |> stop_worker() |> settle_flow({:error, :timeout}, id) |> update_bound()

  def worker_timeout(state, _id, _deadline), do: state

  def down(%{http_auth: %{worker: %{monitor: ref, id: id}}} = state, ref),
    do:
      state
      |> stop_worker()
      |> settle_flow({:error, {:oauth_failed, :authentication_worker_failed}}, id)
      |> update_bound()

  def down(state, monitor) do
    case Map.get(state.http_auth.monitors, monitor) do
      nil -> state
      ref -> state |> remove_waiter(ref) |> update_bound()
    end
  end

  def cancel_request(state, request_id) do
    state.http_auth.waiters
    |> Enum.filter(fn {_ref, waiter} -> waiter.request_id == request_id end)
    |> Enum.reduce(state, fn {ref, waiter}, acc ->
      reply(waiter, {:error, :stream_retired}, acc.transport_state)
      remove_waiter(acc, ref)
    end)
    |> update_bound()
  end

  def retire(state) do
    state = state |> stop_worker() |> finish_waiters({:error, :client_disconnected})

    state =
      case state.transport_state do
        %HTTP{} = transport -> %{state | transport_state: %{transport | rejected_generation: 0}}
        _other -> state
      end

    %{state | http_auth: %__MODULE__{}}
  end

  defp start_worker(state, challenge) do
    parent = self()
    id = make_ref()
    # Preserve the existing inline auth loop protection for a rejected token.
    # This private snapshot only answers the challenge; it cannot send a POST.
    transport =
      if challenge.status == 401 and is_binary(challenge.token),
        do: %{state.transport_state | access_token: challenge.token},
        else: state.transport_state

    {pid, monitor} =
      ConnectionScope.spawn_monitor(fn ->
        result =
          case HTTP.answer_challenge_inline(transport, challenge) do
            {{:ok, token}, authenticated} ->
              {:ok, token, authenticated.granted_scopes, authenticated.credential_generation}

            {{:error, reason}, _transport} ->
              {:error, reason}
          end

        Lifetime.deliver(parent, {:http_inline_auth_result, self(), id, result})
      end)

    worker = %{
      pid: pid,
      monitor: monitor,
      id: id,
      timer: nil,
      deadline: nil,
      scopes: challenge.scopes,
      rejected_generation: state.transport_state.rejected_generation
    }

    %{state | http_auth: %{state.http_auth | worker: worker}} |> join_flow()
  end

  defp join_flow(%{http_auth: %{worker: nil}} = state), do: state

  defp join_flow(state) do
    worker = state.http_auth.worker

    waiters =
      Map.new(state.http_auth.waiters, fn {ref, waiter} ->
        joined =
          if covers?(worker.scopes, waiter.scopes), do: %{waiter | flow: worker.id}, else: waiter

        {ref, joined}
      end)

    %{state | http_auth: %{state.http_auth | waiters: waiters}}
  end

  defp update_bound(%{http_auth: %{waiters: waiters}} = state) when map_size(waiters) == 0,
    do: stop_worker(state)

  defp update_bound(%{http_auth: %{worker: nil}} = state) do
    state = prune_waiters(state)

    case Enum.min_by(state.http_auth.waiters, fn {_ref, waiter} -> waiter.order end, fn -> nil end) do
      nil -> state
      {_ref, waiter} -> state |> start_worker(waiter.challenge) |> update_bound()
    end
  end

  defp update_bound(state) do
    worker = state.http_auth.worker

    deadlines =
      for {_ref, waiter} <- state.http_auth.waiters, waiter.flow == worker.id, do: waiter.deadline

    case deadlines do
      [] ->
        state |> stop_worker() |> update_bound()

      _ ->
        deadline = Enum.max(deadlines)
        cancel_timer(worker.timer)

        timer =
          Process.send_after(
            self(),
            {:http_auth_worker_timeout, worker.id, deadline},
            Deadline.remaining(deadline)
          )

        %{
          state
          | http_auth: %{state.http_auth | worker: %{worker | deadline: deadline, timer: timer}}
        }
    end
  end

  defp prune_waiters(state) do
    Enum.reduce(state.http_auth.waiters, state, fn {ref, waiter}, acc ->
      if live?(waiter, acc) do
        acc
      else
        reason = if Deadline.expired?(waiter.deadline), do: :timeout, else: :stream_retired
        reply(waiter, {:error, reason}, acc.transport_state)
        remove_waiter(acc, ref)
      end
    end)
  end

  defp stop_worker(%{http_auth: %{worker: nil}} = state), do: state

  defp stop_worker(state) do
    worker = state.http_auth.worker
    cancel_timer(worker.timer)
    Process.demonitor(worker.monitor, [:flush])
    if Process.alive?(worker.pid), do: Process.exit(worker.pid, :kill)
    %{state | http_auth: %{state.http_auth | worker: nil}}
  end

  defp finish_waiters(state, result) do
    Enum.reduce(state.http_auth.waiters, state, fn {ref, waiter}, acc ->
      outcome =
        cond do
          Deadline.expired?(waiter.deadline) -> {:error, :timeout}
          not eligible?(waiter, acc) -> {:error, :stream_retired}
          true -> result
        end

      reply(waiter, outcome, acc.transport_state)
      remove_waiter(acc, ref)
    end)
  end

  defp settle_flow(state, result, id) do
    Enum.reduce(state.http_auth.waiters, state, fn {ref, waiter}, acc ->
      outcome =
        cond do
          Deadline.expired?(waiter.deadline) -> {:error, :timeout}
          not eligible?(waiter, acc) -> {:error, :stream_retired}
          true -> flow_outcome(result, waiter, id)
        end

      case outcome do
        :queued ->
          waiters = Map.put(acc.http_auth.waiters, ref, %{waiter | flow: nil})
          %{acc | http_auth: %{acc.http_auth | waiters: waiters}}

        reply_result ->
          reply(waiter, reply_result, acc.transport_state)
          remove_waiter(acc, ref)
      end
    end)
  end

  defp flow_outcome({:ok, token, granted, generation}, waiter, id) do
    cond do
      covers?(granted, waiter.scopes) -> {:ok, token, generation}
      waiter.flow == id -> {:error, {:oauth_failed, :insufficient_scope}}
      true -> :queued
    end
  end

  defp flow_outcome({:error, _} = error, %{flow: id}, id), do: error
  defp flow_outcome({:error, _}, _waiter, _id), do: :queued

  defp covers?(granted, required), do: Enum.all?(required, &(&1 in granted))

  defp remove_waiter(state, ref) do
    {waiter, waiters} = Map.pop(state.http_auth.waiters, ref)
    cancel_timer(waiter.timer)
    Process.demonitor(waiter.monitor, [:flush])

    %{
      state
      | http_auth: %{
          state.http_auth
          | waiters: waiters,
            monitors: Map.delete(state.http_auth.monitors, waiter.monitor)
        }
    }
  end

  defp live?(waiter, state),
    do: not Deadline.expired?(waiter.deadline) and eligible?(waiter, state)

  defp eligible?(%{kind: :stream, pid: pid, request_id: id}, state),
    do: HTTP.stream_owner?(state.transport_state, id, pid)

  defp eligible?(%{kind: :post, pid: pid, request_id: id}, state) do
    request_alive?(state, id) and
      Enum.any?(state.async_post_tasks, fn {_ref, entry} -> entry == {pid, id} end)
  end

  def request_alive?(_state, nil), do: true

  def request_alive?(state, id),
    do: Map.has_key?(state.pending_requests, id) or Map.get(state, :health_check_id) == id

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: false, info: false)

  defp granted_scopes(%HTTP{auth_provider: nil, granted_scopes: scopes}), do: scopes
  defp granted_scopes(%HTTP{auth_provider_state: %{granted_scopes: scopes}}), do: scopes
  defp granted_scopes(_transport), do: []

  defp scopes_granted?(granted, [_ | _] = scopes) when is_list(granted),
    do: Enum.all?(scopes, &(&1 in granted))

  defp scopes_granted?(_granted, _scopes), do: false
end
