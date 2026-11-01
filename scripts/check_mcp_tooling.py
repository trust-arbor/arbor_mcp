#!/usr/bin/env python3
"""Record SDK/harness release drift and every upstream scenario, without repinning."""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / "scripts/mcp_tooling_baseline.json"
REVIEWS = ROOT / "scripts/mcp_upstream_reviews.json"
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?(?:\+[A-Za-z0-9.-]+)?")
HEADINGS = {
    "Server scenarios (test against a server):": "server",
    "Client scenarios (test against a client):": "client",
    "Authorization server scenarios (test against an authorization server):": "authorization"}


class ToolingError(Exception):
    """Missing inventory is an error, not an unchanged result."""


def published_at(value):
    if not isinstance(value, str):
        raise ToolingError("Missing package publication timestamp")
    try:
        timestamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ToolingError("Invalid package publication timestamp") from error
    if timestamp.tzinfo is None:
        raise ToolingError("Package publication timestamp has no timezone")
    return timestamp


def review_key(change):
    return hashlib.sha256(json.dumps(change, sort_keys=True).encode()).hexdigest()


def release_dates(release):
    if not isinstance(release, dict) or not isinstance(release.get("time"), dict):
        raise ToolingError("Incomplete package publication metadata")
    versions = release.get("versions")
    if not isinstance(versions, list) or not versions or any(
            not isinstance(v, str) or not VERSION.fullmatch(v) for v in versions):
        raise ToolingError("Incomplete package release inventory")
    return {version: published_at(release["time"].get(version)) for version in versions}


def newest_harness():
    release = json.loads(command(["npm", "view", "@modelcontextprotocol/conformance", "versions", "time", "--json"]))
    dates = release_dates(release)
    return max(dates, key=lambda version: (dates[version], version))


def load_reviews(path=REVIEWS):
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("reviews"), dict):
        raise ToolingError("Invalid upstream review register")
    for key, record in data["reviews"].items():
        if (not isinstance(record, dict) or record.get("status") not in {"open", "assessed"} or
                not isinstance(record.get("change"), dict) or review_key(record["change"]) != key or
                not record.get("id") or not record.get("decision") or
                not record.get("source_url", "").startswith("https://")):
            raise ToolingError("Invalid upstream review record")
    return data["reviews"]


def command(args):
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True, timeout=180,
                            env=dict(os.environ, npm_config_ignore_scripts="true"), check=False)
    if result.returncode:
        raise ToolingError(f"Tool inventory command failed: {args[0]}")
    return result.stdout


def scenarios(text):
    groups, current = {}, None
    for line in text.splitlines():
        if not line.strip():
            continue
        if line in HEADINGS:
            current = HEADINGS[line]
            if current in groups:
                raise ToolingError("Duplicate scenario inventory section")
            groups[current] = {}
            continue
        match = re.fullmatch(r"  - ([A-Za-z0-9_./-]+) \[([0-9,-]+)\]", line)
        if not current or not match or match[1] in groups[current]:
            raise ToolingError("Unknown or duplicate upstream scenario inventory entry")
        groups[current][match[1]] = match[2].split(",")
    if set(groups) != set(HEADINGS.values()) or any(not entries for entries in groups.values()):
        raise ToolingError("Incomplete upstream scenario inventory")
    return groups


def compare(baseline, releases, inventory, version, reviews=None):
    if not VERSION.fullmatch(version):
        raise ToolingError("Invalid harness version")
    changes = []
    for package, pin in baseline["packages"].items():
        release = releases.get(package)
        dates = release_dates(release)
        if pin not in dates:
            changes.append({"package": package, "kind": "pinned_version_missing", "pin": pin})
            continue
        newer = sorted((version for version in dates if dates[version] > dates[pin]),
                       key=lambda version: (dates[version], version))
        for version_name in newer:
            changes.append({"package": package, "kind": "newer_published", "pin": pin,
                            "version": version_name, "published_at": release["time"][version_name]})
    previous = baseline["scenarios"]
    scenario_changes = []
    for group in HEADINGS.values():
        old, new = previous[group], inventory[group]
        for name in sorted(old.keys() | new.keys()):
            if old.get(name) != new.get(name):
                scenario_changes.append({"role": group, "scenario": name,
                                         "before": old.get(name), "after": new.get(name)})
    key = review_key({"releases": changes, "scenarios": scenario_changes})
    for change in changes + scenario_changes:
        change["review_key"] = review_key(change)
        record = (reviews or {}).get(change["review_key"])
        change["tracking_id"] = record["id"] if record else None
        change["review_status"] = record["status"] if record else "untracked"
    return {"status": "complete", "harness_version": version, "release_changes": changes,
            "scenario_changes": scenario_changes, "review_key": key,
            "needs_review": bool(changes or scenario_changes), "scenarios": inventory,
            "limits": "Scenario availability is not test execution. Runtime skips are checked separately. No pins advanced."}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--version")
    group.add_argument("--resolve-harness", action="store_true", help="Print the newest harness by publication timestamp")
    group.add_argument("--core-inventory", help="Print this harness's actual core scenario inventory")
    parser.add_argument("--output", type=Path, default=ROOT / "tmp/mcp-tooling")
    args = parser.parse_args(argv)
    report = None
    code = 0
    try:
        if args.resolve_harness:
            print(newest_harness())
            return 0
        if args.core_inventory:
            if not VERSION.fullmatch(args.core_inventory):
                raise ToolingError("Invalid requested harness version")
            inventory = scenarios(command([
                "npx", "--yes", f"@modelcontextprotocol/conformance@{args.core_inventory}",
                "list", "--spec-version", "2026-07-28"]))
            print(json.dumps({"harness": "@modelcontextprotocol/conformance@" + args.core_inventory,
                              "protocol": "2026-07-28", "scenarios": inventory}, sort_keys=True))
            return 0
        if not VERSION.fullmatch(args.version):
            raise ToolingError("Invalid requested harness version")
        baseline = json.loads(BASELINE.read_text())
        releases = {package: json.loads(command(["npm", "view", package, "versions", "time", "--json"]))
                    for package in baseline["packages"]}
        inventory = scenarios(command(["npx", "--yes", f"@modelcontextprotocol/conformance@{args.version}",
                                       "list", "--spec-version", "2026-07-28"]))
        report = compare(baseline, releases, inventory, args.version, load_reviews())
    except (ToolingError, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        if args.resolve_harness or args.core_inventory:
            print(f"Harness version collection incomplete: {error}", file=sys.stderr)
            return 1
        report = {"status": "error", "error": str(error)}
        code = 1
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    lines = ["# MCP SDK and conformance inventory", "", "```json", json.dumps(report, indent=2), "```", ""]
    (args.output / "report.md").write_text("\n".join(lines))
    if report.get("needs_review"):
        print(f"::warning::MCP tooling review required: {report['review_key']}")
    return code


if __name__ == "__main__":
    sys.exit(main())
