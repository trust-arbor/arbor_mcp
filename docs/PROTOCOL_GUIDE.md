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

The same handler serves legacy clients. A legacy revision has no
`input_required` result, so the server sends each input request to the client
as the request it stands for (`elicitation/create`, `sampling/createMessage`
or `roots/list`), then calls the callback again with the answers in
`Arbor.MCP.Server.Context.input_responses/0` and the application state in
`Context.request_state/0`, as the TypeScript, Go and C# SDKs do. Each request
waits under what remains of the original request's deadline, a client error
fails the call, and a callback that asks for input more than 10 times fails
with `-32603`. A request is sent only if the connection's negotiated
revision defines it and the client declared the capability (`elicitation`,
`sampling` or `roots`) in `initialize`, so pass `capabilities:` to the client.
Over legacy HTTP the requests go out on the session's stream, so the client
must have one open.

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

A client that forwards the call for another client, such as a gateway, lets
that client answer instead. With `mrtr: :manual` the round comes back as
`{:input_required, %{input_requests: requests, request_state: state, meta: meta}}`,
and `input_responses:` and `request_state:` continue the call; with
`client_capabilities:` the request declares the other client's capabilities:

```elixir
{:input_required, %{input_requests: requests, request_state: state}} =
  Arbor.MCP.Client.call_tool(client, "onboard", %{},
    mrtr: :manual,
    client_capabilities: downstream_capabilities
  )

answers = ask_downstream(requests)

{:ok, result} =
  Arbor.MCP.Client.call_tool(client, "onboard", %{},
    mrtr: :manual,
    client_capabilities: downstream_capabilities,
    input_responses: answers,
    request_state: state
  )
```

