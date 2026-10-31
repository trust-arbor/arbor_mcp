defmodule Arbor.MCP.Examples.ForwardingGateway.Handler do
  @moduledoc false
  use Arbor.MCP.Server.Handler

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.Context

  @impl true
  def init(opts), do: {:ok, %{routes: Keyword.fetch!(opts, :routes)}}

  # Legacy capabilities are negotiated once, not carried on each request.
  # This fixture accepts only the same fixed profile as its identity-owned
  # upstream clients. A general host needs a profile per legacy session.
  @impl true
  def handle_initialize(params, state) do
    if params["protocolVersion"] == "2025-11-25" and
         params["capabilities"] == %{"elicitation" => %{"form" => %{}}} do
      {:ok,
       %{
         protocolVersion: "2025-11-25",
         serverInfo: %{name: "forwarding-example", version: "0"},
         capabilities: %{tools: %{listChanged: true}}
       }, state}
    else
      {:error,
       %{code: -32602, message: "This example requires its fixed legacy capability profile"},
       state}
    end
  end

  @impl true
  def handle_list_tools(_cursor, state) do
    tools =
      state.routes |> Map.values() |> Enum.map(& &1.definition) |> Enum.sort_by(& &1["name"])

    {:ok, tools, nil, state}
  end

  @impl true
  def handle_get_tool(name, state) do
    case Map.fetch(state.routes, name) do
      {:ok, route} -> {:ok, route.definition, state}
      :error -> {:error, %{code: -32602, message: "Unknown gateway tool"}, state}
    end
  end

  @impl true
  def handle_call_tool(name, arguments, state) do
    cond do
      Context.current().application_context.batch? ->
        {:error, %{code: -32602, message: "Tool-call batches are outside this example"}, state}

      not is_nil(Context.input_responses()) and is_nil(Context.request_state()) ->
        {:error, %{code: -32602, message: "Input responses require a verified continuation"},
         state}

      true ->
        dispatch(name, arguments, state)
    end
  end

  defp dispatch(name, arguments, state) do
    case Map.fetch(state.routes, name) do
      {:ok, route} -> forward(route, arguments, state)
      :error -> {:error, %{code: -32602, message: "Unknown gateway tool"}, state}
    end
  end

  defp forward(route, arguments, state) do
    context = Context.current()

    arguments =
      if context.application_context.caller_argument_meta?,
        do: arguments,
        else: Map.delete(arguments, "_meta")

    continuation = Context.request_state() || %{}

    deadline =
      min(
        context.application_context.deadline,
        continuation["deadline"] || context.application_context.deadline
      )

    token =
      continuation["token"] || Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      opts = [
        mrtr: :manual,
        format: :map,
        timeout: remaining,
        client_capabilities: forwarded_capabilities(context),
        input_responses: Context.input_responses(),
        request_state: continuation["upstream"],
        progress_token: token,
        progress_to: self(),
        retry_policy: [max_attempts: 1],
        http_stream_retry: :safe_only
      ]

      task = Task.async(fn -> safe_call(route, arguments, opts) end)

      try do
        case await(task, route.client, token, deadline) do
          {:input_required, %{input_requests: requests, request_state: upstream}} ->
            {:input_required, requests,
             %{"upstream" => upstream, "token" => token, "deadline" => deadline}, state}

          {:ok, result} ->
            {:ok, result, state}

          {:error, _reason} ->
            failed(state)
        end
      after
        Task.shutdown(task, :brutal_kill)
      end
    else
      failed(state)
    end
  end

  defp safe_call(route, arguments, opts) do
    Client.call_tool(route.client, route.name, arguments, opts)
  rescue
    _error -> {:error, :upstream_failed}
  catch
    :exit, _reason -> {:error, :upstream_failed}
  end

  defp forwarded_capabilities(%{era: :legacy}), do: nil

  defp forwarded_capabilities(%{client_capabilities: capabilities}) do
    case get_in(capabilities || %{}, ["elicitation", "form"]) do
      form when is_map(form) -> %{"elicitation" => %{"form" => form}}
      _absent -> %{}
    end
  end

  defp await(%Task{ref: ref} = task, client, token, deadline) do
    receive do
      {:arbor_mcp_progress, ^client, ^token, %{"progress" => progress} = params} ->
        case Context.report_progress(progress, params["total"], params["message"]) do
          :ok -> await(task, client, token, deadline)
          {:error, :progress_not_requested} -> await(task, client, token, deadline)
          {:error, _reason} -> {:error, :downstream_closed}
        end

      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:arbor_mcp_cancelled, _invocation, _reason} ->
        {:error, :cancelled}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :timeout}
    end
  end

  defp failed(state), do: {:error, %{code: -32603, message: "Upstream request failed"}, state}
