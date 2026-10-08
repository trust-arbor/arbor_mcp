defmodule Arbor.MCP.ProgressIntegrationTest do
  use ExUnit.Case, async: true

  @moduletag :progress

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule TestProgressHandler do
    use Arbor.MCP.Server.Handler
    require Logger

    @impl true
    def init(_args) do
      {:ok, %{}}
    end

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-03-26",
         serverInfo: %{
           name: "test-progress-server",
           version: "1.0.0"
         },
         capabilities: %{
           tools: %{}
         }
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      tools = [
        %{
          name: "long_operation",
          description: "A long-running operation that reports progress",
          inputSchema: %{
            type: "object",
            properties: %{
              steps: %{type: "integer", minimum: 1, maximum: 10},
              delay: %{type: "integer", minimum: 100, maximum: 1000}
            },
            required: ["steps"]
          }
        },
        %{
          name: "download_file",
          description: "Simulates file download with progress",
          inputSchema: %{
            type: "object",
            properties: %{
              url: %{type: "string"},
              size: %{type: "integer"}
            },
            required: ["url", "size"]
          }
        },
        %{
          name: "process_batch",
          description: "Process items in batch with progress",
          inputSchema: %{
            type: "object",
            properties: %{
              items: %{type: "array", items: %{type: "string"}}
            },
            required: ["items"]
          }
        }
      ]

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool(name, arguments, state) do
      # Extract progress token from meta
      progress_token = get_in(arguments, ["_meta", "progressToken"])

      case name do
        "long_operation" ->
          handle_long_operation(arguments, progress_token, state)

        "download_file" ->
          handle_download(arguments, progress_token, state)

        "process_batch" ->
          handle_batch_processing(arguments, progress_token, state)

        _ ->
          {:error, "Unknown tool: #{name}", state}
      end
    end

    # Progress notifications are emitted from a detached task, so tests cannot
    # observe them through the tool reply. Each step is therefore also echoed
    # to the process named in the optional "reply_to" argument, which lets the
    # tests use assert_receive instead of sleeping for a guessed duration.
    defp report(args, message) do
      case Map.get(args, "reply_to") do
        nil -> :ok
        encoded -> send(:erlang.list_to_pid(String.to_charlist(encoded)), message)
      end
    end

    defp handle_long_operation(%{"steps" => steps} = args, progress_token, state) do
      delay = Map.get(args, "delay", 0)

      if progress_token do
        # Start async task to report progress
        Task.start(fn ->
          for i <- 1..steps do
            if delay > 0, do: Process.sleep(delay)
            progress = div(i * 100, steps)
            Arbor.MCP.Server.notify_progress(self(), progress_token, progress, 100)
            Logger.debug("Progress #{progress_token}: #{progress}%")
            report(args, {:progress_step, progress_token, progress, 100})
          end

          report(args, {:progress_done, progress_token})
        end)
      end

      {:ok,
       [
         %{
           type: "text",
           text: "Started long operation with #{steps} steps"
         }
       ], state}
    end

    defp handle_download(%{"url" => url, "size" => size} = args, progress_token, state) do
      if progress_token do
        # Simulate download progress
        Task.start(fn ->
          chunks = 10
          chunk_size = div(size, chunks)

          for i <- 1..chunks do
            downloaded = i * chunk_size
            Arbor.MCP.Server.notify_progress(self(), progress_token, downloaded, size)
            Logger.debug("Download #{progress_token}: #{downloaded}/#{size} bytes")
            report(args, {:progress_step, progress_token, downloaded, size})
          end

          report(args, {:progress_done, progress_token})
        end)
      end

      {:ok,
       [
         %{
           type: "text",
           text: "Downloading #{url} (#{size} bytes)"
         }
       ], state}
    end

    defp handle_batch_processing(%{"items" => items} = args, progress_token, state) do
      total = length(items)

      if progress_token != nil and total > 0 do
        # Process items with progress
        Task.start(fn ->
          items
          |> Enum.with_index(1)
          |> Enum.each(fn {_item, index} ->
            Arbor.MCP.Server.notify_progress(self(), progress_token, index, total)
            Logger.debug("Batch #{progress_token}: #{index}/#{total}")
            report(args, {:progress_step, progress_token, index, total})
          end)

          report(args, {:progress_done, progress_token})
        end)
      end

      {:ok,
       [
         %{
           type: "text",
           text: "Processing #{total} items"
         }
       ], state}
    end
  end

  # Test client handler to capture progress notifications
  defmodule TestProgressClient do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    def get_progress_updates(pid) do
      GenServer.call(pid, :get_progress_updates)
    end

    @impl true
    def init(_opts) do
      {:ok, %{progress_updates: []}}
    end

    @impl true
    def handle_info({:notification, "notifications/progress", params}, state) do
      update = %{
        token: params["progressToken"],
        progress: params["progress"],
        total: params["total"]
      }

      {:noreply, %{state | progress_updates: [update | state.progress_updates]}}
    end

    def handle_info(_msg, state) do
      {:noreply, state}
    end

    @impl true
    def handle_call(:get_progress_updates, _from, state) do
      # Return in chronological order
      {:reply, Enum.reverse(state.progress_updates), state}
    end
  end

  setup do
    # Start server with progress handler
    {:ok, server} =
      Server.start_link(
        transport: :test,
        handler: TestProgressHandler
      )

    # Start client
    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server
      )

    # Start progress tracking process
    {:ok, tracker} = TestProgressClient.start_link([])

    # Client.start_link/1 handshakes inside init/1 — nothing to wait for.
    assert {:ok, %{connection_status: :ready}} = Client.get_status(client)

    # Encoded test pid handed to the handler so it can echo progress steps.
    reply_to = self() |> :erlang.pid_to_list() |> List.to_string()

    %{server: server, client: client, tracker: tracker, reply_to: reply_to}
  end

  describe "progress notifications" do
    test "tool execution with progress updates", %{client: client, reply_to: reply_to} do
      # Call tool with progress token
      progress_token = "test-#{System.unique_integer()}"

      {:ok, result} =
        Client.call_tool(client, "long_operation", %{"steps" => 5, "reply_to" => reply_to},
          progress_token: progress_token
        )

      assert hd(result.content).text =~ "Started long operation with 5 steps"

      # Every step is reported, monotonically increasing, ending at 100%.
      for expected <- [20, 40, 60, 80, 100] do
        assert_receive {:progress_step, ^progress_token, ^expected, 100}, 2_000
      end

      assert_receive {:progress_done, ^progress_token}, 2_000
    end

    test "tool without progress token doesn't send notifications", %{
      client: client,
      reply_to: reply_to
    } do
      # Call without progress token
      {:ok, result} =
        Client.call_tool(client, "long_operation", %{"steps" => 3, "reply_to" => reply_to})

      assert hd(result.content).text =~ "Started long operation with 3 steps"

      # No progress task is started at all, so nothing is ever reported.
      refute_receive {:progress_step, _, _, _}, 200
    end

    test "download simulation with byte progress", %{client: client, reply_to: reply_to} do
      progress_token = "download-#{System.unique_integer()}"

      {:ok, result} =
        Client.call_tool(
          client,
          "download_file",
          %{
            "url" => "https://example.com/file.zip",
            "size" => 1_000_000,
            "reply_to" => reply_to
          },
          progress_token: progress_token
        )

      assert hd(result.content).text =~ "Downloading"
      assert hd(result.content).text =~ "1000000 bytes"

      # Ten chunks, byte counts rather than percentages.
      for chunk <- 1..10 do
        expected = chunk * 100_000
        assert_receive {:progress_step, ^progress_token, ^expected, 1_000_000}, 2_000
      end

      assert_receive {:progress_done, ^progress_token}, 2_000
    end

    test "batch processing with item count progress", %{client: client, reply_to: reply_to} do
      progress_token = "batch-#{System.unique_integer()}"
      items = ["item1", "item2", "item3", "item4", "item5"]

      {:ok, result} =
        Client.call_tool(client, "process_batch", %{"items" => items, "reply_to" => reply_to},
          progress_token: progress_token
        )

      assert hd(result.content).text == "Processing 5 items"

      for index <- 1..5 do
        assert_receive {:progress_step, ^progress_token, ^index, 5}, 2_000
      end

      assert_receive {:progress_done, ^progress_token}, 2_000
    end

    test "multiple concurrent operations with different tokens", %{
      client: client,
      reply_to: reply_to
    } do
      # Start multiple operations concurrently
      tokens = for i <- 1..3, do: "concurrent-#{i}"

      tasks =
        Enum.map(tokens, fn token ->
          Task.async(fn ->
            Client.call_tool(client, "long_operation", %{"steps" => 3, "reply_to" => reply_to},
              progress_token: token
            )
          end)
        end)

      # Wait for all to complete
      results = Enum.map(tasks, &Task.await/1)

      # All should succeed
      assert Enum.all?(results, fn {:ok, result} ->
               hd(result.content).text =~ "Started long operation"
             end)

      # Each token reports its own stream of updates; tokens must not be mixed up.
      for token <- tokens do
        assert_receive {:progress_done, ^token}, 2_000
      end
    end

    test "progress token can be string or integer", %{client: client, reply_to: reply_to} do
      # String token
      {:ok, _} =
        Client.call_tool(client, "long_operation", %{"steps" => 2, "reply_to" => reply_to},
          progress_token: "string-token"
        )

      # Integer token
      {:ok, _} =
        Client.call_tool(client, "long_operation", %{"steps" => 2, "reply_to" => reply_to},
          progress_token: 12345
        )

      # Both token types round-trip through the handler unchanged.
      assert_receive {:progress_done, "string-token"}, 2_000
      assert_receive {:progress_done, 12345}, 2_000
    end
  end
end
