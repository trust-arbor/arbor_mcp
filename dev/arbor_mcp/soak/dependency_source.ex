defmodule Arbor.MCP.Soak.DependencySource do
  @moduledoc false

  @source_directories ~w(lib src c_src include config scripts priv)
  @source_files ~w(mix.exs rebar.config rebar.config.script Makefile CMakeLists.txt)

  def capture(dependencies) do
    lock = Mix.Dep.Lock.read()

    Map.new(dependencies, fn dep ->
      name = Atom.to_string(dep.app)
      {name, inspect_dependency(dep, Map.get(lock, dep.app))}
    end)
  end

  def failed(snapshot) when map_size(snapshot) == 0, do: ["<no_dependencies>"]

  def failed(snapshot) do
    for {name, entry} <- snapshot, Map.get(entry, :verified) != true, do: name
  end

  def source_hashes(root) do
    root
    |> source_paths()
    |> Map.new(fn {path, absolute} -> {path, hash_file(absolute)} end)
  end

  def artifact_hashes(root) do
    ["ebin", "priv"]
    |> Enum.flat_map(fn directory -> artifact_paths(root, directory) end)
    |> Map.new(fn {path, absolute} -> {path, hash_artifact(absolute)} end)
  end

  def changed_artifacts(start_snapshot, end_snapshot) do
    for name <- (Map.keys(start_snapshot) ++ Map.keys(end_snapshot)) |> Enum.uniq() |> Enum.sort(),
        start_entry = Map.get(start_snapshot, name, %{}),
        end_entry = Map.get(end_snapshot, name, %{}),
        Map.get(start_entry, :artifacts) != Map.get(end_entry, :artifacts),
        do: name
  end

  def compare(actual, expected) do
    %{
      verified: actual == expected and map_size(expected) > 0,
      actual_sha256: tree_hash(actual),
      expected_sha256: tree_hash(expected),
      changed_paths:
        (Map.keys(actual) ++ Map.keys(expected))
        |> Enum.uniq()
        |> Enum.filter(&(Map.get(actual, &1) != Map.get(expected, &1)))
        |> Enum.sort()
        |> Enum.take(20)
    }
  end

  defp inspect_dependency(dep, {:hex, package, version, inner, _managers, _deps, repo, outer}) do
    root = dep.opts[:dest]
    archive = package_archive(repo, package, version)
    actual = source_hashes(root)
    artifacts = runtime_artifacts(dep.app)

    with {:ok, bytes} <- File.read(archive),
         ^outer <- hash(bytes),
         {:ok, expected} <- archive_hashes(bytes, inner) do
      generated =
        if Enum.all?(expected, fn {path, digest} -> Map.get(actual, path) == digest end) do
          verified_generated_paths(root, actual, expected) |> Enum.sort()
        else
          []
        end

      generated_priv =
        for path <- Map.keys(actual),
            String.starts_with?(path, "priv/"),
            not Map.has_key?(expected, path),
            do: path

      compare(Map.drop(actual, generated ++ generated_priv), expected)
      |> Map.merge(%{
        archive_sha256: hash(bytes),
        lock_sha256: outer,
        package: to_string(package),
        version: version,
        generated_verified: generated,
        generated_priv: Map.take(actual, generated_priv),
        artifacts: artifacts,
        artifacts_sha256: tree_hash(artifacts)
      })
      |> Map.update!(:verified, &(&1 and artifacts_valid?(artifacts)))
    else
      {:error, reason} ->
        failed_entry(actual, outer, {:archive_error, reason}, artifacts)

      actual_hash when is_binary(actual_hash) ->
        failed_entry(actual, outer, {:archive_checksum_mismatch, actual_hash}, artifacts)
    end
  rescue
    error -> failed_entry(%{}, outer, {:exception, Exception.message(error)}, %{})
  end

  defp inspect_dependency(dep, _lock) do
    artifacts = runtime_artifacts(dep.app)

    %{
      verified: false,
      reason: :non_hex_dependency,
      actual_sha256: dep.opts[:dest] |> source_hashes() |> tree_hash(),
      artifacts: artifacts,
      artifacts_sha256: tree_hash(artifacts)
    }
  end

  defp failed_entry(actual, outer, reason, artifacts) do
    %{
      verified: false,
      reason: reason,
      actual_sha256: tree_hash(actual),
      lock_sha256: outer,
      artifacts: artifacts,
      artifacts_sha256: tree_hash(artifacts)
    }
  end

  defp runtime_artifacts(app) do
    Mix.Project.build_path()
    |> Path.join("lib")
    |> Path.join(Atom.to_string(app))
    |> artifact_hashes()
  end

  defp artifacts_valid?(artifacts) do
    Enum.any?(artifacts, fn {path, hash} ->
      String.starts_with?(path, "ebin/") and is_binary(hash)
    end) and Enum.all?(artifacts, fn {_path, hash} -> is_binary(hash) end)
  end

  defp package_archive(repo, package, version) do
    home = System.get_env("HEX_HOME") || Path.join(System.user_home!(), ".hex")
    Path.join([home, "packages", to_string(repo), "#{package}-#{version}.tar"])
  end

  defp archive_hashes(bytes, inner_checksum) do
    with {:ok, outer_files} <- :erl_tar.extract({:binary, bytes}, [:memory]),
         {:ok, contents} <- fetch_entry(outer_files, "contents.tar.gz"),
         {:ok, checksum} <- fetch_entry(outer_files, "CHECKSUM"),
         true <- String.downcase(checksum) == String.downcase(inner_checksum),
         {:ok, source_files} <- :erl_tar.extract({:binary, contents}, [:compressed, :memory]) do
      {:ok,
       Map.new(source_files, fn {path, data} -> {to_string(path), hash(data)} end)
       |> Map.filter(fn {path, _digest} -> source_path?(path) end)}
    else
      false -> {:error, :inner_checksum_mismatch}
      error -> error
    end
  end

  defp fetch_entry(files, name) do
    case Enum.find(files, fn {path, _bytes} -> to_string(path) == name end) do
      {_path, bytes} -> {:ok, bytes}
      nil -> {:error, {:missing_archive_entry, name}}
    end
  end

  defp source_paths(root) do
    directories =
      Enum.flat_map(@source_directories, fn directory ->
        path = Path.join(root, directory)

        case File.lstat(path) do
          {:ok, %{type: :directory}} -> all_paths(root, directory)
          {:ok, _other} -> [{directory, path}]
          {:error, _missing} -> []
        end
      end)

    files =
      for file <- @source_files,
          path = Path.join(root, file),
          File.exists?(path),
          do: {file, path}

    directories ++ files
  end

  defp artifact_paths(root, relative) do
    absolute = Path.join(root, relative)

    case File.stat(absolute) do
      {:ok, %{type: :directory}} ->
        case File.ls(absolute) do
          {:ok, names} -> Enum.flat_map(names, &artifact_paths(root, Path.join(relative, &1)))
          {:error, _reason} -> [{relative, absolute}]
        end

      {:ok, _file} ->
        [{relative, absolute}]

      {:error, :enoent} when relative == "priv" ->
        []

      {:error, _reason} ->
        [{relative, absolute}]
    end
  end

  defp hash_artifact(path) do
    case File.stat(path) do
      {:ok, %{type: :regular}} -> hash_file_contents(path)
      {:ok, %{type: type}} -> {:error, type}
      {:error, reason} -> {:error, reason}
    end
  end

  defp all_paths(root, relative) do
    absolute = Path.join(root, relative)

    case File.ls(absolute) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          path = Path.join(relative, name)
          full = Path.join(root, path)

          case File.lstat(full) do
            {:ok, %{type: :directory}} -> all_paths(root, path)
            {:ok, _} -> [{path, full}]
            {:error, _} -> [{path, full}]
          end
        end)

      {:error, _} ->
        [{relative, absolute}]
    end
  end

  defp source_path?(path) do
    parts = Path.split(path)
    path in @source_files or (parts != [] and hd(parts) in @source_directories)
  end

  defp verified_generated_paths(root, actual, expected) do
    for path <- Map.keys(actual),
        not Map.has_key?(expected, path),
        String.ends_with?(path, ".erl"),
        extension <- [".xrl", ".yrl"],
        input = String.replace_suffix(path, ".erl", extension),
        Map.has_key?(expected, input),
        generated_matches?(root, input, path),
        uniq: true,
        do: path
  end

  @doc false
  def generated_matches?(root, input, output) do
    directory =
      Path.join(System.tmp_dir!(), "soak-generated-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(directory)
      target = Path.join(directory, Path.basename(output))
      source = Path.join(root, input) |> String.to_charlist()
      target_chars = String.to_charlist(target)
      :ok = ensure_parsetools()

      generated =
        case Path.extname(input) do
          ".xrl" -> :erlang.apply(:leex, :file, [source, [scannerfile: target_chars]])
          ".yrl" -> :erlang.apply(:yecc, :file, [source, [parserfile: target_chars]])
        end

      match?({:ok, _}, generated) and
        normalized_generated(File.read!(target)) ==
          normalized_generated(File.read!(Path.join(root, output)))
    rescue
      _error -> false
    after
      File.rm_rf(directory)
    end
  end

  defp ensure_parsetools do
    if :code.lib_dir(:parsetools) == {:error, :bad_name} do
      root = :code.root_dir() |> List.to_string()

      for path <- Path.wildcard(Path.join(root, "lib/parsetools-*/ebin")) do
        :code.add_patha(String.to_charlist(path))
      end
    end

    case Application.ensure_all_started(:parsetools) do
      {:ok, _applications} -> :ok
      _error -> {:error, :parsetools_unavailable}
    end
  end

  defp normalized_generated(contents) do
    Regex.replace(~r/-file\("[^"]+", (\d+)\)\./, contents, fn _full, line ->
      "-file(\"<path>\", #{line})."
    end)
  end

  defp hash_file(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        hash_file_contents(path)

      {:ok, %{type: type}} ->
        {:error, type}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp hash_file_contents(path) do
    case File.read(path) do
      {:ok, bytes} -> hash(bytes)
      {:error, reason} -> {:error, reason}
    end
  end

  defp tree_hash(files) do
    files
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {path, digest} -> [path, <<0>>, inspect(digest), <<0>>] end)
    |> hash()
  end

  defp hash(data), do: Base.encode16(:crypto.hash(:sha256, data), case: :lower)
end
