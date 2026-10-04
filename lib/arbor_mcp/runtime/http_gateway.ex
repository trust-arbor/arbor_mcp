defmodule Arbor.MCP.Server.Runtime.HTTPGateway do
  @moduledoc false
  use GenServer
  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    HTTPWriterBinding,
    HTTPWriterRegistry,
    HTTPWriteTicket,
    Initialization,
    OutputController,
    OutputTicket,
    Ref
  }

  @reap_ms 10

  def start_link(opts) do
    with {:ok, pid} <-
           GenServer.start_link(__MODULE__, fn -> opts end,
             timeout: Initialization.remaining(opts[:table])
           ),
         :ok <- Initialization.watch(opts[:table], pid),
         do: {:ok, pid}
  end

  def submit(runtime, binding, message, opts \\ []) do
    with {:ok, runtime} <- Runtime.ref(runtime),
         {:ok, proof} <- HTTPWriterBinding.validate(binding, runtime),
         true <- proof.owner == self(),
         {:ok, gateway} <- address(runtime),
         {:ok, format, dispatch_opts} <- options(opts),
         {:ok, acceptance} <- acceptance(binding, message, gateway),
         retained = %{
           binding: binding,
           format: format,
           dispatch_opts: dispatch_opts,
           acceptance: acceptance,
           socket: self(),
           scope: proof.scope,
           lifecycle_metadata_reserve: :binary.copy(<<0>>, 512)
         },
         result <- publish(runtime, proof, gateway, message, retained) do
      if match?({:error, _}, result) and acceptance,
        do: HTTPWriterRegistry.release(acceptance)

      result
    else
      false -> {:error, :invalid_http_writer}
      error -> error
    end
  end

  defp publish(runtime, proof, gateway, message, retained) do
    with {:ok, route, reservation} <-
           Runtime.reserve_ingress(runtime, message,
             owner: gateway,
             caller: self(),
             reply_to: gateway,
             edge: gateway,
             scope: proof.scope,
             invocation_deadline: proof.deadline,
             dispatch_opts: [http: retained],
             batch?: is_list(message)
           ),
         :ok <-
           Runtime.publish_ingress(
             runtime,
             route,
             reservation,
             {:http, message, retained},
             gateway
           ),
         do: {:ok, reservation.token}
  end

  defp acceptance(binding, message, gateway) do
    if notification_only?(message) do
      case HTTPWriterRegistry.prepare(binding, "",
             owner: gateway,
             release_owner: self(),
             metadata: %{accepted: true}
           ) do
        {:ok, ticket} ->
          case HTTPWriterRegistry.handoff(ticket) do
            :ok ->
              {:ok, ticket}

            error ->
              HTTPWriterRegistry.release(ticket)
              error
          end

        error ->
          error
      end
    else
      {:ok, nil}
    end
  end

  defp notification_only?([_ | _] = members), do: Enum.all?(members, &notification_only?/1)

  defp notification_only?(%{"jsonrpc" => "2.0", "method" => method} = message)
       when is_binary(method),
       do:
         not Map.has_key?(message, "id") and not Map.has_key?(message, "result") and
           not Map.has_key?(message, "error")

  defp notification_only?(_message), do: false

  def address(runtime) do
    case :ets.lookup(Ref.table(runtime), :http_gateway) do
      [{:http_gateway, pid}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :http_gateway_unavailable}

      _missing ->
        {:error, :http_gateway_unavailable}
    end
  rescue
    ArgumentError -> {:error, :http_gateway_unavailable}
  end

  defp options(opts) do
    if Keyword.keyword?(opts) and length(opts) <= 2 and
         Enum.uniq(Keyword.keys(opts)) == Keyword.keys(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:format, :dispatch_opts])) do
      format = Keyword.get(opts, :format, :json)
      dispatch = Keyword.get(opts, :dispatch_opts, [])

      if format in [:json, :sse] and Keyword.keyword?(dispatch),
        do: {:ok, format, dispatch},
        else: {:error, :invalid_http_gateway_options}
    else
      {:error, :invalid_http_gateway_options}
    end
  end

  @impl true
  def format_status(status),
    do: Arbor.MCP.Server.Runtime.Diagnostics.format_status(status, __MODULE__)

  @impl true
  def init(constructor) when is_function(constructor, 0), do: init(constructor.())

  def init(opts) do
    table = Keyword.fetch!(opts, :table)
    :ok = Initialization.watch(table, self())
    :ets.insert(table, {:http_gateway, self()})
    Process.send_after(self(), :reap, @reap_ms)
    {:ok, %{runtime: Ref.new(opts[:supervisor], table), table: table, jobs: %{}}}
  end

  @impl true
  def handle_info(:runtime_ingress_ready, state) do
    :ets.delete(state.table, {:ingress_wakeup, self()})

    pending =
      Admission.pending_ingress(state.table) |> Enum.sort_by(fn {_, item} -> item.sequence end)

    state =
      Enum.reduce(pending, state, fn {token, reservation}, state ->
        if reservation.edge == self() do
          case Admission.checkout(state.table, token) do
            {:ok, _entry, {:http, message, retained}} -> accept(token, message, retained, state)
            _unavailable -> state
          end
        else
          state
        end
      end)

    {:noreply, state}
  end

  def handle_info({:arbor_mcp_runtime, token, {:ok, %{"__runtime_output" => ticket}}}, state) do
    case state.jobs[token] do
      %{batch?: true} ->
        case OutputController.deliver(state.table, token, ticket) do
          :ok -> {:noreply, put_in(state.jobs[token].output?, true)}
          {:error, reason} -> {:noreply, fail(token, reason, state)}
        end

      %{} ->
        case OutputController.deliver(state.table, token, ticket) do
          :ok ->
            {:noreply,
             put_in(
               state.jobs[token].observation,
               HTTPWriteTicket.observation(OutputTicket.http(ticket))
             )}

          {:error, reason} ->
            {:noreply, fail(token, reason, state)}
        end

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:arbor_mcp_step_ready, token}, state), do: {:noreply, advance(token, state)}

  def handle_info({:http_output_settled, token, _result}, state),
    do: {:noreply, finish(token, state)}

  def handle_info({:arbor_mcp_runtime, token, {:error, reason}}, state),
    do: {:noreply, fail(token, reason, state)}

  def handle_info({:arbor_mcp_runtime, _token, :notification}, state), do: {:noreply, state}

  def handle_info(:reap, state) do
    state =
      Enum.reduce(state.jobs, state, fn {token, job}, state ->
        case job.observation && HTTPWriteTicket.observation_status(job.observation) do
          nil ->
            if job.done?, do: finish(token, state), else: state

          result when result in [:pending, :in_flight] ->
            state

          result when result in [:returned, :failed, :uncertain] ->
            finish(token, state)

          _retired ->
            if job.failed? or job.done? or job.socket_down?,
              do: finish(token, state),
              else: fail(token, :handler_timeout, state)
        end
      end)

    Process.send_after(self(), :reap, @reap_ms)
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _socket, _reason}, state) do
    state =
      Enum.reduce(state.jobs, state, fn {token, job}, state ->
        if job.socket_monitor == monitor and not job.notification_only? do
          Runtime.cancel_scope(state.runtime, job.scope)
          HTTPWriterRegistry.retire(job.binding, :writer_down)
          state = put_in(state.jobs[token].socket_down?, true)
          finish(token, state)
        else
          state
        end
      end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp accept(token, message, retained, state) do
    batch? = is_list(message)

    job =
      retained
      |> Map.delete(:lifecycle_metadata_reserve)
      |> Map.merge(%{
        notification_only?: notification_only?(message),
        batch?: batch?,
        remaining: if(batch?, do: message, else: [message]),
        output?: false,
        bound?: false,
        done?: false,
        failed?: false,
        observation: nil,
        socket_monitor: Process.monitor(retained.socket),
        socket_down?: false
      })

    state = put_in(state.jobs[token], job)
    advance(token, state)
  end

  defp advance(token, state) do
    case state.jobs[token] do
      %{done?: true} ->
        finish(token, state)

      %{failed?: true} ->
        state

      %{remaining: []} = job ->
        if job.batch? and job.output? do
          case OutputController.finish(state.table, token) do
            :ok -> capture_observation(token, state)
            {:error, reason} -> fail(token, reason, state)
          end
        else
          finish(token, state)
        end

      %{remaining: [request | rest]} = job ->
        state = put_in(state.jobs[token].remaining, rest)
        dispatch(token, request, job, state)

      nil ->
        state
    end
  end

  defp dispatch(token, request, job, state) do
    if valid_envelope?(request),
      do: dispatch_valid(token, request, job, state),
      else: invalid_member(token, job, state)
  end

  defp valid_envelope?(%{"jsonrpc" => "2.0", "method" => method} = request)
       when is_binary(method) do
    not Map.has_key?(request, "result") and not Map.has_key?(request, "error") and
      (not Map.has_key?(request, "id") or is_binary(request["id"]) or is_integer(request["id"]))
  end

  defp valid_envelope?(_invalid), do: false

  defp invalid_member(token, job, state) do
    invalid = %{"jsonrpc" => "2.0", "id" => nil, "method" => "__invalid_http_request"}

    output = %{
      edge: self(),
      connection: job.binding,
      batch?: job.batch?,
      http: %{binding: job.binding, format: job.format}
    }

    with {:ok, reservation} <- Admission.promote(state.table, token, invalid, kind: :rpc),
         :ok <- bind(job, token, reservation, state),
         :ok <-
           OutputController.edge_result(
             state.table,
             token,
             output,
             Arbor.RPC.JSONRPC.error(nil, -32600, "Invalid Request")
           ) do
      state = put_in(state.jobs[token].bound?, true)
      state = put_in(state.jobs[token].output?, true)
      if job.batch?, do: advance(token, state), else: state
    else
      {:error, reason} -> fail(token, reason, state)
    end
  end

  defp dispatch_valid(token, request, job, state) do
    output = %{
      edge: self(),
      connection: job.binding,
      batch?: job.batch?,
      http: %{binding: job.binding, format: job.format}
    }

    with {:ok, reservation} <- Admission.promote(state.table, token, request, kind: :rpc),
         :ok <- bind(job, token, reservation, state),
         :ok <- publish_acceptance(job),
         {:ok, route} <- Admission.route(state.table) do
      work_opts = [
        runtime: state.runtime,
        dispatch_opts: job.dispatch_opts,
        output: output,
        retain_reservation: true
      ]

      send(route.scheduler, {:submit, route.generation, token, request, work_opts})
      state = put_in(state.jobs[token].bound?, true)
      put_in(state.jobs[token].acceptance, nil)
    else
      {:error, reason} -> fail(token, reason, state)
    end
  end

  defp publish_acceptance(%{acceptance: nil}), do: :ok

  defp publish_acceptance(%{acceptance: ticket}) do
    with :ok <- HTTPWriterRegistry.handoff(ticket), do: HTTPWriterRegistry.publish(ticket)
  end

  defp bind(%{batch?: true, bound?: true, binding: binding}, _token, _reservation, state) do
    case HTTPWriterBinding.validate(binding, state.runtime) do
      {:ok, _proof} -> :ok
      error -> error
    end
  end

  defp bind(%{binding: binding}, token, _reservation, _state),
    do: HTTPWriterRegistry.bind_dispatched(binding, token)

  defp fail(token, reason, state) do
    case state.jobs[token] do
      %{binding: binding} ->
        case HTTPWriterRegistry.in_flight_observation(binding) do
          {:ok, observation} ->
            state
            |> put_in([:jobs, token, :observation], observation)
            |> put_in([:jobs, token, :failed?], true)
            |> put_in([:jobs, token, :done?], true)

          _not_writing ->
            fail_work(token, reason, state)
        end

      _missing ->
        fail_work(token, reason, state)
    end
  end

  defp fail_work(token, reason, state) do
    case state.jobs[token] do
      %{failed?: true} ->
        state

      %{notification_only?: true} ->
        finish(token, state)

      %{binding: binding, format: format} ->
        OutputController.mark_failure(state.table, token, safe_failure(reason))

        case OutputController.http_failure(state.table, token, binding, format) do
          :ok ->
            capture_observation(token, put_in(state.jobs[token].failed?, true))

          _unavailable ->
            OutputController.retire(state.table, token, :http_invocation_failed)
            HTTPWriterRegistry.retire(binding, :http_invocation_failed)
            finish(token, state)
        end

      _missing ->
        finish(token, state)
    end
  end

  defp safe_failure(reason) when reason in [:handler_timeout, :request_cancelled], do: reason
  defp safe_failure(_reason), do: :http_invocation_failed

  defp finish(token, state) do
    case state.jobs[token] do
      %{observation: observation} when not is_nil(observation) ->
        if HTTPWriteTicket.observation_status(observation) in [:pending, :in_flight],
          do: put_in(state.jobs[token].done?, true),
          else: finish_work(token, state)

      _missing ->
        finish_work(token, state)
    end
  end

  defp finish_work(token, state) do
    case Admission.current(state.table, token) do
      {:ok, %{bound: true}} ->
        if state.jobs[token], do: put_in(state.jobs[token].done?, true), else: state

      _settled ->
        if job = state.jobs[token], do: Process.demonitor(job.socket_monitor, [:flush])
        :ets.delete(state.table, {:output_failure, token})
        :ets.delete(state.table, {:output_commit, token})
        Admission.release(state.table, token)
        %{state | jobs: Map.delete(state.jobs, token)}
    end
  end

  defp capture_observation(token, state) do
    case OutputController.http_observation(state.table, token) do
      {:ok, observation} -> put_in(state.jobs[token].observation, observation)
      _settled -> finish(token, state)
    end
  end
end
