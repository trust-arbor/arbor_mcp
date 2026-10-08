defmodule Arbor.MCP.Credo.NamespaceAliasUsage do
  @moduledoc """
  Applies Credo's alias policy relative to explicit package namespace roots.

  `Arbor.MCP` and `Arbor.RPC` each occupy the package-root position previously
  occupied by `ExMCP`. Candidate discovery, frequency, exclusions, alias
  conflicts and issue metadata still come from Credo's standard check. Only
  the namespace depth calculation recognizes the additional organization
  segment; unrelated namespaces retain their original depth.
  """

  use Credo.Check,
    category: :design,
    base_priority: :normal,
    param_defaults:
      Credo.Check.Design.AliasUsage.param_defaults() ++
        [package_roots: ~w(Arbor.MCP Arbor.RPC)],
    explanations: [
      check:
        "Use aliases for repeatedly called modules nested below the configured package roots."
    ]

  @moduledoc false

  alias Credo.Check.Design.AliasUsage

  @impl true
  def run(source_file, params) do
    depth = Params.get(params, :if_nested_deeper_than, __MODULE__)
    roots = Params.get(params, :package_roots, __MODULE__)

    source_file
    |> AliasUsage.run(Keyword.put(params, :if_nested_deeper_than, 0))
    |> Enum.filter(&(package_depth(&1.trigger, roots) > depth))
  end

  defp package_depth(module_name, roots) do
    root = Enum.find(roots, &(module_name == &1 or String.starts_with?(module_name, &1 <> ".")))
    parts = length(String.split(module_name, "."))
    if root, do: parts - length(String.split(root, ".")) + 1, else: parts
  end
end
