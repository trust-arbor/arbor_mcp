# ArborMCP usage rules

ArborMCP implements MCP clients and servers. The Hex package and OTP application
are `arbor_mcp`; public modules use `Arbor.MCP.*`. These rules describe the 2.x
API. Guide paths below are relative to the installed `arbor_mcp` dependency
directory, usually `deps/arbor_mcp`. Read `README.md`,
`docs/getting-started/QUICKSTART.md` and `docs/guides/MIGRATING_V1_TO_V2.md` for
installation and candidate availability. Library versions and MCP wire revisions
are separate.

## Choose the owning package and API

- Use `Arbor.MCP.Client` for connection, protocol operations and explicit client
  conveniences. Use `Arbor.MCP.Server` for startup, supervision, shutdown,
  statistics and server controls. Define callbacks with `Server.Handler` and
  optionally `Server.DSL`; those modules define behavior rather than lifecycle.
- Start plain handlers with `Arbor.MCP.Server.start_link/1`, passing `handler:`
  and `transport:`. Generated DSL startup delegates to the same constructor.
  Supervise `{Arbor.MCP.Server, handler: MyHandler, transport: :beam}` or your
  DSL module. Startup returns a linked runtime supervisor for every transport;
  the canonical transport default is `:beam`. Select HTTP and stdio explicitly.
- Root client operations remain compatibility wrappers. Their names can hide
  different results/lifetimes; use the role modules in new code.
- ACP clients and agents belong to `arbor_acp` (`Arbor.ACP.*`); built-in vendor
  adapters belong to the optional `arbor_acp_adapters` package. Shared subprocess
  and framing operations belong to `arbor_rpc` (`Arbor.RPC.*`). Declare a direct
  dependency on each package whose APIs your application calls.
- Use documented APIs and behaviours. `Internal` modules, hidden implementation
  bridges and generated component callbacks are not application extension APIs.
  Keep Runtime references opaque; do not inspect or mutate its stores directly.

## Preserve protocol results deliberately

- Canonical Client operations return `{:ok, %Arbor.MCP.Response{}}` by default;
  `format: :map` returns the complete decoded result map. A delivered tool result
  with `isError: true` is still `{:ok, response}` at this layer. Inspect
  `Arbor.MCP.Response.error?/1` before treating it as application success.
- Choose explicit accessors such as `Arbor.MCP.Response.text_content/1`,
  `Arbor.MCP.Response.all_text_content/1` and
  `Arbor.MCP.Response.structured_content/1`.
  `Arbor.MCP.Response.to_raw/1` preserves decoded fields, metadata, extensions,
  cursors and false/null presence. Compare decoded JSON rather than member order.
- Explicit `Arbor.MCP.Client.call_content/4`, `read_content/3`,
  `tool_definitions/2` and `resource_definitions/2` extract content or lists.
  Client `call/4` and `tools/2` remain full-response protocol aliases. Root
  `Arbor.MCP.call/4`, `read/3`, `tools/2` and `resources/2` keep their original
  extraction behavior as compatibility wrappers. Select `format: :map`
  or `:struct` for a complete result, especially when paginating.
  `normalize: false` on `call/4` returns a complete Response struct by default.
  A normalized tool failure returns a ToolError retaining the full result.
- `Client.list_tools/2`, `list_resources/2`, `list_resource_templates/2` and
  `list_prompts/2` return one complete response page. `Client.all_tools/2`,
  `all_resources/2`, `all_resource_templates/2` and `all_prompts/2` explicitly
  collect lists across pages. They discard page metadata and enforce one total
  timeout plus finite `:max_pages`, `:max_items` and `:max_bytes` limits. Errors
  never claim a partial list is complete. Use page methods when metadata matters.
- Resource responses use `contents`. `Client.read_content/3` joins text entries with newlines
  and retains nontext-only results; `parse_json: true` parses extracted text.
  Do not combine an explicit format with `normalize: true` or `parse_json: true`.
  Unsupported facade options raise `ArgumentError`.

## Own lifecycle, deadlines and HTTP mounting

- Supervise long-lived clients and servers. Handle tagged operational errors;
  a local request timeout is `{:error, :timeout}`, distinct from a server's
  JSON-RPC error. Request timeouts are finite non-negative milliseconds.
- `Arbor.MCP.Client.disconnect/1` closes the transport and retains the client
  process; `Client.stop/1,2` terminates it through bounded cleanup. The legacy
  root `Arbor.MCP.disconnect/1` also terminates it. Retain cleanup errors.
- `Arbor.MCP.Client.ping/2` pings an existing connection (or discovers on the
  modern wire revision); `Client.probe/2` initializes a temporary owned client
  and reports success only after scoped cleanup. The server/listener stay borrowed.
- Inspect with tagged `Arbor.MCP.Client.status/2` and `Arbor.MCP.Server.stats/1`;
  their bang variants return a value or raise. Stop a server with `Server.stop/2`.
  A supervisor still applies its child restart policy. A caller timeout alone
  does not prove remote cancellation, completion or cleanup. Do not retry side
  effects blindly.
- Advanced admission, request, await and cancellation APIs remain in
  `Arbor.MCP.Server.Runtime`; ordinary lifecycle and statistics use `Server`.
  Pure constructors and response accessors keep their documented bare values.
- Mount `Arbor.MCP.HttpPlug` with an explicit per-server Runtime in Plug/Phoenix.
  The host owns its listener. Standalone owned listeners require a separately
  selected HTTP backend and its qualified constructor versions. Follow the
  `docs/HTTP_LISTENERS.md` and `docs/RUNTIME_GUIDE.md` for ownership, bounds
  and shutdown.

## Write DSL handlers against the declared contract

```elixir
defmodule MyApp.EchoServer do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL, name: "echo", version: "1.0.0"

  tool "echo", "Echo the input" do
    param :message, :string, required: true

    run fn %{message: message}, state ->
      {:ok, message, state}
    end
  end
end
```

- Follow `docs/DSL_GUIDE.md` for tool, resource, template and prompt
  syntax and callback result forms. Use public result constructors rather than
  calling result-normalization or argument-preparation implementation helpers.
- Declare unique parameter/argument names and scalar instructions. Unknown,
  repeated or contextually invalid options fail compilation with source locations.
  Array parameters require an item type, for example `{:array, :string}`.
- Schema validation does not coerce inputs or insert arbitrary schema defaults.
  Declared parameter defaults are validated; explicit nil/false values retain
  their meaning. Component callbacks receive the host's state and context.
- Keep protocol stdio free of logs and other output; configure host logging to
  stderr. Installing `arbor_rpc` from source on macOS/Linux requires a C17
  compiler even for an HTTP-only or BEAM-only consumer. Assembled releases include
  the helper. See the installation and transport guides for platform limits.
