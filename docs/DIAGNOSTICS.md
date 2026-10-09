# Diagnostics and logging

Operational inspection returns tagged results:

```elixir
{:ok, client_status} = Arbor.MCP.Client.status(client)
{:ok, server_statistics} = Arbor.MCP.Server.stats(server)
```

Use the explicit `status!` / `stats!` variants when raising on inspection failure
is appropriate. Inspect documented fields and aggregate counts; private process
state and ETS layouts are not application APIs.

## Payload privacy

Supported runtime and client diagnostic reports replace handler options, state,
requests, prepared output and store data with component names and aggregate
counts. Native supervisors retain opaque constructor functions. Runtime
initialization errors use fixed callback reasons; termination-hook failures use
fixed log text so callback exception values and state are not printed.

This protection covers library formatters and default OTP reports. Host-selected
process names, child IDs, module/function names and stack locations remain
visible. Application logging, custom Logger handlers, explicit tracing and data
retained by application code are host responsibilities. Redact credentials and
tool payloads when reporting a problem.

## Host-owned Logger configuration

Library startup and stdio connection preserve the host's Logger policy. Keep
MCP stdio stdout reserved for protocol bytes and send host diagnostics to stderr.
Follow [logging configuration](CONFIGURATION.md#logging) for the executable
entrypoint's explicit setup.

## Telemetry and cleanup

Attach to documented `[:arbor_mcp, ...]` events. Managed runtime admission and
completion describe local reservations and terminal settlement; completion does
not prove remote consumption. Update event meanings as well as the prefix when
migrating from ExMCP.

Retain tagged timeout, capacity and cleanup errors. Actor/process death alone
does not prove physical IO cleanup; native subprocess receipts distinguish child
reaping, targeted-group absence and uncertainty. See the [runtime guide](RUNTIME_GUIDE.md),
[transport guide](TRANSPORT_GUIDE.md) and
[ArborRPC contract](https://github.com/trust-arbor/arbor_rpc#native-lifecycle-contract).
