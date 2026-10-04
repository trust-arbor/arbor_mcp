defmodule Arbor.MCP.Server.DSL.Components do
  @moduledoc false

  @kinds [:tools, :resources, :resource_templates, :prompts]
  @version 1

  def import_entries(opts, env) do
    modules = Keyword.get(opts, :components, [])

    Enum.reduce(modules, Map.new(@kinds, &{&1, []}), fn module, acc ->
      info = component_info!(module, env)

      Map.new(@kinds, fn kind ->
        entries = Enum.map(Map.fetch!(info, kind), &import_entry/1)
        {kind, Map.fetch!(acc, kind) ++ entries}
      end)
    end)
  end

  def describe(module, groups, locations, env) do
    Map.new(groups, fn {kind, entries} ->
      {kind, Enum.map(entries, &describe_entry(&1, kind, module, locations, env))}
    end)
    |> Map.put(:version, @version)
  end

  def location(
        {definition, {:component, _module, _id, source}, _params},
        _kind,
        _locations,
        _env
      ),
      do: {definition, source}

  def location({definition, _handler, _params} = entry, kind, locations, env) do
    source = Map.get(locations, {kind, entry}, %{file: env.file, line: env.line})
    {definition, source}
  end

  def assert_unique!(info, env) do
    Enum.each(@kinds, fn kind ->
      info
      |> Map.fetch!(kind)
      |> Enum.group_by(& &1.id)
      |> Enum.each(fn {id, entries} -> assert_unique_group!(kind, id, entries, env) end)
    end)
  end

  def identifier(:tools, definition), do: definition.name
  def identifier(:resources, definition), do: definition.uri
  def identifier(:resource_templates, definition), do: definition.uriTemplate
  def identifier(:prompts, definition), do: definition.name

  def expand_modules(ast, env) do
    case Macro.expand(ast, env) do
      modules when is_list(modules) -> Enum.map(modules, &expand_module(&1, env))
      _ -> error!(env, "components must be a compile-time list of DSL modules")
    end
  end

  defp expand_module(ast, env) do
    case Macro.expand(ast, env) do
      module when is_atom(module) and module not in [nil, true, false] -> module
      _ -> error!(env, "components must contain compile-time DSL module names")
    end
  end

  defp component_info!(module, env) do
    if module == env.module, do: error!(env, "a DSL module cannot include itself as a component")

    with {:module, ^module} <- Code.ensure_compiled(module),
         true <- function_exported?(module, :__mcp_dsl_component__, 0),
         %{version: @version} = info <- module.__mcp_dsl_component__(),
         true <- Enum.all?(@kinds, &valid_entries?(Map.get(info, &1), &1)) do
      info
    else
      _ -> error!(env, "#{inspect(module)} is not a compatible compiled Server.DSL component")
    end
  end

  defp valid_entries?(entries, kind) when is_list(entries) do
    Enum.all?(entries, fn
      %{definition: definition, module: module, id: id, source: %{file: file, line: line}}
      when is_map(definition) and is_atom(module) and is_binary(id) and is_binary(file) and
             is_integer(line) ->
        identifier(kind, definition) == id

      _ ->
        false
    end)
  rescue
    KeyError -> false
  end

  defp valid_entries?(_entries, _kind), do: false

  defp import_entry(%{definition: definition, module: module, id: id, source: source}),
    do: {definition, {:component, module, id, source}, []}

  defp describe_entry(
         {definition, {:component, module, id, source}, _params},
         _kind,
         _host,
         _locations,
         _env
       ),
       do: %{definition: definition, module: module, id: id, source: source}

  defp describe_entry(entry, kind, module, locations, env) do
    {definition, source} = location(entry, kind, locations, env)
    %{definition: definition, module: module, id: identifier(kind, definition), source: source}
  end

  defp error!(env, description),
    do: raise(CompileError, file: env.file, line: env.line, description: description)

  defp assert_unique_group!(_kind, _id, [_entry], _env), do: :ok

  defp assert_unique_group!(kind, id, entries, env) do
    names = %{
      tools: :tool,
      resources: :resource,
      resource_templates: :resource_template,
      prompts: :prompt
    }

    sources =
      Enum.map_join(entries, ", ", fn entry -> "#{entry.source.file}:#{entry.source.line}" end)

    source = List.last(entries).source
    line = if source.file == env.file, do: source.line, else: env.line

    error!(
      %{env | line: line},
      "Duplicate #{names[kind]} #{inspect(id)} declared #{length(entries)} times (#{sources})"
    )
  end
end
