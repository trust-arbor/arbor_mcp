defmodule Arbor.MCP.PromptsComplianceTest do
  use ExUnit.Case, async: true

  @moduletag :compliance

  alias Arbor.MCP.Client
  alias Arbor.MCP.Internal.Protocol
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule TestPromptsServer do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_args) do
      {:ok,
       %{
         prompts: [
           %{
             name: "code_review",
             description: "Perform a comprehensive code review",
             arguments: [
               %{name: "code", description: "The code to review", required: true},
               %{name: "language", description: "Programming language", required: true},
               %{name: "focus", description: "Review focus", required: false}
             ]
           },
           %{
             name: "simple_prompt",
             description: "A simple prompt with no arguments",
             arguments: []
           }
         ]
       }}
    end

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-03-26",
         serverInfo: %{name: "test-prompts-server", version: "1.0.0"},
         capabilities: %{
           prompts: %{listChanged: true}
         }
       }, state}
    end

    @impl true
    def handle_list_prompts(_cursor, state) do
      {:ok, state.prompts, nil, state}
    end

    @impl true
    def handle_get_prompt(name, arguments, state) do
      case find_prompt(name, state.prompts) do
        nil ->
          {:error, "Unknown prompt: #{name}", state}

        prompt ->
          case validate_arguments(prompt, arguments) do
            :ok ->
              messages = generate_messages(prompt, arguments)
              {:ok, %{messages: messages}, state}

            {:error, reason} ->
              {:error, reason, state}
          end
      end
    end

    # Required callbacks (minimal implementation)
    @impl true
    def handle_list_tools(_cursor, state) do
      {:ok, [], nil, state}
    end

    @impl true
    def handle_call_tool(_name, _args, state) do
      {:error, "No tools available", state}
    end

    # Helper functions
    defp find_prompt(name, prompts) do
      Enum.find(prompts, fn p -> p.name == name end)
    end

    defp validate_arguments(prompt, arguments) do
      required_args =
        prompt.arguments
        |> Enum.filter(& &1.required)
        |> Enum.map(& &1.name)

      missing =
        Enum.filter(required_args, fn arg ->
          not Map.has_key?(arguments, arg)
        end)

      case missing do
        [] -> :ok
        _ -> {:error, "Missing required arguments: #{Enum.join(missing, ", ")}"}
      end
    end

    defp generate_messages(prompt, arguments) do
      case prompt.name do
        "code_review" ->
          focus = arguments["focus"] || "all"

          [
            %{
              role: "user",
              content: %{
                type: "text",
                text:
                  "Review this #{arguments["language"]} code with #{focus} focus:\n#{arguments["code"]}"
              }
            }
          ]

        "simple_prompt" ->
          [
            %{
              role: "user",
              content: %{
                type: "text",
                text: "This is a simple prompt."
              }
            }
          ]

        _ ->
          [
            %{
              role: "user",
              content: %{
                type: "text",
                text: "Execute prompt: #{prompt.name}"
              }
            }
          ]
      end
    end
  end

  setup do
    # Start server
    {:ok, server} =
      Server.start_link(
        transport: :test,
        handler: TestPromptsServer
      )

    # Start client
    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server
      )

    # Wait for initialization
    Process.sleep(100)

    %{server: server, client: client}
  end

  describe "prompts capability compliance" do
    test "server declares prompts capability correctly", %{client: client} do
      # The initialization should have been successful
      # Let's verify by making a request
      {:ok, result} = Client.list_prompts(client)

      assert is_list(result.prompts)
      assert length(result.prompts) == 2
    end

    test "prompts/list method works correctly", %{client: client} do
      {:ok, result} = Client.list_prompts(client)

      # Verify structure
      assert %{prompts: prompts} = result
      assert is_list(prompts)

      # Check prompt structure compliance
      code_review_prompt = Enum.find(prompts, &(&1.name == "code_review"))
      assert code_review_prompt != nil
      assert code_review_prompt.name == "code_review"
      assert is_binary(code_review_prompt.description)
      assert is_list(code_review_prompt.arguments)

      # Verify arguments structure
      args = code_review_prompt.arguments
      code_arg = Enum.find(args, &(&1.name == "code"))
      assert code_arg.required == true
      assert is_binary(code_arg.description)
    end

    test "prompts/get method works with valid arguments", %{client: client} do
      arguments = %{
        "code" => "def hello, do: \"world\"",
        "language" => "elixir",
        "focus" => "readability"
      }

      {:ok, result} = Client.get_prompt(client, "code_review", arguments)

      # Verify response structure
      assert %{messages: messages} = result
      assert is_list(messages)
      assert length(messages) == 1

      message = hd(messages)
      assert message.role == "user"
      assert message.content.type == "text"
      assert String.contains?(message.content.text, "elixir")
      assert String.contains?(message.content.text, "readability")
    end

    test "prompts/get handles missing required arguments", %{client: client} do
      # Missing required "code" and "language" arguments
      arguments = %{"focus" => "performance"}

      {:error, reason} = Client.get_prompt(client, "code_review", arguments)

      # Check that reason is an error map with message
      assert is_map(reason)

      message =
        case reason do
          %{message: msg} -> msg
          %{"message" => msg} -> msg
          _ -> "#{inspect(reason)}"
        end

      assert String.contains?(message, "Missing required arguments")
      assert String.contains?(message, "code")
      assert String.contains?(message, "language")
    end

    test "prompts/get handles unknown prompt name", %{client: client} do
      {:error, reason} = Client.get_prompt(client, "nonexistent_prompt", %{})

      # Check that reason is an error map with message
      assert is_map(reason)

      message =
        case reason do
          %{message: msg} -> msg
          %{"message" => msg} -> msg
          _ -> "#{inspect(reason)}"
        end

      assert String.contains?(message, "Unknown prompt")
    end

    test "prompts with no arguments work correctly", %{client: client} do
      {:ok, result} = Client.get_prompt(client, "simple_prompt", %{})

      assert %{messages: messages} = result
      assert length(messages) == 1

      message = hd(messages)
      assert message.content.text == "This is a simple prompt."
    end

    test "pagination support (cursor parameter)", %{client: client} do
      # Test that cursor parameter is accepted (even if not used in this simple example)
      {:ok, result} = Client.list_prompts(client, cursor: "some_cursor")

      # Should still work and return prompts
      assert %{prompts: prompts} = result
      assert is_list(prompts)
    end
  end

  describe "prompt notifications compliance" do
    test "notification format is correct" do
      # Test the notification encoding directly
      notification = Protocol.encode_prompts_changed()

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/prompts/list_changed"
      assert notification["params"] == %{}
      # Notifications don't have IDs
      refute Map.has_key?(notification, "id")
    end
  end

  describe "protocol compliance" do
    test "prompts/list protocol format", %{} do
      # Test protocol encoding
      request = Protocol.encode_list_prompts()

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "prompts/list"
      assert Map.has_key?(request, "id")
      assert request["params"] == %{}
    end

    test "prompts/list with cursor protocol format", %{} do
      request = Protocol.encode_list_prompts("test_cursor")

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "prompts/list"
      assert request["params"] == %{"cursor" => "test_cursor"}
    end

    test "prompts/get protocol format", %{} do
      arguments = %{"code" => "test", "language" => "elixir"}
      request = Protocol.encode_get_prompt("code_review", arguments)

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "prompts/get"
      assert request["params"]["name"] == "code_review"
      assert request["params"]["arguments"] == arguments
    end

    test "prompts list changed notification format", %{} do
      notification = Protocol.encode_prompts_changed()

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/prompts/list_changed"
      assert notification["params"] == %{}
      # Notifications don't have IDs
      refute Map.has_key?(notification, "id")
    end
  end

  describe "argument validation compliance" do
    test "validates required vs optional arguments correctly", %{client: client} do
      # Test with all arguments
      {:ok, _} =
        Client.get_prompt(client, "code_review", %{
          "code" => "test",
          "language" => "elixir",
          "focus" => "performance"
        })

      # Test with only required arguments (should work)
      {:ok, _} =
        Client.get_prompt(client, "code_review", %{
          "code" => "test",
          "language" => "elixir"
        })

      # Test with missing required argument (should fail)
      {:error, reason} =
        Client.get_prompt(client, "code_review", %{
          "language" => "elixir"
          # Missing required "code"
        })

      # Check that reason is an error map with message
      assert is_map(reason)

      message =
        case reason do
          %{message: msg} -> msg
          %{"message" => msg} -> msg
          _ -> "#{inspect(reason)}"
        end

      assert String.contains?(message, "Missing required arguments: code")
    end

    test "handles extra unexpected arguments gracefully", %{client: client} do
      # Include extra arguments that aren't defined
      {:ok, result} =
        Client.get_prompt(client, "code_review", %{
          "code" => "test",
          "language" => "elixir",
          "focus" => "readability",
          "extra_arg" => "should_be_ignored"
        })

      # Should still work - extra arguments are ignored
      assert %{messages: messages} = result
      assert is_list(messages)
    end
  end
end
