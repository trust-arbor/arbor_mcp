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
    example = tooling.get("apps_example")
    if example:
        example_lock = json.loads(local_file(root, example["lock"]).read_text())
        for package, pin in example["packages"].items():
            entry = example_lock.get("packages", {}).get("node_modules/" + package, {})
            if entry.get("version") != pin:
                raise AssuranceError(f"Apps example pin changed without review: {package}")
            reviewed = tooling["packages"].get(package)
            if reviewed and reviewed != pin:
                raise AssuranceError(f"Apps example and peer pins disagree: {package}")
    harness = tooling["packages"]["@modelcontextprotocol/conformance"]
    selectors = re.findall(r"CONFORMANCE_ALPHA_VERSION:-([^}]+)",
                           (root / "scripts/conformance.sh").read_text())
    outcomes = json.loads((root / "scripts/mcp_extension_checks.json").read_text())
    if not selectors or set(selectors) != {harness} or outcomes["harness"] != "@modelcontextprotocol/conformance@" + harness:
        raise AssuranceError("Pinned harness and reviewed check inventory disagree")
    core = root / "scripts/mcp_core_checks.json"
    if core.is_file() and json.loads(core.read_text()).get("harness") != outcomes["harness"]:
        raise AssuranceError("Pinned core harness and reviewed evidence disagree")


def local_file(root, value):
    if not isinstance(value, str) or not value or Path(value).is_absolute():
        raise AssuranceError("Evidence paths must be relative repository files")
    path = (root / value).resolve()
    if not path.is_relative_to(root.resolve()) or not path.is_file():
        raise AssuranceError(f"Missing or unsafe evidence file: {value}")
    return path


def prose_sections(content, depth):
    if depth not in {2, 3, 4}:
        raise AssuranceError("Invalid source section depth")
    stack = []
    names = []
    for match in re.finditer(r"^(#{2,4}) (.+)$", content, re.MULTILINE):
        level, title = len(match[1]), match[2]
        if level > depth:
            continue
        stack = [(n, value) for n, value in stack if n < level]
        stack.append((level, title))
        names.append(" / ".join(value for _level, value in stack))
    return names


def check_extension_sources(data, root, source, field, expected):
    title = source.title()
    if data["sources"].get(source, {}).get("inventory") == "complete" and not data.get(field):
        raise AssuranceError(f"Complete {title} inventory needs its source manifest")
    if not data.get(field):
        return
    manifest = json.loads(local_file(root, data[field]).read_text())
    if (manifest.get("version") != 1 or manifest.get("source") != source or
            manifest.get("revision") != data["sources"][source]["revision"]):
        raise AssuranceError(f"{title} source review differs from its immutable pin")
    if set(manifest.get("files", {})) != expected:
        raise AssuranceError(f"{title} prose and schema both need dispositions")
    identifiers = {row["id"] for row in data["requirements"] if row["source"] == source}
    mapped = set()
    for name, info in manifest["files"].items():
        if not re.fullmatch(r"[0-9a-f]{64}", info.get("sha256", "")):
            raise AssuranceError(f"{title} source needs a content pin")
        content = local_file(root, info.get("local")).read_bytes()
        if hashlib.sha256(content).hexdigest() != info["sha256"]:
            raise AssuranceError(f"{title} source snapshot differs from its content pin")
        prose = name.endswith((".md", ".mdx"))
        entries = info.get("sections" if prose else "exports", {})
        names = (prose_sections(content.decode(), info.get("section_depth", 2)) if prose else
                 re.findall(r"^export (?:interface|type|const) (\w+)", content.decode(), re.MULTILINE))
        if not entries or len(names) != len(set(names)) or set(entries) != set(names):
            raise AssuranceError(f"{title} source needs every section/export disposition")
        for disposition in entries.values():
            references = disposition.get("requirements", []) if isinstance(disposition, dict) else disposition
            if not references or not set(references) <= identifiers:
                raise AssuranceError(f"Invalid {title} source disposition")
            mapped.update(references)
    if mapped != identifiers:
        raise AssuranceError(f"{title} requirement is missing its source disposition")


