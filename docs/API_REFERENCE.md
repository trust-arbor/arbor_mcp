# Public API entrypoints

Use role-specific modules for new code. Full signatures and types are in
[ArborMCP HexDocs](https://hexdocs.pm/arbor_mcp/2.0.0-rc.2/).
The [migration guide](guides/MIGRATING_V1_TO_V2.md) explains removed APIs,
configuration changes and the different return shapes of retained root wrappers.

| Responsibility | Public API |
| --- | --- |
| Connect and supervise clients | `Arbor.MCP.Client.start_link/1`, `connect/1,2`, `child_spec/1`, `with_connection/2,3` |
| Disconnect or stop a client | `Client.disconnect/1` retains the process; `Client.stop/1,2` terminates it |
| Tools, resources and prompts | `Client.call_tool/3,4`, `read_resource/2,3`, `get_prompt/2,3,4` and `list_*` operations |
| Explicit extraction | `Client.call_content`, `read_content`, `tool_definitions`, `resource_definitions` |
| Collect every list page | `Client.all_tools`, `all_resources`, `all_resource_templates`, `all_prompts` |
| Start, supervise and stop servers | `Arbor.MCP.Server.start_link/1`, `child_spec/1`, `stop/1,2` |
| Server callbacks and declarations | `Server.Handler`, `Server.DSL`, [DSL guide](DSL_GUIDE.md) |
| Callback output and context | `Server.Result`, `Server.Context`, `Content` constructors |
| Complete response fields | `Arbor.MCP.Response`, including `to_raw/1`, `error?/1`, `text_content/1`, `all_text_content/1`, `structured_content/1` |
| Operational inspection | `Client.status/1,2`, `Server.stats/1`, with explicit `status!` / `stats!` variants |
| Mount HTTP in a host | `Arbor.MCP.HttpPlug` with an explicit runtime; [HTTP guide](HTTP_LISTENERS.md) |

Canonical tool, resource and prompt operations return `{:ok, %Arbor.MCP.Response{}}`,
or `{:ok, wire_map}` with `format: :map`. Ordinary list operations for those
features preserve a complete page; other methods use their documented result types.
A delivered tool result with `isError: true` remains a successful protocol
response; inspect it or choose an extraction API. Operational inspection returns
tagged success/error tuples. Pure constructors, predicates and accessors return
bare values.

Pagination collectors share one finite total deadline and page/item/byte
limits. They discard page metadata deliberately; use ordinary `list_*` calls
when that metadata matters. Request options are validated, and unsupported
options raise `ArgumentError`.

`Arbor.MCP` retains compatibility wrappers for existing applications. Its
extracted text/list defaults and legacy startup defaults differ from canonical
Client/Server methods. See the migration guide's
[entrypoint table](guides/MIGRATING_V1_TO_V2.md#canonical-role-entrypoints).

`Arbor.MCP.Server.Runtime` provides documented advanced lifecycle operations.
Application integrations should use the role facade and documented Handler,
store and transport contracts. Internal modules, hidden exports, schedulers,
ledgers and generic actor-call helpers are implementation details.

Across the package family, ACP uses `Arbor.ACP.Client` and `Arbor.ACP.Agent`;
vendor adapters implement the core ACP contract. RPC exposes resource-oriented
`Arbor.RPC.Subprocess`, `FramedStream` and envelope/framing APIs. Native child
write admission does not establish application-level response or consumption.
