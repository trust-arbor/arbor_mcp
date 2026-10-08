defmodule Arbor.MCP.PromptsTest do
  use ExUnit.Case, async: true

  @moduletag :prompts

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule TestPromptsHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_args) do
      {:ok, %{prompts: default_prompts()}}
    end

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-03-26",
         serverInfo: %{
           name: "test-prompts-server",
           version: "1.0.0"
         },
         capabilities: %{
           prompts: %{
             listChanged: true
           }
         }
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      {:ok, [], nil, state}
    end

    @impl true
    def handle_call_tool(_name, _arguments, state) do
      {:error, "No tools available", state}
    end

    @impl true
    def handle_list_prompts(cursor, state) do
      prompts = state.prompts

      # Simple pagination: return 2 prompts at a time
      case cursor do
        nil ->
          {:ok, Enum.take(prompts, 2), "page2", state}

        "page2" ->
          {:ok, Enum.drop(prompts, 2), nil, state}

        _ ->
          {:error, "Invalid cursor", state}
      end
    end

    @impl true
    def handle_get_prompt(name, arguments, state) do
      case find_prompt(name, state.prompts) do
        nil ->
          {:error, "Prompt not found: #{name}", state}

        prompt ->
          messages = generate_prompt_messages(prompt, arguments)
          {:ok, %{messages: messages}, state}
      end
    end

    defp default_prompts do
      [
        %{
          name: "code_review",
          description: "Generate a code review for the given code",
          arguments: [
            %{
              name: "language",
              description: "Programming language",
              required: true
            },
            %{
              name: "code",
              description: "Code to review",
              required: true
            }
          ]
        },
        %{
          name: "explain_concept",
          description: "Explain a programming concept",
          arguments: [
            %{
              name: "concept",
              description: "Concept to explain",
              required: true
            },
            %{
              name: "level",
              description: "Explanation level (beginner, intermediate, advanced)",
              required: false
            }
          ]
        },
        %{
          name: "generate_tests",
          description: "Generate unit tests for code",
          arguments: [
            %{
              name: "code",
              description: "Code to test",
              required: true
            },
            %{
              name: "framework",
              description: "Testing framework to use",
              required: false
            }
          ]
        }
      ]
    end

    defp find_prompt(name, prompts) do
      Enum.find(prompts, fn p -> p.name == name end)
    end

    defp generate_prompt_messages(prompt, arguments) do
      case prompt.name do
        "code_review" ->
          [
            %{
              role: "user",
              content: %{
                type: "text",
                text:
                  "Please review the following #{arguments["language"]} code:\n\n```#{arguments["language"]}\n#{arguments["code"]}\n```"
              }
            }
          ]

        "explain_concept" ->
          level = arguments["level"] || "intermediate"

          [
            %{
              role: "user",
              content: %{
                type: "text",
                text:
                  "Please explain the concept of '#{arguments["concept"]}' at a #{level} level."
              }
            }
          ]

        "generate_tests" ->
          framework = arguments["framework"] || "default"

          [
            %{
              role: "user",
              content: %{
                type: "text",
                text: "Generate #{framework} unit tests for:\n\n```\n#{arguments["code"]}\n```"
              }
            }
          ]

        _ ->
          [
            %{
              role: "user",
              content: %{
                type: "text",
                text: "Prompt: #{prompt.name}"
              }
            }
          ]
      end
    end
  end

  setup do
    # Start server with prompts handler using BEAM transport
    {:ok, server} =
      Server.start_link(
        transport: :test,
        handler: TestPromptsHandler
      )

    # Start client connecting to the server
    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server
      )

    # Wait for initialization
    Process.sleep(100)

    %{server: server, client: client}
  end

  describe "prompts functionality" do
    test "client can list prompts with pagination", %{client: client} do
      # First page - use consistent Response struct access
      {:ok, result1} = Client.list_prompts(client)
      page1 = result1.prompts
      # Use the actual nextCursor from the response
      cursor = result1.nextCursor
      assert length(page1) == 2

      # Check first page prompts - access nested maps by string keys
      assert Map.get(Enum.at(page1, 0), "name") == "code_review"
      assert Map.get(Enum.at(page1, 1), "name") == "explain_concept"

      # Second page
      {:ok, result2} = Client.list_prompts(client, cursor: cursor)
      page2 = result2.prompts
      assert length(page2) == 1
      assert Map.get(Enum.at(page2, 0), "name") == "generate_tests"
    end

    test "client can get a prompt with arguments", %{client: client} do
      # Get code review prompt
      arguments = %{
        "language" => "elixir",
        "code" => "def add(a, b), do: a + b"
      }

      {:ok, result} = Client.get_prompt(client, "code_review", arguments)
      messages = result.messages
      assert length(messages) == 1

      message = hd(messages)
      assert message.role == "user"
      assert message.content.type == "text"
      assert message.content.text =~ "review the following elixir code"
      assert message.content.text =~ "def add(a, b), do: a + b"
    end

    test "get_prompt returns error for unknown prompt", %{client: client} do
      {:error, error} = Client.get_prompt(client, "unknown_prompt", %{})
      assert error.message =~ "Prompt not found: unknown_prompt"
    end

    test "get_prompt works with optional arguments", %{client: client} do
      # Without optional level
      {:ok, result1} = Client.get_prompt(client, "explain_concept", %{"concept" => "recursion"})
      assert hd(result1.messages).content.text =~ "intermediate level"

      # With optional level
      {:ok, result2} =
        Client.get_prompt(client, "explain_concept", %{
          "concept" => "recursion",
          "level" => "beginner"
        })

      assert hd(result2.messages).content.text =~ "beginner level"
    end

    test "prompts support embedded resources", %{client: client} do
      # Test with generate_tests prompt
      {:ok, result} =
        Client.get_prompt(client, "generate_tests", %{
          "code" => "function factorial(n) { return n <= 1 ? 1 : n * factorial(n - 1); }",
          "framework" => "jest"
        })

      messages = result.messages
      assert length(messages) == 1
      message = hd(messages)
      assert message.content.text =~ "jest unit tests"
      assert message.content.text =~ "factorial"
    end
  end
end
