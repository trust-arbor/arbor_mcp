defmodule Arbor.MCP.Content.SchemaPolicy.Compiled do
  @moduledoc """
  Opaque modern JSON Schema artifact returned by `Arbor.MCP.Content.SchemaPolicy`.

  Use `Arbor.MCP.Content.SchemaPolicy.compile/1,2` and
  `Arbor.MCP.Content.SchemaPolicy.validate/2,3` to create and validate artifacts.
  Their representation and validator backend are private.
  """

  @enforce_keys [:root]
  defstruct [:root]

  @opaque t :: %__MODULE__{root: JSV.Root.t()}

  @max_errors 16
  @max_text_bytes 256
  @fallback {"value does not conform to JSON Schema", "#"}

  @doc false
  @spec new(JSV.Root.t()) :: t()
  def new(root), do: %__MODULE__{root: root}

  @doc false
  @spec fetch(term()) :: {:ok, t()} | :error
  def fetch(%__MODULE__{} = compiled), do: {:ok, compiled}
  def fetch(_other), do: :error

  @doc false
  @spec validate(t(), term()) :: :ok | {:error, [{String.t(), String.t()}]}
  def validate(%__MODULE__{root: root}, data) do
    case JSV.validate(data, root, cast: false, cast_formats: false) do
      {:ok, _unreturned_data} -> :ok
      {:error, error} -> {:error, diagnostics(error)}
    end
  end

  defp diagnostics(error) do
    # Use the public normalization API rather than opening opaque validator errors.
    # Only property names and instance paths are retained. Numeric values, enum
    # members, constants and the backend's full messages never leave this worker.
    %{details: units} =
      JSV.normalize_error(error, min_error_level: JSV.ErrorFormatter.level_cause())

    {errors, _remaining} = collect_units(units, [], @max_errors)
    if errors == [], do: [@fallback], else: Enum.reverse(errors)
  end

  defp collect_units(_units, errors, 0), do: {errors, 0}
  defp collect_units([], errors, remaining), do: {errors, remaining}

  defp collect_units([%{errors: entries, instanceLocation: path} | rest], errors, remaining) do
    {errors, remaining} = collect_errors(entries, path, errors, remaining)
    collect_units(rest, errors, remaining)
  end

  defp collect_units([_valid_annotation | rest], errors, remaining),
    do: collect_units(rest, errors, remaining)

  defp collect_errors(_entries, _path, errors, 0), do: {errors, 0}
  defp collect_errors([], _path, errors, remaining), do: {errors, remaining}

  defp collect_errors(
         [%{details: [_first | _rest] = units} = entry | rest],
         path,
         errors,
         remaining
       ) do
    case collect_units(units, errors, remaining) do
      {^errors, ^remaining} ->
        diagnostic = {message(entry), bounded_path(path)}
        collect_errors(rest, path, [diagnostic | errors], remaining - 1)

      {errors, remaining} ->
        collect_errors(rest, path, errors, remaining)
    end
  end

  defp collect_errors([entry | rest], path, errors, remaining) do
    diagnostic = {message(entry), bounded_path(path)}
    collect_errors(rest, path, [diagnostic | errors], remaining - 1)
  end

  defp message(%{kind: kind, message: message})
       when kind in [:required, :dependentRequired] do
    bounded_text(message, "required properties are missing")
  end

  defp message(%{kind: kind}) when is_atom(kind) do
    bounded_text("value does not satisfy " <> Atom.to_string(kind), elem(@fallback, 0))
  end

  defp message(_entry), do: elem(@fallback, 0)

  defp bounded_path(path) when is_binary(path) and byte_size(path) <= @max_text_bytes,
    do: bounded_text(path, "#")

  defp bounded_path(_path), do: "#"

  defp bounded_text(text, _fallback) when is_binary(text) and byte_size(text) <= @max_text_bytes,
    do: String.replace(text, ~r/[\x00-\x1f\x7f]/u, "?")

  defp bounded_text(_text, fallback), do: fallback
end
