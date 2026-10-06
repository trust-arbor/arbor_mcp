defmodule Arbor.MCP.Server.SubscriptionMailboxTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.Runtime.Deadline
  alias Arbor.MCP.Server.Subscriptions.Mailbox

  defp mailbox(opts \\ []) do
    Mailbox.new(
      Keyword.merge(
        [max_count: 2, max_bytes: 16_384, max_message_bytes: 1_024],
        opts
      )
    )
  end

  test "precharged payloads stay out of coalesced control wakes" do
    mailbox = mailbox()
    payload = %{"params" => %{"text" => String.duplicate("x", 100)}}
    deadline = Deadline.after_ms(1_000)
    assert {:ok, first} = Mailbox.offer(mailbox, payload, nil, deadline, :async)
    assert {:ok, second} = Mailbox.offer(mailbox, payload, nil, deadline, :async)
    assert {:error, :subscription_busy} = Mailbox.offer(mailbox, payload, nil, deadline, :async)
    assert Mailbox.stats(mailbox).count == 2
    assert Mailbox.stats(mailbox).bytes >= :erlang.external_size(payload) * 2
    assert :ok = Mailbox.wake(mailbox)
    assert :ok = Mailbox.wake(mailbox)
    identity = Mailbox.identity(mailbox)
    assert_receive {:subscription_mailbox_ready, ^identity}
    refute_receive {:subscription_mailbox_ready, _}, 10
    assert Mailbox.pending(mailbox, :async) == [first, second]
  end

  test "processing remains charged after producer timeout until the owner finishes" do
    mailbox = mailbox(max_count: 1)
    parent = self()

    producer =
      spawn(fn ->
        {:ok, id} = Mailbox.offer(mailbox, %{}, nil, Deadline.after_ms(80), :sync)
        send(parent, {:offered, id})

        receive do
          :abort -> Mailbox.abort(mailbox, id)
        end
      end)

    assert_receive {:offered, id}
    assert {:ok, _entry} = Mailbox.take(mailbox, id)
    send(producer, :abort)
    Process.sleep(100)
    Mailbox.reap(mailbox)
    assert Mailbox.stats(mailbox).count == 1
    refute Mailbox.active?(mailbox, id)

    assert {:error, :subscription_busy} =
             Mailbox.offer(mailbox, %{}, nil, Deadline.after_ms(1_000), :async)

    Mailbox.finish(mailbox, id)
    assert %{count: 0, bytes: 0} = Mailbox.stats(mailbox)
  end

  test "checked-out output liability survives expiry until actual delivery settlement" do
    mailbox = mailbox()
    {:ok, id} = Mailbox.offer(mailbox, %{}, nil, Deadline.after_ms(50), :sync)
    assert {:ok, _} = Mailbox.take(mailbox, id)
    assert {:ok, _} = Mailbox.queue(mailbox, id)
    assert {:ok, _} = Mailbox.offer_delivery(mailbox, id)
    assert {:ok, _} = Mailbox.checkout(mailbox, id)
    Process.sleep(70)
    Mailbox.reap(mailbox)
    assert Mailbox.stats(mailbox).count == 1
    Mailbox.finish(mailbox, id)
    assert Mailbox.stats(mailbox).count == 0
  end

  test "unclaimed and queued expirations release both byte and count credit" do
    mailbox = mailbox()
    {:ok, first} = Mailbox.offer(mailbox, %{}, nil, Deadline.after_ms(40), :sync)
    {:ok, second} = Mailbox.offer(mailbox, %{}, nil, Deadline.after_ms(40), :sync)
    {:ok, _} = Mailbox.take(mailbox, second)
    {:ok, _} = Mailbox.queue(mailbox, second)
    Process.sleep(60)
    Mailbox.reap(mailbox)
    assert {:error, :subscription_expired} = Mailbox.entry(mailbox, first)
    assert %{count: 0, bytes: 0} = Mailbox.stats(mailbox)
  end

  test "frame and metadata byte caps reject before any wake is published" do
    mailbox = mailbox(max_message_bytes: 32, max_term_bytes: 256)

    assert {:error, :output_frame_too_large} =
             Mailbox.offer(
               mailbox,
               %{"s" => String.duplicate("a", 40)},
               nil,
               Deadline.after_ms(1_000),
               :async
             )

    mailbox = mailbox(max_bytes: 1)

    assert {:error, :subscription_busy} =
             Mailbox.offer(mailbox, %{}, nil, Deadline.after_ms(1_000), :async)

    assert %{count: 0, bytes: 0} = Mailbox.stats(mailbox)
    refute_receive {:subscription_mailbox_ready, _}, 10
  end

  test "only the lifetime owner can consume or release an offered record" do
    mailbox = mailbox()
    {:ok, id} = Mailbox.offer(mailbox, %{}, nil, Deadline.after_ms(1_000), :sync)
    parent = self()
    spawn(fn -> send(parent, {:foreign_take, Mailbox.take(mailbox, id)}) end)
    assert_receive {:foreign_take, {:error, :subscription_expired}}
    assert Mailbox.stats(mailbox).count == 1
    Mailbox.finish(mailbox, id)
  end
end
