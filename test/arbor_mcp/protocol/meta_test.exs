defmodule Arbor.MCP.Protocol.MetaTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Protocol.Meta

  @version "2026-07-28"
  @traceparent "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

  describe "metadata key grammar" do
    test "accepts unprefixed and reverse-DNS-prefixed keys" do
      for key <- [
            "",
            "progressToken",
            "traceparent",
            "com.example/request-id",
            "io.modelcontextprotocol/clientInfo",
            "org.example.api/foo_bar.baz-1"
          ] do
        assert Meta.valid_key?(key), "expected #{inspect(key)} to be valid"
      end
    end

    test "rejects malformed labels and names" do
      for key <- [
            :progressToken,
            "/name",
            "com..example/name",
            "1com.example/name",
            "com.example/-name",
            "com.example/name_",
            "com.example/name/extra"
          ] do
        refute Meta.valid_key?(key), "expected #{inspect(key)} to be invalid"
      end
    end

    test "recognizes prefixes whose second label is reserved" do
      for key <- [
            "io.modelcontextprotocol/foo",
            "dev.mcp/foo",
            "org.modelcontextprotocol.api/foo",
            "com.mcp.tools/foo"
          ] do
        assert Meta.reserved_key?(key)
      end

      refute Meta.reserved_key?("com.example.mcp/foo")
      refute Meta.reserved_key?("progressToken")
    end
  end

  describe "build_request_meta/4" do
    test "adds required fields and preserves application and trace metadata" do
      assert {:ok, meta} =
               Meta.build_request_meta(
                 %{"com.example/request-id" => "req-1", "progressToken" => 42},
                 @version,
                 %{sampling: %{tools: %{}}},
                 client_info: %{name: "example", version: "1.2.3"},
                 log_level: :warning,
                 trace_context: %{traceparent: @traceparent}
               )

      assert meta["io.modelcontextprotocol/protocolVersion"] == @version

      assert meta["io.modelcontextprotocol/clientCapabilities"] == %{
               "sampling" => %{"tools" => %{}}
             }

      assert meta["io.modelcontextprotocol/clientInfo"] == %{
               "name" => "example",
               "version" => "1.2.3"
             }

      assert meta["io.modelcontextprotocol/logLevel"] == "warning"
      assert meta["com.example/request-id"] == "req-1"
      assert meta["progressToken"] == 42
      assert meta["traceparent"] == @traceparent
    end

    test "connection values replace caller-supplied identity fields" do
      caller_meta = %{
        "io.modelcontextprotocol/protocolVersion" => "spoofed",
        "io.modelcontextprotocol/clientCapabilities" => %{"spoofed" => %{}},
        "io.modelcontextprotocol/clientInfo" => %{"name" => "spoofed", "version" => "0"}
      }

      assert {:ok, meta} =
               Meta.build_request_meta(caller_meta, @version, %{},
                 client_info: %{"name" => "Arbor.MCP", "version" => "1.0"}
               )

      assert meta["io.modelcontextprotocol/protocolVersion"] == @version
      assert meta["io.modelcontextprotocol/clientCapabilities"] == %{}
      assert meta["io.modelcontextprotocol/clientInfo"]["name"] == "Arbor.MCP"
    end

    test "rejects malformed custom metadata and protocol fields" do
      assert {:error, {:invalid_meta_key, :bad}} =
               Meta.build_request_meta(%{bad: true}, @version, %{})

      assert {:error, {:invalid_meta_field, "io.modelcontextprotocol/protocolVersion"}} =
               Meta.build_request_meta(%{}, nil, %{})

      assert {:error, {:invalid_meta_field, "io.modelcontextprotocol/clientCapabilities"}} =
               Meta.build_request_meta(%{}, @version, [])
    end
  end

  describe "parsing" do
    test "parses a valid request into normalized context fields" do
      meta = %{
        "io.modelcontextprotocol/protocolVersion" => @version,
        "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}},
        "io.modelcontextprotocol/clientInfo" => %{"name" => "client", "version" => "1"},
        "io.modelcontextprotocol/logLevel" => "info",
        "progressToken" => "progress-1",
        "traceparent" => @traceparent
      }

      assert {:ok, parsed} = Meta.parse(meta, :request)
      assert parsed.protocol_version == @version
      assert parsed.client_capabilities == %{"elicitation" => %{}}
      assert parsed.client_info["name"] == "client"
      assert parsed.log_level == "info"
      assert parsed.progress_token == "progress-1"
      assert parsed.trace_context == %{"traceparent" => @traceparent}
    end

    test "requires version and capabilities on requests" do
      assert {:error, {:missing_meta_field, "io.modelcontextprotocol/protocolVersion"}} =
               Meta.parse_request_meta(%{})

      assert {:error, {:missing_meta_field, "io.modelcontextprotocol/clientCapabilities"}} =
               Meta.parse_request_meta(%{
                 "io.modelcontextprotocol/protocolVersion" => @version
               })
    end

    test "validates notification and result-specific identities" do
      assert {:ok, %{subscription_id: 12}} =
               Meta.parse_notification_meta(%{
                 "io.modelcontextprotocol/subscriptionId" => 12
               })

      assert {:ok, %{server_info: %{"name" => "server"}}} =
               Meta.parse_result_meta(%{
                 "io.modelcontextprotocol/serverInfo" => %{
                   "name" => "server",
                   "version" => "1"
                 }
               })
    end
  end
end
