defmodule Arbor.MCP.Transport.HTTP.TargetPolicy do
  @moduledoc false

  import Bitwise

  alias Arbor.MCP.Internal.{DNSResolver, NetworkPolicy}

  @default_dns_timeout_ms 1_000

  @type error_reason ::
          :invalid_http_url
          | :invalid_network_policy
          | :dns_failed
          | :dns_timeout
          | :non_public_address
          | :non_loopback_address

  @doc "Resolves and validates every address, returning one address to pin for this request."
  @spec resolve(String.t(), keyword()) ::
          {:ok, URI.t(), :inet.ip_address()} | {:error, error_reason()}
  def resolve(url, opts \\ [])

  def resolve(url, opts) when is_binary(url) and is_list(opts) do
    with :ok <- validate_options(opts),
         {:ok, uri} <- parse_url(url),
         {:ok, addresses} <- resolve_addresses(uri.host, opts),
         :ok <- validate_addresses(uri.host, addresses, opts) do
      {:ok, uri, addresses |> Enum.sort() |> hd()}
    end
  end

  def resolve(_url, _opts), do: {:error, :invalid_http_url}

  @doc false
  @spec validate_options(keyword()) :: :ok | {:error, :invalid_network_policy}
  def validate_options(opts) when is_list(opts) do
    timeout = Keyword.get(opts, :dns_timeout_ms, @default_dns_timeout_ms)
    resolver = Keyword.get(opts, :dns_resolver, DNSResolver)
    private_hosts = Keyword.get(opts, :allowed_private_hosts, [])

    cond do
      not is_integer(timeout) or timeout <= 0 ->
        {:error, :invalid_network_policy}

      not valid_resolver?(resolver) ->
        {:error, :invalid_network_policy}

      not is_list(private_hosts) or not Enum.all?(private_hosts, &valid_host_entry?/1) ->
        {:error, :invalid_network_policy}

      true ->
        :ok
    end
  end

  def validate_options(_opts), do: {:error, :invalid_network_policy}

  defp parse_url(url) do
    case URI.new(url) do
      {:ok, %URI{} = uri} ->
        cond do
          uri.scheme not in ["http", "https"] -> {:error, :invalid_http_url}
          not is_binary(uri.host) or uri.host == "" -> {:error, :invalid_http_url}
          not is_nil(uri.userinfo) or not is_nil(uri.fragment) -> {:error, :invalid_http_url}
          uri.port && uri.port not in 1..65_535 -> {:error, :invalid_http_url}
          true -> {:ok, uri}
        end

      {:error, _reason} ->
        {:error, :invalid_http_url}
    end
  end

  defp resolve_addresses(host, opts) do
    timeout = Keyword.get(opts, :dns_timeout_ms, @default_dns_timeout_ms)
    resolver = Keyword.get(opts, :dns_resolver, DNSResolver)

    result =
      cond do
        is_function(resolver, 2) -> resolver.(host, timeout)
        is_atom(resolver) -> resolver.resolve(host, timeout)
      end

    case result do
      {:ok, addresses} when is_list(addresses) and addresses != [] ->
        if Enum.all?(addresses, &valid_address?/1),
          do: {:ok, Enum.uniq(addresses)},
          else: {:error, :dns_failed}

      {:error, :dns_timeout} ->
        {:error, :dns_timeout}

      _other ->
        {:error, :dns_failed}
    end
  rescue
    _exception -> {:error, :dns_failed}
  catch
    _kind, _reason -> {:error, :dns_failed}
  end

  # Validate the complete answer set before choosing an address. A mixed
  # public/private answer therefore fails rather than creating a DNS-rebinding
  # race between policy evaluation and connection establishment.
  defp validate_addresses(host, addresses, opts) do
    normalized_host = normalize_host(host)

    cond do
      loopback_host?(normalized_host) ->
        if Enum.all?(addresses, &loopback_address?/1),
          do: :ok,
          else: {:error, :non_loopback_address}

      normalized_host in normalized_private_hosts(opts) ->
        if Enum.all?(addresses, &(NetworkPolicy.public_address?(&1) or private_address?(&1))),
          do: :ok,
          else: {:error, :non_public_address}

      Enum.all?(addresses, &NetworkPolicy.public_address?/1) ->
        :ok

      true ->
        {:error, :non_public_address}
    end
  end

  defp normalized_private_hosts(opts) do
    opts
    |> Keyword.get(:allowed_private_hosts, [])
    |> Enum.map(&normalize_host/1)
  end

  defp valid_host_entry?(host) when is_binary(host) do
    trimmed = String.trim(host)
    normalized = normalize_host(trimmed)

    trimmed == host and normalized != "" and
      not String.contains?(normalized, ["/", "@", "?", "#", "*"])
  end

  defp valid_host_entry?(_host), do: false

  defp normalize_host("[" <> rest) do
    rest |> String.trim_trailing("]") |> String.downcase()
  end

  defp normalize_host(host), do: host |> String.trim() |> String.downcase()

  defp loopback_host?("localhost"), do: true

  defp loopback_host?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> loopback_address?(address)
      {:error, _reason} -> false
    end
  end

  defp loopback_address?({127, _b, _c, _d}), do: true
  defp loopback_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_address?(_address), do: false

  defp private_address?({10, _b, _c, _d}), do: true
  defp private_address?({172, b, _c, _d}) when b in 16..31, do: true
  defp private_address?({192, 168, _c, _d}), do: true

  defp private_address?({first, _b, _c, _d, _e, _f, _g, _h}),
    do: (first &&& 0xFE00) == 0xFC00

  defp private_address?(_address), do: false

  defp valid_address?({a, b, c, d}),
    do: Enum.all?([a, b, c, d], &(&1 in 0..255))

  defp valid_address?({a, b, c, d, e, f, g, h}),
    do: Enum.all?([a, b, c, d, e, f, g, h], &(&1 in 0..65_535))

  defp valid_address?(_address), do: false

  defp valid_resolver?(resolver) when is_function(resolver, 2), do: true

  defp valid_resolver?(resolver) when is_atom(resolver) do
    Code.ensure_loaded?(resolver) and function_exported?(resolver, :resolve, 2)
  end

  defp valid_resolver?(_resolver), do: false
end