end

defmodule Arbor.MCP.Examples.ForwardingGateway.HTTPPlug do
  @moduledoc false
  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Map.fetch(Keyword.fetch!(opts, :identities), token) do
          {:ok, %{runtime: runtime, principal: principal}} ->
            deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 5_000)

            mount =
              Arbor.MCP.HttpPlug.init(
                runtime: runtime,
                path: "/mcp",
                sse_mode: :stream,
                allowed_hosts: ["127.0.0.1"],
                allowed_origins: ["http://127.0.0.1:#{conn.port}"],
                protocol_mode: Keyword.get(opts, :protocol_mode, :prefer_modern),
                principal_id: principal,
                tenant_id: "example",
                handler_opts: fn _conn, request ->
                  caller_meta? =
                    case request do
                      %{"params" => %{"arguments" => args}} when is_map(args) ->
                        Map.has_key?(args, "_meta")

                      _other ->
                        false
                    end

                  %{
                    deadline: deadline,
                    caller_argument_meta?: caller_meta?,
                    batch?: is_list(request)
                  }
                end,
                subscription_keepalive_interval_ms: 100,
                request_keepalive_interval_ms: 100,
                authorize_subscription_filter: fn filter, context ->
                  if context.principal_id == principal,
                    do: {:ok, Map.take(filter, ["toolsListChanged"])},
                    else: {:error, :not_authorized}
                end,
                authorize_subscription_publication: fn _method, _params, context ->
                  context.principal_id == principal
                end
              )

            Arbor.MCP.HttpPlug.call(conn, mount)

          :error ->
            unauthorized(conn)
        end

      _other ->
        unauthorized(conn)
    end
  end

  defp unauthorized(conn), do: conn |> send_resp(401, "Unauthorized") |> halt()
end

defmodule Arbor.MCP.Examples.ForwardingGateway.Watcher do
  @moduledoc false
  use GenServer

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.Subscription

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ready(pid), do: GenServer.call(pid, :ready, 5_000)

  @impl true
  def init(opts),
    do: {:ok, %{runtime: opts[:runtime], clients: opts[:clients], feeds: %{}}, {:continue, :open}}

  @impl true
  def handle_continue(:open, state) do
    feeds =
      Map.new(state.clients, fn client ->
        {:ok, feed} = Client.listen(client, %{"toolsListChanged" => true})
        {feed.pid, feed}
      end)

    {:noreply, %{state | feeds: feeds}}
  end

  @impl true
  def handle_call(:ready, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info(
        {:ex_mcp_subscription, %Subscription.Ref{pid: pid}, "notifications/tools/list_changed",
         _params},
        state
      ) do
    if Map.has_key?(state.feeds, pid), do: Arbor.MCP.Server.notify_tools_changed(state.runtime)
    {:noreply, state}
  end

  def handle_info(
        {:ex_mcp_subscription_resync, %Subscription.Ref{pid: pid} = feed, {:complete, _snapshot}},
        state
      ) do
    if Map.has_key?(state.feeds, pid) do
      Arbor.MCP.Server.notify_tools_changed(state.runtime)
      {:noreply, put_in(state.feeds[pid], feed)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:ex_mcp_subscription_resync, _pid, :started}, state), do: {:noreply, state}

  def handle_info({:ex_mcp_subscription_closed, _feed, _reason}, state),
    do: {:stop, :upstream_subscription_closed, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.feeds, fn {_pid, feed} -> Subscription.cancel(feed) end)
  end
end
