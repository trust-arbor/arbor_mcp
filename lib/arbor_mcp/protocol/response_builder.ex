defmodule Arbor.MCP.Protocol.ResponseBuilder do
  @moduledoc """
  Utility module for building JSON-RPC 2.0 responses in MCP.

  This module centralizes all response building logic to ensure consistency
  across the codebase and reduce duplication.
  """

  alias Arbor.MCP.Error
  alias Arbor.MCP.Protocol.ErrorCodes
  alias Arbor.RPC.JSONRPC

  @doc """
  Builds a successful JSON-RPC response.

  ## Examples

      iex> ResponseBuilder.build_success_response(%{"tools" => []}, 123)
      %{
        "jsonrpc" => "2.0",
        "id" => 123,
        "result" => %{"tools" => []}
      }
  """
  @spec build_success_response(any(), any()) :: map()
  def build_success_response(result, id) do
    JSONRPC.response(id, result)
  end

  @doc """
  Builds an error JSON-RPC response.

  Accepts either raw parameters or an Arbor.MCP.Error struct.

  ## Examples

      iex> ResponseBuilder.build_error_response(-32601, "Method not found", nil, 123)
      %{
        "jsonrpc" => "2.0",
        "id" => 123,
        "error" => %{
          "code" => -32601,
          "message" => "Method not found"
        }
      }
      
      iex> ResponseBuilder.build_error_response(-32602, "Invalid params", %{"expected" => "string"}, 123)
      %{
        "jsonrpc" => "2.0",
        "id" => 123,
        "error" => %{
          "code" => -32602,
          "message" => "Invalid params",
          "data" => %{"expected" => "string"}
        }
      }
      
      iex> error = %Arbor.MCP.Error.ProtocolError{code: -32601, message: "Method not found"}
      iex> ResponseBuilder.build_error_response(error, 123)
      %{
        "jsonrpc" => "2.0",
        "id" => 123,
        "error" => %{
          "code" => -32601,
          "message" => "Method not found"
        }
      }
  """
  @spec build_error_response(integer() | struct(), String.t() | any(), any(), any()) :: map()
  def build_error_response(%mod{} = error, id)
      when mod in [
             Error,
             Error.ProtocolError,
             Error.TransportError,
             Error.ToolError,
             Error.ResourceError,
             Error.ValidationError
           ] do
    JSONRPC.error(id, Error.to_json_rpc(error))
  end

  def build_error_response(code, message, data \\ nil, id) do
    error = %{
      "code" => code,
      "message" => message
    }

    error = if data, do: Map.put(error, "data", data), else: error

    JSONRPC.error(id, error)
  end

  @doc """
  Builds a JSON-RPC notification (no id field).

  ## Examples

      iex> ResponseBuilder.build_notification("resources/list_changed", %{})
      %{
        "jsonrpc" => "2.0",
        "method" => "resources/list_changed",
        "params" => %{}
      }
  """
  @spec build_notification(String.t(), map()) :: map()
  def build_notification(method, params) do
    JSONRPC.notification(method, params)
  end

  @doc """
  Builds a JSON-RPC request for legacy or compatibility paths.

  Independent server-to-client requests belong to initialize-based MCP
  revisions. A modern MCP 2026-07-28 server should return an `input_required`
  MRTR result when it needs client input.

  ## Examples

      iex> ResponseBuilder.build_request("tools/call", %{"name" => "test"}, "req-123")
      %{
        "jsonrpc" => "2.0",
        "id" => "req-123",
        "method" => "tools/call",
        "params" => %{"name" => "test"}
      }
  """
  @spec build_request(String.t(), map(), any()) :: map()
  def build_request(method, params, id) do
    JSONRPC.request(method, params, id)
  end

  @doc """
  Builds a standard MCP error response using error code atoms.

  ## Examples

      iex> ResponseBuilder.build_mcp_error(:method_not_found, 123)
      %{
        "jsonrpc" => "2.0",
        "id" => 123,
        "error" => %{
          "code" => -32601,
          "message" => "Method not found"
        }
      }
      
      iex> ResponseBuilder.build_mcp_error(:invalid_params, 123, "Missing required field")
      %{
        "jsonrpc" => "2.0",
        "id" => 123,
        "error" => %{
          "code" => -32602,
          "message" => "Missing required field"
        }
      }
  """
  @spec build_mcp_error(atom(), any(), String.t() | nil, any()) :: map()
  def build_mcp_error(error_atom, id, custom_message \\ nil, data \\ nil) do
    # Use ErrorCodes.error_response to get the code and message
    %{code: code, message: base_message} = ErrorCodes.error_response(error_atom)
    message = custom_message || base_message

    build_error_response(code, message, data, id)
  end

  @doc """
  Builds a tool error response with proper MCP structure.

  ## Examples

      iex> ResponseBuilder.build_tool_error("Tool execution failed", true, 123)
      %{
        "jsonrpc" => "2.0",
        "id" => 123,
        "result" => %{
          "content" => [
            %{
              "type" => "text",
              "text" => "Tool execution failed"
            }
          ],
          "isError" => true
        }
      }
  """
  @spec build_tool_error(String.t(), boolean(), any()) :: map()
  def build_tool_error(error_text, is_error \\ true, id) do
    result = %{
      "content" => [
        %{
          "type" => "text",
          "text" => error_text
        }
      ],
      "isError" => is_error
    }

    build_success_response(result, id)
  end

  @doc """
  Builds a batch response error (when batch requests are not supported).

  ## Examples

      iex> ResponseBuilder.build_batch_error("2025-06-18")
      %{
        "jsonrpc" => "2.0",
        "id" => nil,
        "error" => %{
          "code" => -32600,
          "message" => "Batch requests are not supported in protocol version 2025-06-18"
        }
      }
  """
  @spec build_batch_error(String.t()) :: map()
  def build_batch_error(protocol_version \\ "2025-06-18") do
    message =
      if protocol_version == "2025-06-18" do
        "Batch requests are not supported in protocol version 2025-06-18"
      else
        "Batch requests are not supported"
      end

    build_error_response(ErrorCodes.invalid_request(), message, nil, nil)
  end

  @doc """
  Checks if a response is an error response.

  ## Examples

      iex> ResponseBuilder.error_response?(%{"error" => %{"code" => -32601}})
      true
      
      iex> ResponseBuilder.error_response?(%{"result" => %{}})
      false
  """
  @spec error_response?(map()) :: boolean()
  def error_response?(response) do
    Map.has_key?(response, "error")
  end

  @doc """
  Checks if a response is a notification (has no id).

  ## Examples

      iex> ResponseBuilder.notification?(%{"jsonrpc" => "2.0", "method" => "test"})
      true
      
      iex> ResponseBuilder.notification?(%{"jsonrpc" => "2.0", "id" => 1, "method" => "test"})
      false
  """
  @spec notification?(map()) :: boolean()
  def notification?(message) do
    Map.has_key?(message, "method") && not Map.has_key?(message, "id")
  end
end
