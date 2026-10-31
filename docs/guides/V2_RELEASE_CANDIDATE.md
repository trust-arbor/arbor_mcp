# Testing the ArborMCP and ArborACP release candidates

The current candidate train uses independent version lines. Versioned install
examples and source links apply after matching Hex releases and tags are published. The original four `2.0.0-rc.1` packages are retired; their archives and
tags remain available:

| Package | Replacement candidate | First stable target |
| --- | --- | --- |
| ArborMCP (`arbor_mcp`) | `2.0.0-rc.7` | `2.0.0` |
| ArborRPC (`arbor_rpc`) | `1.0.0-rc.4` | `1.0.0` |
| ArborACP (`arbor_acp`) | `1.0.0-rc.5` | `1.0.0` |
| ArborACP adapters (`arbor_acp_adapters`) | `1.0.0-rc.5` | `1.0.0` |

The versions below are prepared for coordinated publication and verification
through ordinary Hex installation and assembled-release probes. Start with the
[v1-to-v2 migration guide](MIGRATING_V1_TO_V2.md). Stable qualification and the
final continuous 48-hour soak remain incomplete.

## Install the packages your application uses

ArborMCP requires Elixir 1.17 and Erlang/OTP 27 or newer. The OTP minimum is
needed for protocol output encoding and is independent of the Elixir version.

For an MCP application, replace `ex_mcp` with:

```elixir
{:arbor_mcp, "== 2.0.0-rc.7"}
```

ACP applications use `{:arbor_acp, "== 1.0.0-rc.5"}`. Add
`{:arbor_acp_adapters, "== 1.0.0-rc.5"}` when using the bundled vendor adapters.
`arbor_rpc` is transitive; declare it directly if your code calls `Arbor.RPC.*`.
Exact versions make a downstream RC report reproducible. Commit the resulting
lockfile, and use normal Hex resolution without the local package path overrides.

## Candidate scope and validation

Use the owning tag’s CI, source-archive and publication receipts for the current
payload. Earlier dated checkpoints below do not qualify later source changes.

The package split, `Arbor.MCP.*` / `Arbor.ACP.*` namespaces, optional adapter
bundle and full server runtime/scheduler redesign are included. Client/Server are
the canonical MCP entrypoints; ACP uses Client/Agent. The existing DSL remains,
with stricter diagnostics. Spark and further performance work are deferred.

MCP Client adds bounded `all_tools`, `all_resources`, `all_resource_templates`
and `all_prompts`; ordinary listing still returns one complete Response page.
Pagination shares one total deadline and finite page/item/byte limits. ACP
`Client.prompt/4` now returns the peer JSON result unchanged. Callers using the
original RC's synthesized `result["text"]` must use `prompt_text/4`, which returns
`{:ok, %{result: peer_result, text: text, truncated?: boolean}}`. Check truncation;
collection is bounded and excludes thought chunks. `Client.with_connection/2,3`
provides finite startup and cleanup with explicit retained outcomes on cleanup
failure. See the [migration guide](MIGRATING_V1_TO_V2.md) for complete contracts.

Development builds after the original RC use revision tokens for atomic
output-ledger updates. This changes the internal ledger table layout: drain and
stop live MCP runtimes before loading the new code, then start fresh runtimes.
Use the same cold-restart procedure when rolling back.

