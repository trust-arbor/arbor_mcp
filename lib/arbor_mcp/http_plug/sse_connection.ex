defmodule Arbor.MCP.HttpPlug.SSEConnection do
  @moduledoc """
  Connection operations `Arbor.MCP.HttpPlug.SSEHandler` needs from its socket.

  The handler used to sniff its `conn` at runtime (`is_struct/1` plus
  `Map.has_key?/2` checks for `:chunk` and `:get_req_header` function fields)
  so that tests could pass a fake connection. That put test-only branches in
  the production write path.

  Instead the handler calls a *connection module* resolved once at start-up
  from the `:conn_module` key of its options, defaulting to
  `Arbor.MCP.HttpPlug.SSEConnection.PlugConn`. Tests (or alternative adapters)
  supply their own implementation:

      SSEHandler.start_link(fake_conn, session_id, %{conn_module: MyFakeConn})
  """

  @type conn :: term()

  @doc "Writes a chunk to the connection."
  @callback chunk(conn(), iodata()) :: {:ok, conn()} | {:error, term()}

  @doc "Reads a request header, returning a (possibly empty) list of values."
  @callback get_req_header(conn(), String.t()) :: [String.t()]

  @default_module __MODULE__.PlugConn

  @doc """
  Resolves the connection module from handler options.
  """
  @spec resolve(map() | keyword()) :: module()
  def resolve(opts) when is_map(opts), do: Map.get(opts, :conn_module) || @default_module
  def resolve(opts) when is_list(opts), do: Keyword.get(opts, :conn_module) || @default_module
  def resolve(_opts), do: @default_module

  defmodule PlugConn do
    @moduledoc """
    Default `Arbor.MCP.HttpPlug.SSEConnection` implementation backed by `Plug.Conn`.
    """

    @behaviour Arbor.MCP.HttpPlug.SSEConnection

    @impl true
    def chunk(%Plug.Conn{} = conn, message), do: Plug.Conn.chunk(conn, message)
    def chunk(_conn, _message), do: {:error, :not_supported}

    @impl true
    def get_req_header(%Plug.Conn{} = conn, header), do: Plug.Conn.get_req_header(conn, header)
    def get_req_header(_conn, _header), do: []
  end
end
