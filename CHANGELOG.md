# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### 2.0.0-rc.2 (unreleased)

- Add explicit `Client.all_tools/2`, `all_resources/2`,
  `all_resource_templates/2` and `all_prompts/2`. Collection follows opaque
  cursors within one deadline and finite page/item/byte limits, rejects cycles
  and malformed pages, and does not report partial lists as complete. Ordinary
  listing methods retain their single-page Response and metadata.
- Correct Client protocol-result typespecs to include the default Response
  struct and explicit map format. Pagination requests retain their original
  absolute deadline through multi-round request handling.
- Disable protocol consolidation in test builds so test-only JSON encoders
  take effect and the full suite can run with warnings treated as errors.

- Support native BEAM descriptor/content keys in Response accessors without JSON
  conversion or atom creation; preserve canonical string-key precedence and nulls.
  Explicit resource extraction also accepts native callback text fields.
- Consolidate public entrypoints in Client and Server. Add transport-aware Server
  startup/child specs, bounded stop and statistics; route DSL startup through the
  same constructor. Add explicit Client extraction helpers, scoped connectivity
  probe, tagged status/bang inspection and ClientConfig connections. Preserve root
  compatibility semantics and forward transport-specific ClientConfig options.
- Ship agent usage rules in Hex archives and ExDoc, with downstream UsageRules
  setup guidance and API-reference validation through the existing docs gate.
- Preserve complete Response wire fields, extensions, pagination and false/null
  presence in `to_raw/1`; remove unused `to_test_map/1`. Constructors emit `_meta`.
- Read standard resource `contents`, retain nontext results and offer explicit
  complete formats on facade conveniences. Normalized tool failures return a
  ToolError retaining the complete result; forward documented request controls
  and reject unsupported facade options.
- Keep local timeout classification as `{:error, :timeout}` in both formats.
  Runtime statistics return `{:ok, map} | {:error, reason}`; `stats!/1` provides
  explicit value-or-raise inspection. Add advanced Runtime types/specifications.

- Reject duplicate DSL parameters/arguments, repeated instructions or `use`
  options, unknown options, stray instructions and contextually ignored metadata
  at compilation with source diagnostics.
- Remove implementation bridges from Client, DSL, Result and Runtime facades;
  preserve documented constructors and explicitly document advanced Runtime
  operations. Cross-module implementation owners remain internal modules.
- Route top-level `disconnect/1` through bounded Client cleanup and propagate
  failures; `ping/2` reports unconfirmed cleanup. Preserve already-stopped
  idempotence and remove the inaccurate transport-fallback capability flag.
- Keep ArborMCP on 2.x while ArborRPC, ArborACP and its optional adapter bundle
  start independent 1.x release lines. Require ArborRPC `~> 1.0.0-rc.1`; update
  package preparation, CI and installed-version checks for independent versions.
- The original four `2.0.0-rc.1` packages were published on October 6. Existing
  versions and tags are preserved; retirement follows replacement publication.

- Compare output-ledger revision tokens during atomic updates to avoid repeated
  equality checks over retained reply data. Preserve generation fencing,
  lifetime and capacity accounting, deadlines and retry limits. Development
  builds after RC1 require a cold runtime restart when upgrading or rolling back
  because the internal ledger table layout changes.
- Use OTP's JSON encoder for prepared protocol output, preserving plain-value
  and UTF-8 validation, exact frame limits, retained-memory charges and binary
  output/batch interfaces. JSON object member order is unspecified; consumers
  should compare decoded objects rather than serialized key order.
- Avoid repeated closure traversal for freshly checked, function-free output
  metadata. Arbitrary scopes and metadata retain full accounting; charges are
  recomputed for the current term rather than cached.
- Preserve the ExMCP 1.x maintenance branch with backport and compatible
  minor-release policy; document cold restart, cutover and rollback for v2 consumers.
- Allow warnings-as-errors compilation in host applications using Ranch 2.x.
  Runtime-owned Cowboy listeners still require Ranch 1.8.1.
- Allow warnings-as-errors compilation when the optional Cowboy/Ranch stack is
  absent. Guarded listener calls preserve the same version and ownership checks.
- Allow compatible optional Bandit, Thousand Island and Ranch updates in host
  applications. Standalone owned listeners still enforce their qualified
  constructor versions; mounted host listeners use the host application’s graph.
- The original candidate published `arbor_mcp` `2.0.0-rc.1` under `Arbor.MCP.*`. ACP moves to
  `arbor_acp`, vendor adapters to optional `arbor_acp_adapters`, and shared
  subprocess/framing support to `arbor_rpc`.
- Route server transports through a supervised per-server Runtime with bounded
  scheduling, admission, output, cancellation and shutdown.
- Replace legacy HTTP endpoint wrappers with Runtime-backed `Arbor.MCP.HttpPlug`
  mounts and optional standalone listeners. Retire the old `Server.Tools` family
  and deprecated compatibility APIs.
- Add the [v1-to-v2 migration guide](docs/guides/MIGRATING_V1_TO_V2.md) and
  [RC testing notes](docs/guides/V2_RELEASE_CANDIDATE.md), including the documented
  request-ID capacity, native build requirements and open stable-release gates.
- Avoid redundant JSON validation and nil-control accounting work while retaining
  lifetime and capacity guarantees. Fixed scheduling costs remain measurable.

The following retained development notes were recorded before the package split.
Their `ExMCP.*` names describe the original APIs; use the migration guide above
for current owners and replacements. Published historical release sections are
unchanged.

### Fixed

- **Security:** `ExMCP.Authorization.ProtectedResourceMetadata.discover/2`
  dropped the document's `resource`, so the RFC 9728 §3.3 check could not be
  made and metadata naming another resource was used. It now keeps
  `resource` and top-level `scopes_supported` in the result and uses a
  document only when its `resource` names the identifier its well-known URL
  was built from (the requested URL for the path-specific document; the
  origin or the requested URL for the root document; scheme and host
  case-insensitive, default port and a trailing `/` ignored). A document
  that omits `resource` or names another resource is skipped;
  `{:error, {:resource_mismatch, expected: ..., actual: ...}}` or
  `{:error, {:invalid_metadata, "Missing resource"}}` is returned when none
  is usable, and an invalid `scopes_supported` is an error. **Behavior
  change:** a server whose metadata omits the REQUIRED `resource` is no
  longer accepted.
- **Security:** `ExMCP.Authorization.OIDCDiscovery.discover/2` took the
  first metadata document that fetched and checked its issuer afterwards,
  so a foreign-issuer document at the first well-known URL stopped
  discovery. Each document is now issuer-checked, and a mismatched one is
  skipped (RFC 8414 §3.3); the mismatch is reported only when no document
  names the issuer.
- `notifications/initialized` over HTTP carried the client's requested
  `MCP-Protocol-Version` (2025-11-25 by default) instead of the version the
  server selected, because the transport settled the version only after the
  handshake; a strict server that negotiated an older version rejected the
  session. This affected every legacy handshake, `:legacy_only` included.
- `ExMCP.Client` link handling. In push mode any non-normal `EXIT` from any
  linked process was taken for the transport's forwarder dying and
  triggered a reconnect that respawned a stdio server; every other `EXIT`
  was ignored, so a process linked to the client could crash without taking
  it down. Exits are now matched against the receiver and the transport's
  own links (`ExMCP.Transport.linked_processes/1`): an abnormal exit of a
  transport-owned process closes that transport and takes the
  transport-down path, and an abnormal exit of any other link stops the
  client, as it would stop a process that does not trap exits. **Behavior
  change:** a custom transport that links helper processes to the client
  without listing them in `linked_processes/1` now stops the client when
  one crashes.
- A stopping client now closes its transport in `terminate/2` (its
  starter's exit, `stop/2`, a linked crash), so a stdio server or HTTP
  session no longer outlives it. For a legacy HTTP session this sends the
  best-effort `DELETE` on stop, as `disconnect/1` already did. Closing is
  capped at one second (the `DELETE` included) on stop, on `disconnect/1`
  and after a transport crash, so a peer that stopped answering cannot hold
  `stop/2` or the client loop; `disconnect/1` previously waited up to the
  transport's request timeout. A crashed pull-mode receiver now also closes
  the transport before the client reconnects.
- Connection establishment is bounded. A host that accepted the connection
  and then answered nothing was bounded by neither `:handshake_timeout` nor
  `:era_probe_timeout`, because a synchronous HTTP POST (the probe, and the
  legacy handshake before an SSE stream exists) ran under the transport's
  30 s request timeout inside `init/1`. `:era_probe_timeout` now bounds the
  probe exchange and `:handshake_timeout` the initialize exchange, the send
  included, and the new `:establish_timeout` bounds the whole
  establishment; see Added. **Behavior change:** a legacy HTTP server that
  takes longer than `:handshake_timeout` (10 s by default) to answer
  `initialize` now fails with `{:error, :handshake_timeout}`, as the option
  was documented to do.
- A connection attempt that fails after opening its transport now closes it,
  so a stdio server that never answered is stopped instead of outliving the
  attempt and piling up across connection retries and reconnects. What is
  closed is the state the attempt reached, so an HTTP session opened by
  `initialize` (or by a failed `initialize` before a `:prefer_legacy`
  fallback) is ended with its `DELETE`, which gets up to one second of its
  own when the establishment deadline is what failed the attempt.
- A request whose caller had given up was still sent: a synchronous HTTP
  client sends from its own process, so a request queued behind a slow one
  went out after its caller's `GenServer.call` timed out, or after the
  caller exited. A request with an explicit `:timeout` now carries its
  caller's deadline, and the client answers a request whose deadline has
  passed, or whose caller is gone, with an `ExMCP.Error.TransportError`
  whose reason is `:not_sent` instead of sending it. A synchronous send is
  capped at that deadline, so the client is freed when the caller gives up
  rather than after the transport's own request timeout.
- A failed send kept the transport's reason only inside a message string,
  and the `:struct` format turned it into an `ExMCP.Error` with no reason at
  all. The `:map` format now returns
  `%{type: :transport_error, transport: ..., reason: term, message: ...}`
  (`message` unchanged); the `:struct` format returns an
  `ExMCP.Error.TransportError` carrying the reason. **Changed shape** for
  `:struct`-format callers of a failed send.
- An HTTP 404 or 405 answer to the modern `server/discover` probe now counts
  as legacy-fallback evidence, like 400, per MCP's backwards-compatibility
  guidance. `:modern_only` still never falls back, and 401, 403 and 5xx are
  still not evidence.
- The HTTP transport ignored a connection's own
  `security: %{trusted_origins: [...]}`: the SecurityGuard check read only
  the VM-wide `config :ex_mcp, :security`, so credentials to that origin
  were stripped and the default consent handler refused the request. See
  Added.
- Credentials no longer appear when a client's state is inspected, returned
  by `:sys.get_status/1`, or written to a crash report: request header
  values (an `Authorization` bearer, an API-key header of any name), OAuth
  tokens, auth configuration and client secrets, the session id, a stdio
  server's environment and command. `ExMCP.Client`,
  `ExMCP.Transport.HTTP` and `ExMCP.Transport.HTTP.LegacySSE` implement
  `Inspect`, and `ExMCP.Client`, `ExMCP.Transport.SSEClient` and the modern
  HTTP stream client implement `format_status/1`, so every log formatter,
  Erlang's included, gets the redacted state. Header names stay visible;
  of the client's start options only a known-safe set is shown.
  **Breaking for hosts that shipped their own implementation:** a
  `defimpl Inspect, for: ExMCP.Client` or `for: ExMCP.Transport.HTTP` in
  application code (for example Imp's `lib/imp/mcp/redacted_inspect.ex`)
  now redefines ExMCP's module `Inspect.ExMCP.Client` /
  `Inspect.ExMCP.Transport.HTTP`: compilation warns (and fails under
  `--warnings-as-errors`) and a release refuses the duplicate module.
  Remove that implementation when upgrading.
- `ExMCP.Transport.Stdio.receive_message/2` raised `ArgumentError` when the
  port had already closed; it now returns the server's exit waiting in the
  owner's mailbox.

- `ExMCP.ACP.AdapterBridge` now handles the documented
  `{:messages_and_reply_and_write, ...}` adapter translation on every request
  path, not only the session lifecycle. Returning it from `session/set_mode`,
  `session/set_model` or `session/set_config_option` raised a
  `CaseClauseError` in the bridge and killed the connection.
- Claude ACP adapter: `session/load` now clamps an inherited Auto mode the
  model cannot support, matching `session/new` and `session/resume`. It
  applied only the bypass policy.
- `ExMCP.ACP.AdapterEvents.content_chunk/4` accepts a map for `opts`, as its
  spec always said. A map raised `FunctionClauseError` in `Keyword.get/3`
  because `:meta` was read as a keyword list; keyword options are unchanged.
- Pi ACP adapter: when the Pi subprocess exits, pending control requests
  (such as `session/new`) are now failed in the order they were issued.
  Previously the order followed the internal `"group-N"` id strings, so
  requests could be reversed when N crossed a power of ten (`"group-1000"`
  sorts before `"group-999"`).
- HTTPS no longer hangs when the OS CA certificate store cannot be loaded.
  The HTTP transport and the OAuth HTTP boundary called
  `:public_key.cacerts_get/0`, which waits without a timeout; on macOS it runs
  `/usr/bin/security`, which can stall on the keychain (for example while the
  session is locked), blocking every HTTPS request. The OS store is now loaded
  with a deadline (`config :ex_mcp, :cacerts, os_timeout_ms:`, default 5s),
  and a failed load fails closed: HTTPS requests return
  `{:error, {:trust_store_unavailable, reason}}` instead of hanging, the
  failure is cached for `:failure_ttl_ms` (default 30s) so requests fail fast,
  and `[:ex_mcp, :cacerts, :os_load, :failed | :recovered]` telemetry is
  emitted. An opt-in `fallback: :castore` trusts the `castore` bundle during a
  stall instead; it is off by default because it lets anyone who can make the
  OS store unavailable change which CAs are trusted. When the OS store loads
  normally, the trusted CAs are unchanged. The transport also no longer loads
  the OS store when `tls: %{cacerts: ...}` is given.
- Claude ACP adapter: `capabilities/0` advertised `mcpCapabilities` `acp`,
  `http` and `sse` and ExMCP's BEAM transport, but `session/new`,
  `session/load`, `session/resume` and `session/fork` never attached their
  `mcpServers`: Claude Code is already running by then and takes MCP servers
  only at launch. The capabilities now advertise no MCP transport and set
  `mcpCapabilities._meta.ex_mcp.claude_sdk.sessionMcpServers` to `false`, and
  the adapter logs a warning when a session request names a server the launch
  options (`:mcp_servers`, `:mcp_config_path`) did not configure. Session
  servers are still accepted and not attached, so a client that sends its
  launch-configured servers again is unaffected. **Behavior change:**
  `ExMCP.ACP.Client` now refuses BEAM MCP servers for this adapter with
  `{:error, {:unsupported_capability, :mcp_beam}}` instead of dropping them.
- **Security:** Claude ACP adapter: `:mcp_servers` was JSON-encoded into the
  `--mcp-config` argument, so server credentials (HTTP `Authorization`
  headers, stdio `env`) were readable by other local users through `ps` and
  `/proc/<pid>/cmdline`. The adapter now writes the servers to a file only
  the current user can read (0600, in a new 0700 directory under
  `System.tmp_dir/0`), passes its path, and removes it when the adapter
  bridge exits. **Behavior change:** the command line carries a file path
  instead of JSON; Claude Code reads both the same way.
- Claude ACP adapter: `:mcp_servers` in any shape other than a map, such as
  an ACP-style `mcpServers` list, crashed the adapter bridge with a
  `FunctionClauseError` in `ExMCP.ACP.Maps.stringify_keys/1`. It now fails the
  connection with `{:error, {:invalid_option, :mcp_servers, message}}`, as do
  entries that are not name-to-map pairs, names that collide once converted
  to strings, and values that cannot be JSON-encoded. The message never
  includes the value, which may hold credentials.

### Added

- Claude ACP adapter: `:mcp_config_path` option, a path or list of paths to
  Claude MCP config files (`{"mcpServers": {...}}`) passed as
  `--mcp-config <path>...` ahead of the file generated for `:mcp_servers`. A
  relative path is resolved against `:cwd`; a path that is not an existing
  file fails the connection with
  `{:error, {:invalid_option, :mcp_config_path, message}}`.
- `ExMCP.ACP.Adapter`: `command/1` may return `{:error, reason}`, and
  `ExMCP.ACP.AdapterBridge` then stops with `reason`, so `start_link/1`
  returns `{:error, reason}`. Additive: existing return values are unchanged.
- `ExMCP.Client.delivery_outcome/1` reads a request's error as `:not_sent`
  (the request provably never left the client: not connected, failed
  validation, the caller's deadline passed or the caller exited before it
  went out, or the transport refused it before writing, such as a
  connection that could not be opened or an address that could not be
  resolved) or `:unknown` (it was or may have been delivered; a timeout, a
  failure after sending, or any error the server answered with). Retry
  policy stays with the caller.
- `:establish_timeout` client option: one deadline, in milliseconds or
  `:infinity`, around establishing the connection (opening the transport,
  the probe, any legacy fallback, `initialize`, `notifications/initialized`
  and connection retries). Defaults to `:handshake_timeout` plus
  `:era_probe_timeout`; each reconnection attempt is bounded the same way.
  On expiry `start_link/1` fails with `{:error, :establish_timeout}`.
- `process_group: true` stdio option. ERTS starts every port program as the
  leader of a new process group; with this option `close/1` sends SIGTERM,
  then SIGKILL, to the whole group, and when the server exits on its own
  whatever it left running in its group is signalled too. Use it for a
  server that starts processes of its own (a launcher or shell script that
  spawns the real server, a server that forks workers), which otherwise
  outlive the connection. The default is unchanged.
- `ExMCP.Transport.linked_processes/1`, an optional transport callback
  naming the processes and ports a transport links to its caller, and
  `ExMCP.Transport.linked_processes/2` to read it. The stdio, HTTP, legacy
  SSE and reliability-wrapper transports implement it.
- `security: %{trusted_origins: [...]}` on an HTTP connection: exact
  HTTP(S) origins that connection may send credentials to without consent,
  joined to the VM-wide `trusted_origins` for its own requests only. Entries
  are validated at connect.

- Claude ACP adapter: `agent_message_chunk`, `agent_thought_chunk` and
  `user_message_chunk` session updates now carry `messageId`, ported from
  claude-agent-acp's `applyMessageId`. It is the same id `session/fork`'s
  `_meta.jetbrains.air.fork` resolves, so a host can take a fork point
  straight from a chunk it received instead of reading Claude's JSONL
  transcript itself. Live streamed chunks are tagged with the id from the
  `message_start` that opened the message, consolidated assistant text and
  replayed `session/load` history with the persisted entry's grouping id (the
  Anthropic API message id for an assistant turn, the transcript uuid for a
  user message). **Wire-visible but additive:** the field is optional in the
  ACP schema, no existing key changes, and no other update type gains it —
  `tool_call`, `tool_call_update`, `plan`, usage and the session/mode/config
  updates never carry one. Chunks ExMCP synthesizes rather than receives from
  Claude (the Auto-mode fallback notice and the `result` fallback text) also
  carry none, because no transcript entry backs them and a fork at such an id
  would be rejected. Three golden scenarios assert the round trip: the
  `messageId` read back off the wire is forked at verbatim and cuts the
  transcript where expected. Codex, Pi and ZCode adapters are unaffected.
- Claude ACP adapter: `session/fork` accepts an optional, explicitly
  versioned fork point at `_meta.jetbrains.air.fork`
  (`{"version": 1, "messageId": "..."}`), ported from claude-agent-acp#1046.
  The transcript is copied up to **and including** the named message instead
  of in full. The `messageId` addresses an assistant turn by its Anthropic
  API message id and a user message by its transcript uuid (upstream's
  `messageIdForGrouping`), a trailing `:segment:<n>` suffix is stripped and
  both spellings are tried, and the last entry carrying the id wins so a
  message split across several content-block entries is kept whole. A
  `session/fork` with no fork point behaves exactly as before. **Wire-visible:**
  a fork point that matches nothing now answers JSON-RPC `-32602` naming the
  `messageId`, matching the reference's `invalidParams`; every other
  `session/fork` failure still answers `-32603`.
- `ExMCP.ACP.Adapter`: `fork_session/2` may return
  `{:error, {:invalid_params, message}, state}`, which
  `ExMCP.ACP.AdapterBridge` answers as JSON-RPC `-32602`. Additive — a plain
  `{:error, reason, state}` still answers `-32603` unchanged.
- Claude ACP adapter characterization: two golden scenarios pin that a
  `session/prompt` arriving while a permission request or an elicitation is
  outstanding is queued and cannot disturb the pending client request. This
  records ExMCP's standing answer to claude-agent-acp#1045 ("defer steering
  while user input is pending"), which does not apply because ExMCP never
  injects a mid-turn user message. Test-only; no behavior change.
- Claude adapter golden-transcript characterization suite:
  `ExMCP.Test.ClaudeGolden` (`test/support/acp/claude_golden.ex`, with
  `ExMCP.Test.ClaudeGolden.Flows`) and seven golden areas under
  `test/ex_mcp/acp/adapters/claude_sdk/characterization/` with 314 fixtures
  under `test/fixtures/acp/claude/`, pinning the adapter's session
  lifecycle, prompt content conversion, permission bridge, session update
  ordering, process configuration and authorization, fault handling and
  catalog normalization before the queued Claude parity ports. Every run
  uses a private sandbox for the Claude config directory, working directory
  and CLI, so no scenario reads the developer's real Claude configuration,
  credentials, sessions or projects. The suite and its fixtures are
  repo-only; no library code or behavior changes.
- Claude ACP adapter: per-turn, per-model token usage on the prompt response
  as `_meta.quota` (`token_count` plus a `model_usage` breakdown), ported
  from claude-agent-acp#1037 and shaped like codex-acp's so a host reads one
  shape from either agent. Additive: the raw Claude figures remain available
  unchanged under `_meta.ex_mcp.claude_sdk.modelUsage`.
- Claude ACP adapter: every permission mode entry now carries its semantic
  kind under `_meta.kind` (`standard`, `plan`, `auto_review`,
  `full_access`), on `modes/0`, the `session/new` mode catalog and the
  `mode` config option's options (claude-agent-acp#1025).

### Changed

- **Security:** minimum dependency versions now exclude two known
  vulnerabilities, so applications using ExMCP resolve fixed versions:
  `mint` `~> 1.10 and >= 1.10.1` (was `~> 1.6`; 1.10.1 fixes
  EEF-CVE-2026-82672, HTTP/1 response smuggling through unvalidated
  chunk-size lines), and a new direct requirement on `cowlib` `~> 2.20`
  (previously only transitive through `plug_cowboy`, which still allows
  older releases; 2.20.0 fixes EEF-CVE-2026-43971, Link header directive
  smuggling in `cow_link`). ExMCP's own lock already used these versions.
  **Breaking for applications that lock older versions:** dependency
  resolution now fails until they upgrade `mint` and `cowlib`.
- Stdio servers and ACP agent subprocesses: the command is resolved against
  the `PATH` the child will see (an explicit `PATH` in `:env` first) rather
  than the VM's own, and when the VM runs as an OTP release, `PATH` entries
  under `RELEASE_ROOT` are dropped from the inherited `PATH`, so a child
  that is itself an Erlang or Elixir program does not pick up the release's
  `erl`. An explicit `PATH` in `:env` is used as given.
- **Twenty ACP helper modules are no longer public API.** They were never
  intended to be: each is a pure helper behind a public module, and their
  sibling helpers (for example `ExMCP.ACP.Adapters.Pi.Config` and
  `ExMCP.ACP.Adapters.Codex.Permissions`) were already `@moduledoc false`.
  They only appeared in the docs because they had a moduledoc. They are now
  `@moduledoc false` too. The code is unchanged and still callable in 1.x,
  but it may change without notice, and it will not survive ACP's move to
  the `ex_acp` package in 2.0. The modules:
  - Adapter internals: `ExMCP.ACP.Adapters.ClaudeSDK.Mapper`,
    `ClaudeSDK.Protocol`, `ClaudeSDK.ToolInfo`,
    `ExMCP.ACP.Adapters.Codex.Config`, `Codex.Events`, `Codex.FileChanges`,
    `Codex.Protocol`, `Codex.Sessions`, `Codex.SlashCommands`,
    `ExMCP.ACP.Adapters.Pi.RPC`, `ExMCP.ACP.Adapters.ZCode.Config`,
    `ZCode.Mapper`, `ZCode.Protocol`, and `ZCode.Sessions`. Use the root
    adapter module (`ExMCP.ACP.Adapters.Codex` etc.) instead.
  - Shared plumbing: `ExMCP.ACP.Envelope`, `ExMCP.ACP.LifecycleParams`,
    `ExMCP.ACP.Maps`, `ExMCP.ACP.Meta`, `ExMCP.ACP.NameValue`, and
    `ExMCP.ACP.PromptQueue`. Use `ExMCP.ACP.Protocol` and
    `ExMCP.ACP.AdapterEvents` to build ACP messages.
- `ExMCP.ACP.AdapterEvents` is now documented as public API for custom
  adapters, with docs for every builder, and the ACP guide's custom-adapter
  example uses it. Its `maybe_put/3` map helper is hidden from the docs but
  still callable in 1.x.
- `ExMCP.ACP.Adapters.ZCode`, `ExMCP.ACP.Agent.Transport`,
  `ExMCP.ACP.Agent.Transport.Memory`, and `ExMCP.ACP.Agent.Transport.Stdio`
  now appear in the docs sidebar's ACP group. They were already public and
  documented, just left out of the grouping.
- The Pi ACP adapter is split into `ExMCP.ACP.Adapters.Pi.Config`,
  `ExMCP.ACP.Adapters.Pi.Events`, `ExMCP.ACP.Adapters.Pi.PromptFlow` and
  `ExMCP.ACP.Adapters.Pi.Sessions`, alongside the existing `Pi.RPC`,
  `Pi.SessionStore`, `Pi.Settings`, `Pi.SlashCommands`, `Pi.Startup`,
  `Pi.Prompt` and `Pi.Tools`. The new modules are pure: they hold the
  configuration translation, the inbound stream-event folding, the prompt
  scheduling and the session-lifecycle transition, while
  `ExMCP.ACP.Adapters.Pi` keeps the Port, the filesystem access and the
  adapter state. The root drops from 2,586 to 1,795 lines. The public
  `ExMCP.ACP.Adapters.Pi` API, its struct and its startup options are
  unchanged, and there is no wire-visible change: the 123 golden Pi
  transcripts are byte-identical.
- **Wire-visible (Claude ACP adapter):** the permission mode catalog is now
  stable. `auto` is advertised for every model instead of only for a model
  reporting `supportsAutoMode`; `bypassPermissions` keeps its existing
  gating behind `allow_dangerously_skip_permissions` or an inherited bypass
  mode. Accepted under `V2_ROADMAP.md` §8.1 condition 3 as deliberate
  reference parity with claude-agent-acp#1025: the change is additive (one
  extra catalog entry and the new `_meta.kind`), and no existing mode id,
  name, description or config-option key is removed or renamed.
