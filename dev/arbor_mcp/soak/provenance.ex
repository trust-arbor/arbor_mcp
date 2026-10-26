defmodule Arbor.MCP.Soak.Provenance do
  @moduledoc false

  @overrides ["ARBOR_RPC_PATH", "ARBOR_V2_DEPS", "ARBOR_V2_LOCK"]

  def capture do
    %{
      git_head: command("git", ["rev-parse", "HEAD"]),
      git_status_porcelain: command("git", ["status", "--porcelain"]),
      lockfile: Mix.Project.config()[:lockfile] || "mix.lock",
      mix_lock_sha256: sha256(Mix.Project.config()[:lockfile] || "mix.lock"),
      otp_version: otp_version(),
      elixir: System.version(),
      os_type: inspect(:os.type()),
      os_version: inspect(:os.version()),
      platform: :erlang.system_info(:system_architecture) |> List.to_string(),
      mix_env: Mix.env(),
      dependencies: dependency_versions(),
      overrides: Map.new(@overrides, &{&1, System.get_env(&1) != nil})
    }
  end

  def violations(start_snapshot, end_snapshot) do
    []
    |> maybe_violation(
      start_snapshot.git_status_porcelain != "",
      :dirty_tree,
      start_snapshot.git_status_porcelain
    )
    |> maybe_violation(
      end_snapshot.git_status_porcelain != "",
      :dirty_tree_end,
      end_snapshot.git_status_porcelain
    )
    |> maybe_violation(
      start_snapshot != end_snapshot,
      :provenance_changed,
      changed_fields(start_snapshot, end_snapshot)
    )
    |> maybe_violation(
      Enum.any?(start_snapshot.overrides, fn {_key, set?} -> set? end) or
        Enum.any?(end_snapshot.overrides, fn {_key, set?} -> set? end),
      :environment_override,
      start_snapshot.overrides
    )
  end

  defp changed_fields(start_snapshot, end_snapshot) do
    for key <- Map.keys(start_snapshot),
        Map.get(start_snapshot, key) != Map.get(end_snapshot, key),
        do: key
  end

  defp maybe_violation(violations, true, kind, value),
    do: violations ++ [%{kind: kind, value: value}]

  defp maybe_violation(violations, false, _kind, _value), do: violations

  defp command(program, args) do
    case System.cmd(program, args, stderr_to_stdout: true) do
      {output, 0} -> String.trim_trailing(output)
      {output, status} -> "command exited #{status}: #{String.trim(output)}"
    end
  end

  defp sha256(path),
    do: Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower)

  defp otp_version do
    release = :erlang.system_info(:otp_release) |> List.to_string()
    path = :code.root_dir() |> List.to_string() |> Path.join("releases/#{release}/OTP_VERSION")

    case File.read(path) do
      {:ok, version} -> String.trim(version)
      {:error, _} -> :erlang.system_info(:system_version) |> List.to_string() |> String.trim()
    end
  end

  defp dependency_versions do
    Mix.Dep.load_and_cache()
    |> Map.new(fn dep ->
      version =
        case dep.status do
          {:ok, value} -> to_string(value)
          other -> inspect(other)
        end

      {Atom.to_string(dep.app), version}
    end)
  end
end
