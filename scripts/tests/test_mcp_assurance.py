"""Protect against false coverage claims and incomplete execution artifacts."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "assurance", Path(__file__).resolve().parents[1] / "check_mcp_assurance.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class AssuranceTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "case.exs").write_text("test input")
        self.data = {
            "version": 2,
            "work_items": [],
            "sources": {"spec": {"url": "https://example.test/spec", "revision": "a" * 40,
                                  "inventory": "partial", "scope": "client"}},
            "cases": {"case.pass": {"file": "case.exs", "kind": "contract", "asserts": "reject wrong audience"}},
            "requirements": [{"id": "SPEC.AUD", "source": "spec", "section": "3", "role": "client",
                              "profiles": ["JWT"], "level": "MUST", "requirement": "bind audience",
                              "status": "supported", "library_scope": "bind audience", "external_duties": "", "implementation": ["case.exs"],
                              "cases": ["case.pass"], "notes": "client scope"}]}
        self.report = {"source_digest": "digest", "tests": [
            {"file": "case.exs", "name": "test audience", "cases": ["case.pass"], "state": "passed"}]}

    def load(self, data):
        path = self.root / "register.json"
        path.write_text(json.dumps(data))
        return CHECK.load_register(path, self.root)

    def test_actual_execution_accepts_all_expected_cases(self):
        self.load(self.data)
        self.assertEqual(set(CHECK.validate_results(self.data, self.report, "digest")), {"case.pass"})

    def test_blanket_partial_and_unscoped_support_are_rejected(self):
        for mutation in [{"status": "partial"}, {"library_scope": ""}]:
            data = copy.deepcopy(self.data)
            data["requirements"][0].update(mutation)
            with self.subTest(mutation=mutation), self.assertRaises(CHECK.AssuranceError):
                self.load(data)

    def test_work_has_actionable_closure_and_cannot_close_without_evidence(self):
        item = {"id": "WORK.AUD", "kind": "implementation", "status": "open",
                "requirements": ["SPEC.AUD"], "action": "Reject wrong audiences",
                "closure": "Signed wrong-audience input fails before token use"}
        self.data["work_items"] = [item]
        self.data["requirements"][0]["status"] = "gap"
        self.load(self.data)
        for field, value in [("requirements", ["UNKNOWN"]), ("closure", ""), ("status", "closed")]:
            data = copy.deepcopy(self.data)
            data["work_items"][0][field] = value
            with self.subTest(field=field), self.assertRaises(CHECK.AssuranceError):
                self.load(data)
        self.data["requirements"][0]["status"] = "supported"
        item.update(status="closed", cases=["case.pass"])
        self.load(self.data)
        rendered = CHECK.markdown(self.data)
        self.assertIn("No known open library work", rendered)
        self.assertIn("Signed wrong-audience input", rendered)

    def test_gap_cannot_disappear_into_a_note_or_an_aggregate_cycle(self):
        self.data["requirements"][0]["status"] = "gap"
        with self.assertRaisesRegex(CHECK.AssuranceError, "open implementation"):
            self.load(self.data)
        row = self.data["requirements"][0]
        row.update(status="aggregate", depends_on=["SPEC.OTHER"])
        self.data["requirements"].append(dict(row, id="SPEC.OTHER", depends_on=["SPEC.AUD"]))
        with self.assertRaisesRegex(CHECK.AssuranceError, "Cyclic"):
            self.load(self.data)

    def test_tasks_inventory_requires_both_pinned_snapshots_and_every_section_and_export(self):
        self.data["sources"]["TASKS"] = self.data["sources"].pop("spec")
        self.data["requirements"][0]["source"] = "TASKS"
        manifest = {"version": 1, "source": "TASKS", "revision": "a" * 40, "files": {}}
        for remote, name, content, dispositions in [
            ("specification/2026-07-28/tasks.md", "tasks.md", "## Lifecycle\n",
             {"sections": {"Lifecycle": {"requirements": ["SPEC.AUD"]}}}),
            ("schema/2026-07-28/schema.ts", "tasks.ts", "export type Task = unknown;\n",
             {"exports": {"Task": ["SPEC.AUD"]}})
        ]:
            (self.root / name).write_text(content)
            manifest["files"][remote] = dict(dispositions, local=name,
                                              sha256=hashlib.sha256(content.encode()).hexdigest())
        path = self.root / "tasks-manifest.json"
        path.write_text(json.dumps(manifest))
        self.data["tasks_source_manifest"] = path.name
        self.load(self.data)
        schema = "schema/2026-07-28/schema.ts"
        for mutation in ["pin", "file", "export", "section", "reference", "content"]:
            broken = copy.deepcopy(manifest)
            if mutation == "pin":
                broken["revision"] = "b" * 40
            elif mutation == "file":
                del broken["files"][schema]
            elif mutation == "export":
                broken["files"][schema]["exports"] = {}
            elif mutation == "section":
                broken["files"]["specification/2026-07-28/tasks.md"]["sections"] = {}
            elif mutation == "reference":
                broken["files"][schema]["exports"]["Task"] = ["UNKNOWN"]
            else:
                (self.root / "tasks.ts").write_text("changed source")
            path.write_text(json.dumps(broken))
            with self.subTest(mutation=mutation), self.assertRaises(CHECK.AssuranceError):
                self.load(self.data)

    def test_missing_or_wrong_commit_identity_cannot_qualify_an_artifact(self):
        for value in [None, "b" * 40]:
            report = dict(self.report)
            if value is not None:
                report["git_commit"] = value
            with self.subTest(commit=value), self.assertRaisesRegex(CHECK.AssuranceError, "checkout commit"):
                CHECK.validate_results(self.data, report, "digest", expected_commit="a" * 40)
        self.report["git_commit"] = "a" * 40
        CHECK.validate_results(self.data, self.report, "digest", expected_commit="a" * 40)

    def test_missing_skipped_failed_duplicate_and_unknown_cases_fail(self):
        reports = []
        missing = copy.deepcopy(self.report)
        missing["tests"] = []
        reports.append(missing)
        for state in ["skipped", "failed", "excluded"]:
            report = copy.deepcopy(self.report)
            report["tests"][0]["state"] = state
            reports.append(report)
        duplicate = copy.deepcopy(self.report)
        duplicate["tests"] *= 2
        reports.append(duplicate)
        unknown = copy.deepcopy(self.report)
        unknown["tests"][0]["cases"] = ["unknown"]
        reports.append(unknown)
        for report in reports:
            with self.subTest(report=report), self.assertRaises(CHECK.AssuranceError):
                CHECK.validate_results(self.data, report, "digest")

    def test_evidence_cannot_move_to_an_unrelated_test_or_checkout(self):
        with self.assertRaisesRegex(CHECK.AssuranceError, "different source"):
            CHECK.validate_results(self.data, self.report, "new-digest")
        self.report["tests"][0]["file"] = "unrelated.exs"
        with self.assertRaisesRegex(CHECK.AssuranceError, "unexpected file"):
            CHECK.validate_results(self.data, self.report, "digest")

    def test_selected_kind_can_share_a_file_with_other_known_evidence(self):
        self.data["cases"]["other.case"] = dict(self.data["cases"]["case.pass"], kind="interop")
        self.report["tests"].append(dict(self.report["tests"][0], cases=["other.case"]))
        CHECK.validate_results(self.data, self.report, "digest", ["case.pass"])
        self.report["tests"][1]["cases"] = ["unknown.case"]
        with self.assertRaises(CHECK.AssuranceError):
            CHECK.validate_results(self.data, self.report, "digest", ["case.pass"])

    def test_peer_or_harness_pin_changes_require_reviewed_evidence_updates(self):
        (self.root / "scripts").mkdir()
        (self.root / "test/interop").mkdir(parents=True)
        pins = {"packages": {"@modelcontextprotocol/client": "2.4.0", "@modelcontextprotocol/conformance": "0.2.0-alpha.12"}}
        (self.root / "scripts/mcp_tooling_baseline.json").write_text(json.dumps(pins))
        lock = {"packages": {"node_modules/@modelcontextprotocol/client": {"version": "2.4.0"}}}
        path = self.root / "test/interop/package-lock.json"
        path.write_text(json.dumps(lock))
        script = self.root / "scripts/conformance.sh"
        script.write_text('${CONFORMANCE_ALPHA_VERSION:-0.2.0-alpha.12}')
        (self.root / "scripts/mcp_extension_checks.json").write_text(json.dumps({"harness": "@modelcontextprotocol/conformance@0.2.0-alpha.12"}))
        CHECK.check_peer_pins(self.root)
        lock["packages"]["node_modules/@modelcontextprotocol/client"]["version"] = "2.5.0"
        path.write_text(json.dumps(lock))
        with self.assertRaises(CHECK.AssuranceError):
            CHECK.check_peer_pins(self.root)
        lock["packages"]["node_modules/@modelcontextprotocol/client"]["version"] = "2.4.0"
        path.write_text(json.dumps(lock))
        script.write_text('${CONFORMANCE_ALPHA_VERSION:-0.2.0-alpha.13}')
        with self.assertRaises(CHECK.AssuranceError):
            CHECK.check_peer_pins(self.root)

    def test_implemented_claim_requires_code_and_executable_evidence(self):
        for field in ["implementation", "cases"]:
            data = copy.deepcopy(self.data)
            data["requirements"][0][field] = []
            with self.subTest(field=field), self.assertRaises(CHECK.AssuranceError):
                self.load(data)

    def test_duplicate_requirements_and_unpinned_sources_fail(self):
        data = copy.deepcopy(self.data)
        data["requirements"] *= 2
        with self.assertRaises(CHECK.AssuranceError):
            self.load(data)
        self.data["sources"]["spec"]["revision"] = "main"
        with self.assertRaises(CHECK.AssuranceError):
            self.load(self.data)

    def test_missing_and_escaping_paths_fail(self):
        for path in ["missing.exs", "../outside.exs", str(self.root / "case.exs")]:
            self.data["cases"]["case.pass"]["file"] = path
            with self.subTest(path=path), self.assertRaises(CHECK.AssuranceError):
                self.load(self.data)

    def test_host_responsibilities_do_not_become_implementation_passes(self):
        row = self.data["requirements"][0]
        row.update(status="host", implementation=[], cases=[], external_duties="host trust policy")
        self.data["cases"] = {}
        self.load(self.data)
        rendered = CHECK.markdown(self.data)
        self.assertIn("host trust policy", rendered)
        self.assertIn("partial", rendered)
        self.assertIn("Host responsibilities", rendered)

    def test_implemented_claim_cannot_use_a_skipped_or_unmapped_official_check(self):
        (self.root / "scripts").mkdir()
        baseline = self.root / "scripts/mcp_core_checks.json"
        rows = [{"id": "official-check", "status": "SUCCESS"}]
        baseline.write_text(json.dumps({"scenarios": {"server:example": rows}}))
        self.data["cases"] = {}
        self.data["conformance_cases"] = {"official.case": {
            "role": "server", "scenario": "example", "checks": ["official-check"],
            "asserts": "Official wire behavior"}}
        row = self.data["requirements"][0]
        row.update(cases=[], conformance=["official.case"])
        self.load(self.data)
        rows[0]["status"] = "SKIPPED"
        baseline.write_text(json.dumps({"scenarios": {"server:example": rows}}))
        with self.assertRaisesRegex(CHECK.AssuranceError, "Unqualified"):
            self.load(self.data)
        self.data["conformance_cases"]["official.case"]["scenario"] = "unexecuted"
        with self.assertRaises(CHECK.AssuranceError):
            self.load(self.data)

    def test_source_review_cannot_omit_requirements_or_change_the_source_pin(self):
        self.data["sources"]["CORE"] = self.data["sources"].pop("spec")
        self.data["requirements"][0]["source"] = "CORE"
        self.data["source_manifest"] = "manifest.json"
        manifest = {"version": 1, "core_revision": "a" * 40, "files": {
            "docs/specification/2026-07-28/basic/index.mdx": {
                "sha256": "b" * 64, "requirements": ["SPEC.AUD"]}}}
        path = self.root / "manifest.json"
        path.write_text(json.dumps(manifest))
        self.load(self.data)
        for value in [dict(manifest, core_revision="c" * 40), dict(manifest, files={})]:
            path.write_text(json.dumps(value))
            with self.assertRaises(CHECK.AssuranceError):
                self.load(self.data)

    def test_registered_schema_outside_standard_directories_binds_execution(self):
        for name in ["mix.exs", "mix.lock", "scripts/mcp_requirements.json", "scripts/check_mcp_assurance.py"]:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("source")
        schema = self.root / "docs/pinned-schema.json"
        schema.parent.mkdir()
        schema.write_text('{"type":"object"}')
        self.data["requirements"][0]["implementation"].append("docs/pinned-schema.json")
        before = CHECK.fingerprint(self.data, self.root)
        schema.write_text('{"type":"string"}')
        self.assertNotEqual(before, CHECK.fingerprint(self.data, self.root))


if __name__ == "__main__":
    unittest.main()
