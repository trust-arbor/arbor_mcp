#!/usr/bin/env python3
"""Prepare reviewable source copies; never tag, publish, or mutate the inputs."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def copy_source(source, destination):
    names = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=source
    ).decode().split("\0")
    copied = {}
    for name in sorted(set(filter(None, names))):
        if "__pycache__" in Path(name).parts or Path(name).suffix in (".pyc", ".beam", ".o"):
            raise ValueError(f"Generated file in source inventory: {name}")
        original = source / name
        if not original.exists():
            continue  # A reviewed source deletion is absent from the copy too.
        if original.is_symlink() or not original.is_file():
            raise ValueError(f"Not a regular source file: {original}")
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(original, target)
        copied[name] = sha256(original)
    return copied


def rewrite(project, version, requirement):
    path = project / "mix.exs"
    source = path.read_text()
    source, count = re.subn(r'@version "[^"]+"', f'@version "{version}"', source)
    if count != 1:
        raise ValueError(f"Expected one literal @version: {path}")
    if "@internal_requirement" in source:
        source, count = re.subn(
            r'@internal_requirement "[^"]+"', f'@internal_requirement "{requirement}"', source
        )
        if count != 1:
            raise ValueError(f"Expected one literal internal requirement: {path}")
    path.write_text(source)
    readme = project / "README.md"
    if readme.exists():
        text = readme.read_text()
        text = re.sub(r"Version `2\.0\.0(?:-dev|-rc\.[1-9][0-9]*)?`", f"Version `{version}`", text, count=1)
        readme.write_text(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mcp-source", type=Path, required=True)
    parser.add_argument("--acp-source", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"2\.0\.0(?:-dev|-rc\.[1-9][0-9]*)?", args.version):
        parser.error("Expected coordinated 2.0.0-dev, 2.0.0-rc.N, or 2.0.0")
    # Prerelease inclusion is explicit. Stable keeps normal major compatibility.
    requirement = f"~> {args.version}" if "-" in args.version else "~> 2.0"
    output = args.output.resolve()
    sources = {"arbor_mcp": args.mcp_source.resolve(), "arbor_acp": args.acp_source.resolve()}
    for source in sources.values():
        if output == source or source in output.parents or output in source.parents:
            parser.error("Output and input trees must not overlap")
    output.mkdir(parents=True, exist_ok=False)
    copied = {name: copy_source(source, output / name) for name, source in sources.items()}
    projects = {
        "arbor_mcp": output / "arbor_mcp",
        **{app: output / "arbor_acp/packages" / app
           for app in ("arbor_rpc", "arbor_acp", "arbor_acp_adapters")},
    }
    for project in projects.values():
        rewrite(project, args.version, requirement)
    tags = {app: (f"v{args.version}" if app == "arbor_mcp" else f"{app}-v{args.version}")
            for app in projects}
    manifest = {
        "version": args.version,
        "internal_requirement": requirement,
        "tags": tags,
        "release_order": [["arbor_rpc"], ["arbor_mcp", "arbor_acp"], ["arbor_acp_adapters"]],
        "source_inputs": {name: {"commit": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=source).decode().strip(), "sha256": copied[name]}
            for name, source in sources.items()},
        "prepared_files_sha256": {
            app: {name: sha256(project / name) for name in ("mix.exs", "README.md")}
            for app, project in projects.items()
        },
        "publication": "Not performed; final source commit, package tags and archives must agree.",
    }
    (output / "release-preparation.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(output / "release-preparation.json")


if __name__ == "__main__":
    main()
