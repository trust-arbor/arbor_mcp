# Testing the ArborMCP and ArborACP v2 release candidate

`2.0.0-rc.1` is the coordinated candidate for ArborMCP (`arbor_mcp`), ArborACP (`arbor_acp`),
ArborACP adapters (`arbor_acp_adapters`) and ArborRPC (`arbor_rpc`). It is intended
for downstream migration and
compatibility testing. Stable `2.0.0` qualification remains in progress.

Publication is being prepared; the dependency examples below become usable once
the packages appear on Hex. Start with the [v1-to-v2 migration guide](MIGRATING_V1_TO_V2.md).

## Install the packages your application uses

For an MCP application, replace `ex_mcp` with:

```elixir
{:arbor_mcp, "== 2.0.0-rc.1"}
```

ACP applications use `{:arbor_acp, "== 2.0.0-rc.1"}`. Add
`{:arbor_acp_adapters, "== 2.0.0-rc.1"}` when using the bundled vendor adapters.
`arbor_rpc` is transitive; declare it directly if your code calls `Arbor.RPC.*`.
Exact versions make a downstream RC report reproducible. Commit the resulting
lockfile, and use normal Hex resolution without the local package path overrides.

## Candidate scope and validation

The package split, `Arbor.MCP.*` / `Arbor.ACP.*` namespaces, optional adapter
bundle and full server runtime/scheduler redesign are included. The candidate
also includes the native write-publication race fix found during qualification.

Earlier implementation checkpoints passed current/minimum production API
comparisons, four-package source-archive checks, MCP/ACP CI, four
installed/assembled-release mixed-load rehearsals, and six additional public
negative controls. Those receipts retain their original source identities.
The October 6 documentation, dependency-range and Claude file-limit fixes
require updated package and CI qualification; the new macOS cleanup lane and
current ZCode lifecycle smoke have open failures under investigation. See the
[current release assessment](../V2_RELEASE_ASSESSMENT.md) for active gates.
Earlier checks do not qualify these changes or establish a completed soak.

The latest continuous attempt stopped after about 50 minutes when the test
harness exceeded the documented request-ID capacity of one persistent MCP peer
and expected a successful response. All three native child cleanup receipts
were confirmed, but the MCP BEAM lane did not confirm its public cleanup path.
The stable 48-hour qualification remains open.

## Limits to exercise in downstream tests

- **Long-lived peers:** `Arbor.MCP.Server.HandlerServer` retains distinct request
  IDs for a peer connection, with `max_request_ids: 10_000` by default. New IDs
  fail with `request_id_capacity_exceeded` once full; duplicates remain rejected.
  Completion does not evict IDs. A replacement peer establishes a fresh scope.
  Choose a finite capacity and an application connection-lifecycle policy;
  callers must handle the capacity error.
- **Local-call overhead:** the qualified local microbenchmarks measured about
  0.305 ms for BEAM ping and 0.912 ms for a 256 KiB echo, versus about 0.005 ms
  and 0.013 ms in v1.5. A separate controlled v2 optimization comparison reduced
  large echo latency by 31.2%. Measure your application's workload; these are
  microbenchmark results, not an end-to-end latency promise. The timing run
  preceded the private RPC write fix; it is retained evidence, not a fresh run
  of that corrected graph.
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
