defmodule Arbor.MCP.Internal.Headers do
  @moduledoc false

  @type header_name :: String.t() | charlist() | atom()
  @type headers :: %{optional(header_name()) => term()} | [{header_name(), term()}]

  @spec get(headers() | term(), header_name()) :: term() | nil
  def get(headers, name) when is_map(headers) or is_list(headers) do
    with name when is_binary(name) <- normalize_name(name) do
      Enum.find_value(headers, fn
        {key, value} ->
          if normalize_name(key) == name, do: normalize_value(value), else: nil

        _ ->
          nil
      end)
    end
  end

  def get(_headers, _name), do: nil

  @spec delete(list(), header_name()) :: list()
  def delete(headers, name) when is_list(headers) do
    case normalize_name(name) do
      name when is_binary(name) ->
        Enum.reject(headers, fn
          {key, _value} -> normalize_name(key) == name
          _ -> false
        end)

      _ ->
        headers
    end
  end

  def delete(headers, _name), do: headers

  defp normalize_name(name) when is_binary(name), do: String.downcase(name)

  defp normalize_name(name) when is_list(name) do
    name
    |> List.to_string()
    |> String.downcase()
  end

  defp normalize_name(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.downcase()
  end

  defp normalize_name(_name), do: nil

  defp normalize_value(value) when is_list(value), do: List.to_string(value)
  defp normalize_value(value), do: value
end
