defmodule Arbor.MCP.Client.Pagination do
  @moduledoc false

  alias Arbor.MCP.Client.Deadline
  alias Arbor.MCP.Client.Internal.Request
  alias Arbor.MCP.Internal.RequestParams

  def run(client, method, field, opts) do
    opts = Keyword.validate!(opts, [:timeout, :cursor, :max_pages, :max_items, :max_bytes])

    limits = %{
      pages: positive!(opts, :max_pages, 64),
      items: positive!(opts, :max_items, 10_000),
      bytes: positive!(opts, :max_bytes, 8_388_608)
    }

    deadline = Deadline.after_ms(positive!(opts, :timeout, 30_000))
    cursor = Keyword.get(opts, :cursor)

    unless is_nil(cursor) or is_binary(cursor),
      do: raise(ArgumentError, "cursor must be a string or nil")

    seen = if is_nil(cursor), do: %{}, else: %{cursor => true}
    walk(client, method, field, cursor, deadline, limits, seen, [])
  catch
    :exit, {:noproc, _call} -> {:error, :client_not_alive}
  end

  defp walk(client, method, field, cursor, deadline, limits, seen, pages) do
    remaining = Deadline.remaining(deadline)

    cond do
      remaining == 0 -> {:error, :timeout}
      limits.pages == 0 -> {:error, {:pagination_limit, :max_pages}}
      true -> fetch_page(client, method, field, cursor, deadline, limits, seen, pages)
    end
  end

  defp fetch_page(client, method, field, cursor, deadline, limits, seen, pages) do
    opts = [format: :map, timeout: Deadline.remaining(deadline), retry_policy: false]

    with {:ok, page} <-
           Request.make_request(
             client,
             method,
             RequestParams.cursor(cursor),
             opts,
             5_000,
             deadline
           ),
         :ok <- within_deadline(deadline),
         {:ok, items, next} <- page_fields(page, field),
         {:ok, count} <- item_count(items, limits.items),
         {:ok, bytes} <- within_bytes(page, limits.bytes) do
      limits = %{
        limits
        | pages: limits.pages - 1,
          items: limits.items - count,
          bytes: limits.bytes - bytes
      }

      advance(client, method, field, next, deadline, limits, seen, [items | pages])
    end
  end

  defp advance(_client, _method, _field, nil, deadline, _limits, _seen, pages) do
    items = pages |> Enum.reverse() |> List.flatten()
    with :ok <- within_deadline(deadline), do: {:ok, items}
  end

  defp advance(client, method, field, next, deadline, limits, seen, pages) do
    if Map.has_key?(seen, next),
      do: {:error, :pagination_cursor_cycle},
      else: walk(client, method, field, next, deadline, limits, Map.put(seen, next, true), pages)
  end

  defp page_fields(page, field) when is_map(page) do
    items = value(page, field)
    cursor = value(page, :nextCursor)

    if is_list(items) and (is_nil(cursor) or is_binary(cursor)),
      do: {:ok, items, cursor},
      else: {:error, :invalid_pagination_page}
  end

  defp page_fields(_page, _field), do: {:error, :invalid_pagination_page}

  defp value(page, field), do: Map.get(page, Atom.to_string(field), Map.get(page, field))

  defp item_count(items, limit), do: count_items(items, limit, 0)
  defp count_items([], _limit, count), do: {:ok, count}

  defp count_items([item | rest], limit, count) when is_map(item) and count < limit,
    do: count_items(rest, limit, count + 1)

  defp count_items([_item | _rest], limit, count) when count >= limit,
    do: {:error, {:pagination_limit, :max_items}}

  defp count_items(_invalid, _limit, _count), do: {:error, :invalid_pagination_page}

  defp within_bytes(page, limit) do
    bytes = :erlang.external_size(page)

    if bytes <= limit,
      do: {:ok, bytes},
      else: {:error, {:pagination_limit, :max_bytes}}
  end

  defp within_deadline(deadline),
    do: if(Deadline.expired?(deadline), do: {:error, :timeout}, else: :ok)

  defp positive!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 and value <= 2_147_483_647 -> value
      _ -> raise ArgumentError, "#{key} must be a positive finite integer"
    end
  end
end
