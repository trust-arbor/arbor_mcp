# ArborMCP Audit — Recommended Improvements

**Date:** 2026-07-21 · **Version audited:** 1.0.0-rc.4 (commit `3540470`) · **Scope:** architecture, code quality, security, tests, docs, tooling

**Method:** Four parallel code reviews (client/protocol/transports, server/HTTP/dispatch, auth/validation/TLS, tests/CI/hygiene) plus tooling runs on OTP 27 / Elixir 1.17.3: `mix compile` (0 project warnings), `mix credo --strict` (472 files, **0 issues**), `mix format --check-formatted` (clean), sample test runs (61 tests, 0 failures). High-severity findings were individually re-verified against source, one empirically against `:httpc`. Dialyzer and the full suite were not run here (CI covers them). Line numbers refer to the commit above.

**Overall:** The codebase is in strong shape for an rc — clean credo/format, disciplined CHANGELOG, good compile-time DSL errors, correct PKCE/OAuth state handling, and a sane deprecation path for `Arbor.MCP.Server.Tools`. The issues below cluster in four themes: (1) client resilience promises not kept by the code, (2) TLS/origin gaps in the HTTP paths, (3) process-lifecycle leaks on the server side, and (4) CI blind spots.

---

## High priority

### H1. Client auto-reconnect is documented but not implemented
`lib/arbor_mcp/client.ex:956-1024` — on `{:transport_closed, _}` the client transitions to `:disconnected` permanently; no reconnect is ever scheduled and `reconnect_attempts` (client.ex:58) is never incremented. Docs (README, CLAUDE.md, moduledocs) promise auto-reconnection, and telemetry events `[:arbor_mcp, :client, :reconnect, *]` exist for behavior that never fires from the public client.
**Fix:** implement reconnect with backoff in `Arbor.MCP.Client` (the logic already exists in the unused StateMachine, see H2) or remove the claim from docs before 1.0.

### H2. ~940 lines of dead client code: `Arbor.MCP.Client.StateMachine`
`lib/arbor_mcp/client/state_machine.ex`, `transitions.ex` — referenced by nothing in `lib/` except themselves (verified by grep), yet contain the real reconnect/backoff logic and duplicate `receiver_loop` from `connection_manager.ex:86-117`. It is still exercised by tests (`state_machine_integration_test.exs`, 32 `Process.sleep`s), so it looks alive.
**Fix:** either wire it in as the client's connection layer (resolving H1) or delete it and its tests. Decide before 1.0 — this is the single biggest source of confusion about which client path is real.

### H3. Custom TLS options are silently dropped on HTTPS POSTs
`lib/arbor_mcp/transport/http.ex:1219-1274` — `build_ssl_options/1` returns a **flat** ssl list for map input but an `[ssl: [...]]`-wrapped list for non-map input. The POST path (http.ex:683) concatenates the flat list directly into `:httpc` http_options, which is invalid — verified empirically: httpc logs `Invalid option {verify,verify_peer} ignored` and proceeds. On OTP 26+ the built-in `verify_peer` default still applies, but any *configured* TLS setting (client certs for mTLS, private `cacerts`, `versions` restrictions) is silently ignored on every HTTPS POST. The SSE path (http.ex:1054 → sse_client.ex:365) wraps correctly.
**Fix:** make `build_ssl_options/1` return one shape (flat), and wrap as `{:ssl, opts}` at each call site; add a test asserting httpc receives `{:ssl, _}`.

### H4. Origin validation does not prevent DNS rebinding
`lib/arbor_mcp/http_plug/core.ex:30-84` — with `validate_origin: true` (the default): a missing/empty Origin header is allowed (lines 31-35), and the `same_origin?` fallback (75-84) compares Origin against `conn.host` — the attacker-controlled Host header — so in a rebinding scenario Origin == Host and the check passes regardless of `allowed_origins`. The correct mechanism (`Arbor.MCP.Plugs.DnsRebinding`, a Host allow-list) is opt-in, and has its own bugs: default-allows `0.0.0.0` and mis-parses IPv6 hosts (`plugs/dns_rebinding.ex:23,40-41`). `docs/SECURITY.md:16` claims rebinding protection exists.
**Fix:** validate Host against an allow-list in `HttpPlug` by default, drop the `same_origin?` fallback, make missing-Origin policy explicit, fix DnsRebinding's IPv6/`0.0.0.0` handling, and align SECURITY.md.

