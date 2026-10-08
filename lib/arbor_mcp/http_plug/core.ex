defmodule Arbor.MCP.HttpPlug.Core do
  @moduledoc """
  Pure request/response decisions for `Arbor.MCP.HttpPlug`.

  The Plug module owns side effects such as reading request bodies, writing
  responses, ETS/session management, and SSE processes. This module keeps the
  reusable protocol, origin, and host decisions as data transformations.

  ## Origin validation

  `origin_allowed?/2` implements a strict allow-list:

  * Requests **without** an `Origin` header are allowed. Non-browser clients
    (CLIs, SDKs, server-to-server callers) do not send the header, and
    requiring it would break them. DNS rebinding protection for those callers
    comes from Host validation (`host_allowed?/2`).
  * Requests **with** an `Origin` header are only allowed when the origin is
    listed in `:allowed_origins` (or `:allowed_origins` is `:any`). There is
    deliberately no "same origin as the request Host" fallback: in a DNS
    rebinding attack the Host header is attacker-controlled, so comparing the
    Origin against it would always pass.

  ## Host validation

  `host_allowed?/2` compares the request `Host` header against an allow-list
  (`:any` disables the check). Ports are ignored and bracketed IPv6 literals
  such as `"[::1]:8080"` match both `"[::1]"` and `"::1"` entries.
  """

  alias Arbor.MCP.Protocol.ResponseBuilder

  @type origin_context :: %{
          optional(:origin) => String.t() | nil,
          optional(:scheme) => String.t(),
          optional(:host) => String.t(),
          optional(:port) => non_neg_integer() | nil
        }

  @type allowed_hosts :: :any | [String.t()]

  @spec parse_json(binary()) :: {:ok, map()} | {:error, :parse_error | :invalid_json_rpc_envelope}
  def parse_json(body) do
    case Jason.decode(body) do
      {:ok, json} when is_map(json) -> {:ok, json}
      {:ok, _json} -> {:error, :invalid_json_rpc_envelope}
      {:error, _} -> {:error, :parse_error}
    end
  end

  @spec origin_allowed?(origin_context(), map()) :: boolean()
  def origin_allowed?(context, opts) do
    case Map.get(context, :origin) do
      nil ->
        true

      "" ->
        true

      origin ->
        explicit_origin_allowed?(origin, Map.get(opts, :allowed_origins))
    end
  end

  @doc """
  Checks a request `Host` header value against an allow-list.

  Returns `true` when `allowed_hosts` is `:any`. Otherwise the host must be
  present and, after normalization via `normalize_host/1`, match one of the
  allow-list entries (compared case-insensitively, ignoring ports and IPv6
  brackets).
  """
  @spec host_allowed?(String.t() | nil, allowed_hosts()) :: boolean()
  def host_allowed?(_host, :any), do: true

  def host_allowed?(host, allowed_hosts) when is_binary(host) and is_list(allowed_hosts) do
    allowed = Enum.map(allowed_hosts, &String.downcase/1)

    host
    |> normalize_host()
    |> host_candidates()
    |> Enum.any?(&(&1 in allowed))
  end

  def host_allowed?(nil, allowed_hosts) when is_list(allowed_hosts), do: false

  @doc """
  Normalizes a `Host` header value: trims, downcases, and strips the port.

  Bracketed IPv6 hosts keep their brackets (`"[::1]:8080"` becomes `"[::1]"`).
  Non-bracketed values only lose a port suffix when they contain a single
  `:`, so a raw IPv6 literal such as `"::1"` is preserved as-is.
  """
  @spec normalize_host(String.t()) :: String.t()
  def normalize_host(host) when is_binary(host) do
    host = host |> String.trim() |> String.downcase()

    case host do
      "[" <> _ -> strip_bracketed_port(host)
      _ -> strip_port(host)
    end
  end

  @spec cors_response_origin(origin_context(), map()) :: String.t() | nil
  def cors_response_origin(context, %{allowed_origins: :any}) do
    Map.get(context, :origin) || "*"
  end

  def cors_response_origin(context, opts) do
    origin = Map.get(context, :origin)

    cond do
      is_nil(origin) -> nil
      origin_allowed?(context, opts) -> origin
      true -> nil
    end
  end

  @spec json_rpc_error(integer(), String.t(), any(), map() | nil) :: map()
  def json_rpc_error(code, message, id \\ nil, data \\ nil) do
    ResponseBuilder.build_error_response(code, message, data, id)
  end

  @spec oauth_guard_disabled_error() :: map()
  def oauth_guard_disabled_error do
    %{
      error: "server_error",
      error_description: "OAuth is enabled for this plug, but OAuth authorization is disabled"
    }
  end

  defp explicit_origin_allowed?(_origin, :any), do: true
  defp explicit_origin_allowed?(origin, origins) when is_list(origins), do: origin in origins
  defp explicit_origin_allowed?(_origin, _origins), do: false

  # "[::1]:8080" -> "[::1]"; a bracketed host without "]" is left untouched.
  defp strip_bracketed_port(host) do
    case :binary.match(host, "]") do
      {pos, 1} -> binary_part(host, 0, pos + 1)
      :nomatch -> host
    end
  end

  # Only a single ":" indicates a port ("localhost:4000"). Multiple colons
  # mean a raw IPv6 literal, which has no distinguishable port without
  # brackets, so it is kept whole.
  defp strip_port(host) do
    case String.split(host, ":") do
      [bare, _port] -> bare
      _ -> host
    end
  end

  # Compare bracketed and unbracketed IPv6 spellings interchangeably.
  defp host_candidates("[" <> _ = bracketed) do
    unbracketed =
      bracketed
      |> String.trim_leading("[")
      |> String.trim_trailing("]")

    [bracketed, unbracketed]
  end

  defp host_candidates(host) do
    if String.contains?(host, ":") do
      [host, "[" <> host <> "]"]
    else
      [host]
    end
  end
end
