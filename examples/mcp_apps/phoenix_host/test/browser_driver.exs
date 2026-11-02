# Controlled stdin lifecycle for the repository's browser test. Not a web route.
parent = self()
handler_id = {:phoenix_apps_browser, make_ref()}

:ok =
  :telemetry.attach(
    handler_id,
    [:mcp_apps_host, :client, :opened],
    fn _event, _values, %{client: client}, _config -> send(parent, {:opened, client}) end,
    nil
  )

Task.start(fn ->
  IO.stream(:stdio, :line)
  |> Enum.each(fn line -> send(parent, {:command, String.trim(line)}) end)

  send(parent, {:command, "close"})
end)

IO.puts(
  Jason.encode!(%{
    origin: McpAppsHostWeb.Origins.host(),
    sandboxOrigin: McpAppsHostWeb.Origins.sandbox()
  })
)

loop = fn loop, monitored, observed ->
  receive do
    {:opened, client} ->
      loop.(
        loop,
        Map.put(monitored, Process.monitor(client), client),
        MapSet.put(observed, client)
      )

    {:DOWN, ref, :process, _client, _reason} ->
      loop.(loop, Map.delete(monitored, ref), observed)

    {:command, "await_closed"} ->
      deadline = System.monotonic_time(:millisecond) + 5_000

      wait = fn wait, refs ->
        if map_size(refs) == 0 do
          IO.puts(Jason.encode!(%{closed: true, observed: MapSet.size(observed)}))
        else
          receive do
            {:DOWN, ref, :process, _pid, _reason} -> wait.(wait, Map.delete(refs, ref))
          after
            max(deadline - System.monotonic_time(:millisecond), 0) ->
              IO.puts(Jason.encode!(%{closed: false, remaining: map_size(refs)}))
          end
        end
      end

      wait.(wait, monitored)
      loop.(loop, %{}, observed)

    {:command, "close"} ->
      :telemetry.detach(handler_id)
      System.stop(0)

    _other ->
      loop.(loop, monitored, observed)
  end
end

loop.(loop, %{}, MapSet.new())
