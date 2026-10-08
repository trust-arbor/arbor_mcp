defmodule Arbor.MCP.Server.RuntimeRetainedInputTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{Admission, OutputCodec, Ref}

  defmodule Handler do
    def init(parent), do: {:ok, parent}

    def dispatch(request, _handler, parent, _opts) do
      blob = request["params"]["blob"]

      send(
        parent,
        {:retained, self(), :binary.referenced_byte_size(blob), request["params"]["shape"]}
      )

      receive do: (:release -> :ok)
      {:response, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => "done"}, parent}
    end
  end

  test "admitted request detaches a producer buffer while preserving native term shapes" do
    root =
      start_supervised!(
        {Runtime,
         handler: Handler,
         dispatcher: Handler,
         handler_args: self(),
         max_request_bytes: 1_024,
         max_pending_bytes: 8_192}
      )

    {:ok, runtime} = Runtime.ref(root)
    parent = self()
    identity = make_ref()
    shape = {%URI{scheme: "test"}, [identity | :tail]}

    {producer, monitor} =
      spawn_monitor(fn ->
        blob = :binary.part(:binary.copy("b", 16_777_216), 0, 128)
        assert :binary.referenced_byte_size(blob) == 16_777_216

        request = %{
          "jsonrpc" => "2.0",
          "id" => blob,
          "method" => "hold",
          "params" => %{"blob" => blob, "shape" => shape}
        }

        send(
          parent,
          {:admitted, Runtime.submit(runtime, request, owner: parent, reply_to: parent)}
        )

        receive do: (:retire -> :ok)
      end)

    assert_receive {:admitted, {:ok, token}}, 1_000
    assert_receive {:retained, worker, 128, ^shape}, 1_000
    send(producer, :retire)
    assert_receive {:DOWN, ^monitor, :process, ^producer, :normal}, 1_000
    assert Runtime.stats!(runtime).pending_bytes < 1_024
    assert {:ok, reservation} = Admission.current(Ref.table(runtime), token)
    assert :binary.referenced_byte_size(reservation.request_id) == 128
    assert :binary.referenced_byte_size(elem(reservation.key, 2)) == 128
    send(worker, :release)
    assert {:ok, %{"result" => "done"}} = Runtime.await(token, 1_000)
  end

  test "oversized captured backing is rejected without rebuilding the host function" do
    root =
      start_supervised!(
        {Runtime,
         handler: Handler,
         dispatcher: Handler,
         handler_args: self(),
         max_request_bytes: 1_024,
         max_pending_bytes: 8_192}
      )

    {:ok, runtime} = Runtime.ref(root)
    blob = :binary.part(:binary.copy("x", 16_777_216), 0, 128)
    function = fn -> blob end

    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "hold",
      "params" => %{"function" => function}
    }

    assert :erlang.external_size(request) < 1_024
    assert {:error, :request_too_large} = Runtime.submit(runtime, request)
    assert Runtime.stats!(runtime).reserved == 0
    assert :binary.referenced_byte_size(function.()) == 16_777_216
    refute_receive {:retained, _, _, _}

    assert {:error, :output_term_too_large} =
             OutputCodec.prepare(%{"function" => function},
               codec: :term,
               max_term_bytes: 1_024,
               max_frame_bytes: 1_024,
               deadline: System.monotonic_time(:millisecond) + 1_000
             )
  end

  test "prepared BEAM and JSON output cannot retain a larger backing binary" do
    blob = :binary.part(:binary.copy("x", 16_777_216), 0, 128)
    term = %{"result" => blob}
    deadline = System.monotonic_time(:millisecond) + 1_000

    for codec <- [:term, :json] do
      assert {:ok, prepared} =
               OutputCodec.prepare(term,
                 codec: codec,
                 max_term_bytes: 1_024,
                 max_frame_bytes: 1_024,
                 deadline: deadline
               )

      assert prepared.term == term
      assert :binary.referenced_byte_size(prepared.term["result"]) <= prepared.term_bytes
      assert prepared.bytes < 1_024
    end

    assert {:error, :output_term_too_large} =
             OutputCodec.prepare(term,
               max_term_bytes: 16,
               max_frame_bytes: 1_024,
               deadline: deadline
             )
  end
end
