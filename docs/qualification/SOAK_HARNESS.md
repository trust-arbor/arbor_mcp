# Continuous MCP qualification harness

`mix soak.run --duration 48h --output _build/soak/final` runs the repo-only
qualification workload. `mix soak.run --short` is a five-minute rehearsal.
Run either under `with-suite-lock.sh` because the load interferes with the
deadline-sensitive test suite. A 30-minute rehearsal uses `--duration 30m`.
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
and subscriptions, and reconnects across a server restart. The `--rate` option
sets target operations per second; `--mix` accepts comma-separated operation
weights. All operations use the library's normal deadlines and limits.
Every HTTP server passes `sse_mode: :stream` explicitly so the legacy GET SSE
connection stays open even when the test environment enables `:test_mode`.

Legacy Streamable HTTP progress, cancellation, and `tools/list_changed` on
Cowboy and Bandit (owned or host-mounted) are currently **known blocked** by
the independently reproduced server notification delivery defect:
notifications return `:stream_closed` despite a connected GET SSE stream.
Those scenario/operation pairs are recorded with attempt counts and the reason
in `summary.json` under `known_blocked` and in `events.jsonl`; they are not
counted as successes. Any such entry makes `passed` and
`qualification_complete` false. After the library fix, run
`--exercise-known-blocked` after the fix branch merges to exercise them before
removing this temporary classification from `Arbor.MCP.Soak.Policy`.

Clients turn over after the configured `--turnover-requests` (default 500) or
`--turnover-seconds` (default 120), whichever comes first. The harness counts
all outgoing calls, including handshake and subscription traffic, so this is
well below the documented 10,000 distinct request-ID capacity. A cycle also
closes subscriptions and confirms the old client and owned server terminate.
No limit is raised to make a run pass.

The sampler records BEAM memory, process count, ETS table count and aggregate
word size, port count, OS file descriptor count when available, and operation
latency p50/p95/p99. It writes one JSON object per sample or failure to
`events.jsonl`. `summary.json` contains the source commit, lockfile SHA-256,
Elixir/OTP/platform, configuration, per-operation totals, percentiles, and all
failures with typed cleanup evidence. Evidence is flushed as it is written.
On completion the task exits nonzero for any operation or cleanup failure,
error rate above 0.1%, p99 above 5 seconds, or sustained monotonic growth
across at least six turnover samples (processes +20, ETS words +100,000,
ports +10, file descriptors +20, or memory +32 MiB). Missing OS descriptor
data is reported as unavailable, not zero. A run with too few turnover samples
is incomplete and fails qualification.

Judge the 48-hour run only after inspecting `summary.json` and the full JSONL:
the duration must cover 48 continuous hours, every configured transport and era
must have successful operations, no failure or threshold breach may be present,
and cleanup evidence must confirm termination after each turnover. Preserve the
evidence directory with the release candidate's immutable source and lockfile.
