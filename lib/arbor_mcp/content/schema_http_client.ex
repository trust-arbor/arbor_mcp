defmodule Arbor.MCP.Content.SchemaHTTPClient do
  @moduledoc false

  alias Arbor.MCP.Internal.PinnedHTTPClient

  @type response :: %{
          required(:status) => pos_integer(),
          required(:headers) => [{String.t(), String.t()}],
          required(:body) => binary()
        }

  @spec get(URI.t(), :inet.ip_address(), keyword()) ::
          {:ok, response()} | {:error, :fetch_failed | :response_too_large}
  def get(%URI{} = uri, address, opts) do
    headers = [
      {"accept", "application/schema+json, application/json"},
      {"accept-encoding", "identity"},
      {"user-agent", "ex_mcp-json-schema-resolver"}
    ]

    PinnedHTTPClient.get(uri, address, Keyword.put(opts, :request_headers, headers))
  end
end
