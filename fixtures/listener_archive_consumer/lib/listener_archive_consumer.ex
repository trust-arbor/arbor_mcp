defmodule ListenerArchiveConsumer do
  @moduledoc false
  alias Arbor.MCP.Server.{Runtime, Transport}

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts) do
      send(Keyword.fetch!(opts, :observer), {:consumer_handler_init, self()})
      {:ok, %{}}
    end
  end

  def probe do
    {:ok, _apps} = Application.ensure_all_started(:listener_archive_consumer)
    expected = System.fetch_env!("ARCHIVE_EXPECTED_VERSION")

    for app <- [:arbor_rpc, :arbor_mcp],
        do: ^expected = app |> Application.spec(:vsn) |> to_string()

    backend = backend()
    verify_boundaries(backend)
    verify_missing_backend(backend)
    System.put_env("PATH", "/no-runtime-compiler")
    System.put_env("CC", "/compiler-must-not-run")
    nil = System.find_executable("cc")

    first = start(backend)

    try do
      second = start(backend)

      try do
        {:ok, first_listener} = Transport.http_listener(first)
        {:ok, second_listener} = Transport.http_listener(second)
        true = first_listener.listener != second_listener.listener
        first_port = port(first_listener)
        second_port = port(second_listener)
        true = first_port != second_port
        ping(first_port, 1)
        ping(second_port, 2)
        stop_and_observe(first, first_listener.listener, first_port)
        ping(second_port, 3)
        stop_and_observe(second, second_listener.listener, second_port)
      after
        Runtime.stop(second)
      end
    after
      Runtime.stop(first)
    end

    record(backend)
    IO.puts("#{backend}: archive dependencies, owned listeners and sibling lifetime pass")
  end

  defp backend do
    case System.fetch_env!("LISTENER_ARCHIVE_ADAPTER") do
      "cowboy" -> :cowboy
      "bandit" -> :bandit
    end
  end

  defp verify_boundaries(backend) do
    for app <- [:arbor_acp, :arbor_acp_adapters, :bypass, :ex_doc, :credo], do: absent(app)

    if backend == :cowboy do
      "1.8.1" = to_string(Application.spec(:ranch, :vsn))
      true = Code.ensure_loaded?(Plug.Cowboy)
      for app <- [:bandit, :thousand_island, :websock], do: absent(app)
    else
      true = Code.ensure_loaded?(Bandit)
      for app <- [:plug_cowboy, :cowboy, :cowlib, :ranch], do: absent(app)
    end
  end

  defp absent(app) do
    nil = Application.spec(app, :vsn)
    {:error, :bad_name} = :code.lib_dir(app)
  end

  defp verify_missing_backend(backend) do
    {missing, package} =
      if backend == :cowboy, do: {:bandit, :bandit}, else: {:cowboy, :plug_cowboy}

    {:error, {:missing_http_listener_dependency, ^missing, ^package}} =
      Runtime.start_link(
        handler: Handler,
        handler_args: [observer: self()],
        transport: :http,
        http: [adapter: missing, host: {127, 0, 0, 1}, port: 0]
      )

    receive do
      {:consumer_handler_init, _scheduler} ->
        raise "missing backend allowed handler initialization"
    after
      0 -> :ok
    end
  end

  defp start(backend) do
    {:ok, root} =
      Runtime.start_link(
        handler: Handler,
        handler_args: [observer: self()],
        transport: :http,
        http: [adapter: backend, host: {127, 0, 0, 1}, port: 0]
      )

    try do
      receive do
        {:consumer_handler_init, _scheduler} -> root
      after
        1_000 -> raise "handler initialization was not observed"
      end
    rescue
      error ->
        Runtime.stop(root)
        reraise error, __STACKTRACE__
    end
  end

  defp port(%{adapter: :cowboy, ranch_ref: ref}), do: :ranch.get_port(ref)

  defp port(%{adapter: :bandit, listener: listener}) do
    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
    port
  end

  defp ping(port, id) do
    {200, response_headers, response} =
      post(port, [], %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "archive-listener", "version" => "1.0.0"}
        }
      })

    %{"id" => ^id, "result" => %{}} = Jason.decode!(response)
    {_, session} = List.keyfind(response_headers, ~c"mcp-session-id", 0)

    headers = [
      {~c"mcp-session-id", session},
      {~c"mcp-protocol-version", ~c"2025-11-25"}
    ]

    {202, _headers, _body} =
      post(port, headers, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    {200, _headers, body} =
      post(port, headers, %{"jsonrpc" => "2.0", "id" => id, "method" => "ping"})

    %{"jsonrpc" => "2.0", "id" => ^id, "result" => %{}} = Jason.decode!(body)

    receive do
      {:consumer_handler_init, _scheduler} -> raise "HTTP POST initialized the handler again"
    after
      0 -> :ok
    end
  end

  defp post(port, headers, message) do
    headers = [{~c"accept", ~c"application/json"} | headers]

    {:ok, {{_version, status, _reason}, response_headers, body}} =
      :httpc.request(
        :post,
        {~c"http://127.0.0.1:#{port}/mcp", headers, ~c"application/json", Jason.encode!(message)},
        [timeout: 2_000, connect_timeout: 1_000],
        body_format: :binary
      )

    {status, response_headers, body}
  end

  defp stop_and_observe(root, listener, port) do
    monitor = Process.monitor(listener)
    :ok = Runtime.stop(root)

    receive do
      {:DOWN, ^monitor, :process, ^listener, _reason} -> :ok
    after
      2_000 -> raise "actual listener DOWN was not observed"
    end

    closed(port, System.monotonic_time(:millisecond) + 2_000)
  end

  defp closed(port, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: raise("listener port did not close")

    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], min(remaining, 100)) do
      {:error, :econnrefused} ->
        :ok

      {:error, :econnreset} ->
        closed(port, deadline)

      {:ok, socket} ->
        :gen_tcp.close(socket)
        Process.sleep(min(remaining, 10))
        closed(port, deadline)

      other ->
        raise "unexpected listener close observation: #{inspect(other)}"
    end
  end

  defp record(backend) do
    packages =
      for {app, _description, version} <- Application.loaded_applications(), into: %{} do
        directory = to_string(:code.lib_dir(app))
        app_file = Path.join([directory, "ebin", "#{app}.app"])

        {to_string(app),
         %{
           version: to_string(version),
           path: directory,
           app_sha256: digest(app_file),
           modules: Enum.map(Application.spec(app, :modules) || [], &to_string/1)
         }}
      end

    modules = Application.spec(:arbor_mcp, :modules) ++ Application.spec(:arbor_rpc, :modules)
    true = length(modules) == MapSet.size(MapSet.new(modules))

    beams =
      Map.new(modules, fn module ->
        file = module |> :code.which() |> to_string()
        {to_string(module), digest(file)}
      end)

    helper = Path.join(to_string(:code.priv_dir(:arbor_rpc)), "native/arbor_rpc_subprocess")

    paths = Enum.map(:code.get_path(), &to_string/1)

    consolidated =
      for path <- paths,
          Path.basename(path) == "consolidated",
          file <- Path.wildcard(Path.join(path, "*.beam")),
          into: %{},
          do: {file, digest(file)}

    protocols =
      for protocol <- [Enumerable, Collectable, Inspect, String.Chars, List.Chars, Jason.Encoder],
          into: %{} do
        {to_string(protocol),
         %{
           consolidated: Protocol.consolidated?(protocol),
           path: to_string(:code.which(protocol))
         }}
      end

    File.write!(
      System.fetch_env!("LISTENER_ARCHIVE_REPORT"),
      Jason.encode!(%{
        adapter: backend,
        applications: packages,
        beams: beams,
        helper: digest(helper),
        code_paths: paths,
        consolidated_beams: consolidated,
        protocols: protocols,
        elixir: System.version(),
        otp: System.otp_release(),
        architecture: to_string(:erlang.system_info(:system_architecture))
      })
    )
  end

  defp digest(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
