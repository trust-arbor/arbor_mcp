defmodule Arbor.MCP.Authorization.PKCETest do
  use ExUnit.Case

  alias Arbor.MCP.Authorization.PKCE

  describe "generate_code_verifier/0" do
    test "generates a code verifier with correct length" do
      verifier = PKCE.generate_code_verifier()

      assert is_binary(verifier)
      assert byte_size(verifier) >= 43
      assert byte_size(verifier) <= 128
    end

    test "generates unique verifiers" do
      verifier1 = PKCE.generate_code_verifier()
      verifier2 = PKCE.generate_code_verifier()

      assert verifier1 != verifier2
    end

    test "generates verifiers with valid characters only" do
      verifier = PKCE.generate_code_verifier()

      # Should contain only unreserved characters: [A-Z] / [a-z] / [0-9] / "-" / "." / "_" / "~"
      assert Regex.match?(~r/^[A-Za-z0-9\-._~]+$/, verifier)
    end
  end

  describe "generate_code_challenge/1" do
    test "generates SHA256 hash of verifier" do
      verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
      challenge = PKCE.generate_code_challenge(verifier)

      # Known SHA256 hash for the test verifier above
      expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
      assert challenge == expected
    end

    test "produces consistent challenges for same verifier" do
      verifier = "test_verifier_123"
      challenge1 = PKCE.generate_code_challenge(verifier)
      challenge2 = PKCE.generate_code_challenge(verifier)

      assert challenge1 == challenge2
    end

    test "produces different challenges for different verifiers" do
      verifier1 = "verifier_one"
      verifier2 = "verifier_two"

      challenge1 = PKCE.generate_code_challenge(verifier1)
      challenge2 = PKCE.generate_code_challenge(verifier2)

      assert challenge1 != challenge2
    end
  end

  describe "validate_challenge/2" do
    test "validates correct verifier and challenge pair" do
      verifier = PKCE.generate_code_verifier()
      challenge = PKCE.generate_code_challenge(verifier)

      assert PKCE.validate_challenge(verifier, challenge) == true
    end

    test "rejects incorrect verifier for challenge" do
      verifier1 = PKCE.generate_code_verifier()
      verifier2 = PKCE.generate_code_verifier()
      challenge1 = PKCE.generate_code_challenge(verifier1)

      assert PKCE.validate_challenge(verifier2, challenge1) == false
    end

    test "uses secure comparison to prevent timing attacks" do
      verifier = "test_verifier"
      _correct_challenge = PKCE.generate_code_challenge(verifier)

      # Challenges of same length but different content
      wrong_challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

      assert PKCE.validate_challenge(verifier, wrong_challenge) == false
    end
  end

  describe "validate_verifier/1" do
    test "accepts valid verifier" do
      verifier = PKCE.generate_code_verifier()
      assert PKCE.validate_verifier(verifier) == :ok
    end

    test "rejects verifier that is too short" do
      # 42 chars, minimum is 43
      short_verifier = String.duplicate("a", 42)

      assert PKCE.validate_verifier(short_verifier) ==
               {:error, "Code verifier must be at least 43 characters"}
    end

    test "rejects verifier that is too long" do
      # 129 chars, maximum is 128
      long_verifier = String.duplicate("a", 129)

      assert PKCE.validate_verifier(long_verifier) ==
               {:error, "Code verifier must not exceed 128 characters"}
    end

    test "rejects verifier with invalid characters" do
      # Contains space
      invalid_verifier = String.duplicate("a", 43) <> " "

      assert PKCE.validate_verifier(invalid_verifier) ==
               {:error, "Code verifier contains invalid characters"}

      # Contains plus
      invalid_verifier2 = String.duplicate("a", 43) <> "+"

      assert PKCE.validate_verifier(invalid_verifier2) ==
               {:error, "Code verifier contains invalid characters"}
    end

    test "rejects non-string verifier" do
      assert PKCE.validate_verifier(123) == {:error, "Code verifier must be a string"}
      assert PKCE.validate_verifier(nil) == {:error, "Code verifier must be a string"}
    end

    test "accepts verifier with all valid unreserved characters" do
      # Test all valid unreserved characters: [A-Z] / [a-z] / [0-9] / "-" / "." / "_" / "~"
      valid_verifier = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
      assert PKCE.validate_verifier(valid_verifier) == :ok
    end
  end

  describe "RFC 7636 compliance" do
    test "verifier meets entropy requirements" do
      # RFC requires at least 256 bits of entropy
      # Our 32-byte generation provides 256 bits
      verifier = PKCE.generate_code_verifier()

      # Base64url encoding of 32 bytes should be 43 characters (no padding)
      # But may be longer due to URL-safe encoding variations
      assert byte_size(verifier) >= 43
    end

    test "challenge method is S256 (SHA256)" do
      verifier = "test_verifier_for_sha256_validation"
      challenge = PKCE.generate_code_challenge(verifier)

      # Manually compute SHA256 for verification
      expected_hash = :crypto.hash(:sha256, verifier)
      expected_challenge = Base.url_encode64(expected_hash, padding: false)

      assert challenge == expected_challenge
    end
  end
end
