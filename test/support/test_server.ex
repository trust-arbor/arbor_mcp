defmodule Arbor.MCP.TestServer do
  @moduledoc """
  A minimal, isolated test server that does not `use Arbor.MCP.Server`.

  This server is a pure GenServer that mimics the behavior of a real MCP
  server for integration testing purposes. It avoids the `use Arbor.MCP.Server`
  macro when tests need complete process isolation.
  """
  use GenServer

  #
  # GenServer API
  #

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def init(opts) do
    state =
      opts
      |> Map.new()
      |> Map.put_new(:subscriptions, MapSet.new())

    {:ok, state}
  end

  #
  # GenServer Callbacks
  #

  @impl true
  def handle_call(:get_tools, _from, state) do
    {:reply, tools(), state}
  end

  @impl true
  def handle_call(:get_resources, _from, state) do
    {:reply, resources(), state}
  end

  @impl true
  def handle_call(:get_prompts, _from, state) do
    {:reply, prompts(), state}
  end

  @impl true
  def handle_call(:get_capabilities, _from, state) do
    capabilities =
      %{}
      |> maybe_add_tools_capability()
      |> maybe_add_resources_capability()
      |> maybe_add_prompts_capability()

    {:reply, capabilities, state}
  end

  @impl true
  def handle_call({:handle_call_tool, tool_name, arguments}, _from, state) do
    result = do_handle_call_tool(tool_name, arguments, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:handle_read_resource, uri, full_uri}, _from, state) do
    case do_handle_read_resource(uri, full_uri, state) do
      {:ok, content, new_state} ->
        {:reply, {:ok, content, new_state}, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason, new_state}, new_state}
    end
  end

  @impl true
  def handle_call({:handle_get_prompt, prompt_name, arguments}, _from, state) do
    result = do_handle_get_prompt(prompt_name, arguments, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:handle_request, "resources/list", _params}, _from, state) do
    {:ok, resources, new_state} = do_handle_resource_list(state)
    response_payload = %{resources: resources}
    result = {:reply, response_payload, new_state}
    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:handle_request, "prompts/list", _params}, _from, state) do
    {:ok, prompts, new_state} = do_handle_prompt_list(state)
    response_payload = %{prompts: prompts}
    result = {:reply, response_payload, new_state}
    {:reply, result, new_state}
  end

  @impl true
  def handle_call(request, _from, state) do
    {:reply, {:error, {:unknown_call, request}}, state}
  end

  #
  # Private data definitions (replaces DSL)
  #

  defp tools do
    %{
      "echo" => %{
        name: "echo",
        description: "Echoes the input message",
        input_schema: %{
          "type" => "object",
          "properties" => %{"message" => %{"type" => "string"}},
          "required" => ["message"]
        }
      },
      "add" => %{
        name: "add",
        description: "Adds two numbers",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "a" => %{"type" => "number"},
            "b" => %{"type" => "number"}
          },
          "required" => ["a", "b"]
        }
      },
      "greet" => %{
        name: "greet",
        description: "Greets a person by name",
        input_schema: %{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}},
          "required" => ["name"]
        }
      }
    }
  end

  defp resources do
    %{
      "test://config" => %{
        uri: "test://config",
        name: "Test Configuration",
        description: "Test configuration data",
        mime_type: "application/json",
        list_pattern: false,
        subscribable: false
      },
      "test://data.txt" => %{
        uri: "test://data.txt",
        name: "Test Data",
        description: "Simple text data",
        mime_type: "text/plain",
        list_pattern: false,
        subscribable: false
      },
      "test://logs/*" => %{
        uri: "test://logs/*",
        name: "Test Logs",
        description: "Test log files",
        mime_type: "text/plain",
        list_pattern: true,
        subscribable: false
      }
    }
  end

  defp prompts do
    %{
      "greeting" => %{
        name: "greeting",
        description: "A template for greetings",
        arguments: [
          %{name: :style, description: "Greeting style (formal/casual)", required: false},
          %{name: :name, description: "Person to greet", required: true}
        ]
      },
      "code_review" => %{
        name: "code_review",
        description: "Reviews code snippets",
        arguments: [
          %{name: :code, description: "Code to review", required: true},
          %{name: :language, description: "Programming language", required: false}
        ]
      }
    }
  end

  #
  # Private handler implementations
  #

  defp do_handle_call_tool("echo", %{"message" => message}, state) do
    result = %{content: [text("Echo: #{message}")]}
    {:ok, result, state}
  end

  defp do_handle_call_tool("add", %{"a" => a, "b" => b}, state) do
    sum = a + b
    result = %{content: [text("#{a} + #{b} = #{sum}")]}
    {:ok, result, state}
  end

  defp do_handle_call_tool("greet", %{"name" => name}, state) do
    result = %{content: [text("Hello, #{name}!")]}
    {:ok, result, state}
  end

  defp do_handle_call_tool(_name, _args, state) do
    {:error, "Unknown tool", state}
  end

  defp do_handle_read_resource("test://config", _uri, state) do
    config =
      json(%{
        environment: "test",
        debug: true,
        port: 8080,
        features: ["tools", "resources", "prompts"]
      })

    {:ok, [config], state}
  end

  defp do_handle_read_resource("test://data.txt", _uri, state) do
    content = [text("This is test data from the test server.\nLine 2 of test data.")]
    {:ok, content, state}
  end

  defp do_handle_read_resource("test://logs/" <> filename, _uri, state) do
    content = [text("Log file: #{filename}\n[INFO] Test log entry 1\n[WARN] Test log entry 2")]
    {:ok, content, state}
  end

  defp do_handle_read_resource(_uri, _original_uri, state) do
    {:error, "Resource not found", state}
  end

  defp do_handle_get_prompt("greeting", args, state) do
    name = Map.get(args, "name", "friend")
    style = Map.get(args, "style", "casual")

    greeting =
      case style do
        "formal" -> "Good day, #{name}. I hope this message finds you well."
        _ -> "Hey #{name}! How's it going?"
      end

    messages = [
      user("Please greet #{name} in a #{style} style"),
      assistant(greeting)
    ]

    {:ok, %{messages: messages}, state}
  end

  defp do_handle_get_prompt("code_review", args, state) do
    code = Map.get(args, "code", "")
    language = Map.get(args, "language", "unknown")

    messages = [
      user("Please review this #{language} code:\n\n#{code}"),
      assistant("I'll review your #{language} code for style, correctness, and best practices.")
    ]

    {:ok, %{messages: messages}, state}
  end

  defp do_handle_resource_list(state) do
    resources = [
      %{uri: "test://config", name: "Test Configuration"},
      %{uri: "test://data.txt", name: "Test Data"},
      %{uri: "test://logs/app.log", name: "Application Log"},
      %{uri: "test://logs/error.log", name: "Error Log"}
    ]

    {:ok, resources, state}
  end

  defp do_handle_prompt_list(state) do
    prompts = [
      %{name: "greeting", description: "A template for greetings"},
      %{name: "code_review", description: "Reviews code snippets"}
    ]

    {:ok, prompts, state}
  end

  #
  # Private content helpers
  #

  defp text(text_content) do
    %{type: "text", text: text_content}
  end

  defp json(data) do
    %{type: "text", data: data}
  end

  defp user(content) do
    %{role: "user", content: content}
  end

  defp assistant(content) do
    %{role: "assistant", content: content}
  end

  #
  # Private capability helpers
  #

  defp maybe_add_tools_capability(capabilities) do
    case tools() do
      tools when map_size(tools) > 0 ->
        Map.put(capabilities, "tools", %{"listChanged" => true})

      _ ->
        capabilities
    end
  end

  defp maybe_add_resources_capability(capabilities) do
    case resources() do
      resources when map_size(resources) > 0 ->
        subscribable = Enum.any?(Map.values(resources), & &1.subscribable)

        Map.put(capabilities, "resources", %{
          "subscribe" => subscribable,
          "listChanged" => true
        })

      _ ->
        capabilities
    end
  end

  defp maybe_add_prompts_capability(capabilities) do
    case prompts() do
      prompts when map_size(prompts) > 0 ->
        Map.put(capabilities, "prompts", %{"listChanged" => true})

      _ ->
        capabilities
    end
  end
end
