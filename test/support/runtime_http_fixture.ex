defmodule Arbor.MCP.Test.RuntimeHTTPFixture do
  @moduledoc false

  alias Arbor.MCP.HttpPlug
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.SessionManager
  alias Arbor.MCP.SessionManager.SessionLease

  defmodule EmptyHandler do
    @moduledoc false
    use Arbor.MCP.Server.Handler
  end

  def start(handler \\ EmptyHandler, opts \\ []) do
    root =
      ExUnit.Callbacks.start_supervised!(
        {Runtime, Keyword.merge([handler: handler, transport: :mounted_http], opts)},
        id: make_ref()
      )

    {:ok, ref} = Runtime.ref(root)
    ref
  end

  def options(runtime, opts \\ []), do: HttpPlug.init(Keyword.put(opts, :runtime, runtime))

  def session(runtime, initialized \\ true, metadata \\ %{}) do
    {:ok, service} = Runtime.service(runtime, :sessions)

    {:ok, lease} =
      SessionManager.create_session(
        service,
        Map.merge(%{transport: :http, transport_endpoint: "/mcp"}, metadata),
        []
      )

    if initialized do
      {:ok, claim} = SessionManager.claim_initialization(service, lease, [])
      :ok = SessionManager.complete_initialization(service, claim, "2025-06-18", [])
    end

    SessionLease.id(lease)
  end

  def session_state(runtime, id) do
    {:ok, service} = Runtime.service(runtime, :sessions)

    with {:ok, lease} <- SessionManager.ensure_session(service, id, %{}, []),
         do: SessionManager.get_session(service, lease, [])
  end
end
