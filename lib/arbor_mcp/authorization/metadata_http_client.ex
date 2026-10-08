defmodule Arbor.MCP.Authorization.MetadataHTTPClient do
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
    PinnedHTTPClient.get(uri, address, opts)
  end
end
