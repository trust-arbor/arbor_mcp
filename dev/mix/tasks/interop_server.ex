defmodule Mix.Tasks.InteropServer do
  @moduledoc """
  Mix task to run a stdio MCP server for interop testing.

  ## Usage

      mix interop_server
      mix interop_server modern

  Starts a minimal MCP server on stdio for cross-language interop tests. The
  optional `modern` argument pins the server to MCP 2026-07-28 and enables the
  MRTR and subscription fixtures used by the TypeScript SDK v2 tests.
  """

  use Mix.Task

  @shortdoc "Runs a stdio MCP server for interop testing"

  def run(args) do
    modern? = "modern" in args

    app_start_args =
      if "--no-compile" in args, do: ["--no-compile", "--no-deps-check"], else: []

    Mix.Task.run("app.config", app_start_args)
    configure_host_logging()
    Mix.Task.run("app.start", app_start_args)

    Code.eval_string(~S"""
    defmodule InteropHandler do
      use Arbor.MCP.Server.Handler
      use Arbor.MCP.Server.DSL, name: "elixir-interop-server", version: "1.0.0"

      alias Arbor.MCP.Server.Context

      def __server_info__, do: %{name: "elixir-interop-server", version: "1.0.0"}

      tool "echo", "Echoes back the input message" do
        param :message, :string, required: true, description: "Message to echo"

        run fn %{message: message}, state ->
          {:ok, "Echo: #{message}", state}
        end
      end

      tool "add", "Adds two numbers" do
        param :a, :number, required: true, description: "First number"
        param :b, :number, required: true, description: "Second number"

        run fn %{a: a, b: b}, state ->
          {:ok, to_string(a + b), state}
        end
      end

      tool "inspect_context", "Returns the validated request context" do
        run fn _arguments, state ->
          context = Context.current()

          result = %{
            "protocolVersion" => context.protocol_version,
            "clientInfo" => context.client_info,
            "clientCapabilities" => context.client_capabilities
          }

          {:ok, Jason.encode!(result), state}
        end
      end

      tool "onboard", "Collects a display name through an MCP 2026 MRTR flow" do
        run fn _arguments, state ->
          case Context.input_responses() do
            nil ->
              requests = %{
                "profile" => %{
                  "method" => "elicitation/create",
                  "params" => %{
                    "message" => "Choose an Arbor.MCP interop display name",
                    "requestedSchema" => %{
                      "type" => "object",
                      "properties" => %{"name" => %{"type" => "string"}},
                      "required" => ["name"]
                    }
                  }
                }
              }

              {:ok,
               Arbor.MCP.Server.DSL.Result.input_required(requests, %{"server" => "ex_mcp"}), state}

            %{"profile" => %{"content" => %{"name" => name}}} ->
              {:ok, "#{name}:#{Context.request_state()["server"]}", state}
          end
        end
      end

      tool "publish_tools_changed", "Publishes a tools list-changed notification" do
        run fn _arguments, state ->
          Arbor.MCP.Server.notify_tools_changed(self())
          {:ok, "published", state}
        end
      end

      resource "test://greeting", "A test greeting resource" do
        name "Greeting"
        mime_type "text/plain"

        read fn _params, state ->
          {:ok, "Hello from Elixir!", state}
        end
      end

      prompt "simple_prompt", "A simple test prompt" do
        render fn _args, state ->
          {:ok, "This is a test prompt from Elixir", state}
        end
      end

      def handle_request("ping", _params, state) do
        {:reply, %{}, state}
      end

      def handle_request("notifications/initialized", _params, state) do
        {:noreply, state}
      end

      def handle_request(method, _params, state) do
        {:error, %{code: -32601, message: "Method not found: #{method}"}, state}
      end
    end
    """)

    # Start the server using StdioServer with the handler module
    server_opts =
      [module: InteropHandler]
      |> maybe_enable_modern(modern?)

    {:ok, server} = Arbor.MCP.Server.StdioServer.start_link(server_opts)

    # Exit with the transport instead of leaving a nested BEAM VM behind after
    # the SDK closes its end of the stdio pipe.
    server_ref = Process.monitor(server)

    receive do
      {:DOWN, ^server_ref, :process, ^server, _reason} -> :ok
    end
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

  defp maybe_enable_modern(opts, false), do: opts

  defp maybe_enable_modern(opts, true) do
    Keyword.merge(opts,
      protocol_mode: :modern_only,
      mrtr: true,
      request_state: [
        active_key_id: "interop",
        keys: %{"interop" => :binary.copy(<<77>>, 32)}
      ]
    )
  end
end