def load_register(path=REGISTER, root=ROOT):
    data = json.loads(path.read_text())
    if (not isinstance(data, dict) or data.get("version") != 2 or
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
        if not ID.fullmatch(case) or info.get("kind") not in {"contract", "independent_fixture", "interop", "real_provider", "browser"}:
            raise AssuranceError(f"Invalid evidence case: {case}")
        local_file(root, info["file"])
        if not info.get("asserts"):
            raise AssuranceError(f"Evidence needs a stated assertion: {case}")
    conformance = data.get("conformance_cases", {})
    core_path = root / "scripts/mcp_core_checks.json"
    core = json.loads(core_path.read_text())["scenarios"] if conformance else {}
    for case, info in conformance.items():
        if (not ID.fullmatch(case) or case in cases or info.get("role") not in {"server", "client"}
                or not info.get("asserts") or not isinstance(info.get("checks"), list)
                or not info["checks"] or len(info["checks"]) != len(set(info["checks"]))):
            raise AssuranceError(f"Invalid official conformance case: {case}")
        scenario = info["role"] + ":" + info.get("scenario", "")
        passed = {row["id"] for row in core.get(scenario, []) if row["status"] == "SUCCESS"}
        if any(check not in passed for check in info["checks"]):
            raise AssuranceError(f"Unqualified official assertion: {case}")
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
        if row.get("status") not in {"supported", "aggregate", "gap", "host", "not_adopted"}:
            raise AssuranceError(f"Invalid implementation claim: {identifier}")
        if row["status"] in {"supported", "gap", "aggregate"} and not row.get("library_scope"):
            raise AssuranceError(f"Missing library scope: {identifier}")
        if row["status"] in {"host", "not_adopted"} and not row.get("external_duties"):
            raise AssuranceError(f"Missing external disposition: {identifier}")
        for implementation in row.get("implementation", []):
            local_file(root, implementation)
        evidence = row.get("cases", [])
        if len(evidence) != len(set(evidence)) or any(case not in cases for case in evidence):
            raise AssuranceError(f"Unknown or duplicate evidence: {identifier}")
        official = row.get("conformance", [])
        if len(official) != len(set(official)) or any(case not in conformance for case in official):
            raise AssuranceError(f"Unknown or duplicate conformance evidence: {identifier}")
        if row["status"] == "supported" and not row.get("implementation"):
            raise AssuranceError(f"Supported requirement needs code: {identifier}")
    work = data.get("work_items")
    if not isinstance(work, list):
        raise AssuranceError("Missing actionable work inventory")
    work_ids = set()
    pending_evidence = set()
    pending_implementation = set()
    for item in work:
        identifier = item.get("id", "")
        if (not ID.fullmatch(identifier) or identifier in work_ids or
                item.get("kind") not in {"implementation", "qualification", "inventory"} or
                item.get("status") not in {"open", "closed"} or
                not item.get("action") or not item.get("closure") or
                not item.get("requirements") or not set(item["requirements"]) <= seen):
            raise AssuranceError(f"Invalid actionable work item: {identifier}")
        work_ids.add(identifier)
        evidence = item.get("cases", [])
        official = item.get("conformance", [])
        if (any(case not in cases for case in evidence) or
                any(case not in conformance for case in official)):
            raise AssuranceError(f"Unknown work closure evidence: {identifier}")
        related = [row for row in data["requirements"] if row["id"] in item["requirements"]]
        if (not set(evidence) <= {case for row in related for case in row.get("cases", [])} or
                not set(official) <= {case for row in related for case in row.get("conformance", [])}):
            raise AssuranceError(f"Work closure evidence must belong to its bundles: {identifier}")
        if item["status"] == "closed" and not (evidence or official):
            raise AssuranceError(f"Closed work needs executable closure evidence: {identifier}")
        if item["status"] == "open":
            pending_evidence.update(item["requirements"])
            if item["kind"] == "implementation":
                pending_implementation.update(item["requirements"])
    for row in data["requirements"]:
        identifier = row["id"]
        if (row["status"] == "supported" and not (row.get("cases") or row.get("conformance"))
                and identifier not in pending_evidence):
            raise AssuranceError(f"Supported requirement needs executable evidence: {identifier}")
        if row["status"] == "gap" and identifier not in pending_implementation:
            raise AssuranceError(f"Gap needs an open implementation work item: {identifier}")
        dependencies = row.get("depends_on", [])
        if row["status"] == "aggregate" and (not dependencies or
                not set(dependencies) <= seen - {identifier}):
            raise AssuranceError(f"Invalid aggregate dependencies: {identifier}")
    # Aggregate cycles could otherwise hide an unfinished obligation indefinitely.
    rows = {row["id"]: row for row in data["requirements"]}
    def visit(identifier, trail):
        if identifier in trail:
            raise AssuranceError("Cyclic requirement dependencies")
        for dependency in rows[identifier].get("depends_on", []):
            visit(dependency, trail | {identifier})
    for identifier in rows:
        visit(identifier, set())
    referenced = {case for row in data["requirements"] for case in row.get("cases", [])}
    if referenced != set(cases):
        raise AssuranceError("Orphaned evidence cases must be assigned to a requirement")
    if {case for row in data["requirements"] for case in row.get("conformance", [])} != set(conformance):
        raise AssuranceError("Orphaned official cases must be assigned to a requirement")
    if data.get("source_manifest"):
        manifest = json.loads(local_file(root, data["source_manifest"]).read_text())
        if (manifest.get("version") != 1 or manifest.get("core_revision") != data["sources"]["CORE"]["revision"]
                or not isinstance(manifest.get("files"), dict) or not manifest["files"]):
            raise AssuranceError("Core source review differs from its immutable pin")
        core_ids = {row["id"] for row in data["requirements"] if row["source"] == "CORE"}
        mapped = set()
        for name, source in manifest["files"].items():
            if (not name.startswith(("docs/specification/2026-07-28/", "schema/2026-07-28/"))
                    or not re.fullmatch(r"[0-9a-f]{64}", source.get("sha256", ""))
                    or not source.get("requirements") or not set(source["requirements"]) <= core_ids):
                raise AssuranceError("Invalid core source disposition")
            mapped.update(source["requirements"])
        if mapped != core_ids:
            raise AssuranceError("Core requirement is missing its source disposition")
    check_extension_sources(data, root, "TASKS", "tasks_source_manifest", {
        "specification/2026-07-28/tasks.md", "schema/2026-07-28/schema.ts"})
    check_extension_sources(data, root, "APPS", "apps_source_manifest", {
        "specification/2026-01-26/apps.mdx", "src/spec.types.ts"})
    return data


def fingerprint(data, root=ROOT):
    # Include all production and test inputs, including untracked work-in-progress files.
    paths = {"mix.exs", "mix.lock", "scripts/mcp_requirements.json", "scripts/check_mcp_assurance.py"}
    paths.update(str(path.relative_to(root)) for path in (root / "scripts").glob("conformance.sh"))
    paths.update(str(path.relative_to(root)) for pattern in ("mcp_*.json", "check_mcp_*.py")
                 for path in (root / "scripts").glob(pattern))
    paths.update(path for row in data["requirements"] for path in row.get("implementation", []))
    for field in ["tasks_source_manifest", "apps_source_manifest"]:
        if data.get(field):
            manifest = json.loads(local_file(root, data[field]).read_text())
            paths.update(info["local"] for info in manifest["files"].values())
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
             "Use **Remaining library work** below to find known implementation, qualification and",
             "inventory work. **Supported** means the stated library scope has an implementation;",
             "it does not mean every clause in the wider source bundle has an exhaustive test.",
             "External duties and unadopted profiles are separate from library work.", "",
             "This is a reviewed requirement inventory, not a certification. Links identify assertions configured in CI;",
             "only the checkout-bound CI artifact records that they actually passed. Source inventories",
             "marked partial or pending prevent a claim of complete specification coverage.", "",
             "## Remaining library work", ""]
    opened = [item for item in data["work_items"] if item["status"] == "open"]
    if not opened:
        lines.append("No known open library work in this reviewed scope. This is not a claim of exhaustive qualification.")
    for item in opened:
        lines.extend([f"- **{item['id']}** ({item['kind']}): {item['action']}",
                      f"  Closure: {item['closure']} Bundles: {', '.join(item['requirements'])}."])
    lines.extend(["", "## Closed work", "", "| Work | Kind | Closure |", "|---|---|---|"])
    for item in data["work_items"]:
        if item["status"] == "closed":
            evidence = ", ".join(item.get("cases", []) + item.get("conformance", []))
            lines.append(f"| {item['id']} | {item['kind']} | {item['closure']} Evidence: {evidence}. |")
    lines.extend(["", "## Sources", "", "| Source | Pin | Inventory | Scope |", "|---|---|---|---|"])
    for name, source in data["sources"].items():
        lines.append(f"| {name} | [{source['revision'][:12]}]({source['url']}) | {source['inventory']} | {source['scope']} |")
    lines.extend(["", "## Library scopes and evidence", "",
                  "These dispositions replace the old blanket `partial` labels. Named assertions bound",
                  "qualification; a missing implementation is listed as work above. An aggregate inherits",
                  "its constituent dispositions and is not an additional test pass.", "",
                  "| ID / section | Role / profiles | Library support | Source obligation / library scope | Evidence cases | Qualification limits |",
                  "|---|---|---|---|---|---|"])
    for row in data["requirements"]:
        if row["status"] in {"host", "not_adopted"}:
            continue
        evidence = [f"[{case}](https://github.com/trust-arbor/arbor_mcp/blob/master/{data['cases'][case]['file']}) ({data['cases'][case]['kind']})"
                    for case in row.get("cases", [])]
        evidence.extend(f"{case} (official {data['conformance_cases'][case]['role']}: "
                        f"`{data['conformance_cases'][case]['scenario']}`)"
                        for case in row.get("conformance", []))
        cases = ", ".join(evidence) or "None recorded"
        if row["status"] == "aggregate":
            cases = "Inherits: " + ", ".join(row["depends_on"])
        lines.append(f"| {row['id']} / {row['section']} ({row['level']}) | {row['role']} / {', '.join(row['profiles'])} | {row['status']} | {row['requirement']}<br>**Library scope:** {row['library_scope']} | {cases} | {row['notes']} |")
    lines.extend(["", "## External responsibilities", "",
                  "Host responsibilities and unadopted profiles are not library test passes.", "",
                  "| Bundle | Owner | Required integration / policy |", "|---|---|---|"])
    for row in data["requirements"]:
        if row.get("external_duties") and row["status"] != "not_adopted":
            lines.append(f"| {row['id']} | {row['role']} | {row['external_duties']} |")
    lines.extend(["", "## Unadopted profiles", ""])
    for row in data["requirements"]:
        if row["status"] == "not_adopted":
            lines.append(f"- **{row['id']}**: {row['external_duties']}")
    lines.extend(["", "See [the coverage matrix](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/MCP_COVERAGE_MATRIX.md#mcp-extensions) for unadopted MCP extensions.", "",
                  "Independent fixtures are identified separately from third-party implementation interoperability.", ""])
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-docs", action="store_true")
    parser.add_argument("--run", action="store_true", help="Execute every registered ExUnit evidence file")
    parser.add_argument("--kind", action="append", choices=["contract", "independent_fixture", "interop", "real_provider", "browser"],
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
                # Named library contracts may reuse in-process integration tests.
                # The file allowlist remains exact; no live/external tags are enabled.
                command = ["mix", "test", *files, "--include", "integration", "--formatter", "ExUnit.CLIFormatter",
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
