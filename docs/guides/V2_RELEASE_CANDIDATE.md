# Testing the ArborMCP and ArborACP release candidates

The current candidate train is published on Hex and uses independent version
lines. The original four `2.0.0-rc.1` packages are retired; their archives and
tags remain available:

| Package | Replacement candidate | First stable target |
| --- | --- | --- |
| ArborMCP (`arbor_mcp`) | `2.0.0-rc.2` | `2.0.0` |
| ArborRPC (`arbor_rpc`) | `1.0.0-rc.1` | `1.0.0` |
| ArborACP (`arbor_acp`) | `1.0.0-rc.1` | `1.0.0` |
| ArborACP adapters (`arbor_acp_adapters`) | `1.0.0-rc.1` | `1.0.0` |

The versions below have been published and verified through ordinary Hex
installation and assembled-release probes. Start with the
[v1-to-v2 migration guide](MIGRATING_V1_TO_V2.md). Stable qualification and the
final continuous 48-hour soak remain incomplete.

## Install the packages your application uses

ArborMCP requires Elixir 1.17 and Erlang/OTP 27 or newer. The OTP minimum is
needed for protocol output encoding and is independent of the Elixir version.

For an MCP application, replace `ex_mcp` with:

```elixir
{:arbor_mcp, "== 2.0.0-rc.2"}
```

ACP applications use `{:arbor_acp, "== 1.0.0-rc.1"}`. Add
`{:arbor_acp_adapters, "== 1.0.0-rc.1"}` when using the bundled vendor adapters.
`arbor_rpc` is transitive; declare it directly if your code calls `Arbor.RPC.*`.
Exact versions make a downstream RC report reproducible. Commit the resulting
lockfile, and use normal Hex resolution without the local package path overrides.

## Candidate scope and validation

The package split, `Arbor.MCP.*` / `Arbor.ACP.*` namespaces, optional adapter
bundle and full server runtime/scheduler redesign are included. Client/Server are
the canonical MCP entrypoints; ACP uses Client/Agent. The existing DSL remains,
with stricter diagnostics. Spark and further performance work are deferred.

MCP Client adds bounded `all_tools`, `all_resources`, `all_resource_templates`
and `all_prompts`; ordinary listing still returns one complete Response page.
Pagination shares one total deadline and finite page/item/byte limits. ACP
`Client.prompt/4` now returns the peer JSON result unchanged. Callers using the
original RC's synthesized `result["text"]` must use `prompt_text/4`, which returns
`{:ok, %{result: peer_result, text: text, truncated?: boolean}}`. Check truncation;
collection is bounded and excludes thought chunks. `Client.with_connection/2,3`
provides finite startup and cleanup with explicit retained outcomes on cleanup
failure. See the [migration guide](MIGRATING_V1_TO_V2.md) for complete contracts.

Development builds after the original RC use revision tokens for atomic
output-ledger updates. This changes the internal ledger table layout: drain and
stop live MCP runtimes before loading the new code, then start fresh runtimes.
Use the same cold-restart procedure when rolling back.

The October 8 source checkpoint passes supported/latest MCP and ACP CI, RPC's
supported/native matrix, strict docs, four-package archive/source checks and
installed/compiler-free assembled-release probes on minimum/current toolchains.
The probes exercise the new pagination, scoped ACP connection and text APIs.
MCP's full strict checkpoint passes 5,445 tests, 20 doctests and 34 properties;
core ACP passes 387 tests; adapters pass 1,479 tests. Six pinned official ACP
TypeScript SDK 1.4.0 interop tests pass. Existing exclusions and source identities
are recorded in the
[qualification assessment](https://github.com/trust-arbor/arbor_mcp/blob/6c32d32de623962cef0322b2763068c2965980b6/docs/V2_RELEASE_ASSESSMENT.md).
The [release checklist](../RELEASING.md) tracks remaining stable gates.

These checks qualify selected source/archive payloads. Published archive
checksums and ordinary Hex installation were independently
verified after publication.
Earlier credential-free CLI lifecycle checks do not qualify live model turns.
No completed continuous 48-hour final-candidate soak is claimed.

The latest continuous attempt stopped after about 50 minutes when the test
harness exceeded the documented request-ID capacity of one persistent MCP peer
and expected a successful response. All three native child cleanup receipts
were confirmed, but the MCP BEAM lane did not confirm its public cleanup path.
The stable 48-hour qualification remains open.

## Limits to exercise in downstream tests

- **JSON object member order:** object keys in protocol replies have no promised
  order. The OTP encoder can serialize an object in a different order without
  changing its values; compare decoded objects in downstream tests. Output
  validation and exact frame sizing still happen before handler state commits,
  and prepared output remains binary for existing transport and batch delivery.
- **Long-lived peers:** `Arbor.MCP.Server.HandlerServer` retains distinct request
  IDs for a peer connection, with `max_request_ids: 10_000` by default. New IDs
  fail with `request_id_capacity_exceeded` once full; duplicates remain rejected.
  Completion does not evict IDs. A replacement peer establishes a fresh scope.
  Choose a finite capacity and an application connection-lifecycle policy;
  callers must handle the capacity error.
- **Local-call overhead:** the October 6 comparison of MCP `0d831a7` and RPC
  `d2a6fcf` measured median BEAM ping at 315 µs versus 5 µs in v1.5, and a
  256 KiB BEAM echo at 928.5 µs versus 13.5 µs. Four paired rounds use the same
  runner and Elixir 1.19.5 / OTP 28.4.1 toolchain. These are sequential checked
  round trips, not saturated throughput or application latency promises.
  Profiling and targeted comparisons have been completed; further performance
  optimization is deferred in favor of library and integration testing. The
  measured costs still require a stable-release decision.
- **Output optimization:** a separate four-pair comparison of the same v2 source
  with the accounting and OTP JSON changes reduced median BEAM ping from
  359.5 to 304 µs and 256 KiB echo from 930 to 769 µs. Large echo improved in
  all four pairs; ping improved in three. These results measure both changes
  together, preserve the same output limits and do not establish v1 parity or
  real-application performance. BEAM delivery still uses native Erlang terms;
  JSON preparation validates protocol replies and frame size before state commit.
- **Native installation:** macOS/Linux source installation requires a C17
  compiler, including when `arbor_rpc` is only a transitive dependency. Assembled
  releases include the built helper and need no runtime compiler. Native
  subprocess operations on Windows are unsupported.
- **Adapters:** vendor executables and their credentials are host-managed.
  Fixture and transcript tests do not replace testing the actual vendor version
  your application runs.

## What to report

Include all four package versions from your lockfile, Elixir/OTP and OS versions,
transport and listener choice, and a minimal reproduction. Exercise normal
startup/shutdown, cancellation, timeouts, sustained request volume, supervision
restarts, and application-specific tools/resources/prompts. For adapter failures,
include the adapter and vendor version. Remove credentials and sensitive tool
payloads from reports.

Stable promotion requires the accepted continuous soak, a decision on the
measured performance costs, clean registry-based installation and the remaining
release checks. The RC version is an explicit opt-in to test this migration.
