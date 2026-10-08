defmodule Arbor.MCP.Authorization.JWTBearerAssertionTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.JWTBearerAssertion

  describe "grant/1" do
    test "rejects non-HTTPS endpoint" do
      assert {:error, :https_required} =
               JWTBearerAssertion.grant(
                 token_endpoint: "http://insecure.example.com/token",
                 assertion: "eyJ..."
               )
    end

    test "allows localhost HTTP for development" do
      result =
        JWTBearerAssertion.grant(
          token_endpoint: "http://localhost:19876/token",
          assertion: "eyJ..."
        )

      # Should fail with connection/HTTP error, not validation error
      assert {:error, reason} = result
      refute reason == :https_required
    end
  end

  describe "grant_type/0" do
    test "returns correct value" do
      assert JWTBearerAssertion.grant_type() ==
               "urn:ietf:params:oauth:grant-type:jwt-bearer"
    end
  end
end
