#!/usr/bin/env python3
"""Retain a fresh, normally resolved listener consumer made from source archives."""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archives", type=Path, required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--adapter", choices=("cowboy", "bandit"), required=True)
    parser.add_argument("--selection-manifest", type=Path)
    parser.add_argument("--metadata-only", action="store_true")
    args = parser.parse_args()
    if not args.metadata_only and args.selection_manifest is None:
        parser.error("Physical qualification requires a source/archive selection manifest")
    root = Path(__file__).resolve().parent.parent
    archives = args.archives.resolve(strict=True)
    workspace = args.workspace.resolve()
    for source in (archives, root):
        if source == workspace or source in workspace.parents or workspace in source.parents:
            parser.error("Input and workspace trees must not overlap")
    workspace.mkdir(parents=True, exist_ok=False)
    logs = workspace / "logs"
    logs.mkdir()
    consumer = workspace / "consumer"
    shutil.copytree(root / "fixtures/listener_archive_consumer", consumer)
    spec = importlib.util.spec_from_file_location("archive_checker", root / "scripts/check_archive_consumer.py")
    checker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(checker)
    evidence = {
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "adapter": args.adapter,
        "expected_version": args.expected_version,
        "qualified": False,
        "final_release_qualified": False,
        "metadata_only": args.metadata_only,
        "resolution": "Extracted paths for unpublished Arbor packages; normal Hex external dependencies",
        "tooling_sha256": {str(path.relative_to(root)): digest(path) for directory in
                           (root / "scripts", root / "fixtures/listener_archive_consumer")
                           for path in sorted(directory.rglob("*"))
                           if path.is_file() and "__pycache__" not in path.parts},
        "archives": {},
        "steps": [],
    }
    report = workspace / "result.json"
    env = os.environ.copy()
    for key in (
        "ARBOR_V2_LOCAL", "ARBOR_V2_DEPS", "ARBOR_RPC_PATH", "ARBOR_V2_BUILD", "ARBOR_V2_LOCK",
        "MIX_BUILD_PATH", "MIX_DEPS_PATH", "MIX_LOCKFILE", "ARBOR_RELEASE_VERSION",
        "ARCHIVE_CONSUMER_EXTERNAL_DEPS", "ARCHIVE_INSTALL_REPORT", "ERL_LIBS",
    ):
        env.pop(key, None)
    env.update(MIX_ENV="prod", LISTENER_ARCHIVE_ADAPTER=args.adapter,
               ARCHIVE_EXPECTED_VERSION=args.expected_version)

    def run(name, argv, timeout=180, extra=None):
        log = logs / f"{len(evidence['steps']):02}-{name}.log"
        command_env = dict(env, **(extra or {}))
        start = time.monotonic()
        step = {"name": name, "argv": [str(arg) for arg in argv], "cwd": str(consumer),
                "log": str(log), "environment": {key: command_env[key] for key in
                ("MIX_ENV", "LISTENER_ARCHIVE_ADAPTER", "ARCHIVE_EXPECTED_VERSION", "LISTENER_ARCHIVE_REPORT")
                if key in command_env}}
        try:
            with log.open("wb") as output:
                process = subprocess.run(argv, cwd=consumer, env=command_env, stdout=output,
                                         stderr=subprocess.STDOUT, timeout=timeout)
            step["exit_code"] = process.returncode
        except subprocess.TimeoutExpired:
            step["timed_out"] = True
            step["exit_code"] = None
            raise
        finally:
            step["elapsed_seconds"] = time.monotonic() - start
            step["log_sha256"] = digest(log)
            evidence["steps"].append(step)
            atomic_json(report, evidence)
        if process.returncode != 0:
            raise RuntimeError(f"{name} failed; preserved {log}")

    try:
        selection = None
        if args.selection_manifest is not None:
            selected_path = args.selection_manifest.resolve(strict=True)
            selection = json.loads(selected_path.read_text())
            if selection["version"] != args.expected_version:
                raise ValueError("Source selection version does not match expected version")
            for owner in ("arbor_mcp", "arbor_rpc"):
                if not re.fullmatch(r"[0-9a-f]{40}", selection["source_commits"][owner]):
                    raise ValueError(f"Invalid source commit in selection: {owner}")
            evidence["source_selection"] = {"path": str(selected_path), "sha256": digest(selected_path),
                                            "association": selection,
                                            "scope": "Commit/archive association supplied by the source build gate; not independently proven by this consumer"}
        projects = []
        for package in ("arbor_rpc", "arbor_mcp"):
            matches = sorted(archives.rglob(f"{package}-*.tar"))
            if len(matches) != 1:
                raise ValueError(f"Expected one {package} archive, found {len(matches)}")
            destination = consumer / "packages" / package
            destination.mkdir(parents=True)
            receipt = checker.unpack(matches[0], destination)
            receipt.update(path=str(matches[0]), bytes=matches[0].stat().st_size)
            evidence["archives"][package] = receipt
            if selection is not None:
                expected = selection["archives"][package]
                if expected["archive_sha256"] != receipt["archive_sha256"] or expected["source_sha256"] != receipt["source_sha256"]:
                    raise ValueError(f"Archive bytes or shipped source do not match selection: {package}")
            projects.append(str(destination))
        run("metadata", ["elixir", str(root / "scripts/check_package_metadata.exs"), *projects], 30)
        evidence["metadata_qualified"] = True
        if args.metadata_only:
            return
        run("resolve", ["mix", "deps.get"], 180)
        lock = consumer / "mix.lock"
        evidence["resolved_lock"] = {"sha256": digest(lock), "text": lock.read_text()}
        run("dependency-status", ["mix", "deps"], 30)
        run("compile-dependencies", ["mix", "deps.compile"], 300)
        run("compile-consumer", ["mix", "compile", "--warnings-as-errors", "--no-deps-check"], 180)
        installed = workspace / "installed-probe.json"
        run("installed-probe", ["mix", "run", "--no-compile", "-e", "ListenerArchiveConsumer.probe()"], 45,
            {"LISTENER_ARCHIVE_REPORT": str(installed)})
        evidence["installed"] = {"sha256": digest(installed), "receipt": json.loads(installed.read_text())}
        run("assemble-release", ["mix", "release", "--overwrite"], 180)
        released = workspace / "release-probe.json"
        binary = consumer / "_build/prod/rel/listener_archive_consumer/bin/listener_archive_consumer"
        run("release-probe", [str(binary), "eval", "ListenerArchiveConsumer.probe()"], 45,
            {"LISTENER_ARCHIVE_REPORT": str(released)})
        evidence["release"] = {"sha256": digest(released), "receipt": json.loads(released.read_text())}
        if evidence["resolved_lock"]["sha256"] != digest(lock):
            raise ValueError("Dependency lock changed after resolution")
        for package, receipt in evidence["archives"].items():
            for name, sha in receipt["source_sha256"].items():
                if digest(consumer / "packages" / package / name) != sha:
                    raise ValueError(f"Shipped source changed during installation: {package}/{name}")
        evidence["qualified"] = True
    except BaseException as error:
        evidence["failure"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        evidence["finished_utc"] = datetime.now(timezone.utc).isoformat()
        atomic_json(report, evidence)
        print(report, flush=True)


if __name__ == "__main__":
    main()
