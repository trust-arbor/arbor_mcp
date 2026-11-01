#!/usr/bin/env python3
"""Require every pinned extension check to execute; reject new skips or warnings."""
from collections import Counter
import argparse
import json
from pathlib import Path
import re
import sys

BASELINE = Path(__file__).with_name("mcp_extension_checks.json")


def inventory(text):
    decoder = json.JSONDecoder()
    checks = Counter()
    arrays = 0
    for start in re.finditer(r"(?m)^\[\s*$", text):
        try:
            rows, _end = decoder.raw_decode(text[start.start():])
        except ValueError as error:
            raise ValueError("Incomplete conformance JSON result array") from error
        if not isinstance(rows, list) or not rows:
            raise ValueError("Empty conformance execution result")
        arrays += 1
        for row in rows:
            if (not isinstance(row, dict) or not isinstance(row.get("id"), str) or
                    row.get("status") not in {"SUCCESS", "SKIPPED", "FAILURE", "WARNING", "INFO"}):
                raise ValueError("Invalid conformance check result")
            if row["status"] == "INFO":
                continue  # Harness wire traces are observations, not passing assertions.
            checks[row["id"], row["status"]] += 1
    if not arrays:
        raise ValueError("No conformance checks executed")
    return {"arrays": arrays, "checks": [
        {"id": identifier, "status": status, "count": count}
        for (identifier, status), count in sorted(checks.items())]}


def validate(actual, baseline):
    if actual != baseline["execution"]:
        raise ValueError("Extension check inventory changed: missing/new checks, failures, warnings or skips require review")
    skipped = [row["id"] for row in actual["checks"] if row["status"] == "SKIPPED"]
    if set(skipped) != set(baseline["allowed_skips"]):
        raise ValueError("Unreviewed extension check skip")
    if any(row["status"] not in {"SUCCESS", "SKIPPED"} for row in actual["checks"]):
        raise ValueError("Extension checks failed or warned")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path)
    args = parser.parse_args(argv)
    try:
        baseline = json.loads(BASELINE.read_text())
        actual = inventory(args.results.read_text())
        validate(actual, baseline)
        print(f"Verified {sum(row['count'] for row in actual['checks'])} extension check outcomes; no unreviewed skips")
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Conformance evidence incomplete: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
