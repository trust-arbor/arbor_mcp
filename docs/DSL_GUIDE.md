# Arbor.MCP Server DSL Guide

Arbor.MCP's server DSL defines MCP tools, resources, resource templates, and prompts
next to the functions that handle them. Use it with `Arbor.MCP.Server.Handler`:

```elixir
defmodule MyServer do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL, name: "my-server", version: "1.0.0"

  tool "echo", "Echo back the input" do
    title "Echo"
    param :message, :string, required: true, description: "Message to echo"

    run fn %{message: message}, state ->
      {:ok, "Echo: #{message}", state}
    end
  end
end
```

This generates the standard `Arbor.MCP.Server.Handler` callbacks for listing and
dispatching declared capabilities. The generated `start_link/1` supports
`:beam`, `:test`, `:stdio`, and `:http` transports. Modern HTTP SSE streams are
owned by the POST request and require no server transport flag. The deprecated
2024-11-05 two-endpoint transport remains available with
`legacy_http_sse: true` throughout Arbor.MCP 1.x.

## Tools

Tools declare input metadata and a `run` handler:

```elixir
tool "add", "Adds two numbers" do
  title "Add"
  param :a, :number, required: true
  param :b, :number, required: true
  annotations readOnlyHint: true

  output_schema %{
    type: "object",
    properties: %{sum: %{type: "number"}},
    required: ["sum"]
  }

  run fn %{a: a, b: b}, state ->
    sum = a + b
    {:ok, ToolResult.structured("#{sum}", %{sum: sum}), state}
  end
end
```

### Param types

| DSL type | JSON Schema |
|----------|-------------|
| `:string` | `{"type": "string"}` |
| `:integer` | `{"type": "integer"}` |
| `:number` | `{"type": "number"}` |
| `:boolean` | `{"type": "boolean"}` |
| `:object` / `:map` | `{"type": "object"}` |
| `{:array, item_type}` | `{"type": "array", "items": ...}` |

```elixir
param :tags, {:array, :string}, default: []
param :scores, {:array, :number}, required: true
```

Bare `:array` is **not** valid — the item type is required so the generated
`inputSchema` is correct.

Use literal schema maps with `input_schema` and `output_schema`. The input map
must have root `type: "object"`; the output schema must also be a map. Standalone
boolean JSON Schemas are valid for `Content.SchemaPolicy`, but `false` is not a
valid MCP Tool descriptor and is rejected rather than replaced by a generated
schema. An omitted or `nil` output schema deliberately disables output validation.
Malformed declarations fail while the handler module compiles.

The pinned MCP 2026-07-28 schema specifies JSON Schema 2020-12, including its
default dialect. The current local validator, ExJsonSchema, implements drafts 4,
6 and 7 and defaults to draft 7 when `$schema` is omitted. Explicit 2020-12
compilation fails; 2020-12-only keyword semantics are not implemented by this
validator. Full modern-dialect validation is an open release gate, not a supported
feature inferred from descriptor pass-through.

Declared params retain existing atom-key convenience and missing-value defaults.
Literal `input_schema` is checked at module compilation but does not add automatic
runtime input validation, default insertion or type coercion. Use tagged
`Content.SchemaPolicy.compile/2` and `validate/3` explicitly when your application
requires standalone validation.

### Response helpers and normalization

`ToolResult` is an **alias** for `Arbor.MCP.Server.DSL.Result`, injected only inside
modules that `use Arbor.MCP.Server.DSL`. Outside those modules, use the fully
qualified module:

```elixir
Arbor.MCP.Server.DSL.Result.structured("done", %{count: 1})
```

`ToolResult` provides `text/1`, `error/1`, and `structured/2`. The DSL also
normalizes several plain return shapes from `run` / `read` / `render`:

| Return from handler | Normalized result |
|---------------------|-------------------|
| `"hello"` | text content |
| `%{text: "hello"}` | text content |
| `%{content: [...]}` | used as-is (plus structured key cleanup) |
| `ToolResult.structured(text, map)` | text + `structuredContent` |
| `{:error, reason}` | tool/resource/prompt error shape |
| `{:ok, result}` or `{:ok, result, state}` | both accepted |

