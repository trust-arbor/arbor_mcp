#!/usr/bin/env python3
"""Qualify source archives through installation and a compiler-free release."""
import argparse
import hashlib
import io
import json
import os
import re
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile


def unpack(archive, destination):
    with tarfile.open(archive) as outer:
        version = outer.extractfile("VERSION").read()
        metadata = outer.extractfile("metadata.config").read()
        contents = outer.extractfile("contents.tar.gz").read()
        checksum = outer.extractfile("CHECKSUM").read().decode().strip()
    if hashlib.sha256(version + metadata + contents).hexdigest().upper() != checksum:
        raise ValueError(f"Invalid Hex checksum: {archive}")
    hashes = {}
    with tarfile.open(fileobj=io.BytesIO(contents), mode="r:gz") as inner:
        for entry in inner.getmembers():
            path = PurePosixPath(entry.name)
            if path.is_absolute() or ".." in path.parts or not (entry.isfile() or entry.isdir()):
                raise ValueError(f"Unexpected archive entry: {entry.name}")
            if path.parts and path.parts[0] in ("priv", "dev", "test", "deps", "_build"):
                raise ValueError(f"Non-source package entry: {entry.name}")
            if entry.isfile():
                if entry.name in hashes:
                    raise ValueError(f"Duplicate source entry: {entry.name}")
                hashes[entry.name] = hashlib.sha256(inner.extractfile(entry).read()).hexdigest()
        inner.extractall(destination, filter="data")
    if "mix.exs" not in hashes or not any(name.startswith("lib/") for name in hashes):
        raise ValueError(f"Missing package source: {archive}")
    if archive.name.startswith("arbor_rpc-") and "c_src/subprocess_helper.c" not in hashes:
        raise ValueError("RPC archive must ship reviewed C source")
    (destination / ".archive-metadata.config").write_bytes(metadata)
    return {
        "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "contents_sha256": hashlib.sha256(contents).hexdigest(),
        "hex_checksum": checksum,
        "metadata_sha256": hashlib.sha256(metadata).hexdigest(),
        "source_sha256": hashes,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archives", type=Path)
    parser.add_argument("--expected-version", help="Legacy uniform-version assertion")
    parser.add_argument("--expected-package-version", action="append", default=[], metavar="APP=VERSION")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--metadata-only", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    env = os.environ.copy()
    for key in (
        "ARBOR_V2_LOCAL", "ARBOR_V2_DEPS", "ARBOR_RPC_PATH", "ARBOR_V2_BUILD",
        "ARBOR_V2_LOCK", "MIX_BUILD_PATH", "MIX_DEPS_PATH", "MIX_LOCKFILE",
        "ARBOR_RELEASE_VERSION",
    ):
        env.pop(key, None)
    env["MIX_ENV"] = "prod"
    # The validation variable never affects a package's literal version.
    if args.expected_version:
        env["ARCHIVE_EXPECTED_VERSION"] = args.expected_version
    evidence = {"expected_version": args.expected_version, "packages": {}, "steps": []}
    with tempfile.TemporaryDirectory(prefix="arbor-archive-consumer-") as directory:
        consumer = Path(directory)
        shutil.copytree(root / "fixtures/archive_consumer", consumer, dirs_exist_ok=True)
        for package in ("arbor_rpc", "arbor_mcp", "arbor_acp", "arbor_acp_adapters"):
            archives = list(args.archives.rglob(f"{package}-*.tar"))
            if len(archives) != 1:
                raise ValueError(f"Expected one {package} archive, found {len(archives)}")
            destination = consumer / "packages" / package
            destination.mkdir(parents=True)
            evidence["packages"][package] = unpack(archives[0], destination)
        expected_versions = {}
        for value in args.expected_package_version:
            app, separator, version = value.partition("=")
            if not separator or app not in evidence["packages"] or app in expected_versions:
                raise ValueError(f"Invalid or duplicate package version assertion: {value}")
            expected_versions[app] = version
        for app in evidence["packages"]:
            versions = re.findall(
                r'@version "([^"]+)"', (consumer / "packages" / app / "mix.exs").read_text()
            )
            if len(versions) != 1:
                raise ValueError(f"Expected one literal source version: {app}")
            expected = expected_versions.get(app) or args.expected_version or env.get(
                "ARCHIVE_EXPECTED_VERSION_" + app.upper()
            ) or versions[0]
            expected_versions[app] = expected
            env["ARCHIVE_EXPECTED_VERSION_" + app.upper()] = expected
        evidence["expected_versions"] = expected_versions
        env["ARCHIVE_INSTALL_REPORT"] = str(consumer / "installed-checks.json")
        projects = [str(consumer / "packages" / app) for app in evidence["packages"]]
        subprocess.run(
            ["elixir", str(root / "scripts/check_package_metadata.exs"), *projects],
            env=env, check=True, timeout=30,
        )
        steps = [] if args.metadata_only else [
            ("Resolve external dependencies", ["mix", "deps.get"], 180),
            # As in the package CI lane, isolate third-party OTP deprecations.
            ("Compile dependencies", ["mix", "deps.compile"], 180),
            ("Compile source archives", ["mix", "compile", "--warnings-as-errors", "--no-deps-check"], 180),
            ("Probe installed application", ["mix", "run", "--no-compile", "-e", "CombinedArchiveConsumer.probe()"], 30),
            ("Build release", ["mix", "release", "--overwrite"], 180),
            ("Probe compiler-free release", [str(consumer / "_build/prod/rel/combined_archive_consumer/bin/combined_archive_consumer"), "eval", "CombinedArchiveConsumer.probe()"], 30),
        ]
        for title, command, timeout in steps:
            print(title, flush=True)
            subprocess.run(command, cwd=consumer, env=env, check=True, timeout=timeout)
            evidence["steps"].append(title)
            if title.startswith("Probe "):
                evidence.setdefault("installed", {})[title] = json.loads(
                    (consumer / "installed-checks.json").read_text()
                )
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.report.with_suffix(args.report.suffix + ".tmp")
        temporary.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
        temporary.replace(args.report)


if __name__ == "__main__":
    main()
