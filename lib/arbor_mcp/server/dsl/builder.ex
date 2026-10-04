defmodule Arbor.MCP.Server.DSL.Builder do
  @moduledoc false

  @type param :: %{
          name: atom(),
          type: atom() | {atom(), any()},
          required: boolean(),
          default: any(),
          description: String.t() | nil,
          schema: map() | nil
        }

  @spec tool(String.t(), String.t() | nil, keyword()) :: map()
  def tool(name, description, opts) when is_binary(name) do
    params = Keyword.get(opts, :params, [])

    input_schema =
      case Keyword.get(opts, :input_schema) do
        nil -> schema_from_params(params)
        schema -> schema
      end

    %{
      name: name,
      inputSchema: input_schema
    }
    |> put_optional(:description, description)
    |> put_optional(:title, Keyword.get(opts, :title))
    |> put_optional(:outputSchema, Keyword.get(opts, :output_schema))
    |> put_optional(:annotations, normalize_map(Keyword.get(opts, :annotations)))
    |> put_optional(:icons, Keyword.get(opts, :icons))
    |> put_optional(:execution, normalize_map(Keyword.get(opts, :execution)))
    |> put_optional(:_meta, normalize_map(Keyword.get(opts, :meta)))
  end

  @spec resource(String.t(), String.t() | nil, keyword()) :: map()
  def resource(uri, description, opts) when is_binary(uri) do
    title = Keyword.get(opts, :title)

    %{
      uri: uri,
      name: Keyword.get(opts, :name) || uri
    }
    |> put_optional(:description, description)
    |> put_optional(:title, title)
    |> put_optional(:mimeType, Keyword.get(opts, :mime_type))
    |> put_optional(:annotations, normalize_map(Keyword.get(opts, :annotations)))
    |> put_optional(:size, Keyword.get(opts, :size))
    |> put_optional(:icons, Keyword.get(opts, :icons))
    |> put_optional(:_meta, normalize_map(Keyword.get(opts, :meta)))
  end

  @spec resource_template(String.t(), String.t() | nil, keyword()) :: map()
  def resource_template(uri_template, description, opts) when is_binary(uri_template) do
    title = Keyword.get(opts, :title)

    %{
      uriTemplate: uri_template,
      name: Keyword.get(opts, :name) || uri_template
    }
    |> put_optional(:description, description)
    |> put_optional(:title, title)
    |> put_optional(:mimeType, Keyword.get(opts, :mime_type))
    |> put_optional(:annotations, normalize_map(Keyword.get(opts, :annotations)))
    |> put_optional(:icons, Keyword.get(opts, :icons))
    |> put_optional(:_meta, normalize_map(Keyword.get(opts, :meta)))
  end

  @spec prompt(String.t(), String.t() | nil, keyword()) :: map()
  def prompt(name, description, opts) when is_binary(name) do
    %{
      name: name
    }
    |> put_optional(:description, description)
    |> put_optional(:title, Keyword.get(opts, :title))
    |> put_optional(:arguments, prompt_arguments(Keyword.get(opts, :args, [])))
    |> put_optional(:icons, Keyword.get(opts, :icons))
    |> put_optional(:_meta, normalize_map(Keyword.get(opts, :meta)))
  end

  @spec param(atom(), atom() | {atom(), any()}, keyword()) :: param()
  def param(name, type, opts \\ []) when is_atom(name) do
    %{
      name: name,
      type: type,
      required: Keyword.get(opts, :required, false),
      default: Keyword.get(opts, :default),
      description: Keyword.get(opts, :description),
      schema: Keyword.get(opts, :schema)
    }
  end

  @spec schema_from_params([param()]) :: map()
  def schema_from_params(params) do
    properties =
      params
      |> Enum.map(fn param ->
        schema =
          param
          |> param_schema()
          |> put_optional(:description, param.description)
          |> put_optional(:default, param.default)

        {param.name, schema}
      end)
      |> Map.new()

    required =
      params
      |> Enum.filter(& &1.required)
      |> Enum.map(&Atom.to_string(&1.name))

    %{type: "object", properties: properties}
    |> put_optional(:required, empty_to_nil(required))
  end

  @spec normalize_arguments(map(), [param()]) :: map()
  def normalize_arguments(arguments, []), do: arguments

  def normalize_arguments(arguments, params) when is_map(arguments) do
    Enum.reduce(params, arguments, fn param, acc ->
      atom_key = param.name
      string_key = Atom.to_string(atom_key)

      cond do
        Map.has_key?(acc, atom_key) ->
          acc

        Map.has_key?(acc, string_key) ->
          Map.put(acc, atom_key, Map.fetch!(acc, string_key))

        Map.has_key?(param, :default) and param.default != nil ->
          Map.put(acc, atom_key, param.default)

        true ->
          acc
      end
    end)
  end

  @spec normalize_template_variables(map()) :: map()
  def normalize_template_variables(vars) when is_map(vars) do
    Enum.reduce(vars, %{}, fn {key, value}, acc ->
      acc
      |> Map.put(key, value)
      |> maybe_put_atom_key(key, value)
    end)
  end

  defp prompt_arguments([]), do: nil

  defp prompt_arguments(args) do
    Enum.map(args, fn arg ->
      %{
        name: Atom.to_string(arg.name),
        required: arg.required
      }
      |> put_optional(:description, arg.description)
    end)
  end

  defp param_schema(%{schema: schema}) when is_map(schema), do: schema
  defp param_schema(%{type: type}), do: type_to_schema(type)

  @allowed_scalar_types [:string, :integer, :number, :boolean, :object, :map]

  @doc false
  def allowed_param_type?(type) when type in @allowed_scalar_types, do: true

  def allowed_param_type?({:array, item_type}) do
    allowed_param_type?(item_type)
  end

  def allowed_param_type?(_), do: false

  @doc false
  def allowed_param_types_hint do
    ":string, :integer, :number, :boolean, :object, :map, or {:array, type}"
  end

  defp type_to_schema(:string), do: %{type: "string"}
  defp type_to_schema(:integer), do: %{type: "integer"}
  defp type_to_schema(:number), do: %{type: "number"}
  defp type_to_schema(:boolean), do: %{type: "boolean"}
  defp type_to_schema(:object), do: %{type: "object"}
  defp type_to_schema(:map), do: %{type: "object"}

  defp type_to_schema({:array, item_type}) do
    %{type: "array", items: type_to_schema(item_type)}
  end

  # `default: []` is a valid JSON Schema default; only omit nil defaults.
  defp put_optional(map, :default, nil), do: map
  defp put_optional(map, :default, value), do: Map.put(map, :default, value)
  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, []), do: map
  defp put_optional(map, _key, %{} = value) when map_size(value) == 0, do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp empty_to_nil([]), do: nil
  defp empty_to_nil(value), do: value

  defp normalize_map(nil), do: nil
  defp normalize_map(value) when is_list(value), do: Map.new(value)
  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(value), do: value

  defp maybe_put_atom_key(map, key, value) when is_binary(key) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, key) do
      Map.put(map, String.to_atom(key), value)
    else
      map
    end
  end

  defp maybe_put_atom_key(map, _key, _value), do: map
end
