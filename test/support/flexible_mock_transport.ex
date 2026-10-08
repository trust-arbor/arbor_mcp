defmodule Arbor.MCP.Test.FlexibleMockTransport do
  @moduledoc """
  A flexible mock transport that accepts multiple protocol versions
  for testing version negotiation.
  """

  @behaviour Arbor.MCP.Transport

  def connect(opts) do
    case Keyword.get(opts, :fail_connect) do
      true -> {:error, :connection_refused}
      _ -> {:ok, %{pid: self(), opts: opts}}
    end
  end

  def send_data(%{pid: pid}, message) do
    Kernel.send(pid, {:transport_send, message})
    {:ok, %{pid: pid}}
  end

  def recv(%{pid: _pid} = state, timeout) do
    receive do
      {:mock_response, data} ->
        {:ok, data, state}

      {:mock_error, reason} ->
        {:error, reason}
    after
      timeout -> {:error, :timeout}
    end
  end

  def close(_state), do: :ok
  def connected?(_state), do: true
  def controlling_process(_state, _pid), do: :ok
  def send_message(msg, state), do: send_data(state, msg)
  def receive_message(state), do: recv(state, 5000)
end

defmodule Arbor.MCP.Test.FlexibleMockServer do
  @moduledoc """
  Flexible mock server that handles protocol version negotiation.
  """

  # Supported versions in order of preference
  @supported_versions ["2025-06-18", "2025-03-26", "2024-11-05"]

  def handle_initialize(client_pid, data) do
    request = Jason.decode!(data)

    if request["method"] == "initialize" do
      client_version = get_in(request, ["params", "protocolVersion"])

      # Negotiate version
      negotiated_version = negotiate_version(client_version)

      response = %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "result" => %{
          "protocolVersion" => negotiated_version,
          "serverInfo" => %{
            "name" => "FlexibleTestServer",
            "version" => "1.0.0"
          },
          "capabilities" => capabilities_for_version(negotiated_version)
        }
      }

      send(client_pid, {:mock_response, Jason.encode!(response)})
    end
  end

  defp negotiate_version(client_version) do
    if client_version in @supported_versions do
      client_version
    else
      # Default to latest if client version is unknown
      hd(@supported_versions)
    end
  end

  defp capabilities_for_version("2025-06-18") do
    %{
      "tools" => %{"listChanged" => true},
      "resources" => %{"subscribe" => true, "listChanged" => true},
      "prompts" => %{"listChanged" => true},
      "logging" => %{"setLevel" => true}
    }
  end

  defp capabilities_for_version("2025-03-26") do
    %{
      "tools" => %{"listChanged" => true},
      "resources" => %{"subscribe" => true, "listChanged" => true},
      "prompts" => %{"listChanged" => true},
      "logging" => %{"setLevel" => true},
      "experimental" => %{"batchProcessing" => true}
    }
  end

  defp capabilities_for_version(_) do
    %{
      "tools" => %{},
      "resources" => %{},
      "prompts" => %{}
    }
  end
end
