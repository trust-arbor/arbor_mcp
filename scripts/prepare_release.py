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


def rewrite(project, version, requirements):
    path = project / "mix.exs"
    source = path.read_text()
    source, count = re.subn(r'@version "[^"]+"', f'@version "{version}"', source)
    if count != 1:
        raise ValueError(f"Expected one literal @version: {path}")
    for dependency, requirement in requirements.items():
        source, count = re.subn(
            rf'@{dependency}_requirement "[^"]+"', f'@{dependency}_requirement "{requirement}"', source
        )
        if count != 1:
            raise ValueError(f"Expected one literal {dependency} requirement: {path}")
    path.write_text(source)
    readme = project / "README.md"
    if readme.exists():
        text = readme.read_text()
        text = re.sub(r"Version `[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?`", f"Version `{version}`", text, count=1)
        readme.write_text(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mcp-source", type=Path, required=True)
    parser.add_argument("--acp-source", type=Path, required=True)
    parser.add_argument("--rpc-source", type=Path, required=True)
    for package in ("mcp", "rpc", "acp", "adapters"):
        parser.add_argument(f"--{package}-version", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {"arbor_mcp": args.mcp_version, "arbor_rpc": args.rpc_version,
                "arbor_acp": args.acp_version, "arbor_acp_adapters": args.adapters_version}
    for package, version in versions.items():
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?", version):
            parser.error(f"Invalid {package} version: {version}")
    # Requirements follow the dependency's version, independently of its consumer.
    def floor(version):
        return f"~> {version}" if "-" in version else "~> " + ".".join(version.split(".")[:2])

    requirements = {"arbor_mcp": {"rpc": floor(args.rpc_version)},
                    "arbor_rpc": {}, "arbor_acp": {"rpc": floor(args.rpc_version)},
                    "arbor_acp_adapters": {"rpc": floor(args.rpc_version), "acp": floor(args.acp_version)}}
    output = args.output.resolve()
    sources = {"arbor_mcp": args.mcp_source.resolve(), "arbor_acp": args.acp_source.resolve(),
               "arbor_rpc": args.rpc_source.resolve()}
    for source in sources.values():
        if output == source or source in output.parents or output in source.parents:
            parser.error("Output and input trees must not overlap")
    output.mkdir(parents=True, exist_ok=False)
    copied = {name: copy_source(source, output / name) for name, source in sources.items()}
    projects = {
        "arbor_mcp": output / "arbor_mcp",
        "arbor_rpc": output / "arbor_rpc",
        **{app: output / "arbor_acp/packages" / app
           for app in ("arbor_acp", "arbor_acp_adapters")},
    }
    for app, project in projects.items():
        rewrite(project, versions[app], requirements[app])
    tags = {app: (f"v{versions[app]}" if app in ("arbor_mcp", "arbor_rpc") else f"{app}-v{versions[app]}")
            for app in projects}
    manifest = {
        "versions": versions,
        "dependency_requirements": requirements,
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
