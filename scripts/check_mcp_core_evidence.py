#!/usr/bin/env python3
"""Qualify existing official core scenarios, without replacing their assertions."""
from collections import Counter
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

from check_mcp_assurance import ROOT, fingerprint, load_register

BASELINE = ROOT / "scripts/mcp_core_checks.json"
STAMP = re.compile(r"-\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d-\d{3}Z$")


def inventory(directory):
    scenarios = {}
    for role in ("server", "client"):
        for path in sorted((directory / role).rglob("checks.json")):
            name = path.parent.relative_to(directory / role).as_posix()
            name = STAMP.sub("", name)
            if role == "server":
                name = name.removeprefix("server-")
            key = role + ":" + name
            if key in scenarios:
                raise ValueError("Duplicate official scenario: " + key)
            rows = json.loads(path.read_text())
            if not isinstance(rows, list) or not rows:
                raise ValueError("Empty official scenario: " + key)
            counts = Counter()
            for row in rows:
                if (not isinstance(row, dict) or not isinstance(row.get("id"), str)
                        or not row["id"] or row.get("status") not in
                        {"SUCCESS", "INFO", "WARNING", "FAILURE", "SKIPPED"}):
                    raise ValueError("Invalid official check: " + key)
                if row["status"] == "INFO":
                    continue  # Wire observations are not assertions.
                if row["status"] not in {"SUCCESS", "SKIPPED"}:
                    raise ValueError("Official check did not pass: " + key + "/" + row["id"])
                name = row.get("name")
                if not isinstance(name, str) or not name:
                    raise ValueError("Official check lacks a name: " + key)
                counts[row["id"], name, row["status"]] += 1
            if not any(status == "SUCCESS" for _identifier, _name, status in counts):
                raise ValueError("No assertions executed: " + key)
            scenarios[key] = [dict(id=identifier, name=name, status=status, count=count)
                              for (identifier, name, status), count in sorted(counts.items())]
    if not scenarios:
        raise ValueError("No official core scenarios executed")
    return scenarios


def validate(actual, baseline, harness, mappings):
    if (baseline.get("version") != 1 or baseline.get("protocol") != "2026-07-28"
            or baseline.get("harness") != "@modelcontextprotocol/conformance@" + harness):
        raise ValueError("Official core harness differs from reviewed pin")
    if actual != baseline.get("scenarios"):
        raise ValueError("Official core check inventory changed; review missing/new scenarios or assertions")
    skipped = [(scenario, row["id"], row["name"]) for scenario, rows in actual.items()
               for row in rows if row["status"] == "SKIPPED"]
    if set(skipped) != {tuple(row["check"]) for row in baseline.get("allowed_skips", [])}:
        raise ValueError("Unreviewed official core skip")
    for name, mapping in mappings.items():
        key = mapping["role"] + ":" + mapping["scenario"]
        checks = mapping["checks"]
        passed = {row["id"] for row in actual.get(key, []) if row["status"] == "SUCCESS"}
        if not checks or any(check not in passed for check in checks):
            raise ValueError("Requirement lacks its official assertions: " + name)


def source_identity(register):
    return {"git_commit": subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "source_digest": fingerprint(register)}


def validate_source(before, current):
    if before != current or not before.get("source_digest") or not before.get("git_commit"):
        raise ValueError("Source or checkout changed while official scenarios ran")


def validate_scenario_inventory(actual, current, harness):
    if (current.get("harness") != "@modelcontextprotocol/conformance@" + harness
            or current.get("protocol") != "2026-07-28"):
        raise ValueError("Scenario inventory belongs to another harness or protocol")
    expected = {role + ":" + name for role in ("server", "client")
                for name, versions in current["scenarios"][role].items()
                if "2026-07-28" in versions}
    if set(actual) != expected:
        raise ValueError("Missing/new official scenarios relative to the running harness")


def validate_exploratory(actual, baseline):
    # New harnesses can rename/add/remove assertions. Keep raw outcomes, require
    # all scenarios in their own inventory, and attach no qualified case IDs.
    # inventory() has already rejected failures and warnings.
    keys = {tuple(row["check"]) for row in baseline.get("allowed_skips", [])}
    allowed = Counter()
    for scenario, rows in baseline["scenarios"].items():
        for row in rows:
            key = (scenario, row["id"], row["name"])
            if row["status"] == "SKIPPED" and key in keys:
                allowed[key] += row["count"]
    skipped = Counter()
    for scenario, rows in actual.items():
        for row in rows:
            if row["status"] == "SKIPPED":
                skipped[scenario, row["id"], row["name"]] += row["count"]
    if any(count > allowed[key] for key, count in skipped.items()):
        raise ValueError("Unreviewed exploratory core skip")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path)
    parser.add_argument("--harness", required=True)
    parser.add_argument("--begin", action="store_true", help="Record source identity before running the harness")
    parser.add_argument("--output", type=Path, default=ROOT / "tmp/mcp-core-evidence/results.json")
    args = parser.parse_args(argv)
    try:
        register = load_register()
        identity = source_identity(register)
        stamp = args.results / "source.json"
        if args.begin:
            if stamp.exists():
                raise ValueError("Source identity already exists; use a fresh run directory")
            stamp.write_text(json.dumps(identity, sort_keys=True) + "\n")
            return 0
        validate_source(json.loads(stamp.read_text()), identity)
        actual = inventory(args.results)
        baseline = json.loads(BASELINE.read_text())
        mappings = register.get("conformance_cases", {})
        validate_scenario_inventory(actual, json.loads((args.results / "inventory.json").read_text()), args.harness)
        qualified = baseline["harness"] == "@modelcontextprotocol/conformance@" + args.harness
        if qualified:
            validate(actual, baseline, args.harness, mappings)
        else:
            validate_exploratory(actual, baseline)
        report = {"version": 1, **identity,
            "harness": "@modelcontextprotocol/conformance@" + args.harness,
            "qualification": "reviewed_pin" if qualified else "exploratory_unreviewed_harness",
            "protocol": baseline["protocol"], "scenarios": actual,
            "cases": sorted(mappings) if qualified else [], "raw_sha256": {
                str(path.relative_to(args.results)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in sorted(args.results.rglob("checks.json"))}}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(f"Verified {len(actual)} official core scenarios, "
              f"{sum(row['count'] for rows in actual.values() for row in rows if row['status'] == 'SUCCESS')} assertions; "
              f"{len(report['cases'])} qualified requirement evidence mappings; {report['qualification']}")
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Core conformance evidence incomplete: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
