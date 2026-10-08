defmodule Arbor.MCP.Transport.SecurityError do
  @moduledoc """
  Standardized security error handling across transports.

  This module provides consistent error formatting and handling
  for security violations across all MCP transports.
  """

  defstruct [:type, :message, :details, :timestamp]

  alias Arbor.MCP.Protocol.ErrorCodes

  @type t :: %__MODULE__{
          type: atom(),
          message: String.t(),
          details: map(),
          timestamp: DateTime.t()
        }

  @type error_type ::
          :token_passthrough_blocked
          | :consent_required
          | :consent_denied
          | :consent_error
          | :security_violation

  @doc """
  Creates a new security error.

  ## Parameters

  - `type` - The type of security violation
  - `message` - Human-readable error message
  - `details` - Additional context about the error

  ## Examples

      error = SecurityError.new(:consent_required,
        "User consent required",
        %{url: "https://api.example.com", user_id: "user123"}
      )
  """
  @spec new(error_type(), String.t(), map()) :: t()
  def new(type, message, details \\ %{}) do
    %__MODULE__{
      type: type,
      message: message,
      details: details,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Formats a security error for a specific transport.

  Different transports may need different error formats:
  - HTTP: Status codes and JSON responses
  - Stdio: JSON-RPC error format
  - BEAM: Elixir error tuples
  """
  @spec format_for_transport(t(), atom()) :: term()
  def format_for_transport(%__MODULE__{} = error, :http) do
    %{
      status: 403,
      headers: [{"content-type", "application/json"}],
      body:
        Jason.encode!(%{
          error: %{
            type: error.type,
            message: error.message,
            details: error.details,
            timestamp: DateTime.to_iso8601(error.timestamp)
          }
        })
    }
  end

  def format_for_transport(%__MODULE__{} = error, :stdio) do
    # JSON-RPC 2.0 error format
    %{
      code: error_code_for_type(error.type),
      message: error.message,
      data:
        Map.merge(error.details, %{
          type: error.type,
          timestamp: DateTime.to_iso8601(error.timestamp)
        })
    }
  end

  def format_for_transport(%__MODULE__{} = error, :beam) do
    # Native Elixir error tuple
    {error.type, error.message, error.details}
  end

  def format_for_transport(%__MODULE__{} = error, _transport) do
    # Generic format for unknown transports
    %{
      type: error.type,
      message: error.message,
      details: error.details,
      timestamp: error.timestamp
    }
  end

  @doc """
  Converts a security error to a standard Elixir error tuple.
  """
  @spec to_error_tuple(t()) :: {:error, term()}
  def to_error_tuple(%__MODULE__{} = error) do
    {:error,
     %{
       type: error.type,
       message: error.message,
       details: error.details
     }}
  end

  @doc """
  Checks if an error is a security-related error.
  """
  @spec security_error?(term()) :: boolean()
  def security_error?(%__MODULE__{}), do: true

  def security_error?({:error, %{type: type}})
      when type in [
             :token_passthrough_blocked,
             :consent_required,
             :consent_denied,
             :consent_error,
             :security_violation
           ],
      do: true

  def security_error?(_), do: false

  # Private helper functions

  defp error_code_for_type(:token_passthrough_blocked), do: -32001
  defp error_code_for_type(:consent_required), do: ErrorCodes.consent_required()
  defp error_code_for_type(:consent_denied), do: -32003
  defp error_code_for_type(:consent_error), do: -32004
  defp error_code_for_type(:security_violation), do: -32000
  # Internal error
  defp error_code_for_type(_), do: -32603
end
