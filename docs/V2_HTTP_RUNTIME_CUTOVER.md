# Runtime-only HTTP mounts and explicit standalone owners

Every v2 `HttpPlug.init/1` mount requires a named Runtime, local runtime root PID
or `Runtime.Ref`. Named mounts can compile before their root starts; an
unavailable endpoint fails closed at request entry. A retired named mount or
captured reference raises the existing `RuntimeWriter.AdmissionError` before
borrowed response IO; the library does not attempt uncharged fallback IO.
A newly configured unavailable `Runtime.Ref` is rejected at mount initialization. `call/2` validates options
again, so supplying a prepared map cannot re-enable a handler-only mount.
The existing public Plug and standalone module signatures remain available.

```elixir
children = [
  {Arbor.MCP.Server.Runtime,
   name: MyApp.MCPRuntime, handler: MyApp.Handler, handler_args: [],
   transport: :mounted_http}
]
# In a router borrowing its host endpoint:
forward "/mcp", Arbor.MCP.HttpPlug, runtime: MyApp.MCPRuntime
```

Mounted requests share the already initialized Scheduler and handler state.
There is no per-POST MessageProcessor, handler initialization or fallback to a
global session/replay/subscription owner. Host/origin checks precede ordinary
request admission; validated session IDs and required modern method/tool headers
are checked before a callback can commit handler state. Invalid or duplicated
session headers retain HTTP 400; missing sessions remain 404, typed session
capacity 503 and duplicate/request-ID capacity 429. A handler initialization
version inconsistent with its HTTP era cannot commit initialization state or a
successful output. Failed initialization retains its existing HTTP error shape.

The retired mount keys are `handler`, `handler_args`, `handler_call_timeout`,
`server`, `session_manager`, `session_store`, `subscription_registry`,
`replay_cache`, `sse_enabled` and `use_sse`. They raise configuration errors,
even when a runtime is also present. Configure handler/initial arguments,
`request_timeout_ms` and service descriptors on the Runtime. Mount
`handler_opts` retains static, function and MFA resolution as bounded request
`Context.current().application_context`; it does not reinitialize the handler or extend
the HTTP entry cutoff. Legacy `legacy_http_sse` aliases and wire identifiers
remain separate from those retired options.

Mount filter and publication hooks retain their existing option names and
arities: `authorize_subscription_filter/2` and
`authorize_subscription_publication/3`. The root service authorizer runs first;
the mount can only narrow its allowed filter and must independently authorize
publication. A root denial never invokes the mount hook. The four mount caps
`subscription_max_queue`, `subscription_max_message_bytes`,
`subscription_max_queue_bytes` and `subscription_max_lifetime_ms` are finite
positive integers and clamp to the root service caps. No mount can broaden root
policy or renew the listener's captured entry-time cutoff. Listener delivery
still retains its physical IO credit until the existing actual receipt/ACK.

Package startup removes eight implicit standalone server owners:
`Server.ReplayCache.ETS`, `Tasks.Store.ETS`, `Server.Subscriptions`,
`HttpPlug.SessionRegistry`, `Server.Cancellation`, `SubscriptionRegistry`,
`SessionManager` and `ProgressTracker`. All remain exported for deliberate host
supervision; runtime-backed servers resolve addressed services instead. For
example, an application intentionally using the standalone SessionManager facade
can supervise `{Arbor.MCP.SessionManager, []}`. There is no implicit compatibility
mode. Package-wide client/security/reliability facilities and standalone DETS
path-claim authority remain application-owned; runtime stop never adopts or
stops a mounted host listener.

This is a reviewed implementation checkpoint. Its private focused selection
passed on all three captured toolchains, using actual BEAM Runtime roots and
request-owned fake Plug IO. It asserts fresh application startup has no implicit
server owners and preserves session isolation, three durable/two live
publication counts, root+mount denials/byte limits, and native callback semantics
without HTTP headers. The actual legacy Client selection passed on both supported
toolchains, including borrowed listener survival after runtime stop and exact
listener cleanup. Those private receipts do not qualify a sealed normal package
graph. Canonical checkpoint `27f81a1` passes fresh normal compilation, formatting
and 543 combined cases on all three captured toolchains, plus 27 actual HTTP
wire/Client cases on both supported toolchains. Supported strict Credo and normal
Dialyzer pass; the unfiltered warning census retains 72 current/66 minimum warnings
with none in the 12 changed production paths and no added filters. A failed
minimum wire run overlapped a dependency rebuild; its serial repeat passes with
unchanged source, deadlines and stable selected Cowlib bytes. Bounded reverse
integration is now committed at `1284440`: 636 combined cases pass all three
captured toolchains and 40 HTTP wire/Client cases pass both supported toolchains.
The later followups are committed at `e284fee`. Their immediately preceding
qualified snapshot passes 671 cases with WAE/full formatting on all three,
50 HTTP wire cases and supported quality/docs gates on both supported toolchains.
Its full current rerun passes 5,344 tests plus doctests/properties; 13 actual SDK
stdio/HTTP cases pass both with no skips. The only later change in that batch
restores the conformance fixture's original 150 ms progress workload. These
receipts retain strict initialization/version fences and the original shutdown
cutoff. Legacy JSON progress preserves final JSON responses and exact session
authority, with actual ordered-progress conformance now passing. Validated
methodless OAuth responses preserve full ServerGuard and custom mapping; actual
OAuth wire remains pending. Stable server conformance reports 38/1 on both,
with the published version-header mismatch still open. Stable client 218 and
modern server 149/client 387 cases pass both supported toolchains.
Full combined CI, final authenticated wire/conformance, compiled API,
platform/installed consumers, same-runner performance and the 48-hour final RC
qualification remain gates. See [current release status](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/V2_RELEASE_PLAN.md).
