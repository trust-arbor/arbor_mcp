defmodule Arbor.MCP.Authorization.MetadataFetcher do
  @moduledoc """
  Fail-closed HTTP fetch boundary for OAuth metadata documents.

  Fetches use HTTPS by default, reject userinfo and fragments, resolve and
  validate every address on every hop, pin the connection to one approved
  public address, and follow only bounded same-origin redirects unless another
  exact HTTPS origin is explicitly allowed. Tests and local development may
  explicitly allow plain HTTP on loopback addresses. Requests carry fixed
  metadata headers and never inherit authorization, cookie, or application
  transport headers.
  """

  alias Arbor.MCP.Authorization.MetadataHTTPClient
  alias Arbor.MCP.Internal.{DNSResolver, NetworkPolicy}

  @redirect_statuses [301, 302, 303, 307, 308]
  @option_keys [
    :max_redirects,
    :max_response_bytes,
    :max_aggregate_bytes,
    :dns_timeout_ms,
    :connect_timeout_ms,
    :request_timeout_ms,
    :allowed_redirect_origins,
    :allow_insecure_loopback,
    :dns_resolver,
    :http_client
  ]
  @integer_options [
    :max_redirects,
    :max_response_bytes,
    :max_aggregate_bytes,
    :dns_timeout_ms,
    :connect_timeout_ms,
    :request_timeout_ms
  ]
  @request_headers [
    {"accept", "application/json"},
    {"accept-encoding", "identity"},
    {"user-agent", "ex_mcp-oauth-metadata"}
  ]
  @defaults [
    max_redirects: 3,
    max_response_bytes: 262_144,
    max_aggregate_bytes: 524_288,
    dns_timeout_ms: 1_000,
    connect_timeout_ms: 2_000,
    request_timeout_ms: 5_000,
    allowed_redirect_origins: [],
    allow_insecure_loopback: false,
    dns_resolver: DNSResolver,
    http_client: MetadataHTTPClient
  ]

  @type fetch_error :: {:metadata_fetch_error, atom()}
  @type response :: %{
          status: pos_integer(),
          headers: [{String.t(), String.t()}],
          body: binary(),
          final_url: String.t()
        }

  @doc "Fetches one OAuth metadata document through the hardened network boundary."
  @spec fetch(String.t(), keyword()) :: {:ok, response()} | {:error, fetch_error()}
  def fetch(url, opts \\ [])

  def fetch(url, opts) when is_binary(url) and is_list(opts) do
    opts = options(opts)

    with :ok <- validate_options(opts),
         {:ok, uri} <- parse_uri(url) do
      fetch_with_redirects(uri, opts, 0, [], 0)
    end
  end

  def fetch(_url, _opts), do: metadata_error(:invalid_uri)

  @doc "Validates the URL form accepted by the metadata fetch boundary."
  @spec validate_url(String.t(), keyword()) :: :ok | {:error, fetch_error()}
  def validate_url(url, opts \\ [])

  def validate_url(url, opts) when is_binary(url) and is_list(opts) do
    opts = options(opts)

    with :ok <- validate_options(opts),
         {:ok, uri} <- parse_uri(url) do
      validate_uri(uri, opts)
    end
  end

  def validate_url(_url, _opts), do: metadata_error(:invalid_uri)

  @doc false
  @spec options(keyword()) :: keyword()
  def options(overrides) do
    configured = Application.get_env(:arbor_mcp, :oauth_metadata_fetch, [])
    configured = if is_list(configured), do: configured, else: []

    @defaults
    |> Keyword.merge(Keyword.take(configured, @option_keys))
    |> Keyword.merge(Keyword.take(overrides, @option_keys))
    |> Keyword.put(:request_headers, @request_headers)
  end

  defp fetch_with_redirects(uri, opts, redirect_count, visited, aggregate_bytes) do
    canonical = canonical_uri(uri)

    with :ok <- check_redirect_count(redirect_count, opts),
         :ok <- check_redirect_cycle(canonical, visited),
         {:ok, address} <- validate_target(uri, opts),
         {:ok, response} <- fetch(uri, address, opts),
         :ok <- validate_response(response, opts),
         {:ok, next_aggregate} <-
           add_aggregate_bytes(aggregate_bytes, byte_size(response.body), opts) do
      if response.status in @redirect_statuses do
        with {:ok, redirected_uri} <- redirect_uri(uri, response.headers, opts),
             :ok <- validate_redirect_origin(uri, redirected_uri, opts) do
          fetch_with_redirects(
            redirected_uri,
            opts,
            redirect_count + 1,
            [canonical | visited],
            next_aggregate
          )
        end
      else
        {:ok, Map.put(response, :final_url, to_string(uri))}
      end
    end
  end

  defp validate_target(uri, opts) do
    with :ok <- validate_uri(uri, opts),
         {:ok, addresses} <- resolve_addresses(uri.host, opts),
         :ok <- validate_addresses(addresses, uri, opts) do
      {:ok, addresses |> Enum.sort() |> hd()}
    end
  end

  defp parse_uri(url) do
    case URI.new(url) do
      {:ok, %URI{} = uri} -> {:ok, uri}
      {:error, _reason} -> metadata_error(:invalid_uri)
    end
  end

  defp validate_uri(%URI{} = uri, opts) do
    cond do
      uri.scheme != "https" and not allowed_insecure_loopback?(uri, opts) ->
        metadata_error(:https_required)

      not is_nil(uri.userinfo) ->
        metadata_error(:userinfo_forbidden)

      not is_nil(uri.fragment) ->
        metadata_error(:fragment_forbidden)

      not is_binary(uri.host) or not valid_host?(uri.host) ->
        metadata_error(:invalid_uri)

      uri.port && uri.port not in 1..65_535 ->
        metadata_error(:invalid_uri)

      true ->
        :ok
    end
  end

  defp resolve_addresses(host, opts) do
    resolver = opts[:dns_resolver]

    result =
      run_bounded(
        fn ->
          cond do
            is_function(resolver, 2) -> resolver.(host, opts[:dns_timeout_ms])
            is_atom(resolver) -> resolver.resolve(host, opts[:dns_timeout_ms])
            true -> {:error, :dns_failed}
          end
        end,
        opts[:dns_timeout_ms],
        {:error, :dns_timeout}
      )

    case result do
      {:ok, addresses} when is_list(addresses) and addresses != [] ->
        {:ok, Enum.uniq(addresses)}

      {:error, :dns_timeout} ->
        metadata_error(:dns_timeout)

      _other ->
        metadata_error(:dns_failed)
    end
  rescue
    _exception -> metadata_error(:dns_failed)
  end

  defp validate_addresses(addresses, uri, opts) do
    valid? =
      if allowed_insecure_loopback?(uri, opts) do
        Enum.all?(addresses, &loopback_address?/1)
      else
        Enum.all?(addresses, &NetworkPolicy.public_address?/1)
      end

    if valid?, do: :ok, else: metadata_error(:non_public_address)
  end

  defp fetch(uri, address, opts) do
    client = opts[:http_client]
    timeout = opts[:connect_timeout_ms] + opts[:request_timeout_ms]

    result =
      run_bounded(
        fn ->
          cond do
            is_function(client, 3) -> client.(uri, address, opts)
            is_atom(client) -> client.get(uri, address, opts)
            true -> {:error, :fetch_failed}
          end
        end,
        timeout,
        {:error, :request_timeout}
      )

    case result do
      {:ok, %{status: status, headers: headers, body: body}}
      when is_integer(status) and is_list(headers) and is_binary(body) ->
        {:ok, %{status: status, headers: normalize_headers(headers), body: body}}

      {:error, :response_too_large} ->
        metadata_error(:response_too_large)

      {:error, :request_timeout} ->
        metadata_error(:request_timeout)

      _other ->
        metadata_error(:fetch_failed)
    end
  rescue
    _exception -> metadata_error(:fetch_failed)
  end

  defp validate_response(response, opts) do
    cond do
      compressed?(response.headers) -> metadata_error(:compressed_response)
      byte_size(response.body) > opts[:max_response_bytes] -> metadata_error(:response_too_large)
      true -> :ok
    end
  end

  defp redirect_uri(base, headers, opts) do
    case header_values(headers, "location") do
      [location] ->
        redirected = URI.merge(base, location)

        with :ok <- validate_uri(redirected, opts) do
          {:ok, redirected}
        end

      [] ->
        metadata_error(:missing_redirect_location)

      _multiple ->
        metadata_error(:invalid_redirect)
    end
  rescue
    _exception -> metadata_error(:invalid_redirect)
  end

  defp validate_redirect_origin(source, target, opts) do
    target_origin = origin(target)

    if target_origin == origin(source) or target_origin in opts[:allowed_redirect_origins],
      do: :ok,
      else: metadata_error(:cross_origin_redirect)
  end

  defp allowed_insecure_loopback?(%URI{scheme: "http", host: host}, opts) do
    opts[:allow_insecure_loopback] == true and host in ["localhost", "127.0.0.1", "::1"]
  end

  defp allowed_insecure_loopback?(_uri, _opts), do: false

  defp loopback_address?({127, _b, _c, _d}), do: true
  defp loopback_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_address?(_address), do: false

  defp check_redirect_count(count, opts) do
    if count <= opts[:max_redirects],
      do: :ok,
      else: metadata_error(:redirect_limit)
  end

  defp check_redirect_cycle(canonical, visited) do
    if canonical in visited,
      do: metadata_error(:redirect_cycle),
      else: :ok
  end

  defp add_aggregate_bytes(current, additional, opts) do
    total = current + additional

    if total <= opts[:max_aggregate_bytes],
      do: {:ok, total},
      else: metadata_error(:aggregate_response_too_large)
  end

  defp validate_options(opts) do
    with :ok <- validate_integer_options(opts),
         :ok <- validate_boolean(opts[:allow_insecure_loopback]),
         :ok <- validate_redirect_origins(opts[:allowed_redirect_origins]),
         :ok <- validate_callback(opts[:dns_resolver], :resolve, 2) do
      validate_callback(opts[:http_client], :get, 3)
    end
  end

  defp validate_integer_options(opts) do
    if Enum.all?(@integer_options, &(is_integer(opts[&1]) and opts[&1] >= 0)),
      do: :ok,
      else: metadata_error(:invalid_options)
  end

  defp validate_redirect_origins(origins) when is_list(origins) do
    if Enum.all?(origins, &valid_origin?/1),
      do: :ok,
      else: metadata_error(:invalid_options)
  end

  defp validate_redirect_origins(_origins), do: metadata_error(:invalid_options)

  defp validate_boolean(value) when is_boolean(value), do: :ok
  defp validate_boolean(_value), do: metadata_error(:invalid_options)

  defp valid_origin?(value) when is_binary(value) do
    case parse_uri(value) do
      {:ok, uri} -> validate_uri(uri, @defaults) == :ok and value == origin(uri)
      {:error, _reason} -> false
    end
  end

  defp valid_origin?(_value), do: false

  defp validate_callback(callback, _function, arity) when is_function(callback, arity), do: :ok

  defp validate_callback(module, function, arity) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, arity),
      do: :ok,
      else: metadata_error(:invalid_options)
  end

  defp validate_callback(_callback, _function, _arity), do: metadata_error(:invalid_options)

  defp run_bounded(fun, timeout, timeout_result) do
    owner = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result =
          try do
            fun.()
          rescue
            _exception -> {:error, :worker_failed}
          catch
            _kind, _reason -> {:error, :worker_failed}
          end

        send(owner, {result_ref, result})
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        {:error, :worker_failed}
    after
      timeout ->
        Process.exit(pid, :kill)
        await_worker_exit(monitor_ref, pid)
        timeout_result
    end
  end

  defp await_worker_exit(monitor_ref, pid) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      0 -> Process.demonitor(monitor_ref, [:flush])
    end
  end

  defp normalize_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {String.downcase(to_string(name)), to_string(value)}
    end)
  end

  defp header_values(headers, name) do
    for {^name, value} <- headers, do: String.trim(value)
  end

  defp compressed?(headers) do
    Enum.any?(header_values(headers, "content-encoding"), fn value ->
      String.downcase(value) not in ["", "identity"]
    end)
  end

  defp valid_host?(host) do
    byte_size(host) <= 253 and String.match?(host, ~r/^[A-Za-z0-9.:-]+$/)
  end

  defp canonical_uri(uri) do
    uri
    |> Map.put(:scheme, String.downcase(uri.scheme))
    |> Map.put(:host, normalize_host(uri.host))
    |> Map.put(:port, canonical_port(uri))
    |> Map.put(:path, uri.path || "/")
    |> Map.put(:fragment, nil)
    |> to_string()
  end

  defp canonical_port(%URI{scheme: "https", port: 443}), do: nil
  defp canonical_port(uri), do: uri.port

  defp origin(uri) do
    host = normalize_host(uri.host)
    port = uri.port || 443
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host
    if port == 443, do: "https://#{host}", else: "https://#{host}:#{port}"
  end

  defp normalize_host(host), do: host |> String.downcase() |> String.trim_trailing(".")

  defp metadata_error(reason), do: {:error, {:metadata_fetch_error, reason}}
end
