# Tracking upstream MCP core and extensions

The **MCP extensions upstream** workflow checks official extension sources every
Wednesday at 14:13 UTC and supports **Run workflow** for an immediate check. It
also runs when a PR changes the checker, its tests, baseline or workflow.

This is an advisory source check. Successful collection produces a JSON report,
a Markdown job summary and a 90-day artifact. Source drift and pending reviews
produce a warning, not a failing compatibility gate. API errors, incomplete
pagination, truncated trees and invalid baselines fail the job. The ordinary
conformance/release gates remain independently pinned.

## Sources and comparison

The checker discovers public repositories in the `modelcontextprotocol` GitHub
organization with the `ext-` or `experimental-ext-` prefixes, following all
repository-list pages. It also watches `docs/extensions/` and the extension
framework/lifecycle SEPs in `modelcontextprotocol/modelcontextprotocol`.
The same comparison now includes all `docs/specification/`, `schema/` and
`schemas/` trees in the core repository, including draft and newly added
revision directories. Core normative prose is therefore monitored alongside
schema changes, rather than inferred from extension-index changes.

For extension repositories it compares specification, schema and documentation
trees, root README/changelog/release/index files, and schema/type definitions.
This includes stable, beta, experimental, archived and draft specification
directories, nested package schemas and generated schema definitions. Ordinary
SDK implementation, dependency-lock and example/test changes are outside the
comparison. The path policy is in `scripts/check_mcp_extensions.py`; extend it
if upstream adopts a new source layout.

Each default branch resolves to one immutable commit before its tree is read.
Git blob identities are compared with the committed baseline: additions,
modifications, removals, new/missing repositories and archive-state changes are
reported with source/commit-comparison links. A missing public repository can
mean a rename or visibility change, not necessarily deletion. Changes can be
editorial or relevant only to a future revision; a source diff is not itself a
finding that ArborMCP needs a protocol change.

Each observation has a deterministic `review_key` for deduplication. Retain the
key in the reviewed PR or requirement follow-up when triaging it; repeated
observations do not authorize automatic acknowledgement. The committed source
pins and requirement register are the durable review record. Workflow artifacts
are execution history with finite retention, not a substitute for that record.
The workflow has read-only GitHub permissions and does not post issues or comments.

The weekly **MCP conformance upstream** workflow also compares published SDK and
harness versions and every available harness scenario with
`scripts/mcp_tooling_baseline.json`. New, removed and retargeted scenarios are
reported even when our explicit extension selectors do not run them. Unknown
inventory formats and incomplete collection fail. SDK capability still requires
an implementation review; publishing a new version does not qualify a profile.
Neither watcher changes dependency or harness pins.
Published package timestamps determine release order; older calendar-version
packages are not mistaken for newer releases of a subsequent SDK generation.
Each release/scenario change has its own stable key, independent of unrelated
changes in the same report. `scripts/mcp_upstream_reviews.json` links those keys
to source-controlled review IDs and explicit decisions. An open record remains
visible on subsequent runs; recording it does not silently clear the drift or
advance a pin. The initial open record tracks Everything peer 2.1.0 for separate
review and qualification while existing interop remains pinned to 2.0.1.

```sh
python3 -B scripts/check_mcp_tooling.py --version 0.2.0-alpha.12
```

Release/PR conformance remains pinned separately. The extension execution gate
compares actual check outcomes with `scripts/mcp_extension_checks.json`: missing
checks, new skips, failures and warnings cannot hide behind an upstream process's
successful exit. The single recorded Tasks notification stub remains explicitly
unqualified. Local requirement evidence is enforced independently by
`scripts/check_mcp_assurance.py`; see [requirement evidence](MCP_REQUIREMENTS.md).

## Run locally

Python 3.10+ and network access to `api.github.com` are sufficient; no Elixir,
Node or third-party Python dependencies are needed:

```sh
python3 -B -m unittest discover -s scripts/tests -p test_mcp_extensions.py -v
python3 -B scripts/check_mcp_extensions.py
```

Reports are written to `tmp/mcp-extensions/report.json` and `report.md`. Use
`--output DIRECTORY` to preserve a separate run; paths that would overwrite a
custom input baseline are refused. `GITHUB_TOKEN` is optional for
local runs and supplied with read-only permissions in CI. An anonymous run is
subject to GitHub's lower rate limit. Credentials are used only for the GitHub
API; HTTP redirects are refused and upstream code is never executed.

## Reviewing and advancing a baseline

`scripts/mcp_extensions_baseline.json` records exact source commits and a
`review_status`. The initial six entries were an **observed inventory**, all
marked `pending`. The
[baseline assessment](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/MCP_EXTENSION_BASELINE_REVIEW.md)
now covers twelve sources, all acknowledged as reviewed for their recorded
scope after the Tasks/Auth corrections and approved confidential IdP configuration.
Enterprise evidence distinguishes local confidential-client tests from the
official public-client IdP scenario and records existing AS-grant limits.
A reviewed source whose
`assessment` is `not_implemented` is an acknowledgement of current scope, not a
compatibility claim or a decision against future adoption. Newly discovered
repositories still require assessment before being added to the baseline.

Review applicable specifications/schemas against local behavior and tests.
Record whether a source calls for a fix, a new optional feature, documentation,
or no local change. Make required changes through the normal review process.
Only then advance the source's `revision` and set `review_status: "reviewed"`
in a reviewed PR. Include `archived: true` when acknowledging an archived repo.
An unsupported extension can be acknowledged without implementing it; document
that scope decision in the PR. New drift will still be reported.

The check never advances baselines or edits dependencies, generated files,
capability advertisements or protocol behavior. A pending entry remains visible
even when its files match the initial inventory exactly.
