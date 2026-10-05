alias Arbor.MCP.Internal.SessionStore.DETS.PathClaims
alias Arbor.MCP.SessionManager

{:ok, _apps} = Application.ensure_all_started(:arbor_mcp)
path = Path.join(System.tmp_dir!(), "arbor-dets-app-#{System.unique_integer([:positive])}")

{:ok, manager} =
  DynamicSupervisor.start_child(
    Arbor.MCP.DynamicSupervisor,
    {SessionManager, [name: nil, storage_backend: :dets, storage_path: path]}
  )

id = GenServer.call(manager, {:create_session, %{transport: :sse}})
store = :sys.get_state(manager).store
workers = Enum.map(store.names, &:dets.info(&1, :owner))
:ok = Application.stop(:arbor_mcp)
false = Process.alive?(manager)
false = Process.alive?(store.owner)
true = Enum.all?(workers, &(not Process.alive?(&1)))
nil = :persistent_term.get({PathClaims, :identity}, nil)
{:ok, _apps} = Application.ensure_all_started(:arbor_mcp)

{:ok, reopened} =
  DynamicSupervisor.start_child(
    Arbor.MCP.DynamicSupervisor,
    {SessionManager, [name: nil, storage_backend: :dets, storage_path: path]}
  )

{:ok, %{id: ^id}} = GenServer.call(reopened, {:get_session, id})
:ok = Application.stop(:arbor_mcp)
File.rm_rf!(path)

IO.puts(
  "actual application owned durable store stop/start preserved rows and confirmed four-table cleanup"
)
