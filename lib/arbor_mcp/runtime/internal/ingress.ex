defmodule Arbor.MCP.Server.Runtime.Internal.Ingress do
  @moduledoc false
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{Admission, Ref}

  def reserve_ingress(server, message, opts) do
    with {:ok, runtime} <- Runtime.ref(server) do
      opts = opts |> Keyword.put_new(:kind, :ingress) |> Keyword.put(:via_edge, true)
      Admission.reserve(runtime, %{"payload" => message}, opts)
    end
  end

  def publish_ingress(server, route, reservation, payload, edge) do
    with {:ok, runtime} <- Runtime.ref(server),
         do: Admission.publish(Ref.table(runtime), route, reservation, payload, edge)
  end

  def dispatch_reserved(server, token, request, opts \\ []) do
    with {:ok, runtime} <- Runtime.ref(server),
         {:ok, route} <- Admission.route(Ref.table(runtime)),
         {:ok, _reservation} <- Admission.promote(Ref.table(runtime), token, request, opts) do
      work_opts = [
        runtime: runtime,
        dispatch_opts: Keyword.get(opts, :dispatch_opts, []),
        output: Keyword.get(opts, :output),
        retain_reservation: Keyword.get(opts, :retain_reservation, false)
      ]

      send(route.scheduler, {:submit, route.generation, token, request, work_opts})
      {:ok, token}
    end
  end

  def discard_ingress(server, token) do
    with {:ok, runtime} <- Runtime.ref(server) do
      Admission.release(Ref.table(runtime), token)
    end
  end
end
