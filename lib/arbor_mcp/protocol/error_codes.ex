defmodule Arbor.MCP.Protocol.ErrorCodes do
  @moduledoc """
  JSON-RPC 2.0 and MCP-specific error codes.

  This module provides constants and helper functions for working with
  error codes in the MCP protocol. All error codes follow the JSON-RPC 2.0
  specification with MCP-specific extensions.

  ## Standard JSON-RPC 2.0 Error Codes

  - `-32700` - Parse error: Invalid JSON was received
  - `-32600` - Invalid Request: The JSON sent is not a valid Request object
  - `-32601` - Method not found: The method does not exist or is not available
  - `-32602` - Invalid params: Invalid method parameter(s)
  - `-32603` - Internal error: Internal JSON-RPC error

  ## MCP-Specific Error Codes

  - `-32001` - Request cancelled: The request was cancelled by the client
  - `-32002` - Resource not found on legacy MCP versions
  - `-32003` - Consent denied: User denied consent for the operation
  - `-32020` - Header mismatch
  - `-32021` - Missing required client capability
  - `-32022` - Unsupported protocol version
  - `-32000` - Generic server error: Catch-all for server-side errors

  ## Arbor.MCP-local Error Codes

  - `-31002` - Consent required
  - `-31003` - Prompt processing error

  > #### Compatibility note {: .warning}
  >
  > `-32002` and `-32042` are historical MCP codes. Legacy peers remain
  > decodable, but modern emitters use `-32602` for a missing resource and must
  > not emit `-32042`. Arbor.MCP-local consent and prompt errors live outside the
  > JSON-RPC reserved range so they cannot be confused with peer protocol
  > errors.

  ## Usage

      iex> Arbor.MCP.Protocol.ErrorCodes.invalid_params()
      -32602

      iex> Arbor.MCP.Protocol.ErrorCodes.error_message(:invalid_params)
      "Invalid params"

      iex> Arbor.MCP.Protocol.ErrorCodes.is_protocol_error?(-32602)
      true
  """

  alias Arbor.MCP.Internal.RevisionCatalog

  # Standard JSON-RPC 2.0 error codes
  @parse_error -32700
  @invalid_request -32600
  @method_not_found -32601
  @invalid_params -32602
  @internal_error -32603

  # MCP-specific error codes
  @request_cancelled -32001
  @legacy_resource_not_found -32002
  @consent_denied -32003
  @server_error -32000
  @legacy_url_elicitation_required -32042
  @header_mismatch -32020
  @missing_required_client_capability -32021
  @unsupported_protocol_version -32022

  # Arbor.MCP-local application errors. Keep these outside JSON-RPC's reserved
  # -32768..-32000 range so they cannot be mistaken for peer protocol errors.
  @consent_required -31002
  @prompt_error -31003

  # Server-defined error codes range
  @server_error_start -32099
  @server_error_end -32000

  @doc "Parse error: Invalid JSON was received by the server"
  def parse_error, do: @parse_error

  @doc "Invalid Request: The JSON sent is not a valid Request object"
  def invalid_request, do: @invalid_request

  @doc "Method not found: The method does not exist or is not available"
  def method_not_found, do: @method_not_found

  @doc "Invalid params: Invalid method parameter(s)"
  def invalid_params, do: @invalid_params

  @doc "Internal error: Internal JSON-RPC error"
  def internal_error, do: @internal_error

  @doc "Request cancelled: The request was cancelled by the client"
  def request_cancelled, do: @request_cancelled

  @doc """
  Consent required: User consent is required for the operation.

  This is an Arbor.MCP-local application error, not an MCP protocol error.
  """
  def consent_required, do: @consent_required

  @doc "Consent denied: User denied consent for the operation"
  def consent_denied, do: @consent_denied

  @doc "Generic server error: Catch-all for server-side errors"
  def server_error, do: @server_error

  @doc "Returns the resource-not-found code appropriate for a protocol era or version."
  @spec resource_not_found(:legacy | :modern | String.t()) :: integer()
  def resource_not_found(:legacy), do: @legacy_resource_not_found
  def resource_not_found(:modern), do: @invalid_params

  def resource_not_found(version) when is_binary(version) do
    case RevisionCatalog.era_for(version) do
      :legacy -> @legacy_resource_not_found
      :modern -> @invalid_params
      :unknown -> raise ArgumentError, "unknown MCP protocol version: #{inspect(version)}"
    end
  end

  @doc """
  Returns whether a code represents resource-not-found for the given era.

  `:unknown` accepts both encodings for clients that have not established the
  peer's protocol era yet.
  """
  @spec resource_not_found_code?(integer(), :legacy | :modern | :unknown | String.t()) ::
          boolean()
  def resource_not_found_code?(code, :legacy), do: code == @legacy_resource_not_found
  def resource_not_found_code?(code, :modern), do: code == @invalid_params

  def resource_not_found_code?(code, :unknown),
    do: code in [@legacy_resource_not_found, @invalid_params]

  def resource_not_found_code?(code, version) when is_binary(version) do
    resource_not_found_code?(code, RevisionCatalog.era_for(version))
  end

  @doc "Returns the URL-elicitation code for legacy peers and rejects modern emission."
  @spec url_elicitation_required(:legacy | :modern | String.t()) ::
          integer() | {:error, :retired_error_code}
  def url_elicitation_required(:legacy), do: @legacy_url_elicitation_required
  def url_elicitation_required(:modern), do: {:error, :retired_error_code}

  def url_elicitation_required(version) when is_binary(version) do
    case RevisionCatalog.era_for(version) do
      :legacy -> @legacy_url_elicitation_required
      :modern -> {:error, :retired_error_code}
      :unknown -> raise ArgumentError, "unknown MCP protocol version: #{inspect(version)}"
    end
  end

  @doc "Arbor.MCP-local prompt processing error"
  def prompt_error, do: @prompt_error

  @doc "Header mismatch between negotiated protocol state and the request"
  def header_mismatch, do: @header_mismatch

  @doc "A required client capability was not declared"
  def missing_required_client_capability, do: @missing_required_client_capability

  @doc "The requested protocol version is not supported"
  def unsupported_protocol_version, do: @unsupported_protocol_version

  @doc """
  Returns a human-readable error message for the given error code or atom.

  ## Examples

      iex> Arbor.MCP.Protocol.ErrorCodes.error_message(-32602)
      "Invalid params"

      iex> Arbor.MCP.Protocol.ErrorCodes.error_message(:invalid_params)
      "Invalid params"
  """
  # Map of error codes to messages
  @error_messages %{
    @parse_error => "Parse error",
    @invalid_request => "Invalid Request",
    @method_not_found => "Method not found",
    @invalid_params => "Invalid params",
    @internal_error => "Internal error",
    @request_cancelled => "Request cancelled",
    @legacy_resource_not_found => "Resource not found",
    @consent_denied => "Consent denied",
    @server_error => "Server error",
    @header_mismatch => "Header mismatch",
    @missing_required_client_capability => "Missing required client capability",
    @unsupported_protocol_version => "Unsupported protocol version",
    @legacy_url_elicitation_required => "URL elicitation required",
    @consent_required => "Consent required",
    @prompt_error => "Prompt error"
  }

  @atom_messages %{
    resource_not_found: "Resource not found",
    consent_required: "Consent required",
    prompt_error: "Prompt error",
    url_elicitation_required: "URL elicitation required"
  }

  # Map of atom names to error codes
  @atom_to_code %{
    :parse_error => @parse_error,
    :invalid_request => @invalid_request,
    :method_not_found => @method_not_found,
    :invalid_params => @invalid_params,
    :internal_error => @internal_error,
    :request_cancelled => @request_cancelled,
    :consent_required => @consent_required,
    :consent_denied => @consent_denied,
    :server_error => @server_error,
    :resource_not_found => @legacy_resource_not_found,
    :prompt_error => @prompt_error,
    :header_mismatch => @header_mismatch,
    :missing_required_client_capability => @missing_required_client_capability,
    :unsupported_protocol_version => @unsupported_protocol_version,
    :url_elicitation_required => @legacy_url_elicitation_required
  }

  @spec error_message(integer() | atom()) :: String.t()
  def error_message(code) when is_integer(code) do
    cond do
      Map.has_key?(@error_messages, code) -> @error_messages[code]
      code >= @server_error_start and code <= @server_error_end -> "Server error"
      true -> "Unknown error"
    end
  end

  def error_message(atom) when is_atom(atom) do
    case Map.fetch(@atom_messages, atom) do
      {:ok, message} -> message
      :error -> @atom_to_code |> Map.get(atom) |> error_message_for_atom()
    end
  end

  defp error_message_for_atom(nil), do: "Unknown error"
  defp error_message_for_atom(code), do: error_message(code)

  @doc """
  Checks if the given error code is a standard JSON-RPC protocol error.

  ## Examples

      iex> Arbor.MCP.Protocol.ErrorCodes.is_protocol_error?(-32602)
      true

      iex> Arbor.MCP.Protocol.ErrorCodes.is_protocol_error?(-32001)
      false
  """
  @spec is_protocol_error?(integer()) :: boolean()
  def is_protocol_error?(code) when is_integer(code) do
    code in [@parse_error, @invalid_request, @method_not_found, @invalid_params, @internal_error]
  end

  @doc """
  Checks if the given error code is an MCP-specific error.

  ## Examples

      iex> Arbor.MCP.Protocol.ErrorCodes.is_mcp_error?(-32001)
      true

      iex> Arbor.MCP.Protocol.ErrorCodes.is_mcp_error?(-32602)
      false
  """
  @spec is_mcp_error?(integer()) :: boolean()
  def is_mcp_error?(code) when is_integer(code) do
    code in [
      @request_cancelled,
      @legacy_resource_not_found,
      @consent_denied,
      @header_mismatch,
      @missing_required_client_capability,
      @unsupported_protocol_version,
      @legacy_url_elicitation_required
    ] or
      (code >= @server_error_start and code <= @server_error_end)
  end

  @doc "Checks if the code is an Arbor.MCP-local application error."
  @spec application_error?(integer()) :: boolean()
  def application_error?(code), do: code in [@consent_required, @prompt_error]

  @doc """
  Creates an error response map with the given code and message.

  ## Examples

      iex> Arbor.MCP.Protocol.ErrorCodes.error_response(:invalid_params, "Missing required field: name")
      %{code: -32602, message: "Invalid params: Missing required field: name"}
  """
  @spec error_response(atom() | integer(), String.t() | nil) :: map()
  def error_response(code_or_atom, custom_message \\ nil)

  def error_response(atom, custom_message) when is_atom(atom) do
    code = atom_to_code(atom)
    base_message = error_message(atom)

    message =
      if custom_message do
        "#{base_message}: #{custom_message}"
      else
        base_message
      end

    %{code: code, message: message}
  end

  def error_response(code, custom_message) when is_integer(code) do
    base_message = error_message(code)

    message =
      if custom_message do
        "#{base_message}: #{custom_message}"
      else
        base_message
      end

    %{code: code, message: message}
  end

  @doc "Builds a version-aware error response for era-sensitive MCP errors."
  @spec error_response_for_version(atom(), :legacy | :modern | String.t(), String.t() | nil) ::
          map() | {:error, :retired_error_code}
  def error_response_for_version(atom, version_or_era, custom_message \\ nil) do
    case code_for(atom, version_or_era) do
      {:error, _reason} = error -> error
      code -> error_response_with_base(code, error_message(atom), custom_message)
    end
  end

  @doc "Returns an error code using the negotiated version for era-sensitive errors."
  @spec code_for(atom(), :legacy | :modern | String.t()) ::
          integer() | {:error, :retired_error_code}
  def code_for(:resource_not_found, version_or_era), do: resource_not_found(version_or_era)

  def code_for(:url_elicitation_required, version_or_era),
    do: url_elicitation_required(version_or_era)

  def code_for(atom, _version_or_era), do: atom_to_code(atom)

  defp error_response_with_base(code, base_message, custom_message) do
    message = if custom_message, do: "#{base_message}: #{custom_message}", else: base_message
    %{code: code, message: message}
  end

  # Private helper to convert atom to error code
  defp atom_to_code(atom), do: Map.get(@atom_to_code, atom, @server_error)
end
