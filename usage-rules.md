# ArborMCP usage rules

ArborMCP implements MCP clients and servers. The Hex package and OTP application
are `arbor_mcp`; public modules use `Arbor.MCP.*`. These rules describe the 2.x
API. Guide paths below are relative to the installed `arbor_mcp` dependency
directory, usually `deps/arbor_mcp`. Read `README.md`,
`docs/getting-started/QUICKSTART.md` and `docs/guides/MIGRATING_V1_TO_V2.md` for
installation and candidate availability. Library versions and MCP wire revisions
are separate.

## Choose the owning package and API

- Use `Arbor.MCP.Client` for protocol operations and `Arbor.MCP` for convenience
  calls. Use `Arbor.MCP.Server.Handler` with `Arbor.MCP.Server.DSL` for servers.
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
- Convenience `Arbor.MCP.call/4`, `Arbor.MCP.read/3`, `Arbor.MCP.tools/2` and
  `Arbor.MCP.resources/2` extract text or lists by default. Select `format: :map`
  or `:struct` for a complete result, especially when paginating.
  `normalize: false` on `call/4` returns a complete Response struct by default.
  A normalized tool failure returns a ToolError retaining the full result.
- Resource responses use `contents`. `read/3` joins text entries with newlines
  and retains nontext-only results; `parse_json: true` parses extracted text.
  Do not combine an explicit format with `normalize: true` or `parse_json: true`.
  Unsupported facade options raise `ArgumentError`.

## Own lifecycle, deadlines and HTTP mounting

- Supervise long-lived clients and servers. Handle tagged operational errors;
  a local request timeout is `{:error, :timeout}`, distinct from a server's
  JSON-RPC error. Request timeouts are finite non-negative milliseconds.
- Use `Arbor.MCP.Client.stop/1` or `Arbor.MCP.disconnect/1` for client cleanup
  and retain any cleanup error. A caller timeout alone does not prove remote
  cancellation, completion or cleanup. Do not retry side effects blindly.
- `Arbor.MCP.Server.Runtime.stats/1` returns a tagged result;
  `Arbor.MCP.Server.Runtime.stats!/1` explicitly returns a value or raises.
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