- **Wire-visible (Claude ACP adapter):** selecting or inheriting `auto` on a
  model Claude has described as lacking Auto support now falls back to
  `acceptEdits` and says so, instead of failing (`session/set_mode`) or
  silently clamping to `default` (an inherited mode). The client receives a
  `current_mode_update` for the effective mode plus a once-per-session
  `agent_message_chunk` notice. The fallback applies at `session/new` (where
  the notice is held until the first prompt), on `session/set_mode` and its
  `mode` / `permission_mode` aliases, on a model switch that invalidates
  Auto, and to an Exit Plan "use auto mode" decision, whose `setMode`
  permission is rewritten before it reaches Claude. A model Claude never
  described is assumed capable, so no fallback happens. As a consequence the
  elevated Exit Plan option is now always "Yes, and use auto mode", which is
  the same state the reference reached for the same reason.

## [1.5.0] - 2026-09-21

### Added

- The scheduled ACP ecosystem drift check now pins and monitors the newly
  published `zai-org/ZCode` repository alongside the Claude, Codex, and Pi
  adapter references. The pin and the check are repo-only; no library code or
  behavior changes.
- Pi adapter golden-transcript characterization suite:
  `ExMCP.Test.PiGolden` (`test/support/acp/pi_golden.ex`) and seven golden
  areas under `test/ex_mcp/acp/adapters/pi/characterization/` with fixtures
  under `test/fixtures/acp/pi/`, pinning the adapter's RPC envelopes,
  control-group ordering, stream-event conversion, prompt scheduling,
  configuration updates, slash commands and session-store safety rules
  before the `Pi.*` boundary extractions. Repo-only; nothing ships to Hex.
