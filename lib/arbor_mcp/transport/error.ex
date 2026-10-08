defmodule Arbor.MCP.Transport.Error do
  @moduledoc """
  Standardized error handling for MCP transports.

  This module provides consistent error patterns and error handling functions
  for all MCP transport implementations. It ensures that all transports return
  errors in the same format for better client compatibility.

  ## Standard Error Types

  - `:connection_error` - Connection establishment or maintenance failures
  - `:transport_error` - Transport-level communication failures  
  - `:security_violation` - Security policy violations
  - `:validation_error` - Message or parameter validation failures
  - `:timeout_error` - Operation timeout failures
  - `:protocol_error` - Protocol-level violations or incompatibilities

  ## Usage

      # In transport implementations
      case some_operation() do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> Error.transport_error(reason)
      end

      # Connection failures
      Error.connection_error(:server_not_available)

      # Security violations  
      Error.security_violation("Invalid origin")
  """

  @type error_type ::
          :connection_error
          | :transport_error
          | :security_violation
          | :validation_error
          | :timeout_error
          | :protocol_error

  @type error_reason :: atom() | String.t() | map()

  @doc """
  Creates a standardized connection error.

  Used when transport connection establishment or maintenance fails.
  """
  @spec connection_error(error_reason()) :: {:error, {error_type(), error_reason()}}
  def connection_error(reason) do
    {:error, {:connection_error, reason}}
  end

  @doc """
  Creates a standardized transport error.

  Used for transport-level communication failures.
  """
  @spec transport_error(error_reason()) :: {:error, {error_type(), error_reason()}}
  def transport_error(reason) do
    {:error, {:transport_error, reason}}
  end

  @doc """
  Creates a standardized security violation error.

  Used when security policies are violated.
  """
  @spec security_violation(error_reason()) :: {:error, {error_type(), error_reason()}}
  def security_violation(reason) do
    {:error, {:security_violation, reason}}
  end

  @doc """
  Creates a standardized validation error.

  Used when message or parameter validation fails.
  """
  @spec validation_error(error_reason()) :: {:error, {error_type(), error_reason()}}
  def validation_error(reason) do
    {:error, {:validation_error, reason}}
  end

  @doc """
  Creates a standardized timeout error.

  Used when operations exceed their timeout limits.
  """
  @spec timeout_error(error_reason()) :: {:error, {error_type(), error_reason()}}
  def timeout_error(reason) do
    {:error, {:timeout_error, reason}}
  end

  @doc """
  Creates a standardized protocol error.

  Used when protocol-level violations or incompatibilities occur.
  """
  @spec protocol_error(error_reason()) :: {:error, {error_type(), error_reason()}}
  def protocol_error(reason) do
    {:error, {:protocol_error, reason}}
  end

  @doc """
  Wraps an arbitrary error in the standard transport error format.

  This is useful for converting legacy error formats or third-party
  library errors into the standard format.
  """
  @spec wrap_error(error_type(), any()) :: {:error, {error_type(), any()}}
  def wrap_error(type, reason)
      when type in [
             :connection_error,
             :transport_error,
             :security_violation,
             :validation_error,
             :timeout_error,
             :protocol_error
           ] do
    {:error, {type, reason}}
  end

  @doc """
  Normalizes an error tuple to the standard format.

  Converts various error formats into the standardized transport error format.
  """
  @spec normalize_error(any()) :: {:error, {error_type(), any()}}
  def normalize_error({:error, {type, reason}}) when is_atom(type) do
    # Already in standard format
    {:error, {type, reason}}
  end

  def normalize_error({:error, reason}) do
    # Convert simple error to transport error
    transport_error(reason)
  end

  def normalize_error(other) do
    # Wrap unexpected format
    transport_error(other)
  end

  @doc """
  Checks if an error is of a specific type.

  ## Examples

      error = Error.connection_error(:timeout)
      Error.error_type?(error, :connection_error)  #=> true
      Error.error_type?(error, :transport_error)   #=> false
  """
  @spec error_type?({:error, {error_type(), any()}}, error_type()) :: boolean()
  def error_type?({:error, {type, _reason}}, expected_type) do
    type == expected_type
  end

  def error_type?(_, _), do: false

  @doc """
  Extracts the error type from a standardized error tuple.

  Returns `:unknown` for non-standard error formats.
  """
  @spec get_error_type({:error, {error_type(), any()}} | any()) :: error_type() | :unknown
  def get_error_type({:error, {type, _reason}}) when is_atom(type) do
    type
  end

  def get_error_type(_), do: :unknown

  @doc """
  Extracts the error reason from a standardized error tuple.

  Returns the original error for non-standard formats.
  """
  @spec get_error_reason({:error, {error_type(), any()}} | any()) :: any()
  def get_error_reason({:error, {_type, reason}}) do
    reason
  end

  def get_error_reason(error), do: error

  @doc """
  Validates connection state before performing transport operations.

  This helper provides consistent connection validation across all transports.
  It should be called before send_message and receive_message operations.

  ## Examples

      case Error.validate_connection(state, &MyTransport.connected?/1) do
        :ok -> 
          # Proceed with operation
        {:error, reason} -> 
          # Handle disconnected state
      end
  """
  @spec validate_connection(any(), (any() -> boolean())) ::
          :ok | {:error, {error_type(), any()}}
  def validate_connection(state, connected_check_fn) when is_function(connected_check_fn, 1) do
    if connected_check_fn.(state) do
      :ok
    else
      connection_error(:not_connected)
    end
  end

  @doc """
  Validates connection state using the transport's connected?/1 function.

  This is a convenience function for transports that implement the standard
  connected?/1 callback.
  """
  @spec validate_connection_with_module(any(), module()) ::
          :ok | {:error, {error_type(), any()}}
  def validate_connection_with_module(state, transport_module) do
    validate_connection(state, &transport_module.connected?/1)
  end
end
