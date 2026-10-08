defmodule Arbor.MCP.Protocol.ErrorCodeCharacterizationTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Protocol.ErrorCodes
  alias Arbor.MCP.Transport.SecurityError

  test "public error constructors use their assigned protocol or application ranges" do
    error_codes = %{
      parse_error: ErrorCodes.parse_error(),
      invalid_request: ErrorCodes.invalid_request(),
      method_not_found: ErrorCodes.method_not_found(),
      invalid_params: ErrorCodes.invalid_params(),
      internal_error: ErrorCodes.internal_error(),
      request_cancelled: ErrorCodes.request_cancelled(),
      consent_required: ErrorCodes.consent_required(),
      consent_denied: ErrorCodes.consent_denied(),
      server_error: ErrorCodes.server_error(),
      resource_not_found: ErrorCodes.resource_not_found(:legacy),
      url_elicitation_required: ErrorCodes.url_elicitation_required(:legacy)
    }

    errors = %{
      parse_error: Arbor.MCP.Error.parse_error().code,
      invalid_request: Arbor.MCP.Error.invalid_request("details").code,
      method_not_found: Arbor.MCP.Error.method_not_found("method").code,
      invalid_params: Arbor.MCP.Error.invalid_params("details").code,
      internal_error: Arbor.MCP.Error.internal_error("details").code,
      prompt_error: Arbor.MCP.Error.prompt_error("details", "prompt").code
    }

    security_errors =
      Map.new(
        [
          :token_passthrough_blocked,
          :consent_required,
          :consent_denied,
          :consent_error,
          :security_violation,
          :unknown
        ],
        fn type ->
          error = SecurityError.new(type, "message")
          {type, SecurityError.format_for_transport(error, :stdio).code}
        end
      )

    assert error_codes == %{
             parse_error: -32700,
             invalid_request: -32600,
             method_not_found: -32601,
             invalid_params: -32602,
             internal_error: -32603,
             request_cancelled: -32001,
             consent_required: -31002,
             consent_denied: -32003,
             server_error: -32000,
             resource_not_found: -32002,
             url_elicitation_required: -32042
           }

    assert errors == %{
             parse_error: -32700,
             invalid_request: -32600,
             method_not_found: -32601,
             invalid_params: -32602,
             internal_error: -32603,
             prompt_error: -31003
           }

    assert security_errors == %{
             token_passthrough_blocked: -32001,
             consent_required: -31002,
             consent_denied: -32003,
             consent_error: -32004,
             security_violation: -32000,
             unknown: -32603
           }
  end

  test "resource-not-found emission and decoding are era-aware" do
    assert ErrorCodes.error_message(:resource_not_found) == "Resource not found"
    assert ErrorCodes.resource_not_found(:legacy) == -32002
    assert ErrorCodes.resource_not_found("2025-11-25") == -32002
    assert ErrorCodes.resource_not_found(:modern) == -32602
    assert ErrorCodes.resource_not_found("2026-07-28") == -32602

    assert ErrorCodes.resource_not_found_code?(-32002, :legacy)
    assert ErrorCodes.resource_not_found_code?(-32602, :modern)
    assert ErrorCodes.resource_not_found_code?(-32002, :unknown)
    assert ErrorCodes.resource_not_found_code?(-32602, :unknown)

    refute ErrorCodes.resource_not_found_code?(-32002, :modern)
    refute ErrorCodes.resource_not_found_code?(-32602, :legacy)
  end

  test "local errors no longer collide with historical MCP codes" do
    assert ErrorCodes.consent_required() == -31002
    assert ErrorCodes.prompt_error() == -31003
    assert ErrorCodes.application_error?(-31002)
    assert ErrorCodes.application_error?(-31003)
    refute ErrorCodes.is_mcp_error?(-31002)

    assert Arbor.MCP.Error.category(Arbor.MCP.Error.prompt_error("details", "prompt")) ==
             "Prompt Error"
  end

  test "modern protocol codes are additive and retired codes cannot be selected" do
    assert ErrorCodes.header_mismatch() == -32020
    assert ErrorCodes.missing_required_client_capability() == -32021
    assert ErrorCodes.unsupported_protocol_version() == -32022

    assert ErrorCodes.url_elicitation_required(:modern) == {:error, :retired_error_code}

    assert ErrorCodes.error_response_for_version(
             :url_elicitation_required,
             "2026-07-28"
           ) == {:error, :retired_error_code}

    assert ErrorCodes.error_response_for_version(
             :resource_not_found,
             "2026-07-28",
             "file:///missing"
           ) == %{code: -32602, message: "Resource not found: file:///missing"}
  end
end
