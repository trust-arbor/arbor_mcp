#!/usr/bin/env python3
"""Associate source archives with their exact committed package sources."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tempfile


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.PIPE)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archives", type=Path, required=True)
    parser.add_argument("--mcp-source", type=Path, required=True)
    parser.add_argument("--acp-source", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Preserve an existing source selection instead of replacing it")
    archives = args.archives.resolve(strict=True)
    repos = {"arbor_mcp": args.mcp_source.resolve(strict=True),
             "arbor_acp": args.acp_source.resolve(strict=True)}
    commits = {name: git(repo, "rev-parse", "HEAD").decode().strip()
               for name, repo in repos.items()}
    if any(not re.fullmatch(r"[0-9a-f]{40}", commit) for commit in commits.values()):
        raise ValueError("Source selection requires full committed source identities")
    checker_path = Path(__file__).resolve().parent / "check_archive_consumer.py"
    spec = importlib.util.spec_from_file_location("archive_checker", checker_path)
    checker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(checker)
    evidence = {"version": args.version, "source_commits": commits, "archives": {},
                "source_commit_match_verified": True, "final_release_qualified": False,
                "checker_sha256": digest_bytes(checker_path.read_bytes())}
    with tempfile.TemporaryDirectory(prefix="arbor-source-selection-") as temporary:
        for package, owner, prefix in (("arbor_mcp", "arbor_mcp", ""),
                                       ("arbor_rpc", "arbor_acp", "packages/arbor_rpc/")):
            candidates = sorted(archives.rglob(f"{package}-*.tar"))
            if len(candidates) != 1:
                raise ValueError(f"Expected one archive for {package}")
            destination = Path(temporary) / package
            destination.mkdir()
            receipt = checker.unpack(candidates[0], destination)
            versions = re.findall(r'@version "([^"]+)"', (destination / "mix.exs").read_text())
            if versions != [args.version]:
                raise ValueError(f"Archive source version does not match selection: {package}")
            for name, expected in receipt["source_sha256"].items():
                try:
                    actual = git(repos[owner], "show", f"{commits[owner]}:{prefix}{name}")
                except subprocess.CalledProcessError:
                    raise ValueError(f"Archive entry is absent from committed source: {package}/{name}") from None
                if digest_bytes(actual) != expected:
                    raise ValueError(f"Archive entry differs from committed source: {package}/{name}")
            receipt.update(source_commit=commits[owner], source_prefix=prefix,
                           path=str(candidates[0]), bytes=candidates[0].stat().st_size)
            evidence["archives"][package] = receipt
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x") as output:
        output.write(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"source_selection": str(args.output), "commits": commits,
                      "source_commit_match_verified": True, "final_release_qualified": False}))


if __name__ == "__main__":
    main()
