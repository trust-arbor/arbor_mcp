defmodule Arbor.MCP.Server.Subscriptions.Entry do
  @moduledoc """
  A modern MCP subscription registration.

  `subscription_id` is the client-chosen JSON-RPC request ID used on the wire.
  `token` is a distinct unguessable internal identifier and is never sent to
  the peer.
  """

  @enforce_keys [
    :token,
    :subscription_id,
    :listener_pid,
    :transport_ref,
    :filter,
    :expires_at
  ]
  defstruct [
    :token,
    :subscription_id,
    :listener_pid,
    :transport_ref,
    :filter,
    :principal_id,
    :tenant_id,
    :http_listener,
    :expires_at
  ]

  @typedoc "Registration data; `http_listener` is private transport bookkeeping."
  @type t :: %__MODULE__{
          token: String.t(),
          subscription_id: String.t() | integer(),
          listener_pid: pid(),
          transport_ref: pid(),
          filter: map(),
          principal_id: String.t() | nil,
          tenant_id: String.t() | nil,
          http_listener: term(),
          expires_at: integer()
        }
end
