defmodule Arbor.MCP.Internal.DNSResolver do
  @moduledoc false

  @spec resolve(String.t(), non_neg_integer()) ::
          {:ok, [:inet.ip_address()]} | {:error, :dns_failed | :dns_timeout}
  def resolve(host, timeout_ms) when is_binary(host) and is_integer(timeout_ms) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, :einval} ->
        resolve_hostname(host, timeout_ms)
    end
  end

  defp resolve_hostname(host, timeout_ms) do
    task =
      Arbor.MCP.Client.ConnectionScope.async(fn ->
        hostname = String.to_charlist(host)

        addresses =
          [:inet, :inet6]
          |> Enum.flat_map(fn family ->
            case :inet.getaddrs(hostname, family) do
              {:ok, found} -> found
              {:error, _reason} -> []
            end
          end)
          |> Enum.uniq()

        if addresses == [], do: {:error, :dns_failed}, else: {:ok, addresses}
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      {:exit, _reason} ->
        {:error, :dns_failed}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :dns_timeout}
    end
  end
end
