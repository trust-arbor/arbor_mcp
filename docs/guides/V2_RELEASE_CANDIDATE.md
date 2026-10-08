# Testing the ArborMCP and ArborACP v2 release candidate

The original four `2.0.0-rc.1` packages are published on Hex. This checkout
prepares independent replacement versions:

| Package | Prepared replacement | First stable target |
| --- | --- | --- |
| ArborMCP (`arbor_mcp`) | `2.0.0-rc.2` | `2.0.0` |
| ArborRPC (`arbor_rpc`) | `1.0.0-rc.1` | `1.0.0` |
| ArborACP (`arbor_acp`) | `1.0.0-rc.1` | `1.0.0` |
| ArborACP adapters (`arbor_acp_adapters`) | `1.0.0-rc.1` | `1.0.0` |

The replacements are not published yet. Installation examples below apply after
publication; use reviewed source checkouts to test the prepared graph now.
Existing tags and archives stay intact. Retire superseded versions only after
replacement publication and verified installation. Retirement preserves existing
downloads and lockfile resolution. Start with the
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

Development builds after RC1 use revision tokens for atomic output-ledger
updates. This changes the internal ledger table layout: drain and stop live MCP
runtimes before loading the new code, then start fresh runtimes. Use the same
cold-restart procedure when rolling back. This development change still needs
fresh package/consumer qualification and a new candidate soak. Supported and
latest MCP CI passed at `0812257`; changed version/dependency metadata needs its
own archive evidence.

The package split, `Arbor.MCP.*` / `Arbor.ACP.*` namespaces, optional adapter
bundle and full server runtime/scheduler redesign are included. The candidate
also includes the native write-publication race fix found during qualification.

Earlier implementation checkpoints passed current/minimum production API
comparisons, four-package source-archive checks, MCP/ACP CI, four
installed/assembled-release mixed-load rehearsals, and six additional public
negative controls. Those receipts retain their original source identities.
The October 6 documentation, dependency-range and Claude file-limit fixes pass
updated source-archive and supported CI qualification. RPC's macOS native lane
and all four credential-free CLI lifecycle checks pass. ZCode settings fixes
at ACP `7e299f8` pass package and latest-BEAM CI. MCP `e4cb5f6` passes its
22 supported jobs and five latest-BEAM jobs, including the assertion-helper fix.
The subsequent output-accounting and OTP JSON optimizations require their own
final-source qualification. Lifecycle checks do not qualify model turns. See the
[current release assessment](https://github.com/trust-arbor/arbor_mcp/blob/codex/v2-migration/docs/V2_RELEASE_ASSESSMENT.md) for active gates.
Earlier checks do not qualify these changes or establish a completed soak.

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
