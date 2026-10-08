defmodule Arbor.MCP.Internal.CACerts do
  @moduledoc false

  # Default trust anchors for outbound HTTPS (the HTTP transport and the OAuth
  # HTTP boundary) when the caller does not pass `:cacerts`.
  #
  # The OS trust store is the source, so private and corporate CAs installed
  # on the host keep working. `:public_key.cacerts_get/0` has no timeout,
  # though: on macOS it shells out to `/usr/bin/security`, which can stall on
  # the keychain (for example while the session is locked), and every HTTPS
  # caller would hang with it. So the OS load runs under a deadline.
  #
  # When the load stalls, fails, or finds no certificates, the default is to
  # fail closed: raise UnavailableError, and cache the failure for
  # `:failure_ttl_ms` so callers fail fast instead of each waiting out the
  # deadline. Falling back to the CAStore bundle is opt-in (`fallback:
  # :castore`) because it changes which CAs are trusted: anyone able to make
  # the OS store unavailable could otherwise force that switch (reviving CAs
  # the OS has distrusted, or activating a tampered castore). A fallback
  # retries the OS store in the background every `:refresh_interval_ms`.
  #
  # Telemetry: [:arbor_mcp, :cacerts, :os_load, :failed] with metadata
  # %{reason: :timeout | :no_certificates | :error, fallback: :none | :castore},
  # and [:arbor_mcp, :cacerts, :os_load, :recovered] with
  # %{previous: :failed | :fallback} when a later load succeeds.
  #
  # Configured under `config :arbor_mcp, :cacerts` (see docs/CONFIGURATION.md).

  require Logger

  defmodule UnavailableError do
    @moduledoc false
    defexception [:reason]

    alias Arbor.MCP.Internal.CACerts

    @impl true
    def message(%{reason: reason}) do
      "could not load the OS CA certificate store (#{CACerts.describe(reason)}); " <>
        "outbound HTTPS is unavailable. Pass :cacerts explicitly, or opt in to the " <>
        "CAStore fallback with config :arbor_mcp, :cacerts, fallback: :castore"
    end
  end

  @cache_key {__MODULE__, :cacerts}
  @defaults [
    os_timeout_ms: 5_000,
    fallback: :none,
    failure_ttl_ms: 30_000,
    refresh_interval_ms: 300_000
  ]

  @type cacerts :: [:public_key.der_encoded() | :public_key.combined_cert()]

  @doc """
  Returns the default CA certificates, loading and caching them on first use.
  Raises `UnavailableError` when the OS store cannot be loaded and no fallback
  is configured.

  `opts` override the application config; `:loader` and `:cache_key` exist
  for tests.
  """
  @spec get(keyword()) :: cacerts()
  def get(opts \\ []) do
    opts = options(opts)
    key = Keyword.fetch!(opts, :cache_key)

    case :persistent_term.get(key, nil) do
      {:os, certs} ->
        certs

      {:fallback, certs, refresh_at} ->
        maybe_refresh(key, certs, refresh_at, opts)
        certs

      {:failed, reason, retry_at} ->
        if now() < retry_at, do: raise(UnavailableError, reason: reason)
        load_and_cache(key, opts)

      nil ->
        load_and_cache(key, opts)
    end
  end

  @doc "The CAStore bundle as DER-encoded certificates."
  @spec castore_certs() :: [:public_key.der_encoded()]
  def castore_certs do
    for {:Certificate, der, :not_encrypted} <-
          CAStore.file_path() |> File.read!() |> :public_key.pem_decode(),
        do: der
  end

  @doc false
  def describe({:timeout, ms}), do: "timed out after #{ms}ms"
  def describe(:no_certificates), do: "no certificates found"
  def describe({:error, %{__exception__: true} = e}), do: Exception.message(e)
  def describe({kind, reason}) when kind in [:error, :exit, :throw], do: inspect(reason)
  def describe(reason), do: inspect(reason)

  defp options(opts) do
    @defaults
    |> Keyword.merge(Application.get_env(:arbor_mcp, :cacerts, []))
    |> Keyword.merge(opts)
    |> Keyword.put_new(:cache_key, @cache_key)
    |> Keyword.put_new(:loader, &:public_key.cacerts_get/0)
  end

  # Serialized so concurrent callers share one OS load instead of each waiting
  # out their own deadline. The cache is re-read inside the lock because
  # another caller may have finished the load while this one waited.
  defp load_and_cache(key, opts) do
    with_lock(key, fn ->
      case :persistent_term.get(key, nil) do
        {:os, certs} ->
          {:ok, certs}

        {:fallback, certs, _refresh_at} ->
          {:ok, certs}

        {:failed, reason, retry_at} when is_integer(retry_at) ->
          retry_or_fail(key, reason, retry_at, opts)

        nil ->
          load(key, nil, opts)
      end
    end)
    |> case do
      {:ok, certs} -> certs
      {:error, reason} -> raise UnavailableError, reason: reason
    end
  end

  defp retry_or_fail(key, reason, retry_at, opts) do
    if now() < retry_at, do: {:error, reason}, else: load(key, :failed, opts)
  end

  defp load(key, previous, opts) do
    case load_os(opts) do
      {:ok, certs} ->
        if previous, do: recovered(previous)
        :persistent_term.put(key, {:os, certs})
        {:ok, certs}

      {:error, reason} ->
        failed(reason, opts)
        handle_failure(key, reason, opts)
    end
  end

  defp handle_failure(key, reason, opts) do
    case Keyword.fetch!(opts, :fallback) do
      :castore ->
        Logger.warning(
          "Could not load the OS CA certificate store (#{describe(reason)}); " <>
            "using the CAStore bundle because fallback: :castore is configured. " <>
            "CAs installed only in the OS store are not trusted until it loads."
        )

        certs = castore_certs()
        :persistent_term.put(key, {:fallback, certs, next(opts, :refresh_interval_ms)})
        {:ok, certs}

      :none ->
        Logger.error(
          "Could not load the OS CA certificate store (#{describe(reason)}); " <>
            "outbound HTTPS requests will fail until it loads."
        )

        :persistent_term.put(key, {:failed, reason, next(opts, :failure_ttl_ms)})
        {:error, reason}
    end
  end

  defp load_os(opts) do
    loader = Keyword.fetch!(opts, :loader)
    timeout = Keyword.fetch!(opts, :os_timeout_ms)

    task =
      Task.async(fn ->
        try do
          {:ok, loader.()}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, [_ | _] = certs}} -> {:ok, certs}
      {:ok, {:ok, _empty}} -> {:error, :no_certificates}
      {:ok, {:error, reason}} -> {:error, reason}
      nil -> {:error, {:timeout, timeout}}
    end
  end

  defp maybe_refresh(key, _certs, refresh_at, opts) do
    if now() >= refresh_at, do: claim_refresh(key, opts)
    :ok
  end

  @doc false
  # Starts a background refresh if one is still due. The caller's read of the
  # cache may be stale by now (another caller may have claimed the refresh, or
  # a refresh may already have stored the OS store), so the cache is re-read
  # under the same lock every write takes, and a claim never overwrites
  # anything but a due fallback. Returns whether a refresh was started.
  @spec claim_refresh(term(), keyword()) :: boolean()
  def claim_refresh(key, opts) do
    with_lock(key, fn ->
      case :persistent_term.get(key, nil) do
        {:fallback, certs, refresh_at} when is_integer(refresh_at) ->
          if now() >= refresh_at do
            :persistent_term.put(key, {:fallback, certs, next(opts, :refresh_interval_ms)})
            spawn(fn -> refresh(key, opts) end)
            true
          else
            false
          end

        _os_or_other ->
          false
      end
    end)
  end

  defp refresh(key, opts) do
    # The registration catches a slow refresh that is still running when the
    # next interval's claim starts another one.
    with :yes <- :global.register_name({__MODULE__, :refresh, key}, self()),
         {:ok, certs} <- load_os(opts) do
      with_lock(key, fn -> :persistent_term.put(key, {:os, certs}) end)
      recovered(:fallback)
    end
  end

  # Every cache write happens under this per-key lock.
  defp with_lock(key, fun) do
    :global.trans({{__MODULE__, key}, self()}, fun, [node()])
  end

  defp failed(reason, opts) do
    :telemetry.execute([:arbor_mcp, :cacerts, :os_load, :failed], %{}, %{
      reason: reason_tag(reason),
      fallback: Keyword.fetch!(opts, :fallback)
    })
  end

  defp recovered(previous) do
    Logger.info("Loaded the OS CA certificate store")
    :telemetry.execute([:arbor_mcp, :cacerts, :os_load, :recovered], %{}, %{previous: previous})
  end

  defp reason_tag({:timeout, _ms}), do: :timeout
  defp reason_tag(:no_certificates), do: :no_certificates
  defp reason_tag(_reason), do: :error

  defp next(opts, interval_key), do: now() + Keyword.fetch!(opts, interval_key)

  defp now, do: System.monotonic_time(:millisecond)
end
