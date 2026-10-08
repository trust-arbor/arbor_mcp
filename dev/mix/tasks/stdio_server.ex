defmodule Mix.Tasks.StdioServer do
  @moduledoc """
  Mix task to run a stdio MCP server for testing and development.

  ## Usage

      mix stdio_server

  This will start a stdio server that can be used for testing
  with MCP clients via stdin/stdout communication.
  """

  use Mix.Task

  @shortdoc "Runs a stdio MCP server"

  def run(_args) do
    Mix.Task.run("app.config")
    configure_host_logging()
    Mix.Task.run("app.start")

    # Define the server inline to avoid compilation issues
    Code.eval_string("""
    defmodule ExampleStdioServer do
      use Arbor.MCP.Server.Handler
      use Arbor.MCP.Server.DSL, name: "ExampleStdioServer", version: "1.0.0"

      tool "say_hello", "Say hello to someone via stdio" do
        input_schema(%{
          type: "object",
          properties: %{
            name: %{type: "string", description: "Name to greet"}
          },
          required: ["name"]
        })

        run fn %{"name" => name}, state ->
          content = [%{type: "text", text: "Hello, \#{name}! Welcome to Arbor.MCP via stdio! 📝✨"}]
          {:ok, %{content: content}, state}
        end
      end

      tool "echo", "Echo back the input message" do
        input_schema(%{
          type: "object",
          properties: %{
            message: %{type: "string", description: "Message to echo"},
            uppercase: %{type: "boolean", default: false, description: "Convert to uppercase"}
          },
          required: ["message"]
        })

        run fn %{"message" => message} = args, state ->
          result_message =
            if Map.get(args, "uppercase", false), do: String.upcase(message), else: message

          {:ok, %{content: [%{type: "text", text: "Echo: \#{result_message}"}]}, state}
        end
      end

      resource "config://server/info", "Information about this stdio server" do
        title "Server Information"
        mime_type "application/json"

        read fn _params, state ->
          server_info = %{
            name: "ExampleStdioServer",
            version: "1.0.0",
            capabilities: %{"tools" => %{}, "resources" => %{}, "prompts" => %{}}
          }

          {:ok, %{text: Jason.encode!(server_info)}, state}
        end
      end

      prompt "greeting_style", "Generate greetings in different styles" do
        title "Greeting Style Prompt"
        arg(:style, required: true, description: "Greeting style (formal, casual, funny)")
        arg(:name, required: true, description: "Name to greet")

        render fn args, state ->
          style = Map.get(args, "style", "casual")
          name = Map.get(args, "name", "Friend")

          messages =
            case style do
              "formal" ->
                [
                  %{role: "system", content: %{type: "text", text: "You are a formal and professional assistant."}},
                  %{role: "user", content: %{type: "text", text: "Please provide a formal greeting for \#{name}"}},
                  %{role: "assistant", content: %{type: "text", text: "Good day, \#{name}. I hope this message finds you well."}}
                ]

              "funny" ->
                [
                  %{role: "system", content: %{type: "text", text: "You are a humorous and playful assistant."}},
                  %{role: "user", content: %{type: "text", text: "Give \#{name} a funny greeting"}},
                  %{role: "assistant", content: %{type: "text", text: "Hey there, \#{name}! *tips hat* Ready to conquer the world... or at least this conversation? 😄"}}
                ]

              _ ->
                [
                  %{role: "system", content: %{type: "text", text: "You are a friendly and casual assistant."}},
                  %{role: "user", content: %{type: "text", text: "Say hi to \#{name} in a casual way"}},
                  %{role: "assistant", content: %{type: "text", text: "Hey \#{name}! How's it going? Great to see you here! 👋"}}
                ]
            end

          {:ok, %{messages: messages}, state}
        end
      end
    end
    """)

    # Get the configured protocol version
    protocol_version = Application.get_env(:arbor_mcp, :protocol_version, "2025-03-26")

    IO.puts(:stderr, """
    📡 Arbor.MCP stdio Server Ready!

    Example usage with Arbor.MCP client:
    {"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"#{protocol_version}","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}},"id":1}
    {"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}
    {"jsonrpc":"2.0","method":"tools/call","params":{"name":"say_hello","arguments":{"name":"World"}},"id":3}

    Press Ctrl+D to exit.
    """)

    # Start the server using the standard STDIO transport
    # The module is defined dynamically above, so we need to call it dynamically
    server_module = Module.concat(["ExampleStdioServer"])
    {:ok, _server} = server_module.start_link(transport: :stdio, stdio_startup_delay: 10)

    # Keep the process alive
    Process.sleep(:infinity)
  end

  # This standalone command owns its VM's default logger handler. Preserve
  # its level, formatter and filters while routing diagnostics away from JSON-RPC.
  defp configure_host_logging do
    {:ok, %{module: :logger_std_h} = handler} = :logger.get_handler_config(:default)

    config =
      handler
      |> Map.drop([:id, :module])
      |> Map.update!(:config, &Map.put(&1, :type, :standard_error))

    # Mix app.start restarts Logger, so persist this host-owned boot policy too.
    boot_config =
      config
      |> Map.put(:module, :logger_std_h)
      |> Map.update!(:config, &Map.to_list/1)
      |> Map.to_list()

    Application.put_env(:logger, :default_handler, boot_config)
    :ok = :logger.remove_handler(:default)
    :ok = :logger.add_handler(:default, :logger_std_h, config)
  end
end
