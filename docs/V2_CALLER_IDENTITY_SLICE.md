# Scheduled custom-call caller identity

The v2 Test/BEAM runtime preserves the original caller PID for custom
`handle_call/3` callbacks submitted through `Arbor.MCP.Server.call/2,3`.
The callback still executes in a supervised task: its `self()` is the worker,
not the caller, protocol edge, scheduler or runtime root.

The `from` tuple is `{original_caller_pid, proxy_reply_tag}`. The tag is opaque
and addresses an alias owned by the callback task. `GenServer.reply/2` to this
tag cannot settle the original caller's request, inject a premature reply into
its mailbox, or bypass the scheduler's state commit. The alias is retired when
the callback returns or raises. Saved tags cannot deliver late replies to the
original caller. Admission validates the caller as a local PID; direct custom
calls to the diagnostic edge preserve their caller PID too, but do not acquire
the supported pre-mailbox admission guarantees of `Server.call/2,3`.

Custom calls return `{:reply, reply, next_state}`. Deferred replies,
continuations and process-stop return forms remain unsupported. A finite
caller wait can expire while accepted work continues; the runtime's separate
reply alias discards late delivery. The original invocation deadline,
owner/generation validation and serialized commit still govern accepted work.

## Qualification

The source combines with the private output ledger at `1ba2630` and the shared
RPC checkpoint `b46cbfe`. Current Elixir 1.19.5/OTP 28.4.1 full CI selection
passes 20 doctests, 34 properties and 3,863 tests with zero failures (82
excluded). Minimum Elixir 1.17.3/OTP 27.0.1 passes 64 focused caller/output
cases and warnings-as-errors compilation. Normal formatting, compile, Credo
and Dialyzer hooks remain required on the committed checkpoint. The intentional
OTP alias-tag construction has the same function-specific `no_improper_lists`
annotation as OTP's `gen.do_send_request/3`; repository warning filters and all
other checks remain unchanged.

The regressions assert original identity through the public helper and the
diagnostic edge, worker separation, no early reply before commit, and no late
reply entering the caller mailbox. Existing state serialization tests remain.
The stdio fixture also forwards `MIX_DEPS_PATH`, matching its existing explicit
source/build/lock overrides during isolated qualification.

Representative application migration and callback resource ownership,
absolute admission/caller-wait budgeting, bounded custom-reply terms,
per-member batch capacity, output-before-commit wiring, HTTP/server stdio
convergence and full release qualification remain separate requirements.
