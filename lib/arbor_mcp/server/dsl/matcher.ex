defmodule Arbor.MCP.Server.DSL.Matcher do
  @moduledoc false

  @spec match_uri_template(String.t(), String.t()) :: {:ok, map()} | :error
  def match_uri_template(uri, template) when is_binary(uri) and is_binary(template) do
    with {:ok, regex} <- Regex.compile("^" <> regex_source(template) <> "$"),
         %{} = captures <- Regex.named_captures(regex, uri) do
      {:ok, captures}
    else
      _ -> :error
    end
  end

  defp regex_source(template) do
    ~r/\{([^}]+)\}/
    |> Regex.split(template, include_captures: true, trim: false)
    |> Enum.map_join(&regex_part/1)
  end

  defp regex_part("{" <> rest = part) do
    if String.ends_with?(part, "}") do
      variable =
        rest
        |> String.trim_trailing("}")
        |> String.replace(~r/[^A-Za-z0-9_]/, "_")

      "(?<#{variable}>[^/]+)"
    else
      Regex.escape(part)
    end
  end

  defp regex_part(part), do: Regex.escape(part)
end
