defmodule Arbor.MCP.Protocol.APIRetirementTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Content.{Builders, Sanitizer, Transformer}
  alias Arbor.MCP.Protocol.{ErrorCodes, VersionNegotiator}

  test "the first fifteen accepted callable retirements are absent from compiled modules" do
    removed = [
      {Builders, :compress, 1},
      {Builders, :compress, 2},
      {Builders, :resize, 3},
      {Sanitizer, :remove_metadata, 1},
      {Transformer, :compress_image, 2},
      {Transformer, :compress_image, 3},
      {Transformer, :convert_encoding, 1},
      {Transformer, :convert_encoding, 2},
      {Transformer, :generate_thumbnail, 2},
      {Transformer, :generate_thumbnail, 3},
      {Transformer, :resize_image, 3},
      {ErrorCodes, :legacy_consent_required, 0},
      {ErrorCodes, :resource_not_found, 0},
      {ErrorCodes, :url_elicitation_required, 0},
      {VersionNegotiator, :build_capabilities, 1}
    ]

    for {module, name, arity} <- removed do
      assert Code.ensure_loaded?(module)
      refute function_exported?(module, name, arity), "retired #{module}.#{name}/#{arity} remains"
    end

    assert function_exported?(Builders, :image, 3)
    assert function_exported?(Sanitizer, :sanitize, 2)
    assert function_exported?(Transformer, :convert_format, 2)
    assert function_exported?(VersionNegotiator, :negotiate, 1)
  end

  test "explicit protocol era preserves legacy wire codes and modern emission rules" do
    assert ErrorCodes.resource_not_found(:legacy) == -32002
    assert ErrorCodes.resource_not_found("2025-11-25") == -32002
    assert ErrorCodes.resource_not_found(:modern) == -32602
    assert ErrorCodes.resource_not_found("2026-07-28") == -32602
    assert ErrorCodes.resource_not_found_code?(-32002, :legacy)
    refute ErrorCodes.resource_not_found_code?(-32002, :modern)
    assert ErrorCodes.error_message(-32002) == "Resource not found"
    assert ErrorCodes.consent_required() == -31002
    assert ErrorCodes.url_elicitation_required(:legacy) == -32042
    assert ErrorCodes.url_elicitation_required("2025-11-25") == -32042
    assert ErrorCodes.url_elicitation_required(:modern) == {:error, :retired_error_code}
    assert ErrorCodes.url_elicitation_required("2026-07-28") == {:error, :retired_error_code}
  end
end
