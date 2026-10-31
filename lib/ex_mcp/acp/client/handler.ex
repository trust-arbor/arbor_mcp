defmodule ExMCP.ACP.Client.Handler do
  @moduledoc """
  Behaviour for handling ACP session events and agent requests.

  Implement this behaviour to customize how your application responds to
  streaming session updates, permission requests, and file access requests
  from ACP agents.

  See `ExMCP.ACP.Client.DefaultHandler` for a reference implementation.

  Request callbacks (permission, file, terminal and elicitation)
  may return `{:async, work, state}` for a zero-arity function. The new handler
  state is committed immediately, before the next callback. `work` runs in a
  linked, monitored worker and returns `{:ok, value}` or `{:error, reason}`;
  file-write work returns `:ok` or `{:error, reason}`. Work never returns
  handler state. Cancellation, timeout, disconnect and runner shutdown stop
  the worker; late results cannot answer a request twice. Keep the callback
  itself short: synchronous callbacks retain their existing ordering.

  Session updates and permission requests each have a legacy callback and a
  context-aware variant that also receives the decoded JSON-RPC message
  (`c:handle_session_update/3` or `c:handle_session_update/4`, and
  `c:handle_permission_request/4` or `c:handle_permission_request/5`). Both
  arities are optional so a handler can implement only the variant it needs,
  but it must implement at least one of each pair: the client refuses to start
  a handler that implements neither, with
  `{:handler_init_failed, {:missing_callback, name}}`. When both are present
  the context-aware variant is called.
  """

  @type state :: any()
  @type async_request :: {:async, (-> :ok | {:ok, term()} | {:error, term()}), state()}

  @doc "Called when the handler is initialized."
  @callback init(opts :: keyword()) :: {:ok, state()}

  @doc """
  Called for each `session/update` notification from the agent.

  The `update` map contains a `"sessionUpdate"` discriminator field indicating
  the update type (e.g., `"agent_message_chunk"`, `"tool_call"`, `"plan"`, etc.).

  Optional when `c:handle_session_update/4` is implemented.
  """
  @callback handle_session_update(session_id :: String.t(), update :: map(), state()) ::
              {:ok, state()}

  @doc """
  Handles a session update with the decoded JSON-RPC message received by the
  ACP client.

  When implemented, this optional callback is called instead of
  `c:handle_session_update/3`. The message retains unknown top-level and
  parameter fields from the ACP message. It is the decoded map, not the
  original JSON bytes.

  This is an ACP-boundary value. A native ACP agent supplies the message. When
  the client uses `ExMCP.ACP.AdapterTransport`, `ExMCP.ACP.AdapterBridge` and
  the selected adapter construct the ACP message from the agent's native
  protocol. Native fields that the adapter does not map are not present.

  ExMCP validates the update and session before dispatch. Message data counts
  toward the existing handler update queue byte limit.
  """
  @callback handle_session_update(
              session_id :: String.t(),
              update :: map(),
              message :: map(),
              state()
            ) :: {:ok, state()}

  @doc """
  Reports session updates dropped for a full handler mailbox. Optional; omitted
  callbacks are a no-op. Counts are coalesced per session and delivered when
  queue room becomes available, even if no further updates arrive. Notices
  obey the update count and byte bounds. Every drop also emits
  `[:ex_mcp, :acp, :session, :update_dropped]` with count/bytes measurements and
  session, target, limit and configured bounds in metadata.
  """
  @callback handle_session_updates_dropped(String.t(), pos_integer(), state()) :: {:ok, state()}

  @doc """
  Called when the agent requests permission to use a tool.

  Must return an outcome map with an `"optionId"` matching one of the
  provided options.
  """
  @callback handle_permission_request(
              session_id :: String.t(),
              tool_call :: map(),
              options :: [map()],
              state()
            ) ::
              {:ok, outcome :: map(), state()}
              | async_request()

  @doc """
  Handles a permission request with the decoded JSON-RPC message received by
  the ACP client.

  When implemented, this optional callback is called instead of
  `c:handle_permission_request/4`. The message includes the original request
  ID and all received fields. ExMCP retains request correlation, validation,
  cancellation, and timeout ownership. Return the same outcome as the legacy
  callback; do not send a JSON-RPC response from the handler. This callback
  has the same ACP-boundary limit as `c:handle_session_update/4`: an adapted
  agent can supply only the fields that its adapter placed in the ACP request.
  """
  @callback handle_permission_request(
              session_id :: String.t(),
              tool_call :: map(),
              options :: [map()],
              message :: map(),
              state()
            ) ::
              {:ok, outcome :: map(), state()}
              | async_request()

  @doc """
  Called when the agent requests to read a file.

  Return `{:ok, content, state}` with the file contents, or
  `{:error, reason, state}` to deny access.
  """
  @callback handle_file_read(session_id :: String.t(), path :: String.t(), opts :: map(), state()) ::
              {:ok, content :: String.t(), state()}
              | {:error, reason :: String.t(), state()}
              | async_request()

  @doc """
  Called when the agent requests to write a file.

  Return `{:ok, state}` to allow the write, or
  `{:error, reason, state}` to deny it.
  """
  @callback handle_file_write(
              session_id :: String.t(),
              path :: String.t(),
              content :: String.t(),
              state()
            ) :: {:ok, state()} | {:error, reason :: String.t(), state()} | async_request()

  @doc """
  Called when the agent requests a terminal operation.

  The `method` is one of the stable `terminal/*` methods and `params` is the
  raw ACP params map. Return `{:ok, result, state}` with the method-specific
  result map, or `{:error, reason, state}` to deny or fail the operation.
  """
  @callback handle_terminal_request(
              method :: String.t(),
              params :: map(),
              id :: integer() | String.t() | nil,
              state()
            ) ::
              {:ok, result :: map(), state()}
              | {:error, reason :: String.t(), state()}
              | async_request()

  @doc "Called when the agent requests a form-mode elicitation."
  @callback handle_form_elicitation(params :: map(), state()) ::
              {:ok, response :: map(), state()}
              | {:error, reason :: term(), state()}
              | async_request()

  @doc "Called when the agent requests a URL-mode elicitation."
  @callback handle_url_elicitation(params :: map(), state()) ::
              {:ok, response :: map(), state()}
              | {:error, reason :: term(), state()}
              | async_request()

  @doc "Called when an accepted URL elicitation completes out of band."
  @callback handle_elicitation_complete(elicitation_id :: String.t(), state()) :: {:ok, state()}

  @doc "Called when the handler is being terminated."
  @callback terminate(reason :: any(), state()) :: :ok

  @optional_callbacks [
    handle_session_updates_dropped: 3,
    handle_session_update: 3,
    handle_session_update: 4,
    handle_permission_request: 4,
    handle_permission_request: 5,
    handle_file_read: 4,
    handle_file_write: 4,
    handle_terminal_request: 4,
    handle_form_elicitation: 2,
    handle_url_elicitation: 2,
    handle_elicitation_complete: 2,
    terminate: 2
  ]
end
