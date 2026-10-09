# ArborMCP

ArborMCP provides Elixir clients and servers for the [Model Context Protocol](https://modelcontextprotocol.io/), with stdio, Streamable HTTP and BEAM-local transports. Its Hex package is `arbor_mcp`; its Elixir module namespace is `Arbor.MCP.*`.

**Version 2 release candidate.** ArborMCP `2.0.0-rc.2` is published on Hex
for downstream integration testing, with ArborRPC on its independent 1.x line.
Stable `arbor_mcp` 2.0 has not been released. The runtime/scheduler redesign and
accepted API cleanup are implemented; the [roadmap](docs/ROADMAP.md) and
[release checklist](docs/RELEASING.md) describe remaining stable qualification.

ExMCP 1.x remains maintained on [`codex/maintenance-1.x`](https://github.com/trust-arbor/arbor_mcp/tree/codex/maintenance-1.x), with backported fixes and compatible minor releases. Migration to v2 is optional; see the [maintenance policy](https://github.com/trust-arbor/arbor_mcp/blob/codex/maintenance-1.x/docs/MAINTENANCE_POLICY.md).

ACP clients, agents and the optional vendor adapter bundle are developed in [ArborACP](https://github.com/trust-arbor/arbor_acp). MCP and ACP depend on the small shared [ArborRPC](https://github.com/trust-arbor/arbor_rpc) package and can be installed independently. ArborRPC has its own repository, with the `arbor_rpc` Mix project at the repository root.

Upgrading from `ex_mcp` 1.x? Start with the [v1-to-v2 migration guide](docs/guides/MIGRATING_V1_TO_V2.md). It covers package selection, namespace and configuration changes, supervision, HTTP mounting, removed APIs and the RC testing checklist. The [RC notes](docs/guides/V2_RELEASE_CANDIDATE.md) describe the candidate's qualification status and known limits.

## Installation

For reproducible downstream RC testing:

```elixir
defp deps do
  [{:arbor_mcp, "== 2.0.0-rc.2"}]
end
```

Run `mix deps.get`. ArborRPC resolves transitively from Hex; add ArborACP or
its optional adapter bundle only when your application uses them. The original
`2.0.0-rc.1` candidate is retired, with its tag and archive preserved.

For development, clone the default branch and resolve dependencies normally:

```sh
git clone https://github.com/trust-arbor/arbor_mcp.git
cd arbor_mcp
mix deps.get
mix compile
mix test
```

`ARBOR_RPC_PATH` optionally selects a local ArborRPC checkout. See the
[development guide](docs/DEVELOPMENT.md) for local source overrides and
[releasing](docs/RELEASING.md) for package checks without those overrides.

The supported minimum is Elixir 1.17 with Erlang/OTP 27. Protocol output uses OTP's JSON encoder. The CI matrix checks multiple Elixir/OTP versions; passing CI and the release gates are required before publishing 2.0.

On macOS/Darwin and Linux, installing the transitive `arbor_rpc` source package
requires a C17 compiler (`cc`, or the executable selected by `CC`), including for
HTTP-only and BEAM-only applications. Source archives contain reviewed C source,
not prebuilt helpers. An installed release includes the built helper and needs
no runtime compiler. Windows native subprocess operations are unsupported;
framing is separate. Only the qualified platform/architecture matrix is supported.

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

## Public entrypoints

Use `Arbor.MCP.Client` for connection, protocol operations and explicit client
conveniences; use `Arbor.MCP.Server` for startup, supervision, controls, statistics
and shutdown. `Server.Handler` defines callbacks and `Server.DSL` adds declarations.
Canonical Client operations preserve complete responses; `call_content`,
`read_content`, `tool_definitions` and `resource_definitions` extract explicitly.
Root client operations remain compatibility wrappers with their original behavior.
See the [entrypoint migration table](docs/guides/MIGRATING_V1_TO_V2.md#canonical-role-entrypoints).

Ordinary Client `list_*` methods preserve one response page. Explicit
`Client.all_tools/2`, `all_resources/2`, `all_resource_templates/2` and
`all_prompts/2` collect lists across opaque cursors within finite page, item,
byte and total-time limits. See the [public API migration guide](docs/guides/MIGRATING_V1_TO_V2.md).

## Servers and transports

Handlers use `Arbor.MCP.Server.Handler` and the declarative `Arbor.MCP.Server.DSL` to define tools, resources and prompts. HTTP, stdio and BEAM use a supervised Runtime per server, bounded handler scheduling and explicit session/subscription storage contracts. Follow the [roadmap](docs/ROADMAP.md) for the accepted contract.

HTTP applications mount `Arbor.MCP.HttpPlug` with an explicit Runtime inside an existing Plug/Phoenix server. Standalone HTTP listeners are optional. Install the selected Cowboy or Bandit dependency and choose `http_adapter: :cowboy` or `:bandit`; Cowboy remains the default. See the [HTTP listener guide](docs/HTTP_LISTENERS.md) for startup, shutdown and mounted-host ownership, and the [transport guide](docs/TRANSPORT_GUIDE.md) for transport contracts.

## Guides and examples

- [Migrate from v1 to v2](docs/guides/MIGRATING_V1_TO_V2.md)
- [Version 2 release candidate](docs/guides/V2_RELEASE_CANDIDATE.md)
- [Quickstart](docs/getting-started/QUICKSTART.md)
- [User guide](docs/guides/USER_GUIDE.md)
- [Phoenix mounting](docs/guides/PHOENIX_GUIDE.md)
- [Server DSL](docs/DSL_GUIDE.md)
- [Runtime operations](docs/RUNTIME_GUIDE.md)
- [Configuration](docs/CONFIGURATION.md)
- [Security](docs/SECURITY.md)
- [Examples](https://github.com/trust-arbor/arbor_mcp/tree/master/examples)
- [Development](docs/DEVELOPMENT.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Changelog](CHANGELOG.md)

Published 1.x API documentation is available at [hexdocs.pm/ex_mcp](https://hexdocs.pm/ex_mcp). It describes the previous package and namespace. The v2 migration guide is available in this checkout and is included in the package and ExDoc documentation.

For v2 API documentation from the checkout, run `mix docs --warnings-as-errors`
after fetching development dependencies. The original RC API docs are at [hexdocs.pm/arbor_mcp/2.0.0-rc.1](https://hexdocs.pm/arbor_mcp/2.0.0-rc.1/). The current RC API docs are at [hexdocs.pm/arbor_mcp/2.0.0-rc.2](https://hexdocs.pm/arbor_mcp/2.0.0-rc.2/). The [documentation index](docs/README.md) separates guides, contributor checks and release policy.

## AI agent guidance

The package ships [usage rules](usage-rules.md) for supported APIs, result
formats, lifecycle and DSL conventions. They are also an ExDoc guide.
Downstream projects with [UsageRules](https://usage-rules.hexdocs.pm/readme.html)
installed as optional development tooling can add this to their `mix.exs`
project configuration:

```elixir
usage_rules: [file: "AGENTS.md", usage_rules: [:arbor_mcp]]
```

Then run `mix usage_rules.sync`. Add other Arbor packages you use to the list.
UsageRules 1.2 requires Elixir 1.18 or newer; shipping these rules adds no
dependency and preserves ArborMCP's Elixir 1.17 minimum.

## Reporting issues

Report suspected vulnerabilities through the
[private vulnerability reporting form](https://github.com/trust-arbor/arbor_mcp/security/advisories/new).
Use [GitHub issues](https://github.com/trust-arbor/arbor_mcp/issues) for other bugs
and feature requests.

Licensed under the [MIT license](https://github.com/trust-arbor/arbor_mcp/blob/master/LICENSE).
