# Getting Started Examples

These examples show the supported ArborMCP transports with the current
`Arbor.MCP.Server.Handler` + `Arbor.MCP.Server.DSL` server API.

## Files

- `01_stdio_server.exs` - subprocess stdio server with a `hello` tool
- `02_http_server.exs` - regular HTTP JSON-RPC server with resources
- `03_http_sse_server.exs` - HTTP JSON-RPC server with SSE enabled
- `04_beam_server.exs` - BEAM-local server for clients in the same VM
- `demo_client.exs` - starts demo servers and exercises all transport types

## Run The Demo

```bash
./run_demo.sh
```

or:

```bash
elixir demo_client.exs
```

**First-run note:** Expect 1–3+ minutes on initial execution due to `Mix.install` inside the server scripts (cached runs are fast). This is the most complete single-command way to see all transports working.

For a fast version of the core patterns (using the compiled library, no repeated installs):

```bash
mix examples.getting_started
```

(See the main [examples/README.md](../README.md) for more options. The implementation lives in `../support/getting_started.exs`.)

## Start Servers Individually

```bash
elixir 01_stdio_server.exs
elixir 02_http_server.exs
elixir 03_http_sse_server.exs
elixir 04_beam_server.exs
```

## BEAM-Local Transport

The `:beam` transport is local to one BEAM VM. Start the server and pass its pid
to the client:

```elixir
{:ok, server} = MyServer.start_link(transport: :beam)
{:ok, client} = Arbor.MCP.Client.start_link(transport: :beam, server: server)
```

It does not use the removed `Arbor.MCP.Native` dispatcher and it does not discover
services through a registry.
