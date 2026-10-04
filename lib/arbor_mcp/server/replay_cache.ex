defmodule Arbor.MCP.Server.ReplayCache do
  @moduledoc """
  Behaviour for atomically consuming MRTR continuation identifiers.

  A replay cache is optional because consuming a token changes ambiguous
  network failure semantics. Enable one for resumed handlers that may cause
  side effects; otherwise `Arbor.MCP.Server.RequestContext.delivery_semantics` is
  explicitly `:at_least_once`.
  """

  @callback consume(jti :: String.t(), expires_at :: integer(), opts :: keyword()) ::
              :ok | {:error, :replayed | term()}

  @doc "Consumes a continuation ID through an explicitly addressed runtime replay service."
  def consume(service, jti, expires_at),
    do: Arbor.MCP.Server.Runtime.Services.consume(service, jti, expires_at)
end

defmodule Arbor.MCP.Server.ReplayCache.ETS do
  @moduledoc """
  Node-local atomic replay cache for MRTR request state.

  Clustered servers should configure an adapter backed by their shared
  consistency store instead.
  """

  use GenServer

  @impl true
  def format_status(status),
    do: Arbor.MCP.Server.Runtime.Diagnostics.format_status(status, __MODULE__)

  @behaviour Arbor.MCP.Server.ReplayCache

  @name __MODULE__

  alias Arbor.MCP.Server.Runtime.ServiceAdapter

  def start_link(opts \\ []) do
    server_opts = [timeout: Keyword.get(opts, :init_timeout_ms, :infinity)]

    case Keyword.get(opts, :name, @name) do
      nil -> GenServer.start_link(__MODULE__, opts, server_opts)
      name -> GenServer.start_link(__MODULE__, opts, Keyword.put(server_opts, :name, name))
    end
  end

  @doc false
  def runtime_service_capabilities, do: %{bounded_startup: 1}

  @impl Arbor.MCP.Server.ReplayCache
  def consume(jti, expires_at, opts \\ [])
      when is_binary(jti) and is_integer(expires_at) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:consume, jti, expires_at, System.system_time(:second)})
  catch
    :exit, reason -> {:error, {:replay_cache_unavailable, reason}}
  end

  @impl GenServer
  def init(opts) do
    with :ok <- ServiceAdapter.watch_owned(opts), do: {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:consume, jti, expires_at, now}, _from, entries) do
    entries = Map.reject(entries, fn {_seen_jti, expiry} -> expiry < now end)

    if Map.has_key?(entries, jti) do
      {:reply, {:error, :replayed}, entries}
    else
      {:reply, :ok, Map.put(entries, jti, expires_at)}
    end
  end
end
