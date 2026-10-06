# Getting Started Examples

These examples show the supported ArborMCP transports with the current
`Arbor.MCP.Server.Handler` + `Arbor.MCP.Server.DSL` server API.

## Files

- `01_stdio_server.exs` - subprocess stdio server with a `hello` tool
- `02_http_server.exs` - regular HTTP JSON-RPC server with resources
- `03_http_sse_server.exs` - HTTP server with legacy `/sse` aliases enabled
- `04_beam_server.exs` - BEAM-local server for clients in the same VM
- `demo_client.exs` - starts demo servers and exercises stdio, HTTP and BEAM-local calls

## Run The Demo

```bash
export ARBOR_RPC_PATH=/absolute/path/to/arbor_rpc
cd examples/getting_started # From the MCP repository root.
./run_demo.sh
```

or:

```bash
elixir demo_client.exs
```

**First-run note:** Standalone scripts use `Mix.install` and require a C17
compiler for the RPC source build. Cold dependency resolution/compilation can
take minutes. Inspect each transport's output: failures are printed and skipped,
so the final completion message does not assert that every connection succeeded.

The demo's "HTTP+SSE" branch enables legacy server aliases but uses a normal
modern-preferred HTTP client with `use_sse: false`; it does not exercise a real
2024 `/sse` stream. Modern SSE, legacy Streamable HTTP GET and deprecated 2024
HTTP+SSE are different flows; see the [transport guide](../../docs/TRANSPORT_GUIDE.md).

For a fast version of the core patterns (using the compiled library, no repeated installs):

```bash
# Run from the repository root, not this subdirectory.
mix examples.getting_started
```

This alias uses `:test` and demonstrates the DSL/client API without launching
physical HTTP or stdio peers. See the main [examples/README.md](../README.md)
for more options. Its implementation is `../support/getting_started.exs`.

## Start Servers Individually

```bash
elixir 01_stdio_server.exs
elixir 02_http_server.exs
elixir 03_http_sse_server.exs
elixir 04_beam_server.exs
```

## BEAM-Local Transport

The `:beam` transport is local to one BEAM VM. Start the server and pass its PID
to the client:

```elixir
{:ok, server} = MyServer.start_link(transport: :beam)
{:ok, client} = Arbor.MCP.Client.start_link(transport: :beam, server: server)
:ok = Arbor.MCP.Client.stop(client)
:ok = Arbor.MCP.Server.Runtime.stop(server)
```

It does not use the removed `ExMCP.Native` dispatcher and it does not discover
services through a registry.
