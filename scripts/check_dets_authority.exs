for path <- [
      "lib/arbor_mcp/runtime/diagnostics.ex",
      "lib/arbor_mcp/internal/session_store.ex",
      "lib/arbor_mcp/internal/session_store/dets/claim_ingress.ex",
      "lib/arbor_mcp/internal/session_store/dets/path_claims.ex",
      "lib/arbor_mcp/internal/session_store/dets/raw.ex",
      "lib/arbor_mcp/internal/session_store/dets/owner.ex",
      "lib/arbor_mcp/internal/session_store/dets/error.ex",
      "lib/arbor_mcp/internal/session_store/dets.ex"
    ],
    do: Code.compile_file(path)

alias Arbor.MCP.Internal.SessionStore.DETS
alias Arbor.MCP.Internal.SessionStore.DETS.PathClaims

wait = fn predicate ->
  Enum.reduce_while(1..200, nil, fn _, _ ->
    if predicate.(),
      do: {:halt, :ok},
      else:
        (
          Process.sleep(5)
          {:cont, nil}
        )
  end) || raise "condition did not settle"
end

path = Path.join(System.tmp_dir!(), "arbor-dets-authority-#{System.unique_integer([:positive])}")
{:ok, claims} = PathClaims.start_link(max_stores: 1)
{:ok, store} = DETS.open(%{storage_path: path})
{:error, :storage_claim_limit} = DETS.open(%{storage_path: path <> "-other"})
false = File.exists?(path <> "-other")
:ok = DETS.close(store)
:ok = GenServer.stop(claims)
{:ok, claims} = PathClaims.start_link(max_stores: 1)
{:ok, store} = DETS.open(%{storage_path: path})
:ok = DETS.close(store)
:ok = GenServer.stop(claims)
IO.puts("bounded admission and confirmed clean authority restart passed")

{:ok, claims} = PathClaims.start_link([])
parent = self()
:erlang.suspend_process(claims)

spawn(fn ->
  send(
    parent,
    {:late_claim, DETS.open(%{storage_path: path <> "-late-claim", storage_io_timeout_ms: 30})}
  )
end)

receive do
  {:late_claim, {:error, :storage_io_timeout}} -> :ok
after
  1_000 -> raise "claim timeout failed"
end

:erlang.resume_process(claims)
wait.(fn -> map_size(:sys.get_state(claims).claims) == 0 end)
false = File.exists?(path <> "-late-claim")
IO.puts("expired suspended authority request cannot register late ownership or start I/O")

route = :persistent_term.get({PathClaims, :identity})
:erlang.suspend_process(claims)
large = :binary.copy("padding", 300_000) <> path <> "-pressure"

pressure_path =
  binary_part(
    large,
    byte_size(large) - byte_size(path <> "-pressure"),
    byte_size(path <> "-pressure")
  )

for _ <- 1..160 do
  spawn(fn ->
    send(
      parent,
      {:pressure, DETS.open(%{storage_path: pressure_path, storage_io_timeout_ms: 500})}
    )
  end)
end

results =
  for _ <- 1..160 do
    receive do
      {:pressure, result} -> result
    after
      2_000 -> raise "pressure caller retained"
    end
  end

true = Enum.any?(results, &(&1 == {:error, :storage_claim_overloaded}))

rows =
  for {_slot, {phase, data}} <- :ets.tab2list(route.table),
      phase in [:reserved, :abandoned],
      do: data

128 = length(rows)

true =
  Enum.all?(rows, fn data ->
    byte_size(data.path) <= 4_096 and
      :binary.referenced_byte_size(data.path) == byte_size(data.path)
  end)

{:messages, messages} = Process.info(claims, :messages)
true = length(messages) <= 2

true =
  Enum.all?(messages, fn
    {:claim_ready, token} -> token == route.token
    :claim_tick -> true
    _payload -> false
  end)

false = File.exists?(pressure_path)
:erlang.resume_process(claims)
wait.(fn -> not Arbor.MCP.Internal.SessionStore.DETS.ClaimIngress.pending?(route) end)

IO.puts(
  "128 detached bounded controls retain credit under pressure with token-only coalesced mailbox"
)

server = Process.whereis(:dets)
:erlang.suspend_process(server)

spawn(fn ->
  send(
    parent,
    {:late_open, DETS.open(%{storage_path: path <> "-late-open", storage_io_timeout_ms: 30})}
  )
end)

receive do
  {:late_open, {:error, :storage_io_timeout}} -> :ok
after
  1_000 -> raise "open timeout failed"
end

{:error, :storage_io_timeout} =
  DETS.open(%{storage_path: path <> "-late-open", storage_io_timeout_ms: 30})

:erlang.resume_process(server)
wait.(fn -> map_size(:sys.get_state(claims).claims) == 0 end)

for file <- ["sessions.dets", "events.dets", "request_ids.dets", "meta.dets"] do
  false = File.exists?(Path.join(path <> "-late-open", file))
end

File.rm_rf!(path <> "-late-open")
IO.puts("blocked open remains exclusive and cannot begin new tables after its cutoff")

{:ok, store} = DETS.open(%{storage_path: path})
owner = store.owner
Process.exit(owner, :kill)
wait.(fn -> :atomics.get(store.gate, 1) == 4 end)
{:error, :storage_cleanup_unconfirmed} = DETS.close(store)
{:error, :storage_cleanup_unconfirmed} = DETS.open(%{storage_path: path})
wait.(fn -> Enum.all?(store.names, &(:dets.info(&1, :owner) == :undefined)) end)
IO.puts("abrupt private Owner loss remains quarantined without claiming cleanup")

Process.unlink(claims)
Process.exit(claims, :kill)
wait.(fn -> not Process.alive?(claims) end)
Process.flag(:trap_exit, true)
{:error, :storage_claims_identity_lost} = PathClaims.start_link([])
{:error, :storage_claims_unavailable} = DETS.open(%{storage_path: path})
File.rm_rf!(path)
IO.puts("abrupt authority loss is fail-closed until VM restart")