### H5. SSE session ETS table is owned by a transient request process
`lib/arbor_mcp/http_plug.ex:63-70` — `start_link/1` is a sham (`{:ok, self()}`, no GenServer, no callers), so `:http_plug_sessions` is actually created lazily inside `register_sse_handler`'s rescue (http_plug.ex:766-776), owned by whichever Cowboy request process touched it first. When that process exits, every session registration is destroyed. Related leak: `sse_handler.ex:234-237` traps exits but ignores `:EXIT` from the conn owner, and ETS cleanup lives only in the request process's `receive` loop (http_plug.ex:585-598) — if the client disconnects first, handler + ETS entry leak while heartbeats keep firing into a dead stream.
**Fix:** create the table from `Arbor.MCP.Application` (or use `Registry`); stop the handler on conn-owner `:EXIT` and move ETS cleanup into `terminate/2`.

### H6. Per-request unsupervised handler GenServer; exits become dropped requests
`lib/arbor_mcp/message_processor.ex:182-207` — every HTTP POST spawns a linked, unsupervised `GenServer.start_link(handler_module, ...)`, discarding handler state after the request. The `rescue` clauses in `message_processor/method_handlers.ex` (e.g. 77-78) don't catch **exits**, so a handler crash or the hardcoded `GenServer.call` timeouts (10s at method_handlers.ex:64, 5s elsewhere) kill the request process with no JSON-RPC error response.
**Fix:** run handlers under a supervisor (or a pool for stateless handlers) and `catch :exit` in MethodHandlers, returning a proper `-32603`.

### H7. Transport `close/1` leaks reader/SSE processes
`lib/arbor_mcp/transport/http.ex:972` and `lib/arbor_mcp/transport/stdio.ex:319` — `Process.exit(pid, :normal)` is a no-op against a process that isn't trapping exits (neither sse_client.ex nor stdio.ex sets `trap_exit`; verified), so the SSE client GenServer and the stdio reader survive `close/1`.
**Fix:** `GenServer.stop/1` for the SSE client; `Process.exit(pid, :kill)` or a shutdown message for the reader.

### H8. Async POST discards updated transport state; Task unmonitored
`lib/arbor_mcp/transport/http.ex:319-339` + `lib/arbor_mcp/client.ex:902-910` — the async POST Task computes a new transport state (session-ID rotation, OAuth refresh from `maybe_oauth_retry`) that the client throws away (`{:ok, _new_ts, ...}`), so session/auth updates are lost between requests; the Task is also unlinked/unmonitored, so if it crashes the pending request hangs until timeout.
**Fix:** send state updates back to the owning client process and monitor the Task.

### H9. CI never runs the integration/interop suites, and compliance runs 4× identically
`.github/workflows/ci.yml:78` runs `mix test --exclude compliance` while `test/test_helper.exs:53-89` already excludes `integration, external, live_server, slow, performance, stress, requires_http, requires_beam, requires_bypass, interop` — and no CI job ever `--include`s them, so a large tagged portion of the suite never executes anywhere. Meanwhile the three "version" compliance jobs (ci.yml:113,145,177) all run the same unparameterized `mix test.suite compliance`, plus a fourth run for coverage (ci.yml:210) — coverage that measures only the compliance suite and gates nothing.
**Fix:** add a CI job for the integration/`requires_*` tags (`mix test.suite ci` exists for this), collapse the duplicate compliance jobs (or parameterize them for real, including 2025-11-25), and run coveralls over the whole suite.

### H10. Batch request replies violate their own contract on disconnect
`lib/arbor_mcp/client/request_handler.ex:262` replies `{:ok, responses}` on success, but the disconnect/transport-close paths reply a **bare list** (`client.ex:810` and `client.ex:1005`, verified), breaking the documented `{:ok, results} | {:error, reason}` shape of `batch_request/3`.
**Fix:** wrap all batch replies uniformly.

