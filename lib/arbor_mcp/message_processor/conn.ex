defmodule Arbor.MCP.MessageProcessor.Conn do
  @moduledoc """
  Connection struct representing an MCP message processing context.
  """

  defstruct [
    :request,
    :response,
    :state,
    :assigns,
    :transport,
    :session_id,
    :progress_token,
    :halted
  ]

  @type t :: %__MODULE__{
          request: map() | nil,
          response: map() | nil,
          state: term(),
          assigns: map(),
          transport: atom(),
          session_id: String.t() | nil,
          progress_token: String.t() | integer() | nil,
          halted: boolean()
        }

  # Struct-level primitive shared by `Arbor.MCP.MessageProcessor` and its method
  # handlers so the handlers do not depend back on the processor facade.
  @doc false
  @spec assign(t(), atom(), term()) :: t()
  def assign(%__MODULE__{} = conn, key, value) do
    %{conn | assigns: Map.put(conn.assigns, key, value)}
  end
end
