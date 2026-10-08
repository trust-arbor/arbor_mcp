defmodule Arbor.MCP.Content.SchemaPolicy.ModernResolver do
  @moduledoc false
  @behaviour JSV.Resolver

  @impl true
  def resolve(uri, documents) do
    case Map.fetch(documents, uri) do
      {:ok, true} -> {:normal, %{}}
      {:ok, false} -> {:normal, %{"not" => %{}}}
      {:ok, document} -> {:normal, document}
      :error -> embedded_only(uri)
    end
  end

  defp embedded_only(uri) do
    # These are static bundled standards, never a network or application module
    # lookup. The policy rejects JSV module refs before its mandatory fallback.
    case JSV.Resolver.Embedded.resolve(uri, []) do
      {:normal, _schema} = embedded -> embedded
      _other -> {:error, :schema_reference_unavailable}
    end
  end
end
