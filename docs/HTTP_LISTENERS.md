# Standalone HTTP listeners

`arbor_mcp` keeps the HTTP client and `Arbor.MCP.HttpPlug` in core. Standalone
listener dependencies are optional. A client, stdio server or mounted Plug can
compile and run with neither Cowboy nor Bandit installed.

The listener foundation is implemented separately from HTTP runtime routing.
Per-server HTTP runtime ownership, cancellation, store isolation and the
mounted/standalone runtime equivalence gates remain v2 release work.

## Cowboy

Add `{:plug_cowboy, "~> 2.7"}` to the host application. Cowboy remains the
compatibility default, and the optional Cowlib requirement retains the 2.20
security floor whenever the Cowboy stack is selected.

```elixir
{:ok, listener} = Arbor.MCP.Server.Transport.start_http_server(
  MyHandler,
  %{name: "my-server", version: "2.0.0"},
  [],
  http_adapter: :cowboy,
  port: 4000,
  ranch_ref: MyApp.MCPListener
)

:ok = Arbor.MCP.Server.Transport.stop_http_server(MyApp.MCPListener)
```

An explicit `:ranch_ref` retains its Ranch identity. Without one, the reference
remains `Arbor.MCP.HttpPlug.HTTP`, so serving that Plug on multiple ports needs
distinct references. An already started reference keeps the existing
`{:ok, listener_pid}` result. Shutdown accepts that reference or the returned
PID and removes the listener from Ranch supervision.
PID lookup reads only Ranch's root child identities; an unrelated listener's
connections or suspended supervisor cannot delay that lookup.

## Bandit

Add `{:bandit, "~> 1.12 and >= 1.12.5"}` to the host application and explicitly
choose it:

```elixir
{:ok, listener} = Arbor.MCP.Server.Transport.start_http_server(
  MyHandler,
  %{name: "my-server", version: "2.0.0"},
  [],
  http_adapter: :bandit,
  port: 4000,
  http_listener_options: [startup_log: false]
)

:ok = Arbor.MCP.Server.Transport.stop_http_server(listener, http_adapter: :bandit)
```

Bandit's supervisor is linked to its startup caller. It uses the returned PID
for shutdown and rejects `:ranch_ref`. The 1.12.5 floor includes upstream
[HTTP/2 validation and flow-control fixes](https://github.com/mtrudel/bandit/blob/main/CHANGELOG.md#1125-20-aug-2026).

## Configuration and diagnostics

`:http_listener_options` forwards backend-specific options. Top-level `:port`,
`:host`, and Cowboy's `:ranch_ref` take precedence so bind addresses and MCP
Host/Origin defaults remain consistent. This convenience entry point serves
plain HTTP; a host can terminate TLS or mount the Plug in its existing HTTPS
listener. Existing CORS, Host/Origin, path and deprecated HTTP+SSE options are
passed to the same `Arbor.MCP.HttpPlug` for either backend.

The selected package must be installed; installing the other backend does
not change the selection. Missing dependencies return:

```elixir
{:error, {:missing_http_listener_dependency, :cowboy, :plug_cowboy}}
{:error, {:missing_http_listener_dependency, :bandit, :bandit}}
```

Unsupported selections return `{:error, {:unsupported_http_adapter, selection}}`.
`Arbor.MCP.Server.Transport.list_transports/0` reports Cowboy and Bandit
availability separately. `stop_http_server/2` stops only the selected listener.
Both backend shutdowns use a finite `:http_shutdown_timeout` budget (default
`5_000` milliseconds). A timeout returns
`{:error, {:http_listener_operation_timeout, backend, :shutdown}}`; it does not
claim that the listener or its active connections have stopped. Retain the
listener identity and complete cleanup through the host when that happens.
The Bandit adapter rejects PIDs outside its Thousand Island supervisor; Cowboy
PID shutdown resolves a listener under Ranch before removing it.

## Existing hosts

Forward requests to `Arbor.MCP.HttpPlug` from an existing Plug or Phoenix router
using the same handler and authorization options as before. The host owns its
listener and TLS configuration; mounting MCP does not create or stop a listener.
Keep the existing host's lifecycle management when adopting the per-server
HTTP runtime integration in the next milestone.
