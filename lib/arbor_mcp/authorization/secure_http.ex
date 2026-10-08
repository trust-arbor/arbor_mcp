defmodule Arbor.MCP.Authorization.SecureHTTP do
  @moduledoc """
  Bounded, redirect-free HTTP boundary for OAuth protocol requests.

  The destination is resolved once, every returned address is checked against
  the network policy, and the request URL is rewritten to the selected address.
  The original host is retained in the HTTP `Host` header and TLS SNI, so DNS
  cannot be re-resolved between validation and connection establishment.
  Response bodies are read incrementally and the connection is closed as soon
  as the configured size limit is exceeded.

  Plain HTTP is accepted only for loopback development endpoints. Private
  HTTPS endpoints are rejected by default and may be enabled only by listing
  their exact hostname in `:allowed_private_hosts`.
  """

  alias Arbor.MCP.Authorization.PinnedHTTPClient
  alias Arbor.MCP.Internal.{CACerts, DNSResolver, NetworkPolicy}

  @default_options [
    dns_timeout_ms: 1_000,
    connect_timeout_ms: 2_000,
    request_timeout_ms: 5_000,
    max_request_bytes: 1_048_576,
    max_response_bytes: 1_048_576,
    max_header_bytes: 65_536,
    allow_insecure_loopback: true,
    allowed_private_hosts: [],
    dns_resolver: DNSResolver
  ]

  @option_keys Keyword.keys(@default_options) ++
                 [:cacerts, :request_fun, :ssl_options]

  @type response ::
          {{String.t() | charlist(), non_neg_integer(), String.t() | charlist()}, list(),
           binary()}

  @doc """
  Sends one request through the hardened OAuth HTTP boundary.

  The response shape matches `:httpc.request/4`, but the body is always a
  binary. Redirects are returned to the caller and are never followed.
  """
  @spec request(atom(), String.t(), [{String.t(), String.t()}], iodata() | nil, keyword()) ::
          {:ok, response()} | {:error, term()}
  def request(method, url, headers \\ [], body \\ nil, opts \\ [])

  def request(method, url, headers, body, opts)
      when method in [:get, :post, :put, :delete] and is_binary(url) and is_list(headers) and
             is_list(opts) do
    opts = options(opts)

    with :ok <- validate_options(opts),
         {:ok, uri, address} <- resolve_target(url, opts),
         {:ok, body} <- normalize_request_body(body, opts),
         {:ok, request} <- build_request(method, uri, address, headers, body),
         :ok <- ensure_ssl_started(),
         result <- perform_request(method, request, uri, address, opts) do
      normalize_response(result, opts)
    end
  end

  def request(_method, _url, _headers, _body, _opts), do: {:error, :invalid_request}

  @doc """
  Validates and resolves a URL under the same policy used by `request/5`.

  The returned address is the address that a caller must connect to in order
  to preserve the validation result.
  """
  @spec resolve_target(String.t(), keyword()) ::
          {:ok, URI.t(), :inet.ip_address()} | {:error, term()}
  def resolve_target(url, opts \\ []) when is_binary(url) and is_list(opts) do
    opts = options(opts)

    with :ok <- validate_options(opts),
         {:ok, uri} <- parse_uri(url),
         :ok <- validate_uri(uri, opts),
         {:ok, addresses} <- resolve_addresses(uri.host, opts),
         :ok <- validate_addresses(uri, addresses, opts) do
      {:ok, uri, addresses |> Enum.sort() |> hd()}
    end
  end

  @doc "Returns the effective configuration after application and call overrides."
  @spec options(keyword()) :: keyword()
  def options(overrides \\ []) when is_list(overrides) do
    configured = Application.get_env(:arbor_mcp, :oauth_http, [])
    configured = if is_list(configured), do: configured, else: []

    @default_options
    |> Keyword.merge(Keyword.take(configured, @option_keys))
    |> Keyword.merge(Keyword.take(overrides, @option_keys))
  end

  defp parse_uri(url) do
    if valid_uri_text?(url) do
      case URI.new(url) do
        {:ok, %URI{} = uri} -> {:ok, uri}
        {:error, _reason} -> {:error, :invalid_uri}
      end
    else
      {:error, :invalid_uri}
    end
  end

  defp validate_uri(%URI{} = uri, opts) do
    cond do
      not is_binary(uri.host) or not valid_host?(uri.host) ->
        {:error, :invalid_uri}

      uri.scheme == "https" ->
        validate_uri_components(uri)

      uri.scheme == "http" and opts[:allow_insecure_loopback] == true and
          literal_loopback_host?(uri.host) ->
        validate_uri_components(uri)

      uri.scheme == "http" ->
        {:error, :https_required}

      true ->
        {:error, :https_required}
    end
  end

  defp validate_uri_components(uri) do
    cond do
      not is_nil(uri.userinfo) -> {:error, :userinfo_forbidden}
      not is_nil(uri.fragment) -> {:error, :fragment_forbidden}
      uri.port && uri.port not in 1..65_535 -> {:error, :invalid_uri}
      true -> :ok
    end
  end

  defp resolve_addresses(host, opts) do
    resolver = opts[:dns_resolver]

    result =
      cond do
        is_function(resolver, 2) -> resolver.(host, opts[:dns_timeout_ms])
        is_atom(resolver) -> resolver.resolve(host, opts[:dns_timeout_ms])
        true -> {:error, :dns_failed}
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
  end

  defp validate_addresses(uri, addresses, opts) do
    normalized_host = String.downcase(uri.host)

    private_allowed? =
      normalized_host in Enum.map(opts[:allowed_private_hosts], &String.downcase/1)

    cond do
      Enum.all?(addresses, &NetworkPolicy.public_address?/1) ->
        :ok

      loopback_uri?(uri, opts) and Enum.all?(addresses, &loopback_address?/1) ->
        :ok

      uri.scheme == "https" and private_allowed? ->
        :ok

      true ->
        {:error, :non_public_address}
    end
  end

  defp loopback_uri?(uri, opts) do
    opts[:allow_insecure_loopback] == true and literal_loopback_host?(uri.host)
  end

  defp literal_loopback_host?(host),
    do: String.downcase(host) in ["localhost", "127.0.0.1", "::1"]

  defp loopback_address?({127, _b, _c, _d}), do: true
  defp loopback_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_address?(_address), do: false

  defp valid_address?({a, b, c, d}),
    do: Enum.all?([a, b, c, d], &(&1 in 0..255))

  defp valid_address?({a, b, c, d, e, f, g, h}),
    do: Enum.all?([a, b, c, d, e, f, g, h], &(&1 in 0..65_535))

  defp valid_address?(_address), do: false

  defp normalize_request_body(nil, _opts), do: {:ok, ""}

  defp normalize_request_body(body, opts) do
    body = IO.iodata_to_binary(body)

    if byte_size(body) <= opts[:max_request_bytes],
      do: {:ok, body},
      else: {:error, :request_too_large}
  rescue
    _exception -> {:error, :invalid_request_body}
  end

  defp build_request(method, uri, address, headers, body) do
    with {:ok, normalized_headers} <- normalize_request_headers(headers) do
      headers =
        normalized_headers
        |> delete_header("host")
        |> delete_header("accept-encoding")
        |> List.insert_at(0, {"host", authority(uri)})
        |> List.insert_at(1, {"accept-encoding", "identity"})
        |> Enum.map(fn {name, value} ->
          {String.to_charlist(name), String.to_charlist(value)}
        end)

      pinned_url =
        uri |> Map.put(:host, address_string(address)) |> URI.to_string() |> to_charlist()

      case method do
        method when method in [:get, :delete] ->
          {:ok, {pinned_url, headers}}

        method when method in [:post, :put] ->
          content_type =
            header_value(normalized_headers, "content-type") || "application/octet-stream"

          {:ok, {pinned_url, headers, to_charlist(content_type), body}}
      end
    end
  end

  defp normalize_request_headers(headers) do
    Enum.reduce_while(headers, {:ok, []}, fn
      {name, value}, {:ok, acc} ->
        name = to_string(name)
        value = to_string(value)

        if valid_header?(name, value) do
          {:cont, {:ok, [{String.downcase(name), value} | acc]}}
        else
          {:halt, {:error, :invalid_header}}
        end

      _other, _acc ->
        {:halt, {:error, :invalid_header}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp valid_header?(name, value) do
    name != "" and not String.contains?(name, ["\r", "\n", ":"]) and
      not String.contains?(value, ["\r", "\n"])
  end

  defp perform_request(method, request, uri, address, opts) do
    http_options = [
      timeout: opts[:request_timeout_ms],
      connect_timeout: opts[:connect_timeout_ms],
      autoredirect: false,
      ssl: ssl_options(uri, opts)
    ]

    request_options = [body_format: :binary]

    case opts[:request_fun] do
      fun when is_function(fun, 4) -> fun.(method, request, http_options, request_options)
      nil -> PinnedHTTPClient.request(method, uri, address, request, http_options, opts)
    end
  rescue
    _exception -> {:error, :request_failed}
  catch
    _kind, _reason -> {:error, :request_failed}
  end

  defp ssl_options(%URI{scheme: "https", host: host}, opts) do
    overrides =
      (opts[:ssl_options] || [])
      |> Keyword.drop([
        :verify,
        :server_name_indication,
        :customize_hostname_check,
        :verify_fun,
        :partial_chain,
        :versions,
        :cacerts,
        :cacertfile
      ])

    defaults = [
      verify: :verify_peer,
      cacerts: opts[:cacerts] || CACerts.get(),
      versions: [:"tlsv1.2", :"tlsv1.3"],
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    Keyword.merge(defaults, overrides)
  end

  defp ssl_options(_uri, _opts), do: []

  defp normalize_response({:ok, {{version, status, reason}, headers, body}}, opts)
       when is_integer(status) and is_list(headers) do
    body = IO.iodata_to_binary(body)

    cond do
      compressed_response?(headers) ->
        {:error, :compressed_response}

      response_length_too_large?(headers, body, opts[:max_response_bytes]) ->
        {:error, :response_too_large}

      true ->
        {:ok, {{version, status, reason}, headers, body}}
    end
  rescue
    _exception -> {:error, :invalid_response}
  end

  defp normalize_response({:error, _reason} = error, _opts), do: error
  defp normalize_response(_other, _opts), do: {:error, :invalid_response}

  defp response_length_too_large?(headers, body, max_bytes) do
    byte_size(body) > max_bytes or
      Enum.any?(headers, fn {name, value} ->
        if String.downcase(to_string(name)) == "content-length" do
          case Integer.parse(to_string(value)) do
            {length, ""} -> length > max_bytes
            _other -> true
          end
        else
          false
        end
      end)
  end

  defp compressed_response?(headers) do
    Enum.any?(headers, fn {name, value} ->
      String.downcase(to_string(name)) == "content-encoding" and
        String.downcase(String.trim(to_string(value))) not in ["", "identity"]
    end)
  end

  defp authority(uri) do
    host = if String.contains?(uri.host, ":"), do: "[#{uri.host}]", else: uri.host
    default_port = if uri.scheme == "https", do: 443, else: 80
    if uri.port && uri.port != default_port, do: "#{host}:#{uri.port}", else: host
  end

  defp address_string(address), do: address |> :inet.ntoa() |> to_string()

  defp delete_header(headers, name),
    do: Enum.reject(headers, fn {header_name, _value} -> header_name == name end)

  defp header_value(headers, name) do
    Enum.find_value(headers, fn
      {^name, value} -> value
      _header -> nil
    end)
  end

  defp validate_options(opts) do
    integer_keys = [
      :dns_timeout_ms,
      :connect_timeout_ms,
      :request_timeout_ms,
      :max_request_bytes,
      :max_response_bytes,
      :max_header_bytes
    ]

    valid? =
      Enum.all?([
        valid_positive_integer_options?(opts, integer_keys),
        is_boolean(opts[:allow_insecure_loopback]),
        valid_private_hosts?(opts[:allowed_private_hosts]),
        valid_resolver?(opts[:dns_resolver]),
        valid_optional_fun?(opts[:request_fun], 4),
        valid_optional_keyword?(opts[:ssl_options])
      ])

    if valid?, do: :ok, else: {:error, :invalid_options}
  end

  defp valid_positive_integer_options?(opts, keys) do
    Enum.all?(keys, &(is_integer(opts[&1]) and opts[&1] > 0))
  end

  defp valid_private_hosts?(hosts) when is_list(hosts), do: Enum.all?(hosts, &is_binary/1)
  defp valid_private_hosts?(_hosts), do: false

  defp valid_optional_fun?(nil, _arity), do: true
  defp valid_optional_fun?(fun, arity), do: is_function(fun, arity)

  defp valid_optional_keyword?(nil), do: true
  defp valid_optional_keyword?(value), do: Keyword.keyword?(value)

  defp valid_resolver?(resolver) when is_function(resolver, 2), do: true

  defp valid_resolver?(resolver) when is_atom(resolver) do
    Code.ensure_loaded?(resolver) and function_exported?(resolver, :resolve, 2)
  end

  defp valid_resolver?(_resolver), do: false

  defp valid_uri_text?(url) do
    byte_size(url) <= 8_192 and
      not String.contains?(url, ["\r", "\n", "\0"])
  end

  defp valid_host?(host) do
    byte_size(host) <= 253 and String.match?(host, ~r/^[A-Za-z0-9.:-]+$/)
  end

  defp ensure_ssl_started do
    case Application.ensure_all_started(:ssl) do
      {:ok, _apps} -> :ok
      {:error, reason} -> {:error, {:ssl_start_failed, reason}}
    end
  end
end
