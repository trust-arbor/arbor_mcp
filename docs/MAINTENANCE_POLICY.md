# ExMCP 1.x maintenance and Arbor v2 releases

ExMCP 1.x remains supported while ArborMCP, ArborACP, ArborACP adapters and
ArborRPC 2.x are introduced. Publishing v2 does not require existing applications
to migrate. No end-of-support date has been set; any future retirement will be
announced in advance in this policy and the release notes.

## Release lines

| Line | Source branch | Hex packages | Public modules |
| --- | --- | --- | --- |
| Maintained 1.x | `codex/maintenance-1.x` in `trust-arbor/arbor_mcp` | `ex_mcp` | `ExMCP.*`, including `ExMCP.ACP.*` |
| Version 2 | `codex/v2-migration` until merged into MCP's default branch; each split repository thereafter | `arbor_mcp`, `arbor_acp`, `arbor_acp_adapters`, `arbor_rpc` | `Arbor.MCP.*`, `Arbor.ACP.*`, `Arbor.RPC.*` |

The 1.x branch was preserved from supported commit `3914a927` before the v2
merge. Its package identity, configuration ownership and compatibility promises
remain those of ExMCP 1.x. Existing tags and releases are preserved.

## Backport policy

- Backport applicable correctness, security and compatibility fixes, with a
  regression test on the 1.x implementation. Record the originating v2 commit
  or issue, or explain when an independent implementation is required.
- Publish compatible bug fixes as 1.x patch releases. Compatible additions may
  ship in a 1.x minor release after review; maintenance is not security-only.
- Keep the 1.x public API, defaults, wire/storage identifiers and process-lifetime
  contracts. Do not copy the v2 namespace/package split, scheduler redesign or
  API removals into 1.x. A security fix that intentionally changes observable
  behavior must explain that change and its migration implications.
- Prefer small reviewed cherry-picks with `git cherry-pick -x` when source
  layouts still match. Otherwise implement the equivalent fix against 1.x and
  link both changes. Do not merge the v2 branch wholesale into maintenance.
- Run the maintenance branch's own CI and relevant protocol, security, adapter
  and package-consumer checks. A passing v2 test does not qualify its backport.
- Review release notes, source archives and clean Hex installation before
  tagging `v1.<minor>.<patch>` and publishing `ex_mcp`. Never reuse a published
  version or tag. Keep the v2 release process separate.

Consumers staying on 1.x can retain `{:ex_mcp, "~> 1.0"}` to allow compatible
1.x releases, or choose a narrower minor-series requirement. Keep and review the
application's lockfile when updating. The GitHub move does not change the Hex
package name.

## Reporting and support

Report vulnerabilities through the repository's
[private reporting form](https://github.com/trust-arbor/arbor_mcp/security/advisories/new).
For ordinary issues, include the package version, branch/release line, Elixir/OTP
and platform, and a minimal reproduction. Fix applicability is assessed for
both maintained lines rather than assuming that their internals are identical.
