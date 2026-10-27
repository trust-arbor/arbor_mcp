defmodule ExMCP.Internal.JSONRPC do
  @moduledoc false

  @jsonrpc "2.0"

  @type id :: String.t() | integer() | nil
  @type method :: String.t()
  @type params :: map()

  @spec request(method()) :: map()
  def request(method) when is_binary(method) do
    %{"jsonrpc" => @jsonrpc, "method" => method}
  end

  @spec request(method(), params()) :: map()
  def request(method, params) when is_binary(method) and is_map(params) do
    method
    |> request()
    |> with_params(params)
  end

  @spec request(method(), params(), id()) :: map()
  def request(method, params, id) when is_binary(method) and is_map(params) do
    method
    |> request(params)
    |> with_id(id)
  end

  @spec notification(method(), params()) :: map()
  def notification(method, params \\ %{}) when is_binary(method) and is_map(params) do
    request(method, params)
  end

  @spec response(id(), any()) :: map()
  def response(id, result) do
    %{"jsonrpc" => @jsonrpc, "id" => id, "result" => result}
  end

  @spec error(id(), map()) :: map()
  def error(id, %{} = error) do
    %{"jsonrpc" => @jsonrpc, "id" => id, "error" => error}
  end

  @spec error(id(), integer(), String.t(), any()) :: map()
  def error(id, code, message, data \\ nil) when is_integer(code) and is_binary(message) do
    error =
      %{"code" => code, "message" => message}
      |> put_present("data", data)

    error(id, error)
  end

  @spec with_params(map(), params()) :: map()
  def with_params(envelope, params) when is_map(envelope) and is_map(params) do
    Map.put(envelope, "params", params)
  end

  @spec with_id(map(), id()) :: map()
  def with_id(envelope, id) when is_map(envelope) do
    Map.put(envelope, "id", id)
  end

  @spec parse_unvalidated(String.t() | map() | list()) ::
          {:request, method(), params(), id()}
          | {:notification, method(), params()}
          | {:result, any(), id()}
          | {:error, map(), id()}
          | {:batch, list()}
          | {:error, :invalid_message}
  def parse_unvalidated(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, decoded} -> parse_unvalidated(decoded)
      {:error, _} -> {:error, :invalid_message}
    end
  end

  def parse_unvalidated(%{"jsonrpc" => @jsonrpc, "result" => result, "id" => id}) do
    {:result, result, id}
  end

  def parse_unvalidated(%{"jsonrpc" => @jsonrpc, "error" => error, "id" => id}) do
    {:error, error, id}
  end

  def parse_unvalidated(%{
        "jsonrpc" => @jsonrpc,
        "method" => method,
        "params" => params,
        "id" => id
      }) do
    {:request, method, params, id}
  end

  def parse_unvalidated(%{"jsonrpc" => @jsonrpc, "method" => method, "params" => params}) do
    {:notification, method, params}
  end

  def parse_unvalidated(messages) when is_list(messages), do: {:batch, messages}
  def parse_unvalidated(_message), do: {:error, :invalid_message}

  @spec generate_id() :: integer()
  def generate_id do
    System.unique_integer([:positive, :monotonic])
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
