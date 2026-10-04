#!/usr/bin/env python3
"""Qualify source archives through installation and a compiler-free release."""
import argparse
import io
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile


def unpack(archive, destination):
    with tarfile.open(archive) as outer:
        contents = outer.extractfile("contents.tar.gz").read()
    with tarfile.open(fileobj=io.BytesIO(contents), mode="r:gz") as inner:
        for entry in inner.getmembers():
            path = PurePosixPath(entry.name)
            if path.is_absolute() or ".." in path.parts or not (entry.isfile() or entry.isdir()):
                raise ValueError(f"Unexpected archive entry: {entry.name}")
            if path.parts and path.parts[0] in ("priv", "test", "deps", "_build"):
                raise ValueError(f"Non-source package entry: {entry.name}")
        inner.extractall(destination, filter="data")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archives", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    env = os.environ.copy()
    for key in (
        "ARBOR_V2_LOCAL", "ARBOR_V2_DEPS", "ARBOR_RPC_PATH", "ARBOR_V2_BUILD",
        "ARBOR_V2_LOCK", "MIX_BUILD_PATH", "MIX_DEPS_PATH", "MIX_LOCKFILE",
    ):
        env.pop(key, None)
    env["MIX_ENV"] = "prod"
    with tempfile.TemporaryDirectory(prefix="arbor-archive-consumer-") as directory:
        consumer = Path(directory)
        shutil.copytree(root / "fixtures/archive_consumer", consumer, dirs_exist_ok=True)
        for package in ("arbor_rpc", "arbor_mcp", "arbor_acp", "arbor_acp_adapters"):
            archives = list(args.archives.rglob(f"{package}-*.tar"))
            if len(archives) != 1:
                raise ValueError(f"Expected one {package} archive, found {len(archives)}")
            destination = consumer / "packages" / package
            destination.mkdir(parents=True)
            unpack(archives[0], destination)
        steps = [
            ("Resolve external dependencies", ["mix", "deps.get"], 180),
            ("Compile source archives", ["mix", "compile", "--warnings-as-errors"], 180),
            ("Probe installed application", ["mix", "run", "--no-compile", "-e", "CombinedArchiveConsumer.probe()"], 30),
            ("Build release", ["mix", "release", "--overwrite"], 180),
            ("Probe compiler-free release", [str(consumer / "_build/prod/rel/combined_archive_consumer/bin/combined_archive_consumer"), "eval", "CombinedArchiveConsumer.probe()"], 30),
        ]
        for title, command, timeout in steps:
            print(title, flush=True)
            subprocess.run(command, cwd=consumer, env=env, check=True, timeout=timeout)


if __name__ == "__main__":
    main()
