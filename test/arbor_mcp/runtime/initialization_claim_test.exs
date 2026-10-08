defmodule Arbor.MCP.Server.RuntimeInitializationClaimTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.Runtime.Internal.Ingress, as: RuntimeIngress

  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    Admission,
    CallbackContext,
    Deadline,
    Initialization,
    Ref,
    Services,
    ServiceStore
  }

  alias Arbor.MCP.SessionManager
  alias Arbor.MCP.SessionManager.{InitializationClaim, RuntimeStore, SessionLease}

  defmodule Handler do
    def init(opts), do: {:ok, %{parent: opts[:parent]}}

    def dispatch(request, _handler, state, _opts) do
      invocation = CallbackContext.current()
      {:ok, sessions} = Runtime.service(invocation.runtime, :sessions)

      {:ok, lease} =
        SessionManager.create_session(sessions, %{}, session_id: request["session_id"])

      claim = SessionManager.claim_initialization(sessions, lease, request["claim_opts"] || [])
      send(state.parent, {:claimed, self(), claim, sessions, lease, invocation})

      if request["deferred_claim"] do
        parent = state.parent

        deferred =
          spawn(fn ->
            CallbackContext.with_context(invocation, fn ->
              receive do
                {:attempt_claim, fresh_lease} ->
                  send(
                    parent,
                    {:deferred_claim, self(),
                     SessionManager.claim_initialization(sessions, fresh_lease, [])}
                  )
              end
            end)
          end)

        send(parent, {:deferred_callback, deferred})
      end

      receive do
        :finish_without_initialization ->
          :ok

        {:complete, opts} ->
          result =
            case claim do
              {:ok, claim} ->
                SessionManager.complete_initialization(sessions, claim, "2025-06-18", opts)

              error ->
                error
            end

          send(state.parent, {:completed, self(), result})
      end

      {:response, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => "finished"}, state}
    end
  end

  defmodule HeldMaintenanceStore do
    def start_link(opts), do: ServiceStore.start_link(__MODULE__, opts)
    def runtime_service_capabilities, do: RuntimeStore.runtime_service_capabilities()

    def runtime_service_binding(server, timeout),
      do: RuntimeStore.runtime_service_binding(server, timeout)

    def operate(operation, args, context, opts),
      do: RuntimeStore.operate(operation, args, context, opts)

    def lease_active?(id, epoch, opts), do: RuntimeStore.lease_active?(id, epoch, opts)
    def open(opts), do: RuntimeStore.open(opts)
    def read_address(model), do: RuntimeStore.read_address(model)

    def apply(operation, args, context, model),
      do: RuntimeStore.apply(operation, args, context, model)

    def expire(model, _deadline), do: model
    def info(message, model), do: RuntimeStore.info(message, model)
    def close(model), do: RuntimeStore.close(model)
  end

  test "a callback completes initialization beyond the default one-second store wait" do
    root = runtime()
    {token, worker, claim, sessions, lease, invocation} = claim(root)
    {:ok, _key, _token, owner, cutoff} = InitializationClaim.validate(claim, sessions)
    assert owner == self()
    assert cutoff == invocation.deadline
    Process.sleep(1_050)
    assert {:ok, _key, _token, ^owner, ^cutoff} = InitializationClaim.validate(claim, sessions)
    send(worker, {:complete, []})
    assert_receive {:completed, ^worker, :ok}, 1_000
    assert {:ok, %{"result" => "finished"}} = Runtime.await(token, 1_000)

    assert {:ok, _lease} =
             SessionManager.ensure_initialized_session(sessions, SessionLease.id(lease), %{}, [])
  end

  test "a short operation timeout does not shorten or renew the invocation claim" do
    root = runtime(session_options: [operation_timeout_ms: 100])
    {token, worker, claim, sessions, lease, invocation} = claim(root, timeout: 100)
    Process.sleep(150)
    assert {:ok, _key, _token, _owner, cutoff} = InitializationClaim.validate(claim, sessions)
    assert cutoff == invocation.deadline
    send(worker, {:complete, timeout: 100})
    assert_receive {:completed, ^worker, :ok}, 1_000
    assert {:ok, _response} = Runtime.await(token, 1_000)
    assert {:ok, %{initialized: true}} = SessionManager.get_session(sessions, lease, [])
  end

  test "a failed short completion wait leaves the original claim available for retry" do
    root = runtime()
    {token, worker, claim, sessions, lease, _invocation} = claim(root)
    {:ok, binding} = Services.resolve(sessions, :sessions)
    :sys.suspend(binding.server)
    on_exit(fn -> safe_resume(binding.server) end)

    task =
      Task.async(fn ->
        SessionManager.complete_initialization(sessions, claim, "2025-06-18", timeout: 50)
      end)

    assert {:error, :operation_timeout} = Task.await(task)
    :sys.resume(binding.server)
    assert {:ok, %{initialized: false}} = SessionManager.get_session(sessions, lease, [])
    send(worker, {:complete, []})
    assert_receive {:completed, ^worker, :ok}, 1_000
    assert {:ok, _response} = Runtime.await(token, 1_000)
    assert {:ok, %{initialized: true}} = SessionManager.get_session(sessions, lease, [])
  end

  test "a shorter caller cutoff is preserved during completion and cannot commit" do
    root = runtime()
    {token, worker, claim, sessions, lease, _invocation} = claim(root)

    assert {:error, :operation_timeout} =
             SessionManager.complete_initialization(sessions, claim, "2025-06-18",
               deadline: Deadline.now() - 1
             )

    assert {:error, :invalid_operation_deadline} =
             SessionManager.complete_initialization(sessions, claim, "2025-06-18", deadline: nil)

    assert {:ok, %{initialized: false}} = SessionManager.get_session(sessions, lease, [])
    send(worker, {:complete, []})
    assert_receive {:completed, ^worker, :ok}, 1_000
    assert {:ok, _response} = Runtime.await(token, 1_000)
  end

  test "cancellation retires the captured session epoch and cannot affect its replacement" do
    root = runtime(cancel_grace_ms: 1_000)
    {token, worker, claim, sessions, lease, invocation} = claim(root)
    assert :ok = Runtime.cancel(root, invocation.scope, request_id(root, token))

    assert {:error, %{"error" => %{"data" => %{"type" => "request_cancelled"}}}} =
             Runtime.await(token, 1_000)

    eventually(fn ->
      SessionManager.ensure_session(sessions, SessionLease.id(lease), %{}, []) ==
        {:error, :session_not_found}
    end)

    {:ok, replacement} =
      SessionManager.create_session(sessions, %{}, session_id: SessionLease.id(lease))

    refute replacement == lease

    assert {:error, :stale_session_lease} =
             SessionManager.complete_initialization(sessions, claim, "2025-06-18", [])

    send(worker, {:complete, []})
    assert_receive {:completed, ^worker, {:error, _retired}}, 1_000
    assert {:ok, %{initialized: false}} = SessionManager.get_session(sessions, replacement, [])
  end

  test "explicit claim deadline can shorten the original invocation but a future integer cannot extend it" do
    root = runtime()
    short = Deadline.now() + 150
    {token, worker, claim, sessions, lease, _invocation} = claim(root, deadline: short)
    assert {:ok, _key, _token, _owner, ^short} = InitializationClaim.validate(claim, sessions)
    sleep_until(short + 20)
    assert {:error, :stale_initialization_claim} = InitializationClaim.validate(claim, sessions)
    send(worker, {:complete, []})
    assert_receive {:completed, ^worker, {:error, _expired}}, 1_000
    assert {:ok, _response} = Runtime.await(token, 1_000)
    assert {:error, _expired} = SessionManager.get_session(sessions, lease, [])

    {_token, _worker, claim, sessions, _lease, invocation} =
      claim(root, deadline: Deadline.now() + 60_000, session_id: "future")

    assert {:ok, _key, _token, _owner, cutoff} = InitializationClaim.validate(claim, sessions)
    assert cutoff == invocation.deadline
  end

  test "the original request cutoff revokes a claim even while its owner stays alive" do
    root = runtime(cancel_grace_ms: 1_000)
    {token, worker, claim, sessions, lease, invocation} = claim(root, request_timeout: 150)
    sleep_until(invocation.deadline + 10)
    assert {:error, _expired_request} = Runtime.await(token, 1_000)
    assert Process.alive?(self())
    assert {:error, :stale_initialization_claim} = InitializationClaim.validate(claim, sessions)
    send(worker, {:complete, []})
    assert_receive {:completed, ^worker, {:error, _expired_claim}}, 1_000
    assert {:error, _retired_lease} = SessionManager.get_session(sessions, lease, [])
    refute_receive {:arbor_mcp_runtime, ^token, _late_success}, 20
  end

  test "a borrowed backend cannot expose or complete a retired cohort's retained claim" do
    external =
      start_supervised!(%{id: :borrowed_claims, start: {HeldMaintenanceStore, :start_link, [[]]}})

    descriptor = [
      ownership: :borrowed,
      adapter: HeldMaintenanceStore,
      server: external,
      namespace: "claim-cohort"
    ]

    root = runtime(session_descriptor: descriptor)
    {token, _worker, claim, sessions, lease, _invocation} = claim(root)
    {:ok, runtime_ref} = Runtime.ref(root)
    table = Ref.table(runtime_ref)
    [{:services_generation, old_generation, stores}] = :ets.lookup(table, :services_generation)
    Process.exit(stores, :kill)
    assert {:error, _restarted} = Runtime.await(token, 1_000)

    eventually(fn ->
      match?(
        [{:services_generation, generation, _}] when generation != old_generation,
        :ets.lookup(table, :services_generation)
      ) and Initialization.ready?(table)
    end)

    assert Process.alive?(external)

    assert {:error, :session_not_found} =
             SessionManager.ensure_session(sessions, SessionLease.id(lease), %{}, [])

    assert {:error, :stale_session_lease} =
             SessionManager.complete_initialization(sessions, claim, "2025-06-18", [])

    {:ok, replacement} =
      SessionManager.create_session(sessions, %{}, session_id: SessionLease.id(lease))

    refute replacement == lease
    assert {:ok, %{initialized: false}} = SessionManager.get_session(sessions, replacement, [])
  end

  test "claim creation rejects an owner that differs from the actual invocation owner" do
    root = runtime()
    other = spawn(fn -> receive do: (:finish -> :ok) end)
    on_exit(fn -> Process.exit(other, :kill) end)
    {token, worker, result, _sessions, _lease, _invocation} = claim_result(root, owner: other)
    assert {:error, :invalid_initialization_owner_or_origin} = result
    send(worker, {:complete, []})
    assert_receive {:completed, ^worker, ^result}, 1_000
    assert {:ok, _response} = Runtime.await(token, 1_000)
  end

  test "outside-callback claims retain their finite operation cutoff without future-integer extension" do
    root = runtime(session_options: [operation_timeout_ms: 100])
    {:ok, sessions} = Runtime.service(root, :sessions)
    {:ok, lease} = SessionManager.create_session(sessions, %{}, [])
    started = Deadline.now()

    {:ok, claim} =
      SessionManager.claim_initialization(sessions, lease, deadline: started + 60_000)

    returned = Deadline.now()
    assert {:ok, _key, _token, _owner, cutoff} = InitializationClaim.validate(claim, sessions)
    assert cutoff <= returned + 100
    sleep_until(cutoff + 10)
    assert {:error, :stale_initialization_claim} = InitializationClaim.validate(claim, sessions)
  end

  test "a retired member's deferred callback cannot claim under the next batch member" do
    root = runtime(cancel_grace_ms: 1_000)
    first = claim_request(7, "retired", deferred_claim: true)
    second = claim_request(8, "current")
    {:ok, runtime_ref} = Runtime.ref(root)
    table = Ref.table(runtime_ref)

    {:ok, _route, envelope} =
      RuntimeIngress.reserve_ingress(root, [first, second],
        scope: :claim_batch,
        owner: self()
      )

    assert {:ok, token} =
             RuntimeIngress.dispatch_reserved(
               root,
               envelope.token,
               first,
               retain_reservation: true
             )

    assert_receive {:claimed, prior, {:ok, old_claim}, sessions, old_lease, _origin}, 1_000
    assert_receive {:deferred_callback, deferred}, 1_000
    on_exit(fn -> Process.exit(deferred, :kill) end)
    assert :ok = Runtime.cancel(root, :claim_batch, 7)
    assert {:error, _cancelled} = Runtime.await(token, 1_000)
    send(prior, :finish_without_initialization)
    assert_receive {:arbor_mcp_step_ready, ^token}, 1_000

    assert {:ok, ^token} =
             RuntimeIngress.dispatch_reserved(root, token, second, retain_reservation: true)

    assert_receive {:claimed, current, {:ok, _claim}, _sessions, _lease, current_origin}, 1_000
    assert {:ok, current_row} = Admission.current(table, token)
    assert current_row.output_phase == current_origin.output_phase
    {:ok, fresh_lease} = SessionManager.create_session(sessions, %{}, session_id: "deferred")
    send(deferred, {:attempt_claim, fresh_lease})

    assert_receive {:deferred_claim, ^deferred,
                    {:error, :invalid_initialization_owner_or_origin}},
                   1_000

    assert {:error, _retired} =
             SessionManager.complete_initialization(sessions, old_claim, "2025-06-18", [])

    assert {:error, _retired} = SessionManager.get_session(sessions, old_lease, [])
    send(current, {:complete, []})
    assert_receive {:completed, ^current, :ok}, 1_000
    assert {:ok, _response} = Runtime.await(token, 1_000)
    assert_receive {:arbor_mcp_step_ready, ^token}, 1_000
    assert :ok = RuntimeIngress.discard_ingress(root, token)
  end

  test "completed success keeps its original claim valid after callback exit and later member cancellation" do
    root = runtime(cancel_grace_ms: 1_000)
    first = claim_request(7, "completed")
    second = claim_request(7, "later")

    {:ok, _route, envelope} =
      RuntimeIngress.reserve_ingress(root, [first, second],
        scope: :success_batch,
        owner: self()
      )

    assert {:ok, token} =
             RuntimeIngress.dispatch_reserved(
               root,
               envelope.token,
               first,
               retain_reservation: true
             )

    assert_receive {:claimed, prior, {:ok, claim}, sessions, lease, _origin}, 1_000
    monitor = Process.monitor(prior)
    send(prior, :finish_without_initialization)
    assert {:ok, _response} = Runtime.await(token, 1_000)
    assert_receive {:DOWN, ^monitor, :process, ^prior, :normal}, 1_000
    assert_receive {:arbor_mcp_step_ready, ^token}, 1_000

    assert {:ok, ^token} =
             RuntimeIngress.dispatch_reserved(root, token, second, retain_reservation: true)

    assert_receive {:claimed, current, {:ok, _later_claim}, _sessions, _lease, _origin}, 1_000
    assert :ok = Runtime.cancel(root, :success_batch, 7)
    assert {:error, _cancelled} = Runtime.await(token, 1_000)
    assert :ok = SessionManager.complete_initialization(sessions, claim, "2025-06-18", [])
    assert {:ok, %{initialized: true}} = SessionManager.get_session(sessions, lease, [])
    send(current, :finish_without_initialization)
    assert_receive {:arbor_mcp_step_ready, ^token}, 1_000
    assert :ok = RuntimeIngress.discard_ingress(root, token)
  end

  defp claim_request(id, session_id, opts \\ []) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "claim",
      "session_id" => session_id,
      "deferred_claim" => opts[:deferred_claim]
    }
  end

  defp claim(root, opts \\ []) do
    {token, worker, {:ok, claim}, sessions, lease, invocation} = claim_result(root, opts)
    {token, worker, claim, sessions, lease, invocation}
  end

  defp claim_result(root, opts) do
    {id, opts} = Keyword.pop(opts, :session_id, "initializing")
    {timeout, opts} = Keyword.pop(opts, :request_timeout, 3_000)

    request = %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => "claim",
      "session_id" => id,
      "claim_opts" => opts
    }

    {:ok, token} = Runtime.submit(root, request, timeout: timeout)
    assert_receive {:claimed, worker, claim, sessions, lease, invocation}, 1_000
    {token, worker, claim, sessions, lease, invocation}
  end

  defp request_id(root, token) do
    {:ok, runtime} = Runtime.ref(root)
    {:ok, reservation} = Admission.current(Ref.table(runtime), token)
    reservation.request_id
  end

  defp runtime(opts \\ []) do
    {session_options, opts} = Keyword.pop(opts, :session_options, [])
    {descriptor, opts} = Keyword.pop(opts, :session_descriptor, options: session_options)

    start_supervised!(
      {Runtime,
       [
         handler: Handler,
         handler_args: [parent: self()],
         dispatcher: Handler,
         services: [sessions: descriptor]
       ] ++ opts}
    )
  end

  defp sleep_until(cutoff), do: Process.sleep(max(0, cutoff - Deadline.now()))

  defp safe_resume(pid) do
    if Process.alive?(pid), do: :sys.resume(pid)
  catch
    :exit, _reason -> :ok
  end

  defp eventually(predicate, attempts \\ 100)
  defp eventually(_predicate, 0), do: flunk("initialization claim did not retire")

  defp eventually(predicate, attempts) do
    if predicate.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(predicate, attempts - 1)
        )
  end
end
