defmodule Arbor.MCP.Server.ReplayCacheTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.{MRTR, ReplayCache, RequestContext, RequestState}

  @key :binary.copy(<<91>>, 32)

  test "atomically admits one concurrent consumer" do
    cache = start_cache()
    expires_at = System.system_time(:second) + 60

    results =
      1..20
      |> Enum.map(fn _index ->
        Task.async(fn -> ReplayCache.ETS.consume("same-jti", expires_at, server: cache) end)
      end)
      |> Task.await_many()

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :replayed})) == 19
  end

  test "marks verified context single-use and rejects a second resume" do
    cache = start_cache()
    context = context()
    params = params()
    request_state = [active_key_id: "test", keys: %{"test" => @key}]
    seal_opts = [request_state: request_state]

    assert {:ok, binding} = RequestState.binding(context, params, ["approval"], 1, seal_opts)
    assert {:ok, token} = RequestState.seal(%{"step" => 1}, binding, seal_opts)

    retry_context = %{
      context
      | input_responses: %{"approval" => %{"action" => "accept"}},
        request_state: token,
        sealed_request_state: token
    }

    retry_params =
      params
      |> Map.put("inputResponses", retry_context.input_responses)
      |> Map.put("requestState", token)

    opts = [
      request_state: request_state,
      replay_cache: {ReplayCache.ETS, [server: cache]}
    ]

    assert {:ok, verified} = MRTR.prepare_context(retry_context, retry_params, opts)
    assert verified.delivery_semantics == :single_use
    assert verified.request_state == %{"step" => 1}

    assert {:error, error} = MRTR.prepare_context(retry_context, retry_params, opts)
    assert error.code == -32602
    assert error.message =~ "already been consumed"
  end

  defp start_cache do
    id = make_ref()
    start_supervised!(%{id: id, start: {ReplayCache.ETS, :start_link, [[name: nil]]}})
  end

  defp context do
    %RequestContext{
      method: "tools/call",
      request_id: 1,
      request?: true,
      era: :modern,
      protocol_version: "2026-07-28",
      client_capabilities: %{"elicitation" => %{}}
    }
  end

  defp params do
    %{
      "name" => "side-effect",
      "arguments" => %{},
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}}
      }
    }
  end
end
