defmodule Arbor.MCP.ContentValidationRefactorTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Content.{Sanitizer, SchemaValidator, SecurityScanner, Transformer}
  alias Arbor.MCP.Content.Validation

  describe "SchemaValidator" do
    test "validates required fields for text content" do
      assert :ok = SchemaValidator.validate_required_fields(%{type: :text, text: "hello"})

      assert {:error, [error]} = SchemaValidator.validate_required_fields(%{type: :text})
      assert error.rule == :required_fields
      assert error.message =~ "cannot be empty"
    end

    test "validates content size limits" do
      large_text = String.duplicate("a", 1001)
      content = %{type: :text, text: large_text}

      assert {:error, [error]} = SchemaValidator.validate_max_size(content, 1000)
      assert error.rule == :max_size
      assert error.value == 1001
    end

    test "validates MIME types" do
      content = %{type: :image, mime_type: "image/png"}

      assert :ok = SchemaValidator.validate_mime_types(content, ["image/png", "image/jpeg"])

      assert {:error, [error]} = SchemaValidator.validate_mime_types(content, ["image/jpeg"])
      assert error.rule == :mime_types
    end
  end

  describe "Sanitizer" do
    test "escapes HTML entities" do
      assert "&lt;script&gt;" = Sanitizer.html_escape("<script>")
      assert "&amp;amp;" = Sanitizer.html_escape("&amp;")
    end

    test "strips script tags" do
      html = ~s[<p>Hello <script>alert('xss')</script>world</p>]
      assert ~s[<p>Hello world</p>] = Sanitizer.strip_scripts(html)
    end

    test "sanitizes content with multiple operations" do
      content = %{type: :text, text: "<script>alert('xss')</script>"}

      result = Sanitizer.sanitize(content, [:strip_scripts, :html_escape])
      assert result.text == ""
    end

    test "normalizes Unicode to NFC" do
      # é as e + combining accent (NFD) should become precomposed é (NFC)
      nfd = "e" <> <<0xCC, 0x81>>
      nfc = Sanitizer.normalize_unicode(nfd)
      assert String.valid?(nfc)
      assert nfc == :unicode.characters_to_nfc_binary(nfd)
    end

    test "sanitizes file paths" do
      assert "home/user/file.txt" = Sanitizer.sanitize_path("../../../home/user/file.txt")
      assert "etc/passwd" = Sanitizer.sanitize_path("/etc/passwd")
    end
  end

  describe "SchemaValidator.validate_schema/2" do
    test "accepts content matching the schema" do
      content = %{type: :text, text: "hello"}
      schema = %{"type" => "object", "required" => ["text"]}

      assert :ok = SchemaValidator.validate_schema(content, schema)
    end

    test "rejects content that fails the schema" do
      content = %{type: :text, text: "hello"}
      schema = %{"type" => "object", "required" => ["missing_field"]}

      assert {:error, [%{rule: :json_schema} | _]} =
               SchemaValidator.validate_schema(content, schema)
    end
  end

  describe "Transformer" do
    test "normalizes whitespace" do
      text = "  Hello   \n\n\n  World  \t\t"
      assert "Hello\n\nWorld" = Transformer.normalize_whitespace(text)
    end

    test "transforms content with operations" do
      content = %{type: :text, text: "  HELLO  "}

      {:ok, result} = Transformer.transform(content, [:normalize_whitespace])
      assert result.text == "HELLO"
    end

    test "extracts text from HTML" do
      html_content = %{type: :html, text: "<p>Hello <b>world</b></p>"}

      {:ok, text} = Transformer.extract_text(html_content)
      assert text == "Hello world"
    end
  end

  describe "SecurityScanner" do
    test "detects sensitive data patterns" do
      content = %{type: :text, text: "My SSN is 123-45-6789 and credit card 4111111111111111"}

      threats = SecurityScanner.detect_sensitive_data(content)

      assert Enum.any?(threats, &(&1.type == :sensitive_data_ssn))
      assert Enum.any?(threats, &(&1.type == :sensitive_data_credit_card))
    end

    test "scans for injection attacks" do
      content = %{type: :text, text: "'; DROP TABLE users; --"}

      threats = SecurityScanner.scan_injection_attacks(content)

      assert Enum.any?(threats, &(&1.type == :injection_attack_sql_injection))
    end

    test "calculates overall threat level" do
      safe_content = %{type: :text, text: "Hello world"}
      dangerous_content = %{type: :text, text: "My private key: -----BEGIN RSA PRIVATE KEY-----"}

      {:ok, %{threat_level: :safe}} =
        SecurityScanner.scan_security(safe_content, [:sensitive_data])

      {:ok, %{threat_level: :critical}} =
        SecurityScanner.scan_security(dangerous_content, [:sensitive_data])
    end
  end

  describe "Validation backward compatibility" do
    test "validate function works with rules list" do
      content = %{type: :text, text: "Hello"}

      assert :ok = Validation.validate(content, [:required_fields, {:max_size, 1000}])

      assert {:error, errors} = Validation.validate(content, [{:max_size, 3}])
      assert length(errors) == 1
    end

    test "batch validation works" do
      contents = [
        %{type: :text, text: "Hello"},
        %{type: :text, text: ""},
        %{type: :text, text: "World"}
      ]

      # validate_batch returns {:error, results_list} where each element is :ok or {:error, ...}
      assert {:error, results} = Validation.validate_batch(contents, [:required_fields])
      assert is_list(results)
      assert Enum.at(results, 1) != :ok
    end

    test "delegated functions work correctly" do
      content = %{type: :text, text: "<script>alert('xss')</script>safe"}

      # Sanitizer strips script blocks
      sanitized = Validation.sanitize(content, [:strip_scripts])
      assert sanitized.text == "safe"

      # SecurityScanner returns :safe or {:threat, threats}
      assert :safe = Validation.scan_security(%{type: :text, text: "Hello"}, [:xss])
    end

    test "custom validators can be registered" do
      :ok =
        Validation.register_validator(:always_fail_test, fn _content ->
          {:error, %{rule: :always_fail_test, message: "Always fails", severity: :error}}
        end)

      content = %{type: :text, text: "Hello"}
      assert {:error, [error]} = Validation.validate(content, [:always_fail_test])
      assert error.message == "Always fails"
    end
  end
end
