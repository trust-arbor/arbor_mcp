# Getting Started With ArborMCP

Start with:

- [QUICKSTART.md](QUICKSTART.md) for a minimal server and client
- [v1-to-v2 migration](../guides/MIGRATING_V1_TO_V2.md) for the package split and current API replacements
- [Historical migrations](MIGRATION.md) for the ExMCP 0.x and 1.x rollout record
- [USER_GUIDE.md](../guides/USER_GUIDE.md) for the full MCP API

ArborMCP supports MCP clients and servers over stdio, Streamable HTTP, and BEAM-local
transports. ACP controllers, agents and optional vendor adapters live in
[ArborACP](https://github.com/trust-arbor/arbor_acp).

MCP `2026-07-28` is the latest stable revision and is available through
`:prefer_modern` and `:modern_only`. The `2.0.0-rc.2` package split is prepared
but not yet published. See the [RC notes](../guides/V2_RELEASE_CANDIDATE.md) for
qualification and known limits. New connections
default to `:prefer_modern`; set `:legacy_only` to preserve the
legacy protocol era (not an exact rc.5 package rollback). See the
[Configuration Guide](../CONFIGURATION.md#protocol-eras-and-modes) before
deploying.

## Current Server Shape

Use `Arbor.MCP.Server.Handler` directly, optionally with the server DSL:

```elixir
defmodule MyServer do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL, name: "my-server", version: "1.0.0"

  tool "echo", "Echoes text" do
    param :message, :string, required: true
    run fn %{message: message}, state -> {:ok, message, state} end
  end
end
```

## Transports

- `:stdio` for subprocess JSON-RPC
- `:http` for Streamable HTTP; modern POST-owned SSE streams need no server flag
- `:beam` for local client/server processes in the same BEAM VM
- `:test` for in-memory tests

The old `ExMCP.Native` direct dispatcher and public `:native` transport alias
were removed before ExMCP 1.0. Use `transport: :beam` with a server PID for BEAM-local
MCP.
