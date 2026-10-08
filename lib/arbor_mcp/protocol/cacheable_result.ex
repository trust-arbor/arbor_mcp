defmodule Arbor.MCP.Protocol.CacheableResult do
  @moduledoc """
  Defines and validates the cache hints required by modern MCP results.

  The method set is pinned to the `CacheableResult` implementors in the
  vendored 2026-07-28 schema. A schema-sync test derives that set directly
  from `schema.json`, so a future spec update cannot silently leave this
  runtime table stale.

  This module validates wire metadata only. It does not store or reuse
  responses.
  """

  @cacheable_methods ~w(
    server/discover
    tools/list
    prompts/list
    resources/list
    resources/templates/list
    resources/read
  )

  @type result_kind :: :complete | :input_required | {:extension, String.t()}
  @type validation_error ::
          :missing_ttl_ms
          | {:invalid_ttl_ms, term()}
          | :missing_cache_scope
          | {:invalid_cache_scope, term()}
          | :cache_hints_not_allowed

  @doc "Returns the schema-defined methods whose complete results carry cache hints."
  @spec methods() :: [String.t()]
  def methods, do: @cacheable_methods

  @doc "Returns whether a method has a cacheable complete result in MCP 2026-07-28."
  @spec cacheable_method?(term()) :: boolean()
  def cacheable_method?(method), do: method in @cacheable_methods

  @doc "Validates cache hints for a classified modern result."
  @spec validate(term(), result_kind(), map()) :: :ok | {:error, validation_error()}
  def validate(method, :complete, result) when method in @cacheable_methods do
    with {:ok, ttl_ms} <- fetch(result, "ttlMs", :ttlMs, :missing_ttl_ms),
         :ok <- validate_ttl_ms(ttl_ms),
         {:ok, cache_scope} <-
           fetch(result, "cacheScope", :cacheScope, :missing_cache_scope) do
      validate_cache_scope(cache_scope)
    end
  end

  def validate(method, _kind, result) when method in @cacheable_methods do
    if cache_hints_present?(result), do: {:error, :cache_hints_not_allowed}, else: :ok
  end

  def validate(_method, _kind, _result), do: :ok

  defp fetch(result, string_key, atom_key, missing_error) do
    cond do
      Map.has_key?(result, string_key) -> {:ok, Map.get(result, string_key)}
      Map.has_key?(result, atom_key) -> {:ok, Map.get(result, atom_key)}
      true -> {:error, missing_error}
    end
  end

  defp validate_ttl_ms(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_ttl_ms(value), do: {:error, {:invalid_ttl_ms, value}}

  defp validate_cache_scope(value) when value in ["public", "private"], do: :ok
  defp validate_cache_scope(value), do: {:error, {:invalid_cache_scope, value}}

  defp cache_hints_present?(result) do
    Enum.any?(["ttlMs", :ttlMs, "cacheScope", :cacheScope], &Map.has_key?(result, &1))
  end
end
