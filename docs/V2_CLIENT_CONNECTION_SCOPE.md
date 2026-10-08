# Client connection brackets

> **Implementation history.** This page records the connection-bracket implementation checkpoint. The later
> [ordinary client lifetime work](V2_ORDINARY_CLIENT_LIFETIME.md) covers ordinary
> client shutdown; the final paragraph below describes the earlier checkpoint,
> not an outstanding implementation task. Start with the
> [current migration guide](guides/MIGRATING_V1_TO_V2.md) for application changes.

`Arbor.MCP.Client.with_connection(spec, opts, callback)` constructs one new client,
runs the callback in the original caller, and performs bounded cleanup before
returning. The two-argument form uses default options. Existing client PIDs are
rejected; servers, mock backends and listeners in connection specs remain borrowed.

```elixir
Client.with_connection({:beam, server: runtime}, fn client ->
  Client.list_tools(client)
end)
```

A confirmed cleanup returns `{:ok, value}`. An unsuccessful or unconfirmed cleanup
returns `{:error, {:cleanup_failed, reason, value}}`. A failed connection prevents
callback invocation. If its cleanup is also unconfirmed, the result is
`{:error, {:connection_cleanup_failed, connection_error, cleanup_reason}}`.
Exceptions, throws and exits raised by the callback retain their reason and stack
after cleanup; cleanup failure in that path emits a bounded telemetry event without
callback values or credentials. Killing the caller triggers independent cleanup.

The client has an unlinked guardian as its actual native OTP parent. The caller
never adopts an existing client and is not linked to the new client. A separate
observer monitors the caller and remains responsive during blocked transport init,
handler callbacks and close. The observer records the native client before transport
effects and tracks explicitly registered owned workers. Watchdogs stop those workers
if their owner or observer dies. Unrelated links and borrowed processes are untouched.

`establish_timeout` (12,000 milliseconds by default) covers the native constructor
and all initial handshake attempts with one absolute cutoff. A caller suspended
through queued startup success cannot invoke the callback after that cutoff.
`cleanup_timeout` (1,000 milliseconds by default) uses one new cutoff across
disconnect, native stop, owned-worker termination and proof collection. Both options
must be positive finite milliseconds up to 2,147,483,647. Names are limited to local
atoms, avoiding arbitrary caller-side name lookup callbacks. Callback duration itself
has no helper timeout.

`max_scope_workers` defaults to 256. It bounds registered handshake/pull receivers, reverse/MRTR callbacks,
resource-replacement work, async HTTP POSTs, stream actors and their socket workers.
Each owned process has a small watchdog; one additional proof collector exists only
during cleanup. The observer retains at most 32 transport proofs and 32 cleanup
failure observations. Exceeding those limits fails explicitly before further worker
effects, or reports uncertain transport cleanup if a new transport cannot be recorded.
These limits describe the helper's owned metadata and workers, not a hard bound on
arbitrary user messages or callback-created work.

A stdio child requires its retained typed ArborRPC cleanup receipt. Client/actor
PID death alone does not prove child reaping. Direct-child and targeted-group
outcomes retain the RPC receipt's exact scope; arbitrary descendant trees are not
claimed contained. A receipt that cannot be collected before the original cleanup
cutoff yields an explicit uncertain result, while the RPC guardian can continue its
independent cleanup attempt.

HTTP cleanup distinguishes local ownership from remote effects. Registered stream
and socket workers stop before local cleanup succeeds; shared listeners and HTTP
profile services remain borrowed. Legacy DELETE is currently best effort and cannot
prove remote session termination, even when it receives 204, so a legacy session
returns `remote_session_cleanup_unconfirmed`. Cancellation never promises rollback
of a remote request that was already written.

Custom transport effects that remain unregistered are outside this contract. A
blocked constructor without a recorded transport reports uncertain cleanup rather
than treating native client death as success. The new scope hooks preserve ordinary
`Client.connect/start_link/disconnect/stop` behavior. In particular, ordinary client
stop still needs a separate release audit for previously unlinked reverse/MRTR and
resource/HTTP work; this helper does not extend its ownership claim to those calls.
