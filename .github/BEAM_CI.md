# Elixir and Erlang/OTP CI policy

The pinned PR matrix covers four Elixir minor lines and three OTP majors using
supported pairs, rather than every combination:

| Elixir | OTP | Purpose |
| --- | --- | --- |
| 1.17.3 | 27.0 | Retained minimum and formatting/quality gate |
| 1.18.5 | 27.3.4.18 | Elixir 1.18 compatibility |
| 1.19.6 | 28.5.0.7 | Elixir 1.19 / OTP 28 compatibility |
| 1.20.4 | 29.1.1 | Elixir 1.20 / OTP 29 compatibility |

All four pairs run unit/integration tests, four-package archive installation,
and both HTTP listener archive/release probes. Third-party dependencies compile
separately so their OTP deprecations do not become project warnings-as-errors.
Project compilation remains strict. Formatting uses the pinned minimum lane.

`BEAM latest stable` runs weekly on Monday, can be dispatched manually, and runs
on PRs changing the CI workflows. It resolves the newest stable patch in each
listed Elixir line and the newest stable release within its paired OTP major.
A fifth lane tries the newest stable Elixir/OTP pair, including future lines.
The `> 0` selector excludes prereleases; the action's literal `latest` does not.
See [setup-beam version selection](https://github.com/erlef/setup-beam#input-versioning)
and [Elixir's compatibility table](https://hexdocs.pm/elixir/compatibility-and-deprecations.html#between-elixir-and-erlang-otp).

Each floating lane records the exact resolved versions, dependencies and
lockfiles, and annotates differences from the pins in its job summary. Failures
stay visible; a future newest pair can be incompatible upstream and needs review
before it becomes a supported combination. Floating formatter output is not a
gate. These jobs do not publish packages, update branches or merge changes.

After a newer pair passes, update all three matrices in `workflows/ci.yml`, the
comparison pins in `workflows/beam-latest.yml`, and this table. Preserve the
minimum 1.17.3/27.0 lane; its OTP difference from the floating 1.17 lane is
expected. Keep the matching ACP workspace and standalone RPC matrices in sync.

Every MCP lane checks out `trust-arbor/arbor_rpc` independently at `.arbor-v2/rpc`
and sets `ARBOR_RPC_PATH` to that repository root until the dependency is published.
The four-package archive consumer additionally checks out the ACP workspace for
its core and adapter archives; the HTTP archive consumer needs only MCP and RPC.

GitHub schedules activate only once the workflow reaches the default branch.
Before merge, the workflow-edit PR trigger exercises the floating lanes.
