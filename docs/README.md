# ArborMCP documentation

| Task | Start here |
| --- | --- |
| Install ArborMCP and make a first call | [Quickstart](getting-started/QUICKSTART.md), [user guide](guides/USER_GUIDE.md) |
| Move from ExMCP 1.x | [Migration guide](guides/MIGRATING_V1_TO_V2.md), [maintenance policy](MAINTENANCE_POLICY.md) |
| Review supported API entrypoints | [Public API reference](API_REFERENCE.md), [server DSL](DSL_GUIDE.md) |
| Host a server | [Runtime guide](RUNTIME_GUIDE.md), [HTTP listeners](HTTP_LISTENERS.md), [Phoenix](guides/PHOENIX_GUIDE.md) |
| Choose limits and storage | [Configuration](CONFIGURATION.md), [storage](STORAGE.md) |
| Understand protocol and validation | [Protocol guide](PROTOCOL_GUIDE.md), [transports](TRANSPORT_GUIDE.md), [schemas](SCHEMAS.md) |
| Diagnose a problem | [Troubleshooting](TROUBLESHOOTING.md), [diagnostics](DIAGNOSTICS.md), [security](SECURITY.md) |
| Contribute or qualify a release | [Development](DEVELOPMENT.md), [roadmap](ROADMAP.md), [releasing](RELEASING.md), [protocol coverage](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/MCP_COVERAGE_MATRIX.md) |

ArborMCP `2.0.0-rc.2` is available for downstream testing. The
[RC testing notes](guides/V2_RELEASE_CANDIDATE.md) describe its known limits and
the remaining stable-release gates. ArborACP and its optional adapters have
their own [guides](https://github.com/trust-arbor/arbor_acp).

Completed implementation notes, historical release plans and audit records are
available in [Git history](https://github.com/trust-arbor/arbor_mcp/tree/6c32d32de623962cef0322b2763068c2965980b6/docs).
The maintained [ExMCP 1.x branch](https://github.com/trust-arbor/arbor_mcp/tree/codex/maintenance-1.x)
retains its own documentation. Frozen API compatibility fixtures live under
`test/fixtures/api`; they remain inputs to the retirement check.
