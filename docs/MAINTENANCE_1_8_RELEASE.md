# ExMCP 1.8 maintenance release

ExMCP 1.8.1 includes asynchronous ACP handler work and session-update drop notices,
along with the merged MCP transport and interoperability fixes since 1.7.3.
These compatible additions make this a minor release. The package remains
`ex_mcp`, the OTP application remains `:ex_mcp`, and public modules remain under
`ExMCP.*`, including the bundled ACP adapters.

The `v1.8.0` tag records an unpublished preparation. Version 1.8.1 includes
those changes and the remaining backports from tracker #113; the earlier tag
is preserved.

After publication, applications can select the new minor series with:

```elixir
{:ex_mcp, "~> 1.8"}
```

An existing `~> 1.0` requirement also permits 1.8.1. Review and commit the updated
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

- Circuit-breaker stdio reads retain their port owner. Discovery skips preceding
  notifications within its original deadline, including a continuous stream of
  notifications. Unsupported-version HTTP errors advertise the mount's enabled
  revisions in preference order.
- Provider token errors refuse new POSTs and request-owned streams before
  sending; nil tokens clear earlier Authorization, and a provider owns that
  header. Callback failures and non-atom error details are contained and
  redacted. A stream connection that never opens returns a transport error with
  its connection failure as the reason. `ExMCP.Client.delivery_outcome/1`
  classifies that error as `:not_sent`; the error itself is not the atom
  `:not_sent`. It is not retried as an ambiguous stream break.
- Optional handler defaults now answer `-32601` for unserved methods. Modern
  HTTP uses status 404 for that protocol error, including a stream's first
  response; the client reads a matching JSON-RPC error from it. Advertised
  capabilities retain empty-list/completion or named-not-found semantics.
  SSE responses omit HTTP/2-forbidden connection headers.
- Legacy session expiry fails pending work and reconnects without replaying
  application requests. The reason is `{:session_expired, ...}` inside the
  existing 1.x error envelope; code matching the earlier raw HTTP 404 reason
  should handle this classification. A rejected configured session id is
  retried once without it, within the establishment deadline. Delayed failures
  from a replaced session cannot end its replacement. An expired GET for the
  replaced session leaves the current session available through POST.
- The HTTP `request_timeout` cap retains its 30-second default. Longer operations
  need both a larger transport cap and caller timeout; the earlier budget wins.

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

Session expiry keeps the operation's existing 1.x error envelope. The normal
client return shapes are:

| Operation path / format | Return shape |
| --- | --- |
| Synchronous HTTP, default struct format | `{:error, %ExMCP.Error.TransportError{reason: {:session_expired, detail}}}` |
| Synchronous HTTP, `format: :map` | `{:error, %{type: :transport_error, reason: {:session_expired, detail}}}` |
| Triggering legacy SSE async POST, either format | `{:error, {:transport_error, {:session_expired, detail}}}` |

For a POST, `detail` is `{:http_error, 404, body}`. For pending work failed by
the current session's GET expiry, it is `{:sse_error, {:http_error, 404}}`.
Handle the nested reason appropriate to the operation path; a bare
`{:error, {:session_expired, detail}}` is not the normal client return.
With `reconnect: false`, the client stays disconnected after expiry.

The release also requires patched JOSE `>= 1.11.13`. The changelog records
[the remaining tracker fixes](../CHANGELOG.md#181---2026-10-31) and
[the earlier 1.8 preparation changes](../CHANGELOG.md#180---2026-10-31),
including return shapes, deadlines, behavior changes and backport provenance.

The [1.x backport tracker](https://github.com/trust-arbor/arbor_mcp/issues/113)
records the completed maintenance backports included in this release. The
transport guide describes the exact error and timeout contracts.
