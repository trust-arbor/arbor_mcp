defmodule Arbor.MCP.Security.ValidationTest do
  @moduledoc """
  Tests for `Arbor.MCP.Security.Validation`, focusing on the two places where a
  weak configuration used to pass silently: non-binary bind addresses and
  `verify: :verify_none`.
  """
  # async: false — these assertions inspect captured log output, which is
  # VM-global while the capture is active.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.MCP.Security.Validation

  doctest Arbor.MCP.Security.Validation, only: [validate_localhost_binding: 1]

  describe "validate_localhost_binding/1 with binary bindings" do
    test "accepts loopback names" do
      for binding <- ["127.0.0.1", "localhost", "::1", "[::1]", "0:0:0:0:0:0:0:1"] do
        assert :ok = Validation.validate_localhost_binding(%{binding: binding})
      end
    end

    test "rejects public bindings" do
      for binding <- ["0.0.0.0", "192.168.1.10", "::", "example.com"] do
        assert {:error, :public_binding_requires_security} =
                 Validation.validate_localhost_binding(%{binding: binding})
      end
    end
  end

  describe "validate_localhost_binding/1 with non-binary bindings" do
    test "accepts loopback address tuples" do
      assert :ok = Validation.validate_localhost_binding(%{binding: {127, 0, 0, 1}})
      assert :ok = Validation.validate_localhost_binding(%{binding: {127, 0, 0, 53}})
      assert :ok = Validation.validate_localhost_binding(%{binding: {0, 0, 0, 0, 0, 0, 0, 1}})
    end

    test "rejects wildcard address tuples" do
      # {0, 0, 0, 0} binds every interface exactly like "0.0.0.0" does, and
      # used to slip through the binary-only clause.
      assert {:error, :public_binding_requires_security} =
               Validation.validate_localhost_binding(%{binding: {0, 0, 0, 0}})

      assert {:error, :public_binding_requires_security} =
               Validation.validate_localhost_binding(%{binding: {0, 0, 0, 0, 0, 0, 0, 0}})

      assert {:error, :public_binding_requires_security} =
               Validation.validate_localhost_binding(%{binding: {192, 168, 1, 10}})
    end

    test "accepts the :loopback atom" do
      assert :ok = Validation.validate_localhost_binding(%{binding: :loopback})
    end

    test "handles charlist bindings" do
      assert :ok = Validation.validate_localhost_binding(%{binding: ~c"127.0.0.1"})

      assert {:error, :public_binding_requires_security} =
               Validation.validate_localhost_binding(%{binding: ~c"0.0.0.0"})
    end

    test "rejects unrecognised binding shapes rather than ignoring them" do
      for binding <- [:any, nil, 8080, %{}] do
        assert {:error, :public_binding_requires_security} =
                 Validation.validate_localhost_binding(%{binding: binding})
      end
    end

    test "a config without a :binding key is not a binding decision" do
      assert :ok = Validation.validate_localhost_binding(%{})
      assert :ok = Validation.validate_localhost_binding(%{validate_origin: true})
    end
  end

  describe "validate_tls_config/1" do
    test "accepts verify_peer without logging" do
      log =
        capture_log(fn ->
          assert :ok = Validation.validate_tls_config(%{verify: :verify_peer})
        end)

      refute log =~ "verify_none"
    end

    test "accepts verify_none but warns loudly" do
      log =
        capture_log(fn ->
          assert :ok = Validation.validate_tls_config(%{verify: :verify_none})
        end)

      assert log =~ "verify: :verify_none"
      assert log =~ "man-in-the-middle"
    end

    test "still rejects weak ciphers and obsolete TLS versions" do
      assert {:error, :insecure_tls_versions} =
               Validation.validate_tls_config(%{versions: [:"tlsv1.0", :"tlsv1.2"]})

      assert {:error, :weak_cipher_suites} =
               Validation.validate_tls_config(%{ciphers: ["RC4-SHA"]})
    end

    test "rejects an unknown verify mode" do
      assert {:error, :invalid_verify_mode} = Validation.validate_tls_config(%{verify: :maybe})
    end
  end
end
