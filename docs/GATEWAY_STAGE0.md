# Embedded forwarding: Stage 0 record

This checkout contains a runnable, repo-only forwarding fixture in
[`examples/forwarding_gateway`](../examples/forwarding_gateway/README.md).
It uses the library's existing public APIs; this work adds no new runtime
module, callback, option or default to `lib/`.

## What is exercised

The fixture has two modern HTTP upstream endpoints and one gateway endpoint.
Each test identity has its own Runtime and upstream clients. Static alias and
schema maps avoid a new catalog service; encrypted application request state
and the Runtime replay cache avoid a new continuation store.

The integration tests exercise actual HTTP on both sides:

- Namespaced tool aggregation and routing, complete structured results, and
  distinct upstream credentials per identity.
- Preservation of caller-owned `arguments["_meta"]`. A public `handler_opts`
  function records whether that key existed before Runtime injection, so
  changing downstream progress tokens does not change upstream arguments.
- Form elicitation answered by the downstream client, including modern HTTP
  and the example's fixed-profile legacy `2025-11-25` HTTP path.
- Stable upstream progress tokens across MRTR rounds while downstream tokens
  can change; progress is relayed by the owning callback.
- Rejection of changed arguments, replayed outer continuations and input
  responses supplied without a verified continuation. The last case was a real
  review finding in the initial fixture; its regression failed before the fix.
- Concurrent operations through one gateway client; caller-exit cancellation
  stops only the corresponding upstream work.
- A gateway ingress deadline that cancels upstream work even while the
  downstream caller is willing to wait longer.
- Upstream tool-list change subscriptions forwarded to modern subscription
  clients and legacy notification listeners, with cross-identity isolation and
  feed cleanup on identity retirement.

Run the demo or tests from the repository root:

```sh
mix run examples/forwarding_gateway/demo.exs
mix test test/arbor_mcp/forwarding_gateway_test.exs --include integration
```

The test suite uses messages and monitors as synchronization barriers. Fixture
ports are assigned by the OS; credentials are fixed fake values; no real user
profile, account, token or vendor process is accessed. Example code is excluded
from the Hex package. Its implementation details are not a new public library
API.

## Coverage and remaining boundaries

| Requirement | Outcome |
| --- | --- |
| Core proxy-mode hooks from #92 | Already implemented in rc.7; exercised without adding another proxy mode or deployment. |
| Immutable schema/route consistency | Same static map supplies listing, `handle_get_tool/2` and execution. Mutable catalogs and schema-update races need separate work if required. |
| MRTR lifetime and single use | Existing key ring, request binding and Runtime replay service are used; original application deadline is carried in sealed state. Remote effects are not exactly once. |
| Per-user subscription publication | Existing Runtime-scoped helpers suffice with one Runtime per fixed identity. Shared multi-user Runtime publication and dynamically pooled interests are not qualified here. |
| Subscription ownership | One fixed catalog feed per identity/upstream lives for that identity Runtime's lifetime, independently of individual tool calls or downstream listeners. Retirement closes it. |
| Legacy downstream capabilities | Only the fixture's negotiated form-elicitation profile is accepted. A production host must resolve capabilities per legacy session or deliberately support a fixed profile. |
| Resource-read progress with manual MRTR | Known public-API limitation remains: `read_resource/3` has no explicit progress-token path for that combination. Resources are not in this tools-only fixture. |
| Arbitrary upstream progress/event pressure | Not qualified. Plain-message delivery through `progress_to:` and generic subscription owners does not provide a bounded producer/consumer handshake. Controlled tools emit finitely many events; a hard-bound general bridge needs a separate API/design decision. |
| Application-call replay policy | The fixture chooses existing `conformance_mode: false` / `http_stream_retry: :safe_only` and one ordinary attempt to avoid reissuing tools after an ambiguous break. This is an explicit opt-out, not the library default or a claim of identical standard retry behavior. |
| Real host/harness integration | Not claimed. Real credentials, arbitrary legacy profiles, Claude Code/Codex versions, long-running resync/pressure rehearsals and production operating limits remain to qualify for the intended host. |

This establishes a controlled embedded forwarding proof, not a fully qualified
general-purpose gateway. It does not close the design's open producer-bound or
host-integration gates. If those guarantees are required, resolve them before
using the fixture as a production implementation. Reuse existing Arbor services
where they meet the actual requirements; a separate gateway service remains
optional. See the [design draft](GATEWAY_DESIGN.md).
