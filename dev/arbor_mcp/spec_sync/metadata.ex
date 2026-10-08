defmodule Arbor.MCP.SpecSync.Metadata do
  @moduledoc """
  Manages sync metadata for MCP specification files.

  Tracks per-file SHA256 checksums, ETags, and sync timestamps
  in a `.sync_metadata.json` file within the specs directory.
  """

  @metadata_file ".sync_metadata.json"

  @type file_entry :: %{
          sha256: String.t(),
          etag: String.t() | nil,
          synced_at: String.t(),
          source_url: String.t()
        }

  @type t :: %{
          version: integer(),
          last_sync: String.t() | nil,
          files: %{String.t() => file_entry()}
        }

  @doc """
  Loads sync metadata from the given base directory.

  Returns a metadata map with file checksums and sync info.
  If the file doesn't exist, returns an empty metadata structure.
  """
  @spec load(String.t()) :: t()
  def load(base_dir) do
    path = Path.join(base_dir, @metadata_file)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> normalize(data)
          {:error, _} -> empty()
        end

      {:error, _} ->
        empty()
    end
  end

  @doc """
  Saves sync metadata to the given base directory.
  """
  @spec save(String.t(), t()) :: :ok | {:error, term()}
  def save(base_dir, metadata) do
    path = Path.join(base_dir, @metadata_file)
    File.mkdir_p!(base_dir)

    content =
      metadata
      |> Map.put(:last_sync, DateTime.utc_now() |> DateTime.to_iso8601())
      |> Jason.encode!(pretty: true)

    File.write(path, content)
  end

  @doc """
  Checks if a file has changed compared to the stored metadata.

  Returns `true` if the file is new or its content differs from
  the stored checksum.
  """
  @spec file_changed?(t(), String.t(), binary()) :: boolean()
  def file_changed?(metadata, relative_path, content) do
    stored_sha = get_in(metadata, [:files, relative_path, :sha256])
    current_sha = sha256(content)
    stored_sha != current_sha
  end

  @doc """
  Updates metadata for a specific file after successful sync.
  """
  @spec update_file(t(), String.t(), binary(), keyword()) :: t()
  def update_file(metadata, relative_path, content, opts \\ []) do
    entry = %{
      sha256: sha256(content),
      etag: Keyword.get(opts, :etag),
      synced_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      source_url: Keyword.get(opts, :source_url, "")
    }

    put_in(metadata, [:files, relative_path], entry)
  end

  @doc """
  Returns the stored ETag for a file, if any.
  """
  @spec get_etag(t(), String.t()) :: String.t() | nil
  def get_etag(metadata, relative_path) do
    get_in(metadata, [:files, relative_path, :etag])
  end

  @doc """
  Computes SHA256 checksum of content.
  """
  @spec sha256(binary()) :: String.t()
  def sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  # Private

  defp empty do
    %{version: 1, last_sync: nil, files: %{}}
  end

  defp normalize(data) when is_map(data) do
    %{
      version: Map.get(data, "version", 1),
      last_sync: Map.get(data, "last_sync"),
      files: normalize_files(Map.get(data, "files", %{}))
    }
  end

  defp normalize_files(files) when is_map(files) do
    Map.new(files, fn {path, entry} ->
      {path,
       %{
         sha256: Map.get(entry, "sha256", ""),
         etag: Map.get(entry, "etag"),
         synced_at: Map.get(entry, "synced_at", ""),
         source_url: Map.get(entry, "source_url", "")
       }}
    end)
  end

  defp normalize_files(_), do: %{}
end
