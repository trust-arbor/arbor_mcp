# MIT License
#
# Copyright (c) 2020 Mat Trudel
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# HTTP option transformation adapted from Bandit 1.12.5, lib/bandit.ex.
# TLS remains host-managed; the owned constructor fixes scheme: :http.
defmodule Arbor.MCP.Server.HTTP.Bandit.Options do
  @moduledoc false
  @top_level_keys ~w(plug scheme port ip keyfile certfile otp_app cipher_suite display_plug startup_log thousand_island_options http_options http_1_options http_2_options websocket_options)a
  @http_keys ~w(compress response_encodings deflate_options zstd_options log_exceptions_with_status_codes log_protocol_errors log_client_closures)a
  @http_1_keys ~w(enabled max_request_line_length max_header_length max_header_count max_requests clear_process_dict gc_every_n_keepalive_requests log_unknown_messages)a
  @http_2_keys ~w(enabled max_header_block_size max_requests max_reset_stream_rate sendfile_chunk_size default_local_settings)a
  @websocket_keys ~w(enabled max_frame_size max_fragmented_message_size validate_text_frames compress deflate_options max_inflate_ratio primitive_ops_module log_protocol_errors)a

  def compile(arg, initialize_plug? \\ true) do
    # Special case top-level `:inet` and `:inet6` options so we can use keyword logic everywhere else
    arg = arg |> special_case_inet_options() |> validate_options(@top_level_keys, "top level")

    thousand_island_options =
      Keyword.get(arg, :thousand_island_options, [])
      |> validate_options(thousand_island_keys(), :thousand_island_options)

    http_options =
      Keyword.get(arg, :http_options, [])
      |> validate_options(@http_keys, :http_options)

    http_1_options =
      Keyword.get(arg, :http_1_options, [])
      |> validate_options(@http_1_keys, :http_1_options)

    http_2_options =
      Keyword.get(arg, :http_2_options, [])
      |> validate_options(@http_2_keys, :http_2_options)

    websocket_options =
      Keyword.get(arg, :websocket_options, [])
      |> validate_options(@websocket_keys, :websocket_options)

    plug = if initialize_plug?, do: plug(arg), else: Keyword.fetch!(arg, :plug)
    {http_1_enabled, http_1_options} = Keyword.pop(http_1_options, :enabled, true)
    {http_2_enabled, http_2_options} = Keyword.pop(http_2_options, :enabled, true)

    handler_options = %{
      plug: plug,
      handler_module: Bandit.InitialHandler,
      opts: %{
        http: http_options,
        http_1: http_1_options,
        http_2: http_2_options,
        websocket: websocket_options
      },
      http_1_enabled: http_1_enabled,
      http_2_enabled: http_2_enabled
    }

    transport_options =
      Keyword.get(thousand_island_options, :transport_options, []) ++ Keyword.take(arg, [:ip])

    port = Keyword.get(arg, :port, 4000) |> parse_as_number()

    options =
      thousand_island_options
      |> Keyword.put_new(:port, port)
      |> Keyword.put_new(:transport_module, ThousandIsland.Transports.TCP)
      |> Keyword.put(:transport_options, transport_options)
      |> Keyword.put_new(:handler_module, Bandit.DelegatingHandler)
      |> Keyword.put_new(:handler_options, handler_options)

    # Optional backend: qualified before this pure transformation.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(ThousandIsland.ServerConfig, :new, [options])
  end

  def validate(options) do
    config = compile(Keyword.put(options, :plug, {Arbor.MCP.HttpPlug, []}), false)

    unless is_integer(config.num_acceptors) and config.num_acceptors in 1..128,
      do: raise(ArgumentError, "owned listener admits at most128 acceptors")

    timeout = Keyword.get(config.genserver_options, :timeout, 10_000)

    unless is_integer(timeout) and timeout > 0 and timeout <= 4_294_967_295,
      do: raise(ArgumentError, "owned connection constructor requires a finite timeout")

    :ok
  rescue
    _exception -> {:error, :invalid_http_listener_options}
  end

  defp thousand_island_keys do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(ThousandIsland.ServerConfig, :__struct__, [])
    |> Map.from_struct()
    |> Map.keys()
    |> Enum.sort()
  end

  @spec special_case_inet_options(keyword()) :: keyword()
  defp special_case_inet_options(opts) do
    {inet_opts, opts} = Enum.split_with(opts, &(&1 in [:inet, :inet6]))

    if inet_opts == [] do
      opts
    else
      Keyword.update(
        opts,
        :thousand_island_options,
        [transport_options: inet_opts],
        fn thousand_island_opts ->
          Keyword.update(thousand_island_opts, :transport_options, inet_opts, &(&1 ++ inet_opts))
        end
      )
    end
  end

  @spec validate_options(Keyword.t(), [atom(), ...], String.t() | atom()) ::
          Keyword.t() | no_return()
  defp validate_options(options, valid_values, name) do
    case Keyword.split(options, valid_values) do
      {options, []} ->
        options

      {_, illegal_options} ->
        raise "Unsupported key(s) in #{name} config: #{inspect(Keyword.keys(illegal_options))}"
    end
  end

  @spec plug(keyword()) :: {module(), term()}
  defp plug(arg) do
    arg
    |> Keyword.get(:plug)
    |> case do
      nil -> raise "A value is required for :plug"
      {plug_fn, plug_options} when is_function(plug_fn, 2) -> {plug_fn, plug_options}
      plug_fn when is_function(plug_fn) -> {plug_fn, []}
      {plug, plug_options} when is_atom(plug) -> validate_plug(plug, plug_options)
      plug when is_atom(plug) -> validate_plug(plug, [])
      other -> raise "Invalid value for plug: #{inspect(other)}"
    end
  end

  defp validate_plug(plug, plug_options) do
    Code.ensure_loaded!(plug)
    if !function_exported?(plug, :init, 1), do: raise("plug module does not define init/1")
    if !function_exported?(plug, :call, 2), do: raise("plug module does not define call/2")

    {plug, plug.init(plug_options)}
  end

  @spec parse_as_number(binary() | integer()) :: integer()
  defp parse_as_number(value) when is_binary(value), do: String.to_integer(value)
  defp parse_as_number(value) when is_integer(value), do: value
end
