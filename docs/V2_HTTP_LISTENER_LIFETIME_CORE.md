# HTTP listener lifetime capability core

This private prerequisite is based on canonical `c1ae91b`, retained HTTP twelve paths, convergence thirteen paths, and the exact future-control seven-path packet (`8008a757`). It does not yet route mounted `subscriptions/listen` or publication through Gateway/Controller. Its tests exercise installed runtime actors and fake borrowed writer processes without repository test helpers, sockets, or native helpers.

## Separate lifetimes

The installed entry facade captures the original monotonic entry timestamp before body/auth/protocol processing. It derives the ordinary request cutoff as before and captures one potential listener cutoff from the root-owned subscription service's configured `max_lifetime_ms`, default one hour. The potential cutoff is retained in the existing charged writer row; it is not recomputed after body parsing or for each event.

Only the actual installed Gateway can call `HTTPWriterRegistry.establish_listener(binding, admitted_token, options)`. It requires a live matching scalar Admission reservation, exact runtime generation, owner and writer scope, original request cutoff, and an unused entry capability. Its `:deadline` option only shortens the potential cutoff. `:endpoint` and optional trusted `:identity` are bounded, detached metadata. A failed metadata admission leaves ordinary entry authority unchanged. Successful establishment returns opaque `HTTPListenerBinding`; registration includes a distinct nonce, so an old capability cannot address a later binding even when a host reuses a writer PID or wire request ID.

`HTTPListenerBinding.validate(listener, runtime)` checks the immutable listener cutoff, installed proxy/Gateway, cohort, actual writer/root lifetime and registration nonce. Pending setup remains bounded by the original request cutoff; a successful immutable setup outcome can retain listener authority through its original listener cutoff. Failed setup cannot do so. Ordinary `HTTPWriterBinding.validate` and service-invocation validation do not accept the listener phase. Listener establishment grants no renewed callback, store or publication-source authority.

## Accounting and physical IO

The existing `max_http_writers` and `max_http_writer_metadata_bytes` bound the combined entry/listener registration count and term metadata. Capture and establishment charge their whole retained row before CAS publication; there is no second unbounded listener-control registry. Existing bounded CAS attempts and original request budget apply to establishment. Endpoints/principals/tenants are copied before retention.

Listener IO uses the existing `max_http_io_frames`, `max_http_io_bytes`, and `max_http_io_frame_bytes` aggregate liability budgets, one entered frame per actual writer, and coalesced token-only wake slots across binding lifetimes. The established listener cutoff affects only target IO admission. A future Controller route must separately validate the publication source before preparing/claiming IO; possession of a target capability does not authenticate an event source.

Logical retirement, listener expiry, proxy/cohort replacement, and root stop cannot release entered IO credit or kill a borrowed host process. Only its actual completion receipt or writer `DOWN` releases that liability. Root stop reports the existing typed unsettled frame/byte result while such liability remains. Listener expiry or reset can reject future frames while the old frame remains charged.

Subscription Mailbox/Delivery count and byte budgets remain separate bounded budgets; this core does not claim the runtime output ledger's limit covers all listener queues or host process memory. Their aggregate pressure qualification belongs to mounted subscription integration.

## Next integration

Gateway must validate the unchanged modern method/filter/authorization rules, establish this lifetime once while original entry admission is live, and create an addressed runtime-owned listener. Registry/Listener cleanup must identify the opaque registration nonce rather than only writer PID and wire ID. The listener's detached Mailbox loan stays charged through OutputController until actual borrowed IO completion. A callback publication carries its original Admission token/phase/scope/cohort/deadline and retained endpoint/lease/trusted identity independently of the target listener lifetime.

Anonymous public notifications retain the existing authenticated application-callback fanout within exact runtime/cohort/endpoint and configured filter/publication authorization. Anonymous cross-POST cancellation remains advisory. Anonymous sources cannot satisfy trusted-identity or private lease listeners; trusted sources remain identity matched unless explicit configured publication authorization permits the topic. Addressed legacy resource publication must commit an accepted replay append once and then let GET replay/poll deliver it, without reconnect republishing or rollback after durable acceptance.

Mounted listen/publication, real socket ACK/keepalive/completion, original callback cancellation/expiry negatives, mixed identity scopes, bounded active-listener pressure, and existing official SDK behavior remain qualification gates. The core alone makes no claim of complete HTTP convergence or legacy API retirement.

## Qualification of this standalone prerequisite

The exact frozen core passes 48 pure lifetime/installation/writer regressions on Elixir 1.17.3/OTP 27.0.1, 1.19.5/OTP 28.4.1, and 1.20.3/OTP 29.0.5. The cases include same-PID re-registration with stale capability rejection, original one-hour and shortened lifetimes, aggregate metadata pressure, held physical IO through expiry/cohort replacement/root stop, and borrowed owner survival. All three compile with warnings as errors and pass full formatting. Current strict Credo runs 64 checks across 729 files without issues; ExDoc succeeds. Normal supported Dialyzer runs report 72 current and 66 minimum existing filtered warnings, with no filter changes. Direct unfiltered native audits report those same totals and zero warnings in the three changed production modules.

This is source-only prerequisite evidence, not a full application suite or physical mounted subscription/SDK proof. Gateway, Controller, Origin and subscription routing remain unchanged in this packet.

## Canonical integration qualification

All five core files merge exactly onto `d3ce77b`, retaining the canonical
Admission pressure/materialization and queued-cancellation changes. The merged
source passes the same 48 pure cases on each minimum/current/newest toolchain,
with warnings-as-errors test and production compilation on all three. Supported
formatting, current strict Credo (741 files, 64 checks, zero issues), ExDoc and
normal minimum Dialyzer pass; its 66 existing filters are unchanged.

The independent owner-readiness fixture correction is included in the same
checkpoint. Its exact corrected case passes against the merged graph on all
three toolchains. This observation wait does not change a production cutoff.
The preceding `d3ce77b` CI finishes eleven jobs green and one newest-toolchain
fixture failure; a fresh checkpoint run is required. No full application suite,
physical subscription or installed SDK qualification is claimed for this
unwired core.
