# ArborMCP Protocol Guide

How-tos for MCP protocol features that sit beside tools, resources, and
prompts: elicitation, sampling, roots, ping, progress, and cancellation.
Each section shows the handler and the client call. This is not a spec
reprint.

MCP 2026-07-28 deprecated Roots and Sampling. ArborMCP retains their public
APIs in 2.x for pinned legacy protocol revisions. New work should pass directories
through tool parameters or resource URIs, and call an LLM provider API directly.

## Elicitation

A server can pause `tools/call`, `resources/read`, or `prompts/get` and ask
the client for structured input. On MCP 2026-07-28 that pause is an
`input_required` result (MRTR). Enable it on the server and declare the
matching client capability:

```elixir
{:ok, server} = MyServer.start_link(transport: :beam, protocol_mode: :modern_only, mrtr: true)

{:ok, client} =
  Arbor.MCP.Client.start_link(
    transport: :beam,
    server: server,
    protocol_mode: :modern_only,
    capabilities: %{"elicitation" => %{"form" => %{}, "url" => %{}}},
    handler: {MyClientHandler, []}
  )
```

See [Multi Round-Trip Requests](CONFIGURATION.md#multi-round-trip-requests-mcp-2026-07-28)
for key-ring setup. The six elicitation rows below use that path.

### Form mode

The server returns an `elicitation/create` input request with a
JSON Schema 2020-12 `requestedSchema`. The client handler collects values
and returns `action` plus optional `content`.

```elixir
# Server
@impl true
def handle_call_tool("onboard", _args, state) do
  case Arbor.MCP.Server.Context.input_responses() do
    nil ->
      requests = %{
        "profile" =>
          Arbor.MCP.Server.elicit(%{
            message: "Choose a display name",
            requested_schema: %{
              "$schema" => "https://json-schema.org/draft/2020-12/schema",
              "type" => "object",
              "properties" => %{
                "name" => %{"type" => "string"}
              },
              "required" => ["name"]
            }
          })
      }

      {:input_required, requests, %{"step" => "profile"}, state}

    %{"profile" => %{"content" => %{"name" => name}}} ->
      {:ok, %{content: [%{type: "text", text: "Welcome, #{name}"}]}, state}
  end
end

# Client
@impl true
def handle_elicitation_create(message, requested_schema, state) do
  case present_form(message, requested_schema) do
    {:accept, data} ->
      {:ok, %{action: "accept", content: data}, state}

    :decline ->
      {:ok, %{action: "decline"}, state}

    :cancel ->
      {:ok, %{action: "cancel"}, state}
  end
end
```

`Arbor.MCP.Client.call_tool/3` retries the original method with the handler's
response. You do not POST `elicitation/create` yourself on a modern
connection. The raw
`%{"method" => "elicitation/create", "params" => %{"message" => ...,
"requestedSchema" => ...}}` map is equivalent to `Arbor.MCP.Server.elicit/1`.

### URL mode

URL mode sends the user to a page instead of a form. Advertise
`elicitation.url` and implement `handle_url_elicitation/4`:

```elixir
# Server
requests = %{
  "login" =>
    Arbor.MCP.Server.elicit(%{
      message: "Sign in to continue",
      mode: "url",
      url: "https://auth.example.com/login",
      elicitationId: "elicit-login-1"
    })
}

{:input_required, requests, state}

# Client
@impl true
def handle_url_elicitation(message, url, elicitation_id, state) do
  _ = {message, open_browser(url)}

  {:ok, %{action: "accept", content: %{"authenticated" => true}},
   Map.put(state, :elicitation_id, elicitation_id)}
end
```

If the handler only implements `handle_elicitation_create/3`, URL-mode
requests still arrive there. The second argument is then a map with
`"mode"`, `"url"`, and `"elicitationId"`. `handle_url_elicitation/3`
remains for compatibility in v2 and does not receive the id.

### Schema validation

`requestedSchema` is a JSON Schema 2020-12 object
(`https://json-schema.org/draft/2020-12/schema`). Validate accepted content
before returning it:

```elixir
@impl true
def handle_elicitation_create(_message, requested_schema, state) do
  content = collect_from_user(requested_schema)

  case Arbor.MCP.Content.SchemaValidator.validate_schema(content, requested_schema) do
    :ok ->
      {:ok, %{action: "accept", content: content}, state}

    {:error, _errors} ->
      {:ok, %{action: "decline"}, state}
  end
end
```

`Arbor.MCP.Content.SchemaValidator` is an experimental helper. Prefer keeping
schemas small and local; remote `$ref` values are rejected unless you opt
into the [JSON Schema resource policy](CONFIGURATION.md#json-schema-resource-policy).

### Default values

Put `default` on a property. The client can pre-fill the form; the server
still sees whatever the user accepts.

```elixir
"requestedSchema" => %{
  "$schema" => "https://json-schema.org/draft/2020-12/schema",
  "type" => "object",
  "properties" => %{
    "name" => %{"type" => "string", "default" => "guest"},
    "notify" => %{"type" => "boolean", "default" => true}
  },
  "required" => ["name"]
}
```

For automated tests only, `config :arbor_mcp, elicitation_auto_accept: true`
fills defaults through `Arbor.MCP.Client.ElicitationHandler`. Do not enable that
in production.

### Enum values

Constrain a string (or other) field with `enum`:

```elixir
"requestedSchema" => %{
  "$schema" => "https://json-schema.org/draft/2020-12/schema",
  "type" => "object",
  "properties" => %{
    "role" => %{
      "type" => "string",
      "enum" => ["reader", "editor", "admin"],
      "default" => "reader"
    }
  },
  "required" => ["role"]
}
```

The client should only accept one of those values. The same schema is what
`Arbor.MCP.Content.SchemaValidator.validate_schema/2` checks.

### Complete notification

After a URL-mode flow finishes out of band, the client notifies the server
with `notifications/elicitation/complete`. There is no dedicated wrapper;
use `Arbor.MCP.Client.notify/3` with the `elicitationId` from
`handle_url_elicitation/4`:

```elixir
:ok =
  Arbor.MCP.Client.notify(client, "notifications/elicitation/complete", %{
    "elicitationId" => elicitation_id
  })

# Server
@impl true
def handle_elicitation_complete(elicitation_id, state) do
  {:ok, Map.put(state, :last_elicitation, elicitation_id)}
end
```

## Sampling

Sampling lets a server ask the **client** to call a model. MCP 2026-07-28
deprecated it; ArborMCP retains `Arbor.MCP.Server.create_message/2` and
`c:Arbor.MCP.Client.Handler.handle_create_message/2` in 2.x for pinned legacy
protocol revisions. New code should call the LLM provider directly.

```elixir
# Server (legacy server-to-client request, or your own MRTR wrapper)
{:ok, result} =
  Arbor.MCP.Server.create_message(server, %{
    "messages" => [
      %{"role" => "user", "content" => %{"type" => "text", "text" => "Summarize the diff"}}
    ],
    "maxTokens" => 256
  })

# Client — human approval is required
@impl true
def handle_create_message(params, state) do
  case get_user_approval(params) do
    :approved ->
      {:ok,
       %{
         role: "assistant",
         content: %{type: "text", text: "Looks good."},
         model: "gpt-4",
         stopReason: "stop"
       }, state}

    :denied ->
      {:error, "User denied sampling request", state}
  end
end
```

On a modern connection, pause a tool instead of sending an independent
server request:

```elixir
{:input_required,
 %{
   "draft" => %{
     "method" => "sampling/createMessage",
     "params" => %{
       "messages" => [
         %{"role" => "user", "content" => %{"type" => "text", "text" => "Summarize the diff"}}
       ],
       "maxTokens" => 256
     }
   }
 }, state}
```

The client must declare `%{"sampling" => %{}}`. The same
`handle_create_message/2` callback satisfies the MRTR input.

## Roots

Roots are informational directory hints, not an authorization boundary.
MCP 2026-07-28 deprecated them; ArborMCP retains the callbacks in 2.x for
pinned legacy protocol revisions.

```elixir
# Client exposes roots the server may ask for
@impl true
def handle_list_roots(state) do
  {:ok, [%{uri: "file:///projects", name: "Projects"}], state}
end

# Server asks the connected client
{:ok, %{roots: roots}} = Arbor.MCP.Server.list_roots(server)

# Client asks the server (only if the server implements handle_list_roots/1)
{:ok, result} = Arbor.MCP.Client.list_roots(client)

# Server publishes notifications/roots/list_changed
:ok = Arbor.MCP.Server.notify_roots_changed(server)
```

Prefer passing directories or files through tool parameters, resource URIs,
or server configuration.

## Protocol ping

`Arbor.MCP.Client.ping/2` is the protocol liveness check. It is not a tool
named `"ping"`.

```elixir
{:ok, _result} = Arbor.MCP.Client.ping(client)
{:ok, _result} = Arbor.MCP.Client.ping(client, timeout: 2_000)
```

On a legacy connection this sends JSON-RPC `ping`. On a modern
(2026-07-28) connection it calls `server/discover` instead. A server can
also ping the connected client:

```elixir
{:ok, _result} = Arbor.MCP.Server.ping(server)

# Client
@impl true
def handle_ping(state), do: {:ok, %{}, state}
```

## Progress notifications

The client opts in by sending `_meta.progressToken` on a request. The
server reports progress against that token.

```elixir
# Client — token on the request
{:ok, result} =
  Arbor.MCP.Client.call_tool(client, "import", %{}, progress_token: "job-42")

# Client — modern HTTP delivers events to the handler
@impl true
def handle_progress(_request_id, %{"progressToken" => token, "progress" => n} = note, state) do
  _ = {token, n, Map.get(note, "total"), Map.get(note, "message")}
  {:ok, state}
end

# Server — request-scoped, writes notifications/progress on the owning stream
@impl true
def handle_call_tool("import", _args, state) do
  if Arbor.MCP.Server.Context.progress_token() do
    :ok = Arbor.MCP.Server.Context.report_progress(25, 100, "Reading")
    :ok = Arbor.MCP.Server.Context.report_progress(100, 100, "Done")
  end

  {:ok, %{content: [%{type: "text", text: "imported"}]}, state}
end
```

On BEAM, stdio, and other non-stream helpers you can still publish by
token:

```elixir
:ok = Arbor.MCP.Server.notify_progress(server, "job-42", 50)
:ok = Arbor.MCP.Server.notify_progress(server, "job-42", 50, 100)
```

`Arbor.MCP.Client.call_tool/4` also accepts `:meta` and merges it with `:progress_token`.

## Cancellation

Cancel an in-flight request by id. On modern Streamable HTTP this closes
that request's POST response stream. Other transports send
`notifications/cancelled`. The server MAY stop the work.

```elixir
task =
  Task.async(fn ->
    Arbor.MCP.Client.call_tool(client, "slow_import", %{})
  end)

[request_id | _] = Arbor.MCP.Client.get_pending_requests(client)
:ok = Arbor.MCP.Client.send_cancelled(client, request_id, "User cancelled")
```

A server can emit the same notification toward a client request:

```elixir
:ok = Arbor.MCP.Server.cancel_request(server, request_id, "superseded")
```

You cannot cancel `initialize`. `send_cancelled/3` returns
`{:error, :cannot_cancel_initialize}` in that case.

This is request cancellation, not the experimental Tasks extension
(`Arbor.MCP.Client.cancel_task/3`).

A long-running handler can check the current request between steps. The
server MAY stop; ArborMCP does not automatically abort the JSON-RPC request.

```elixir
@impl true
def handle_call_tool("slow_import", _args, state) do
  Enum.reduce_while(import_steps(), {:ok, state}, fn step, {:ok, state} ->
    if Arbor.MCP.Server.Context.cancelled?() do
      {:halt, {:error, "Import cancelled", state}}
    else
      {:cont, run_import_step(step, state)}
    end
  end)
end
```
