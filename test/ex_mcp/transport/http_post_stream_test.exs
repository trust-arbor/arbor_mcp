defmodule ExMCP.Transport.HTTP.PostStreamTest do
  use ExUnit.Case, async: true

  alias ExMCP.Transport.HTTP.PostStream

  @progress ~s({"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"t","progress":1}})
  @response ~s({"jsonrpc":"2.0","id":1,"result":{}})

  # Stands in for the client: acknowledges each message and passes it on.
  defp client do
    test = self()

    spawn_link(fn -> acknowledge(test) end)
  end

  defp acknowledge(test) do
    receive do
      {:http_post_stream_message, stream, ref, data} ->
        send(test, {:handed_over, data})
        send(stream, {:http_post_stream_ack, ref})
        acknowledge(test)
    end
  end

  defp consumer(parent, max_buffer \\ 1_024) do
    {acc, fun} = PostStream.consumer(parent, max_buffer_bytes: max_buffer, max_kept_bytes: 4_096)
    deadline = System.monotonic_time(:millisecond) + 5_000

    {acc,
     fn
       :done, acc -> fun.(:done, acc)
       chunk, acc -> fun.({:data, chunk, deadline}, acc)
     end}
  end

  defp feed(chunks, opts \\ []) do
    parent = Keyword.get_lazy(opts, :parent, &client/0)
    {acc, fun} = consumer(parent, Keyword.get(opts, :max_buffer, 1_024))

    Enum.reduce_while(chunks, {:ok, acc}, fn chunk, {:ok, acc} ->
      case fun.(chunk, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> fun.(:done, acc)
      error -> error
    end
  end

  test "hands over each message as its event completes and keeps the response" do
    {acc, fun} = consumer(client())

    {:ok, acc} = fun.("data: " <> @progress <> "\n", acc)
    refute_receive {:handed_over, _}, 50

    {:ok, acc} = fun.("\ndata: " <> @response <> "\n\n", acc)
    assert_receive {:handed_over, @progress}

    assert {:ok, body} = fun.(:done, acc)
    assert body =~ @response
    refute body =~ "progress"
  end

  test "a CRLF split across chunks ends one event, not two" do
    assert {:ok, body} =
             feed(["data: " <> @progress <> "\r", "\n\r\ndata: " <> @response <> "\r\n\r\n"])

    assert_receive {:handed_over, @progress}
    refute_receive {:handed_over, _}, 50
    assert body =~ @response
  end

  # A server that waits for its ping to be answered sends nothing more.
  test "an event ended by CRs is handed over without waiting for the next chunk" do
    ping = ~s({"jsonrpc":"2.0","id":"p","method":"ping","params":{}})
    {acc, fun} = consumer(client())

    assert {:ok, _acc} = fun.("data: " <> ping <> "\r\r", acc)
    assert_receive {:handed_over, ^ping}
  end

  test "handed-over events keep only the last id and retry" do
    events =
      for n <- 1..500,
          do: "id: e#{n}\nretry: #{n}\ndata: " <> @progress <> "\n\n"

    assert {:ok, body} = feed(events ++ ["data: " <> @response <> "\n\n"])
    assert body =~ "id: e500"
    refute body =~ "id: e499"
    assert byte_size(body) < 200
  end

  test "a complete event read at once is limited too" do
    big =
      ~s({"jsonrpc":"2.0","method":"notifications/message","params":{"data":") <>
        String.duplicate("x", 200) <> ~s("}})

    assert {:error, :stream_buffer_limit_exceeded} =
             feed(["data: " <> big <> "\n\n"], max_buffer: 100)

    refute_receive {:handed_over, _}, 50
  end

  test "an event that never ends can't grow without bound" do
    assert {:error, :stream_buffer_limit_exceeded} =
             feed(["data: ", String.duplicate("x", 200)], max_buffer: 100)
  end

  test "a client that has gone away ends the stream" do
    parent = spawn(fn -> :ok end)
    ref = Process.monitor(parent)
    assert_receive {:DOWN, ^ref, :process, ^parent, _reason}

    assert {:error, :stream_consumer_closed} =
             feed(["data: " <> @progress <> "\n\n"], parent: parent)
  end
end
