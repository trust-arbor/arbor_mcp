# ExMCP 1.6 maintenance release

This release retains `{:ex_mcp, "~> 1.0"}`, the `:ex_mcp` application and
`ExMCP.*` namespaces, including the built-in `ExMCP.ACP.*` adapters. It does
not require the Arbor package split, a native compiler or the v2 scheduler.
No end-of-support date has been set for ExMCP 1.x.

The accumulated compatible additions after 1.5.0 warrant a minor release.
Review the 1.6.0 changelog's **Behavior change** entries: metadata and issuer
validation, linked transport ownership, typed transport errors, inspection
redaction and Claude session MCP capability reporting correct prior behaviour.
The Mint/Cowlib security floors may require updating an older lockfile.

## Backport provenance

| Fix | Origin | 1.x adaptation |
| --- | --- | --- |
| Claude byte caps and UTF-8 response validation | arbor_acp `991fc419` | Mapper and regression/golden tests; original protocol and Port runner |
| ZCode session catalogs, model selection and native setter acknowledgements | arbor_acp `7e299f84` | Adapter mapping plus additive deferred bridge return form and optional failure callback; existing adapter forms still work |
| Complete response fields and native content/accessors | arbor_mcp `24b632f9`, `81c19c3b` | Preserve `to_test_map/1`, local `meta` spelling, omitted local false `isError`, and old facade defaults |
| Correct resource-text extraction | arbor_mcp `24b632f9` | Read standard `contents` without adopting new v2 facade options or errors |

TLS/OS CA deadlines, security dependency floors, client lifecycle and deadline
fixes, credential redaction and private Claude MCP configuration files already
exist on the maintained source line after tag `v1.5.0`; they are included once,
not reapplied as new backports.

## Qualification and publication

Run maintenance CI and adapter/protocol/security regressions on this source.
Check documentation and package contents; install the built archive into a
clean consumer and assemble a release against the unchanged application name.
Only after review and passing CI should the maintenance PR be merged and a
fresh `v1.6.0` tag/package published. Publishing needs a user-owned terminal
for any Hex 2FA prompt. Keep the v2 RC and stable-release gates independent.
