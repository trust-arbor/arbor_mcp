# Entries are verified against both MIX_ENV=dev and MIX_ENV=test, because the
# files under test/ are only analyzed in the test environment. Check with
# `mix dialyzer --list-unused-filters` in both before adding or removing one.
[
  # Ignore warnings in test support files that depend on ExUnit
  {"lib/arbor_mcp/testing/assertions.ex"},
  {"lib/arbor_mcp/testing/mock_server.ex"},

  # Ignore testing module type resolution issues
  {"lib/arbor_mcp/testing/mock_server.ex", :no_return},
  {"lib/arbor_mcp/testing/mock_server.ex", :call},
  {"lib/arbor_mcp/testing/assertions.ex", :invalid_contract},

  # Ignore @spec issue in builder.ex - Dialyzer and Credo have conflicting requirements
  {"lib/arbor_mcp/server/tools/builder.ex", :invalid_contract},

  # Ignore pattern match warnings for deprecated batch support
  # Batch support is deprecated but still needed for backward compatibility
  {"lib/arbor_mcp/client/request_handler.ex", :pattern_match},

  # Ignore Transport.Error contract warnings in stdio.ex - these functions are used correctly
  # but Dialyzer expects different return patterns in some call contexts
  {"lib/arbor_mcp/transport/stdio.ex", :call},

  # Ignore unreachable pattern warning in SecurityGuard - this is a defensive pattern
  # for robustness against malformed consent handlers
  {"lib/arbor_mcp/transport/security_guard.ex", :pattern_match_cov},

  # Test environment specific warnings - these files are only analyzed when MIX_ENV=test

  # Test support callback type mismatches - these are intentional for testing edge cases
  {"test/support/consent_handler/test.ex", :callback_type_mismatch},

  # Compliance generators and feature modules - generated tests / intentional edge cases
  {"test/arbor_mcp/compliance/version_generator.ex", :no_return},

  # Compliance test feature files - generated test functions and intentional mismatches
  {"test/arbor_mcp/compliance/features/batch.ex", :no_return},
  {"test/arbor_mcp/compliance/features/batch.ex", :call},
  {"test/arbor_mcp/compliance/features/completion.ex", :no_return},
  {"test/arbor_mcp/compliance/features/completion.ex", :call},
  {"test/arbor_mcp/compliance/features/cancellation.ex", :guard_fail},
  {"test/arbor_mcp/compliance/features/roots.ex", :guard_fail},
  {"test/arbor_mcp/compliance/features/transport.ex", :pattern_match},

  # Compliance handler files with intentional callback mismatches for testing different protocol versions
  {"test/arbor_mcp/compliance/handlers/handler20241105.ex", :callback_type_mismatch},
  {"test/arbor_mcp/compliance/handlers/handler20250326.ex", :callback_type_mismatch},
  {"test/arbor_mcp/compliance/handlers/handler20250618.ex", :callback_type_mismatch},

  # JWT/OAuth authorization modules - Dialyzer doesn't track rescue clause types correctly,
  # causing false positives for pattern_match and unused_fun in with-chains
  {"lib/arbor_mcp/authorization/oauth_flow.ex", :pattern_match},
  {"lib/arbor_mcp/authorization/oauth_flow.ex", :unused_fun},

  # Codex adapter - defensive check for input format (content is always binary from
  # extract_prompt_text, but the guard is kept for robustness)
  {"lib/arbor_mcp/acp/adapters/codex.ex", :pattern_match},

  # Token manager refresh_with_jwt_auth - Dialyzer infers ClientAssertion.build_assertion_params
  # always returns error based on the specific keyword args passed, but the function can succeed
  # when valid private_key is provided at runtime
  {"lib/arbor_mcp/authorization/token_manager.ex", :pattern_match},

  # FullOAuthFlow client_credentials JWT - same issue: Dialyzer infers
  # build_assertion_params always returns error for specific keyword args
  {"lib/arbor_mcp/authorization/full_oauth_flow.ex", :pattern_match}
]
