defmodule Arbor.MCP.Protocol.ResultEnvelope do
  @moduledoc """
  Classifies result envelopes according to the negotiated MCP protocol era.

  Legacy peers may omit `resultType`; modern and unnegotiated peers may not.
  Extension result types are accepted only when the caller explicitly lists
  them as negotiated.
  """

  alias Arbor.MCP.Internal.VersionRegistry
  alias Arbor.MCP.Protocol.CacheableResult

  @type result_kind :: :complete | :input_required | {:extension, String.t()}
  @type classification_error ::
          :result_must_be_object
          | :missing_result_type
          | {:invalid_result_type, term()}
          | {:unknown_result_type, String.t()}
          | CacheableResult.validation_error()

  @doc "Classifies a result without changing its wire representation."
  @spec classify(map(), :legacy | :modern | :unknown | String.t() | nil, keyword()) ::
          {:ok, result_kind()} | {:error, classification_error()}
  def classify(result, version_or_era, opts \\ [])

  def classify(result, version_or_era, opts) when is_map(result) do
    era = normalize_era(version_or_era)
    allowed_extensions = Keyword.get(opts, :allowed_result_types, [])

    case fetch_result_type(result) do
      :missing when era == :legacy ->
        {:ok, :complete}

      :missing ->
        {:error, :missing_result_type}

      {:ok, "complete"} ->
        {:ok, :complete}

      {:ok, "input_required"} ->
        {:ok, :input_required}

      {:ok, type} when is_binary(type) ->
        if type in allowed_extensions,
          do: {:ok, {:extension, type}},
          else: {:error, {:unknown_result_type, type}}

      {:ok, type} ->
        {:error, {:invalid_result_type, type}}
    end
  end

  def classify(_result, _version_or_era, _opts), do: {:error, :result_must_be_object}

  @doc "Validates a result and returns it unchanged with its classification."
  @spec validate(map(), :legacy | :modern | :unknown | String.t() | nil, keyword()) ::
          {:ok, result_kind(), map()} | {:error, classification_error()}
  def validate(result, version_or_era, opts \\ []) do
    with {:ok, kind} <- classify(result, version_or_era, opts),
         :ok <- validate_cache_hints(result, kind, version_or_era, opts) do
      {:ok, kind, result}
    end
  end

  defp validate_cache_hints(result, kind, version_or_era, opts) do
    if normalize_era(version_or_era) == :modern do
      CacheableResult.validate(Keyword.get(opts, :method), kind, result)
    else
      :ok
    end
  end

  defp fetch_result_type(result) do
    cond do
      Map.has_key?(result, "resultType") -> {:ok, result["resultType"]}
      Map.has_key?(result, :resultType) -> {:ok, result[:resultType]}
      true -> :missing
    end
  end

  defp normalize_era(era) when era in [:legacy, :modern, :unknown], do: era
  defp normalize_era(nil), do: :unknown
  defp normalize_era(version) when is_binary(version), do: VersionRegistry.era_for(version)
  defp normalize_era(_version), do: :unknown
end
