defmodule Arbor.MCP.Server.Discover do
  @moduledoc """
  Assembles and validates `server/discover` results.

  Discovery is the modern, stateless replacement for initialize-time server
  metadata. The protocol mode controls the advertised preference order; rc.6
  defaults servers to dual-era, modern-preferred discovery.
  """

  alias Arbor.MCP.Internal.VersionRegistry

  @default_ttl_ms 3_600_000

  @type parse_error ::
          :result_must_be_object
          | {:invalid_discover_field, String.t()}

  @doc "Builds the body of a modern discovery result."
  @spec build(map(), map(), keyword()) :: map()
  def build(server_info, capabilities, opts \\ []) do
    mode = Keyword.get(opts, :protocol_mode) || VersionRegistry.protocol_mode()

    supported_versions =
      Keyword.get(opts, :supported_versions) || VersionRegistry.enabled_versions(mode)

    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    cache_scope = Keyword.get(opts, :cache_scope, "public")

    %{
      "supportedVersions" => supported_versions,
      "capabilities" => capabilities,
      "ttlMs" => normalize_ttl(ttl_ms),
      "cacheScope" => normalize_cache_scope(cache_scope),
      "_meta" => %{
        "io.modelcontextprotocol/serverInfo" => server_info
      }
    }
    |> put_optional("instructions", Keyword.get(opts, :instructions))
  end

  @doc "Validates and extracts a discovery result received by a client."
  @spec parse_result(term()) :: {:ok, map()} | {:error, parse_error()}
  def parse_result(result) when is_map(result) do
    with {:ok, supported_versions} <- supported_versions(result),
         {:ok, capabilities} <- object_field(result, "capabilities"),
         {:ok, ttl_ms} <- ttl_field(result),
         {:ok, cache_scope} <- cache_scope_field(result) do
      {:ok,
       %{
         supported_versions: supported_versions,
         capabilities: capabilities,
         instructions: field(result, "instructions"),
         server_info: server_info(result),
         ttl_ms: ttl_ms,
         cache_scope: cache_scope
       }}
    end
  end

  def parse_result(_result), do: {:error, :result_must_be_object}

  defp supported_versions(result) do
    case field(result, "supportedVersions") do
      versions when is_list(versions) and versions != [] ->
        if Enum.all?(versions, &is_binary/1),
          do: {:ok, versions},
          else: invalid_field("supportedVersions")

      _other ->
        invalid_field("supportedVersions")
    end
  end

  defp object_field(result, key) do
    case field(result, key) do
      value when is_map(value) -> {:ok, value}
      _other -> invalid_field(key)
    end
  end

  defp ttl_field(result) do
    case field(result, "ttlMs") do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _other -> invalid_field("ttlMs")
    end
  end

  defp cache_scope_field(result) do
    case field(result, "cacheScope") do
      scope when scope in ["public", "private", :public, :private] ->
        {:ok, normalize_cache_scope(scope)}

      _other ->
        invalid_field("cacheScope")
    end
  end

  defp field(result, "supportedVersions"),
    do: Map.get(result, "supportedVersions") || Map.get(result, :supportedVersions)

  defp field(result, "capabilities"),
    do: Map.get(result, "capabilities") || Map.get(result, :capabilities)

  defp field(result, "instructions"),
    do: Map.get(result, "instructions") || Map.get(result, :instructions)

  defp field(result, "ttlMs"), do: Map.get(result, "ttlMs") || Map.get(result, :ttlMs)

  defp field(result, "cacheScope"),
    do: Map.get(result, "cacheScope") || Map.get(result, :cacheScope)

  defp server_info(result) do
    case Map.get(result, "_meta") || Map.get(result, :_meta) do
      meta when is_map(meta) ->
        Map.get(meta, "io.modelcontextprotocol/serverInfo") ||
          Map.get(meta, :"io.modelcontextprotocol/serverInfo")

      _other ->
        nil
    end
  end

  defp normalize_ttl(ttl) when is_integer(ttl) and ttl >= 0, do: ttl
  defp normalize_ttl(_ttl), do: @default_ttl_ms

  defp normalize_cache_scope(:public), do: "public"
  defp normalize_cache_scope(:private), do: "private"
  defp normalize_cache_scope("private"), do: "private"
  defp normalize_cache_scope(_scope), do: "public"

  defp invalid_field(field), do: {:error, {:invalid_discover_field, field}}
  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
