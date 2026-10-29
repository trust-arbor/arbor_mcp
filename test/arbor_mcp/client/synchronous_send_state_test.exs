defmodule Arbor.MCP.Client.SynchronousSendStateTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.RequestHandler

  @moduletag :reauth_round8

  defmodule Transport do
    @behaviour Arbor.MCP.Transport
    @impl true
    def connect(opts),
      do:
        {:ok,
         %{
           owner: Keyword.fetch!(opts, :test_pid),
           phase: Keyword.get(opts, :fail_phase, :first),
           retired: false
         }}

    @impl true
    def send_message(body, state) do
      case send_message_with_state(body, state) do
        {:error, reason, _latest} -> {:error, reason}
        result -> result
      end
    end

    @doc false
    def send_message_with_state(body, %{phase: :initialized} = state) do
      case Jason.decode!(body) do
        %{"method" => "initialize", "id" => id} ->
          result = %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{},
            "serverInfo" => %{"name" => "stateful-error", "version" => "1"}
          }

          {:ok, state, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})}

        _notification ->
          {:error, :refused, %{state | retired: true}}
      end
    end

    def send_message_with_state(_body, state), do: {:error, :refused, %{state | retired: true}}
    @impl true
    def receive_message(_state), do: {:error, :unexpected_receive}
    @impl true
    def connected?(_state), do: true
    @impl true
    def close(state) do
      send(state.owner, {:closed_transport, state})
      :ok
    end
  end

  for mode <- [:modern_only, :prefer_modern, :legacy_only, :prefer_legacy] do
    test "#{mode} establishment cleanup receives the failed send's updated transport" do
      assert {:error, _} =
               Client.start_link(
                 transport: Transport,
                 test_pid: self(),
                 protocol_mode: unquote(mode),
                 reconnect: false,
                 health_check_interval: nil
               )

      assert_receive {:closed_transport, %{retired: true}}
    end
  end

  test "initialized notification failure keeps the updated state for cleanup" do
    assert {:error, _} =
             Client.start_link(
               transport: Transport,
               test_pid: self(),
               fail_phase: :initialized,
               protocol_mode: :legacy_only,
               reconnect: false,
               health_check_interval: nil
             )

    assert_receive {:closed_transport, %{retired: true}}
  end

  test "a failed synchronous legacy batch applies the returned transport state" do
    state = %Client{
      transport_mod: Transport,
      transport_state: %{owner: self(), phase: :first, retired: false},
      protocol_version: "2025-11-25",
      transport_opts: [capabilities: %{}],
      client_info: %{name: "batch", version: "1"}
    }

    assert {:reply, {:error, %{type: :transport_error}}, updated} =
             RequestHandler.handle_batch_request(
               [{"tools/list", %{}}],
               {self(), make_ref()},
               state
             )

    assert updated.transport_state.retired
  end
end
