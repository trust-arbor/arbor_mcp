# ExMCP 1.8 maintenance release

ExMCP 1.8.0 adds asynchronous ACP handler work and session-update drop notices,
along with the merged MCP transport and interoperability fixes since 1.7.3.
These compatible additions make this a minor release. The package remains
`ex_mcp`, the OTP application remains `:ex_mcp`, and public modules remain under
`ExMCP.*`, including the bundled ACP adapters.

After publication, applications can select the new minor series with:

```elixir
{:ex_mcp, "~> 1.8"}
```

An existing `~> 1.0` requirement also permits 1.8.0. Review and commit the updated
lockfile. Elixir 1.17 / OTP 27 remain the minimum. Installation requires no native
C compiler. The [maintenance policy](MAINTENANCE_POLICY.md) continues to apply;
no 1.x end-of-support date has been set.

## New ACP options

Permission, file, terminal and elicitation handlers can return
`{:async, work, state}` to commit handler state before running a zero-arity
function outside the handler mailbox. The work returns the operation result,
without handler state. Cancellation, the owning request deadline, disconnect
and runner shutdown stop the worker. Existing synchronous callback returns keep
their ordering. See [asynchronous request work](ACP_GUIDE.md#asynchronous-request-work).

Every dropped session update emits telemetry. Event listeners can opt into
coalesced `{:acp_session_updates_dropped, session_id, count}` messages with
`notify_update_drops: true`; handlers can implement
`handle_session_updates_dropped/3`. Notices obey the existing queue limits and
recover without requiring another update. Session close/delete and disconnect
retire their counts. See the [event listener contract](ACP_GUIDE.md#event-listener).

## MCP transport changes to review

- Legacy HTTP POST streams dispatch notifications and server requests while
  waiting for their response. Concurrent authentication challenges share one
  refresh, preserve the live stream consumer and respect the request deadline.
  Settled requests retire their POST workers, including queued authentication
  retries, and stale results cannot update a later connection.
- Legacy GET notifications reach the owning session, replay through reconnect
  gaps and use the configured session manager. A refused GET stream can leave
  the session operating through POST.
- Progress and log notifications on connection streams reach client handlers.
  Tool header discovery covers cursor pages within one deadline and keeps
  concurrent listing generations separate.
- HTTP authentication-provider initialization errors fail the connection through
  the existing error envelope; non-atom reasons and exception details are
  redacted. A provider runs inside the client process and must not call back into
  that client, directly or indirectly.
- Under `:prefer_modern`, a stdio peer that exits or stays silent during discovery
  can be replaced once and initialized through the legacy handshake. Replacement
  and reconnect wait for confirmed shutdown. Malformed protocol output does not
  trigger this fallback, and `:modern_only` never falls back. The implicit
  establishment budget is now 20 seconds only for stdio clients that open with
  discovery; explicit budgets and clients that open with initialize are unchanged.
- HTTP event-stream selection respects Accept quality values and quoted
  parameters. Nested capabilities and omitted JSON-RPC `params` are handled
  consistently across the applicable transports.

The release also requires patched JOSE `>= 1.11.13`. The
[changelog](../CHANGELOG.md#180---2026-10-31) records exact return shapes,
deadlines, accepted behavior changes and backport provenance.

The [1.x backport tracker](https://github.com/trust-arbor/arbor_mcp/issues/113)
records remaining maintenance work. This release includes the changes already
merged into the maintenance branch; individual pending backports retain their
own review and regression requirements.