- `ExMCP.Client.subscribe_notifications/3` and
  `ExMCP.Client.unsubscribe_notifications/2`, a public delivery path for
  legacy-era (MCP 2024-11-05 through 2025-11-25) list-change and
  resource-update notifications. A listener registers a filter using the same
  keys as `listen/3`, minus `taskIds`, and receives matching notifications as
  `{:ex_mcp_notification, listener, method, params}`. Listened resource URIs
  are subscribed on the server once and shared across listeners, released
  when the last listener naming them goes away or its subscriber exits, and
  re-subscribed after an automatic reconnect with a
  `{:ex_mcp_notification_reconnected, listener, result}` report. On a modern
  peer the call returns `{:error, :use_listen}`. Previously the client parsed
  these notifications and dropped them with a warning about an unknown
  subscription; that warning is now a debug-level message when no listener
  matches. Modern subscription routing and `subscribe_resource/3` are
  unchanged (#44).

### Changed
- Internal: `.dialyzer_ignore.exs` drops fifteen filters that no longer match
  a warning, and documents that entries must be verified in both `MIX_ENV=dev`
  and `MIX_ENV=test` because the files under `test/` are only analyzed in the
  test environment. No analysis result changes.

- ACP reference-adapter parity, from the 2026-09-20 drift review of
  claude-agent-acp and codex-acp (both still on ACP SDK 1.4.0):
  - Claude SDK adapter: a host may opt a session out of `bypassPermissions`
    with `_meta.claudeCode.options.allowDangerouslySkipPermissions: false`
    on `session/new`, `session/load`, or `session/resume`. The mode leaves
    the catalog, `session/set_mode` refuses it, and an active bypass mode is
    clamped to `default` through a `set_permission_mode` control. `true`
    cannot override the adapter's own option. (claude-agent-acp#1129)
  - Claude SDK adapter: an AskUserQuestion custom answer no longer replaces
    a selection. It joins a multi-select in the CLI's own quoted form, and
    for a single-select it rides beside the pick as the tool's per-question
    `annotations[question].notes`, so a client that presents the box as a
    notes field cannot make the selection disappear. (#1031, #1131)
  - Codex adapter: `item/tool/requestUserInput` forms follow codex-acp#299.
    The elicitation message is always "Codex needs your input to continue.",
    the question text is the field title and the header its description,
    every question is required, an `isOther` question with options gains a
    "None of the above" choice and a separate `<id>_note` field tagged
    `_meta.codex.role: "user_note"`, and note text returns to Codex as
    `user_note: <text>` beside the selection instead of replacing it. A
    whitespace-only answer is dropped. **Wire-visible for clients that read
    the previous `<id>__other` field or `_meta.codex.isOtherAnswer`.**
  - Codex adapter: `session/load` pages a thread's older turns through
    `thread/turns/list` when the resume result carries a backwards cursor,
    replaying the full history in order instead of only the newest hundred
    turns; the initial page is now requested newest-first and reversed. A
    server without the method, or a failed page, still loads with the
    initial page. (codex-acp#481)
  - `ExMCP.ACP.Adapter` translations may return
    `{:messages_and_reply_and_write, messages, result, iodata, state}`, and
    `session/load` and `session/resume` accept `{:reply_and_write, ...}`.
  - Deferred with recorded decisions (pre-standard `_meta` extensions, not
    in ACP SDK 1.4.0): `authStatus`, `recommendedValue`, `asyncTasks`,
    tool-call `name`, and both compaction mechanisms. Not applicable:
    codex-acp#471, since ExMCP forwards MCP elicitations without a
    synthetic tool call. See `docs/POST_1_0_MAINTENANCE_PLAN.md`.
- Internal: the three Mint-based pinned HTTP clients
  (`ExMCP.Internal.PinnedHTTPClient`, `ExMCP.Authorization.PinnedHTTPClient`,
  and `ExMCP.Transport.HTTP.BoundedClient`) now share one pure response
  reducer, `ExMCP.Internal.HTTPResponseReducer`, for Mint event accumulation
  and bounded-body decisions. Each client keeps its own DNS pinning, TLS,
  compression and framing policy, error atoms, and return shapes. No public
  API or behavior change.
- mint moves to 1.10.1, which fixes `EEF-CVE-2026-82672` (unvalidated
  chunk-size line tail in the HTTP/1 client). `mix hex.audit` fails on 1.10.0
  since the advisory was published on 2026-09-19.
- Internal dependency-cycle reductions with no public API change. Seven of
  the nine `mix xref graph --format cycles` components reported on Elixir
  1.19.5 / OTP 28.3.1 are gone (`MessageProcessor`/`MethodHandlers`,
  `Content.Validation`/`Rules`, `SchemaPolicy`/`SchemaRemoteResolver`,
  `ExMCP`/`ClientConfig`, `Server.Subscriptions`/`Tasks`, the
  `Internal.SessionStore` behaviour and its ETS/DETS backends, and the
  `VersionRegistry`/`Protocol.Methods`/`ErrorCodes`/`Types` version cycle),
  each through a narrow dependency inversion or a small `@moduledoc false`
  lower-level module (`ExMCP.Tasks.StoreCall`,
  `ExMCP.Internal.SessionStore.Factory`, `ExMCP.Internal.RevisionCatalog`).
  The two large client and transport cycles remain; see
  `docs/POST_1_0_MAINTENANCE_PLAN.md`.

- The Codex ACP adapter is split into `ExMCP.ACP.Adapters.Codex.Permissions`,
  `Codex.Content`, and `Codex.MCP` (internal modules) with no wire-visible
  change: the golden transcript fixtures are byte-identical, and the public
  `ExMCP.ACP.Adapters.Codex` API and state struct are unchanged. See the
  Codex status in `docs/POST_1_0_MAINTENANCE_PLAN.md`.

### Fixed
- Pi adapter: three agent-controlled payloads no longer crash the adapter.
  A streamed tool call carried under `partial.content[contentIndex]` is now
  selected with `Enum.at/2` (`Access` cannot index a list, so the clause
  written to support that shape always raised), and a `get_available_models`
  payload whose `models` is not a list, or whose entries are not maps, drops
  the unusable data instead of raising. Found by the new Pi characterization
  gate and pinned by three golden scenarios.
- Codex adapter: `session/load` history replay now handles app-server v2's camelCase `agentMessage` items. Previously a replayed `agentMessage` reached the streaming completion path with no session state and crashed the load; only the legacy `agent_message` spelling replayed.

- `ExMCP.SessionManager` no longer logs at `info` when it starts or when it
  sweeps expired sessions; both are `debug`. The `:ex_mcp` application boots
  before a stdio server can suppress logging, and the default Elixir logger
  writes to stdout, so in a release that did not configure `:stdio_mode`
  ahead of boot the startup line landed in the protocol stream before the
  first frame. A subprocess test now boots the application's supervision tree
  under the default logger and asserts stdout stays empty. The configuration
  guide documents `config :ex_mcp, stdio_mode: true` together with
  `config :logger, :default_handler, config: [type: :standard_error]` as the
  stdio deployment setting that closes the window for every application in
  the VM.

- The stdio transports no longer let the process locale translate protocol
  frames. `ExMCP.Server.StdioServer` and `ExMCP.ACP.Agent.Transport.Stdio`
  now detect, on every read and write, whether each device is a character
  or a byte device and use the matching calls, through one shared framing
  owner, which is byte-exact for UTF-8 on every supported OTP and survives
  the VM flipping a device to latin1 after undecodable input (on OTP 27 that
  flip still ends the session under a UTF-8 locale; see the transport
  guide). Previously,
  under a C locale or no locale (launchd, systemd, minimal MCP host
  environments) the MCP stdio server double-encoded non-ASCII input and
  emitted `\x{...}` escapes for non-ASCII output, producing invalid JSON,
  while under a UTF-8 locale the ACP agent transport corrupted non-ASCII
  input. An echo tool masked the MCP case because the write reversed the
  read's damage. A byte-order mark before the first frame is now stripped
  instead of hanging the session at `initialize`. Diagnosed by deepfates in
  #41. A shared non-ASCII payload corpus now runs byte-exact through every
  transport, with a locale matrix on the stdio subprocess test (#52).

## [1.4.0] - 2026-09-17

- A 1.x minor driven by the Jido Connect review of 1.3.0: the modern
  subscription client now rejects server acknowledgments that broaden the
  requested notification filter, `ExMCP.Client.get_status/2` accepts a
  caller-supplied timeout, and Cowlib moves to 2.20.0, which clears one of the
  three tracked advisories. The remaining two Cowlib advisories are won't-fix
  upstream; see Changed. Legacy notification delivery through a public client
  API (#44) is not in this release.

### Added

- `ExMCP.Client.get_status/2` with a `:timeout` option. It accepts a
  non-negative millisecond value or `:infinity`, returns `{:error, :timeout}`
  when the deadline expires and `{:error, :invalid_timeout}` for anything
  else, and leaves `get_status/1` unchanged. Downstream adapters can now pass
  their own request deadline through the public API (#43, #45).

### Fixed

- A server acknowledgment of a `ExMCP.Client.listen/3` subscription that adds
  resource URIs, task IDs, or notification categories the client did not
  request is rejected with `{:error, :invalid_subscription_acknowledgment}`
  and the subscription is closed. Previously the expanded filter was stored,
  and after a reconnect the resynchronization step read resources and tasks
  from the expanded set. The check applies to the initial acknowledgment and
  to every reconnect acknowledgment; a rejected reconnect reports the resync
  failure and stops the subscription before any snapshot read. Equal and
  narrower acknowledgments continue to work. The client and server now share
  one filter normalization and subset rule set (#42, #46).

### Changed

- A modern subscription forwards only events covered by its acknowledged
  filter. `notifications/resources/updated` requires the URI to be in
  `resourceSubscriptions`, each `list_changed` notification requires its
  category to be enabled, and any other method is dropped. Previously every
  non-task notification on the subscription was forwarded regardless of the
  filter. Consumers that relied on receiving unfiltered events on a narrow
  subscription must widen the requested filter (#46).

- Cowlib moves to 2.20.0 and Cowboy to 2.19.0. Cowlib 2.20.0 fixes
  `EEF-CVE-2026-43971` (`cow_link:link/1`), the advisory now records 2.20.0 as
  the fixed version, and its `mix hex.audit` exception is removed. The
  `EEF-CVE-2026-43966` and `EEF-CVE-2026-43969` exceptions remain: the Cowlib
  maintainer has declined to change `cow_http_struct_hd:escape_string/2` and
  `cow_cookie:cookie/1` (ninenines/cowlib #152, #166, #169), so no Cowlib
  release will clear them while ExMCP requires Cowboy. The mitigation
  assumptions are unchanged and remain covered by
  `dependency_advisory_mitigation_test.exs`. Making the HTTP server dependency
  optional is now an accepted 2.0 change; see `docs/V2_ROADMAP.md` (#18).

## [1.3.0] - 2026-09-05

- ACP client handlers can receive the decoded JSON-RPC message for session updates and
  permission requests, adapter extension data lives under one nested `_meta.ex_mcp`
  namespace with opt-in native-event provenance, the Codex adapter reports failed turns
  and streams agent text once, and mint moves to 1.10.0 for two security advisories.
  The `_meta` key change is wire-visible for consumers that read the old flat keys; see
  Changed. The pending Claude and Codex parity decisions recorded in
  `docs/POST_1_0_MAINTENANCE_PLAN.md` remain open and the reference pins are unchanged.

### Added

- Optional `handle_session_update/4` and `handle_permission_request/5` callbacks on
  `ExMCP.ACP.Client.Handler` that receive the decoded JSON-RPC message the ACP client
  received, so consumers can retain extension fields and the permission request ID.
  ExMCP calls the context variant when the handler exports it and the legacy callback
  otherwise; validation, session authority, request correlation, cancellation, and
  handler deadlines are unchanged. For adapted agents the message is the ACP envelope
  the adapter constructed, not the native provider event (#31, #32).

- Opt-in `_meta.ex_mcp.native` provenance on every ACP message an adapter derives from
  a native agent line. Start `AdapterTransport`/`AdapterBridge` with
  `native_events: :summary` for the adapter `name` and a per-connection `sequence`, or
  `native_events: :raw` to also embed the decoded native `event`. The default is `:off`,
  so existing consumers see no wire change. Adapters can implement the new optional
  `ExMCP.ACP.Adapter.name/0` callback; the bridge derives a name from the module
  otherwise, and Claude SDK's `agentInfo.name` is now `claude_sdk` instead of
  `claudesdk`.

### Changed

- `handle_session_update/3` and `handle_permission_request/4` on
  `ExMCP.ACP.Client.Handler` are now optional, so a handler can implement only the
  context-aware arities. A handler must still export at least one arity of each pair;
  the client refuses to start one that does not, with
  `{:handler_init_failed, {:missing_callback, name}}`. Existing handlers are unaffected.
- **BREAKING:** Adapter extension data now lives under nested `_meta.ex_mcp.<adapter>`
  maps everywhere. The Claude SDK adapter previously used a flat `"ex_mcp.claude_sdk"`
  key, and the Codex, Pi, and ZCode capability advertisements used flat `"ex_mcp.codex"`,
  `"ex_mcp.pi"`, and `"ex_mcp.zcode"` keys. Consumers reading those keys must read
  `_meta["ex_mcp"]["claude_sdk"]` (and so on) instead; the documented dotted paths such
  as `_meta.ex_mcp.claude_sdk.sessionId` are unchanged and now match the wire shape.
- `ExMCP.ACP.Protocol.parse_message/1` rejects a JSON string that contains encoded JSON
  instead of decoding it a second time (#32).

### Fixed

- Bump `mint` to 1.10.0, which fixes EEF-CVE-2026-82728 and EEF-CVE-2026-82729, and
  `castore` to 1.0.21. `mix hex.audit` reports only the three accepted Cowlib 2.19.0
  exceptions again.
- The Codex ACP adapter fails the active prompt when `codex app-server` reports a failed turn. Previously an `error` notification (`usageLimitExceeded`, a `401` response-stream disconnect, a system error) followed by `turn/completed` with `status: "failed"` resolved the prompt as a successful `end_turn` with empty text, so callers could not tell "the model said nothing" from "the model never ran" (observed with codex-cli 0.151). The prompt now gets a JSON-RPC error carrying the Codex message, `codexErrorInfo`, and a `kind` of `rate_limit_exhausted` (`-32029`), `unauthenticated` (`-32031`), or `turn_failed` (`-32030`); the last `error` notification is used when the turn carries no error of its own.
- The Codex ACP adapter no longer repeats an agent message. `item/completed` for an agent message emitted the full text again after it had been streamed through `item/agentMessage/delta`, so chunk consumers saw it twice (`PONGPONG`). The final chunk now carries only the text not already streamed, and that remainder is folded into the accumulated prompt text so `_meta.ex_mcp.text` matches the stream even when no deltas were sent.

## [1.2.0] - 2026-09-02

### Added

- Claude Code `tools: []` now passes `--tools ""` so the CLI disables built-in tools. Empty allow/deny lists still mean no opinion.
- Characterization tests for handler callback process identity, cancellation, serialized state ordering, and two-server isolation.
- Characterization tests for Codex native app-server envelopes, method names, inbound classification, and request-id correlation.
- Standalone 1.x store-adapter ADR and ETS-only SessionManager event-store contract suite.
- Opt-in SessionManager DETS store (`storage_backend: :dets` with `:storage_path`) and an unpublished Internal SessionStore seam. ETS remains the default.
- Characterization tests for Pi native RPC envelopes, correlation ids, and inbound response classification.

### Fixed

- `ExMCP.Server.SSESession.init/0` is safe under concurrent first calls. Two requests racing to create the named ETS table made the loser raise `ArgumentError`, which the gating MCP 2026-07-28 conformance run hit intermittently in `server-sse-multiple-streams`. The conformance server now creates the table once at startup from its long-lived main process instead of on every request.
- `HttpPlug` rejects `GET`/`DELETE` in `:modern_only` mode with `405` at its mount root wherever it is mounted. The check compared the absolute request path with the `:path` option (default `/mcp`), so a router `forward` at any other prefix (the README's `/api/mcp` mount) answered `404` and `400` instead.
- `HttpPlug` halts the conn after responding, as a terminal plug should. Mounting it directly in an endpoint no longer needs a manual `halt/1`.
- `HttpPlug` no longer answers `-32700 Parse error` when an upstream `Plug.Parsers` has already drained the request body, which is what the README's Phoenix router mount does on every stock endpoint. It now falls back to the payload Phoenix parsed (`conn.body_params`) for JSON requests carrying a non-empty object. An empty body, a non-JSON content type, and a `%{"_json" => ...}` wrapper (a top-level array) keep their previous behaviour, and `conn.assigns[:raw_body]` still takes precedence when set.
- Circuit breaker elapsed-duration math uses injected monotonic `now_ms` from the process shell instead of reading wall time inside the core.

### Deprecated

- `ExMCP.Transport.HTTPServer` and `ExMCP.Transport.HTTPServerWithVersion`, the simplified example transport. It reads the body itself and so fails behind `Plug.Parsers`, matches its SSE route only at the host root, and returns a canned `initialize`. Use `ExMCP.HttpPlug`. Both modules log a one-time warning and will be removed in 2.0.0.

### Changed

- ACP reference pins advanced to Claude Agent ACP `7c66108` and Codex ACP `4823131`. The Codex 1.7.0 permission/mode parity below is ported; the later upstream changes the pins now cover (Claude stable mode catalog with `_meta.kind` and Auto-mode fallback, per-model token usage, deferred steering, native subagents/async tasks, and session forks; Codex native subagent sessions, session forks, and session title generation) are not yet implemented and are tracked in `docs/POST_1_0_MAINTENANCE_PLAN.md` as pending parity decisions.
- Codex ACP adapter 1.7.0 permission/mode parity: `approvalsReviewer`, mode `_meta.kind`, and TS permission presentation.
- Extracted `ExMCP.ACP.Adapters.Codex.Protocol` for native app-server envelopes, method names, response classification, and request-id correlation.
- Extracted `ExMCP.ACP.Adapters.Pi.RPC` for native RPC envelopes, correlation ids, and response classification.
- Documented three 1.x contract mismatches: `storage_backend: :persistent_term`
  remains accepted and uses ETS (no-op durability) with a warning;
  `ExMCP.connect/2` still accepts a list but uses only the first spec;
  stdio logger configuration still mutates VM-global Logger behavior.
- Resource subscribe/unsubscribe now decide modern vs legacy from `Client.get_status` protocol version after an explicit Client process marker, not `$initial_call`.
- SessionManager dispatches session, event, and request-id tables through an internal store adapter. Default ETS restart-empty behavior and `storage_backend: :persistent_term` no-op durability are unchanged.

## [1.1.1] - 2026-08-27

### Added

- `transport: :sse` is a first-class client connector for the deprecated
  MCP 2024-11-05 HTTP+SSE handshake (`GET /sse`, then POST to the
  advertised `/message?sessionId=` URI). This is not Streamable HTTP;
  `use_sse: true` still GETs the MCP endpoint after `initialize`.
- `ExMCP.Server.Context.cancelled?/0` so a running handler can see
  `notifications/cancelled` without polling `get_pending_requests/1`.
- `ExMCP.Server.elicit/1` builds an `elicitation/create` MRTR input-request
  entry for form and URL mode. `handle_url_elicitation/4` receives
  `elicitationId` so `notifications/elicitation/complete` does not need
  out-of-band state; `handle_url_elicitation/3` is unchanged.
- SEP-1730 how-tos for protocol and content coverage gaps.

### Fixed

- Unknown tool, resource, and prompt names now return JSON-RPC `-32602`
  instead of a tool-result `isError` or a generic server error (#25).
- HTTP registered-tool execution errors stay result `isError: true` after
  the #25 protocol-error change.
- The conformance fixture server now implements the SEP-2575
  `server-stateless` diagnostic tools that the official harness calls.
- HTTP `prompts/get` and `resources/read` now return JSON-RPC `-32602` when a
  handler reports an unknown name as a string. Non-name handler strings stay
  `-32603`.

## [1.1.0] - 2026-08-25

### Added

- A ZCode ACP adapter with app-server translation, model and mode selection,
  permission handling, session persistence, MCP configuration forwarding, and
  credential-free real-CLI lifecycle coverage.
- A weekly advisory workflow now runs the complete MCP 2026-07-28 conformance
  suites against the newest published official harness while keeping release CI
  pinned to a reviewed version.
- ACP v1 form and URL elicitation support across the shared client and agent
  APIs, including capability negotiation, request validation,
  `elicitation/complete`, and fail-closed default handlers.
- Adapter regression coverage for Claude `AskUserQuestion`, Codex user input,
  MCP and device-auth URL elicitations, Pi extension UI requests, prompt-close
  fencing, and background-agent settlement.

### Changed

- The gating MCP 2026-07-28 conformance runner now pins
  `@modelcontextprotocol/conformance@0.2.0-alpha.11`, including wire-schema,
  HTTP session-lifecycle, and client schema-preservation coverage.
- ACP compatibility tracking now follows Codex ACP in its canonical
  `agentclientprotocol/codex-acp` repository after the Zed repository moved.

### Fixed

- The Claude SDK adapter now exposes Claude Code's native session UUID in the
  initial `session_info_update` metadata, allowing clients to retain the
  provider resume id even when a prompt times out before its final response.
- **ACP Claude SDK adapter — updates dropped as "unknown session" with Claude
  Code 2.1.x** — `ExMCP.ACP.Adapters.ClaudeSDK` adopted the CLI's own session
  UUID (stamped on every stream-json event) as its session id, so every
  `session/update` went out under an id the client never received from
  `session/new`; `ExMCP.ACP.Client` logged `ACP client ignored an update for an
  unknown session` for each and the prompt returned empty text. The ACP-facing
  id now stays the one `session/new` returned through final and deferred
  results; the CLI's UUID is kept separately and surfaces only as provider
  metadata for correlation.
- Full OAuth flow verification no longer expands broad inferred error and map
  unions that made compiling the module take minutes under Elixir 1.20.
- The external MCP conformance client now round-trips complete JSON Schema
  2020-12 tool schemas without replacing them with generated arguments.
- The Pi adapter now waits for `agent_settled` before completing an ACP prompt,
  preserving follow-up work that can arrive after `agent_end`, and always
  answers extension UI requests it cannot represent.
- The Codex adapter now cancels active prompts and pending client requests when
  a session closes, ignores late events from closed sessions, bridges
  non-secret structured user input through ACP forms, and completes URL
  elicitation UI after the app server resolves it.
- The Claude SDK adapter now tracks SDK `0.3.238`, gates model-specific modes,
  removes permission choices whose durable effect cannot be honored, maps
  Exit Plan mode selections, and keeps a prompt open while its background
  subagents still need to stream output or request permission.

### Security

- Form elicitation refuses Codex and Claude secret-input shapes, URL
  elicitation accepts only HTTP(S) URLs without embedded credentials, and
  ChatGPT device-code authentication is advertised only when the client
  explicitly supports URL elicitation.

## [1.0.0] - 2026-08-22

Stable 1.0 preserves the public API, MCP/ACP wire behavior, security posture,
and `:prefer_modern` default of `1.0.0-rc.8`. The final candidate soaked for
more than seven calendar days without a release-blocking regression. There are
no protocol-default, wire-design, or public-API changes between rc.8 and this
release.

### Fixed

- OAuth callback parsing now uses a closed mapping for the supported atom-key
  representation instead of relying on those atoms to have been loaded by
  unrelated code first. This fixes a test-order-dependent crash without
  accepting dynamic keys or changing the callback wire format.

### Release evidence

- See the repository-only
  [1.0 release record](https://github.com/azmaveth/ex_mcp/blob/v1.0.0/docs/RELEASE_1_0_0.md).
- The mixed-version rollback gate passed with a modern node holding an active
  subscription and paused MRTR request while an exact `1.0.0-rc.5` stdio node
  remained live. The drill drained modern work, reconciled state on rc.5, and
  verified that modern era pins require explicit operator reset.

### Security

- Acknowledge `EEF-CVE-2026-43971` while Cowlib has no patched Hex release.
  ExMCP and its Plug/Cowboy server stack do not call the affected
  `cow_link:link/1` encoder; a BEAM-import regression test locks that
  assumption, and the exception expires with the existing Cowlib review date.

## [1.0.0-rc.8] - 2026-08-13

This narrow follow-up candidate preserves rc.7's MCP/ACP wire behavior and
`:prefer_modern` default while adding real adapter lifecycle evidence, fixing
Pi configuration isolation, and reducing duplicated internal code. Publishing
rc.8 starts the final-candidate soak from the rc.8 artifact.

### Fixed

- The Pi adapter now consistently honors `:agent_dir` while discovering
  settings, prompts, and sessions, allowing tests and embedded callers to avoid
  the developer's real Pi state. Slash-command input hints are normalized to
  the ACP object shape before advertisement.
- ACP adapter examples now use `ExMCP.ACP.AdapterTransport`, matching the
  actual Claude SDK, Codex, and Pi adapter lifecycle.

### Added

- Opt-in, credential-free lifecycle tests launch the real Claude Code, Codex,
  and Pi CLIs through their adapters. The tests initialize, create/list/close a
  session, and shut down without sending a prompt or making an LLM request.
- Post-1.0 maintenance and 2.0 roadmap notes now track adapter decomposition,
  pure functional cores, dependency-cycle cleanup, configuration ownership,
  and the evidence required before considering separate MCP and ACP packages.

### Changed

- Subprocess environment isolation, positive-integer option handling, and
  symlink-aware workspace containment now use shared internal helpers with
  focused characterization tests; public options and security defaults are
  unchanged.
- Internal planning, audit, migration, coverage, and release-history documents
  remain in the repository but are no longer installed in the Hex source
  package or rendered as normal HexDocs guides. The user-facing architecture,
  configuration, transport, security, troubleshooting, ACP, DSL, migration,
  and getting-started guides remain packaged.

### Release evidence

- See the repository-only
  [rc.8 release record](https://github.com/azmaveth/ex_mcp/blob/v1.0.0-rc.8/docs/RELEASE_1_0_0_RC_8.md).

## [1.0.0-rc.7] - 2026-08-13

This release candidate packages the post-rc.6 transport lifecycle, ACP, and
security hardening work that requires a fresh modern-preferred soak before
stable 1.0. The application default remains `:prefer_modern`. Set
`protocol_mode: :legacy_only` to preserve the legacy protocol era. Exact rc.5
wire and session behavior still requires package rollback to `1.0.0-rc.5`;
rc.7 continues to enforce server-issued sessions and newer lifecycle/security
rules.

### Fixed

- Legacy GET SSE streams now persist events before delivery and replay events
  published during a connection gap after `Last-Event-ID`. Normal stream
  disconnects retain the MCP session until explicit deletion or expiry, and
  bounded event retention continues to keep the newest events after repeated
  evictions.
- ACP Pi managed event handling now correctly processes multi-chunk agent
  streams without dropping or duplicating partial updates.
- CI compatibility follow-ups after the 2026-08-12 security harden: invalid
  MRTR identities fail closed, public docs remain compatible with Elixir 1.17,
  an unreachable Elixir 1.20 clause was removed, and tagged test fixtures align
  with server-issued sessions and strict schema/privacy behavior.
- SSE cleanup tests are race-safe under concurrent teardown.

### Security

- MCP and ACP protocol implementations were hardened across lifecycle,
  identity, authorization, network, resource, and privacy boundaries. See
  [the 2026-08-12 security audit](https://github.com/azmaveth/ex_mcp/blob/v1.0.0-rc.7/docs/SECURITY_AUDIT_2026-08-12.md).
- Legacy Streamable HTTP sessions are server-issued only, identity-bound for
  their lifetime, initialize-once, and capacity-capped. Duplicate JSON-RPC
  request IDs are rejected before dispatch.
- OAuth metadata and MCP HTTP destinations use pinned, hostname-verifying
  clients with DNS revalidation, public-address checks, and bounded redirects.
- Adapter and MCP/ACP subprocesses use a closed environment by default:
  inherited variables are cleared before a minimal runtime baseline and
  explicit values are restored. Callers that require the legacy behavior can
  opt into `environment_policy: :inherit` or
  `adapter_opts[:environment_policy] == :inherit`.
- Resource, frame, queue, handshake, and replay paths enforce byte/count/
  deadline limits with slow-consumer handling. Peer-facing errors omit
  internal details; logs and telemetry use structural summaries.

### Added

- Added a canonical ExMCP 2.0 roadmap covering runtime ownership, bounded
  handler scheduling, state/replay adapters, public API consolidation,
  deprecation removals, and the compatibility gate for 1.x backports.
- Additive `ExMCP.SessionManager.append_event/3` for store-owned,
  monotonically increasing SSE event IDs used by persist-before-delivery.

### Documentation and release evidence

- Release packaging for `1.0.0-rc.7`, including
  [the rc.7 release record](https://github.com/azmaveth/ex_mcp/blob/v1.0.0-rc.7/docs/RELEASE_1_0_0_RC_7.md) and an updated
  public API delta note for post-rc.6 changes.

## [1.0.0-rc.6] - 2026-08-05

This is the first published dual-era release candidate and starts the
modern-preferred soak for stable 1.0. New connections try MCP 2026-07-28 first
and retain evidence-based fallback to every legacy revision. Set
`protocol_mode: :legacy_only` for the exact rc.5 wire path.

### MCP wire protocol changes

- **MCP 2026-07-28 lands before stable 1.0** — New connections prefer the modern
  protocol era and fall back according to the configured protocol mode. The
  `:prefer_legacy`, `:legacy_only`, and `:modern_only` modes provide explicit
  rollout and rollback controls. A connection is pinned to one era after
  negotiation; it never silently downgrades after application traffic starts.
- **Modern initialization and discovery** — Modern sessions use the 2026-07-28
  initialization shape and `server/discover`, including extension metadata.
  Existing revisions remain supported throughout 1.x.
- **Stateless Streamable HTTP routing** — Modern requests use body-derived
  `Mcp-Method`, `Mcp-Params`, and `Mcp-Param-*` headers, per-request or
  subscription POST-owned SSE streams, and modern GET/DELETE semantics. The
  deprecated two-endpoint HTTP+SSE transport remains opt-in for legacy peers.
- **Multi-round tool results** — Tools, prompts, and resource reads can return
  input-required results with sealed `requestState`; clients dispatch input and
  continue the operation under bounded round, expiry, replay, principal, and
  key-rotation controls.
- **Subscriptions and cache metadata** — `subscriptions/listen` replaces the
  modern resource-only flow and supports bounded local storage plus optional
  clustered PubSub fanout. Result envelopes validate `resultType`, `ttlMs`, and
  `cacheScope`; 1.0 deliberately does not store or reuse cached responses.
- **Tasks extension** — Store-backed handlers advertise and implement
  `io.modelcontextprotocol/tasks`; clients advertise it only when explicitly
  configured. Legacy task APIs remain available on legacy protocol revisions.
- **Protocol deprecations are compatibility features in 1.x** — Roots,
  sampling, logging, the old resource-subscription methods, and legacy
  HTTP+SSE remain available where their negotiated revision supports them, with
  documented migration paths.

### ExMCP public API compatibility

- **No rc.5 public surface was removed** — The compiled API comparison found no
  removed module, exported function/arity, callback, named type, or struct
  field. Existing handler callbacks are widened for MRTR and existing structs
  only gain fields. See the
  [rc.5-to-1.0 API diff](https://github.com/azmaveth/ex_mcp/blob/v1.0.0-rc.6/docs/API_DIFF_RC5_TO_1_0.md).
- **Modern APIs are additive** — Discovery, request context, MRTR,
  subscriptions, Tasks-extension, era control, modern HTTP, and OAuth security
  APIs are added alongside the rc.5 surface.
- **Deprecated library APIs remain for all of 1.x** — `ExMCP.Server.Tools`,
  `ExMCP.Server.Tools.Simplified`, companion modules, and deprecated content
  transformation stubs target removal in 2.0.0, not a 1.x release.
- **OAuth state ownership is intentionally hardened** —
  `OAuthFlow.start_authorization_flow/1` rejects caller-supplied `:state`,
  generates a single-use value, and returns it in the bound transaction. This
  is the one public input-behavior change identified by the rc.5 API audit;
  callers should retain the returned transaction instead of supplying state.

### Operations and security

- **Modern-preferred release default** — The application default is now
  `:prefer_modern`. Servers accept both eras and advertise 2026-07-28 first;
  clients probe with `server/discover` and initialize only after positive
  legacy evidence. Explicit modes are unchanged.
- **Patched HTTP dependency stack** — Mint, Mint WebSocket, Plug, Plug Cowboy,
  Cowboy, Cowlib, HPAX, Decimal, and related runtime dependencies are updated
  to remove every high-severity lockfile advisory. CI now gates on
  `mix hex.audit` and a real Hex package build. The two remaining upstream
  Cowlib medium/low advisories are explicitly acknowledged because Plug and
  Cowboy validate response headers and ExMCP does not call the affected cookie
  encoder; every new advisory still fails the build.
- **Bounded modern state** — Era observations, MRTR continuations/replay data,
  subscription queues, filters, lifetimes, and task records have explicit
  bounds and cleanup behavior.
- **Migration telemetry is privacy-safe** — Era selection/fallback/downgrade,
  MRTR failures, ambiguous reissue, and subscription reconnect/pressure events
  use bounded classifications and exclude headers, arguments, response
  content, request state, credentials, and raw subscription identifiers.
- **OAuth 2026 hardening** — Metadata fetching is address-pinned and
  SSRF-resistant; transactions are atomic and single-use; credentials are
  issuer- and authorization-context-bound; CIMD replaces DCR where available.
  Modern POST-owned request streams now apply the configured provider token,
  handle a bounded 401 refresh plus optional 403 scope step-up, and merge the
  resulting token/provider state back only while that stream still owns the
  request.

### Documentation and release evidence

- **Protocol-era guidance is consistent across README, HexDocs, and guides** —
  Public HTTP and callback documentation now distinguishes stateless MCP
  2026-07-28 behavior from legacy sessions, GET streams, resumability, and
  independent server-to-client requests. Troubleshooting covers modern
  discovery, metadata, routing headers, result envelopes, and expected 405s.
- **Release evidence ships with the package** — The MCP coverage matrix,
  rc.5-to-1.0 API diff, and 2026 migration plan are packaged and linked from
  HexDocs. The development checklist records the modern conformance, RC soak,
  and mixed-cluster rollback gates, and CI treats ExDoc warnings as failures.
- **Official SDK v2 interop is release-gating** — Four isolated CI lanes exercise
  ExMCP as client and server over stdio and Streamable HTTP against the official
  TypeScript MCP v2 client/server packages pinned at `2.0.0`. They negotiate
  `2026-07-28` exactly and cover discovery, request context, result envelopes,
  MRTR, subscriptions, routing headers, POST-owned SSE, and stateless sessions;
  legacy SDK interop remains independently gated.

### Security

- **OAuth metadata fetches are SSRF-hardened** — CIMD, Protected Resource Metadata,
  OIDC/RFC 8414 authorization-server metadata, and JWKS retrieval now require HTTPS and share a
  bounded, address-pinned fetcher. It rejects any private, loopback, link-local, reserved or mixed
  DNS result; re-resolves every redirect; blocks cross-origin redirects unless an exact HTTPS
  origin is configured; and forwards no credentials or application headers. Legacy URL-only
  custom metadata clients are replaced by `get(uri, approved_address, opts)` so adapters cannot
  silently re-resolve after validation.
- **OAuth transactions are atomic and single-use** — Library-started authorization-code flows
  now generate their own 256-bit state, reject reserved parameter overrides, retain only state/code
  digests in a bounded supervised transaction store, and bind callback issuer, PKCE, authorization
  code, and exact redirect URI through one-time transitions shared by both MCP protocol eras.
  Concurrent callback/redemption attempts have one winner; an ambiguous token request cannot
  replay its code. OAuth failure logs and telemetry redact credential fields, cookies,
  authorization values, and URL query/fragment data.
- **OAuth credentials are authorization-server bound** — MCP 2026-07-28 pre-registered clients require an exact `credential_issuer`; discovered metadata, callbacks, and persisted registrations use one no-normalization issuer comparison. The new pluggable `ExMCP.Authorization.CredentialStore` partitions registrations by issuer + client ID and tokens by the complete authorization context, rejects unkeyed legacy records pending explicit migration, and redacts stored secrets from inspection. DCR credentials are reused only within the same issuer partition and a changed AS triggers registration in a new partition.

## [1.0.0-rc.5] - 2026-08-04

This release closes the findings of a full-codebase audit (architecture, security,
tests, tooling). Behavior changes are listed under **Breaking Changes** below.

### Security
- **Real DNS-rebinding protection in `ExMCP.HttpPlug`** — Origin validation previously allowed a missing or empty `Origin`, and its same-origin fallback compared `Origin` against the attacker-controlled `Host` header, so the check passed in exactly the scenario it was meant to stop. Host is now validated against an allow-list (`:allowed_hosts`) before routing, mismatches get `421 Misdirected Request`, and the same-origin fallback is gone. `ExMCP.Plugs.DnsRebinding` no longer default-allows `0.0.0.0` and now parses bracketed IPv6 hosts correctly (`[::1]:8080`).
- **Configured TLS options are actually applied to HTTPS POSTs** — `ExMCP.Transport.HTTP.build_ssl_options/1` returned two different shapes; on the POST path the result was spliced into `:httpc` http_options as a flat list, which `:httpc` rejects and ignores (`Invalid option {verify,verify_peer} ignored`). Every configured TLS setting — client certificates for mTLS, private `cacerts`, `versions` — was silently dropped on each request. The builder now returns one shape, wrapped as `{:ssl, opts}` at each call site, and default client TLS adds `customize_hostname_check` so wildcard certificates verify correctly.
- **JWT expiry is now enforced** — `ExMCP.Authorization.JWT` accepted tokens with no `exp` claim, or with a non-numeric `exp`. `exp` is now required and must be numeric (opt out with `require_exp: false`), `nbf`/`iat` types are validated when present, and a `:leeway` option (default 30s) covers clock skew. The asymmetric-only algorithm allow-list is unchanged.
- **Client-supplied session IDs are validated** — `mcp-session-id` (and legacy `x-session-id`) values are checked for format and length instead of being accepted and echoed back unbounded.
- **Consent expiry contract is explicit** — `ExMCP.Security.Consent` accepted a bare integer expiry as a monotonic value, so a handler returning unix seconds granted near-permanent consent. Handlers now return `DateTime`, `{:ttl, _}`, `{:unix, _}`, or `{:monotonic, _}`; implausible values fail closed. Fixes a related unit bug where `:consent_ttl` (milliseconds in config) was passed to handlers as seconds.
- **Security enforcement flags are honored** — `enable_token_passthrough_prevention` and `enable_user_consent_validation` were read nowhere; they now gate their checks in `ExMCP.Transport.SecurityGuard` and are type-validated.
- **Removed a hostname-verification stub** — `ExMCP.Internal.Security.verify_hostname/3` always returned `:valid_peer`; wiring it as a `verify_fun` would have silently disabled hostname checking. Removed, and the module's divergent second TLS-options builder now delegates to the canonical one. `verify: :verify_none` now logs a warning.

### Added
- **Session-scoped HTTP resource subscriptions** — Streamable-HTTP subscriptions
  are retained across POST and SSE requests, tracked independently per client
  session in supervised ETS indexes, and removed on explicit termination or
  TTL expiry. `ExMCP.Server.notify_resource_update/1` broadcasts updates to
  every connected subscriber without routing through a singleton mailbox.
- **Canonical protocol method registry** — `ExMCP.Protocol.Methods` now owns method names, version bounds, message kinds, and dispatcher handlers. Server dispatch, HTTP message processing, request processing, version gating, and message-format metadata all derive from it.
- **Pre-2.0 compatibility guardrails** — committed wire-capability fixtures and characterization tests pin protocol method tables, public error codes, the omitted-version initialize default, and elicitation callback routing across all four supported protocol revisions.
- **Client auto-reconnection** — `ExMCP.Client` now automatically reconnects when the transport closes unexpectedly, as the documentation always promised. Pending requests still fail with a connection error, then the client re-establishes the transport and MCP handshake with exponential backoff and jitter (defaults: initial 1s, multiplier 2, cap 60s, up to 10 attempts). New `start_link/1` options: `:reconnect` (default `true`), `:max_reconnect_attempts`, and `:reconnect_backoff` (`:initial`/`:max`/`:multiplier`). Emits `[:ex_mcp, :client, :reconnect, :attempt | :success | :error | :timeout]` telemetry. Explicit `disconnect/1`/`stop/2` never triggers reconnection; requests made while reconnecting return `{:error, :not_connected}`.
- **Client health checks** — On persistent transports the client sends a protocol `ping` on an interval and treats an unanswered ping as transport loss, handing off to the reconnect path. (The previous health-check timer fired but performed no check.)
- **Working progress tokens** — `call_tool/4` now accepts `:progress_token`, which was previously ignored; it is sent as `_meta.progressToken`, and request-level `_meta` is merged into the arguments map handed to `handle_call_tool/3`, as `ExMCP.Server.Handler` has always documented. Long-running tools can now actually report progress.
- **Shared server dispatch** — New `ExMCP.Server.Dispatch`, `ExMCP.Server.ResultNormalizer`, and `ExMCP.Server.HandlerBridge` give the HandlerServer, stdio, HTTP, and request-processor paths one method table and one result/error shape. stdio gained `completion/complete`, `resources/subscribe`, `resources/unsubscribe`, `roots/list`, `logging/setLevel`, resource templates, and the `tasks/*` methods it was missing.

### Fixed
- **Claude streamed text is emitted once** — Claude SDK terminal assistant text
  no longer repeats content already emitted through text deltas. Multiple
  non-streamed text blocks and distinct identical assistant messages remain
  intact.
- **Codex structured approvals are preserved** — Structured command-execution,
  file-change, and permission responses no longer crash string conversion or
  lose provider fields. Decisions are validated against the advertised
  `availableDecisions` before they are returned.
- **Codex file-change snapshots and legacy patches agree** — Current ordered
  `changes` snapshots are mapped in full, while legacy nested `patch` and flat
  `diff` / `text` / `delta` payloads retain their previous behavior.
- **Raw Handler field names use MCP wire casing** — Shared result normalization
  maps idiomatic fields including `:input_schema`, `:output_schema`,
  `:mime_type`, and `:uri_template` to their protocol names on every server
  dispatch path.
- **HTTP Handler timeout is configurable** — `ExMCP.HttpPlug` now exposes
  `:handler_call_timeout` (default 10 seconds) and threads it into the existing
  MessageProcessor deadline. This server-side deadline is independent of
  client request and SSE timeouts.
- **URL-mode elicitation reaches the URL callback** — `elicitation/create` requests with `mode: "url"` now dispatch to `handle_url_elicitation/3` when implemented. This is the release's one intentional behavior change: handlers implementing both elicitation callbacks will now receive URL-mode requests in the URL callback. Form-only handlers retain a compatibility fallback, receive the URL payload instead of an empty schema, and get a once-per-handler warning.
- **Compliance coverage includes 2025-11-25** — the generated legacy compliance matrix now derives versions from the canonical registry, requires an explicit handler for every version, and carries inherited feature coverage through the newest legacy revision.
- **Transport `close/1` no longer leaks processes** — HTTP and stdio called `Process.exit(pid, :normal)` on processes that do not trap exits (a no-op), leaving the SSE client GenServer and the stdio reader running after close.
- **Async POST state and crashes** — The async POST task's updated transport state (session-ID rotation, refreshed OAuth token) was discarded by the client, so session and auth updates were lost between requests; the task was also unmonitored, so a crash hung the pending request until timeout.
- **SSE handler and session-registry lifetime** — The SSE session table was created lazily inside a Cowboy request process, so every registration vanished when that request ended; it is now owned by a supervised `ExMCP.HttpPlug.SessionRegistry`. SSE handlers stop on conn-owner `:EXIT` and clean up in `terminate/2` instead of leaking with heartbeats still firing.
- **Handler crashes and timeouts return JSON-RPC errors** — `ExMCP.MessageProcessor` ran a per-request handler GenServer whose exits were not caught, so a crash or a call timeout killed the request process and the client got no response at all. Exits are caught and mapped to `-32603`.
- **Handler errors are no longer reported as "Method not found"** — Any `{:error, _}` or exit from a custom method previously became `-32601`; only genuinely unknown methods do now.
- **Batch rejection follows the spec across versions** — Batch support was gated on the exact string `"2025-06-18"`, so 2025-11-25 sessions still accepted JSON-RPC batches. Gating now uses version ordering.
- **Protocol-version defaults unified** — `ExMCP.Plugs.ProtocolVersion`, `MessageProcessor`, `MethodHandlers`, and the default `handle_initialize` disagreed on the default and supported-version list; all now read `ExMCP.Internal.VersionRegistry`.
- **`logging/setLevel` reaches the handler** on the HTTP path instead of being answered with a canned success.
- **Internal detail no longer leaks in error responses** — `inspect(reason)` was embedded in JSON-RPC error data and messages; detail is logged, clients get generic messages.
- **Circuit breaker and reliability wrapper** — A raising function killed the `CircuitBreaker` GenServer through its task link, and `ClientWrapper.execute_with_reliability` spawned unbounded unsupervised tasks while never applying the configured breaker. Both fixed; the wrapper takes `:max_concurrency` (default 100).
- **Retry policy** — `add_jitter/1` raised via `:rand.uniform(0)` for sub-4ms delays, and every exception was treated as retryable.
- **Handshake timeouts** — Client connect and stdio receive had no timeout, so `start_link/1` could hang forever in `init/1` against an unresponsive server; they now return `{:error, :handshake_timeout}`.
- **Request bookkeeping** — Requests with a caller-supplied `:timeout` leaked their pending-request entry forever.
- **`ExMCP.SessionManager` is no longer lazily started** linked to an HTTP request process (it is supervised by the application); `HttpPlug` fails fast with a clear message instead.
- **`clientInfo` version** — The MCP handshake advertised a hardcoded `"0.8.0"`; it is now derived from the application version.
- **Dead code removed** — `HandlerServer`'s unreachable `:start_message_loop` (which evaluated `self()` inside `spawn_link` and would have messaged itself), the unused stdio `:buffer` field, and an unreachable branch in the client's connect path.
- **Test isolation** — `ExMCP.ApplicationTest`, `ProgressTrackerMinimalTest`, and the stdio isolation test stopped the `:ex_mcp` application without restarting it, taking supervised singletons down for every test that ran afterwards.
- **stdio handshake no longer kills the spawned server** — The bounded handshake wait ran the transport's blocking `receive_message/1` inside a temporary task, which took ownership of the port; when that task exited, OTP closed the port and terminated the spawned program, so the very next send failed with `{:send_failed, :badarg}`. `ExMCP.Transport.Stdio` now exposes a timeout-aware `receive_message/2` that runs in the owning process.

### Changed
- **Protocol versions have one source of truth** — `VersionNegotiator` and `ExMCP.Types` delegate version lists/scalars to `VersionRegistry`; unknown-version capability/message-format fallbacks now warn while preserving their existing return values.
- **Error codes have one numeric source** — duplicate JSON-RPC constants and atom maps now delegate to `ExMCP.Protocol.ErrorCodes`. Future header/capability/version codes are additive; the legacy three-way `-32002` collision is documented and unchanged.
- **Test scaffolding out of production code** — `HttpPlug`'s `:test_mode` branch is replaced by `:sse_mode` (`:stream` | `:oneshot`) resolved in `init/1`, SSE conn duck-typing by a `:conn_module` injection point, and `HandlerServer`'s cancellation-state poking by a `:cancellation_tracker` behaviour.
- **Dev tooling out of the published package** — Mix tasks (`test.suite`, `test.tags`, `test.cleanup`, `check_skip_tags`, `mcp.sync_spec`) and `ExMCP.SpecSync` moved to `dev/`, so they no longer ship on Hex or appear in dependents' `mix help`. `ExMCP.Testing.*` remains a supported public test kit.
- **CI** — Integration, performance/stress/slow, and Node interop suites now actually run (they were excluded by default and included by no job); the three identical per-version compliance jobs are collapsed; coverage is broadened; `_build` is cached.
- **Tests** — `Process.sleep`-based synchronization reduced from 296 to 142 occurrences, with the remainder documented where the delay is the thing under test.

### Removed
- **Pre-2.0 dead validation paths** — removed the uncalled method-version validator, its unreachable session-version batch clause, and the empty 2025-03-26 method-gating branch.
- **Dead client state machine modules** — Removed `ExMCP.Client.StateMachine`, `ExMCP.Client.Transitions`, and `ExMCP.Client.States` (unreferenced since the client adapter layer was removed before 1.0; their reconnect/backoff behavior now lives in `ExMCP.Client`), along with their tests, the state-machine-only test transport helper, and the now-unused `gen_state_machine` dependency.
- **`mox`** — Removed from dependencies; it was imported by a single test that used no mock.

### Breaking Changes
- **Batch replies are consistently tagged** — `ExMCP.Client.batch_request/3` replied `{:ok, results}` on success but a bare list on disconnect. It now always returns `{:ok, results} | {:error, reason}`.
- **`ExMCP` facade returns tagged tuples** — The convenience functions in `ExMCP` returned bare values on success and rescued every exception into "Client not responding". They now follow the `{:ok, _} | {:error, _}` convention used everywhere else and rescue narrowly.
- **`ExMCP.Client.connect/2` returns errors instead of throwing** — Invalid transport configuration now yields `{:error, {:invalid_transport_config, reason}}`.
- **JWT validation requires `exp`** — Tokens without a numeric `exp` are rejected unless `require_exp: false` is passed.
- **Consent handler expiry values** — Bare integers are still read as monotonic for compatibility, but implausible values (in the past, or more than 365 days out) now fail closed; prefer the explicit `{:ttl, _}` / `{:unix, _}` / `DateTime` forms. Handlers now receive `:consent_ttl` in seconds (it was mistakenly passed as milliseconds).
- **`ExMCP.Internal.Security.verify_hostname/3` removed**, and `apply_security/2` now includes `cacerts` and `customize_hostname_check` in its TLS options.
- **`ExMCP.Security.Validation.validate_localhost_binding/1`** rejects unrecognised binding shapes instead of passing them through (`{0,0,0,0}` no longer validates as localhost).
- **`ExMCP.Server.Transport`** no longer passes the ignored `tools:` key and defaults `cors_enabled` to `false`, matching `HttpPlug`.
- **Server transports may return `{:ok, state, response}`** — The `ExMCP.Transport` behaviour's `send_message/2` type was widened to admit the 3-tuple the HTTP transport already returned (a widening; existing implementations still conform).

### Deprecated
- **`ExMCP.Server.Tools` API** — `ExMCP.Server.Tools`, `ExMCP.Server.Tools.Simplified`, and companion modules (`Builder`, `Helpers`, `Registry`, `ResponseNormalizer`, `ASTValidator`) are deprecated, retained throughout 1.x, and planned for **removal in 2.0.0**. `use ExMCP.Server.Tools` and `use ExMCP.Server.Tools.Simplified` emit compile-time warnings. Migrate to `ExMCP.Server.Handler` + `ExMCP.Server.DSL` (see the DSL guide and migration guide).
- **Image processing stubs** — Compress/resize/thumbnail/encoding conversion helpers under `ExMCP.Content.Transformer`, `ExMCP.Content.Builders`, and related Validation pipelines are deprecated for **removal in 2.0.0**. They were never required by MCP/ACP (which only define **image content blocks**: base64 + MIME). Use `ExMCP.Content.image/2` for protocol content; do image processing in the application if needed.
- **`remove_metadata` / face-color analysis stubs** — Same deprecation class; not protocol features.

### Improved
- **Protocol sync verification (2026-07-11)** — Confirmed alignment with MCP **2025-11-25**, the latest stable revision on that date, and ACP major **v1**. Official conformance re-run: **39/39** server and **226/226** client (`@modelcontextprotocol/conformance@0.1.16` core suite). All-versions server/client suites green for 2025-11-25 and 2025-06-18. Refreshed local `docs/mcp-specs/2025-11-25` via `mix mcp.sync_spec --force`. Documented that the then-unreleased MCP **2026-07-28** draft/RC was intentionally not implemented yet.
- **SSE bidirectional stability** — `ExMCP.Server.SSESession` waits for a live GET stream (and sole-session fallback), drops dead ETS registrations, cleans up on stream exit, and tolerates int/string request-id echoes. Conformance harness frees port 3099 between runs so elicitation/sampling tools no longer flake with “Server did not request elicitation/sampling”.
- **DSL compile errors** — `ExMCP.Server.DSL` now raises `CompileError`s with file/line and actionable messages for missing handlers, duplicate tool/resource/prompt ids, wrong instructions per declaration kind, unknown instructions (with suggestions such as `inputSchema` → `input_schema`), non-literal values, and invalid param types.
- **DSL docs and examples** — Documented param types, compile-time checks, and `ToolResult` scoping in the DSL guide and quick start; examples note the `ToolResult` alias.
- **1.0 cleanup** — Documented API stability (README / `ExMCP` moduledoc); fixed stale agent docs (`CLAUDE.md`) that still referenced removed client adapters; HexDocs module groups now feature core APIs and group deprecated Tools modules; content modules clarify protocol vs experimental helpers; client list-changed notifications emit telemetry instead of bare TODOs; removed empty `lib` directories and finished docs audit plan file; pruned dead `.dialyzer_ignore.exs` entries.
- **Content schema validation** — `ExMCP.Content.SchemaValidator.validate_schema/2` and `ExMCP.Content.Validation.validate_schema/2` now validate with **ExJsonSchema**.
- **Unicode NFC** — `Sanitizer.normalize_unicode/1` and related Validation sanitization use `:unicode.characters_to_nfc_binary/1`.

### Fixed
- **ACP initialize lifecycle** — `ExMCP.ACP.Client` accepts a bounded
  `:initialize_timeout`, applies it to the full initialize handshake, and closes
  the receiver and transport when initialization fails so spawned stdio agents
  do not outlive a failed client start.
- **Bare `:array` param types** — `param :name, :array` no longer silently maps to a string schema. Use `{:array, :string}` (or another item type). Examples (`advanced_dsl_server`, `weather_service`) were updated accordingly.
- **Empty-list param defaults** — `default: []` is preserved in generated JSON Schema properties.
- **Honest image transform behaviour** — Deprecated resize no longer pretends to change width/height without processing pixels.

## [1.0.0-rc.4] - 2026-07-08

### Added
- **HTTP handler initialization context** — `ExMCP.HttpPlug` now accepts `:handler_opts` as a static term, `Plug.Conn` function, `Plug.Conn` plus decoded request function, or MFA tuple, and passes the resolved value into temporary handler GenServers. This lets Phoenix/Plug pipelines pass verified request context such as authenticated users, tenants, or signed request data into handler `init/1`.

### Fixed
- **MessageProcessor handler startup** — `ExMCP.MessageProcessor` now starts temporary handler GenServers with the configured handler options and consistently assigns `server_info` before dispatching initialize requests.
- **MessageProcessor handler reply normalization** — `ExMCP.MessageProcessor.MethodHandlers` now accepts map-shaped list results and GenServer-style three-tuple replies from handler processes, preserving compatibility with existing handlers while returning MCP tool errors as successful `isError` tool results.
- **Release docs** — Updated active installation snippets and Phoenix request-context examples for the rc.4 release line.

## [1.0.0-rc.3] - 2026-07-03

### Fixed
- **State machine test determinism** — Removed an idle-timeout race from the state machine test transport so successful handshakes are not sampled after the fake transport has already disconnected.

## [1.0.0-rc.2] - 2026-07-03

### Changed
- **ACP protocol updates** — Added current ACP request cancellation support, propagated prompt `messageId` values through client/agent/protocol helpers, and refreshed adapter chunk handling for upstream-compatible message streaming.
- **Codex ACP upstream sync** — Synced `ExMCP.ACP.Adapters.Codex` with `agentclientprotocol/codex-acp` v1.1.0 behavior, including upstream auth ids (`api-key`, `chat-gpt`, and opt-in `gateway`), `read-only`/`agent`/`agent-full-access` modes, app-server `session/delete` through thread archive, additional workspace directories, upstream prompt content shapes, HTTP MCP `http_headers`, per-turn model/mode/reasoning/fast-mode application, `/status`, richer terminal/MCP metadata, usage updates, guardian review, image view, and fuzzy file search events.
- **Claude ACP upstream sync** — Synced `ExMCP.ACP.Adapters.ClaudeSDK` with compatible `agentclientprotocol/claude-agent-acp` v0.55.0 behavior, including Claude Agent SDK 0.3.198 launch metadata, initialize-aware terminal/gateway auth method advertisement, `auth.logout` capability, upstream `mode` config option id, fast-mode and agent config controls when advertised by the SDK, MCP slash-command prompt rewriting, resource-link plus embedded-context prompt shapes, HTTP image prompt support, tool-call-before-permission ordering, Bash terminal metadata, result usage updates, and richer model/agent config option metadata.
- **Pi ACP upstream sync** — Synced `ExMCP.ACP.Adapters.Pi` with compatible `svkozak/pi-acp` v0.0.31 behavior, including upstream-compatible Pi RPC spawn arguments, per-session `model` and `thought_level` config options, config-option sync updates after model/thinking changes, and Pi session listing that prefers latest message activity over later metadata-only timestamps.
- **MCP conformance tooling** — Updated the draft conformance runner pin to the latest published alpha while keeping stable conformance runs on the published `latest` runner.

### Fixed
- **Claude final-result fallback** — `ExMCP.ACP.Adapters.ClaudeSDK` now emits an `agent_message_chunk` from Claude SDK `session_result` text when the SDK completes without streaming message chunks, so ACP clients that accumulate streamed text do not receive an empty answer.

### Breaking Changes
- **Codex ACP mode IDs** — `ExMCP.ACP.Adapters.Codex` now only accepts upstream codex-acp-compatible mode IDs: `read-only`, `agent`, and `agent-full-access`. The older `auto` and `full-access` ids are no longer accepted, along with the prior `suggest`, `auto-edit`, and `full-auto` aliases.

## [1.0.0-rc.1] - 2026-06-15

### Changed
- **BEAM-local MCP cleanup** — Removed the public `ExMCP.Native` direct dispatcher stack, `ExMCP.Service`, and `ExMCP.ServiceRegistry.*`. BEAM-local MCP now uses `transport: :beam` with a server pid, preserving MCP initialization, capabilities, request ids, and tool/resource/prompt semantics.
- **Examples and docs refresh** — Updated README, guides, getting-started docs, and examples to use `ExMCP.Server.Handler` plus `ExMCP.Server.DSL`; removed stale debug/test examples and the placeholder OAuth full-flow script.

### Removed
- **Optional Horde dependency** — Removed the old optional Horde dependency and registry wiring because the Native dispatcher API no longer exists.
- **Legacy Claude ACP adapter** — Removed `ExMCP.ACP.Adapters.Claude`; Claude Code integrations now use `ExMCP.ACP.Adapters.ClaudeSDK`.
- **Unused public cleanup modules** — Removed `ExMCP.ClientConfigEnhanced`, `ExMCP.ClientConfig.Macros`, and the old distributed `ExMCP.Transport.Beam.*` cluster namespace. The active BEAM-local MCP path remains `transport: :beam`.

## [1.0.0-rc.0] - 2026-06-08

### Added
- **Claude SDK ACP adapter** — Added `ExMCP.ACP.Adapters.ClaudeSDK`, a new Claude Code adapter that uses the SDK-compatible stream-json control protocol with permission bridging, partial tool-call lifecycle events, SDK interrupt cancellation, runtime model/mode/effort config, richer status updates, plan updates, and SDK launch environment support.
- **Claude SDK session store** — Added pure Elixir helpers for Claude Code's SDK session store, including SDK-compatible project key derivation, JSONL metadata extraction, sidechain filtering, transcript reads, ACP `session/list`, disk-backed `session/fork`, and validated `session/delete`.
- **Codex ACP parity** — Expanded `ExMCP.ACP.Adapters.Codex` with app-server-backed `session/list`, `session/load`/resume replay, `session/close`, embedded-context prompts, ACP HTTP/stdio MCP descriptor forwarding, Codex auth methods, runtime model/reasoning config updates, `session/set_model`, Codex model catalog state from `model/list`, slash commands (`/compact`, `/init`, `/review`, `/review-branch`, `/review-commit`, `/logout`), and permission request bridging for Codex approval prompts.
- **Pi ACP parity** — Reworked `ExMCP.ACP.Adapters.Pi` around ACP-native session setup/load/list, terminal auth advertisement, model state and `session/set_model`, thinking levels through `session/set_mode`, prompt queuing, image/resource/audio prompt normalization, built-in and markdown slash commands, structured tool updates, edit diffs, session replay, and a pure Elixir Pi session map helper.
- **ACP session fork support** — Added unstable `session/fork` protocol/client/agent/adapter-bridge support, including `ExMCP.ACP.Client.fork_session/4`, native agent `handle_fork_session/3`, adapter `fork_session/2`, and capability auto-advertisement.
- **Adapter bridge direct replies** — Adapter implementations can now return direct JSON-RPC results, emit ACP messages before direct replies, emit messages from notifications, or reply while also writing to the subprocess, so adapted agents can own session IDs, replay history, and runtime config responses without bridge-synthesized placeholders.
- **Adapter-managed bridge mode** — Adapters can now return `:adapter_managed` from `command/1`, own persistent subprocess Ports directly, receive forwarded process messages through `handle_adapter_message/2`, and clean up resources through `shutdown/1`.
- **Adapter auth method advertisement** — ACP adapters can implement `auth_methods/1` so the bridge initialize response reflects implemented authentication methods instead of always returning an empty list.

### Changed
- **ACP docs** — Updated README and the ACP guide to recommend `ClaudeSDK` for new Claude Code integrations while keeping the legacy `Claude` stream-json adapter documented.
- **Claude SDK session capabilities** — The new adapter now advertises live session setup/load/resume/fork/close plus disk-backed `session/list` and `session/delete` support for Claude Code's local SDK store. `session/load` now replays persisted JSONL transcript entries as ACP updates before returning.
- **Claude SDK MCP capabilities** — Replaced legacy `"mcpServers" => true` advertisement with official ACP `mcpCapabilities` and an ExMCP-only `_meta.ex_mcp.mcpCapabilities.beam` flag for BEAM-local MCP transport negotiation.
- **Claude SDK prompt lifecycle** — Claude SDK prompts now queue while another prompt is active and drain in FIFO order after the active prompt result; queued prompts for a cancelled/closed/deleted session receive cancelled prompt responses.
- **Codex adapter session safety** — Codex prompt, cancel, mode, and config requests now require an explicit known `sessionId` instead of falling back to the last active thread. Codex-specific session metadata now lives under `_meta.ex_mcp.codex` instead of a non-spec root `metadata` field.
- **Codex app-server event coverage** — The Codex adapter now handles current app-server camelCase item variants (`commandExecution`, `fileChange`, `mcpToolCall`, `dynamicToolCall`, `webSearch`, `imageGeneration`), reasoning summary deltas, plan/status/goal/compaction notifications, and richer replay of loaded turn history. Unsupported dynamic tool calls, request-user-input prompts, ChatGPT token refresh, and attestation requests are rejected explicitly instead of being treated as approval prompts.
- **Pi adapter ACP surface** — Pi-specific control now uses ACP methods and slash commands instead of custom extension methods. `session/new` and `session/load` wait for Pi state/model/command responses instead of returning bridge-generated placeholder sessions, and `session/list` scans Pi JSONL sessions with optional cwd filtering.
- **Pi adapter remaining parity** — Pi now runs through adapter-managed subprocesses, supports `session/resume`, `session/close`, and `session/delete`, returns paginated `session/list` result maps with `nextCursor`, merges global/project Pi settings, filters skill commands from settings, emits startup/prelude context, adds `/changelog`, improves slash-command result messages, and maps prompt-time auth failures to ACP auth-required errors.
- **Pi destructive defaults** — Pi `session/delete` removes ExMCP session-map state by default and only deletes backing Pi JSONL files when `delete_session_files: true` is configured. Pi registry update notices are opt-in through `update_notice: true` or `PI_ACP_UPDATE_NOTICE=true`.
- **Adapter bridge set_model behavior** — `AdapterBridge` now returns method-not-found when an adapter skips `session/set_model`, instead of synthesizing a successful empty result for an unimplemented model change.

### Fixed
- **HexDocs package contents** — Included the public guide docs in the Hex package and updated ExDoc module grouping so the 1.0 RC documentation builds against current public modules.

### Breaking Changes
- **MCP server DSL compatibility removal** — Removed the legacy `use ExMCP.Server` macro, `deftool`/`defresource`/`defprompt` declarations, generated getter APIs (`get_tools/0`, `get_resources/0`, `get_prompts/0`), `ExMCP.DSL.*` modules, and the old `ExMCP.Server.start_link` helper. Server implementations should use `ExMCP.Server.Handler` directly, optionally combined with `ExMCP.Server.DSL`, and start handler processes with `MyServer.start_link/1`, `ExMCP.Server.HandlerServer.start_link/1`, or `ExMCP.start_server/1`.
- **MCP handler server rename** — Renamed `ExMCP.Server.Legacy` to `ExMCP.Server.HandlerServer` and removed migration-only `MessageProcessor` dispatcher/handler facades for direct/genserver legacy server modes.
- **Server notification spelling** — Removed the legacy `notify_resource_updated` alias. Use `ExMCP.Server.notify_resource_update/2`.
- **Refactor compatibility helpers removed** — Removed unused `ExMCP.Server.RefactorHelpers`, old DSL-oriented `ExMCP.ContentHelpers`, `ExMCP.ErrorHelpers`, and transport `send`/`recv` compatibility aliases. Use `ExMCP.Protocol.ResponseBuilder`, `ExMCP.Content`, `ExMCP.Error`, and transport `send_message/2`/`receive_message/1` respectively.
- **Root protocol wrapper removed** — Removed deprecated `ExMCP.Protocol`. Low-level protocol construction/parsing remains internal; public protocol utility modules under `ExMCP.Protocol.*` remain available.
- **Client adapter switching layer removed** — Removed `ExMCP.Client.Adapter`, `ExMCP.Client.LegacyAdapter`, `ExMCP.Client.StateMachineAdapter`, `ExMCP.Client.Wrapper`, and `ExMCP.Client.Configuration`. Use `ExMCP.Client` as the supported public client API.
- **Handler init arguments are explicit** — `ExMCP.Server.HandlerServer` no longer passes leftover transport/system options to `handler.init/1`. Use `handler_args: term` when a handler needs initialization data.
- **Transport aliases removed** — Removed public `transport: :sse` and `transport: :native`. Use `transport: :http, use_sse: true` for HTTP SSE streaming and `transport: :beam` for BEAM-local MCP transport. BEAM transport now carries MCP-shaped maps/lists as Elixir terms without JSON serialization.
- **ACP BEAM MCP metadata renamed** — ExMCP ACP metadata now advertises BEAM-local MCP support only as `_meta.ex_mcp.mcpCapabilities.beam`; the previous `native` metadata flag and `:native_mcp` builder option were removed.
- **ACP adapter session listing callback** — Custom ACP adapters should implement `list_sessions(params, state)` instead of `list_sessions(state)`. The bridge now forwards decoded `session/list` params directly to adapters and no longer carries the legacy arity.
- **Codex ACP mode IDs** — `ExMCP.ACP.Adapters.Codex` now only accepts upstream codex-acp-compatible mode IDs: `read-only`, `agent`, and `agent-full-access`. The old `suggest`, `auto-edit`, `auto`, `full-auto`, and `full-access` aliases were removed.
- **Adapter authenticate behavior** — `AdapterBridge` no longer returns `{}` for `authenticate` when an adapter skips the request. Unimplemented auth now returns method-not-found or invalid-params, while adapters that write to their subprocess can produce the eventual auth response themselves.
- **Pi extension methods removed** — `ExMCP.ACP.Adapters.Pi` no longer implements `_ex_mcp.pi/*` or legacy `pi/*` control methods. Use `session/set_model`, `session/set_mode`, `session/load`, `session/list`, or prompt slash commands such as `/compact`, `/export`, `/session`, `/name`, `/steering`, and `/follow-up`.

## [0.12.0] - 2026-06-07

### Added
- **ACP functional cores** — Added focused ACP modules for capabilities, lifecycle params, envelopes, metadata, map helpers, name/value normalization, and adapter event normalization. These keep protocol transformation logic pure and easier to test while preserving the existing facade APIs.
- **ACP interoperability coverage** — Expanded integration fixtures and tests for official ACP TypeScript libraries, including everything-style agent/client flows, prompt lifecycle events, auth/logout, permissions, session list/resume/close/delete, and rich content blocks.

### Changed
- **ACP stable spec alignment** — Updated ACP protocol encoding/decoding, session lifecycle params, prompt/session updates, capability builders, MCP server config shapes, extension method names, and adapter output to match the current stable ACP schema.
- **ACP adapter behavior** — Claude, Codex, and Pi adapters now produce normalized stable update events for tool calls, tool call progress, usage, plan/config/mode/session info, and streaming message chunks. Deprecated Pi extension aliases are still accepted, but only `_ex_mcp.pi/*` methods are advertised.
- **Claude adapter permission defaults** — The Claude adapter no longer defaults to `--permission-mode bypassPermissions`; it now inherits the Claude CLI default unless a permission mode is configured explicitly. Permission mode atoms now map to Claude CLI's real mode names.
- **HTTP Plug internals** — Extracted request parsing, session resolution, CORS/origin checks, response shaping, and SSE handling into a smaller functional core so side effects stay at the Plug boundary.

### Fixed
- **Official ACP library compatibility** — Fixed response result shapes, session id propagation, update discriminators, error responses, prompt capability handling, and adapter bridge request handling that prevented clean interop with official ACP SDK clients and agents.
- **MCP HTTP/SSE edge cases** — Hardened streamable HTTP and SSE parsing, session manager selection, response conversion, and structured output wrapping across conformance and integration paths.
- **Client state-machine tests** — Reworked timing-sensitive client tests to use telemetry-driven synchronization instead of sleeps.

### Security
- **MCP HTTP hardening** — OAuth and HTTP guard paths now fail closed on invalid auth state, validate scopes consistently, preserve configured session managers, enforce origin/CORS decisions at the boundary, and keep request body handling bounded.
- **ACP adapter hardening** — Adapter process startup now avoids leaking configured API keys into child environments unless explicitly required, and adapter error responses are normalized before crossing the ACP boundary.

## [0.11.0] - 2026-06-05

### Added
- **ACP Claude adapter — `sessionId` on prompt response result** — `ExMCP.ACP.Adapters.Claude` now includes `"sessionId"` in the prompt response result map when `state.session_id` is non-nil. The field sits alongside the existing optional `"thinking"` blocks and is omitted entirely when no session id is available, so downstream consumers can rely on `Map.has_key?(result, "sessionId")` as an absence signal. Backwards-compatible — callers that ignore it keep working unchanged. Useful for callers that need to correlate a prompt response with the underlying Claude SDK session, drive `--resume` themselves, or attach the session id to audit / telemetry.

## [0.10.1] - 2026-05-29

### Fixed
- **CI test determinism** — Explicitly load target modules before API export assertions so tests do not depend on execution order.

## [0.10.0] - 2026-05-29

### Added
- **Native ACP agents** — `ExMCP.ACP.Agent` and `ExMCP.ACP.Agent.Handler` let Elixir applications implement the agent side of the Agent Client Protocol over the same transports as the ACP client.
- **ACP agent facade helpers** — `ExMCP.ACP.start_agent/1`, `run_agent/1`, and streaming helpers provide a symmetrical API for building controllers and agents.
- **ACP examples** — Added an end-to-end native Elixir ACP echo agent and controller under `examples/acp`.
- **ACP cross-SDK interop fixtures** — Added TypeScript SDK agent/client fixtures plus ExMCP integration tests that cover both directions of ACP controller/agent interoperability.
- **ACP everything-style interop coverage** — Added broad ACP fixtures that exercise auth/logout, session lifecycle, prompt/cancel, mode/config updates, permission requests, filesystem requests, terminal requests, session updates, and rich content blocks.
- **ACP `usage_update` helpers** — Added protocol, type, and agent helper APIs for emitting stable context-window usage updates.

### Changed
- **ACP documentation** — Updated README, examples, and the ACP guide to cover both controller-side and agent-side protocol support.
- **ACP capabilities** — Updated ACP interop agents to use the official schema shape for session capability declarations.

### Fixed
- **ACP streamed prompt isolation** — `ExMCP.ACP.Client` now accumulates streamed `agent_message_chunk` text only while a matching prompt is pending, preventing out-of-band updates such as `session/load` chunks from leaking into the next prompt result.

## [0.9.2] - 2026-05-28

### Added
- **ACP Registry helpers** — `ExMCP.ACP.Registry` can fetch, parse, search, and build `npx` commands from the public ACP Registry.
- **ACP handler runner** — Agent-originated requests and session update handlers now run outside the ACP client process, so slow permission, file, terminal, or update handlers cannot block streamed updates or prompt completion.
- **MCP 2025-11-25 conformance coverage** — Conformance scripts and tests cover the then-latest supported MCP revision and updated server behaviors.

### Changed
- **ACP stable spec alignment** — Updated ACP method names, content/resource builders, permission responses, terminal delegation, config options, prompt capabilities, session capabilities, and adapter update shapes to match the current stable ACP v1 schema.
- **Adapter update normalization** — Claude, Codex, and Pi adapters now emit stable `agent_thought_chunk`, `tool_call`, and `tool_call_update` shapes for core streaming and tool lifecycle events.
- **Prompt text handling** — `Client.prompt/4` now folds streamed `agent_message_chunk` text into the returned result when agents stream the answer instead of returning inline text.

### Fixed
- **Permission cancellation** — `Client.cancel/2` now replies to pending `session/request_permission` requests with the required `cancelled` outcome without waiting for a blocked handler.
- **MCP protocol edge cases** — Updated method handling and version registry tests for newly covered MCP conformance cases.

## [0.9.1] - 2026-04-11

### Added
- **`HttpPlug`: cached body support via `conn.assigns[:raw_body]`** — Upstream
  plugs (e.g., signature-verification auth pipelines) can now pre-read the
  request body and stash it in `conn.assigns[:raw_body]`. The HTTP plug
  checks for a cached body before calling `read_body/1`, avoiding the
  empty-body issue that occurs when the underlying adapter has already
  been consumed by an upstream plug.

  Backwards compatible: callers that don't pre-read the body see no change
  in behavior. The new helper falls through to `read_body/1` when
  `raw_body` is absent.

  Use case: enables HTTP-authentication plugs that need to verify the body
  bytes (e.g., per-request request signing) before ExMCP processes the
  request, without forcing the auth plug to patch ExMCP, swap the conn
  adapter, or replace `ExMCP.HttpPlug` entirely.

## [0.9.0] - 2026-03-18

### Added
- **Pi ACP Adapter** — Full adapter for the Pi coding agent (badlogic/pi-mono) with 25 RPC commands and 14 event types
  - Text/thinking streaming, tool execution lifecycle, auto-compaction/retry events
  - Extension UI request/response bridge for dialog flows
  - Session persistence via `--session` flag, session directory scanning for `session/list`
  - Image support with data-url prefix stripping
  - 6 config options routed to native Pi RPC (model, thinking_level, auto_compaction, auto_retry, steering_mode, follow_up_mode)
- **ACP Spec Compliance** — All stabilized ACP features now implemented
  - `session/list` method (stabilized March 9, 2026)
  - All 8 official session update types: `user_message_chunk`, `agent_message_chunk`, `tool_call_update`, `plan_update`, `available_commands_update`, `config_option_update`, `current_mode_update`, `session_info_update`
  - Content blocks: `audio`, `resource_link`, `resource` (in addition to existing `text`, `image`)
  - `sessionCapabilities` in agent capabilities
  - ACP error codes: `-32000` (auth_required), `-32002` (resource_not_found)
  - Terminal request routing in Client (`terminal/*` methods delegated to handler)
- **Adapter Behaviour Extensions** — 3 new optional callbacks
  - `modes/0` — declare supported operational modes (advertised in initialize response)
  - `config_options/0` — declare supported config options (advertised in initialize response)
  - `list_sessions/1` — return available sessions for `session/list`
- **AdapterBridge Enhancements**
  - `session/list` handler with adapter delegation or empty fallback
  - `session/set_mode` handler with synthesized OK response
  - `session/set_config_option` handler routed through adapters
  - `authenticate` handler with synthesized OK response (RFD draft scaffolding)
  - Initialize response includes modes, configOptions, sessionCapabilities from adapter callbacks
- **Authentication Scaffolding** — protocol authentication encoding, `Client.authenticate/3`, and `Types.auth_required_code/0`
- **Plan Mode Builders** — `Types.plan_entry/3`, `Types.plan_update/2` for structured plan updates

### Changed
- **Claude Adapter** — Zed-parity tool introspection
  - Context-aware tool titles: "Read lib/app.ex (10-29)", "Search: defmodule"
  - Structured metadata: `kind` (read/write/execute/search/think), `locations` (file:line for jump-to-source), `content` (diff/terminal/text)
  - Tool calls now use spec-compliant `tool_call_update` (was non-standard `tool_call`)
  - Tool results include `completed`/`failed` status
  - Project-relative display paths when cwd is known
  - Usage streaming notification emitted before final result
  - System event and rate_limit_event forwarding as status notifications
  - Richer stop reason classification (end_turn, max_tokens, tool_use, error)
  - Declares `config_options` (model, thinking_budget)
- **Codex Adapter** — Tool call lifecycle and enrichments
  - Tool call notifications: `item/created` with `function_call` type
  - Tool completion: `item/completed` for function_call, function_call_output, patch types
  - Command execution lifecycle (started/outputDelta/completed)
  - Web search events (started/completed)
  - Image content in prompts
  - Session resume via `session/load` → `thread/start` with threadId
  - Status notification on turn/completed
  - Declares `modes` (suggest, auto-edit, full-auto) and `config_options` (model)
- **Pi Adapter** — Enhanced tool result parsing matching pi-acp reference
  - Content blocks, diff details, stdout/stderr/exitCode formatting
  - Replaces simpler `extract_tool_content` with full `extract_tool_result_text`

### MCP Protocol Conformance — 100% Client and Server
- **Official MCP Conformance** — 223/223 client checks, 39/39 server checks (0 failures, 0 warnings)
- **Full OAuth 2.1 Authorization Code Flow with PKCE** (`ExMCP.Authorization.FullOAuthFlow`)
  - Protected Resource Metadata discovery (RFC 9728) with path-based and root fallback
  - OIDC/OAuth AS metadata discovery with 4 URL patterns (RFC 8414)
  - Dynamic Client Registration (RFC 7591)
  - Local redirect server for authorization code callback
  - Token endpoint auth method selection (client_secret_basic, client_secret_post, none)
  - Client ID Metadata Document support (CIMD)
  - Scope negotiation from WWW-Authenticate header and PRM scopes_supported
  - Scope step-up on 403 insufficient_scope
  - Resource mismatch validation (RFC 8707)
- **HTTP Transport OAuth Integration**
  - Automatic 401/403 → OAuth discovery → token → retry
  - Auth loop protection (prevents infinite retry)
  - Unified FullOAuthFlow for both pre-existing credentials and browser auth
  - SSE POST response parsing with retry field extraction
  - SSE forced reconnection for pending tool results
  - Last-Event-ID propagation on reconnection
- **Elicitation Support**
  - `ExMCP.Client.ElicitationHandler` — configurable auto-accept/decline
  - Capability-aware routing (method-not-found when not declared)
  - `ExMCP.Testing.SchemaGenerator` — generate test values from JSON Schema
- **Server-Side SSE Sessions** (`ExMCP.Server.SSESession`)
  - Bidirectional SSE for server→client requests (elicitation, sampling)
  - ETS-based pending request tracking
  - GET SSE stream registration and event loop
- **DNS Rebinding Protection** (`ExMCP.Plugs.DnsRebinding`)
- **MessageProcessor Fixes**
  - `deep_stringify_keys` for all handler response paths (atom→string keys)
  - Initialize response normalization for Handler path
  - tools/call result wrapping in `{content: [...]}` format
  - `logging/setLevel` and `completion/complete` handlers
  - Default protocol version updated to `2025-11-25`
- **Test Infrastructure**
  - `scripts/test.sh` — saves output on every run
  - `scripts/conformance.sh` — runs official MCP conformance framework
  - `capture_log: true` — logs shown on test failures
  - Expected-failures baseline for CI
- **HTTP Transport Improvements**
  - URL auto-splitting (extract endpoint from URL path)
  - `:sse` transport alias → HTTP with use_sse: true (was broken)
  - SSE receive loop stability (waiting_for_session, not_supported_in_sync_mode)
  - 405 handling for GET SSE (graceful fallback)
  - SSE retry field parsing and timing buffer

### Removed
- Misleading `supportedModes` from Claude and Codex capabilities (removed features that weren't actually implemented)

## [0.8.4] - 2026-03-10

### Fixed
- `AdapterTransport` receiver loop now uses `:infinity` timeout (was 30s) for `AdapterBridge.receive_message/2`. This prevents spurious `receiver_exited` errors when CLI agents (Claude, Codex) take longer than 30 seconds to produce their first output line — common during complex reasoning or multi-turn tool use. The timeout is now configurable via `receive_timeout:` in transport opts.

## [0.8.3] - 2026-03-09

### Added
- Claude adapter handles multi-turn tool use sequences (`assistant(thinking)→assistant(tool_use)→user(tool_result)→assistant(text)→result`). Emits `tool_call` and `tool_result` session updates for observability.

## [0.8.2] - 2026-03-09

### Fixed
- **BREAKING:** Comprehensive ACP spec conformance audit — align all method names, field names, and message structures with the [ACP specification](https://agentclientprotocol.com/)
  - `session/prompt` params key is `"prompt"` (not `"content"`) per spec
  - `initialize` request uses `"clientCapabilities"` (not `"capabilities"`)
  - `initialize` response reads `"agentCapabilities"` (not `"capabilities"`)
  - Method names use snake_case: `session/set_mode`, `session/set_config_option`, `session/request_permission`
  - File system methods: `fs/read_text_file` / `fs/write_text_file` (not `session/fileRead` / `session/fileWrite`)
  - `session/update` notifications use nested `"update"` object with `"sessionUpdate"` discriminator (not flat `"kind"`)
  - Text updates use `"sessionUpdate": "agent_message_chunk"` with content block (not `"kind": "text"`)
  - Permission options use `"optionId"` field (not `"id"`)
  - Permission response is flat `{"outcome": "selected", "optionId": "..."}` (not wrapped)
  - `fs/write_text_file` response returns `null` result (not empty map)
  - Image content blocks use `"mimeType"` (not `"mediaType"`)
  - Plan entries use `"content"` / `"priority"` (not `"id"` / `"title"`)
  - Capabilities restructured to match spec (`loadSession`, `promptCapabilities`, `mcp`, `fs`, `terminal`)

## [0.8.1] - 2026-03-09

### Fixed
- ACP `session/prompt` message uses correct `"content"` param key instead of `"prompt"` to match the ACP specification

## [0.8.0] - 2026-03-08

### Added
- **Agent Client Protocol (ACP) Support** -- Full implementation of the [Agent Client Protocol](https://agentclientprotocol.com/) for controlling coding agents programmatically
  - `ExMCP.ACP` facade module for quick client startup
  - `ExMCP.ACP.Client` GenServer for managing ACP agent connections over stdio
  - `ExMCP.ACP.Protocol` for ACP-specific JSON-RPC 2.0 message encoding (integer protocol versions, ACP method names)
  - `ExMCP.ACP.Types` with type specifications and builder functions for ACP messages
  - `ExMCP.ACP.Client.Handler` behaviour for handling session events (updates, permission requests, file access)
  - `ExMCP.ACP.Client.DefaultHandler` implementation that auto-allows permissions
- **ACP Adapter System** for non-native agents
  - `ExMCP.ACP.Adapter` behaviour for protocol translation between ACP and agent-native formats
  - `ExMCP.ACP.AdapterBridge` GenServer bridge managing adapted agent subprocesses
  - `ExMCP.ACP.AdapterTransport` transport implementation delegating to the adapter bridge
  - `ExMCP.ACP.Adapters.Claude` -- Adapter for Claude Code CLI (NDJSON stream-json protocol)
  - `ExMCP.ACP.Adapters.Codex` -- Adapter for Codex CLI (app-server JSON-RPC protocol)
- **ACP Session Management** -- Create, resume, prompt, cancel, and configure sessions
  - `session/new`, `session/load`, `session/prompt`, `session/cancel` methods
  - `session/set_mode`, `session/set_config_option` for runtime agent configuration
  - Streaming session updates via notifications
  - Bidirectional communication for permission and file access requests
- **ACP Documentation** -- New [ACP Guide](docs/ACP_GUIDE.md) with usage examples and adapter development instructions

## [0.7.4] - 2026-02-14

### Fixed
- Fixed compile warnings for users without Horde installed -- `ExMCP.ServiceRegistry.Horde` now uses `apply/3` for all `Horde.Registry` calls to avoid compile-time "module is not available" warnings
- Removed 15 dead test files left over from DSL migration (eliminates ExUnit `test_load_filters` warning)

## [0.7.3] - 2026-02-13

### Added
- **OAuth Client Credentials with JWT Authentication** (`private_key_jwt`) -- RFC 7523 Section 2.2 client assertions as an alternative to client secrets for machine-to-machine auth
- **Enterprise-Managed Authorization (ID-JAG)** -- RFC 8693 token exchange + RFC 7523 JWT bearer grants for enterprise SSO flows
- **JWT Infrastructure** (`ExMCP.Authorization.JWT`) -- General-purpose JWT module wrapping JOSE for key management, signing, verification, and claims validation
- **Client Assertion Module** (`ExMCP.Authorization.ClientAssertion`) -- Build and verify JWT client assertions for token endpoint authentication
- **Discovery Flow** (`ExMCP.Authorization.DiscoveryFlow`) -- Full 401-to-discovery-to-auth orchestrator supporting both `client_secret` and `private_key_jwt` methods
- **Token Exchange** (`ExMCP.Authorization.TokenExchange`) -- RFC 8693 token exchange for swapping ID tokens for ID-JAG tokens
- **JWT Bearer Grant** (`ExMCP.Authorization.JWTBearerAssertion`) -- RFC 7523 Section 2.1 JWT bearer authorization grants
- **ID-JAG Creation and Validation** (`ExMCP.Authorization.IdJag`) -- Create and validate ID-JAG JWTs with `typ="oauth-id-jag+jwt"`
- **ID-JAG Server Handler** (`ExMCP.Authorization.IdJagHandler`) -- Server-side processing of JWT bearer grants containing ID-JAG tokens
- **Enterprise Flow** (`ExMCP.Authorization.EnterpriseFlow`) -- Client-side enterprise SSO orchestrator (OIDC -> token exchange -> JWT bearer grant)
- Extended `OAuthFlow` with `client_credentials_jwt_flow/1` for private_key_jwt auth
- Extended `HTTPClient` metadata parsing with `token_endpoint_auth_methods_supported`, `token_endpoint_auth_signing_alg_values_supported`, `issuer`, `jwks_uri`, and `issued_token_type`
- Extended `Validator` with JWT bearer and token exchange grant type validation
- Extended `AuthorizationServerMetadata` with auth method metadata fields
- Extended `TokenManager` with `auth_method` awareness (`:client_secret`, `:private_key_jwt`, `:enterprise_idjag`)
- Added `{:jose, "~> 1.11"}` dependency for JWT operations
- **Pluggable Service Registry** (`ExMCP.ServiceRegistry`) -- Registry abstraction with `Local` (built-in `Registry`, zero deps) and `Horde` adapters for `ExMCP.Native`
- `ExMCP.ServiceRegistry.Local` -- Default adapter using Elixir's built-in `Registry` for single-node service discovery
- `ExMCP.ServiceRegistry.Horde` -- Distributed adapter wrapping `Horde.Registry` for cross-node clusters (opt-in)

### Changed
- `Horde` is now fully optional -- default service registry uses Elixir's built-in `Registry` with zero extra dependencies
- `ExMCP.Native` uses pluggable registry via `ExMCP.ServiceRegistry.adapter()` instead of hardcoded `Horde.Registry`
- Application supervision tree starts the configured registry adapter's child specs instead of hardcoded Horde processes

### Fixed
- All examples updated to use correct DSL syntax (`meta do` + `input_schema`) -- previously used invalid syntax that would fail to compile
- Removed unnecessary Horde references from examples and getting-started guides
- Updated all documentation to present DSL (`use ExMCP.Server`) as the primary server API
- User Guide rewritten to lead with DSL examples; low-level Handler API preserved as one reference section

## [0.7.2] - 2026-02-12

### Fixed
- Aligned Tools DSL `handle_call_tool` with Handler behaviour arity
- Resolved CI failures in compliance test and dialyzer
- Made `ConsentCache.clear/0` synchronous to fix test isolation race condition
- Eliminated Elixir 1.19 type warnings in handler bridge
- Fixed `@before_compile` ordering for GenServer bridge in Elixir 1.19
- Injected GenServer bridge via `__using__` macro for HttpPlug compatibility
- Suppressed dialyzer pattern_match warnings in generated GenServer bridge at the source
- Fixed `@behaviour` vs `use` in handler20250618 compliance test (Elixir 1.17 compat)

## [0.7.0] - 2026-02-11

### Added
- **MCP Protocol Version 2025-11-25 Support** - Added the then-latest protocol version with full spec compliance
- **Streamable HTTP Spec Compliance** - Client and server now fully comply with MCP Streamable HTTP spec:
  - Server provides session ID (not client); first POST omits `Mcp-Session-Id` header
  - `Accept: application/json, text/event-stream` header sent on requests
  - SSE GET handled on same endpoint as POST (not `/sse`)
  - `mcp-protocol-version` header included in all responses
  - POST responses return 200 with JSON body even when SSE is enabled
- **TypeScript MCP SDK Interop Tests** - Verified interoperability with the official TypeScript MCP SDK
- **Agent Simulation Integration Tests** - Integration tests with MockLLM for testing agent workflows
- **<code>mix mcp.sync_spec</code> Task** - Automated task for syncing MCP protocol specifications
- **Conformance Test Suites** - Automated conformance tests for all 4 protocol versions (2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25)
- **Client State Machine Adapter** - Refactored client using GenStateMachine with:
  - Formal state transitions with guards
  - State-specific data structures
  - Comprehensive telemetry events for observability
  - Enhanced reconnection logic with exponential backoff
  - Integration with `ExMCP.ProgressTracker`
- Structured error types with `ExMCP.Error` module
- Comprehensive telemetry instrumentation:
  - `[:ex_mcp, :request, :start/stop]` events
  - `[:ex_mcp, :tool, :start/stop]` events
  - `[:ex_mcp, :resource, :read, :start/stop]` events
  - `[:ex_mcp, :prompt, :get, :start/stop]` events
- Bidirectional communication for MCP server-to-client requests
- Comprehensive protocol version validation

### Changed
- **BREAKING:** Refactored internal architecture of `ExMCP.Server` module
  - Split monolithic 1,488-line module into focused components:
    - `ExMCP.Protocol.ResponseBuilder` - Response formatting
    - `ExMCP.Protocol.RequestTracker` - Request lifecycle management
    - `ExMCP.Protocol.RequestProcessor` - Request routing and handling
    - `ExMCP.Server.Transport.Coordinator` - Transport management
    - `ExMCP.DSL.CodeGenerator` - DSL macro code generation
  - Public API remains unchanged - 100% backward compatible
- Replaced deprecated `preferred_cli_env` with `cli/0` callback
- Reduced cyclomatic complexity in `TestTransport` and `Reliability.Supervisor`

### Fixed
- DSL type narrowing warnings for unreachable clauses (closes #3)
- Test isolation issues in session and property tests
- Conformance test alignment with MCP spec
- ETF deserialization security in BEAM transport
- Security guard robustness against malformed consent handlers
- Flaky security test race conditions
- Test infrastructure race conditions
- HTTP transport communication reliability
- Replaced unsafe `String.to_atom` usage with safe alternatives (atom exhaustion prevention)
- All compiler warnings in test files resolved

### Removed
- 22 stale planning/internal docs from root directory
- 16 stale docs and 5 stale subdirectories from `docs/`
- Non-existent `USER_GUIDE.md` and `EXTENSIONS.md` from hex package file list

### Security
- Prevented atom exhaustion attacks by using string keys instead of dynamic atom creation
- Enhanced ETF deserialization security in BEAM transport

## [0.6.0] - 2025-06-26

### 🎉 Major Release: Production-Ready ExMCP

This release represents the completion of an 18-week comprehensive test remediation and enhancement project that transformed ExMCP from alpha software into a production-ready MCP implementation. **100% MCP protocol compliance achieved** across all supported protocol versions.

### 🏆 18-Week Project Achievements

**📊 Quantitative Results:**
- **100% MCP Compliance**: All 270/270 compliance tests passing across 3 protocol versions
- **Complete Protocol Support**: 2024-11-05, 2025-03-26, and 2025-06-18 MCP specifications
- **High Performance**: <10ms average latency, >100 ops/sec throughput, ~15μs native BEAM calls
- **Comprehensive Testing**: 8 test suites with 95%+ coverage and organized tagging strategy
- **Security Implementation**: OAuth 2.1, TLS/SSL, comprehensive audit logging
- **Documentation**: 80+ documentation files with complete guides and examples

**🛡️ Enterprise-Grade Reliability:**
- Circuit breaker pattern for automatic failure detection and recovery
- Configurable retry policies with exponential backoff
- Health monitoring and connection recovery
- Performance baselines with regression detection
- Comprehensive security audit with OAuth 2.1 compliance

**⚡ Performance & Scalability:**
- Native BEAM service dispatcher with zero serialization overhead
- Cross-node distributed service discovery via Horde.Registry
- Performance profiling infrastructure with baseline establishment
- Concurrent load testing and throughput optimization
- Memory efficiency optimization for production workloads

### Added
- **Comprehensive Python MCP SDK Interoperability Examples**
  - Complete bidirectional integration between ExMCP (Elixir) and Python MCP SDK
  - **Elixir → Python Integration:**
    - `elixir_to_python_stdio.ex` - Elixir clients connecting to Python subprocess servers
    - `elixir_to_python_http.ex` - Elixir clients connecting to Python HTTP servers with load balancing and failover
  - **Python → Elixir Integration:**
    - `python_clients/elixir_client.py` - Python clients connecting to Elixir servers via stdio
    - `elixir_servers_for_python.ex` - Elixir servers with rich schemas designed for Python clients
  - **Python MCP Server Examples:**
    - `python_mcp_servers/calculator_server.py` - Full stdio MCP server with history and statistics
    - `python_mcp_servers/http_server.py` - FastAPI-based HTTP MCP server with REST endpoints
  - **Hybrid Architecture Example:**
    - `hybrid_architecture.ex` - Production-ready architecture combining Native Elixir (~15μs), Python stdio (~1-5ms), and Python HTTP (~5-20ms) services
    - ServiceRegistry for managing multi-language service types
    - HybridOrchestrator with intelligent routing and automatic failover
    - Performance-based service selection and load balancing
  - **Complete Documentation:**
    - Comprehensive setup instructions and prerequisites
    - Performance comparisons across transport types
    - Cross-language JSON-RPC compatibility examples
    - Production deployment patterns and best practices
- **Native Service Dispatcher Migration**
  - Migrated 30+ example files from non-existent `:beam` transport to Native Service Dispatcher pattern
  - Updated examples to use `ExMCP.Service` macro for automatic service registration
  - Enhanced `ExMCP.Native` calls with zero serialization overhead for ultra-high performance
  - Fixed references to internal modules now in `ExMCP.Internal.*` namespace
  - Updated all BEAM transport examples to use Horde.Registry for service discovery
- **Comprehensive Test Tagging Strategy**
  - Implemented test tagging system based on ex_llm approach for efficient test execution
  - Created <code>mix test.suite</code> task with predefined test suites: unit, compliance, integration, transport, security, performance, all, ci
  - Created <code>mix test.tags</code> task to list all available tags and descriptions
  - Added 100+ test files with appropriate module tags for categorization
  - Default exclusions for fast development: integration, external, slow, performance tests excluded by default
  - Test categories: `:unit`, `:integration`, `:compliance`, `:security`, `:performance`, `:transport`, feature-specific tags
  - Transport-specific tags: `:beam`, `:http`, `:stdio` with requirement tags `:requires_beam`, `:requires_http`, `:requires_stdio`
  - Feature tags: `:progress`, `:roots`, `:resources`, `:prompts`, `:protocol`, `:cancellation`, `:batch`, `:logging`
  - Development tags: `:slow`, `:wip`, `:skip`, `:manual_only` for test lifecycle management
  - Reduced default test run time from ~30s to ~5s while maintaining full test coverage
  - Updated test tags from `:sse` to `:http` to align with MCP "Streamable HTTP transport" naming convention
  - Removed unused `ExMCP.Test.MockSSEServer` module and cleaned up references
- **Enhanced Compliance Test Organization**
  - Extracted MCP protocol compliance tests from implementation-specific test files
  - Created 7 new compliance test files by extracting tests from non-compliance files:
    - `cancellation_compliance_test.exs` - Cancellation protocol validation
    - `version_negotiation_compliance_test.exs` - Version negotiation compliance  
    - `roots_compliance_test.exs` - Roots functionality protocol compliance
    - `security_compliance_test.exs` - MCP security requirements
  - All 241 compliance tests now centralized in `test/ex_mcp/compliance/` directory
  - Updated compliance test statistics: 218 passing, 0 failing, 23 skipped
  - Created comprehensive documentation: `TAGGING_STRATEGY.md`, `TAGGING_IMPLEMENTATION.md`, `EXTRACTION_LOG.md`
- **Configurable SSE Endpoint**
  - HTTP transport now supports custom endpoint configuration via `:endpoint` option
  - Defaults to "/mcp/v1" for backward compatibility
  - Handles trailing slashes and empty endpoints properly
  - Example: `ExMCP.Client.start_link(transport: :http, url: "http://localhost", endpoint: "/custom/api")`
- **Progress Token and _meta Field Support**
  - Added `_meta` field support to all MCP request methods in Protocol module
  - Extended Client API to accept `:meta` option for all methods
  - Progress tokens can now be passed via `meta: %{"progressToken" => token}`
  - Backward compatibility maintained for `:progress_token` option in `call_tool/4`
  - All protocol methods now support arbitrary metadata passthrough
  - Server handlers receive _meta in tool arguments (for tools/call) or params (for other methods)
- **OAuth 2.1 Authorization Framework** (MCP 2025-03-26 specification)
  - Full OAuth 2.1 implementation with:
    - Authorization Code Flow with mandatory PKCE (RFC 7636)
    - Client Credentials Flow for service-to-service authentication
    - Authorization Server Metadata Discovery (RFC 8414)
    - Dynamic Client Registration (RFC 7591)
    - Protected Resource Metadata Discovery (RFC 9728 draft)
  - Token Management:
    - Automatic token refresh with configurable window
    - Token rotation for public clients
    - Token validation and introspection support
    - Secure token storage in GenServer state
  - Security Features:
    - PKCE S256 code challenge method required for all authorization code flows
    - HTTPS enforcement for all OAuth endpoints (except localhost)
    - No tokens in URLs - all tokens in headers
    - Bearer token authentication for HTTP transports
  - Integration:
    - `ExMCP.Authorization` module for OAuth flows
    - `ExMCP.Authorization.TokenManager` for automatic token lifecycle
    - `ExMCP.Authorization.PKCE` for code challenge generation/verification
    - Transport-level OAuth support for HTTP streaming and WebSocket
  - Comprehensive test coverage: 217+ passing OAuth tests

- **Production-Grade Reliability Framework**
  - **Circuit Breaker Integration**: Automatic failure detection and recovery across all transports
  - **Enhanced Retry Policies**: Configurable retry strategies with exponential backoff for all MCP operations
  - **Health Monitoring**: Real-time transport and connection health tracking
  - **Connection Recovery**: Automatic reconnection with intelligent backoff strategies
  - **Error Recovery**: Comprehensive error handling and graceful degradation
  - **Reliability Testing**: 100+ integration tests for circuit breakers, retry policies, and health monitoring

- **Performance Infrastructure & Benchmarking**
  - **Performance Profiling Utility**: Comprehensive metrics collection including execution time, memory usage, GC statistics
  - **Baseline Establishment**: Performance baselines stored for regression detection across all operations
  - **Benchmark Test Suites**: 7 comprehensive test suites covering basic operations, payload scaling, concurrent load, throughput
  - **Performance Regression Detection**: Automated comparison against established baselines
  - **Memory Efficiency Tracking**: Detailed memory delta monitoring and optimization
  - **Throughput Optimization**: Benchmarked >100 ops/sec for basic operations with concurrent client support

- **Comprehensive Testing Framework**
  - **8 Organized Test Suites**: Unit, compliance, integration, transport, security, performance, CI, and comprehensive suites
  - **Advanced Test Tagging**: Efficient test execution with 15+ tags for categorization and selection
  - **Cross-Transport Testing**: Comprehensive compatibility tests across stdio, HTTP, SSE, and Native BEAM transports
  - **Integration Test Framework**: End-to-end scenario validation with real component testing
  - **Process Cleanup Automation**: Automated test environment cleanup for reliable test execution
  - **CI/CD Integration**: Complete automated testing pipeline with quality gates

- **Cancellation Protocol Implementation** (MCP specification compliance)
  - Full support for `notifications/cancelled` messages
  - Client-side cancellation API: `ExMCP.Client.send_cancelled/3`
  - Request tracking: `ExMCP.Client.get_pending_requests/1` 
  - Automatic cleanup of cancelled in-progress requests
  - Validation that initialize request cannot be cancelled per spec
  - Proper handling of race conditions and late cancellations
  - Comprehensive test coverage with 12 passing tests

- **Logging Control Implementation** (MCP specification compliance)
  - `logging/setLevel` request handler with RFC 5424 syslog levels
  - Full integration with Elixir's Logger system
  - `ExMCP.Logging` module for centralized logging management
  - Automatic log level conversion between MCP and Elixir formats
  - Structured logging via `notifications/message`
  - Security features:
    - Automatic sanitization of sensitive data (passwords, tokens, keys)
    - Rate limiting support
    - Configurable logger names
  - Comprehensive test coverage with 33 passing tests

- **MCP Specification Compliance Updates**
  - Initialize request batch validation - prevents `initialize` from being part of JSON-RPC batch per spec
  - Audio content type support with `ExMCP.Content` module and examples
  - Completions capability declaration with `hasArguments` and `values` fields
  - Enhanced HTTP transport flexibility:
    - Session management with `Mcp-Session-Id` header
    - Non-streaming mode for single JSON responses
    - Configurable endpoint (defaults to `/mcp/v1`)
    - Resumability support with Last-Event-ID
  - Security requirements enforcement:
    - Origin validation for DNS rebinding protection
    - HTTPS enforcement for non-localhost deployments
    - Localhost binding security checks
    - Enhanced `SecureServer` module with all security features

### Fixed

#### 🔧 18-Week Remediation Project Fixes

**Phase 1: Critical Infrastructure (Weeks 1-4)**
- **Transport Configuration**: Fixed transport selection and configuration inconsistencies
- **Response Migration**: Resolved ExMCP.Response struct vs map access patterns throughout codebase  
- **Error Protocol**: Standardized isError/is_error field handling across all protocol versions
- **Connection State**: Fixed connection status tracking and state machine transitions

**Phase 2: Protocol Compliance (Weeks 5-8)**
- **Protocol Methods**: Implemented missing MCP protocol methods for 100% coverage
- **Message Field Normalization**: Fixed camelCase/snake_case field access inconsistencies
- **Pagination Standardization**: Resolved cursor handling and nextCursor field presence issues
- **Resource Operations**: Fixed resource read protocol compliance and resource/prompt operations

**Phase 3: Reliability & Performance (Weeks 9-12)**
- **Transport Behaviors**: Standardized transport implementations and error handling patterns
- **Connection Validation**: Implemented consistent connection validation across all transports
- **Message Format**: Standardized message format handling and protocol encoding/decoding

**Phase 4: Advanced Features & Testing (Weeks 13-16)**
- **Cross-Transport Compatibility**: Fixed DSL server integration and response format issues
- **Performance Profiling**: Resolved JSON serialization issues in performance metrics storage
- **HTTP Transport Communication**: Identified and documented HTTP/SSE client-server communication issues
- **Integration Framework**: Fixed test infrastructure and end-to-end scenario validation

**Phase 5: Documentation & Validation (Weeks 17-18)**
- **Documentation Completeness**: Updated 80+ documentation files for consistency and accuracy
- **Security Validation**: Confirmed OAuth 2.1 compliance and security audit requirements
- **Final Validation**: Verified 100% MCP compliance maintained across all protocol versions

#### Other Fixes
- All Credo code quality issues resolved (0 issues)
- Logger metadata warnings fixed with proper configuration
- Dialyzer type checking issues resolved across all modules
- Memory leaks and process cleanup issues in test environment
- Performance regression detection false positives
- Security audit logging configuration for production environments

## [0.5.0] - 2025-05-28

### Breaking Changes
- **Removed `:sse` transport identifier** - Use `:http` instead for Streamable HTTP transport
- **Renamed SSE references** - All documentation and APIs now use "HTTP streaming" or "Streamable HTTP" terminology

### Fixed
- **Logging Notification Method Name** - Changed from `notifications/log` to `notifications/message` to match MCP specification exactly

### Added

#### Current MCP Specification (2025-03-26) Features
- **OAuth 2.1 Authorization Support**
  - Full OAuth 2.1 implementation with PKCE support
  - Automatic token refresh before expiration
  - TokenManager GenServer for token lifecycle management
  - Authorization error handling for 401/403 responses
  - Request interceptor for automatic header injection
  - Integration with HTTP transport for seamless auth
  - Example demonstrating OAuth-protected MCP servers
- **Enhanced Streamable HTTP Transport**
  - Automatic reconnection with exponential backoff
  - Built-in keep-alive mechanism (30-second heartbeat)
  - Support for Last-Event-ID header for event resumption with HTTP streaming
  - Improved connection stability and error recovery

#### Draft MCP Specification Features (Experimental)
- **Structured Tool Output** (Draft feature - not in MCP 2025-03-26)
  - Tools can define `outputSchema` in their schema
  - Tool results can include `structuredContent` alongside regular content
  - Marked with "Draft feature" comments in code
- **Logging Level Control** (Draft feature - not in MCP 2025-03-26)
  - Added `logging/setLevel` handler implementation
  - `Client.set_log_level/3` for adjusting server log verbosity
  - `handle_set_log_level/2` callback in server handlers
- **Security Best Practices Implementation** (Draft specification)
  - Token validation with audience checking (prevents confused deputy)
  - Client registration and accountability system
  - Consent management for dynamic client registration
  - Request audit trail maintenance
  - Trust boundary enforcement
  - SecureServer module with built-in security features
  - Security supervisor for managing security components

#### Other Enhancements
- **Lifecycle Management Improvements**
  - Improved BEAM transport server lifecycle (supports reconnections)
  - Dynamic client capability building based on handler
  - Protocol version validation and negotiation
- **Client Roots Tests and Examples** (MCP specification compliance)
  - Comprehensive tests for client roots functionality
  - Root demo showing client-server root exchange
  - Server tools for requesting and analyzing client roots
  - Default handler providing current directory as root
  - Protocol compliance verification for roots/list requests
  - Note: Client roots functionality already fully implemented
- **Progress Notifications Tests and Examples** (MCP specification compliance)
  - Integration tests for progress tracking in long-running operations
  - Progress demo server showing various progress patterns
  - Support for string and integer progress tokens
  - Progress updates with current/total values
  - Note: Progress notifications already fully implemented
- **Server Utilities Tests** (MCP specification compliance)
  - Comprehensive test coverage for pagination across all list operations
  - Completion utility tests for prompt and resource references
  - Logging utility verification with all severity levels
  - Cursor-based pagination with proper error handling
  - Note: All utilities (completion, logging, pagination) already fully implemented
- **Tools Feature Tests** (MCP specification compliance)
  - Comprehensive test coverage for existing tools functionality
  - Tests for tool discovery, invocation, and error handling
  - Verification of isError flag support for tool execution errors
  - Batch tool request testing
  - Multiple content type support (text, image)
  - Progress token support verification
  - Note: Tools functionality including isError support already fully implemented
- **Resources Feature Tests and Examples** (MCP specification compliance)
  - Comprehensive test coverage for existing resources functionality
  - Example server demonstrating various resource types (text, JSON, binary)
  - Support for resource subscriptions and update notifications
  - Resource templates for dynamic URI patterns
  - Pagination support for resource listing
  - Multiple URI schemes (file://, config://, data://, db://)
  - Note: Resources functionality was already fully implemented
- **Prompts Feature Tests and Examples** (MCP specification compliance)
  - Comprehensive test coverage for existing prompts functionality
  - Example server demonstrating various prompt patterns
  - Support for parameterized prompts with required/optional arguments
  - Pagination support for prompt listing
  - Dynamic prompt list changes with notifications
  - Note: Prompts functionality was already fully implemented
- **Ping Utility Tests and Examples** (MCP specification compliance)
  - Comprehensive test coverage for existing ping functionality
  - Health check pattern examples and best practices
  - Bidirectional ping demonstration
  - Connection monitoring and verification patterns
  - Performance measurement examples
  - Note: Ping functionality was already fully implemented
- **Request Cancellation Support** (MCP specification compliance)
  - Complete implementation of `notifications/cancelled` method
  - Client and server can cancel in-progress requests
  - Automatic request tracking and resource cleanup
  - Initialize request cannot be cancelled (as per spec)
  - Graceful handling of unknown/completed requests
  - Malformed cancellation notification validation
  - Comprehensive test coverage and example implementation
- **OAuth 2.1 Authorization Support** (MCP specification compliance)
  - Complete OAuth 2.1 implementation with PKCE support
  - Authorization code flow with mandatory PKCE for security
  - Client credentials flow for application-to-application communication
  - Server metadata discovery (RFC 8414)
  - Dynamic client registration (RFC 7591)
  - Token validation and introspection
  - HTTPS enforcement with localhost development support
  - Comprehensive test coverage for all authorization flows
- Enhanced protocol version negotiation (MCP specification compliance)
  - Handlers now receive client's protocol version in params
  - Servers can check client version and propose alternatives
  - Comprehensive documentation and examples for version negotiation
  - Full test coverage for various negotiation scenarios

### Changed
- **BREAKING:** Renamed SSE transport to HTTP transport (MCP specification update)
  - `ExMCP.Transport.SSE` is now `ExMCP.Transport.HTTP`
  - Use `transport: :http` instead of `transport: :sse`
  - Transport identifier `:sse` is now `:http` (`:sse` still works for compatibility)
  - Updated documentation to reflect "Streamable HTTP" terminology from MCP spec 2025-03-26
  - All tests and examples updated to use new naming

## [0.4.0] - 2025-05-27

### Added
- Tool execution error reporting with `isError` flag (MCP specification compliance)
  - Handlers can return `{:ok, %{content: [...], isError: true}, state}` for tool errors
  - Distinguishes between protocol errors and tool execution errors
  - Full test coverage demonstrating proper error handling
- Pagination support for list methods (MCP specification compliance)
  - Added cursor parameter to `list_tools`, `list_resources`, and `list_prompts`
  - Server handlers now return optional `nextCursor` for paginated results
  - Client API changed to accept options keyword list for cursor and timeout
  - Full test coverage for pagination functionality
- JSON-RPC batch request support (MCP specification compliance)
  - `batch_request/3` client method for sending multiple requests as a batch
  - Server automatically handles batch requests and returns batch responses
  - Full integration tests demonstrating batch functionality
- Bi-directional communication support (server-to-client requests)
  - New `ExMCP.Client.Handler` behaviour for handling server requests
  - Server can ping clients with `ping/2`
  - Server can request client roots with `list_roots/2`
  - Server can request client to sample LLM with `create_message/3`
  - Client automatically advertises capabilities when handler is provided
- Human-in-the-loop (HITL) interaction support
  - `ExMCP.Approval` behaviour for implementing approval flows
  - `ExMCP.Client.DefaultHandler` with built-in approval support
  - `ExMCP.Approval.Console` for terminal-based approval prompts
  - Approval required for LLM sampling requests and responses
  - Support for approving, denying, or modifying requests/responses
  - Full test coverage with approval and HITL integration tests
- WebSocket transport implementation (client-side only)
  - Support for ws:// and wss:// protocols
  - Automatic ping/pong frame handling
  - Full integration with ExMCP transport system
  - TLS/SSL support for secure connections
- Comprehensive security features across all transports
  - New `ExMCP.Security` module for unified security configuration
  - Authentication support: Bearer tokens, API keys, Basic auth, custom headers, node cookies
  - HTTP streaming transport: Origin validation, CORS headers, security headers
  - WebSocket transport: Authentication headers, TLS configuration
  - BEAM transport: Process-level authentication, node cookie support
  - TLS/SSL configuration with certificate validation
  - Mutual TLS support for HTTP streaming and WebSocket transports
  - Comprehensive security documentation in docs/SECURITY.md
- Native format support for BEAM transport
  - `:json` format (default) maintains MCP compatibility
  - `:native` format for direct Elixir term passing between processes
  - Configurable via `:format` option in connect/accept
- HTTP test server for streaming testing
  - Implemented with Plug and Cowboy
  - Supports Server-Sent Events connections and message endpoints
  - Request tracking for test assertions
  - Proper Server-Sent Events streaming with keep-alive

### Changed
- **BREAKING:** Client list methods now take options keyword list instead of timeout
  - `list_tools(client, timeout)` → `list_tools(client, opts \\ [])`
  - `list_resources(client, timeout)` → `list_resources(client, opts \\ [])`
  - `list_prompts(client, timeout)` → `list_prompts(client, opts \\ [])`
  - Options include `:timeout` and `:cursor` for pagination
- **BREAKING:** Server handler callbacks for list methods now include cursor parameter
  - `handle_list_tools(state)` → `handle_list_tools(cursor, state)`
  - `handle_list_resources(state)` → `handle_list_resources(cursor, state)`
  - `handle_list_prompts(state)` → `handle_list_prompts(cursor, state)`
  - All must return 4-tuple with optional `next_cursor`
- SSE transport endpoint is now configurable (was hardcoded to /mcp/v1)
- BEAM transport now supports both JSON and native Elixir term formats

### Fixed
- Dialyzer type errors in WebSocket and BEAM transports
- BEAM transport connection format to support security authentication
- Test compatibility issues with new security features

### Documentation
- Added comprehensive security guide (docs/SECURITY.md)
- Added local copy of MCP specification (docs/mcp-llms-full.txt)
- Updated TASKS.md with detailed compliance status

## [0.3.0] - 2025-05-26

### Added
- Protocol version updated to "2025-03-26" (latest MCP specification)
- Roots capability for URI-based resource boundaries
  - `list_roots/2` client method
  - `handle_list_roots/1` server callback
  - `notify_roots_changed/1` for dynamic root updates
- Resource subscription support
  - `subscribe_resource/3` and `unsubscribe_resource/3` client methods
  - `handle_subscribe_resource/2` and `handle_unsubscribe_resource/2` server callbacks
- Resource templates support
  - `list_resource_templates/2` client method  
  - `handle_list_resource_templates/1` server callback
- Enhanced protocol method support
  - `ping/2` for connection health checks
  - `complete/4` for completion/autocomplete features
  - `send_cancelled/3` for request cancellation notifications
  - `log_message/4` for structured logging
- Tool annotations (readOnlyHint, destructiveHint, idempotentHint, openWorldHint)
- Audio content support (`audio_content` type)
- Embedded resource support in content
- Pagination support with cursor/nextCursor
- RFC-5424 compliant logging levels
- Progress tokens now use `_progressToken` in `_meta` as per spec
- Comprehensive USER_GUIDE.md documentation
- API_REFERENCE.md with complete module documentation
- Enhanced examples for all new features

### Changed  
- **BREAKING**: JSON field names now use camelCase to match official MCP schema
  - `mime_type` → `mimeType`
  - `progress_token` → `_progressToken` (in `_meta`)
  - All response fields follow camelCase convention
- **BREAKING**: ModelHint is now an object with optional `name` field (was array)
- Type specifications completely rewritten to match official schema
- Updated all documentation to reflect protocol version 2025-03-26
- Enhanced capabilities type to include roots and other new features

### Fixed
- Protocol compliance with official MCP schema
- Missing cancellation and logging notification handlers
- Type definitions for multimodal content
- Progress token parameter location (now in `_meta._progressToken`)

## [0.2.0] - 2025-05-26

### Added
- Sampling/createMessage support for LLM integrations
- Change notifications (resources, tools, prompts)
- Progress notifications with token support
- Comprehensive BEAM transport examples
- Code quality tooling (Credo, Dialyzer, Sobelow, ExCoveralls)
- Git hooks for pre-commit and pre-push checks
- GitHub Actions CI/CD pipeline

### Changed
- **BREAKING**: Simplified BEAM transport architecture to Native BEAM transport
  - Removed complex TCP-based BEAM transport modules (`ExMCP.Transport.Beam.Server`, `Client`, etc.)
  - Implemented `ExMCP.Transport.Native` for direct process communication
  - Added Registry-based service discovery and registration
  - Improved performance: ~15μs local calls vs previous TCP overhead
  - Note: Requires migration from old TCP-based API to new service registration pattern

### Fixed
- BEAM transport now properly supports server-initiated notifications
- Documentation discrepancies between claimed and actual features
- Server handler callback specs for sampling support

## [0.1.0] - 2025-05-25

### Added
- Initial release of ExMCP
- Complete Model Context Protocol implementation
- Protocol encoder/decoder for JSON-RPC messages
- Client implementation with automatic reconnection
- Server implementation with handler behaviour
- stdio transport for process communication
- SSE (Server-Sent Events) transport for HTTP streaming
- BEAM transport for native Erlang/Elixir communication
- Tool discovery and execution
- Resource listing and reading
- Prompt management
- Server manager for multiple connections
- Server discovery (npm packages, local directories)
- Request/response correlation
- Concurrent request handling
- Error handling and validation
- Type specifications throughout

### Features
- Full MCP specification compliance
- Multiple transport layer support (stdio, Streamable HTTP with optional SSE, BEAM)
- Both client and server implementations
- Extensible architecture
- Supervision tree integration
