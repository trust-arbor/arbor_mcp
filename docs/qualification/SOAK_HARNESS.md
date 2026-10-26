# Continuous MCP qualification harness

`mix soak.run --duration 48h --output _build/soak/final` runs the repo-only
qualification workload. `mix soak.run --short` is a five-minute rehearsal.
Coordinate short rehearsals with the deadline-sensitive test suite. Run the
48-hour qualification on a dedicated machine without a shared suite lock.
A 30-minute rehearsal uses `--duration 30m`.
The 48-hour release gate must run against the final candidate without a source
or lockfile change; a short or interrupted run cannot satisfy it.

Use `--era modern|legacy|both` (default `both`) and `--transports` with a
comma-separated subset of `beam,stdio,cowboy_owned,cowboy_host,bandit_owned,bandit_host`
(default `all`) to select coverage. For example, `mix soak.run --short --era modern
--transports all` runs every modern transport. `--only beam/modern` narrows a
selected set to one scenario for diagnosis.

Each cycle covers legacy `2025-11-25` and modern `2026-07-28` peers over BEAM,
stdio, and Streamable HTTP. HTTP exercises Cowboy and Bandit with both owned
listeners and host-mounted `HttpPlug`. The workload checks tool calls, resource
and template reads, prompts, progress, cancellation, modern MRTR, notifications
and subscriptions. A restart operation terminates the stdio server
while its client remains live and requires exactly one disconnect, reconnect
attempt, and reconnect success before a ping. Any other disconnect or reconnect
attempt is a failure. The harness also attributes SSE-client reconnect telemetry
to each legacy HTTP stream's process and reports one failure per unplanned
GET-stream reconnect episode, even when both disconnect and reconnect telemetry
are emitted.
BEAM binds a client to one server process, and modern HTTP
is stateless, so those transports skip this reconnect operation.
The `--rate` option
sets target operations per second; `--mix` accepts comma-separated operation
weights. All operations use the library's normal deadlines and limits.
Each scenario keeps its weighted operation schedule across peer turnovers;
`timed_counts` in the summary distinguishes timed-loop coverage from startup
probes. Full qualification requires each applicable operation in the timed loop.
Every HTTP server passes `sse_mode: :stream` explicitly so the legacy GET SSE
connection stays open even when the test environment enables `:test_mode`.

Legacy Streamable HTTP progress, cancellation, and `tools/list_changed` on
Cowboy and Bandit (owned or host-mounted) are currently **known blocked** by
the independently reproduced server notification delivery defect:
notifications return `:stream_closed` despite a connected GET SSE stream.
Those scenario/operation pairs are recorded with attempt counts and the reason
in `summary.json` under `known_blocked` and in `events.jsonl`; they are not
counted as successes. Any such entry makes `passed` and
`qualification_complete` false. After the fix branch merges, run
`--exercise-known-blocked` to exercise them before
removing this temporary classification from `Arbor.MCP.Soak.Policy`.

The legacy short probe on the unfixed branch used `--exercise-known-blocked`,
the library's default HTTP stream idle timeout, and server
`sse_mode: :stream`. All four HTTP variants still failed progress,
cancellation, and list-change notification delivery in their startup probes.
An all-transport modern diagnostic at the short-mode turnover interval also
recorded a stdio reconnect era-probe timeout after its first turnover. The
harness reports this as a failed restart; the library's 2-second era-probe
deadline remains unchanged. Resolve or characterize this failure before using
a 48-hour result as release evidence.

Clients turn over after the configured `--turnover-requests` (default 500) or
`--turnover-seconds` (default 120), whichever comes first. Legacy HTTP has a
lower effective request budget of 96, below its 128 request-ID session limit;
other transports use the configured limit, capped at 5,000 below the 10,000
peer limit. Request accounting includes a conservative allowance for handshake
and subscription calls. A cycle also
closes subscriptions and confirms the old client and owned server terminate.
If normal cleanup fails, it force-stops the listener and confirms the bound
port can be reused; for stdio it retains the child OS PID and requires a
subprocess reaping receipt. Before signalling a child, it verifies the saved
process start time and command against the current PID; if OS identity cannot be
confirmed, cleanup fails without signalling that PID. The last known child PID
and identity survive an inconclusive lookup during restart. Host listeners use
an OS-selected ephemeral port known before startup, so a failed port-info call
can still be followed by listener shutdown and a port-free check. Any
forced cleanup is recorded as a failure even if it succeeds.
No limit is raised to make a run pass.

The sampler forces garbage collection of the harness, client, and owned server
processes before recording
BEAM memory, process count, ETS table count and aggregate word size, port count,
and OS file descriptor count when available. A bounded series is retained for
each scenario's turnover samples and for periodic whole-VM samples. Leak checks
compare the median of eight post-warm-up baseline samples with the median of
the latest eight samples. Qualification requires at least 18 periodic samples
and 18 turnover samples for every scenario, so each leak series has both windows.
Operation latency uses fixed buckets for bounded
p50/p95/p99 estimates; percentile values are bucket ceilings. It writes one
JSON object per periodic sample, turnover sample, or failure to
`events.jsonl`. `summary.json` contains the source commit, lockfile SHA-256,
full OTP version, OS version, Mix environment, dependency versions, override
flags, and `git status --porcelain` at both start and end, plus configuration,
per-operation totals, percentiles, and failures with typed cleanup evidence.
For each Hex dependency, the harness verifies the cached package checksum
against `mix.lock`, compares extracted source files (including packaged `priv/`)
with the package, and repeats the check at the end. It also records per-file
hashes of each dependency's loaded `_build/<env>/lib/<dep>/ebin` and `priv`
artifacts, including native binaries, and fails if they change during the run.
Generated build output without a package checksum is compared between the two
snapshots. Generated Erlang lexer/parser source is
regenerated from its locked grammar and compared before acceptance. A missing
package cache or a source mismatch fails qualification.
Evidence is flushed as it is written, and a nonempty output directory is refused.
On completion the task exits nonzero for any operation or cleanup failure,
error rate above 0.1%, p99 above 5 seconds, a dirty or changing tree, an
environment override, or post-warm-up growth beyond the configured thresholds
(processes +20, ETS tables +10, ETS words +100,000,
ports +10, file descriptors +20, or memory +32 MiB). Missing OS descriptor
data is reported as unavailable, not zero. A run with too few turnover samples
is incomplete and fails qualification.

Judge the 48-hour run only after inspecting `summary.json` and the full JSONL:
the duration must cover 48 continuous hours, all transports and eras must be
selected with the default operation mix, no failure or threshold breach may be present,
and cleanup evidence must confirm termination after each turnover. Preserve the
evidence directory with the release candidate's immutable source and lockfile.
Only then can `qualification_complete` be true; short or selected runs cannot
qualify the release.
