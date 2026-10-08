defmodule Arbor.MCP.Protocol.TraceContextTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Protocol.{Meta, TraceContext}
  alias Arbor.MCP.Server.RequestContext

  @traceparent "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
  @version "2026-07-28"

  setup do
    previous = Application.get_env(:arbor_mcp, :otel_meta)
    on_exit(fn -> restore_env(:arbor_mcp, :otel_meta, previous) end)
    :ok
  end

  describe "traceparent" do
    test "accepts a W3C version 00 traceparent" do
      assert {:ok, %{"traceparent" => @traceparent}} =
               TraceContext.normalize(%{traceparent: @traceparent})
    end

    test "rejects malformed, uppercase, and all-zero identifiers" do
      invalid = [
        "00-abcd-1234-01",
        String.upcase(@traceparent),
        "00-00000000000000000000000000000000-00f067aa0ba902b7-01",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01",
        "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
      ]

      Enum.each(invalid, fn value ->
        assert {:error, "traceparent"} = TraceContext.normalize(%{"traceparent" => value})
      end)
    end

    test "rejects non-binary fields and invalid map keys without raising" do
      assert {:error, "trace-context"} = TraceContext.normalize(%{"traceparent" => 123})
      assert {:error, "trace-context"} = TraceContext.normalize(%{{:bad, :key} => "value"})

      assert {:error, "traceparent"} =
               TraceContext.normalize(%{"traceparent" => <<0xFF, 0::size(432)>>})

      assert {:error, "trace-context"} =
               TraceContext.normalize(%{"traceparent" => @traceparent, traceparent: @traceparent})
    end
  end

  describe "tracestate" do
    test "accepts valid unique members with traceparent" do
      tracestate = "vendor=value,tenant@system=opaque"

      assert {:ok, normalized} =
               TraceContext.normalize(%{
                 "traceparent" => @traceparent,
                 "tracestate" => tracestate
               })

      assert normalized["tracestate"] == tracestate
    end

    test "requires traceparent and rejects duplicates or invalid values" do
      assert {:error, "tracestate"} = TraceContext.normalize(%{"tracestate" => "vendor=value"})

      assert {:error, "tracestate"} =
               TraceContext.normalize(%{
                 "traceparent" => @traceparent,
                 "tracestate" => "vendor=one,vendor=two"
               })

      assert {:error, "tracestate"} =
               TraceContext.normalize(%{
                 "traceparent" => @traceparent,
                 "tracestate" => "vendor=bad=value"
               })

      assert {:error, "tracestate"} =
               TraceContext.normalize(%{
                 "traceparent" => @traceparent,
                 "tracestate" => <<"vendor=", 0xFF>>
               })
    end

    test "bounds members and total tracestate bytes" do
      too_many = Enum.map_join(1..33, ",", &"k#{&1}=v")

      assert {:error, "tracestate"} =
               TraceContext.normalize(%{
                 "traceparent" => @traceparent,
                 "tracestate" => too_many
               })

      assert {:error, "tracestate"} =
               TraceContext.normalize(%{
                 "traceparent" => @traceparent,
                 "tracestate" => "vendor=" <> String.duplicate("x", 506)
               })
    end
  end

  describe "baggage" do
    test "propagates only allowlisted keys and preserves valid properties" do
      configure(baggage_allowlist: ["tenant.id", "request-id"])

      baggage = "tenant.id=acme;secure,secret=drop,request-id=req-1"

      assert {:ok, normalized} = TraceContext.normalize(%{"baggage" => baggage})
      assert normalized["baggage"] == "tenant.id=acme;secure,request-id=req-1"
    end

    test "drops baggage entirely when no keys are allowlisted" do
      assert {:ok, %{}} = TraceContext.normalize(%{"baggage" => "secret=drop"})
    end

    test "validates and bounds baggage before allowlist filtering" do
      configure(baggage_allowlist: ["safe"], max_baggage_bytes: 32, max_baggage_members: 2)

      assert {:error, "baggage"} =
               TraceContext.normalize(%{"baggage" => "secret=" <> String.duplicate("x", 40)})

      assert {:error, "baggage"} =
               TraceContext.normalize(%{"baggage" => "one=1,two=2,three=3"})

      assert {:error, "baggage"} =
               TraceContext.normalize(%{"baggage" => "safe=one,safe=two"})

      assert {:error, "baggage"} = TraceContext.normalize(%{"baggage" => "safe=bad value"})
      assert {:error, "baggage"} = TraceContext.normalize(%{"baggage" => <<"safe=", 0xFF>>})
    end
  end

  describe "MCP metadata integration" do
    test "validates caller meta and lets explicit trace context override it" do
      assert {:error, {:invalid_meta_field, "traceparent"}} =
               Meta.build_request_meta(
                 %{"traceparent" => "invalid"},
                 @version,
                 %{}
               )

      assert {:ok, meta} =
               Meta.build_request_meta(
                 %{"traceparent" => "invalid"},
                 @version,
                 %{},
                 trace_context: %{"traceparent" => @traceparent}
               )

      assert meta["traceparent"] == @traceparent
    end

    test "sanitizes inbound request metadata and context baggage" do
      configure(baggage_allowlist: ["tenant.id"])

      meta = %{
        "io.modelcontextprotocol/protocolVersion" => @version,
        "io.modelcontextprotocol/clientCapabilities" => %{},
        "traceparent" => @traceparent,
        "baggage" => "tenant.id=acme,secret=drop"
      }

      assert {:ok, parsed} = Meta.parse_request_meta(meta)
      assert parsed.trace_context["baggage"] == "tenant.id=acme"
      assert parsed.meta["baggage"] == "tenant.id=acme"
      refute parsed.meta["baggage"] =~ "secret"
    end

    test "applies the same bounds to notifications, results, and legacy request context" do
      assert {:error, {:invalid_meta_field, "traceparent"}} =
               Meta.parse_notification_meta(%{"traceparent" => "invalid"})

      assert {:error, {:invalid_meta_field, "tracestate"}} =
               Meta.parse_result_meta(%{"tracestate" => "vendor=value"})

      message = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{"_meta" => %{"traceparent" => "invalid"}}
      }

      assert {:error, {:invalid_meta_field, "traceparent"}} =
               RequestContext.from_message(message)
    end

    test "fails closed when the trace-context policy is invalid" do
      Application.put_env(:arbor_mcp, :otel_meta, baggage_allowlist: :all)

      assert {:error, "trace-context"} = TraceContext.normalize(%{})

      Application.put_env(:arbor_mcp, :otel_meta, max_total_bytes: 65_537)

      assert {:error, "trace-context"} = TraceContext.normalize(%{})
    end

    test "applies the configured total-byte limit before propagation" do
      configure(max_total_bytes: 32)

      assert {:error, "trace-context"} =
               TraceContext.normalize(%{"traceparent" => @traceparent})
    end
  end

  defp configure(options), do: Application.put_env(:arbor_mcp, :otel_meta, options)

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
