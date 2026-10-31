defmodule ExMCP.Client.EraProbeNotificationsTest do
  use ExUnit.Case, async: true

  alias ExMCP.Client.EraProbe

  defmodule ChattyTransport do
    alias ExMCP.Server.Discover
    def send_message(message, state), do: {:ok, Map.put(state, :id, Jason.decode!(message)["id"])}

    def receive_message(state, _timeout) do
      if state.remaining == :infinity or state.remaining > 0 do
        next =
          if state.remaining == :infinity,
            do: state,
            else: %{state | remaining: state.remaining - 1}

        {:ok,
         Jason.encode!(%{
           "jsonrpc" => "2.0",
           "method" => "notifications/message",
           "params" => %{}
         }), next}
      else
        result =
          Discover.build(%{"name" => "chatty", "version" => "1"}, %{},
            protocol_mode: :modern_only
          )

        response = %{
          "jsonrpc" => "2.0",
          "id" => state.id,
          "result" => Map.put(result, "resultType", "complete")
        }

        {:ok, Jason.encode!(response), state}
      end
    end
  end

  test "notifications keep the updated transport state until the actual response" do
    assert {:ok, %{protocol_version: "2026-07-28"}, %{remaining: 0}} =
             EraProbe.probe(ChattyTransport, %{remaining: 3},
               protocol_mode: :modern_only,
               era_probe_timeout: 1_000
             )
  end

  test "continuous notifications cannot renew the probe deadline" do
    task =
      Task.async(fn ->
        EraProbe.probe(ChattyTransport, %{remaining: :infinity},
          protocol_mode: :modern_only,
          era_probe_timeout: 10
        )
      end)

    try do
      assert {:error, {:probe_timeout, _}, _state} = Task.await(task, 1_000)
    after
      Task.shutdown(task, :brutal_kill)
    end
  end
end
