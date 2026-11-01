"""Protect against false coverage claims and incomplete execution artifacts."""
import copy
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
            "version": 1,
            "sources": {"spec": {"url": "https://example.test/spec", "revision": "a" * 40,
                                  "inventory": "partial", "scope": "client"}},
            "cases": {"case.pass": {"file": "case.exs", "kind": "contract", "asserts": "reject wrong audience"}},
            "requirements": [{"id": "SPEC.AUD", "source": "spec", "section": "3", "role": "client",
                              "profiles": ["JWT"], "level": "MUST", "requirement": "bind audience",
                              "status": "implemented", "implementation": ["case.exs"],
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
        row.update(status="host", implementation=[], cases=[])
        self.data["cases"] = {}
        self.load(self.data)
        rendered = CHECK.markdown(self.data)
        self.assertIn("None recorded", rendered)
        self.assertIn("partial", rendered)
        self.assertIn("Host responsibilities", rendered)


if __name__ == "__main__":
    unittest.main()
