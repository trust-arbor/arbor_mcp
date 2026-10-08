defmodule Arbor.MCP.ConsentHandler do
  @moduledoc """
  A behaviour for handling user consent for accessing external resources.
  """

  @typedoc "The user identifier."
  @type user_id :: String.t() | atom()

  @typedoc "The origin of the resource being accessed (e.g., \"https://api.example.com\")."
  @type resource_origin :: String.t()

  @typedoc "Context about the consent request."
  @type request_context :: map()

  @typedoc """
  When a granted consent expires.

  Prefer one of the explicit forms — they are unambiguous:

  - `DateTime.t()` — absolute wall-clock instant, e.g. `DateTime.add(DateTime.utc_now(), 3600)`
  - `{:ttl, seconds}` — relative to now, e.g. `{:ttl, 3600}` for one hour
  - `{:unix, seconds}` — absolute Unix epoch seconds, e.g. `{:unix, System.os_time(:second) + 3600}`
  - `{:monotonic, seconds}` — absolute `System.monotonic_time(:second)` value

  A bare integer is interpreted as a `System.monotonic_time(:second)` value for
  backwards compatibility. **This is easy to get wrong**: Unix epoch seconds and
  monotonic seconds are not interchangeable, and a Unix timestamp read as a
  monotonic value grants consent for decades. Values that are implausible as
  monotonic times (already in the past, or more than 365 days in the future)
  are rejected and the request fails closed. Use `{:unix, seconds}` or
  `{:ttl, seconds}` instead of a bare integer.
  """
  @type expiry ::
          DateTime.t()
          | {:ttl, pos_integer()}
          | {:unix, integer()}
          | {:monotonic, integer()}
          | integer()

  @typedoc """
  The result of a consent request.
  - `{:ok, expiry}`: Consent granted until `expiry` (see `t:expiry/0`).
  - `{:approved, opts}`: Consent granted; `opts[:expires_at]` is an `t:expiry/0`.
    When omitted, the `:consent_ttl` from the request context is used.
  - `{:denied, opts}` / `{:error, :denied}`: Consent explicitly denied.
  - `{:error, :consent_required}`: Consent needs to be obtained through another channel (e.g., a web UI).

  Any other return value is treated as an error and the request is denied.
  """
  @type consent_result ::
          {:ok, expiry()}
          | {:approved, keyword()}
          | {:denied, keyword()}
          | {:error, :denied | :consent_required}

  @doc """
  Requests user consent to access a resource.

  The `request_context` map carries transport-specific information plus
  `:transport` and `:consent_ttl`. `:consent_ttl` is the configured consent
  lifetime **in seconds** (the `:consent_ttl` security setting itself is in
  milliseconds); it is a sensible default to hand back:

      @impl Arbor.MCP.ConsentHandler
      def request_consent(_user_id, origin, context) do
        if approve?(origin) do
          {:ok, {:ttl, Map.get(context, :consent_ttl, 3600)}}
        else
          {:error, :denied}
        end
      end
  """
  @callback request_consent(
              user_id :: user_id(),
              resource_origin :: resource_origin(),
              request_context :: request_context()
            ) :: consent_result()

  @doc """
  Checks if a valid consent already exists.

  This callback is primarily for handlers that might have their own persistent
  storage, separate from the global `ConsentCache`. Most handlers can simply
  return `{:not_found}` and rely on the cache.
  """
  @callback check_existing_consent(
              user_id :: user_id(),
              resource_origin :: resource_origin()
            ) :: {:ok, expires_at :: non_neg_integer()} | {:not_found} | {:expired}

  @doc """
  Revokes any existing consent for a user and resource.
  """
  @callback revoke_consent(user_id :: user_id(), resource_origin :: resource_origin()) ::
              :ok | {:error, String.t()}
end
