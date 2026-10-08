# Mounted runtime HTTP POST and request SSE

This candidate adds mounted JSON POST and request-owned SSE to the same initialized handler, Admission and Scheduler used by the other runtime transports. It is an isolated overlay on `8ffa713` plus the qualified HTTP writer installation slice. It is not the completed HTTP release gate.

## Mount and request context

Start a single runtime in the application's supervision tree, then mount the plug with its root name, PID or logical reference:

```elixir
children = [
  {Arbor.MCP.Server.HandlerServer,
   handler: MyHandler,
   name: MyMCPRuntime,
   handler_args: [catalog: MyCatalog],
   services: [sessions: [], replay_cache: []]}
]

# Phoenix router or another borrowed Plug host:
forward "/mcp", Arbor.MCP.HttpPlug,
  runtime: MyMCPRuntime,
  handler_opts: fn conn, request ->
    %{principal: conn.assigns.principal, request_id: request["id"]}
  end
```

`handler_args` initializes the handler once. Previously, the HTTP handler option mapper supplied arguments to a new handler's `init/1` for each POST. On a mounted runtime its static, function or MFA result becomes `Arbor.MCP.Server.Context.current().application_context` for that invocation. It does not mutate request params or initialize another handler. The result is charged as native dispatch metadata before publication. Configured host functions remain host-owned; the library neither adopts nor kills their processes.

## Admission and physical output

The actual Plug process captures an authenticated writer binding and original cutoff at entry, before body, authentication, protocol-era or option-mapper work. Body reads use its remaining budget. Later checks cannot extend it. Upstream-parsed JSON uses the native bounded plain-JSON codec; it cannot invoke application JSON encoders. Private `:invocation_deadline` is a signed-64-bit shortening option on Admission, distinct from the admission confirmation and caller wait budgets.

The root-installed Gateway owns accepted work and publishes only token wakeups. The socket process owns physical IO. A response reserves both the primary decoded/wire output and its complete HTTP IO companion before handler-state commit, then publishes after commit. Notifications use the same charged path. A queued read-only peek allows session initialization settlement before IO starts; it grants neither checkout nor ACK authority. The actual Plug process checks out the exact prepared frame immediately before calling its adapter.

Physical completion means the actual `Plug.Conn.send_resp/3`, `send_chunked/2` or `chunk/2` returned. It does not mean the remote client received the frame. The primary output is ACKed only after that return. Failures after state commit never replay callbacks or roll state back. Socket death cancels only its accepted response scope. Notification-only `202` is pre-admitted before callbacks and admitted notification work is Gateway-owned. Continuation of every notification-array member after the socket's early return remains a separate qualification gate.

Legacy arrays retain one work permit per member, including notifications and invalid elements. They reserve prospective complete-array IO bytes while callbacks execute, omit notification responses and preserve response order. A distinct final aggregate identity is installed only after every response member's precommit output and state outcome succeeds. An early successful member cannot authorize a later failed array. A failed array produces one fixed terminal error, never a partial array or retry of prior committed members. Modern arrays remain rejected before callbacks.

## Lifetime and bounds

Defaults retain independent primary output and IO budgets of 4 MiB each, 128 physical frames and 128 writer bindings, plus 64 KiB writer metadata. Their sum is the conservative aggregate bound; `max_output_bytes` alone does not bound HTTP output. IO charges include retained bytes and bounded opaque handle copies. Each input includes a 512-byte lifecycle metadata reserve, and companion handles conservatively charge four copies including the Gateway's read-only completion view. The frame budgets cover prepared response bodies and SSE data frames; HTTP headers, adapter framing and socket buffers remain host or adapter memory. Whole-row CAS operations create transient copies; these limits do not bound total producer, VM, Plug adapter or OS socket memory.

The unlinked IO guardian survives logical scope expiry, execution replacement and root stop. A checked-out borrowed write retains its original charge until the actual writer returns or its monitored process dies. No deadline, reset or replacement root can reclaim that IO credit early. A read-only completion observation allows Gateway bookkeeping to settle even after its logical output scope is gone. Unknown guardian state is explicitly unconfirmed. Sequential calls on one PID can reclaim only IO whose actual receipt is already recorded; an outstanding coalesced wake nonce survives binding reuse.

Once response or notification IO starts, a later failure preserves that original in-flight observation and prepares no replacement terminal write. Logical step completion and expiry retain the bounded Gateway bookkeeping until the actual return or writer death. Queued output remains distinct and may be replaced by the single failure-only frame before physical IO starts.

One Controller-authenticated fixed terminal error may use a failure-only tail captured at entry: original cutoff plus the finite output timeout. It cannot publish success, renew work/store authority or retry physical IO. If the terminal frame cannot be admitted, or initial binding admission fails, the plug raises the fixed host-facing `RuntimeWriter.AdmissionError` before any library socket write. The host owns its exception-response policy; the library does not promise an uncharged `503`.

## Implemented and pending behavior

Implemented in this slice: shared handler state across mounted POSTs; modern stateless JSON and request SSE; progress/log/final ordering; root-addressed legacy initialize/version/session claims and complete arrays; original-cutoff request context; charged validation responses; actual adapter-return ACK; pressure rejection before state commit; borrowed host survival; and logical versus physical completion cleanup.

Mounted legacy GET/DELETE currently return a charged `501` to prevent fallback to global session registries. The next HTTP routing slice must implement addressed session GET/disconnect/reconnect, deletion with final-mutation and physical output proof, event replay/Last-Event-ID, deprecated HTTP+SSE endpoint behavior and modern subscription sources. Cross-session cancellation, MRTR/replay retained conformance, API replacement/removal qualification, standalone listener runtime ownership, and the full default runtime-mounted plug contract remain release gates. The old unmounted compatibility route still initializes a handler per POST and must be retired or explicitly migrated before v2 release. No global Logger settings change in this slice.

## Qualification

Qualification uses private dependency source copies and builds with no global test helper. The 40-case focused/wire selection passed on Elixir 1.19.5 / OTP 28.4.1 and Elixir 1.17.3 / OTP 27.0.1. It includes actual random-loopback Cowboy JSON, request SSE, legacy initialization/array, overload and borrowed-listener checks, plus deterministic producer/owner, paused Admission, aggregate, notification-timeout and late IO interleavings. The final source's 35 pure cases, warnings-as-errors compilation and full formatting pass on both supported toolchains and Elixir 1.20.3 / OTP 29.0.5. Strict Credo and ExDoc pass on the current toolchain. Normal Dialyzer passes with the unchanged 73 current / 67 minimum filters; independent raw audits find zero warnings in the 26 owned paths. The two final cross-formatter helper changes preserve behavior and are covered by the final pure and static runs.

Writer core/installation checks pass 41 cases on each supported toolchain. A separate test-only topology overlay makes the retained 84-case runtime/startup/claim/deadline selection pass on each: it compares the stable initial live proof count with each replacement, rather than assuming a fixed child count. That fixture overlay is delivered separately from the 26-path Gateway source overlay. Combined canonical qualification remains required after merging the current guard, privacy, stdio and native-client overlays. Mounted GET/replay/subscriptions and the other release gates above are outside these passed selections.
