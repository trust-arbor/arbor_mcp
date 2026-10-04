defmodule Arbor.MCP.Client.DiagnosticPrivacyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.{ConnectionScope, Deadline, DefaultHandler, Diagnostics, Lifetime, MRTR}
  alias Arbor.MCP.Transport.HTTP.ModernStreamClient
  alias Arbor.MCP.Transport.SSEClient

  @secret "arbor-client-private-payload-4816"
  @input_secret "arbor-client-private-input-7249"

  setup do
    filters = :logger.get_primary_config().filters

    enabled =
      Enum.map(filters, fn
        {:logger_translator, {translator, options}} ->
          {:logger_translator, {translator, Map.put(options, :sasl, true)}}

        filter ->
          filter
      end)

    :ok = :logger.set_primary_config(:filters, enabled)
    on_exit(fn -> :logger.set_primary_config(:filters, filters) end)
    :ok
  end

  defmodule ErrorTransport do
    @behaviour Arbor.MCP.Transport
    def connect(opts) do
      send(Keyword.fetch!(opts, :owner), {:error_transport_owner, self()})
      {:error, Keyword.fetch!(opts, :private_payload)}
    end

    def send_message(_message, state), do: {:ok, state}
    def receive_message(_state), do: {:error, :closed}
    def close(_state), do: :ok
    def connected?(_state), do: false
  end

  defmodule CustomNative do
    use GenServer

    def init(opts) do
      send(Keyword.fetch!(opts, :owner), {:custom_native_opts, self(), opts})
      {:ok, opts}
    end
  end

  defmodule PlainInit do
    use GenServer
    def init(constructor), do: constructor.()
  end

  defmodule CapturedInit do
    use GenServer
    def init(constructor), do: Diagnostics.initialize(constructor)
  end

  defmodule RaisedApproval do
    def request_approval(_kind, _params, opts), do: raise(ArgumentError, opts[:private_payload])
  end

  defmodule RaisedInput do
    @behaviour Arbor.MCP.Client.Handler
    def init(opts), do: {:ok, %{owner: opts[:owner], private_payload: opts[:private_payload]}}
    def handle_ping(state), do: {:ok, %{}, state}
    def handle_list_roots(state), do: {:ok, [], state}

    def handle_create_message(_params, state) do
      send(state.owner, {:raised_input_worker, self()})

      receive do
        :raise_now ->
          case Map.get(state, :failure, :raise) do
            :raise -> raise ArgumentError, state.private_payload
            :throw -> throw(state.private_payload)
            :exit -> exit(state.private_payload)
          end
      end
    end

    def mrtr_input_concurrency, do: 2
  end

  defmodule ReplyTransport do
    @behaviour Arbor.MCP.Transport
    def connect(opts), do: {:ok, %{owner: opts[:owner]}}

    def send_message(message, state) do
      send(state.owner, {:reply_wire, message})
      {:ok, state}
    end

    def receive_message(_state), do: {:error, :closed}
    def close(_state), do: :ok
    def connected?(_state), do: true
  end

  defmodule ImmediateRaisedInput do
    def handle_create_message(_params, state), do: raise(ArgumentError, state.private_payload)
    def mrtr_input_concurrency, do: 2
  end

  test "Client diagnostic formatting omits arbitrary state, messages, reasons and logs" do
    state = %Client{client_handler: {__MODULE__, %{private: @secret}}}
    refute_payload(Client.format_status(status(state)))
  end

  test "connection-scope diagnostic formatting fails closed for unknown status fields" do
    refute_payload(ConnectionScope.Observer.format_status(status(%{private: @secret})))
  end

  test "the ordinary lifetime owner has payload-free diagnostic formatting" do
    Code.ensure_loaded!(Lifetime)
    assert function_exported?(Lifetime, :format_status, 1)
    refute_payload(Lifetime.format_status(status(%{private: @secret})))
  end

  test "diagnostic summaries retain only counts and tolerate non-map state" do
    assert %{state: %{pending_requests: 1, component: Client, payloads: :redacted}} =
             Diagnostics.format_status(status(%{pending_requests: %{1 => @secret}}), Client)

    refute_payload(Diagnostics.format_status(status({:unknown, @secret}), Client))
    refute_payload(Diagnostics.format_status(status(nil), Client))
  end

  test "modern HTTP diagnostic formatting omits buffered data and arbitrary crash context" do
    refute_payload(ModernStreamClient.format_status(status(%ModernStreamClient{buffer: @secret})))
  end

  test "legacy SSE diagnostic formatting omits buffered data and arbitrary crash context" do
    refute_payload(SSEClient.format_status(status(%SSEClient{buffer: @secret})))
  end

  test "built-in HTTP init failures retain exact typed options but use a fixed native exception" do
    Process.flag(:trap_exit, true)
    opts = [private_payload: @secret]

    log =
      capture_log(fn ->
        for {module, key} <- [{ModernStreamClient, :parent}, {SSEClient, :url}] do
          assert {:error, {%KeyError{key: ^key, term: ^opts}, stack}} =
                   Lifetime.start_process(module, opts, :linked)

          assert is_list(stack)
        end

        Logger.flush()
      end)

    refute_payload(log)
    assert log =~ ":client_init_failed"
  end

  test "default sampling rescue omits exception detail and retains its authored protocol error" do
    opts = [approval_handler: RaisedApproval, private_payload: @secret]
    {:ok, state} = DefaultHandler.init(opts)

    log =
      capture_log(fn ->
        assert {:error,
                %{"code" => -32603, "message" => "Internal error handling createMessage request"},
                ^state} =
                 DefaultHandler.handle_create_message(%{}, state)
      end)

    refute_payload(log)
  end

  test "actual native Client status is private while trusted state inspection remains exact" do
    client = client()
    :sys.replace_state(client, &%{&1 | client_handler: {__MODULE__, %{private: @secret}}})
    assert :sys.get_state(client).client_handler == {__MODULE__, %{private: @secret}}
    assert native_parent(client) == self()
    refute_payload(:sys.get_status(client))
  end

  test "native Client child construction stays opaque under its real parent" do
    {:ok, parent} = Supervisor.start_link([{Client, client_opts()}], strategy: :one_for_one)
    Process.unlink(parent)
    on_exit(fn -> if Process.alive?(parent), do: Supervisor.stop(parent) end)
    [{Client, client, :worker, [Client]}] = Supervisor.which_children(parent)
    assert native_parent(client) == parent
    assert Keyword.fetch!(:sys.get_state(client).transport_opts, :private_payload) == @secret
    refute_payload(:sys.get_status(parent))
  end

  test "transport-down logging hides details without changing public cleanup state" do
    client = client()

    log =
      capture_log(fn ->
        send(client, {:transport_error, @secret})
        assert {:ok, %{connection_status: :disconnected}} = Client.get_status(client)
      end)

    refute_payload(log)
    assert :sys.get_state(client).cleanup_result == :ok
  end

  test "an actual reverse callback exception is contained without a payload-bearing native report" do
    client = input_client()

    log =
      capture_log(fn ->
        send(
          client,
          {:transport_message,
           Jason.encode!(%{
             "jsonrpc" => "2.0",
             "id" => 42,
             "method" => "sampling/createMessage",
             "params" => %{}
           })}
        )

        assert_receive {:raised_input_worker, worker}, 1_000
        monitor = Process.monitor(worker)
        send(worker, :raise_now)
        assert_receive {:reply_wire, reply}, 1_000

        assert %{
                 "id" => 42,
                 "error" => %{"code" => -32603, "message" => "Internal error in client handler"}
               } = Jason.decode!(reply)

        assert_receive {:DOWN, ^monitor, :process, ^worker, reason}, 1_000
        assert reason in [:normal, :noproc]
        assert {:ok, _status} = Client.get_status(client)
        Logger.flush()
      end)

    refute_payload(log)
  end

  for mode <- [:raise, :throw, :exit] do
    @mode mode
    test "concurrent MRTR captures #{@mode} before native Task reporting" do
      client = input_client(@mode)
      owner = self()

      log =
        capture_log(fn ->
          caller =
            spawn(fn ->
              outcome =
                GenServer.call(
                  client,
                  {:fulfill_mrtr,
                   %{
                     "a" => %{
                       "method" => "sampling/createMessage",
                       "params" => %{"private" => @input_secret}
                     }
                   }, [], make_ref()},
                  2_000
                )

              send(owner, {:mrtr_outcome, outcome})
            end)

          on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
          assert_receive {:raised_input_worker, worker}, 1_000
          monitor = Process.monitor(worker)
          [{producer, _meta}] = Map.to_list(:sys.get_state(client).mrtr_tasks)
          {:links, producer_links} = Process.info(producer, :links)
          assert native_parent(worker) in producer_links
          {observer, _token, _epoch} = Lifetime.from_client(client)
          assert Map.has_key?(:sys.get_state(observer).workers, worker)
          send(worker, :raise_now)
          assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
          assert_receive {:mrtr_outcome, {:error, error}}, 1_000
          assert error.code == -32603
          assert error.message == "MRTR input handler failed"
          assert {:ok, _status} = Client.get_status(client)
          Logger.flush()
        end)

      refute_payload(log)
      refute log =~ @input_secret
      refute log =~ "Task.Supervised"
      assert :sys.get_state(client).mrtr_tasks == %{}

      assert {RaisedInput, %{failure: @mode, private_payload: @secret}} =
               :sys.get_state(client).client_handler
    end
  end

  test "private MRTR fulfillment retains original failure detail only in its trusted return" do
    state = %{private_payload: @secret}
    request = %{"a" => %{"method" => "sampling/createMessage", "params" => %{}}}

    log =
      capture_log(fn ->
        assert {:error, {:client_handler_raised, %ArgumentError{message: @secret}, stack}, ^state} =
                 MRTR.fulfill(request, ImmediateRaisedInput, state, %{"sampling" => %{}})

        assert is_list(stack)
        Logger.flush()
      end)

    refute_payload(log)
  end

  test "ordinary managed async streams preserve native value and exit outcomes with opaque arguments" do
    Process.flag(:trap_exit, true)
    :ok = Lifetime.install(client_cleanup_timeout: 200)
    {observer, _token, _epoch} = Lifetime.current()
    on_exit(fn -> if Process.alive?(observer), do: Process.exit(observer, :kill) end)

    log =
      capture_log(fn ->
        results =
          Lifetime.async_stream(
            [{:value, @input_secret}, {:exit, :expected_native_exit}],
            fn
              {:value, value} -> value
              {:exit, reason} -> exit(reason)
            end,
            max_concurrency: 1,
            ordered: true,
            timeout: 1_000
          )
          |> Enum.to_list()

        assert results == [{:ok, @input_secret}, {:exit, :expected_native_exit}]
        assert :ok = Lifetime.cleanup(Deadline.after_ms(200))
        Logger.flush()
      end)

    refute log =~ @input_secret
  end

  test "initial connection diagnostics hide a supplied error while returning its public detail" do
    Process.flag(:trap_exit, true)

    log =
      capture_log(fn ->
        assert {:error, {:transport_connect_failed, @secret}} =
                 Client.start_link(
                   transport: ErrorTransport,
                   private_payload: @secret,
                   owner: self(),
                   protocol_mode: :legacy_only,
                   reconnect: false,
                   health_check_interval: nil
                 )

        assert_receive {:error_transport_owner, failed_client}
        monitor = Process.monitor(failed_client)
        assert_receive {:DOWN, ^monitor, :process, ^failed_client, :noproc}
        Logger.flush()
      end)

    refute_payload(log)
    assert log =~ ":client_init_failed"
  end

  test "failed native child startup retains its exact returned error at the trusted host boundary" do
    Process.flag(:trap_exit, true)
    {:ok, parent} = Supervisor.start_link([], strategy: :one_for_one)
    Process.unlink(parent)
    on_exit(fn -> if Process.alive?(parent), do: Supervisor.stop(parent) end)

    opts = [
      transport: ErrorTransport,
      private_payload: @secret,
      owner: self(),
      protocol_mode: :legacy_only,
      reconnect: false,
      health_check_interval: nil
    ]

    log =
      capture_log(fn ->
        assert {:error, {{:transport_connect_failed, @secret}, child}} =
                 Supervisor.start_child(parent, {Client, opts})

        assert elem(child, 0) == :child
        assert_receive {:error_transport_owner, failed_client}
        monitor = Process.monitor(failed_client)
        assert_receive {:DOWN, ^monitor, :process, ^failed_client, :noproc}
        Logger.flush()
      end)

    refute_payload(log)
    assert Supervisor.which_children(parent) == []
  end

  test "a host Supervisor initial child failure can report the preserved typed error" do
    Process.flag(:trap_exit, true)

    opts = [
      transport: ErrorTransport,
      private_payload: @secret,
      owner: self(),
      protocol_mode: :legacy_only,
      reconnect: false,
      health_check_interval: nil
    ]

    log =
      capture_log(fn ->
        assert {:error,
                {:shutdown,
                 {:failed_to_start_child, Client, {:transport_connect_failed, @secret}}}} =
                 Supervisor.start_link([{Client, opts}], strategy: :one_for_one)

        Logger.flush()
      end)

    # The host Supervisor owns this failure report and can print the public
    # typed error it received. The child's diagnostic reason remains fixed.
    assert log =~ @secret
    assert log =~ "failed to start"
    assert log =~ ":client_init_failed"
  end

  test "the generic lifetime native starter preserves custom init options and native parent" do
    opts = [owner: self(), private_payload: @secret]
    assert {:ok, child} = Lifetime.start_process(CustomNative, opts, :linked)
    on_exit(fn -> if Process.alive?(child), do: Process.exit(child, :kill) end)
    assert_receive {:custom_native_opts, ^child, ^opts}
    assert native_parent(child) == self()
    assert :sys.get_state(child) == opts
    GenServer.stop(child)
  end

  test "native initialization stop, throw and graceful failure ACKs retain OTP semantics" do
    Process.flag(:trap_exit, true)

    for constructor <- [
          fn -> {:stop, @secret} end,
          fn -> throw({:stop, @secret}) end,
          fn -> throw(:ignore) end,
          fn -> throw(@secret) end,
          fn -> {:error, @secret} end
        ] do
      # The control is OTP's original init behavior; its raw returned error is
      # deliberately trusted test data, not a managed Client diagnostic.
      original = GenServer.start_link(PlainInit, constructor)
      Logger.flush()

      log =
        capture_log(fn ->
          assert GenServer.start_link(CapturedInit, constructor) == original
          Logger.flush()
        end)

      refute_payload(log)
    end
  end

  defp client do
    {:ok, client} = Client.start_link(client_opts())
    on_exit(fn -> if Process.alive?(client), do: Process.exit(client, :kill) end)
    client
  end

  defp input_client(failure \\ :raise) do
    client = client()
    owner = self()

    :sys.replace_state(client, fn state ->
      %{
        state
        | transport_mod: ReplyTransport,
          transport_state: %{owner: owner},
          connection_status: :connected,
          protocol_version: "2026-07-28",
          client_handler:
            {RaisedInput, %{owner: owner, private_payload: @secret, failure: failure}},
          transport_opts: Keyword.put(state.transport_opts, :capabilities, %{"sampling" => %{}})
      }
    end)

    client
  end

  defp client_opts,
    do: [
      _skip_connect: true,
      private_payload: @secret,
      reconnect: false,
      health_check_interval: nil
    ]

  defp status(state),
    do: %{
      state: state,
      message: {:unknown, @secret},
      reason: {:unknown, @secret},
      log: [@secret],
      future_field: @secret
    }

  defp native_parent(pid) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)
    dictionary |> Keyword.fetch!(:"$ancestors") |> hd()
  end

  defp refute_payload(value) do
    refute inspect(value, limit: :infinity, printable_limit: :infinity) =~ @secret
    refute IO.iodata_to_binary(:io_lib.format(~c"~p", [value])) =~ @secret
  end
end