Each round repeats the arguments, capabilities and progress token, so
`reset_timeout_on_progress: true` needs an explicit `:progress_token` here. See
[Forwarding clients](CONFIGURATION.md#forwarding-clients-mcp-2026-07-28).

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

# Server, started with execution: :stateful so callbacks can update state
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

# Client — example implementation of recommended human approval
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

This example deliberately requests human approval. For legacy MCP Sampling, the specification recommends human review but does not require a specific approval UI or mandate this callback-level check as a wire-protocol rule. Client applications may choose their own review workflow.

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

# Client — the handler receives each update, on every transport
@impl true
def handle_progress(_request_id, %{"progressToken" => token, "progress" => n} = note, state) do
  _ = {token, n, Map.get(note, "total"), Map.get(note, "message")}
  {:ok, state}
end

# Server — request-scoped, on every transport
@impl true
def handle_call_tool("import", _args, state) do
  if Arbor.MCP.Server.Context.progress_token() do
    :ok = Arbor.MCP.Server.Context.report_progress(25, 100, "Reading")
    :ok = Arbor.MCP.Server.Context.report_progress(100, 100, "Done")
  end

  {:ok, %{content: [%{type: "text", text: "imported"}]}, state}
end
```

Outside a callback, or for another request's token, publish by token:

```elixir
:ok = Arbor.MCP.Server.notify_progress(server, "job-42", 50)
:ok = Arbor.MCP.Server.notify_progress(server, "job-42", 50, 100)
```

`Arbor.MCP.Client.call_tool/4` also accepts `:meta` and merges it with `:progress_token`.

### Progress to another process

With `progress_to: pid`, a request's progress also goes to `pid`, alongside
the handler, as
`{:arbor_mcp_progress, client, progress_token, params}`. `client` is the
client process, so a process that waits on several clients can tell them
apart, and `params` is the notification's params, as `handle_progress/3` gets
them. A process that forwards a request for another client, such as a
gateway, relays it from there:

```elixir
caller = self()

task =
  Task.async(fn ->
    Arbor.MCP.Client.call_tool(client, "import", %{},
      progress_to: caller,
      progress_token: "job-42"
    )
  end)

receive do
  {:arbor_mcp_progress, ^client, "job-42", %{"progress" => progress} = params} ->
    _ = Arbor.MCP.Server.Context.report_progress(progress, params["total"], params["message"])
end
```

- **A token is added if the request has none,** as for
  `reset_timeout_on_progress`, since progress names its request only by
  token. Under automatic MRTR every round already shares the request's
  token, so each round's progress arrives.
- **Manual MRTR needs an explicit token.** With `mrtr: :manual` on
  `call_tool/4` or `get_prompt/4`, pass `:progress_token` yourself and
  repeat it on every round. Without one, the call returns a
  `ValidationError`, because a generated token would differ between rounds.
  `read_resource/3` takes no progress token, so a manual read can't use
  `progress_to:` or `reset_timeout_on_progress`. It returns the same
  `ValidationError`.
- **Delivery stops once the call returns,** with a result, an error, a
  timeout or a cancellation, even while the client is still cleaning up
  after a caller's own `:timeout`. The client measures the caller's
  deadline on its own clock, so a caller on another node gets its progress
  whatever that node's clock says. Progress that arrives later, as late
  notifications on stdio or legacy HTTP can, isn't sent.
- **Delivery stops when the caller goes down,** whether or not
  `cancel_on_caller_exit:` cancels the request: the client monitors the
  caller of every request with a target. That works for a caller on another
  node too. If the connection to the caller's node is lost, the monitor
  fires with `:noconnection` and delivery stops, even though the caller may
  still be running there. A target on another node gets its updates by plain
  message, so updates sent while its node is unreachable are lost.
- **A request's target gets only that request's progress.** A message on a
  modern request stream that names another request's token is dropped. After
  a request settles, its token is held back for a second, the client's
  cleanup grace: progress naming it on the connection reaches no target, so
  a late notification can't reach a newer request that reuses the token.
  Such a newer request gets its progress at its target only once that
  second has passed.
- **An `input_required` round doesn't settle its call.** Its token and
  target stay reserved until the round's deadline, or the client's default
  timeout when the round had none, for the round's own continuation.
  - **Who can claim it:** a request with the same method and name that
    presents the `request_state` the round returned, or, if the server
    returned none, answers the same input request ids. Automatic MRTR's
    rounds do this by themselves. A manual continuation claims it with
    `request_state:` and the same `:progress_token`.
  - **What a claim gets:** the round's target, unless the continuation
    names its own `progress_to:`.
  - **Anyone else:** any other request with the token starts as usual, but
    its target gets nothing while the reservation lasts. Neither does a
    continuation that comes after the round's deadline.
  - **Expiry:** once the round's deadline has passed, the token is held back
    for a second more, as for a settled request.
  - **Limits:** a round that can't be identified within the request's own
    MRTR limits reserves nothing. That covers a `requestState` over
    `:max_mrtr_bytes`, or input requests over `:max_input_requests` or of
    the wrong shape. Its token is held back like a settled request's. A
    continuation whose `request_state:` is over its `:max_mrtr_bytes`
    claims nothing.
  - **Tombstones still apply:** a claim never ends a hold left by an earlier
    request that used the token.
- **Use tokens that are unique on the connection.** The client's generated
  tokens are. A gateway that forwards downstream requests shouldn't reuse
  downstream tokens upstream, since different downstream clients may pick
  the same ones: generate a token per downstream request and map back to the
  downstream token when relaying.
- **A dead target misses the updates.** The request goes on, and the handler
  still gets them.
- **Every transport that carries progress delivers it:** modern Streamable
  HTTP request streams, legacy Streamable HTTP (on a POST's event stream or
  the session's GET stream), stdio, BEAM and the test transport.

### Keeping a long request alive

As with the TypeScript SDK's `resetTimeoutOnProgress`, a request made with
`reset_timeout_on_progress: true` times out only once it has gone `:timeout`
milliseconds (or the client's default) without progress, and
`:max_total_timeout` caps it however much progress it makes. The client adds a
progress token if the request has none.

```elixir
{:ok, result} =
  Arbor.MCP.Client.call_tool(client, "import", %{},
    timeout: 30_000,
    reset_timeout_on_progress: true,
    max_total_timeout: :timer.hours(2)
  )
```

Without `:max_total_timeout` there is no overall limit. Over HTTP the
transport's `:request_timeout` doesn't cut such a request off, but a modern
request stream that carries nothing for `:stream_idle_timeout` (60 s by
default) still closes.

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

### When the caller exits

A request is also cancelled when the process waiting for it exits while it
is in flight, for example a `Task` that is shut down or a process that
crashes mid-call. Nobody will read the result, so the client cancels it as
it would at a timeout: over modern Streamable HTTP it closes the request's
POST or request stream, and elsewhere it sends `notifications/cancelled`.
If the caller exits during an MRTR round, while the client handler is still
answering the round's input requests, that handler is stopped too.

This is on by default for modern (2026-07-28) requests. On a legacy
connection it happens only when the call asks for it, since there it sends a
`notifications/cancelled` that legacy peers did not get before. The
`:cancel_on_caller_exit` option decides per call:

- absent or `nil`: the era's default, as above (`nil` leaves an option
  unset, so a gateway can pass options through unfiltered);
- `true` or `false`: on or off, on either era;
- anything else raises `ArgumentError`.

Every request function takes it, the `all_*` list helpers included, which
pass it to each page request, and so does the `tools/list` refresh a
`tools/call` makes after a header mismatch on its caller's behalf. Batches
(`batch_request/3`, `send_batch/3`) are the exception: they take only a
timeout and aren't cancelled when their caller exits. JSON-RPC batching is a
legacy feature, removed from MCP in 2025-06-18.

```elixir
# A modern request that should finish even if its caller goes away.
Arbor.MCP.Client.call_tool(client, "publish", %{}, cancel_on_caller_exit: false)

# A legacy request that should be cancelled with its caller.
Arbor.MCP.Client.call_tool(client, "slow_import", %{}, cancel_on_caller_exit: true)
```

Each such cancellation emits `[:arbor_mcp, :client, :request, :caller_exited]`
with the request's `method` and `request_id`. A request that completed before
its caller exited is left alone.

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
