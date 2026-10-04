defmodule Arbor.MCP.Test.StdioRuntimeFixture do
  @moduledoc false

  defmodule Handler do
    @moduledoc false
    use Arbor.MCP.Server.Handler
    def init(opts), do: {:ok, %{owner: opts[:test_pid], count: 0}}

    def handle_call_tool("inc", _args, state) do
      send(state.owner, {:invoked, state.count + 1})

      {:ok, %{content: [], structuredContent: %{count: state.count + 1}},
       %{state | count: state.count + 1}}
    end

    def handle_call_tool("hold", _args, state) do
      send(state.owner, {:holding, self()})

      receive do
        :release ->
          {:ok, %{content: [], structuredContent: %{count: state.count + 1}},
           %{state | count: state.count + 1}}
      end
    end

    def handle_call_tool("reverse", _args, state) do
      {:ok, result} = Arbor.MCP.Server.ping(self(), 1_000)
      {:ok, %{content: [], structuredContent: result}, state}
    end

    def handle_call_tool("progress_hold", _args, state) do
      :ok = Arbor.MCP.Server.notify_progress(self(), "source", 1)
      send(state.owner, {:progress_source, self()})

      receive do
        :release ->
          {:ok, %{content: []}, %{state | count: state.count + 1}}

        {:arbor_mcp_cancelled, _token, _reason} ->
          send(state.owner, {:source_cancelled, self()})

          receive do
            :release -> {:ok, %{content: []}, %{state | count: state.count + 1}}
          end
      end
    end

    def handle_call_tool("progress_finish", _args, state) do
      :ok = Arbor.MCP.Server.notify_progress(self(), "source", 1)
      {:ok, %{content: []}, %{state | count: state.count + 1}}
    end

    def handle_request("extension/echo", params, state), do: {:reply, params, state}

    def handle_request("notifications/silent", _params, state),
      do: {:noreply, %{state | count: state.count + 1}}
  end

  # Borrowed IO device with controllable stdin EOF and stdout completion. It
  # deliberately retains a single blocked IO request after its writer dies.
  defmodule Device do
    @moduledoc false
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def init(opts),
      do:
        {:ok,
         %{
           owner: opts[:owner],
           input: "",
           eof: false,
           read: nil,
           write: nil,
           hold: Keyword.get(opts, :hold, false),
           written: []
         }}

    def handle_call({:input, data, eof}, _from, state) do
      {:reply, :ok, satisfy_read(%{state | input: state.input <> data, eof: eof})}
    end

    def handle_call(:release_write, _from, %{write: {from, ref, data}} = state) do
      send(from, {:io_reply, ref, :ok})
      send(state.owner, {:written, data})
      {:reply, :ok, %{state | write: nil, written: [data | state.written]}}
    end

    def handle_call(:state, _from, state), do: {:reply, state, state}

    def handle_info({:io_request, from, ref, :getopts}, state) do
      send(from, {:io_reply, ref, [encoding: :unicode, binary: true]})
      {:noreply, state}
    end

    def handle_info({:io_request, from, ref, {:get_chars, :unicode, _prompt, 1}}, state) do
      {:noreply, satisfy_read(%{state | read: {from, ref}})}
    end

    def handle_info({:io_request, from, ref, {:put_chars, :unicode, data}}, state) do
      data = IO.iodata_to_binary(data)
      send(state.owner, {:write_attempt, from, data})

      if state.hold do
        {:noreply, %{state | write: {from, ref, data}}}
      else
        send(from, {:io_reply, ref, :ok})
        send(state.owner, {:written, data})
        {:noreply, %{state | written: [data | state.written]}}
      end
    end

    defp satisfy_read(%{read: nil} = state), do: state
    defp satisfy_read(%{input: "", eof: false} = state), do: state

    defp satisfy_read(%{read: {from, ref}, input: "", eof: true} = state) do
      send(from, {:io_reply, ref, :eof})
      %{state | read: nil}
    end

    defp satisfy_read(%{read: {from, ref}} = state) do
      {unit, rest} = String.next_codepoint(state.input)
      send(from, {:io_reply, ref, unit})
      %{state | read: nil, input: rest}
    end
  end
end
