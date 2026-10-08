defmodule Arbor.MCP.Client.Internal.Connection do
  @moduledoc false
  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.{ConnectionManager, Deadline, Diagnostics}

  def normalize_start_result(result) do
    case result do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} when is_map(reason) ->
        {:error, reason}

      {:error, {:shutdown, reason}} when is_map(reason) ->
        {:error, reason}

      {:error, {:shutdown, {:transport_connect_failed, details}}} ->
        {:error, {:connection_error, details}}

      {:error, {:shutdown, {:initialize_error, details}}} ->
        {:error, {:initialize_error, details}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def connection_options(spec, opts) when not is_pid(spec) do
    {:ok, Keyword.merge(do_parse_connection_spec(spec), opts)}
  rescue
    error in [ArgumentError, FunctionClauseError] ->
      {:error, {:invalid_transport_config, error.__struct__}}
  catch
    :throw, {:transport_config_error, reason} ->
      {:error, {:invalid_transport_config, reason}}
  end

  def connection_options(_spec, _opts), do: {:error, :existing_client_not_owned}

  def start_scoped(opts, scope, deadline) do
    {name_opts, start_opts} = Keyword.split(opts, [:name])
    start_opts = Keyword.put(start_opts, :_connection_scope, scope)

    normalize_start_result(
      GenServer.start_link(
        Client,
        Diagnostics.argument(Client, start_opts),
        Keyword.put(name_opts, :timeout, Deadline.remaining(deadline))
      )
    )
  end

  def parse_connection_spec(spec) do
    do_parse_connection_spec(spec)
  catch
    :throw, {:transport_config_error, reason} ->
      {:error, {:invalid_transport_config, reason}}
  end

  def prepare_transport_config(opts), do: ConnectionManager.prepare_transport_config(opts)

  # Delegate to ConnectionManager for consistent transport spec normalization
  defp normalize_transport_spec(transport_spec, opts) do
    case ConnectionManager.prepare_transport_config([transport: transport_spec] ++ opts) do
      {:ok, [transports: [normalized_spec]]} -> normalized_spec
      {:error, reason} -> throw({:transport_config_error, reason})
    end
  end

  def do_parse_connection_spec(%Arbor.MCP.ClientConfig{} = config),
    do: Arbor.MCP.ClientConfig.to_client_opts(config)

  def do_parse_connection_spec(url) when is_binary(url) do
    uri = URI.parse(url)

    case uri.scheme do
      "http" -> [transport: :http, url: url]
      "https" -> [transport: :http, url: url]
      "stdio" -> [transport: :stdio, command: uri.path || uri.host]
      "file" -> [transport: :stdio, command: uri.path]
      _ -> [transport: :http, url: url]
    end
  end

  def do_parse_connection_spec({transport, opts}) do
    [transport: transport] ++ opts
  end

  def do_parse_connection_spec(specs) when is_list(specs) do
    transports =
      Enum.map(specs, fn
        url when is_binary(url) ->
          opts = do_parse_connection_spec(url)
          transport_atom = Keyword.fetch!(opts, :transport)
          normalize_transport_spec(transport_atom, opts)

        {transport, opts} ->
          normalize_transport_spec(transport, opts)
      end)

    [transports: transports]
  end
end