---

## Medium priority

### Correctness & API consistency

- **M1. clientInfo version hardcoded as "0.8.0"** — `client.ex:1080` and `connection_manager.ex:323` (actual version: 1.0.0-rc.4). Derive from `Application.spec(:arbor_mcp, :vsn)` in one helper.
- **M2. `:format` default contradicts docs and breaks `find_tool`** — docs say `:map` (client.ex:206-233) but the code defaults to `:struct` (client.ex:1166); `Operations.Tools.find_tool` pattern-matches `%{"tools" => _}` which never matches a struct, and returns `:tool_not_found` where the spec says `{:error, :not_found}` (operations/tools.ex:99-131).
- **M3. `Arbor.MCP` facade returns bare values and blanket-rescues** — `ex_mcp.ex:356-455` returns unwrapped results (violating the project-wide `{:ok, _}` convention) and `rescue _ ->` relabels any exception as "Client not responding". Return tagged tuples; rescue narrowly.
- **M4. `connect/2` can throw instead of returning an error tuple** — `normalize_transport_spec` throws `{:transport_config_error, _}` with no catch (client.ex:1039-1044).
- **M5. Retry wrapper changes error shapes and can crash** — with a retry policy, errors become `{:error, {:retry_exhausted, reason}}` (undocumented); `execute_function` rescues *all* exceptions into retryable errors; `add_jitter/1` calls `:rand.uniform(0)` (raises) when delay < 4ms (reliability/retry.ex:189,226-244).
- **M6. Transport behaviour type doesn't admit the HTTP 3-tuple** — behaviour declares 2-tuples (transport.ex:108) but HTTP returns `{:ok, state, response}`; `send_response` (request_handler.ex:596-605) lacks the 3-tuple clause → `CaseClauseError` if a server-request reply arrives with an inline HTTP body.
- **M7. Batch rejection gated on exactly `"2025-06-18"`** — `handler_server.ex:238-247`; 2025-11-25 sessions still process JSON-RPC batches contrary to spec. Gate on version ≥ 2025-06-18.
- **M8. Protocol-version defaults disagree across modules** — `plugs/protocol_version.ex:24-44` (defaults "2025-11-25", moduledoc says "2025-06-18", hardcoded list) vs `http_plug.ex:805-826` (400 on missing header) vs `handler.ex:790` ("2025-03-26"). Centralize on `VersionRegistry`.

### Server robustness

