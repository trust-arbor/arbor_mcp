defmodule Arbor.MCP.Protocol.Elicitation do
  @moduledoc false

  alias Arbor.MCP.Content.SchemaPolicy
  alias Arbor.MCP.Server.Runtime.{Deadline, OutputCodec}

  # Exact ElicitRequestParams and its transitive definitions from the pinned
  # 2026-07-28 primary schema. Includes legacy form/URL parameter shapes.
  @external_resource Path.join(__DIR__, "elicitation_schema.json")
  @schema @external_resource |> File.read!() |> Jason.decode!()

  def validate(params, deadline) do
    with remaining when remaining > 0 <- Deadline.remaining(deadline),
         {:ok, prepared} <-
           OutputCodec.prepare(params,
             codec: :protocol,
             deadline: deadline,
             max_frame_bytes: 65_536,
             max_term_bytes: 65_536
           ),
         normalized = Jason.decode!(prepared.wire),
         :ok <-
           SchemaPolicy.validate(normalized, @schema,
             max_instance_bytes: 65_536,
             max_instance_depth: 32,
             resolve_timeout_ms: min(250, remaining),
             validation_timeout_ms: min(100, remaining)
           ),
         true <- deadline > Deadline.now() do
      {:ok, normalized}
    else
      _invalid -> {:error, :invalid_elicitation_params}
    end
  end
end
