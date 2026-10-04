defmodule Arbor.MCP.Client.EraCache do
  @moduledoc """
  Stores protocol-era observations independently of an individual client.

  Modern observations do not expire and cannot be replaced by an automatic
  legacy fallback. Legacy observations have a bounded lifetime so an upgraded
  server will eventually be probed again. Values used to identify HTTP auth
  configuration are hashed before they are stored in ETS.

  The cache is intentionally process-local. Operators can clear all
  observations with `clear/0`, or clear one connection identity by starting a
  client with `reset_era_cache: true`.
  """

  use GenServer

  alias Arbor.MCP.Transport.{HTTP, Local, ReliabilityWrapper, Stdio, Test}

  @table __MODULE__
  @default_legacy_ttl 300_000

  @type era :: :legacy | :modern
  @type identity :: :none | {:configured | :http | :process, binary()}
  @type observation :: %{
          era: era(),
          protocol_version: String.t(),
          observed_at: integer(),
          expires_at: integer() | :infinity
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the stable cache identity for a connected transport."
  @spec identity(module(), term(), keyword()) :: identity()
  def identity(transport_mod, transport_state, opts) do
    case transport_identity(transport_mod, transport_state, opts) do
      :none -> configured_identity(opts)
      identity -> identity
    end
  end

  @doc "Looks up a non-expired era observation."
  @spec lookup(identity()) :: {:ok, observation()} | :miss
  def lookup(:none), do: :miss

  def lookup(identity) do
    case table_lookup(identity) do
      [{^identity, observation}] ->
        if expired?(observation) do
          :ets.delete(@table, identity)
          :miss
        else
          {:ok, observation}
        end

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc "Records a successful protocol-era observation."
  @spec observe(identity(), era(), String.t(), keyword()) :: :ok
  def observe(identity, era, version, opts \\ [])

  def observe(:none, _era, _version, _opts), do: :ok

  def observe(identity, era, version, opts)
      when era in [:legacy, :modern] and is_binary(version) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, {:observe, identity, era, version, opts})
    end
  end

  @doc "Clears all cached protocol-era observations."
  @spec clear() :: :ok
  def clear do
    call_if_started(:clear)
  end

  @doc false
  @spec clear(identity()) :: :ok
  def clear(:none), do: :ok
  def clear(identity), do: call_if_started({:clear, identity})

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, table}
  end

  @impl true
  def handle_call({:observe, identity, era, version, opts}, _from, table) do
    observation = build_observation(era, version, opts)

    stored? =
      case table_lookup(identity) do
        [{^identity, %{era: :modern}}] when era == :legacy ->
          :telemetry.execute(
            [:arbor_mcp, :client, :era, :downgrade_attempt],
            %{count: 1},
            %{
              from: :modern,
              to: :legacy,
              observed_version: telemetry_version(version)
            }
          )

          false

        _other ->
          :ets.insert(table, {identity, observation})
          true
      end

    :telemetry.execute(
      [:arbor_mcp, :client, :era, :observed],
      %{},
      %{
        era: era,
        protocol_version: telemetry_version(version),
        identity_kind: identity_kind(identity),
        stored: stored?
      }
    )

    {:reply, :ok, table}
  end

  def handle_call({:clear, identity}, _from, table) do
    :ets.delete(table, identity)
    {:reply, :ok, table}
  end

  def handle_call(:clear, _from, table) do
    :ets.delete_all_objects(table)
    {:reply, :ok, table}
  end

  defp telemetry_version(version) do
    if Arbor.MCP.Internal.VersionRegistry.known?(version), do: version, else: :unknown
  end

  defp transport_identity(ReliabilityWrapper, state, opts) do
    {wrapped_module, wrapped_state} = ReliabilityWrapper.unwrap(state)
    transport_identity(wrapped_module, wrapped_state, opts)
  end

  defp transport_identity(HTTP, %HTTP{} = state, opts) do
    endpoint = canonical_http_endpoint(state)

    configuration = {
      normalize_headers(state.headers),
      state.http_client,
      state.security,
      state.origin,
      state.auth_config,
      state.auth_provider,
      Keyword.take(opts, [:headers, :security, :auth, :auth_provider, :http_client])
    }

    {:http, digest({endpoint, configuration})}
  end

  defp transport_identity(Stdio, %Stdio{subprocess: nil}, _opts), do: :none

  defp transport_identity(Stdio, %Stdio{} = state, _opts),
    do: {:process, digest({:stdio, Stdio.identity(state)})}

  defp transport_identity(Local, %Local{server_pid: server_pid}, _opts) do
    process_identity({:local, server_pid})
  end

  defp transport_identity(Test, %Test{peer_pid: peer_pid}, _opts) do
    process_identity({:test, peer_pid})
  end

  defp transport_identity(_transport_mod, _transport_state, _opts), do: :none

  defp configured_identity(opts) do
    case Keyword.get(opts, :era_cache_key) do
      nil -> :none
      configured -> {:configured, digest(configured)}
    end
  end

  defp process_identity(identity) do
    if Enum.any?(Tuple.to_list(identity), &(is_pid(&1) or is_port(&1) or is_integer(&1))) do
      {:process, digest(identity)}
    else
      :none
    end
  end

  defp canonical_http_endpoint(state) do
    base_uri = URI.parse(state.base_url)

    path =
      case state.endpoint do
        "" -> ""
        "/" <> _ = endpoint -> String.trim_trailing(endpoint, "/")
        endpoint -> "/" <> String.trim_trailing(endpoint, "/")
      end

    base_uri
    |> Map.put(:scheme, downcase(base_uri.scheme))
    |> Map.put(:host, downcase(base_uri.host))
    |> Map.put(:port, canonical_port(base_uri.scheme, base_uri.port))
    |> Map.put(:path, path)
    |> Map.put(:fragment, nil)
    |> Map.put(:userinfo, nil)
    |> URI.to_string()
  end

  defp canonical_port("http", 80), do: nil
  defp canonical_port("https", 443), do: nil
  defp canonical_port(_scheme, port), do: port

  defp downcase(value) when is_binary(value), do: String.downcase(value)
  defp downcase(value), do: value

  defp normalize_headers(headers) do
    headers
    |> Enum.map(fn {name, value} -> {String.downcase(to_string(name)), to_string(value)} end)
    |> Enum.sort()
  end

  defp build_observation(:modern, version, _opts) do
    %{era: :modern, protocol_version: version, observed_at: now(), expires_at: :infinity}
  end

  defp build_observation(:legacy, version, opts) do
    observed_at = now()
    ttl = legacy_ttl(opts)

    %{
      era: :legacy,
      protocol_version: version,
      observed_at: observed_at,
      expires_at: observed_at + ttl
    }
  end

  defp legacy_ttl(opts) do
    case Keyword.get(opts, :era_cache_legacy_ttl, @default_legacy_ttl) do
      ttl when is_integer(ttl) and ttl >= 0 -> ttl
      _invalid -> @default_legacy_ttl
    end
  end

  defp expired?(%{expires_at: :infinity}), do: false
  defp expired?(%{expires_at: expires_at}), do: now() >= expires_at

  defp now, do: System.monotonic_time(:millisecond)

  defp table_lookup(identity) do
    :ets.lookup(@table, identity)
  rescue
    ArgumentError -> []
  end

  defp call_if_started(message) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, message)
    end
  end

  defp identity_kind({kind, _digest}), do: kind
  defp identity_kind(:none), do: :none

  defp digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end
end
