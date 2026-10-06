defmodule Arbor.MCP.Security.Consent do
  @moduledoc """
  Manages user consent for various operations.

  This module is responsible for ensuring that user consent has been
  obtained before proceeding with sensitive actions.

  ## Expiry handling

  Consent handlers may express a grant's lifetime in any of the forms listed in
  `t:Arbor.MCP.ConsentHandler.expiry/0`. All of them are normalized here into the
  monotonic-seconds value stored by ArborMCP's internal consent cache.

  Every decision path fails closed: an expiry that cannot be interpreted, is
  already in the past, or is implausibly far in the future (the classic
  "handler returned Unix epoch seconds where a monotonic value was expected"
  bug, which would otherwise grant consent for decades) is logged and the
  request is rejected with `{:error, :consent_error}` rather than cached.
  """

  alias Arbor.MCP.Internal.ConsentCache
  alias Arbor.MCP.Security.TokenHandler

  require Logger

  # Longest consent lifetime we are willing to store. Anything beyond this is
  # treated as a handler bug (typically Unix epoch seconds returned where a
  # monotonic value was expected) rather than an intentional grant.
  @max_consent_seconds 365 * 24 * 3600

  # Used when the security config carries no (valid) :consent_ttl.
  @default_consent_ttl_seconds 3600

  @doc """
  Ensures user consent is obtained before accessing an external resource.
  """
  @spec ensure_user_consent(
          Arbor.MCP.ConsentHandler.user_id(),
          String.t(),
          atom(),
          module(),
          map()
        ) :: :ok | {:error, :consent_denied | :consent_required | :consent_error}
  def ensure_user_consent(user_id, url, transport, handler, config) do
    with {:ok, origin} <- TokenHandler.extract_origin(url),
         :external <- TokenHandler.classify_url(url, config) do
      do_ensure_user_consent(user_id, origin, transport, handler, config)
    else
      :internal ->
        :ok

      {:error, _reason} ->
        # If URL is invalid or has no origin, we can't check consent.
        # Let other parts of the system handle the invalid URL.
        # From a consent perspective, we don't block it.
        :ok
    end
  end

  defp do_ensure_user_consent(user_id, origin, transport, handler, config) do
    case ConsentCache.check_consent(user_id, origin) do
      {:ok, _expires_at} ->
        :ok

      {:not_found} ->
        handle_consent_request(user_id, origin, transport, handler, config)

      {:expired} ->
        # Consent expired, so revoke it from cache and re-request.
        ConsentCache.revoke_consent(user_id, origin)
        handle_consent_request(user_id, origin, transport, handler, config)
    end
  end

  defp compute_expires_at(context) do
    {:ttl, Map.get(context, :consent_ttl, @default_consent_ttl_seconds)}
  end

  # The `:consent_ttl` security setting is milliseconds (see
  # `Arbor.MCP.Internal.SecurityConfig`), but consent handlers receive — and
  # `t:Arbor.MCP.ConsentHandler.expiry/0` speaks — seconds.
  defp consent_ttl_seconds(config) do
    case Map.get(config, :consent_ttl) do
      ms when is_integer(ms) and ms > 0 -> max(div(ms, 1000), 1)
      _ -> @default_consent_ttl_seconds
    end
  end

  defp handle_consent_request(user_id, origin, transport, handler, config) do
    # Include any handler-specific options
    handler_opts = Map.get(config, :consent_handler_opts, [])

    context =
      %{
        transport: transport,
        consent_ttl: consent_ttl_seconds(config)
      }
      |> Map.merge(Enum.into(handler_opts, %{}))

    case handler.request_consent(user_id, origin, context) do
      {:ok, expires_at} ->
        store_consent(user_id, origin, expires_at, handler)

      {:approved, opts} ->
        expires_at = Keyword.get(opts, :expires_at, compute_expires_at(context))
        store_consent(user_id, origin, expires_at, handler)

      {:denied, _opts} ->
        # Don't cache denials - let the handler be called each time
        # This ensures fresh consent checks for denied requests
        {:error, :consent_denied}

      {:error, :denied} ->
        {:error, :consent_denied}

      {:error, :consent_required} ->
        {:error, :consent_required}

      {:error, opts} when is_list(opts) ->
        # Handle error with options
        if Keyword.get(opts, :reason) == "Consent required" do
          {:error, :consent_required}
        else
          {:error, :consent_denied}
        end

      other ->
        # Handle unexpected consent handler responses
        Logger.warning(
          "Unexpected consent handler response: #{inspect(other)} from #{inspect(handler)} for user #{user_id} at #{origin}"
        )

        {:error, :consent_error}
    end
  end

  defp store_consent(user_id, origin, expiry, handler) do
    case normalize_expiry(expiry) do
      {:ok, monotonic_expires} ->
        ConsentCache.store_consent(user_id, origin, monotonic_expires)
        :ok

      {:error, reason} ->
        # Fail closed: an expiry we cannot interpret is never treated as a grant.
        Logger.warning(
          "Rejecting consent grant from #{inspect(handler)} for #{user_id} at #{origin}: " <>
            describe_expiry_error(reason, expiry)
        )

        {:error, :consent_error}
    end
  end

  # Normalizes every supported `t:Arbor.MCP.ConsentHandler.expiry/0` form into the
  # monotonic seconds value the ConsentCache stores.
  defp normalize_expiry(%DateTime{} = datetime) do
    from_unix(DateTime.to_unix(datetime))
  end

  defp normalize_expiry({:unix, seconds}) when is_integer(seconds) do
    from_unix(seconds)
  end

  defp normalize_expiry({:ttl, seconds}) when is_integer(seconds) do
    from_now(seconds)
  end

  defp normalize_expiry({:monotonic, seconds}) when is_integer(seconds) do
    from_monotonic(seconds)
  end

  # Legacy bare integer: documented as a monotonic value, but frequently a Unix
  # timestamp by mistake, so the plausibility check below is what catches it.
  defp normalize_expiry(seconds) when is_integer(seconds) do
    from_monotonic(seconds)
  end

  defp normalize_expiry(_other), do: {:error, :invalid_expiry}

  defp from_unix(unix_seconds) do
    from_now(unix_seconds - System.os_time(:second))
  end

  defp from_now(ttl_seconds) do
    cond do
      ttl_seconds <= 0 -> {:error, :expiry_in_past}
      ttl_seconds > @max_consent_seconds -> {:error, :expiry_too_far_in_future}
      true -> {:ok, System.monotonic_time(:second) + ttl_seconds}
    end
  end

  defp from_monotonic(monotonic_seconds) do
    case from_now(monotonic_seconds - System.monotonic_time(:second)) do
      {:ok, _absolute} -> {:ok, monotonic_seconds}
      {:error, _reason} = error -> error
    end
  end

  defp describe_expiry_error(:invalid_expiry, expiry) do
    "unsupported expiry #{inspect(expiry)}. Return a DateTime, {:ttl, seconds}, " <>
      "{:unix, seconds}, or {:monotonic, seconds}."
  end

  defp describe_expiry_error(:expiry_in_past, expiry) do
    "expiry #{inspect(expiry)} is already in the past."
  end

  defp describe_expiry_error(:expiry_too_far_in_future, expiry) do
    "expiry #{inspect(expiry)} is more than #{div(@max_consent_seconds, 86_400)} days away. " <>
      "A bare integer is read as System.monotonic_time(:second); if this is a Unix " <>
      "timestamp, return {:unix, seconds} (or a DateTime) instead."
  end
end
