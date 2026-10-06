defmodule Arbor.MCP.Helpers do
  @moduledoc """
  Helper macros and functions for common MCP patterns in ArborMCP.

  This module provides convenient macros and utilities to reduce boilerplate
  and improve developer experience when working with MCP clients and servers.

  ## Features

  - Connection management macros with automatic cleanup
  - Tool calling with pattern matching and error handling
  - Resource reading with automatic parsing
  - Batch operation helpers with timeout management
  - Testing utilities for MCP development

  ## Usage

      use Arbor.MCP.Helpers

      # Use helper macros
      with_mcp_client "http://localhost:8080" do
        tools = list_tools!()
        result = call_tool!("calculator", %{op: "add", a: 1, b: 2})
      end
  """

  alias Arbor.MCP.Client.Error
  alias Arbor.MCP.Content.SchemaPolicy

  @doc """
  Imports helper macros into the calling module.
  """
  defmacro __using__(_opts) do
    quote do
      import Arbor.MCP.Helpers
      alias Arbor.MCP, as: MCP
    end
  end

  @doc """
  Establishes an MCP connection and executes a block with automatic cleanup.

  ## Examples

      with_mcp_client "http://localhost:8080" do
        tools = list_tools!()
        IO.inspect(tools)
      end

      # With options
      with_mcp_client "http://localhost:8080", timeout: 10_000 do
        result = call_tool!("slow_operation", %{})
      end

      # With fallback
      with_mcp_client ["http://primary:8080", "http://backup:8080"] do
        status = get_status!()
      end
  """
  defmacro with_mcp_client(connection_spec, opts \\ [], do: block) do
    quote do
      case Arbor.MCP.connect(unquote(connection_spec), unquote(opts)) do
        {:ok, client} ->
          try do
            var!(client) = client
            unquote(block)
          after
            Arbor.MCP.disconnect(client)
          end

        {:error, reason} ->
          raise Arbor.MCP.ConnectionError, "Failed to connect: #{inspect(reason)}"
      end
    end
  end

  @doc """
  Lists tools with error handling. Raises on failure.

  Must be used within a `with_mcp_client` block or with an explicit client.
  """
  defmacro list_tools!(opts \\ []) do
    quote do
      case Arbor.MCP.tools(var!(client), unquote(opts)) do
        {:ok, tools} -> tools
        {:error, error} -> raise Arbor.MCP.ToolError, format_error_message(error)
      end
    end
  end

  @doc """
  Calls a tool with error handling. Raises on failure.

  ## Examples

      result = call_tool!("calculator", %{op: "add", a: 1, b: 2})

      # With timeout
      result = call_tool!("slow_tool", %{data: "..."}, timeout: 30_000)
  """
  defmacro call_tool!(tool_name, args \\ quote(do: %{}), opts \\ []) do
    quote do
      case Arbor.MCP.call(
             var!(client),
             unquote(tool_name),
             unquote(args),
             unquote(opts)
           ) do
        {:ok, result} -> result
        {:error, error} -> raise Arbor.MCP.ToolError, format_error_message(error)
      end
    end
  end

  @doc """
  Lists resources with error handling. Raises on failure.
  """
  defmacro list_resources!(opts \\ []) do
    quote do
      case Arbor.MCP.resources(var!(client), unquote(opts)) do
        {:ok, resources} -> resources
        {:error, error} -> raise Arbor.MCP.ResourceError, format_error_message(error)
      end
    end
  end

  @doc """
  Reads a resource with error handling. Raises on failure.

  ## Examples

      content = read_resource!("file://data.txt")

      # With JSON parsing
      data = read_resource!("file://config.json", parse_json: true)
  """
  defmacro read_resource!(uri, opts \\ []) do
    quote do
      case Arbor.MCP.read(var!(client), unquote(uri), unquote(opts)) do
        {:ok, content} -> content
        {:error, error} -> raise Arbor.MCP.ResourceError, format_error_message(error)
      end
    end
  end

  @doc """
  Lists prompts with error handling. Raises on failure.
  """
  defmacro list_prompts!(opts \\ []) do
    quote do
      case Arbor.MCP.prompts(var!(client), unquote(opts)) do
        prompts when is_list(prompts) -> prompts
        {:error, error} -> raise Arbor.MCP.PromptError, format_error_message(error)
      end
    end
  end

  @doc """
  Gets a prompt with error handling. Raises on failure.
  """
  defmacro get_prompt!(prompt_name, args \\ quote(do: %{}), opts \\ []) do
    quote do
      case Arbor.MCP.prompt(
             var!(client),
             unquote(prompt_name),
             unquote(args),
             unquote(opts)
           ) do
        {:error, error} -> raise Arbor.MCP.PromptError, format_error_message(error)
        result -> result
      end
    end
  end

  @doc """
  Gets client status with error handling. Raises on failure.
  """
  defmacro get_status! do
    quote do
      case Arbor.MCP.status(var!(client)) do
        {:ok, status} -> status
        {:error, error} -> raise Arbor.MCP.ClientError, "Failed to get status: #{inspect(error)}"
      end
    end
  end

  @doc """
  Executes batch operations with error handling.

  ## Examples

      results = batch_execute!([
        {:call_tool, "greet", %{name: "Alice"}},
        {:call_tool, "greet", %{name: "Bob"}},
        {:list_resources, %{}}
      ])
  """
  defmacro batch_execute!(operations, opts \\ []) do
    quote do
      Arbor.MCP.batch(var!(client), unquote(operations), unquote(opts))
    end
  end

  @doc """
  Retries an operation with exponential backoff.

  ## Examples

      result = retry max_attempts: 3, base_delay: 1000 do
        call_tool!("unreliable_tool", %{})
      end
  """
  defmacro retry(opts \\ [], do: block) do
    quote do
      Arbor.MCP.Helpers.do_retry(
        fn -> unquote(block) end,
        unquote(opts)
      )
    end
  end

  @doc """
  Measures execution time of an operation.

  ## Examples

      {result, time_ms} = measure do
        call_tool!("slow_operation", %{})
      end

      IO.puts("Operation took \#{time_ms}ms")
  """
  defmacro measure(do: block) do
    quote do
      start_time = System.monotonic_time(:millisecond)
      result = unquote(block)
      end_time = System.monotonic_time(:millisecond)
      {result, end_time - start_time}
    end
  end

  @doc """
  Creates a testing context with a mock MCP server.

  ## Examples

      with_mock_server tools: [%{name: "test_tool"}] do
        tools = list_tools!()
        assert length(tools) == 1
      end
  """
  defmacro with_mock_server(opts \\ [], do: block) do
    quote do
      Arbor.MCP.Testing.with_mock_server(unquote(opts), fn client ->
        var!(client) = client
        unquote(block)
      end)
    end
  end

  # Runtime Functions

  @doc """
  Implements retry logic with exponential backoff.
  """
  @spec do_retry((-> any()), keyword()) :: any()
  def do_retry(fun, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 3)
    base_delay = Keyword.get(opts, :base_delay, 1000)
    max_delay = Keyword.get(opts, :max_delay, 30_000)

    do_retry_attempt(fun, 1, max_attempts, base_delay, max_delay)
  end

  defp do_retry_attempt(fun, attempt, max_attempts, base_delay, max_delay) do
    fun.()
  rescue
    error ->
      if attempt < max_attempts and max_attempts > 0 do
        delay = min(base_delay * :math.pow(2, attempt - 1), max_delay)
        Process.sleep(round(max(delay, 0)))
        do_retry_attempt(fun, attempt + 1, max_attempts, base_delay, max_delay)
      else
        reraise error, __STACKTRACE__
      end
  end

  @doc """
  Formats an error message for display.
  """
  @spec format_error_message(map() | any()) :: String.t()
  def format_error_message(%{message: message, suggestions: suggestions}) do
    base = message

    if is_list(suggestions) and Enum.any?(suggestions) do
      suggestion_text = Error.format_suggestions(suggestions)
      "#{base}\n\nSuggestions:\n#{suggestion_text}"
    else
      base
    end
  end

  def format_error_message(error), do: inspect(error)

  @doc """
  Validates tool arguments against schema.
  """
  @spec validate_tool_args(map(), map() | boolean()) :: :ok | {:error, String.t()}
  def validate_tool_args(args, schema)
      when is_map(args) and (is_map(schema) or is_boolean(schema)) do
    case SchemaPolicy.validate(args, schema) do
      :ok ->
        :ok

      {:error, reason} when is_tuple(reason) or is_atom(reason) ->
        {:error, SchemaPolicy.format_error(reason)}

      {:error, errors} ->
        {:error, format_validation_errors(errors)}
    end
  end

  def validate_tool_args(_, _), do: :ok

  defp format_validation_errors(errors) when is_list(errors) do
    errors
    |> Enum.map_join(", ", fn
      {error, path} when is_list(path) ->
        "#{Enum.join(path, ".")}: #{error}"

      {error, path} ->
        "#{path}: #{error}"

      error ->
        "#{error}"
    end)
  end

  defp format_validation_errors(errors), do: inspect(errors)

  @doc """
  Safely executes an operation with timeout.
  """
  @spec safe_execute((-> any()), timeout()) :: {:ok, any()} | {:error, :timeout}
  def safe_execute(fun, timeout \\ 5_000) do
    task = Task.async(fun)

    case Task.yield(task, timeout) do
      {:ok, result} ->
        {:ok, result}

      {:exit, _reason} ->
        Task.shutdown(task)
        {:error, :timeout}

      nil ->
        Task.shutdown(task)
        {:error, :timeout}
    end
  end
end

# Custom exception types for better error handling

defmodule Arbor.MCP.ConnectionError do
  @moduledoc "Raised when MCP connection fails"
  defexception [:message]
end

defmodule Arbor.MCP.ToolError do
  @moduledoc "Raised when tool operations fail"
  defexception [:message]
end

defmodule Arbor.MCP.ResourceError do
  @moduledoc "Raised when resource operations fail"
  defexception [:message]
end

defmodule Arbor.MCP.PromptError do
  @moduledoc "Raised when prompt operations fail"
  defexception [:message]
end

defmodule Arbor.MCP.ClientError do
  @moduledoc "Raised when client operations fail"
  defexception [:message]
end
