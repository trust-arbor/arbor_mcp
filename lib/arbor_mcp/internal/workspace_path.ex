defmodule Arbor.MCP.Internal.WorkspacePath do
  @moduledoc false

  @max_symlink_depth 40

  @spec within?(String.t(), String.t()) :: boolean()
  def within?(path, root) when is_binary(path) and is_binary(root) do
    relative = path |> canonical() |> Path.relative_to(canonical(root))

    relative == "." or
      (Path.type(relative) == :relative and relative != ".." and
         not String.starts_with?(relative, "../"))
  end

  def within?(_path, _root), do: false

  @spec canonical(String.t()) :: String.t()
  def canonical(path) when is_binary(path), do: resolve_components(Path.expand(path), 0)

  # Resolve every symlink that exists at authorization time. Nonexistent final
  # components retain their lexical location under the resolved parent so safe
  # create/write requests remain possible without trusting symlink escapes.
  defp resolve_components(path, depth) when depth >= @max_symlink_depth, do: path

  defp resolve_components(path, depth) do
    case Path.split(path) do
      [base | components] ->
        Enum.reduce(components, base, &resolve_component(&1, &2, depth))

      [] ->
        path
    end
  end

  defp resolve_component(component, resolved_parent, depth) do
    candidate = Path.join(resolved_parent, component)

    case :file.read_link(to_charlist(candidate)) do
      {:ok, target} -> resolve_link_target(to_string(target), candidate, depth)
      {:error, _reason} -> candidate
    end
  end

  defp resolve_link_target(target, candidate, depth) do
    target =
      if Path.type(target) == :absolute,
        do: target,
        else: Path.join(Path.dirname(candidate), target)

    target
    |> Path.expand()
    |> resolve_components(depth + 1)
  end
end
