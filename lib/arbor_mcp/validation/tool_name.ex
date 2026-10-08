defmodule Arbor.MCP.Validation.ToolName do
  @moduledoc """
  Validates MCP tool names according to the 2025-11-25 specification.

  Tool names must:
  - Be 1-128 characters long
  - Only contain alphanumeric characters, dots, hyphens, and underscores
  - Match the pattern: `^[a-zA-Z0-9_.\\-]+$`
  """

  @name_pattern ~r/^[a-zA-Z0-9_.\-]+$/
  @max_length 128

  @doc """
  Validates a tool name.

  Returns `{:ok, name}` if valid, `{:error, reason}` if invalid.

  ## Examples

      iex> Arbor.MCP.Validation.ToolName.validate("my_tool")
      {:ok, "my_tool"}

      iex> Arbor.MCP.Validation.ToolName.validate("my tool")
      {:error, "Tool name contains invalid characters. Must match [a-zA-Z0-9_.\\\\-]+"}

      iex> Arbor.MCP.Validation.ToolName.validate("")
      {:error, "Tool name must be between 1 and 128 characters"}
  """
  @spec validate(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate(name) when is_binary(name) do
    cond do
      byte_size(name) == 0 or byte_size(name) > @max_length ->
        {:error, "Tool name must be between 1 and #{@max_length} characters"}

      not Regex.match?(@name_pattern, name) ->
        {:error, "Tool name contains invalid characters. Must match [a-zA-Z0-9_.\\-]+"}

      true ->
        {:ok, name}
    end
  end

  def validate(_), do: {:error, "Tool name must be a string"}

  @doc """
  Returns true if the tool name is valid.
  """
  @spec valid?(String.t()) :: boolean()
  def valid?(name) when is_binary(name) do
    byte_size(name) > 0 and byte_size(name) <= @max_length and Regex.match?(@name_pattern, name)
  end

  def valid?(_), do: false
end
