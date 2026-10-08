defmodule Arbor.MCP.Test.RawHTTPServer do
  @moduledoc """
  Single-connection TCP server that replays a scripted HTTP/1.1 response.

  Bypass and Plug cannot produce malformed or unusual wire shapes such as
  duplicate `content-length` headers, conflicting framing, compressed bodies
  without a real encoder, chunked trailers, or a server that never answers.
  This helper accepts exactly one connection on an ephemeral loopback port,
  reads the request head, optionally forwards it to an owner process as
  `{:raw_request, request_head}`, then writes each scripted frame in order
  and closes the socket.

  Scripts are either a list of iodata frames, which are written with
  separate `:gen_tcp.send/2` calls so a Mint client may observe them across
  several `recv/3` rounds, or the atom `:hang`, which reads the request and
  then holds the socket open until the client closes it. Used by the pinned
  HTTP client characterization tests.
  """

  @accept_timeout 5_000
  @hang_timeout 10_000

  @type script :: [iodata()] | :hang

  @doc """
  Starts the server and returns `{port, task}`.

  Options:

    * `:owner` - pid that receives `{:raw_request, request_head}`.
  """
  @spec start(script(), keyword()) :: {:inet.port_number(), Task.t()}
  def start(script, opts \\ []) when is_list(script) or script == :hang do
    owner = Keyword.get(opts, :owner)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, @accept_timeout)
        {:ok, request} = recv_head(socket, "")
        if owner, do: send(owner, {:raw_request, request})
        :ok = respond(socket, script)
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
        :ok
      end)

    {port, task}
  end

  @doc "Waits for the server task to finish; returns `:ok`."
  @spec await(Task.t()) :: :ok
  def await(task), do: Task.await(task, @hang_timeout + 1_000)

  defp respond(socket, :hang) do
    # Hold the connection open until the client gives up and closes it.
    case :gen_tcp.recv(socket, 0, @hang_timeout) do
      {:ok, _more} -> respond(socket, :hang)
      {:error, _closed} -> :ok
    end
  end

  defp respond(socket, frames) do
    Enum.each(frames, fn frame -> :ok = :gen_tcp.send(socket, frame) end)
  end

  defp recv_head(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, @accept_timeout) do
        {:ok, data} -> recv_head(socket, acc <> data)
        error -> error
      end
    end
  end
end
