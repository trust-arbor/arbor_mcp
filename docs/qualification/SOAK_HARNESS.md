# Continuous MCP qualification harness

`mix soak.run --duration 48h --output _build/soak/final` runs the repo-only
qualification workload. `mix soak.run --short` is a five-minute rehearsal.
Run either under `with-suite-lock.sh` because the load interferes with the
deadline-sensitive test suite. A 30-minute rehearsal uses `--duration 30m`.
The 48-hour release gate must run against the final candidate without a source
or lockfile change; a short or interrupted run cannot satisfy it.

Each cycle covers legacy `2025-11-25` and modern `2026-07-28` peers over BEAM,
stdio, and Streamable HTTP. HTTP exercises Cowboy and Bandit with both owned
listeners and host-mounted `HttpPlug`. The workload checks tool calls, resource
and template reads, prompts, progress, cancellation, modern MRTR, notifications
and subscriptions, and reconnects across a server restart. The `--rate` option
sets target operations per second; `--mix` accepts comma-separated operation
weights. All operations use the library's normal deadlines and limits.

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
