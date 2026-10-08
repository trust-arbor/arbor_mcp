# ArborMCP

ArborMCP provides Elixir clients and servers for the [Model Context Protocol](https://modelcontextprotocol.io/), with stdio, Streamable HTTP and BEAM-local transports. Its Hex package is `arbor_mcp`; its Elixir module namespace is `Arbor.MCP.*`.

**Version 2 release candidate preparation.** The original `2.0.0-rc.1` is published on Hex. This checkout prepares its replacement `2.0.0-rc.2` with ArborRPC on its independent 1.x line; the replacement is not published yet. The released 1.x package remains [`ex_mcp`](https://hex.pm/packages/ex_mcp); `arbor_mcp` 2.0 has not been released. The supervised Runtime and accepted API cleanup are implemented; final package and release qualification remain in progress. See the [release assessment](https://github.com/trust-arbor/arbor_mcp/blob/codex/v2-migration/docs/V2_RELEASE_ASSESSMENT.md) for the qualified source checkpoints and open gates. Historical 1.x test counts and performance results are not v2 qualification evidence.

ExMCP 1.x remains maintained on [`codex/maintenance-1.x`](https://github.com/trust-arbor/arbor_mcp/tree/codex/maintenance-1.x), with backported fixes and compatible minor releases. Migration to v2 is optional; see the [maintenance policy](https://github.com/trust-arbor/arbor_mcp/blob/codex/maintenance-1.x/docs/MAINTENANCE_POLICY.md).

ACP clients, agents and the optional vendor adapter bundle are developed in [ArborACP](https://github.com/trust-arbor/arbor_acp). MCP and ACP depend on the small shared [ArborRPC](https://github.com/trust-arbor/arbor_rpc) package and can be installed independently. ArborRPC has its own repository, with the `arbor_rpc` Mix project at the repository root.

Upgrading from `ex_mcp` 1.x? Start with the [v1-to-v2 migration guide](docs/guides/MIGRATING_V1_TO_V2.md). It covers package selection, namespace and configuration changes, supervision, HTTP mounting, removed APIs and the RC testing checklist. The [RC notes](docs/guides/V2_RELEASE_CANDIDATE.md) describe the candidate's qualification status and known limits.

## Development checkout

For downstream RC testing after publication, use an exact dependency pin:

```elixir
defp deps do
  [{:arbor_mcp, "== 2.0.0-rc.2"}]
end
```

This pulls in shared ArborRPC. Add ArborACP or the optional adapter bundle only
when your application uses them. Replacement RC publication is still pending; the local
checkout setup below works without treating the candidate as a published package.

The MCP migration branch is `codex/v2-migration`; the default `master` branch
still contains ExMCP 1.x. ArborRPC is a separate repository on `main`. To test the prepared replacement before publication, select both source checkouts explicitly:

```sh
git clone --branch codex/v2-migration https://github.com/trust-arbor/arbor_mcp.git
git clone --branch codex/independent-package-versions https://github.com/trust-arbor/arbor_rpc.git
cd arbor_mcp
export ARBOR_RPC_PATH="$(pwd)/../arbor_rpc"
mix deps.get
mix compile
mix test
```

`ARBOR_RPC_PATH` is a local development override. Without it, the package declares a normal Hex dependency with an explicit development/RC prerelease floor; stable ArborRPC requirements retain the `~> 1.0` compatible range. See the [package release guide](docs/V2_PACKAGE_RELEASE.md). For isolated split QA, `ARBOR_V2_DEPS` can point to an existing directory of dependency sources; `ARBOR_V2_BUILD` and `ARBOR_V2_LOCK` select separate build and lock paths. Release checks must also run without those overrides using the packaged artifacts.

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

## Servers and transports

Handlers use `Arbor.MCP.Server.Handler` and the declarative `Arbor.MCP.Server.DSL` to define tools, resources and prompts. HTTP, stdio and BEAM use a supervised Runtime per server, bounded handler scheduling and explicit session/subscription storage contracts. Follow the [roadmap](https://github.com/trust-arbor/arbor_mcp/blob/codex/v2-migration/docs/V2_ROADMAP.md) for the accepted contract.

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
- [Examples](https://github.com/trust-arbor/arbor_mcp/tree/codex/v2-migration/examples)
- [Development](docs/DEVELOPMENT.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Changelog](CHANGELOG.md)

Published 1.x API documentation is available at [hexdocs.pm/ex_mcp](https://hexdocs.pm/ex_mcp). It describes the previous package and namespace. The v2 migration guide is available in this checkout and is included in the package and ExDoc documentation.

For v2 API documentation from the checkout, run `mix docs --warnings-as-errors`
after fetching development dependencies. The original RC API docs are at [hexdocs.pm/arbor_mcp/2.0.0-rc.1](https://hexdocs.pm/arbor_mcp/2.0.0-rc.1/). Replacement RC documentation follows its publication. Repository-only release assessments
remain separate from the consumer guides shipped in the source package.

## Reporting issues

Report suspected vulnerabilities through the
[private vulnerability reporting form](https://github.com/trust-arbor/arbor_mcp/security/advisories/new).
Use [GitHub issues](https://github.com/trust-arbor/arbor_mcp/issues) for other bugs
and feature requests.

Licensed under the [MIT license](https://github.com/trust-arbor/arbor_mcp/blob/codex/v2-migration/LICENSE).
