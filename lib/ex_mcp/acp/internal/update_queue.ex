defmodule ExMCP.ACP.Internal.UpdateQueue do
  @moduledoc false

  # Count the complete mailbox first, avoiding a copy of a mailbox already
  # beyond the count bound. Inspect bytes only for update/notification data.
  def check(pid, count_limit, byte_limit, incoming_bytes, kind)
      when is_pid(pid) and node(pid) == node() do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, count} when count < count_limit ->
        case Process.info(pid, :messages) do
          {:messages, messages} when length(messages) < count_limit ->
            bytes =
              Enum.reduce_while(messages, 0, fn message, total ->
                total = total + size(message, kind)
                if total >= byte_limit, do: {:halt, total}, else: {:cont, total}
              end)

            if incoming_bytes <= byte_limit - bytes, do: :ok, else: {:error, :bytes}

          {:messages, _full} ->
            {:error, :count}

          _dead ->
            {:error, :unavailable}
        end

      {:message_queue_len, _full} ->
        {:error, :count}

      _dead ->
        {:error, :unavailable}
    end
  end

  def check(_pid, _count_limit, _byte_limit, _incoming_bytes, _kind), do: {:error, :unavailable}

  defp size({:acp_session_update, _, update}, :listener), do: :erlang.external_size(update)

  defp size({:acp_session_updates_dropped, _, _} = message, :listener),
    do: :erlang.external_size(message)

  defp size({:"$gen_cast", {:session_update, _, update, nil}}, :handler),
    do: :erlang.external_size(update)

  defp size({:"$gen_cast", {:session_update, _, _update, message}}, :handler),
    do: :erlang.external_size(message)

  defp size({:"$gen_cast", {:session_updates_dropped, _, _}} = message, :handler),
    do: :erlang.external_size(message)

  defp size(_message, _kind), do: 0
end
