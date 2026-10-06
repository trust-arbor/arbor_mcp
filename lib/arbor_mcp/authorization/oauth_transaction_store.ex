defmodule Arbor.MCP.Authorization.OAuthTransactionStore do
  @moduledoc """
  Bounded, node-local single-use state for OAuth authorization-code flows.

  Transactions move atomically through `pending -> code_ready -> redeemed`.
  The store retains only SHA-256 digests of state values and authorization
  codes, so neither value appears in the store's retained process state or
  crash reports.

  The built-in store is intentionally node-local because the loopback callback
  flow is owned by one ArborMCP client process. Applications implementing a
  distributed browser callback should terminate that callback on the same node
  or provide their own end-to-end authorization provider.
  """

  use GenServer

  alias Arbor.MCP.Authorization.Issuer

  @name __MODULE__
  @default_ttl_ms 600_000
  @default_max_entries 10_000
  @field_atoms %{"code" => :code, "iss" => :iss, "state" => :state}

  @type transaction_id :: String.t()
  @type callback_error ::
          :state_mismatch
          | :missing_authorization_code
          | :missing_callback_issuer
          | :missing_expected_issuer
          | :authorization_transaction_not_found
          | :authorization_transaction_replayed
          | :oauth_transaction_store_unavailable
          | {:issuer_mismatch, keyword()}

  @type entry :: %{
          state_digest: binary(),
          issuer: String.t() | nil,
          require_issuer: boolean(),
          redirect_uri: String.t(),
          status: :pending | :consumed | :redeemed | {:code_ready, binary()},
          expires_at: integer()
        }

  @type state :: %{
          entries: %{optional(transaction_id()) => entry()},
          max_entries: pos_integer(),
          ttl_ms: pos_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, @name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Registers a new authorization transaction using a digest of its random state."
  @spec register(String.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, transaction_id()} | {:error, term()}
  def register(state, issuer, redirect_uri, opts \\ [])

  def register(state, issuer, redirect_uri, opts)
      when is_binary(state) and state != "" and
             (is_binary(issuer) or is_nil(issuer)) and
             is_binary(redirect_uri) and redirect_uri != "" do
    server = Keyword.get(opts, :server, @name)
    ttl_ms = Keyword.get(opts, :ttl_ms)
    require_issuer = Keyword.get(opts, :require_issuer, false) == true

    GenServer.call(
      server,
      {:register, digest(state), issuer, require_issuer, redirect_uri, ttl_ms}
    )
  catch
    :exit, _reason -> {:error, :oauth_transaction_store_unavailable}
  end

  def register(_state, _issuer, _redirect_uri, _opts),
    do: {:error, :invalid_oauth_transaction}

  @doc "Atomically validates and consumes one callback for a transaction."
  @spec validate_callback(transaction_id(), map(), keyword()) ::
          {:ok, String.t()} | {:error, callback_error()}
  def validate_callback(transaction_id, callback, opts \\ [])

  def validate_callback(transaction_id, callback, opts)
      when is_binary(transaction_id) and is_map(callback) do
    server = Keyword.get(opts, :server, @name)
    code = field(callback, "code")

    case GenServer.call(server, {
           :validate_callback,
           transaction_id,
           digest_if_binary(field(callback, "state")),
           field(callback, "iss"),
           digest_nonempty_binary(code)
         }) do
      :ok -> {:ok, code}
      {:error, _reason} = error -> error
    end
  catch
    :exit, _reason -> {:error, :oauth_transaction_store_unavailable}
  end

  def validate_callback(_transaction_id, _callback, _opts),
    do: {:error, :state_mismatch}

  @doc "Atomically marks an authorization code as redeemed with its exact redirect URI."
  @spec redeem_code(transaction_id(), String.t(), String.t(), keyword()) ::
          :ok
          | {:error,
             :authorization_transaction_not_found
             | :authorization_code_not_ready
             | :authorization_code_replayed
             | :authorization_code_mismatch
             | :redirect_uri_mismatch
             | :oauth_transaction_store_unavailable}
  def redeem_code(transaction_id, code, redirect_uri, opts \\ [])

  def redeem_code(transaction_id, code, redirect_uri, opts)
      when is_binary(transaction_id) and is_binary(code) and code != "" and
             is_binary(redirect_uri) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:redeem_code, transaction_id, digest(code), redirect_uri})
  catch
    :exit, _reason -> {:error, :oauth_transaction_store_unavailable}
  end

  def redeem_code(_transaction_id, _code, _redirect_uri, _opts),
    do: {:error, :authorization_code_mismatch}

  @doc "Invalidates a transaction after a failed or abandoned flow."
  @spec abort(transaction_id(), keyword()) :: :ok
  def abort(transaction_id, opts \\ []) when is_binary(transaction_id) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, {:abort, transaction_id})
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, :count)
  end

  @impl GenServer
  def init(opts) do
    ttl_ms = positive_option(opts, :ttl_ms, @default_ttl_ms)
    max_entries = positive_option(opts, :max_entries, @default_max_entries)
    {:ok, %{entries: %{}, ttl_ms: ttl_ms, max_entries: max_entries}}
  end

  @impl GenServer
  def handle_call(
        {:register, state_digest, issuer, require_issuer, redirect_uri, ttl_override},
        _from,
        state
      ) do
    now = now_ms()
    state = purge_expired(state, now)

    if map_size(state.entries) >= state.max_entries do
      {:reply, {:error, :oauth_transaction_capacity_exceeded}, state}
    else
      transaction_id = unique_transaction_id(state.entries)
      ttl_ms = valid_ttl_override(ttl_override, state.ttl_ms)

      entry = %{
        state_digest: state_digest,
        issuer: issuer,
        require_issuer: require_issuer,
        redirect_uri: redirect_uri,
        status: :pending,
        expires_at: now + ttl_ms
      }

      {:reply, {:ok, transaction_id}, put_in(state, [:entries, transaction_id], entry)}
    end
  end

  def handle_call(
        {:validate_callback, transaction_id, state_digest, callback_issuer, code_digest},
        _from,
        state
      ) do
    state = purge_expired(state, now_ms())

    case state.entries[transaction_id] do
      nil ->
        {:reply, {:error, :authorization_transaction_not_found}, state}

      %{status: status} when status != :pending ->
        {:reply, {:error, :authorization_transaction_replayed}, state}

      entry ->
        validate_pending_callback(
          transaction_id,
          entry,
          state_digest,
          callback_issuer,
          code_digest,
          state
        )
    end
  end

  def handle_call({:redeem_code, transaction_id, code_digest, redirect_uri}, _from, state) do
    state = purge_expired(state, now_ms())

    case state.entries[transaction_id] do
      nil ->
        {:reply, {:error, :authorization_transaction_not_found}, state}

      %{status: :redeemed} ->
        {:reply, {:error, :authorization_code_replayed}, state}

      %{status: {:code_ready, expected_digest}} = entry ->
        redeem_ready_code(
          transaction_id,
          entry,
          expected_digest,
          code_digest,
          redirect_uri,
          state
        )

      _entry ->
        {:reply, {:error, :authorization_code_not_ready}, state}
    end
  end

  def handle_call({:abort, transaction_id}, _from, state) do
    state = purge_expired(state, now_ms())

    state =
      case state.entries[transaction_id] do
        %{status: :redeemed} -> state
        nil -> state
        entry -> put_in(state, [:entries, transaction_id], %{entry | status: :consumed})
      end

    {:reply, :ok, state}
  end

  def handle_call(:count, _from, state) do
    state = purge_expired(state, now_ms())
    {:reply, map_size(state.entries), state}
  end

  defp validate_pending_callback(
         transaction_id,
         entry,
         state_digest,
         callback_issuer,
         code_digest,
         state
       ) do
    if secure_equal?(state_digest, entry.state_digest) do
      case validate_bound_callback(
             entry.issuer,
             entry.require_issuer,
             callback_issuer,
             code_digest
           ) do
        :ok ->
          updated = %{entry | status: {:code_ready, code_digest}}
          state = put_in(state, [:entries, transaction_id], updated)
          {:reply, :ok, state}

        {:error, _reason} = error ->
          state = put_in(state, [:entries, transaction_id], %{entry | status: :consumed})
          {:reply, error, state}
      end
    else
      {:reply, {:error, :state_mismatch}, state}
    end
  end

  defp validate_bound_callback(expected_issuer, require_issuer, callback_issuer, code_digest) do
    with :ok <- validate_callback_issuer(expected_issuer, require_issuer, callback_issuer) do
      validate_code(code_digest)
    end
  end

  defp validate_callback_issuer(_expected_issuer, true, nil),
    do: {:error, :missing_callback_issuer}

  defp validate_callback_issuer(_expected_issuer, false, nil), do: :ok

  defp validate_callback_issuer(nil, _require_issuer, _callback_issuer),
    do: {:error, :missing_expected_issuer}

  defp validate_callback_issuer(expected_issuer, _require_issuer, callback_issuer),
    do: Issuer.compare(expected_issuer, callback_issuer)

  defp validate_code(code_digest) when is_binary(code_digest), do: :ok
  defp validate_code(_code), do: {:error, :missing_authorization_code}

  defp redeem_ready_code(
         transaction_id,
         entry,
         expected_digest,
         code_digest,
         redirect_uri,
         state
       ) do
    cond do
      not secure_equal?(code_digest, expected_digest) ->
        {:reply, {:error, :authorization_code_mismatch}, state}

      redirect_uri != entry.redirect_uri ->
        {:reply, {:error, :redirect_uri_mismatch}, state}

      true ->
        state = put_in(state, [:entries, transaction_id], %{entry | status: :redeemed})
        {:reply, :ok, state}
    end
  end

  defp purge_expired(state, now) do
    %{state | entries: Map.reject(state.entries, fn {_id, entry} -> entry.expires_at <= now end)}
  end

  defp unique_transaction_id(entries) do
    transaction_id = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    if Map.has_key?(entries, transaction_id),
      do: unique_transaction_id(entries),
      else: transaction_id
  end

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end

  defp valid_ttl_override(value, _default) when is_integer(value) and value > 0, do: value
  defp valid_ttl_override(_value, default), do: default

  defp digest(value), do: :crypto.hash(:sha256, value)
  defp digest_if_binary(value) when is_binary(value), do: digest(value)
  defp digest_if_binary(_value), do: nil
  defp digest_nonempty_binary(value) when is_binary(value) and value != "", do: digest(value)
  defp digest_nonempty_binary(_value), do: nil

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_left, _right), do: false

  defp field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Map.fetch!(@field_atoms, key))
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
