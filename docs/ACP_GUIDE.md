# ACP Guide

The [Agent Client Protocol (ACP)](https://agentclientprotocol.com/) is a standardized protocol for controlling coding agents programmatically. ExMCP includes a full ACP client implementation, letting you start agent sessions, send prompts, receive streaming updates, and handle permission requests — all from Elixir. It also includes `ExMCP.ACP.Agent` for building native Elixir ACP agents.

## Overview

ACP uses JSON-RPC 2.0 over stdio (the same wire format as MCP) with methods for session management and bidirectional communication. Most coding agents speak ACP natively. For agents with their own protocols (Claude Code, Codex, Pi, and ZCode), ExMCP provides an adapter system that translates between ACP and the agent's native protocol.

### Architecture

```
Your Elixir App
    │
    ▼
ExMCP.ACP.Client (GenServer)
    │
    ├─── Native ACP agents (Gemini CLI, Hermes, OpenCode, Qwen Code, ...)
    │       └── stdio JSON-RPC directly
    │
    └─── Adapted agents (Claude Code, Codex, Pi, ZCode)
            └── AdapterBridge → Adapter → agent-native protocol

ACP Client
    │
    ▼
ExMCP.ACP.Agent (GenServer)
    │
    └─── Your Elixir handler
```

## Quick Start

### Native ACP Agent

```elixir
# Start a client connected to a native ACP agent
{:ok, client} = ExMCP.ACP.start_client(command: ["gemini", "--acp"])

# Create a session rooted at a project directory
{:ok, %{"sessionId" => session_id}} =
  ExMCP.ACP.Client.new_session(client, "/path/to/project")

# Send a prompt and wait for the result
{:ok, %{"stopReason" => reason}} =
  ExMCP.ACP.Client.prompt(client, session_id, "Fix the failing tests")

# Cancel a running prompt
ExMCP.ACP.Client.cancel(client, session_id)

# Clean up
ExMCP.ACP.Client.disconnect(client)
```

### Native Elixir ACP Agent

Use `ExMCP.ACP.Agent` when your Elixir application is the agent being controlled by an ACP client:

```elixir
defmodule MyApp.EchoAgent do
  @behaviour ExMCP.ACP.Agent.Handler

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_new_session(_params, _ctx, state) do
    {:reply, %{"sessionId" => "sess_" <> Base.encode16(:crypto.strong_rand_bytes(8))}, state}
  end

  @impl true
  def handle_prompt(session_id, prompt, ctx, state) do
    text = prompt |> List.first() |> Map.get("text", "")

    ExMCP.ACP.Agent.agent_message(ctx.agent, session_id, "Echo: " <> text)
    {:reply, %{"stopReason" => "end_turn"}, state}
  end
end

ExMCP.ACP.run_agent(
  handler: MyApp.EchoAgent,
  agent_info: %{"name" => "echo-agent", "version" => "1.0.0"}
)
```

Prompt handlers can also stream updates and finish asynchronously:

```elixir
def handle_prompt(session_id, _prompt, ctx, state) do
  Task.start(fn ->
    ExMCP.ACP.Agent.agent_message(ctx.agent, session_id, "Working...")
    ExMCP.ACP.Agent.finish_prompt(ctx.agent, ctx.prompt_id, "end_turn")
  end)

  {:noreply, state}
end
```

### Adapted Agent (Claude Code)

```elixir
{:ok, client} = ExMCP.ACP.start_client(
  transport_mod: ExMCP.ACP.AdapterTransport,
  adapter: ExMCP.ACP.Adapters.ClaudeSDK,
  adapter_opts: [model: "sonnet", cwd: "/my/project"]
)

{:ok, %{"sessionId" => sid}} = ExMCP.ACP.Client.new_session(client, "/my/project")
{:ok, result} = ExMCP.ACP.Client.prompt(client, sid, "Refactor the auth module")
```

Use `ExMCP.ACP.Adapters.ClaudeSDK` for new Claude Code integrations. It speaks
the same SDK-style control protocol used by the official Claude Agent SDK, so it
can bridge permission prompts, partial tool lifecycle events, cancellation,
session setup, model/mode config, and richer status updates.

### Adapted Agent (Codex)

```elixir
{:ok, client} = ExMCP.ACP.start_client(
  transport_mod: ExMCP.ACP.AdapterTransport,
  adapter: ExMCP.ACP.Adapters.Codex,
  adapter_opts: [model: "gpt-4o"]
)
```

### Adapted Agent (ZCode)

```elixir
{:ok, client} = ExMCP.ACP.start_client(
  transport_mod: ExMCP.ACP.AdapterTransport,
  adapter: ExMCP.ACP.Adapters.ZCode,
  adapter_opts: [
    cwd: "/my/project",
    workspace_roots: ["/my/project"],
    mode_id: "build"
  ]
)

{:ok, %{"sessionId" => sid}} = ExMCP.ACP.Client.new_session(client, "/my/project")
{:ok, _} = ExMCP.ACP.Client.set_config_option(client, sid, "thought_level", "medium")
{:ok, result} = ExMCP.ACP.Client.prompt(client, sid, "Fix the failing tests")
```

The adapter launches `zcode app-server`. Set `adapter_opts[:cli_path]` or the
`ZCODE_EXECUTABLE` environment variable when `zcode` is not on `PATH`.

### Adapted Agent (Pi)

```elixir
{:ok, client} = ExMCP.ACP.start_client(
  transport_mod: ExMCP.ACP.AdapterTransport,
  adapter: ExMCP.ACP.Adapters.Pi,
  adapter_opts: [
    session_path: "/path/to/session.jsonl"  # optional: resume session
  ]
)

{:ok, %{"sessionId" => sid}} = ExMCP.ACP.Client.new_session(client, "/my/project")
{:ok, _} = ExMCP.ACP.Client.set_config_option(client, sid, "model", "anthropic/claude-sonnet-4")
{:ok, _} = ExMCP.ACP.Client.set_config_option(client, sid, "thought_level", "medium")
```

## Client Options

| Option | Default | Description |
|--------|---------|-------------|
| `:command` | (required) | Command list for the agent subprocess |
| `:adapter` | `nil` | Adapter module for non-native agents |
| `:adapter_opts` | `[]` | Options passed to adapter's `init/1` |
| `:handler` | `DefaultHandler` | Module implementing `ExMCP.ACP.Client.Handler` |
| `:handler_opts` | `[]` | Options passed to `handler.init/1` |
| `:event_listener` | `nil` | PID to receive `{:acp_session_update, sid, update}` messages |
| `:client_info` | `%{"name" => "ex_mcp", ...}` | Client identification |
| `:capabilities` | `%{}` | Client capabilities map |
| `:protocol_version` | `1` | ACP major protocol version (integer). Matches upstream [v1](https://agentclientprotocol.com/protocol/v1/overview); non-breaking features use capability negotiation. |
| `:max_frame_bytes` | `1_048_576` | Maximum inbound or outbound ACP JSON-RPC frame size |
| `:max_pending_requests` | `1_024` | Maximum concurrent requests in either direction |
| `:max_prompt_text_bytes` | `1_048_576` | Maximum streamed prompt text retained per session |
| `:pending_request_timeout` | `30_000` | Server-side lifetime for outbound requests and pending prompts |
| `:handler_request_timeout` | `30_000` | Maximum lifetime for inbound handler callbacks |
| `:max_update_queue` | `32` | Mailbox cutoff for handler and event-listener session updates; excess updates are dropped |
| `:max_update_queue_bytes` | `8_388_608` | Aggregate encoded byte cutoff for queued handler/listener updates and drop notices |
| `:notify_update_drops` | `false` | Opt into coalesced event-listener drop notices |
| `:max_outbox_bytes` | `4_194_304` | Aggregate byte limit for an adapter bridge's undelivered messages |
| `:native_events` | `:off` | Adapter-bridged agents only: opt-in `_meta.ex_mcp.native` provenance on derived messages (`:summary` for adapter name and sequence, `:raw` to also embed the decoded native event) |
| `:name` | `nil` | GenServer name registration |

### Boolean Config Options

ACP v1 clients must explicitly advertise that they can present and change
boolean session config options. Build that capability without hand-authoring
the nested wire map:

```elixir
capabilities =
  %{}
  |> ExMCP.ACP.Capabilities.put(:boolean_config_options, true)

{:ok, client} = ExMCP.ACP.start_client(
  command: ["my-agent", "--acp"],
  capabilities: capabilities
)

{:ok, _} =
  ExMCP.ACP.Client.set_config_option(client, session_id, "auto_retry", true)
```

Only opt in when the integrating client can render boolean options and return
user changes. ExMCP deliberately does not infer this UI capability from the
generic session-update callback. Boolean values are encoded with ACP's
required `type: "boolean"` discriminator.

### Adapter Subprocess Environment

Adapted agents start with an isolated environment by default. ExMCP clears the
parent environment, retains only a small runtime baseline such as `PATH`,
`HOME`, temporary-directory, locale, and TLS certificate settings, then applies
the adapter's declared environment and `adapter_opts[:env]`. Pass credentials
and provider settings explicitly through `adapter_opts[:env]`.

For compatibility with a CLI that genuinely requires the complete parent
environment, set `adapter_opts: [environment_policy: :inherit]`. This weakens
subprocess isolation and should be used only at a trusted integration boundary.

### Codex Workspace and MCP Authority

Treat every workspace path and MCP server definition received over ACP as
untrusted. The Codex adapter confines session `cwd` and
`additionalDirectories` to `:workspace_roots` (the adapter working directory
by default) using canonical, symlink-aware containment. Deployments with a
different tenancy model can supply fail-closed callbacks:

```elixir
adapter_opts: [
  workspace_roots: ["/srv/workspaces"],
  authorize_workspace: fn path, %{kind: kind} ->
    MyApp.Workspaces.allowed?(path, kind)
  end,
  authorize_mcp_server: fn server, %{cwd: cwd} ->
    MyApp.MCPPolicy.allowed?(server, cwd)
  end
]
```

Without `:authorize_mcp_server`, `:trusted_mcp_servers` must contain the exact
operator-owned server map; a matching name alone grants nothing. Avoid
`trusted_mcp_servers: :all`: it deliberately accepts peer-supplied HTTP URLs,
headers, stdio commands, arguments, and environment values. Set
`:trust_authorized_workspaces` only when the same authorization decision should
also mark that path trusted in Codex's project configuration.

### ZCode Workspace and MCP Authority

The ZCode adapter applies the same fail-closed boundary to session workspaces
and MCP server definitions. `:workspace_roots` defaults to the adapter's
working directory, and `:authorize_workspace` may authorize paths for a
specific operation such as `:session_new`, `:session_load`, or
`:session_resume`. ZCode Protocol v1 does not support ACP
`additionalDirectories`, so the adapter rejects non-empty values.

MCP servers must either exactly match a map in `:trusted_mcp_servers` or pass
`:authorize_mcp_server`. Names alone do not authorize peer-controlled URLs,
headers, commands, arguments, or environment values. As with Codex,
`trusted_mcp_servers: :all` is an unsafe compatibility escape hatch and should
only be used at a trusted integration boundary.

### Claude Code MCP Servers

Claude Code reads its MCP servers only when it starts, so the Claude adapter
takes them as launch options and does **not** attach the `mcpServers` of
`session/new`, `session/load`, `session/resume` or `session/fork`. Its
capabilities say so: `mcpCapabilities` advertises no transport (`http`, `sse`
and `acp` are `false`, and there is no BEAM transport) and
`mcpCapabilities._meta.ex_mcp.claude_sdk.sessionMcpServers` is `false`. When a
session request names a server the launch options did not configure, the
adapter logs a warning.

```elixir
adapter_opts: [
  # Claude's own format: server name => config, with header and env maps.
  mcp_servers: %{
    "docs" => %{
      "type" => "http",
      "url" => "https://docs.example.com/mcp",
      "headers" => %{"Authorization" => "Bearer " <> token}
    }
  },
  # Or config files you manage ({"mcpServers": {...}}); relative to :cwd.
  mcp_config_path: "/run/my_app/claude-mcp.json",
  # Ignore the user's own Claude MCP configuration.
  strict_mcp_config: true
]
```

`:mcp_servers` is never put on the command line, where other local users can
read it through `ps` or `/proc/<pid>/cmdline`. The adapter writes it to a file
readable only by the current user (0600, in a new 0700 directory under the
system temporary directory), passes the path to `--mcp-config`, and removes the
file when the adapter bridge exits. `:mcp_servers` must be a map: an ACP-style
`mcpServers` list, or any other shape, fails the connection with
`{:error, {:invalid_option, :mcp_servers, message}}`, and a
`:mcp_config_path` that is not an existing file fails it with
`{:error, {:invalid_option, :mcp_config_path, message}}`.

## Session Lifecycle

ACP sessions represent ongoing conversations with an agent.

```elixir
# Create a new session
{:ok, %{"sessionId" => sid}} = ExMCP.ACP.Client.new_session(client, "/project",
  additional_directories: ["/shared/docs"],
  mcp_servers: [
    ExMCP.ACP.Types.http_mcp_server("my-server", "http://localhost:3000/mcp")
  ]
)

# Load an existing session and replay conversation history
{:ok, _} = ExMCP.ACP.Client.load_session(client, sid, "/project")

# Resume an existing session without replaying history (if supported)
{:ok, _} = ExMCP.ACP.Client.resume_session(client, sid, "/project")

# List available sessions with optional filters (if supported)
{:ok, %{"sessions" => sessions}} =
  ExMCP.ACP.Client.list_sessions(client,
    cwd: "/project",
    additional_directories: ["/shared/docs"]
  )

# Delete a session from session history (if supported)
{:ok, %{}} = ExMCP.ACP.Client.delete_session(client, sid)

# Send prompts (blocks until agent responds)
{:ok, result} = ExMCP.ACP.Client.prompt(client, sid, "Add error handling")

# Cancel a running prompt
ExMCP.ACP.Client.cancel(client, sid)

# Cancel a specific JSON-RPC request when you have its request id
ExMCP.ACP.Client.cancel_request(client, request_id)

# Configure the agent at runtime
ExMCP.ACP.Client.set_mode(client, sid, "high")
ExMCP.ACP.Client.set_config_option(client, sid, "model", "anthropic/claude-sonnet-4")
ExMCP.ACP.Client.set_config_option(client, sid, "auto_retry", false)

# Close a session and free agent-side resources (if supported)
ExMCP.ACP.Client.close_session(client, sid)

# Authenticate or logout (if agent requires/supports it)
ExMCP.ACP.Client.authenticate(client, "api-key")
ExMCP.ACP.Client.logout(client)
```

## Handling Session Events

Implement the `ExMCP.ACP.Client.Handler` behaviour to react to streaming updates and agent requests:

```elixir
defmodule MyApp.ACPHandler do
  @behaviour ExMCP.ACP.Client.Handler

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_session_update(session_id, update, state) do
    case update["sessionUpdate"] do
      "agent_message_chunk" ->
        IO.write(update["content"]["text"])

      "tool_call_update" ->
        status = update["status"]  # "pending", "in_progress", "completed", or "failed"
        IO.puts("[#{status}] #{update["title"]}")

        # Rich metadata available for ClaudeSDK/Codex/Pi/ZCode adapters:
        # update["kind"]      — "read", "edit", "execute", "search", "think"
        # update["locations"] — [%{"path" => "/src/app.ex", "line" => 10}]
        # update["content"]   — [%{"type" => "diff", "oldText" => ..., "newText" => ...}]

      "plan" ->
        for entry <- update["entries"] do
          IO.puts("  [#{entry["status"]}] #{entry["content"]}")
        end

      "agent_thought_chunk" ->
        IO.write(update["content"]["text"])

      "usage" ->
        IO.puts("Tokens: #{update["inputTokens"]} in / #{update["outputTokens"]} out")

      _ ->
        :ok
    end

    {:ok, state}
  end

  @impl true
  def handle_permission_request(_session_id, tool_call, options, state) do
    reject_option = Enum.find(options, &(&1["kind"] == "reject_once")) || List.first(options)

    # Return the direct outcome; ExMCP wraps it as result.outcome on the wire.
    case reject_option do
      nil -> {:ok, %{"outcome" => "cancelled"}, state}
      option -> {:ok, %{"outcome" => "selected", "optionId" => option["optionId"]}, state}
    end
  end

  # Optional: each elicitation mode is advertised only when its callback exists.
  # Form elicitation is for non-sensitive structured input; never request
  # passwords, API keys, or other secrets through a form.
  def handle_form_elicitation(params, state) do
    {:ok, %{"action" => "decline"}, state}
  end

  def handle_url_elicitation(params, state) do
    # Display the destination and wait for explicit user consent before opening.
    {:ok, %{"action" => "decline"}, state}
  end

  def handle_elicitation_complete(elicitation_id, state) do
    # Dismiss any UI retained for this URL-mode elicitation.
    {:ok, state}
  end

  # Optional: handle file read requests from the agent
  def handle_file_read(_session_id, path, _opts, state) do
    # ExMCP admits only absolute paths contained by the canonical session cwd or
    # additionalDirectories. The handler should still open files defensively to
    # close application-specific policy and filesystem TOCTOU gaps.
    case File.read(path) do
      {:ok, content} -> {:ok, content, state}
      {:error, reason} -> {:error, to_string(reason), state}
    end
  end

  # Optional: handle terminal requests from the agent
  def handle_terminal_request(method, params, _id, state) do
    # Handle terminal/create, terminal/output, terminal/kill, etc.
    {:error, "Terminal operations not implemented", state}
  end
end
```

The client records canonical workspace roots when a session is created, loaded,
resumed, or forked. It rejects filesystem paths and terminal working directories
outside those roots, including escapes through existing symlinks. Nonexistent
children below a trusted root are permitted so write/create handlers can work;
custom handlers remain responsible for rechecking policy at the point of use.

### Asynchronous request work

Permission, file, terminal and elicitation callbacks can return
`{:async, work, state}`. The runner commits `state` before the next callback,
then runs the zero-arity function in a linked, monitored worker. The work returns
`{:ok, value}` or `{:error, reason}`; file-write work returns `:ok` or
`{:error, reason}`. Work does not return handler state.

```elixir
def handle_file_read(_session_id, path, _opts, state) do
  {:async, fn -> File.read(path) end, state}
end
```

The client owns the wire response, cancellation and handler deadline. It stops
workers on cancellation, timeout, disconnect or runner shutdown, and skips
cancelled callbacks still queued in the runner. Keep the callback itself short;
synchronous returns retain their existing ordering. Use this form for long waits
so operations such as `terminal/kill` can still run while a terminal wait is pending.

### ACP message context

Handlers can also implement `handle_session_update/4` and
`handle_permission_request/5`. These optional variants receive the decoded
JSON-RPC message that reached the ACP client, immediately before the handler
state argument. When a variant is present, ExMCP calls it instead of the
corresponding legacy callback. Both arities are optional, but a handler must
implement at least one of each pair or the client refuses to start it. Keep the
legacy callbacks as well if the handler must run on older ExMCP versions.

The message retains unknown top-level and parameter fields and the permission
request ID from the received ACP message. It is a decoded map, not the original
JSON bytes. This callback does not provide an unmodified native-provider event.
For a native ACP agent, the value is the message that the agent wrote. For an
agent used through `ExMCP.ACP.AdapterTransport`, `AdapterBridge` and the adapter
construct the ACP message from the agent's native protocol. Native fields that
the adapter does not map are already absent. An adapter can include selected
native data in ACP extension fields when its contract supports that data.

ExMCP performs validation and session authorization before dispatch. It still
owns request correlation, cancellation, and handler deadlines. Return the same
permission outcome as before; ExMCP builds the response.

Both variants run through the existing handler runner. Retained update message
data counts toward `:max_update_queue_bytes`, including fields outside the
update. Legacy handlers and the event-listener message format are unchanged.

For an adapted agent, start the transport with `native_events: :summary` to
have the retained message carry `_meta.ex_mcp.native` with the adapter name and
sequence, or `native_events: :raw` to also receive the decoded native provider
event there; see "`_meta.ex_mcp` namespaces" below.

### Event Listener

For simple use cases, receive session updates as process messages instead of implementing a full handler:

```elixir
{:ok, client} = ExMCP.ACP.start_client(
  command: ["gemini", "--acp"],
  event_listener: self()
)

# In your receive loop or GenServer
receive do
  {:acp_session_update, session_id, %{"sessionUpdate" => type} = update} ->
    IO.puts("#{type}: #{inspect(update)}")
end
```


Delivery to handlers and listeners obeys `:max_update_queue` and
`:max_update_queue_bytes`. Each dropped update emits
`[:ex_mcp, :acp, :session, :update_dropped]` telemetry with count/bytes
measurements and session id, target, limit and configured bounds in metadata.
Set `notify_update_drops: true` to receive coalesced
`{:acp_session_updates_dropped, session_id, count}` messages. Handlers can
implement `handle_session_updates_dropped/3` for the corresponding notice.
Notices obey the same queue bounds, retain no update payload, and retry after
recovery even without another update. A notice larger than the byte limit is
telemetry-only.

Counts belong to the session, including concurrent pending load/resume calls.
A failed, expired or abandoned open retires counts only when no session authority
remains. Successful close/delete, local `end_session/2` fallback and disconnect
end that notice lifetime and clear counts immediately, including when an open
for the same id is pending. Subsequent updates belong to a new notice lifetime.

The public `GenServer.call/3` wait timeout alone does not retire an underlying
request if its caller catches the timeout exit and stays alive. Its notices
remain valid until the client retires that request or session. The separate
`:pending_request_timeout` is a server-owned lifetime: when it expires the
client sends cancellation and retires the request. Caller death also retires it.

## Session Update Types

The ACP spec defines these session update types (all supported by ExMCP):

| Type | Description |
|------|-------------|
| `agent_message_chunk` | Streaming text/image content from the agent |
| `user_message_chunk` | Echo of user input |
| `agent_thought_chunk` | Streaming thought content from the agent |
| `tool_call` | New tool call started |
| `tool_call_update` | Tool call lifecycle (pending → in_progress → completed/failed) |
| `plan` | Multi-step execution plan with entry status |
| `available_commands_update` | Slash commands the agent supports |
| `config_option_update` | Runtime config change notification |
| `current_mode_update` | Operational mode change |
| `session_info_update` | Session metadata such as title and updatedAt |
| `usage_update` | Context window usage and optional cost information |

Adapter-specific status, error, and extension bridge details are attached under
`_meta.ex_mcp` on spec-defined update types, usually `session_info_update`.
Content chunks may include ACP's optional `messageId` field so clients can group
streamed chunks into logical messages.

### `_meta.ex_mcp` namespaces

ExMCP keeps all of its extension data under one `_meta.ex_mcp` map so other ACP
implementations can ignore it as a unit:

| Key | Set by | Contents |
|-----|--------|----------|
| `_meta.ex_mcp.<adapter>` | The adapter (`claude_sdk`, `codex`, `pi`, `zcode`) | Provider-specific fields the adapter chose to surface, such as Claude Code's session UUID, tool names, cost, or auth errors |
| `_meta.ex_mcp.native` | `AdapterBridge`, opt-in | Provenance of the ACP message: the adapter `name`, a per-connection `sequence` number, and with `native_events: :raw` the decoded native `event` |
| `_meta.ex_mcp.mcpCapabilities.beam` | Capability negotiation | BEAM-local MCP transport support |

The `native` block is off by default. Pass `native_events: :summary` to
`AdapterTransport` (or `AdapterBridge`) to attach it to every ACP message an
adapter derives from one native agent line, so all messages from the same line
share a `sequence`, or `native_events: :raw` to also embed the full native
event. Raw events can be large; they count toward the client's
`:max_update_queue_bytes` like any other retained update data. Adapters
implement `c:ExMCP.ACP.Adapter.name/0` to name their namespace; the bridge
derives it from the module name otherwise.

## Writing Custom Adapters

To support an agent that doesn't speak ACP natively, implement the `ExMCP.ACP.Adapter` behaviour:

```elixir
defmodule MyApp.CustomAgentAdapter do
  @behaviour ExMCP.ACP.Adapter

  @impl true
  def init(opts), do: {:ok, %{model: Keyword.get(opts, :model, "default")}}

  @impl true
  def command(_opts), do: {"my-agent", ["--json-mode"]}

  @impl true
  def capabilities, do: %{}

  # Optional: declare supported modes
  @impl true
  def modes do
    [%{"id" => "fast", "name" => "Fast Mode"}, %{"id" => "quality", "name" => "Quality Mode"}]
  end

  # Optional: declare config options
  @impl true
  def config_options do
    [
      %{
        "id" => "model",
        "name" => "Model",
        "category" => "model",
        "type" => "select",
        "currentValue" => "fast",
        "options" => [
          %{"value" => "fast", "name" => "Fast"},
          %{"value" => "quality", "name" => "Quality"}
        ]
      }
    ]
  end

  # Optional: list available sessions
  @impl true
  def list_sessions(params, state) do
    sessions = [
      %{
        "sessionId" => "sess-1",
        "cwd" => params["cwd"] || state.cwd,
        "title" => "My Session"
      }
    ]

    {:ok, sessions, state}
  end

  @impl true
  def translate_outbound(%{"method" => "session/prompt", "params" => params}, state) do
    text = hd(params["prompt"])["text"]
    {:ok, [Jason.encode!(%{"action" => "ask", "text" => text}), "\n"], state}
  end

  def translate_outbound(_msg, state), do: {:ok, :skip, state}

  @impl true
  def translate_inbound(line, state) do
    case Jason.decode(line) do
      {:ok, %{"type" => "stream", "delta" => delta}} ->
        {:messages, [ExMCP.ACP.AdapterEvents.agent_message_chunk("default", delta)], state}

      _ ->
        {:skip, state}
    end
  end
end
```

`ExMCP.ACP.AdapterEvents` builds the other ACP messages an adapter emits, such
as thought chunks, tool calls, plans, mode changes, and the final
`session/prompt` response, so adapters do not hand-assemble JSON-RPC maps.

### Adapter Callbacks

| Callback | Required | Description |
|----------|----------|-------------|
| `init/1` | Yes | Initialize adapter state |
| `command/1` | Yes | Return `{executable, args}`, `:one_shot`, or `:adapter_managed` |
| `translate_outbound/2` | Yes | Convert ACP message to native format |
| `translate_inbound/2` | Yes | Convert native output to ACP messages |
| `post_connect/1` | No | Send initial data after port opens |
| `handle_adapter_message/2` | No | Handle Port/process messages for adapter-managed subprocesses |
| `shutdown/1` | No | Clean up adapter-managed resources when the bridge closes |
| `env/1` | No | Return child-process environment variables |
| `capabilities/0` | No | Return static agent capabilities |
| `modes/0` | No | Return supported operational modes |
| `config_options/0` | No | Return supported config options |
| `auth_methods/1` | No | Return initialize `authMethods` for adapter options |
| `list_sessions/2` | No | Return a sessions list or full ACP `session/list` result for decoded params |
| `fork_session/2` | No | Fork an existing session for decoded `session/fork` params |

## Built-in Adapters

### Claude Code SDK (`ExMCP.ACP.Adapters.ClaudeSDK`)

Translates between ACP and Claude Code's SDK-compatible stream-json control
protocol. This is the recommended Claude adapter for new code.

**Features:**
- SDK entrypoint launch environment and `--permission-prompt-tool stdio`, tracking Claude Agent SDK `0.3.238`
- Partial message and pending tool-call lifecycle mapping
- `session/cancel` via SDK `interrupt`
- ACP permission requests bridged from Claude SDK `can_use_tool`, with pending `tool_call` emitted before the permission request and durable choices shown only when Claude supplies a durable update
- `AskUserQuestion` bridged through ACP form elicitation when the client advertises it; otherwise it fails closed
- Runtime mode, model, effort, fast-mode, and agent config controls where supported by the SDK session; `auto` is model-gated and bypass mode requires explicit dangerous-mode opt-in
- Initialize-aware terminal login auth methods, opt-in gateway auth methods, and ACP `auth.logout`
- Initial session metadata exposes Claude Code's native session UUID at `_meta.ex_mcp.claude_sdk.sessionId` so clients can resume a turn that times out before its final result
- Live session setup/load/resume/fork/close ACP surface
- Disk-backed `session/list`, `session/delete`, and `session/fork` for Claude Code's SDK store
- Full `session/load` replay from persisted Claude JSONL transcripts
- FIFO prompt queueing with queued prompt cancellation responses
- Plan updates from `TodoWrite` and task progress events, with prompt settlement held while spawned background subagents remain live
- Resource links, embedded text resources, HTTP/base64 images, and MCP slash-command prompt rewriting
- Rich tool metadata, Codex-style Bash terminal metadata, result usage updates, and improved stop reasons
- Official ACP `mcpCapabilities` plus ExMCP `_meta` support for BEAM-local MCP transport

`session/list`, `session/load`, `session/fork`, and `session/delete` read and mutate Claude Code's local
`CLAUDE_CONFIG_DIR/projects` JSONL store directly in Elixir, using the same
project-key derivation, UUID validation, sidechain filtering, and title
sanitization rules as the official Claude Agent SDK. `session/load` replays
persisted transcript entries as ACP `session/update` notifications before the
load response; `session/resume` keeps the lighter no-replay behavior.

The adapter advertises official ACP MCP support through `mcpCapabilities`
(`acp`, `http`, and `sse`). ExMCP's BEAM-local MCP transport is intentionally
advertised only as `_meta.ex_mcp.mcpCapabilities.beam`, so other ACP libraries can
ignore it while ExMCP peers can negotiate and validate BEAM-local descriptors.

**Config options:** `mode`, `model`, `effort`, `fast` (when the selected model supports fast mode), and `agent` (when custom main-thread agents are available). The legacy inbound `permission_mode` config id is still accepted as an alias for `mode`.

**Modes:** the catalog is stable — `default` (Manual), `acceptEdits`, `plan`,
and `auto` are always advertised, and `bypassPermissions` is added only behind
the `allow_dangerously_skip_permissions` opt-in (or an inherited bypass mode).
Each entry carries its semantic kind under `_meta.kind`
(`standard`, `plan`, `auto_review`, `full_access`). When a session selects or
inherits `auto` while Claude has described the current model as not supporting
it, the session runs in `acceptEdits` instead and the client is told: a
`current_mode_update` plus a one-per-session `agent_message_chunk` notice. A
model Claude never described is assumed capable, so no fallback happens.

**Prompt response usage:** besides the ACP `usage` field, a prompt response
carries `_meta.quota` with a `token_count` for the turn and a `model_usage`
breakdown (`[{"model": ..., "token_count": ...}]`) derived from Claude's
`modelUsage`. The raw Claude figures remain available unchanged under
`_meta.ex_mcp.claude_sdk.modelUsage`.

**Startup options:** `model`, `permission_mode`, `max_thinking_tokens`,
`effort`, `fast_mode`, `agent`, `additional_directories`, `mcp_servers`, `session_id`, `resume`,
`resume_session_at`, `allowed_tools`, `disallowed_tools`, `tools`,
`strict_mcp_config`, `include_partial_messages`, and `cli_path`.

### Codex (`ExMCP.ACP.Adapters.Codex`)

Translates between ACP and Codex's app-server JSON-RPC protocol.

**Features:**
- Initialize handshake with `post_connect/1`
- Model catalog loading from Codex `model/list`, ACP `model` config options, legacy `session/set_model` compatibility, and per-session `models` state
- Tool call lifecycle: creation, completion, output, patch events, and current camelCase app-server item variants
- Command execution streaming with ACP terminal metadata
- Web search, MCP tool, dynamic tool, file change, image view, image generation, guardian review, fuzzy file search, plan, status, goal, usage, and compaction events
- Session list/load/resume/close/delete through Codex app-server thread APIs
- Load-history replay from returned Codex turns when available, including tool history
- Image content, resource links, embedded text/binary resources, and additional workspace directories in prompts/session setup
- Codex slash commands in prompts: `/compact`, `/init`, `/review`, `/review-branch`, `/review-commit`, `/status`, and `/logout`
- ACP HTTP and stdio MCP server descriptors forwarded into Codex session config
- Codex auth methods for `chat-gpt`, `api-key`, and opt-in custom `gateway` auth; ChatGPT device login uses request-scoped ACP URL elicitation and is advertised only to URL-capable clients
- Approval requests bridged through ACP `session/request_permission`; MCP form/URL requests and non-secret `requestUserInput` questions use ACP elicitation
- Active prompt and pending client-request cancellation on close/delete, plus a closed-session fence for late app-server events

**Modes:** `read-only`, `agent`, `agent-full-access`. Legacy `suggest`, `auto-edit`, `auto`, `full-auto`, and `full-access` aliases are no longer accepted.
**Config options:** `mode`, `model`, `reasoning_effort`, and `fast-mode` (when supported by the selected model) are returned with Codex session responses. Runtime changes are kept in adapter session state and applied to subsequent `turn/start` requests.

**Unsupported Codex app-server requests:** Dynamic tool calls, ChatGPT token refresh, and attestation generation are rejected explicitly. Secret `requestUserInput` questions are answered empty instead of being exposed through ACP form elicitation.

### ZCode (`ExMCP.ACP.Adapters.ZCode`)

Translates between ACP and the ZCode Protocol v1 NDJSON stream exposed by the
persistent `zcode app-server` process.

**Features:**
- Startup workspace-state handshake and dynamic model catalog loading
- ACP `session/new`, `session/load`, `session/resume`, `session/list`,
  `session/fork`, `session/close`, `session/prompt`, and `session/cancel`
- FIFO prompt queueing, queued-prompt cancellation, and prompt stop-reason mapping
- Streaming agent text and reasoning, rich tool-call lifecycle metadata,
  session title/mode updates, and context-window usage updates
- ZCode permission requests bridged through ACP `session/request_permission`
- Runtime mode, model, and thought-level controls with ACP config-option updates
- HTTP, SSE, and authorized stdio MCP server descriptors
- Terminal authentication through `zcode login`
- Canonical, symlink-aware workspace confinement and fail-closed MCP authorization

**Modes:** `plan` disables tool execution; `build` uses normal permission
prompts; `edit` auto-accepts file edits; `auto` uses ZCode's classifier to
approve requests; and `yolo` allows operations without prompting.

**Config options:** `mode`, `model` (after the app server returns its model
catalog), and `thought_level`. The fallback thought levels are `off`,
`minimal`, `low`, `medium`, and `high`; a selected model may provide its own
supported levels. Legacy `session/set_model` remains available for compatibility.

**Startup options:** `cli_path`, `cwd`, `workspace_roots`,
`authorize_workspace`, `authorize_mcp_server`, `trusted_mcp_servers`, `model`,
`mode_id`, `thought_level`, and `env`. The shared adapter bridge also accepts
`environment_policy: :inherit` when an explicitly trusted deployment requires
the complete parent environment.

**Protocol limitations:** ZCode Protocol v1 accepts text prompts only, so image
and embedded-context prompt capabilities are not advertised. Non-empty
`additionalDirectories` and ACP `session/delete` are unsupported. ZCode
request-user-input calls are answered as cancelled because ACP does not expose
the corresponding structured response schema.

### Pi (`ExMCP.ACP.Adapters.Pi`)

Translates between ACP and Pi's RPC NDJSON protocol.

**Features:**
- Adapter-managed Pi subprocesses for ACP `session/new`, `session/load`, and `session/resume`
- ACP-native `session/new`, `session/load`, `session/resume`, `session/list`, `session/close`, `session/delete`, `session/prompt`, `session/cancel`, `session/set_config_option`, and `session/set_mode`, with legacy `session/set_model` compatibility
- Terminal authentication method advertisement through `authMethods`
- Pi session discovery from JSONL files plus a local ExMCP session map at `~/.ex_mcp/pi/session-map.json`, with cursor pagination and last-cwd default filtering
- Prompt queuing while another Pi turn is active; prompt completion waits for Pi's `agent_settled` event rather than the earlier `agent_end` usage snapshot
- Per-session `model` and `thought_level` config options, with ACP config-option sync updates after model/thinking changes
- Global/project Pi settings merge for skill command filtering and quiet startup
- Startup info for Pi version, context, prompts, skills, extensions, and captured CLI prelude; registry update notices are opt-in
- Markdown slash commands loaded from `~/.pi/agent/prompts` and `<cwd>/.pi/prompts`
- Built-in slash commands: `/compact`, `/autocompact`, `/export`, `/session`, `/name`, `/steering`, `/follow-up`, and `/changelog`
- Text/thinking streaming, tool-call streaming, tool execution lifecycle, compaction, retry, and extension UI events; select/confirm bridge to ACP permission choices while input/editor requests fail closed with a Pi cancellation response
- Enhanced tool result parsing with content blocks, structured edit diffs, stdout/stderr/exitCode formatting, and file locations
- Image support with data-url prefix stripping
- Resource links and embedded text resources folded into Pi prompt text; audio blocks are represented as unsupported markers

**Modes:** `off`, `minimal`, `low`, `medium`, `high`, `xhigh` map to Pi thinking levels through ACP `session/set_mode`.

**Config options:** Session responses include upstream-compatible `model` and `thought_level` selectors, plus ExMCP's existing `auto_compaction`, `auto_retry`, `steering_mode`, and `follow_up_mode` controls. Prefer `set_config_option/4` with config id `model` for model changes; `ExMCP.ACP.Client.set_model/3` is retained for compatibility with older adapters.

**Startup options:** `cli_path`/`pi_command`, `agent_dir`, `session_path`, `session_dir`, `session_map_path`, `delete_session_files`, and `update_notice`. The live Pi subprocess is started like upstream `pi-acp`, with `--mode rpc --no-themes` and optional `--session <path>`; cwd is applied as the child process working directory. `agent_dir` isolates the settings and user-prompt directory used by the adapter; also pass the same path as `PI_CODING_AGENT_DIR` in `env` so the Pi subprocess uses it. `session/delete` removes ExMCP session-map state by default; backing Pi JSONL files are deleted only when `delete_session_files: true` is set and the file is under the configured Pi session directory. Registry update checks are disabled unless `update_notice: true` or `PI_ACP_UPDATE_NOTICE=true` is set.

Pi `0.80.4` or newer is required for the `agent_settled` completion boundary;
the credential-free real-CLI suite currently pins Pi `0.84.1`.

**Breaking change:** Pi-specific `_ex_mcp.pi/*` and legacy `pi/*` extension methods are no longer implemented. Use the ACP session methods above or slash commands in prompts.

## Content Block Types

ACP supports these content block types in prompts and responses:

```elixir
alias ExMCP.ACP.Types

# Text
Types.text_block("Hello, world!")

# Images
Types.image_block("image/png", "base64data...")

# Audio
Types.audio_block("audio/wav", "base64data...")

# Resource links (references to external resources)
Types.resource_link_block("file:///src/app.ex", name: "app.ex")

# Embedded resources
Types.resource_block("file:///src/app.ex", text: "defmodule App do...")

# Plan entries
Types.plan_entry("Fix the auth bug", "high", "in_progress")

# Plan update notification (emits the stable "plan" update type)
Types.plan_update(session_id, [
  Types.plan_entry("Read the code", "high", "completed"),
  Types.plan_entry("Write the fix", "high", "in_progress"),
  Types.plan_entry("Run tests", "medium", "pending")
])
```

## MCP Server Integration

ACP agents can use MCP servers as tool providers. Pass MCP server configurations when creating sessions:

```elixir
{:ok, %{"sessionId" => sid}} = ExMCP.ACP.Client.new_session(client, "/project",
  additional_directories: ["/shared/docs"],
  mcp_servers: [
    ExMCP.ACP.Types.stdio_mcp_server("local-tools", "my_mcp_server", args: ["--stdio"]),
    ExMCP.ACP.Types.http_mcp_server("remote-tools", "http://localhost:4000/mcp")
  ]
)
```

## ACP Registry

The public ACP Registry lists ACP-compatible agents and their distribution metadata:

```elixir
{:ok, registry} = ExMCP.ACP.Registry.fetch()

agent = ExMCP.ACP.Registry.get_agent(registry, "codex-acp")
{:ok, command} = ExMCP.ACP.Registry.npx_command(agent)

{:ok, client} = ExMCP.ACP.start_client(command: command)
```

Use `ExMCP.ACP.Registry.find_agents/2` to search the decoded registry by agent id, name, or description.
`npx_command/1` validates the npm package specifier and inserts `--` before it, so a registry
entry cannot add `npx` options; an invalid specifier returns `{:error, :invalid_npx_package}`.

## Adapter CLI Interop Tests

The standard `:interop_acp` suite checks both ACP roles against the official
TypeScript SDK. A separate opt-in suite launches the real Claude Code, Codex,
Pi, and ZCode CLIs through their adapters:

```bash
mix test --only interop_acp_cli
```

These tests stop at session lifecycle operations and never send a prompt, so
they do not make LLM calls or consume model credits. They use isolated config
directories and fail if a required executable is missing. Set
`CLAUDE_CODE_EXECUTABLE`, `CODEX_PATH`, `PI_ACP_PI_COMMAND`, or
`ZCODE_EXECUTABLE` when a CLI is not on `PATH`. On macOS, the suite also finds
the runtime bundled with `/Applications/ZCode.app`.

## Ecosystem Compatibility Tracking

The repository tracks the public ACP agents page, the machine-readable ACP
Registry, and reviewed executable smoke tests in
`test/interop/acp_compatibility.json`. Check the pinned snapshot against live
sources with:

```bash
# Network-free manifest validation
mix acp.compat.check --offline

# Live catalog, registry version, and adapter-reference checks
mix acp.compat.check

# Run one reviewed, version-pinned native ACP command
ACP_ECOSYSTEM_AGENT_ID=gemini mix test --only interop_acp_ecosystem
```

The native smoke tier verifies process startup, ACP initialization, capability
decoding, authentication-method decoding, and clean shutdown without sending a
prompt. Entries marked with the stronger `session` tier also create a session
and exercise advertised list/close capabilities. The initial executable matrix
covers Claude Agent ACP, Codex ACP, Gemini CLI, and Pi ACP; every entry is
version-pinned and runs with an isolated home and scratch working directory.

The same manifest pins the reference revisions used to inform ExMCP's Claude,
Codex, Pi, and ZCode protocol adapters:

- `agentclientprotocol/claude-agent-acp`
- `agentclientprotocol/codex-acp`
- `svkozak/pi-acp`
- `zai-org/ZCode`

Upstream commit drift produces a direct compare URL for adapter review. Catalog
or registry changes are never executed automatically: maintainers must review
the package, command, platform and authentication requirements before adding
or changing an `interopAgents` entry. The scheduled `ACP ecosystem
compatibility` workflow runs weekly and can also be dispatched manually.

## API Reference

- `ExMCP.ACP` — Facade module
- `ExMCP.ACP.Agent` — GenServer runtime for native Elixir ACP agents
- `ExMCP.ACP.Agent.Handler` — Agent-side handler behaviour
- `ExMCP.ACP.Client` — GenServer client with full session API
- `ExMCP.ACP.Client.Handler` — Handler behaviour
- `ExMCP.ACP.Capabilities` — Capability inspection and construction helpers
- `ExMCP.ACP.Protocol` — ACP JSON-RPC message encoding
- `ExMCP.ACP.Types` — Type specs and builders
- `ExMCP.ACP.Registry` — Public ACP Registry fetch and lookup helpers
- `ExMCP.ACP.Adapter` — Adapter behaviour for non-native agents
- `ExMCP.ACP.AdapterBridge` — GenServer bridge managing Port and message queue
- `ExMCP.ACP.Adapters.ClaudeSDK` — Claude Code SDK-protocol adapter
- `ExMCP.ACP.Adapters.Codex` — Codex adapter
- `ExMCP.ACP.Adapters.ZCode` — ZCode app-server adapter
- `ExMCP.ACP.Adapters.Pi` — Pi adapter
