# Arbor.MCP

Elixir clients and servers for the [Model Context Protocol](https://modelcontextprotocol.io/), with stdio, Streamable HTTP and BEAM-local transports.

**Version 2 is under development.** This checkout is the MCP part of the library split. The released 1.x package remains [`ex_mcp`](https://hex.pm/packages/ex_mcp); `arbor_mcp` 2.0 has not been released. The runtime integration, public API cleanup and package qualification described in the [v2 roadmap](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/V2_ROADMAP.md) are release work in progress. Historical 1.x test counts and performance results are not v2 qualification evidence.

ACP clients, agents and the optional vendor adapter bundle are developed in [Arbor.ACP](https://github.com/trust-arbor/arbor_acp). MCP and ACP depend on the small shared `arbor_rpc` package and can be installed independently.

## Development checkout

Until the shared package is published, select its checkout explicitly:

```sh
export ARBOR_RPC_PATH=/absolute/path/to/arbor_rpc
mix deps.get
mix compile
mix test
```

`ARBOR_RPC_PATH` is a local development override. Without it, the package declares a normal `{:arbor_rpc, "~> 2.0"}` dependency. For isolated split QA, `ARBOR_V2_DEPS` can point to an existing directory of dependency sources; `ARBOR_V2_BUILD` and `ARBOR_V2_LOCK` select separate build and lock paths. Release checks must also run without those overrides using the packaged artifacts.

The supported Elixir floor is 1.17. The CI matrix checks multiple Elixir/OTP versions; passing CI and the release gates are required before publishing 2.0.

## Client example

```elixir
{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :stdio,
    command: ["mcp-server"],
    protocol_mode: :prefer_modern
  )

{:ok, tools} = Arbor.MCP.Client.list_tools(client, format: :map)
{:ok, result} = Arbor.MCP.Client.call_tool(client, "echo", %{"message" => "hello"}, format: :map)
Arbor.MCP.Client.stop(client)
```

The latest stable MCP revision is `2026-07-28`. `:prefer_modern` allows evidence-based fallback to the legacy protocol era; `:modern_only` and `:legacy_only` select an era explicitly. Library version 2 and the MCP wire revision are separate version identifiers.

## Servers and transports

Handlers use `Arbor.MCP.Server.Handler` and the declarative `Arbor.MCP.Server.DSL` to define tools, resources and prompts. Version 2 introduces a supervised runtime per server, a scheduler for handler work and explicit session/subscription storage contracts. HTTP, stdio and BEAM integration is being migrated to that runtime. Follow the [roadmap](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/V2_ROADMAP.md) for the final contract and qualification status.

HTTP applications can mount `Arbor.MCP.HttpPlug` inside an existing Plug/Phoenix server. Standalone HTTP listeners are optional. Install the selected Cowboy or Bandit dependency and choose `http_adapter: :cowboy` or `:bandit`; Cowboy remains the default. See the [HTTP listener guide](docs/HTTP_LISTENERS.md) for startup, shutdown and mounted hosts. HTTP runtime integration remains v2 release work. The [transport guide](docs/TRANSPORT_GUIDE.md) and [examples](https://github.com/trust-arbor/arbor_mcp/tree/master/examples) are being updated alongside the implementation.

## Guides and examples

- [Getting started](https://github.com/trust-arbor/arbor_mcp/tree/master/docs/getting-started)
- [User guide](docs/guides/USER_GUIDE.md)
- [Server DSL](docs/DSL_GUIDE.md)
- [Configuration](docs/CONFIGURATION.md)
- [Security](docs/SECURITY.md)
- [Examples](https://github.com/trust-arbor/arbor_mcp/tree/master/examples)
- [Changelog](CHANGELOG.md)

Published 1.x API documentation is available at [hexdocs.pm/ex_mcp](https://hexdocs.pm/ex_mcp). It describes the previous package and namespace. Version 2 migration guidance and API documentation will be published with the qualified release.

Licensed under the [MIT license](https://github.com/trust-arbor/arbor_mcp/blob/master/LICENSE).