The October 8 source checkpoint passes supported/latest MCP and ACP CI, RPC's
supported/native matrix, strict docs, four-package archive/source checks and
installed/compiler-free assembled-release probes on minimum/current toolchains.
The probes exercise the new pagination, scoped ACP connection and text APIs.
MCP's full strict checkpoint passes 5,445 tests, 20 doctests and 34 properties;
core ACP passes 387 tests; adapters pass 1,479 tests. Six pinned official ACP
TypeScript SDK 1.4.0 interop tests pass. Existing exclusions and source identities
are recorded in the
[qualification assessment](https://github.com/trust-arbor/arbor_mcp/blob/6c32d32de623962cef0322b2763068c2965980b6/docs/V2_RELEASE_ASSESSMENT.md).
The [release checklist](../RELEASING.md) tracks remaining stable gates.

These checks qualify selected source/archive payloads. Published archive
checksums and ordinary Hex installation were independently
verified after publication.

ArborMCP `2.0.0-rc.3` replaces `2.0.0-rc.2` with dependency security floors and
one OAuth fix; the other three packages remain at `1.0.0-rc.1`. It requires
`decimal` `>= 3.1.2` and Bandit `~> 1.13 and >= 1.13.1`. Owned Bandit listeners
now qualify exact Bandit `1.13.1` and Thousand Island `1.6.0`, so hosts that
pinned `1.12.5`/`1.5.0` for an owned listener must update both pins. OAuth
requests send the `resource` parameter exactly as protected resource metadata
publishes it. The public API is unchanged from `2.0.0-rc.2`.

ArborMCP `2.0.0-rc.4` replaces `2.0.0-rc.3` with a security fix for
handler-process request cancellation (GHSA-22m7-hr37-pxg3).
`Arbor.MCP.MessageProcessor` now limits `notifications/cancelled` to requests
from the same HTTP session or authenticated principal, and bounds the table
it keeps. Runtime-mounted servers were not affected. The public API is
unchanged.

ArborMCP `2.0.0-rc.5` replaces `2.0.0-rc.4` with TLS trust fixes.
- **Fail closed:** the legacy HTTP+SSE transport, OAuth metadata and JWKS
  fetches, and remote JSON Schema fetches passed no CA certificates, so Mint
  fell back to the `castore` bundle when the OS trust store could not be
  loaded. They now fail closed like other HTTPS requests.
- **CA options:** those connections now accept CA certificates:
  `MetadataFetcher`'s `:cacerts`, schema `network_refs: [cacerts: ...]`, and
  `security: %{tls: ...}` on `transport: :sse`.
- **`verify_none`:** `verify: :verify_none` no longer loads the trust store.

The public API only gains options; the changelog lists the behavior changes.

ArborMCP `2.0.0-rc.6` replaces `2.0.0-rc.5`. Servers handle the requests on a
connection concurrently, as the other MCP SDKs do. The client gains response
caching, progress-reset timeouts and output-schema checks, and servers gain
local JWT checks, cache hints and middleware. It requires ArborRPC
`~> 1.0.0-rc.3`, whose subprocess close gives a stdio server `:eof_grace` to
exit before SIGTERM, and Bandit `~> 1.14`, for that release's advisories. A
client's `logging/setLevel` no longer changes the host's global Logger level.
Seven changes can break existing code; the "Upgrading from 2.0.0-rc.5" section
below explains each.

ArborMCP `2.0.0-rc.7` requires patched Bandit `>= 1.14.1` and replaces
`2.0.0-rc.6` with request forwarding and
manual MRTR controls, progress delivery, provider-owned authorization,
validated runtime options, typed startup errors and corrected HTTP request
retirement and tool-list cache ordering. Host/schema/JWT validation and
pre-registered OAuth credential binding are hardened. It requires ArborRPC
`~> 1.0.0-rc.4`.

ArborACP and adapters `1.0.0-rc.5` include the ACP SDK 1.9 protocol-1
MCP-over-ACP extension, asynchronous handler work and bounded drop notices.
Claude uses managed session processes and private connection homes by default;
Codex uses a private connection home and keeps canonical workspace bindings.
Pi uses private child homes. Caller-owned homes are retained. See the owning
package changelogs for compatibility options and the exact workspace rules.

Earlier credential-free CLI lifecycle checks do not qualify live model turns.
No completed continuous 48-hour final-candidate soak is claimed.

The latest continuous attempt stopped after about 50 minutes when the test
harness exceeded the documented request-ID capacity of one persistent MCP peer
and expected a successful response. All three native child cleanup receipts
were confirmed, but the MCP BEAM lane did not confirm its public cleanup path.
The stable 48-hour qualification remains open.

## Upgrading from 2.0.0-rc.6

- Bandit users need `~> 1.14 and >= 1.14.1`; owned listeners qualify exact
  Bandit `1.14.1` with Thousand Island `1.6.0`. Update explicit 1.14.0 pins.

- Direct callers of `Authorization.JWT.validate_claims/2` and
  `verify_and_validate/3` must provide the expected `:aud`; omission returns
  `{:error, :missing_expected_audience}`. Signature-only verification is unchanged.
- Pre-registered OAuth credentials require an exact `credential_issuer` binding.
  Authentication providers own the Authorization header when configured.
- Client startup errors retain structured reasons in their established error
  envelopes. Update callers that previously matched their string representation.
- Runtime constructors reject unknown option names. Configure `mrtr` and
  `request_state` on the runtime so startup validates them consistently.
- Tool arguments preserve a caller-provided string `"_meta"` entry on every
  transport; request metadata is injected only when that entry is absent.

The [changelog](../../CHANGELOG.md) records all changes and the transport-specific
contracts. The next section retains the earlier rc.5-to-rc.6 migration guidance.

## Upgrading from 2.0.0-rc.5

ArborMCP `2.0.0-rc.6` makes servers handle the requests on a
connection concurrently, as the other MCP SDKs do, and lets the caller decide how
long a request runs. Seven changes can break existing code. The
[changelog](../../CHANGELOG.md) lists the rest, including the client changes.

### Request callbacks no longer change handler state by default

A server now runs up to 64 callbacks at once (`execution: :stateless,
max_concurrency: 64`). `init/1` and `handle_initialize/2` can still set up
handler state, and initializations commit one at a time. Every other callback
gets a snapshot of that state and must return it unchanged: tools, resources,
prompts, completion, logging, subscriptions, and custom `handle_call/3` and
`handle_cast/2` reached through `Arbor.MCP.Server.call/3` and `cast/2`.

A callback that returns a changed state fails its request. The peer receives
JSON-RPC error `-32603` with `%{"type" => "invalid_handler_state"}`, and the
server logs a warning naming the handler the first time:

```text
[warning] MyApp.MCPServer returned a changed handler state from a callback that
may not change it, so the request failed. ...
```

To keep the previous behavior, start the server with `execution: :stateful`.
Callbacks then run one at a time, in arrival order, and each commits the state
it returns:

```elixir
# Supervised runtime, for example mounted in Phoenix
{Arbor.MCP.Server.Runtime,
 handler: MyApp.MCPServer, transport: :mounted_http, execution: :stateful}

# Plain handler or stdio server
Arbor.MCP.Server.start_link(handler: MyApp.MCPServer, transport: :stdio, execution: :stateful)

# DSL module
MyApp.MCPServer.start_link(transport: :beam, execution: :stateful)
```

To run concurrently instead, keep the changing data where concurrent callbacks
can share it, such as a GenServer, an Agent, an ETS table or your database, and
return the state unchanged:

```elixir
@impl true
def init(_args) do
  {:ok, counter} = Agent.start_link(fn -> 0 end)
  {:ok, %{counter: counter}}
end

@impl true
def handle_call_tool("increment", _args, state) do
  count = Agent.get_and_update(state.counter, &{&1 + 1, &1 + 1})
  {:ok, %{content: [%{type: "text", text: Integer.to_string(count)}]}, state}
end
```

`execution: :stateful` accepts only `max_concurrency: 1`; raise
`max_concurrency` on a stateless server instead. A stateful server still answers
`ping` while a callback runs.

### Responses can arrive in completion order

On a stateless server, a slow tool's response can follow the response to a later,
faster request, on every transport including stdio. Each response carries its
request's id, JSON-RPC allows any order, and ArborMCP's client and the official
SDKs match responses by id. A hand-written client or test that reads responses
in order must match them by id instead. A stateful server still answers requests
in arrival order, except `ping`, which it answers at once.

### The server's request deadline defaults to one hour

`request_timeout_ms` was 10 s, so a tool that ran longer failed with
`handler_timeout` while the client was still waiting. It is now one hour, as a
safety net: the caller's timeout decides how long work runs. ArborMCP's client
cancels a request when it stops waiting, with `notifications/cancelled`, or over
modern Streamable HTTP by closing the request's connection. Set
`request_timeout_ms` to keep a tighter server-side bound. A stdio server's
default EOF drain is unchanged at 15 s.

### Invalid DSL tool arguments return a tool error

A DSL tool called with arguments that fail its schema used to answer with a
`-32602` protocol error and no details. It now returns a successful result with
`isError: true` and text such as `Input validation error: ...` naming the failing
fields and rules, as SEP-1303 and the other MCP SDKs do, so a model can correct
its call. Rejected values are never included. Code that matched the error tuple
from `Client.call_tool/4` now receives
`{:ok, %Arbor.MCP.Response{is_error: true}}`.

### Resource-template values are percent-decoded

`resource_template "files://{name}"` used to hand its `read` function the
value as it appeared in the URI, so `files://a%20b` gave `"a%20b"`. Values are
now percent-decoded (`"a b"`), and a handler that decoded them itself would
decode twice. Templates also match every RFC 6570 operator now: `{+path}` and
`{#frag}` span slashes, and `{/a,b}`, `{.ext}`, `{;params}` and `{?query}` work.
As in Python's MCPServer, a decoded value doesn't match if it contains a NUL
byte, climbs out of its starting point with `..`, or is an absolute path; the
read then fails as an unknown resource.

### Elicitations are checked in both eras

An elicitation a handler asks for in an `input_required` result is now checked
against the protocol's ElicitRequest schema on modern connections too, as it
already was on legacy ones. A form elicitation's `requestedSchema` must be an
object with `properties`, each a string, number, integer, boolean, or single- or
multi-select enum field. One that isn't, most often `%{"type" => "object"}` with
no `properties`, fails the call with `-32602` and
`%{"inputRequestId" => id, "method" => "elicitation/create"}`, and the client
is never asked:

```elixir
# Fails the call:
%{"message" => "Name?", "requestedSchema" => %{"type" => "object"}}

# Fits, with fields or without:
%{
  "message" => "Name?",
  "requestedSchema" => %{
    "type" => "object",
    "properties" => %{"name" => %{"type" => "string"}}
  }
}

%{"message" => "Continue?", "requestedSchema" => %{"type" => "object", "properties" => %{}}}
```

### Owned Bandit listeners need Bandit 1.14.0

Bandit 1.14.0 fixes eleven HTTP/1, HTTP/2 and WebSocket advisories that are open
against 1.13.1, so ArborMCP now requires Bandit `~> 1.14`. An owned Bandit
listener qualifies exact Bandit `1.14.0` with Thousand Island `1.6.0`; with
the `1.13.1` pin, startup returns `:unsupported_owned_bandit_constructor`.
Change the pin to `{:bandit, "== 1.14.0"}`. Bandit 1.14.0 also limits each
HTTP/2 connection to 500 concurrent streams and 262,144 bytes of headers by
default.

## Limits to exercise in downstream tests

- **JSON object member order:** object keys in protocol replies have no promised
  order. The OTP encoder can serialize an object in a different order without
  changing its values; compare decoded objects in downstream tests. Output
  validation and exact frame sizing still happen before handler state commits,
  and prepared output remains binary for existing transport and batch delivery.
- **Long-lived peers:** `Arbor.MCP.Server.HandlerServer` retains distinct request
  IDs for a peer connection, with `max_request_ids: 10_000` by default. New IDs
  fail with `request_id_capacity_exceeded` once full; duplicates remain rejected.
  Completion does not evict IDs. A replacement peer establishes a fresh scope.
  Choose a finite capacity and an application connection-lifecycle policy;
  callers must handle the capacity error.
- **Local-call overhead:** the October 6 comparison of MCP `0d831a7` and RPC
  `d2a6fcf` measured median BEAM ping at 315 µs versus 5 µs in v1.5, and a
  256 KiB BEAM echo at 928.5 µs versus 13.5 µs. Four paired rounds use the same
  runner and Elixir 1.19.5 / OTP 28.4.1 toolchain. These are sequential checked
  round trips, not saturated throughput or application latency promises.
  Profiling and targeted comparisons have been completed; further performance
  optimization is deferred in favor of library and integration testing. The
  measured costs still require a stable-release decision.
- **Output optimization:** a separate four-pair comparison of the same v2 source
  with the accounting and OTP JSON changes reduced median BEAM ping from
  359.5 to 304 µs and 256 KiB echo from 930 to 769 µs. Large echo improved in
  all four pairs; ping improved in three. These results measure both changes
  together, preserve the same output limits and do not establish v1 parity or
  real-application performance. BEAM delivery still uses native Erlang terms;
  JSON preparation validates protocol replies and frame size before state commit.
- **Native installation:** macOS/Linux source installation builds the RPC helper
  when a C17 compiler is available. Without one, installation warns and continues;
  HTTP/BEAM use remains available, while native subprocess operations return
  `:native_helper_unavailable`. Releases using subprocesses must include the built
  helper and need no runtime compiler. Native
  subprocess operations on Windows are unsupported.
- **Adapters:** vendor executables and their credentials are host-managed.
  Fixture and transcript tests do not replace testing the actual vendor version
  your application runs.

## What to report

Include all four package versions from your lockfile, Elixir/OTP and OS versions,
transport and listener choice, and a minimal reproduction. Exercise normal
startup/shutdown, cancellation, timeouts, sustained request volume, supervision
restarts, and application-specific tools/resources/prompts. For adapter failures,
include the adapter and vendor version. Remove credentials and sensitive tool
payloads from reports.

Stable promotion requires the accepted continuous soak, a decision on the
measured performance costs, clean registry-based installation and the remaining
release checks. The RC version is an explicit opt-in to test this migration.
