defmodule Arbor.MCP.Error do
  @moduledoc """
  Error types and utilities for ArborMCP.

  This module provides structured error handling with proper error types
  that can be pattern matched and provide useful debugging information.
  """

  defstruct [:code, :message, :data, :request_id, __exception__: true]

  alias Arbor.MCP.Protocol.ErrorCodes

  @prompt_error_code ErrorCodes.prompt_error()

  @type t :: %__MODULE__{
          code: integer(),
          message: String.t(),
          data: any(),
          request_id: String.t() | nil,
          __exception__: true
        }

  # Implement the Exception behaviour for Error struct
  def exception(value) when is_map(value), do: struct(__MODULE__, value)
  def exception(msg) when is_binary(msg), do: %__MODULE__{message: msg, __exception__: true}
  def message(%__MODULE__{message: message}), do: message || ""

  defmodule ProtocolError do
    @moduledoc """
    Errors related to MCP protocol violations.
    """
    defexception [:code, :message, :data]

    @type t :: %__MODULE__{
            code: integer(),
            message: String.t(),
            data: any()
          }

    @impl true
    def message(%{code: code, message: message}) do
      "MCP Protocol Error (#{code}): #{message}"
    end
  end

  defmodule TransportError do
    @moduledoc """
    Errors related to transport layer issues.
    """
    defexception [:transport, :reason, :details]

    @type t :: %__MODULE__{
            transport: atom() | nil,
            reason: term(),
            details: term()
          }

    @impl true
    def message(%{transport: transport, reason: reason}) do
      "Transport Error (#{transport}): #{inspect(reason)}"
    end
  end

  defmodule ToolError do
    @moduledoc """
    Errors that occur during tool execution.
    """
    defexception [:tool_name, :reason, :arguments]

    @impl true
    def message(%{tool_name: tool_name, reason: reason}) do
      "Tool Error (#{tool_name}): #{inspect(reason)}"
    end
  end

  defmodule ResourceError do
    @moduledoc """
    Errors that occur during resource operations.
    """
    defexception [:uri, :operation, :reason]

    @impl true
    def message(%{uri: uri, operation: operation, reason: reason}) do
      "Resource Error (#{operation} #{uri}): #{inspect(reason)}"
    end
  end

  defmodule ValidationError do
    @moduledoc """
    Errors related to input validation.
    """
    defexception [:field, :value, :reason]

    @impl true
    def message(%{field: field, reason: reason}) do
      "Validation Error (#{field}): #{reason}"
    end
  end

  @doc """
  Creates a protocol error exception with the given JSON-RPC error code.

  ## Standard JSON-RPC Error Codes

  * `-32700` - Parse error
  * `-32600` - Invalid Request
  * `-32601` - Method not found
  * `-32602` - Invalid params
  * `-32603` - Internal error
  * `-32000` to `-32099` - Server error
  """
  def protocol_error(code, message, data \\ nil)

  def protocol_error(_code, %ProtocolError{} = error, _data), do: error

  def protocol_error(code, message, data) do
    %ProtocolError{
      code: code,
      message: message,
      data: data
    }
  end

  @doc """
  Creates the MCP 2026-07-28 error returned when a server operation requires
  client capabilities that were not declared on the request.

  Handlers may return this value as their normal error reason; every ArborMCP
  server dispatcher preserves its code and `requiredCapabilities` data.
  """
  @spec missing_required_client_capability(map()) :: ProtocolError.t()
  def missing_required_client_capability(required_capabilities)
      when is_map(required_capabilities) do
    protocol_error(
      ErrorCodes.missing_required_client_capability(),
      "Missing required client capability",
      %{"requiredCapabilities" => required_capabilities}
    )
  end

  @doc """
  Creates a transport error exception.
  """
  # Transport error struct versions for tests (binary details)
  def transport_error(details) when is_binary(details) do
    %__MODULE__{
      code: -32003,
      message: "Transport error: #{details}",
      data: nil,
      request_id: nil,
      __exception__: true
    }
  end

  def transport_error(details, opts) when is_binary(details) and is_list(opts) do
    %__MODULE__{
      code: -32003,
      message: "Transport error: #{details}",
      data: Keyword.get(opts, :data),
      request_id: Keyword.get(opts, :request_id),
      __exception__: true
    }
  end

  # Transport error exception versions (transport/reason pattern)
  def transport_error(transport, reason) do
    %TransportError{
      transport: transport,
      reason: reason,
      details: nil
    }
  end

  def transport_error(transport, reason, details) do
    %TransportError{
      transport: transport,
      reason: reason,
      details: details
    }
  end

  @doc """
  Creates a validation error.
  """
  def validation_error(field, value, reason) do
    %ValidationError{
      field: field,
      value: value,
      reason: reason
    }
  end

  @doc """
  Wraps a function call and converts exceptions to proper error tuples.

  ## Examples

      Arbor.MCP.Error.wrap(fn ->
        do_something_dangerous()
      end)
      # => {:ok, result} or {:error, %Arbor.MCP.Error.SomeError{}}
  """
  def wrap(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    e in [ProtocolError, TransportError, ToolError, ResourceError, ValidationError] ->
      {:error, e}

    e ->
      {:error, %RuntimeError{message: Exception.message(e)}}
  end

  @doc """
  Wraps a function call with a custom error transformer.

  ## Examples

      Arbor.MCP.Error.wrap_with(fn ->
        read_file(path)
      end, fn
        {:error, :enoent} -> Arbor.MCP.Error.resource_error(path, :read, :not_found)
        error -> error
      end)
  """
  def wrap_with(fun, error_transformer)
      when is_function(fun, 0) and is_function(error_transformer, 1) do
    case wrap(fun) do
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, error_transformer.(error)}
    end
  end

  def tool_error(details) when is_binary(details) do
    tool_error_struct(details, nil, [])
  end

  def tool_error(details, tool_name)
      when is_binary(details) and (is_binary(tool_name) or is_nil(tool_name)) do
    tool_error_struct(details, tool_name, [])
  end

  def tool_error(tool_name, reason) when is_atom(tool_name) do
    %ToolError{
      tool_name: tool_name,
      reason: reason,
      arguments: nil
    }
  end

  # Handle case where reason is an exception struct - pass it through directly
  def tool_error(_tool_name, %ProtocolError{} = error), do: error
  def tool_error(_tool_name, %TransportError{} = error), do: error
  def tool_error(_tool_name, %ToolError{} = error), do: error
  def tool_error(_tool_name, %ResourceError{} = error), do: error
  def tool_error(_tool_name, %ValidationError{} = error), do: error

  def tool_error(details, tool_name, opts)
      when is_binary(details) and is_binary(tool_name) and is_list(opts) do
    tool_error_struct(details, tool_name, opts)
  end

  def tool_error(tool_name, reason, arguments) when is_atom(tool_name) or is_binary(tool_name) do
    %ToolError{
      tool_name: tool_name,
      reason: reason,
      arguments: arguments
    }
  end

  def resource_error(details, uri) when is_binary(details) and is_binary(uri) do
    resource_error_struct(details, uri, [])
  end

  def resource_error(_uri, _operation, %ProtocolError{} = error), do: error

  def resource_error(uri, operation, reason) when is_atom(operation) do
    %ResourceError{
      uri: uri,
      operation: operation,
      reason: reason
    }
  end

  def resource_error(details, uri, opts)
      when is_binary(details) and is_binary(uri) and is_list(opts) do
    resource_error_struct(details, uri, opts)
  end

  def authentication_error(details) when is_binary(details) do
    %__MODULE__{
      code: -32004,
      message: "Authentication error: #{details}",
      data: nil,
      request_id: nil,
      __exception__: true
    }
  end

  def authorization_error(details) when is_binary(details) do
    %__MODULE__{
      code: -32005,
      message: "Authorization error: #{details}",
      data: nil,
      request_id: nil,
      __exception__: true
    }
  end

  def connection_error_struct(details) when is_binary(details) do
    %__MODULE__{
      code: :connection_error,
      message: "Connection error: #{details}",
      data: nil,
      request_id: nil,
      __exception__: true
    }
  end

  def connection_error_struct(details, opts) when is_binary(details) and is_list(opts) do
    %__MODULE__{
      code: :connection_error,
      message: "Connection error: #{details}",
      data: Keyword.get(opts, :data),
      request_id: Keyword.get(opts, :request_id),
      __exception__: true
    }
  end

  @doc """
  Creates an error struct from a JSON-RPC error response.
  """
  def from_json_rpc_error(json_error, opts \\ []) do
    %__MODULE__{
      code: Map.get(json_error, "code"),
      message: Map.get(json_error, "message", "Unknown error"),
      data: Map.get(json_error, "data"),
      request_id: Keyword.get(opts, :request_id),
      __exception__: true
    }
  end

  @doc """
  Creates a JSON-RPC parse error.
  """
  def parse_error(details \\ "", opts \\ []) do
    message =
      if details == "" do
        "Parse error"
      else
        "Parse error: #{details}"
      end

    %__MODULE__{
      code: -32700,
      message: message,
      data: Keyword.get(opts, :data),
      request_id: Keyword.get(opts, :request_id),
      __exception__: true
    }
  end

  @doc """
  Creates a JSON-RPC invalid request error.
  """
  def invalid_request(details, opts \\ []) do
    %__MODULE__{
      code: -32600,
      message: "Invalid request: #{details}",
      data: Keyword.get(opts, :data),
      request_id: Keyword.get(opts, :request_id),
      __exception__: true
    }
  end

  @doc """
  Creates a JSON-RPC method not found error.
  """
  def method_not_found(method, opts \\ []) do
    %__MODULE__{
      code: -32601,
      message: "Method not found: #{method}",
      data: Keyword.get(opts, :data),
      request_id: Keyword.get(opts, :request_id),
      __exception__: true
    }
  end

  @doc """
  Creates a JSON-RPC invalid params error.
  """
  def invalid_params(details, opts \\ []) do
    %__MODULE__{
      code: -32602,
      message: "Invalid params: #{details}",
      data: Keyword.get(opts, :data),
      request_id: Keyword.get(opts, :request_id),
      __exception__: true
    }
  end

  @doc """
  Creates a JSON-RPC internal error.
  """
  def internal_error(details, opts \\ []) do
    %ProtocolError{
      code: -32603,
      message: "Internal error: #{details}",
      data: Keyword.get(opts, :data)
    }
  end

  @doc """
  Creates an MCP prompt error.
  """
  def prompt_error(details, prompt_name, opts \\ []) do
    data =
      case Keyword.get(opts, :data) do
        nil -> %{prompt_name: prompt_name}
        custom_data -> custom_data
      end

    %__MODULE__{
      code: @prompt_error_code,
      message: "Prompt error in '#{prompt_name}': #{details}",
      data: data,
      request_id: Keyword.get(opts, :request_id),
      __exception__: true
    }
  end

  @doc """
  Creates a connection error.
  """
  def connection_error(details), do: connection_error(details, [])

  def connection_error(details, opts) when is_list(opts) do
    %__MODULE__{
      code: :connection_error,
      message: "Connection error: #{details}",
      data: Keyword.get(opts, :data),
      request_id: Keyword.get(opts, :request_id),
      __exception__: true
    }
  end

  defp tool_error_struct(details, tool_name, opts) do
    message =
      if tool_name do
        "Tool error in '#{tool_name}': #{details}"
      else
        "Tool error: #{details}"
      end

    data =
      case Keyword.get(opts, :data) do
        nil when tool_name != nil -> %{tool_name: tool_name}
        nil -> nil
        custom_data -> custom_data
      end

    %__MODULE__{
      code: -32000,
      message: message,
      data: data,
      request_id: Keyword.get(opts, :request_id),
      __exception__: true
    }
  end

  defp resource_error_struct(details, uri, opts) do
    data =
      case Keyword.get(opts, :data) do
        nil -> %{resource_uri: uri}
        custom_data -> custom_data
      end

    %__MODULE__{
      code: -32001,
      message: "Resource error for '#{uri}': #{details}",
      data: data,
      request_id: Keyword.get(opts, :request_id),
      __exception__: true
    }
  end

  # Classification functions for Error structs
  def json_rpc_error?(%__MODULE__{code: code}) when is_integer(code), do: true
  def json_rpc_error?(_), do: false

  def mcp_error?(%__MODULE__{code: code}) when code in [-32000, -32001, -32002], do: true
  def mcp_error?(_), do: false

  def application_error?(%__MODULE__{code: code}), do: ErrorCodes.application_error?(code)
  def application_error?(_), do: false

  def category(%__MODULE__{code: -32700}), do: "Parse Error"
  def category(%__MODULE__{code: -32600}), do: "Invalid Request"
  def category(%__MODULE__{code: -32601}), do: "Method Not Found"
  def category(%__MODULE__{code: -32602}), do: "Invalid Params"
  def category(%__MODULE__{code: -32603}), do: "Internal Error"
  def category(%__MODULE__{code: -32000}), do: "Tool Error"
  def category(%__MODULE__{code: -32001}), do: "Resource Error"
  def category(%__MODULE__{code: @prompt_error_code}), do: "Prompt Error"
  def category(%__MODULE__{code: -32002}), do: "Legacy Resource Not Found"
  def category(%__MODULE__{code: -32003}), do: "Transport Error"
  def category(%__MODULE__{code: -32004}), do: "Authentication Error"
  def category(%__MODULE__{code: -32005}), do: "Authorization Error"
  def category(%__MODULE__{code: :connection_error}), do: "Connection Error"
  def category(_), do: "Unknown Error"

  # Convert errors to JSON-RPC format
  def to_json_rpc(%__MODULE__{code: -32000, message: _message, data: data}) do
    # Tool error - use standard message for consistency
    result = %{
      "code" => -32000,
      "message" => "Tool execution error"
    }

    if data do
      Map.put(result, "data", data)
    else
      result
    end
  end

  def to_json_rpc(%__MODULE__{code: :connection_error, message: message, data: data}) do
    result = %{
      "code" => -32003,
      "message" => message
    }

    if data do
      Map.put(result, "data", data)
    else
      result
    end
  end

  def to_json_rpc(%__MODULE__{code: code, message: message, data: data}) when is_integer(code) do
    result = %{
      "code" => code,
      "message" => message
    }

    if data do
      Map.put(result, "data", data)
    else
      result
    end
  end

  def to_json_rpc(%ProtocolError{code: code, message: message, data: data}) do
    error = %{
      "code" => code,
      "message" => message
    }

    if data do
      Map.put(error, "data", data)
    else
      error
    end
  end

  def to_json_rpc(%TransportError{} = error) do
    %{
      "code" => -32000,
      "message" => "Transport error",
      "data" => %{
        "transport" => error.transport,
        "reason" => inspect(error.reason),
        "details" => error.details
      }
    }
  end

  def to_json_rpc(%ToolError{} = error) do
    reason_str =
      case error.reason do
        r when is_binary(r) -> r
        r -> inspect(r)
      end

    %{
      "code" => -32000,
      "message" => reason_str,
      "data" => %{
        "tool" => error.tool_name,
        "reason" => reason_str
      }
    }
  end

  def to_json_rpc(%ResourceError{} = error) do
    reason_str =
      case error.reason do
        r when is_binary(r) -> r
        r -> inspect(r)
      end

    %{
      "code" => -32000,
      "message" => reason_str,
      "data" => %{
        "uri" => error.uri,
        "operation" => to_string(error.operation),
        "reason" => reason_str
      }
    }
  end

  def to_json_rpc(%ValidationError{} = error) do
    %{
      "code" => -32000,
      "message" => "Tool execution error",
      "data" => %{
        "tool" => error.field,
        "reason" => inspect(error.reason)
      }
    }
  end

  def to_json_rpc(error) do
    %{
      "code" => -32603,
      "message" => "Internal error",
      "data" => inspect(error)
    }
  end
end
