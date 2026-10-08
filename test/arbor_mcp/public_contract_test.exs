defmodule Arbor.MCP.PublicContractTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.{Client, Error, Response}

  defmodule Peer do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    @impl true
    def init(opts), do: {:ok, Map.new(opts)}
    @impl true
    def handle_call({:request, method, params, control}, _from, state) do
      send(state.owner, {:request, method, params, control})
      {:reply, state.reply, state}
    end

    def handle_call(:conformance_mode?, _from, state) do
      send(state.owner, :conformance_checked)
      {:reply, false, state}
    end

    def handle_call(:get_default_retry_policy, _from, state), do: {:reply, {:ok, []}, state}
    def handle_call(:get_default_timeout, _from, state), do: {:reply, {:ok, 5_000}, state}
    @impl true
    def handle_cast({:cancel_mrtr_scope, _scope}, state), do: {:noreply, state}
  end

  test "resource convenience reads use standard contents and retain nontext results" do
    raw = %{"contents" => [%{"uri" => "file:///data", "text" => "{\"ready\":true}"}]}
    client = peer({:ok, raw})
    assert {:ok, "{\"ready\":true}"} = Arbor.MCP.read(client, "file:///data")
    assert {:ok, %{"ready" => true}} = Arbor.MCP.read(client, "file:///data", parse_json: true)
    assert {:ok, ^raw} = Arbor.MCP.read(client, "file:///data", format: :map)

    assert {:ok, %Response{contents: [_]}} =
             Arbor.MCP.read(client, "file:///data", format: :struct)

    blob = %{"contents" => [%{"uri" => "file:///image", "blob" => "AAAA"}]}
    assert {:ok, ^blob} = Arbor.MCP.read(peer({:ok, blob}), "file:///image")
    assert {:ok, %{}} = Arbor.MCP.read(peer({:ok, %{}}), "file:///empty")
  end

  test "list convenience aliases expose a complete page on explicit format" do
    raw = %{"tools" => [%{"name" => "echo"}], "nextCursor" => "next", "_meta" => %{}}
    client = peer({:ok, raw})
    assert {:ok, [%{"name" => "echo"}]} = Arbor.MCP.tools(client)
    assert {:ok, ^raw} = Arbor.MCP.tools(client, cursor: "first", format: :map)
    assert_receive {:request, "tools/list", %{"cursor" => "first"}, _control}
    assert {:ok, %Response{nextCursor: "next"}} = Arbor.MCP.tools(client, format: :struct)
  end

  test "tool controls are forwarded and complete results remain available" do
    raw = %{"content" => [%{"type" => "text", "text" => "done"}], "structuredContent" => false}
    client = peer({:ok, raw})

    assert {:ok, "done"} =
             Arbor.MCP.call(client, "charge", %{amount: 1},
               idempotency_key: "order",
               progress_token: "progress",
               meta: %{"trace" => true},
               http_stream_retry: :safe_only
             )

    assert_receive {:request, "tools/call", params, _control}
    assert params["arguments"]["idempotencyKey"] == "order"
    assert params["_meta"] == %{"trace" => true, "progressToken" => "progress"}
    assert_receive :conformance_checked

    assert {:ok, %Response{structuredOutput: false}} =
             Arbor.MCP.call(client, "charge", %{}, normalize: false)

    assert {:ok, ^raw} = Arbor.MCP.call(client, "charge", %{}, format: :map)
  end

  test "normalized tool errors retain the complete result in ToolError" do
    raw = %{
      "isError" => true,
      "content" => [%{"type" => "text", "text" => "declined"}],
      "structuredContent" => %{"code" => "declined"},
      "_meta" => %{"trace" => "a"}
    }

    client = peer({:ok, raw})

    assert {:error, %Error.ToolError{tool_name: "charge", reason: %Response{} = result}} =
             Arbor.MCP.call(client, "charge")

    assert Response.to_raw(result) == raw
    assert {:ok, %Response{is_error: true}} = Client.call_tool(client, "charge", %{})
    assert {:ok, ^raw} = Arbor.MCP.call(client, "charge", %{}, format: :map)
  end

  test "local timeout classification is independent of response format" do
    client = peer({:error, :timeout})

    for format <- [:map, :struct] do
      assert {:error, :timeout} = Client.list_tools(client, format: format, retry_policy: false)
    end

    remote = peer({:error, %{"code" => -32603, "message" => "server failure"}})
    assert {:error, %Error.ProtocolError{code: -32603}} = Client.list_tools(remote)
  end

  test "conflicting or unsupported facade controls raise before submitting" do
    client = peer({:ok, %{}})
    assert_raise ArgumentError, fn -> Arbor.MCP.call(client, "echo", %{}, timeuot: 10) end
    assert_raise ArgumentError, fn -> Arbor.MCP.call(client, "echo", %{}, format: :raw) end

    assert_raise ArgumentError, fn ->
      Arbor.MCP.call(client, "echo", %{}, format: :map, normalize: true)
    end

    assert_raise ArgumentError, fn ->
      Arbor.MCP.read(client, "file:///data", format: :map, parse_json: true)
    end

    assert_raise ArgumentError, fn -> Client.list_tools(client, timeout: :infinity) end
    refute_receive {:request, _, _, _}
  end

  test "wire conversion preserves envelopes, extensions, media and schema field presence" do
    raw = %{
      "content" => [
        %{"type" => "image", "data" => "AAAA", "mimeType" => "image/png", "annotations" => nil},
        %{
          "type" => "resource",
          "resource" => %{"uri" => "file:///a", "text" => "hello"},
          "_meta" => %{"x" => false}
        }
      ],
      "isError" => false,
      "_meta" => nil,
      "structuredContent" => false,
      "tools" => [
        %{
          "name" => "echo",
          "inputSchema" => %{"type" => "object", "properties" => %{"a" => %{"type" => "string"}}}
        }
      ],
      "resources" => [%{"uri" => "file:///a", "mimeType" => nil}],
      "resourceTemplates" => [%{"uriTemplate" => "file:///{path}"}],
      "prompts" => [%{"name" => "ask", "arguments" => [%{"name" => "a", "required" => false}]}],
      "messages" => [
        %{
          "role" => "assistant",
          "content" => %{"type" => "text", "text" => "hello", "_meta" => %{}}
        }
      ],
      "contents" => [%{"uri" => "file:///a", "text" => "hello"}],
      "roots" => [%{"uri" => "file:///"}],
      "nextCursor" => nil,
      "description" => "prompt",
      "completion" => %{"values" => ["a"], "total" => 1, "hasMore" => false},
      "resultType" => "mixed",
      "ttlMs" => 0,
      "cacheScope" => "session",
      "resourceLinks" => [],
      "extension" => %{"enabled" => false}
    }

    assert raw |> Response.from_raw_response() |> Response.to_raw() == raw

    for value <- [nil, false, [], %{}] do
      input = %{"structuredContent" => value}
      assert input |> Response.from_raw_response() |> Response.to_raw() == input
    end

    aliases = %{
      "_meta" => nil,
      "meta" => %{"legacy" => true},
      "isError" => false,
      "is_error" => true,
      "structuredContent" => false,
      "structuredOutput" => %{"legacy" => true}
    }

    response = Response.from_raw_response(aliases)
    assert response.is_error == false
    assert Response.to_raw(response) == aliases
    assert %{} |> Response.from_raw_response() |> Response.to_raw() == %{}
  end

  defp peer(reply) do
    start_supervised!({Peer, owner: self(), reply: reply}, id: make_ref())
  end
end
