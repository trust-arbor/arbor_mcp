defmodule Arbor.MCP.ClientStatusTimeoutTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client

  defmodule StatusServer do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call(:get_status, _from, opts) do
      Process.sleep(Keyword.get(opts, :delay_ms, 0))
      {:reply, {:ok, %{connection_status: :ready}}, opts}
    end
  end

  test "status keeps the existing call and accepts a caller timeout" do
    client = start_supervised!({StatusServer, []})

    assert {:ok, %{connection_status: :ready}} = Client.get_status(client)
    assert {:ok, %{connection_status: :ready}} = Client.get_status(client, timeout: 100)
  end

  test "a delayed status call returns a stable timeout result" do
    client = start_supervised!({StatusServer, delay_ms: 80})

    assert {:error, :timeout} = Client.get_status(client, timeout: 1)
  end

  test "canonical status returns tagged values and timeout, and bang raises explicitly" do
    client = start_supervised!({StatusServer, []})
    assert {:ok, value} = Client.status(client, timeout: 100)
    assert value == Client.status!(client)

    delayed = start_supervised!({StatusServer, delay_ms: 80}, id: :delayed)
    assert {:error, :timeout} = Client.status(delayed, timeout: 1)
    assert_raise RuntimeError, fn -> Client.status!(delayed, timeout: 1) end
  end

  test "invalid timeout options return a stable error" do
    client = start_supervised!({StatusServer, []})

    for opts <- [[timeout: -1], [timeout: "10"], [timeout: nil], :invalid] do
      assert {:error, :invalid_timeout} = Client.get_status(client, opts)
    end
  end
end