### Image, audio, and embedded resource results

A `run` handler may return several content blocks. Build image, audio, and
embedded-resource items with `Arbor.MCP.Content` (base64 payload plus MIME type):

```elixir
tool "preview", "Return a thumbnail, clip, and attached spec" do
  run fn _args, state ->
    image = File.read!("priv/preview.png") |> Base.encode64()
    audio = File.read!("priv/clip.mp3") |> Base.encode64()

    {:ok,
     %{
       content: [
         Arbor.MCP.Content.image(image, "image/png"),
         Arbor.MCP.Content.audio(audio, "audio/mp3"),
         Arbor.MCP.Content.resource(%{
           uri: "file:///spec.pdf",
           name: "Spec",
           mimeType: "application/pdf"
         })
       ]
     }, state}
  end
end

{:ok, result} = Arbor.MCP.Client.call_tool(client, "preview", %{})
```

`Arbor.MCP.Content.image/2`, `Arbor.MCP.Content.audio/2`, and `Arbor.MCP.Content.resource/1` are protocol content
builders, not image-processing APIs.

## Compile-time checks

Invalid DSL declarations fail at **compile time** with file/line and a fix hint:

```elixir
# Missing handler
tool "echo" do
  param :message, :string
end
# => tool "echo" must define `run` or `handle`, e.g. run fn args, state -> ...

# Bare :array
param :data, :array
# => Invalid param type :array ... Use {:array, item_type}, e.g. {:array, :string}

# Wrong instruction for the declaration kind
tool "echo" do
  arg :message   # arg is only valid on prompts
  run fn _, s -> {:ok, "ok", s} end
end

# Duplicates
tool "echo" do ... end
tool "echo" do ... end
# => Duplicate tool "echo" declared 2 times
```

Other checks include unknown instructions (with suggestions for common
mistakes like `inputSchema` → `input_schema`), non-literal types, empty
names/URIs, and using `run`/`read`/`render`/`mime_type` in the wrong block.

## Resources

Static resources use `resource` and a `read` handler:

```elixir
resource "config://app", "Application configuration" do
  title "App Config"
  mime_type "application/json"

  read fn %{uri: uri}, state ->
    {:ok, %{uri: uri, text: Jason.encode!(%{enabled: true})}, state}
  end
end
```

### Binary (blob) resources

Return `blob` (base64) instead of `text` for binary bodies. The DSL copies
`uri` and `mimeType` onto a `%{blob: ...}` map the same way it does for text:

```elixir
resource "asset://logo.png", "Product logo" do
  mime_type "image/png"

  read fn %{uri: uri}, state ->
    blob = File.read!("priv/logo.png") |> Base.encode64()
    {:ok, %{uri: uri, blob: blob, mimeType: "image/png"}, state}
  end
end

{:ok, contents} = Arbor.MCP.Client.read_resource(client, "asset://logo.png")
```

Resource templates use URI variables and optional typed params:

```elixir
resource_template "file:///{path}", "File contents" do
  title "File"
  mime_type "text/plain"
  param :path, :string

  read fn %{path: path}, state ->
    {:ok, "contents for #{path}", state}
  end
end
```

Template variables are available as atom and string keys.

## Prompts

Prompts declare arguments and a `render` handler:

```elixir
prompt "code_review", "Review code" do
  title "Code Review"
  arg :code, required: true, description: "Code to review"

  render fn %{code: code}, state ->
    {:ok,
     %{
       messages: [
         %{role: "user", content: %{type: "text", text: "Review this code:\n#{code}"}}
       ]
     }, state}
  end
end
```

Returning a string creates a single user text message.

### Image and embedded resource prompt messages

`render` may put image or embedded-resource content on a message, not only
text:

