defmodule Arbor.MCP.Plugs.ProtocolVersionTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Arbor.MCP.Internal.VersionRegistry
  alias Arbor.MCP.Plugs.ProtocolVersion

  setup do
    # Store original config
    original_config = Application.get_env(:arbor_mcp, :protocol_version_required)

    on_exit(fn ->
      # Restore original config
      if original_config == nil do
        Application.delete_env(:arbor_mcp, :protocol_version_required)
      else
        Application.put_env(:arbor_mcp, :protocol_version_required, original_config)
      end
    end)

    :ok
  end

  describe "with feature flag disabled" do
    setup do
      Application.put_env(:arbor_mcp, :protocol_version_required, false)
      :ok
    end

    test "sets default version without validation" do
      conn =
        conn(:post, "/mcp")
        |> ProtocolVersion.call([])

      assert conn.assigns[:mcp_version] == "2025-11-25"
      refute conn.halted
    end

    test "rejects an explicit invalid header when missing-header enforcement is disabled" do
      conn =
        conn(:post, "/mcp")
        |> put_req_header("mcp-protocol-version", "invalid-version")
        |> ProtocolVersion.call([])

      assert conn.status == 400
      assert conn.halted
    end

    test "validates and accepts the modern version even when the legacy flag is disabled" do
      conn =
        conn(:post, "/mcp")
        |> put_req_header("mcp-protocol-version", "2026-07-28")
        |> ProtocolVersion.call([])

      assert conn.assigns[:mcp_version] == "2026-07-28"
      refute conn.halted
    end
  end

  describe "modern-only mode" do
    test "requires exactly one modern protocol header" do
      missing = conn(:post, "/mcp") |> ProtocolVersion.call(protocol_mode: :modern_only)
      assert missing.status == 400
      assert missing.halted

      accepted =
        conn(:post, "/mcp")
        |> put_req_header("mcp-protocol-version", "2026-07-28")
        |> ProtocolVersion.call(protocol_mode: :modern_only)

      assert accepted.assigns[:mcp_version] == "2026-07-28"
      refute accepted.halted
    end
  end

  describe "with feature flag enabled" do
    setup do
      Application.put_env(:arbor_mcp, :protocol_version_required, true)
      :ok
    end

    test "sets default version when no header is present" do
      conn =
        conn(:post, "/mcp")
        |> ProtocolVersion.call([])

      assert conn.assigns[:mcp_version] == "2025-11-25"
      refute conn.halted
    end

    test "accepts valid 2025-11-25 version" do
      conn =
        conn(:post, "/mcp")
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> ProtocolVersion.call([])

      assert conn.assigns[:mcp_version] == "2025-11-25"
      refute conn.halted
    end

    test "accepts valid 2025-06-18 version" do
      conn =
        conn(:post, "/mcp")
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> ProtocolVersion.call([])

      assert conn.assigns[:mcp_version] == "2025-06-18"
      refute conn.halted
    end

    test "accepts valid 2025-03-26 version" do
      conn =
        conn(:post, "/mcp")
        |> put_req_header("mcp-protocol-version", "2025-03-26")
        |> ProtocolVersion.call([])

      assert conn.assigns[:mcp_version] == "2025-03-26"
      refute conn.halted
    end

    test "accepts valid 2024-11-05 version" do
      conn =
        conn(:post, "/mcp")
        |> put_req_header("mcp-protocol-version", "2024-11-05")
        |> ProtocolVersion.call([])

      assert conn.assigns[:mcp_version] == "2024-11-05"
      refute conn.halted
    end

    test "rejects invalid version with 400 error" do
      conn =
        conn(:post, "/mcp")
        |> put_req_header("mcp-protocol-version", "2024-01-01")
        |> ProtocolVersion.call([])

      assert conn.status == 400
      assert conn.halted

      body = Jason.decode!(conn.resp_body)
      assert body["jsonrpc"] == "2.0"
      assert body["error"]["code"] == -32600
      assert body["error"]["message"] == "Invalid Request"
      assert body["error"]["data"]["reason"] =~ "Unsupported protocol version"

      # Without a configured mode the Plug accepts every version of both
      # eras, 2026-07-28 included, and lists exactly what it accepts.
      supported = body["error"]["data"]["supported_versions"]
      assert supported == Arbor.MCP.Server.RequestContext.accepted_versions(nil)
      assert "2026-07-28" in supported

      for version <- supported do
        accepted =
          conn(:post, "/mcp")
          |> put_req_header("mcp-protocol-version", version)
          |> ProtocolVersion.call([])

        refute accepted.halted, "#{version} is listed but rejected"
      end
    end

    test "rejects empty version string" do
      conn =
        conn(:post, "/mcp")
        |> put_req_header("mcp-protocol-version", "")
        |> ProtocolVersion.call([])

      assert conn.status == 400
      assert conn.halted
    end

    test "rejects duplicate protocol version headers" do
      conn =
        conn(:post, "/mcp")
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> prepend_req_headers([{"mcp-protocol-version", "2025-06-18"}])
        |> ProtocolVersion.call([])

      assert conn.status == 400
      assert conn.halted
    end

    test "handles case-sensitive version matching" do
      conn =
        conn(:post, "/mcp")
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> ProtocolVersion.call([])

      assert conn.assigns[:mcp_version] == "2025-06-18"
      refute conn.halted

      # Wrong case should fail
      conn =
        conn(:post, "/mcp")
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> ProtocolVersion.call([])

      assert conn.assigns[:mcp_version] == "2025-06-18"
      refute conn.halted
    end
  end

  describe "protocol mode" do
    test "legacy_only rejects the modern revision and lists only legacy versions" do
      accepted =
        conn(:post, "/mcp")
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> ProtocolVersion.call(protocol_mode: :legacy_only)

      assert accepted.assigns[:mcp_version] == "2025-11-25"
      refute accepted.halted

      rejected =
        conn(:post, "/mcp")
        |> put_req_header("mcp-protocol-version", "2026-07-28")
        |> ProtocolVersion.call(protocol_mode: :legacy_only)

      assert_mode_versions(rejected, "2026-07-28", :legacy_only)
    end

    test "modern_only lists only the modern revision for a legacy or unknown header" do
      accepted =
        conn(:post, "/mcp")
        |> put_req_header("mcp-protocol-version", "2026-07-28")
        |> ProtocolVersion.call(protocol_mode: :modern_only)

      assert accepted.assigns[:mcp_version] == "2026-07-28"
      refute accepted.halted

      for version <- ["2025-11-25", "2099-01-01"] do
        rejected =
          conn(:post, "/mcp")
          |> put_req_header("mcp-protocol-version", version)
          |> ProtocolVersion.call(protocol_mode: :modern_only)

        assert_mode_versions(rejected, version, :modern_only)
      end
    end

    test "prefer_modern lists modern and legacy revisions for an unknown header" do
      accepted =
        conn(:post, "/mcp")
        |> put_req_header("mcp-protocol-version", "2026-07-28")
        |> ProtocolVersion.call(protocol_mode: :prefer_modern)

      assert accepted.assigns[:mcp_version] == "2026-07-28"
      refute accepted.halted

      rejected =
        conn(:post, "/mcp")
        |> put_req_header("mcp-protocol-version", "2099-01-01")
        |> ProtocolVersion.call(protocol_mode: :prefer_modern)

      assert_mode_versions(rejected, "2099-01-01", :prefer_modern)
    end

    test "prefer_legacy lists legacy revisions before the modern revision" do
      rejected =
        conn(:post, "/mcp")
        |> put_req_header("mcp-protocol-version", "2099-01-01")
        |> ProtocolVersion.call(protocol_mode: :prefer_legacy)

      assert_mode_versions(rejected, "2099-01-01", :prefer_legacy)
    end
  end

  describe "helper functions" do
    test "supported_versions/0 returns correct list" do
      assert ProtocolVersion.supported_versions() == [
               "2025-11-25",
               "2025-06-18",
               "2025-03-26",
               "2024-11-05"
             ]
    end

    test "default_version/0 returns correct version" do
      assert ProtocolVersion.default_version() == "2025-11-25"
    end
  end

  defp assert_mode_versions(conn, _version, mode) do
    assert conn.status == 400
    assert conn.halted
    body = Jason.decode!(conn.resp_body)

    assert body["error"]["data"]["supported_versions"] ==
             VersionRegistry.supported_versions(mode)
  end

  describe "init/1" do
    test "passes through options unchanged" do
      opts = [some: :option]
      assert ProtocolVersion.init(opts) == opts
    end
  end
end
