defmodule Arbor.MCP.Server.HTTP.Bandit.Dynamic do
  @moduledoc false
  use DynamicSupervisor

  alias Arbor.MCP.Server.Runtime.{Initialization, Ref}

  def start_link(runtime, options),
    do:
      DynamicSupervisor.start_link(__MODULE__, fn -> {runtime, options} end,
        timeout: Initialization.remaining(Ref.table(runtime))
      )

  @impl true
  def init(constructor) do
    {runtime, options} = constructor.()

    with :ok <- Initialization.watch(Ref.table(runtime), self()),
         do: DynamicSupervisor.init(options)
  end
end