```elixir
prompt "review_screenshot", "Review a screenshot" do
  render fn _args, state ->
    image = File.read!("priv/shot.png") |> Base.encode64()

    {:ok,
     %{
       messages: [
         %{role: "user", content: Arbor.MCP.Content.image(image, "image/png")},
         %{
           role: "user",
           content:
             Arbor.MCP.Content.resource(%{
               uri: "file:///notes.md",
               name: "Notes",
               mimeType: "text/markdown"
             })
         }
       ]
     }, state}
  end
end
```

### Getting a prompt with no arguments

`Arbor.MCP.Client.get_prompt/2` defaults arguments to `%{}`:

```elixir
{:ok, prompt} = Arbor.MCP.Client.get_prompt(client, "review_screenshot")
{:ok, prompt} = Arbor.MCP.Client.get_prompt(client, "code_review", %{"code" => "def add(a, b), do: a + b"})
```

## Metadata

The DSL supports spec-aligned metadata on declarations:

```elixir
tool "search", "Search documents" do
  title "Search"
  icons [%{src: "https://example.com/search.svg", mimeType: "image/svg+xml"}]
  annotations readOnlyHint: true
  meta %{"owner" => "docs"}

  param :query, :string, required: true
  run fn %{query: query}, state -> {:ok, "Searching #{query}", state} end
end
```

Use `title` for display names. Custom extension data belongs under `_meta` via
`meta`.

## Starting Servers

For the generated DSL server:

```elixir
{:ok, pid} = MyServer.start_link(transport: :test)
{:ok, pid} = MyServer.start_link(transport: :stdio)
{:ok, pid} = MyServer.start_link(transport: :http, port: 4000)
```

For a hand-written handler without the DSL:

```elixir
{:ok, pid} =
  Arbor.MCP.Server.HandlerServer.start_link(
    transport: :test,
    handler: MyHandler
  )
```

`Arbor.MCP.start_server/1` is also available as a top-level convenience wrapper for
`Arbor.MCP.Server.HandlerServer.start_link/1`.

**Fast verification tip:** After `mix compile`, `mix examples.getting_started` runs a quick in-process demo of the DSL + client patterns shown throughout this guide (and in QUICKSTART.md).

## Deprecated: `Arbor.MCP.Server.Tools`

`Arbor.MCP.Server.Tools` and `Arbor.MCP.Server.Tools.Simplified` are **deprecated** and
will be retained throughout 1.x, with removal planned for **2.0.0**. They only covered tools (not resources/prompts)
and overlapped with this DSL.

| Old (`Server.Tools`) | New (`Server.DSL`) |
|----------------------|--------------------|
| `use Arbor.MCP.Server.Tools` | `use Arbor.MCP.Server.DSL, name: "...", version: "..."` |
| `tool "name" do ... handle fn ... end end` | `tool "name" do ... run fn ... end end` |
| `handle fn args, state -> ... end` | `run fn args, state -> ... end` |
| (tools only) | also `resource`, `resource_template`, `prompt` |

Using the old modules prints a compile-time deprecation warning.

## Migration From The Removed Legacy DSL

The former `use Arbor.MCP.Server` macro and `deftool`, `defresource`, and
`defprompt` declarations have been removed. Migrate by:

1. Replacing `use Arbor.MCP.Server` with `use Arbor.MCP.Server.Handler` and
   `use Arbor.MCP.Server.DSL`.
2. Replacing `deftool` blocks with `tool` blocks and colocated `run` handlers.
3. Replacing `defresource` blocks with `resource` or `resource_template` blocks
   and colocated `read` handlers.
4. Replacing `defprompt` blocks with `prompt` blocks and colocated `render`
   handlers.
5. Replacing the removed `Arbor.MCP.Server.start_link` helper with `MyServer.start_link/1`,
   `Arbor.MCP.Server.HandlerServer.start_link/1`, or `Arbor.MCP.start_server/1`.

Old generated getters such as `get_tools/0`, `get_resources/0`, and
`get_prompts/0` are no longer part of the server API. Use the standard handler
callbacks instead.
