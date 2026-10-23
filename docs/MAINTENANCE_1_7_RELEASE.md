# ExMCP 1.7 maintenance release

This release retains `{:ex_mcp, "~> 1.0"}`, the `:ex_mcp` application and
`ExMCP.*` namespaces. It does not require the Arbor package split, a native
compiler or the v2 scheduler. No end-of-support date has been set for
ExMCP 1.x.

1.7.0 is a minor release because it adds options as well as fixes. Every
outbound HTTPS connection now follows the same trust-store rules, and the
connections that had no way to choose CA certificates now have one:
- `ExMCP.Authorization.MetadataFetcher` takes `:cacerts`;
- remote JSON Schema references take `network_refs: [cacerts: ...]`;
- the legacy HTTP+SSE transport takes `security: %{tls: ...}`.

## Behavior changes

Nothing changes for applications whose OS trust store loads, beyond the new
options and the first item below. Review the 1.7.0 changelog before
upgrading:
- `security: %{tls: %{verify: :verify_none}}` no longer loads the trust store,
  so those connections keep working while the store is unavailable.
- **When the OS trust store cannot be loaded**, for example in a minimal
  container without `ca-certificates`, these connections now fail like other
  HTTPS requests instead of silently trusting the `castore` bundle: the legacy
  HTTP+SSE transport, OAuth metadata, OIDC discovery and JWKS fetches, and
  remote JSON Schema fetches. Set `config :ex_mcp, :cacerts, fallback: :castore`
  to keep the old behavior for all HTTPS connections.
- **The legacy HTTP+SSE transport (`transport: :sse`) now reads `:security`.**
  It used to ignore it. A `security:` map passed to it is validated like the
  HTTP transport's, and its `:tls` settings apply. Over HTTPS it uses the HTTP
  transport's TLS defaults: peer verification, TLS 1.2/1.3 and HTTPS hostname
  matching.

## Backport provenance

The fixes were made on ArborMCP master first (#94) and applied to 1.x by hand
because the namespace differs (#95). The touched files otherwise match.

| Fix | Origin | 1.x commit |
| --- | --- | --- |
| Fail closed when Mint would pick CA certificates itself | arbor_mcp `295db2d` | `c1168a6` |
| CA certificate options for metadata, schema and legacy HTTP+SSE fetches | arbor_mcp `977b66a` | `dd6868a` |
| TLS test certificates signed with SHA-256 (tests only) | arbor_mcp `c0912a0` | `235d48d` |
| No trust store load for `verify: :verify_none` | arbor_mcp `3cb62d9` | `821b4f1` |

Still left out of 1.x, as noted for 1.6:
- JSON Schema 2020-12 dialect support. It needs a new dependency and changes
  how schemas validate.

## 1.7.1 security patch

1.7.1 fixes GHSA-2q9v-qvwf-3m8w. The Claude and Pi ACP adapters appended
option values to their CLI command lines without checking them, so a value
starting with `-` became another flag. This is the argument injection reported
upstream as CVE-2026-96620, where a value such as `--mcp-config ...` can start
an arbitrary command. It is exploitable when an application passes untrusted
input as an adapter startup option. Session IDs from ACP `session/load` and
`session/resume` requests do not reach the command line.

The **Behavior change**: `ClaudeSDK.Protocol.command/1` and
`Pi.cli_command/1` return `{:error, {:invalid_option, key, reason}}` for a
value starting with `-` or one that is not a string, and Claude `:resume` and
`:session_id` must be session UUIDs. `ExMCP.ACP.Registry.npx_command/1`
returns `{:error, :invalid_npx_package}` for an invalid package specifier.

| Fix | Origin | 1.x commit |
| --- | --- | --- |
| Reject ACP adapter CLI options that would be parsed as flags | arbor_acp#8 (`dd14886`, `61fe5c5`) | `9546f68` (#100) |

## 1.7.2 security patch

1.7.1 was tagged but never published to Hex, so 1.7.2 is the first published
release carrying its argument-injection fix (GHSA-2q9v-qvwf-3m8w). It adds the
findings of the pre-release security review:

- GHSA-jrw4-h7gq-x4cj: `ExMCP.Internal.WorkspacePath.canonical/1` collapsed
  `..` before resolving symlinks, so `<root>/link/../secret` passed the ACP
  client's `fs`/`terminal` authorization and the Codex/ZCode workspace-root
  checks while the real file was opened; a project's `.pi/settings.json` could
  set `piCommand` and so choose the executable the Pi adapter spawns; the Pi
  edit-snapshot root followed the cwd the agent reported; Codex gateway
  authentication ignored `:gateway_auth`.
- 1.x-only items: the DSL success path and the deprecated `Server.Tools`
  normalizer `inspect/1`ed arbitrary handler terms into tool results, and the
  client spawned an unbounded handler process per server-initiated request
  (now bounded by `:max_server_requests`, default 256).
- The ZCode `session/list` error path (arbor_acp#7), previously left out.

**Behavior change**: handlers returning terms the protocol cannot carry now
produce a fixed error text (the shape is logged server-side); the project
`piCommand` setting is ignored; Codex gateway authentication requires
`adapter_opts[:gateway_auth]` and an https or loopback `baseUrl`.

| Fix | Origin | 1.x commit |
| --- | --- | --- |
| Workspace confinement, Pi executable selection, Codex gateway opt-in | arbor_acp#11 (`f810383`, `7e4d929`) | `c4d2867` (#102) |
| Tool-result `inspect/1` fallbacks; concurrent server-request cap | review, 1.x only | `7d889bc`, `9da1170` (#103) |
| AdapterBridge crash on bare translation errors | arbor_acp#12 (`336ca66`) | `8d9df01` |

## Qualification and publication

Run maintenance CI and adapter/protocol/security regressions on this source.
Check documentation and package contents; install the built archive into a
clean consumer and assemble a release against the unchanged application name.
Only after review and passing CI should the maintenance PR be merged and a
fresh `v1.7.x` tag/package published. Publishing needs a user-owned terminal
for any Hex 2FA prompt. Keep the v2 RC and stable-release gates independent.