- **M9. Four parallel dispatch implementations with feature drift** — `handler_server.ex:676-1185`, `message_processor.ex` + `method_handlers.ex`, `stdio_server.ex:166-316`, `protocol/request_processor.ex`; stdio lacks completion/subscribe/roots/setLevel; `normalize_tool_result`/`deep_stringify_keys` are copy-pasted (handler_server.ex:1187-1203 vs method_handlers.ex:257-289). Extract one shared dispatcher/normalizer — this is the root cause of M7/M8/M10/M11-class drift.
- **M10. `logging/setLevel` short-circuited in MessageProcessor** — canned success at message_processor.ex:226; `handle_set_log_level` is never called on that path (handler_server does call it).
- **M11. Custom-method errors and exits mapped to `-32601 Method not found`** — method_handlers.ex:207-216 masks real failures (including call timeouts) as "method not found". Distinguish `-32603` internal errors.
- **M12. Error responses leak internals** — `inspect(reason)` goes into JSON-RPC error data/messages (method_handlers.ex:249-251, message_processor.ex:198-203, handler_server.ex:709,745,802,918). Log the detail; return generic messages.
- **M13. Handler reply-shape zoo** — MethodHandlers accepts 2-/3-/4-tuples and `:ok` (method_handlers.ex:29-52,129-139) because the Handler GenServer bridge leaks state into replies (handler.ex:683,765-766). Normalize at the bridge.
- **M14. Lazy `SessionManager` started linked to the request process** — http_plug.ex:614-627 (unsupervised, dies with the request; it's already supervised in application.ex:22); `:ok = terminate_session` at :470 is a crash-match.
- **M15. Task callbacks are unreachable on 2 of 3 dispatch paths** — `handle_task_*` defined at handler.ex:482-508 but HandlerServer and MessageProcessor never dispatch them. Wire up or document as request_processor-only.

### Client robustness

- **M16. Sampling/elicitation handlers block the client loop** — user `handle_create_message` runs synchronously inside `handle_info` (request_handler.ex:434-465), head-of-line-blocking all responses; handler `init/1` re-runs per incoming request and the returned handler state is discarded (request_handler.ex:379-404), so stateful client handlers are impossible. Run in a supervised Task; persist state.
- **M17. No handshake timeout** — `connection_manager.ex:347-356` and stdio's `receive` (stdio.ex:357-368) have no `after`; `start_link` can hang in `init/1` against an unresponsive server.
- **M18. Per-request GenServer.calls for defaults** — `make_request/5` issues up to two extra calls (`:get_default_timeout`, `:get_default_retry_policy`) per request; the latter uses the request timeout as its own call timeout (client.ex:1103-1148). Cache at connect.
- **M19. Circuit breaker: linked task can kill the breaker; ClientWrapper never uses it** — `Task.async`/`Task.yield` in `handle_call` serializes protected calls and a raising fun crashes the CircuitBreaker via the link (circuit_breaker.ex:152-184); `ClientWrapper.execute_with_reliability` spawns unbounded `Task.start` and ignores `state.circuit_breaker` entirely (reliability/supervisor.ex:453,528-537).

### Security hardening

- **M20. Default SecurityGuard config blocks all non-localhost servers** — `internal/security_config.ex:13,17`: localhost-only `trusted_origins` + Deny consent handler means any external MCP URL gets its auth headers stripped then the request denied. Fail-closed but a trap that pushes users to disable security wholesale; also `enable_token_passthrough_prevention` / `enable_user_consent_validation` flags are read nowhere (dead knobs).
- **M21. JWT `exp`/`nbf` optional and type-loose** — `authorization/jwt.ex:271-290`: missing or non-numeric `exp` passes validation; `iss`/`aud` only checked if the caller asks. Algorithm allow-list is correctly asymmetric-only (no `none`/HS*). Require numeric `exp` by default.
- **M22. Client-supplied `mcp-session-id` accepted unvalidated** — http_plug.ex:736-741 accepts any string (unbounded length/charset), echoes it back (269); legacy `x-session-id` also honored (744-756). Generation entropy is good (16 random bytes, :797-801). Validate format/length and reject unknown IDs.
- **M23. Missing `customize_hostname_check` in default client TLS opts** — transport/http.ex:1219-1266 (wildcard certs fail); `spec_sync/github_client.ex:186-189` does it correctly. Also: `internal/security.ex:415-428` is a divergent second TLS builder with no cacerts default, and `internal/security.ex:373-377` exports a `verify_hostname` stub that always returns `:valid_peer` — delete or implement both.
- **M24. Consent TTL integer ambiguity** — `security/consent.ex:124-127` treats integer expiry as monotonic time; a handler returning unix seconds yields near-permanent consent.

### Tests

- **M25. 296 `Process.sleep` calls across 71 test files** — worst: `state_machine_integration_test.exs` (32), `logging_compliance_test.exs` (20), `cancellation_comprehensive_test.exs` (16), plus 10 in shared `test/support/test_helpers.ex`. Flakiness and wall-clock cost; replace with `assert_receive`/monitor-based sync.
- **M26. Mox is a dependency but effectively unused** — one test file uses it; `test_helper.exs:94` says "Transport mocks removed". CLAUDE.md still claims "Unit tests with Mox for transport mocking". Drop the dep or realign.

---

## Low priority

- **L1.** Hex package ships dev tooling: `lib/arbor_mcp/spec_sync/`, mix tasks `test.suite`/`test.tags`/`test.cleanup`/`check_skip_tags`/`mcp.sync_spec` appear in consumers' `mix help` (mix.exs:109-126 includes all of `lib`). Keep `Arbor.MCP.Testing.*` (document it as a public test kit); move the rest out.
- **L2.** `lib/arbor_mcp/test/support/transports.ex` defines `ExMcp.Test.Support.Transports` — wrong `ExMcp` capitalization, duplicates test/support's role. Fold into `test/support/` or `Arbor.MCP.Testing`.
- **L3.** README coverage badge points to codecov (README.md:8) while CI uses coveralls — dead badge.
- **L4.** CLAUDE.md staleness: references `lib/arbor_mcp/protocol.ex` (actual: `lib/arbor_mcp/internal/protocol.ex`) and the Mox claim (M26).
- **L5.** Dead code with a latent bug: `handler_server.ex:110-114` `:start_message_loop` evaluates `self()` inside `spawn_link` (would message itself); no senders exist. Delete.
- **L6.** Test scaffolding in production modules: `http_plug.ex:568-573` `:test_mode`, `sse_handler.ex:279-293` duck-typed fake conns, `handler_server.ex:580-627` SlowHandler introspection. Move behind injection.
- **L7.** `config/config.exs:25-60` placeholder `auth.example.com` OAuth endpoints — harmless for dependents (library config isn't loaded) but ensure runtime code never falls back to them.
- **L8.** `security/validation.ex:193` accepts `verify: :verify_none` silently while rejecting weak ciphers; at least log a warning.
- **L9.** DSL: `dsl/result.ex:47-53` has no clause for bare non-tuple handler returns → raw `FunctionClauseError` despite moduledoc claiming plain values normalize.
- **L10.** `server/transport.ex:110-121` passes `tools:` (ignored by `HttpPlug.init`) and defaults `cors_enabled: true` vs HttpPlug's `false` (http_plug.ex:83).
- **L11.** Deprecated `Arbor.MCP.Server.Tools` (~2,130 LOC): zero internal callers outside itself. The original 1.1.0 removal target would violate SemVer after stable 1.0, so the API is retained throughout 1.x and removal is deferred to 2.0.0. `structured_output_test.exs` / `structured_output_compliance_test.exs` should still be ported first; public functions carry compiler deprecation warnings.
- **L12.** CI: no `_build` caching (only deps + dialyzer PLT); every job recompiles the app.
- **L13.** Hygiene: `.gitignore` has duplicate `/cover/` and `tmp/` entries; untracked local junk on disk (`erl_crash.dump`, `.aider*`, `doc/`, `cover/`, old `ex_mcp-*.tar`) — all gitignored, just delete locally.
- **L14.** Health-check timer fires but performs no check (client.ex:934-941); unused `:buffer` field (stdio.ex:35); unreachable duplicate branch (connection_manager.ex:132-140).
- **L15.** Oversized modules: client.ex (1,452), transport/http.ex (1,275), handler_server.ex (1,200+) — worth splitting when touched, not urgently.

---

## What's already in good shape

Credo strict and `mix format` are clean across 472 files; compile has zero project warnings. PKCE (256-bit verifier, S256, constant-time compare), OAuth `state` handling, redirect-URI HTTPS-or-localhost validation, and introspection HTTPS enforcement are correct. Consent/SecurityGuard decision paths are total and fail closed. No `binary_to_term`, no runtime `Code.eval*`, `String.to_atom` confined to compile-time DSL keys (request paths use `to_existing_atom`). Request body limit (1MB) present. No tokens in logs. The Server DSL's compile-time diagnostics are excellent. CHANGELOG discipline, skip-tag CI gate, and the version matrix (Elixir 1.17–1.20 / OTP 27–29) are all solid.

## Suggested sequencing

**Before 1.0.0 final** (contract/behavior changes get harder after): H1/H2 (decide the client connection story), H3 (TLS), H4 (origin), H10 + M2/M3/M4 (public API contracts), M1 (clientInfo), M20 (default security posture), M21 (JWT exp).
**Shortly after:** H5–H8, H9, M9-M15 (server consolidation), M16–M19, M25.
**Opportunistic:** everything in Low.
