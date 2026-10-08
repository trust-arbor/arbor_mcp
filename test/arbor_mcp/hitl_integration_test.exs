defmodule Arbor.MCP.HITLIntegrationTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.DefaultHandler
  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.Handler.Echo
  alias Arbor.MCP.Server.HandlerServer

  defmodule MockApprovalHandler do
    @behaviour Arbor.MCP.Approval

    @impl true
    def request_approval(_type, data, opts) do
      # Get the test process from opts
      test_pid = Keyword.get(opts, :test_pid)

      if test_pid do
        send(test_pid, {:approval_requested, data})
      end

      # Auto-approve for testing
      {:approved, data}
    end
  end

  describe "full human-in-the-loop flow" do
    test "server requests createMessage and gets approved response" do
      # Start server
      {:ok, server} =
        HandlerServer.start_link(
          transport: :test,
          handler: Echo
        )

      # Start client with default handler and mock approval
      {:ok, _client} =
        Client.start_link(
          transport: :test,
          server: server,
          handler:
            {DefaultHandler,
             [
               approval_handler: MockApprovalHandler
             ]}
        )

      # Wait for initialization
      Process.sleep(100)

      # Server creates a message request
      params = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => %{
              "type" => "text",
              "text" => "What is the weather like?"
            }
          }
        ],
        "modelPreferences" => %{
          "hints" => ["gpt-4", "claude-3"],
          "temperature" => 0.7
        }
      }

      # Server calls createMessage on client
      {:ok, result} = Server.create_message(server, params)

      # Verify the response structure
      assert result["role"] == "assistant"
      assert result["model"] == "default-model"
      assert is_map(result["content"])
      assert result["content"]["type"] == "text"
      assert is_binary(result["content"]["text"])
    end

    test "client handler denies sampling request" do
      # Custom handler that denies requests
      defmodule DenyingHandler do
        @behaviour Arbor.MCP.Client.Handler

        @impl true
        def init(args), do: {:ok, args}

        @impl true
        def handle_ping(state), do: {:ok, %{}, state}

        @impl true
        def handle_list_roots(state), do: {:ok, [], state}

        @impl true
        def handle_create_message(_params, state) do
          {:error,
           %{
             "code" => -32603,
             "message" => "User denied the sampling request"
           }, state}
        end

        @impl true
        def terminate(_reason, _state), do: :ok
      end

      # Start server
      {:ok, server} =
        HandlerServer.start_link(
          transport: :test,
          handler: Echo
        )

      # Start client with denying handler
      {:ok, _client} =
        Client.start_link(
          transport: :test,
          server: server,
          handler: DenyingHandler
        )

      # Wait for initialization
      Process.sleep(100)

      # Server creates a message request
      params = %{
        "messages" => [
          %{"role" => "user", "content" => "Test"}
        ]
      }

      # Server calls createMessage on client - should get error
      {:error, error} = Server.create_message(server, params)
      assert error["code"] == -32603
      assert error["message"] =~ "denied"
    end

    test "approval handler receives context and can track requests" do
      test_pid = self()

      # Custom approval handler that sends data to test process
      defmodule TrackingApprovalHandler do
        @behaviour Arbor.MCP.Approval

        @impl true
        def request_approval(type, data, opts) do
          test_pid = Keyword.fetch!(opts, :test_pid)
          send(test_pid, {:approval, type, data, opts})

          case type do
            :sampling ->
              {:approved, data}

            :response ->
              # Modify the response
              modified =
                data
                |> Map.put(
                  "content",
                  Map.put(data["content"] || %{}, "text", "Modified by approval handler")
                )

              {:modified, modified}
          end
        end
      end

      # Start server
      {:ok, server} =
        HandlerServer.start_link(
          transport: :test,
          handler: Echo
        )

      # Start client with tracking handler
      {:ok, _client} =
        Client.start_link(
          transport: :test,
          server: server,
          handler:
            {DefaultHandler,
             [
               approval_handler: TrackingApprovalHandler,
               test_pid: test_pid
             ]}
        )

      # Wait for initialization
      Process.sleep(100)

      # Server creates a message request
      params = %{
        "messages" => [
          %{"role" => "user", "content" => "Test message"}
        ]
      }

      # Server calls createMessage
      {:ok, result} = Server.create_message(server, params)

      # Should have received sampling approval request
      assert_receive {:approval, :sampling, ^params, _opts}

      # Should have received response approval request
      assert_receive {:approval, :response, response_data, opts}
      assert response_data["role"] == "assistant"
      assert Keyword.get(opts, :sampling_params) == params

      # Result should be modified
      assert result["content"]["text"] == "Modified by approval handler"
    end
  end
end
