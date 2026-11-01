#!/usr/bin/env python3
"""Validate requirement claims and collect actual, checkout-bound ExUnit evidence.

No network calls and no pin updates. A source review is not a test result.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REGISTER = ROOT / "scripts/mcp_requirements.json"
REPORT = ROOT / "docs/MCP_REQUIREMENTS.md"
ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]+")


class AssuranceError(Exception):
    """Invalid claims or incomplete execution must fail the check."""


def check_peer_pins(root=ROOT):
    tooling = json.loads((root / "scripts/mcp_tooling_baseline.json").read_text())
    lock = json.loads((root / "test/interop/package-lock.json").read_text())
    for package, pin in tooling["packages"].items():
        if package != "@modelcontextprotocol/conformance":
            if lock["packages"]["node_modules/" + package]["version"] != pin:
                raise AssuranceError(f"Peer pin changed without updating reviewed evidence: {package}")
    harness = tooling["packages"]["@modelcontextprotocol/conformance"]
    selectors = re.findall(r"CONFORMANCE_ALPHA_VERSION:-([^}]+)",
                           (root / "scripts/conformance.sh").read_text())
    outcomes = json.loads((root / "scripts/mcp_extension_checks.json").read_text())
    if not selectors or set(selectors) != {harness} or outcomes["harness"] != "@modelcontextprotocol/conformance@" + harness:
        raise AssuranceError("Pinned harness and reviewed check inventory disagree")


def local_file(root, value):
    if not isinstance(value, str) or not value or Path(value).is_absolute():
        raise AssuranceError("Evidence paths must be relative repository files")
    path = (root / value).resolve()
    if not path.is_relative_to(root.resolve()) or not path.is_file():
        raise AssuranceError(f"Missing or unsafe evidence file: {value}")
    return path


def load_register(path=REGISTER, root=ROOT):
    data = json.loads(path.read_text())
    if (not isinstance(data, dict) or data.get("version") != 1 or
            not isinstance(data.get("sources"), dict) or not data["sources"] or
            not isinstance(data.get("requirements"), list) or not data["requirements"]):
        raise AssuranceError("Invalid requirement register")
    for source in data["sources"].values():
        if (not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", source.get("revision", "")) or
                not source.get("url", "").startswith("https://") or
                source.get("inventory") not in {"complete", "partial", "pending"}):
            raise AssuranceError("Each source needs an immutable pin and inventory scope")
    cases = data.get("cases", {})
    for case, info in cases.items():
        if not ID.fullmatch(case) or info.get("kind") not in {"contract", "independent_fixture", "interop"}:
            raise AssuranceError(f"Invalid evidence case: {case}")
        local_file(root, info["file"])
        if not info.get("asserts"):
            raise AssuranceError(f"Evidence needs a stated assertion: {case}")
    seen = set()
    for row in data["requirements"]:
        identifier = row.get("id", "")
        if not ID.fullmatch(identifier) or identifier in seen:
            raise AssuranceError(f"Duplicate or invalid requirement: {identifier}")
        seen.add(identifier)
        if row.get("source") not in data["sources"]:
            raise AssuranceError(f"Unpinned requirement source: {identifier}")
        for field in ["section", "role", "profiles", "level", "requirement", "notes"]:
            if not row.get(field):
                raise AssuranceError(f"Missing {field}: {identifier}")
        if row.get("level") not in {"MUST", "SHOULD", "MAY", "MUST/SHOULD", "profile", "inherited", "policy"}:
            raise AssuranceError(f"Invalid obligation level: {identifier}")
        if row.get("status") not in {"implemented", "partial", "gap", "host", "not_adopted"}:
            raise AssuranceError(f"Invalid implementation claim: {identifier}")
        for implementation in row.get("implementation", []):
            local_file(root, implementation)
        evidence = row.get("cases", [])
        if len(evidence) != len(set(evidence)) or any(case not in cases for case in evidence):
            raise AssuranceError(f"Unknown or duplicate evidence: {identifier}")
        if row["status"] == "implemented" and (not evidence or not row.get("implementation")):
            raise AssuranceError(f"Implemented requirement needs code and executable evidence: {identifier}")
    referenced = {case for row in data["requirements"] for case in row.get("cases", [])}
    if referenced != set(cases):
        raise AssuranceError("Orphaned evidence cases must be assigned to a requirement")
    return data


def fingerprint(data, root=ROOT):
    # Include all production and test inputs, including untracked work-in-progress files.
    paths = {"mix.exs", "mix.lock", "scripts/mcp_requirements.json", "scripts/check_mcp_assurance.py"}
    for directory in ["lib", "dev", "test", "config"]:
        paths.update(str(path.relative_to(root)) for path in (root / directory).rglob("*")
                     if path.is_file() and "node_modules" not in path.parts)
    digest = hashlib.sha256()
    for name in sorted(paths):
        path = local_file(root, name)
        digest.update(name.encode() + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def validate_results(data, report, expected_digest, required_cases=None, expected_commit=None):
    if report.get("source_digest") != expected_digest:
        raise AssuranceError("Evidence was collected from different source inputs")
    if expected_commit is not None and report.get("git_commit") != expected_commit:
        raise AssuranceError("Evidence was collected from a different checkout commit")
    found = {}
    for test in report.get("tests", []):
        if test.get("state") != "passed":
            raise AssuranceError(f"Failed, excluded or skipped test: {test.get('name')}")
        if not isinstance(test.get("cases"), list):
            raise AssuranceError("Invalid test evidence labels")
        for case in test["cases"]:
            if case not in data["cases"] or case in found:
                raise AssuranceError(f"Unknown or duplicate executed case: {case}")
            if test["file"] != data["cases"][case]["file"]:
                raise AssuranceError(f"Evidence case ran in an unexpected file: {case}")
            found[case] = test
    missing = set(data["cases"] if required_cases is None else required_cases) - found.keys()
    if missing:
        raise AssuranceError("Evidence cases did not execute: " + ", ".join(sorted(missing)))
    return found


def markdown(data):
    lines = ["# MCP requirement evidence", "", "Generated by `python3 scripts/check_mcp_assurance.py --write-docs`.", "",
             "This is a reviewed requirement inventory, not a certification. Implementation status",
             "and executable evidence are separate. Links identify assertions configured in CI;",
             "only the checkout-bound CI artifact records that they actually passed. Source inventories",
             "marked partial or pending prevent a claim of complete specification coverage.", "",
             "## Sources", "", "| Source | Pin | Inventory | Scope |", "|---|---|---|---|"]
    for name, source in data["sources"].items():
        lines.append(f"| {name} | [{source['revision'][:12]}]({source['url']}) | {source['inventory']} | {source['scope']} |")
    lines.extend(["", "## Requirements", "", "| ID / section | Role / profiles | Status | Evidence cases | Limits / responsibility |",
                  "|---|---|---|---|---|"])
    for row in data["requirements"]:
        cases = ", ".join(f"[{case}](https://github.com/trust-arbor/arbor_mcp/blob/master/{data['cases'][case]['file']}) ({data['cases'][case]['kind']})"
                          for case in row.get("cases", [])) or "None recorded"
        lines.append(f"| {row['id']} / {row['section']} ({row['level']}) | {row['role']} / {', '.join(row['profiles'])} | {row['status']} | {cases} | {row['requirement']} {row['notes']} |")
    lines.extend(["", "Host responsibilities and unadopted profiles are not library test passes.",
                  "Independent fixtures are identified separately from third-party implementation interoperability.", ""])
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-docs", action="store_true")
    parser.add_argument("--run", action="store_true", help="Execute every registered ExUnit evidence file")
    parser.add_argument("--kind", action="append", choices=["contract", "independent_fixture", "interop"],
                        help="Evidence kinds to execute/validate (default: contract)")
    parser.add_argument("--results", type=Path, help="Validate a previous checkout-bound execution artifact")
    parser.add_argument("--output", type=Path, default=ROOT / "tmp/mcp-assurance/results.json")
    args = parser.parse_args(argv)
    try:
        data = load_register()
        check_peer_pins()
        expected = markdown(data)
        if args.write_docs:
            REPORT.write_text(expected)
        elif not REPORT.is_file() or REPORT.read_text() != expected:
            raise AssuranceError("Generated requirement report is stale; run --write-docs")
        selected = dict(data, cases={case: info for case, info in data["cases"].items()
                                    if info["kind"] in (args.kind or ["contract"])})
        if args.run:
            target = args.output.resolve()
            if target.is_relative_to(ROOT) and not any(
                    target.is_relative_to(ROOT / directory) for directory in ["tmp", "_build"]):
                raise AssuranceError("Execution output inside the repository must be under tmp/ or _build/")
            before = fingerprint(data)
            before_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.unlink(missing_ok=True)
            with tempfile.TemporaryDirectory(prefix="mcp-assurance-") as temporary:
                raw = Path(temporary) / "results.json"
                env = dict(os.environ, MCP_ASSURANCE_RESULTS=str(raw), MIX_ENV="test")
                files = sorted({case["file"] for case in selected["cases"].values()})
                if not files:
                    raise AssuranceError("No executable evidence configured")
                command = ["mix", "test", *files, "--formatter", "ExUnit.CLIFormatter",
                           "--formatter", "Arbor.MCP.AssuranceFormatter"]
                if any(info["kind"] != "contract" for info in selected["cases"].values()):
                    command += ["--include", "interop"]
                result = subprocess.run(command, cwd=ROOT, env=env, check=False)
                if result.returncode or not raw.is_file():
                    raise AssuranceError("Requirement tests failed or produced no execution report")
                report = json.loads(raw.read_text())
            report["source_digest"] = before
            report["git_commit"] = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
            if fingerprint(data) != before:
                raise AssuranceError("Source changed while collecting evidence")
            report["kinds"] = sorted(set(args.kind or ["contract"]))
            validate_results(data, report, before, selected["cases"], before_commit)
            args.output.write_text(json.dumps(report, indent=2) + "\n")
        if args.results:
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
            validate_results(data, json.loads(args.results.read_text()), fingerprint(data), selected["cases"], commit)
        print(f"Validated {len(data['requirements'])} requirements and {len(data['cases'])} evidence definitions")
        return 0
    except (AssuranceError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"MCP assurance check failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
