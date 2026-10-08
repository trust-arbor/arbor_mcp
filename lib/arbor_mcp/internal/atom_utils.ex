defmodule Arbor.MCP.Internal.AtomUtils do
  @moduledoc """
  Internal utilities for safe atom handling.

  This module provides functions to safely convert strings to atoms
  without risking atom table exhaustion from untrusted input.
  """

  @doc """
  Safely converts a binary string to an atom if the atom already exists.
  Otherwise, returns a generic :__unknown_key__ atom. Prevents atom exhaustion attacks
  and ensures consistent map key types.

  ## Examples

      iex> Arbor.MCP.Internal.AtomUtils.safe_string_to_atom("name")
      :name  # if :name already exists

      iex> Arbor.MCP.Internal.AtomUtils.safe_string_to_atom("unknown_key_12345")
      :__unknown_key__  # returns generic atom for unknown keys
  """
  @spec safe_string_to_atom(String.t() | atom()) :: atom()
  def safe_string_to_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError ->
      require Logger

      Logger.warning(
        "Received unexpected key '#{key}' that cannot be atomized to an existing atom. Mapping to :__unknown_key__."
      )

      # Return a generic atom to maintain consistent map key types
      :__unknown_key__
  end

  def safe_string_to_atom(key), do: key
end
