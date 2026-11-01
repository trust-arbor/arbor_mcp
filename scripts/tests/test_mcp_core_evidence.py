"""An official harness success summary cannot conceal missing core assertions."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
SPEC = importlib.util.spec_from_file_location(
    "core_evidence", Path(__file__).resolve().parents[1] / "check_mcp_core_evidence.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class CoreEvidenceTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.path = self.root / "client/auth/example-2026-11-01T19-00-00-000Z/checks.json"
        self.path.parent.mkdir(parents=True)
        self.rows = [{"id": "check", "name": "Specific assertion", "status": "SUCCESS"}]
        self.write()
        self.actual = CHECK.inventory(self.root)
        self.baseline = {"version": 1, "protocol": "2026-07-28",
                         "harness": "@modelcontextprotocol/conformance@0.2.0-alpha.12",
                         "scenarios": copy.deepcopy(self.actual), "allowed_skips": []}
        self.mapping = {"official.example": {"role": "client", "scenario": "auth/example", "checks": ["check"]}}

    def write(self):
        self.path.write_text(json.dumps(self.rows))

    def validate(self, actual=None, mapping=None):
        CHECK.validate(self.actual if actual is None else actual, self.baseline,
                       "0.2.0-alpha.12", self.mapping if mapping is None else mapping)

    def test_actual_official_scenario_is_required(self):
        self.validate()
        self.assertIn("client:auth/example", self.actual)
        with self.assertRaisesRegex(ValueError, "inventory changed"):
            self.validate({})

    def test_duplicate_or_moved_scenario_cannot_fill_a_missing_one(self):
        other = self.path.parent.with_name("example-2026-11-01T19-00-01-000Z")
        other.mkdir()
        (other / "checks.json").write_text(self.path.read_text())
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            CHECK.inventory(self.root)

    def test_named_assertions_cannot_be_replaced_under_the_same_id(self):
        for key, value in [("name", "Different assertion"), ("id", "different"), ("status", "SKIPPED")]:
            with self.subTest(key=key):
                self.rows = [{"id": "check", "name": "Specific assertion", "status": "SUCCESS"}]
                self.rows[0][key] = value
                # Retain a passing check so a new skip reaches inventory validation.
                self.rows.append({"id": "other", "name": "Other", "status": "SUCCESS"})
                self.write()
                with self.assertRaises(ValueError):
                    self.validate(CHECK.inventory(self.root))

    def test_failures_warnings_unknown_states_and_empty_results_fail(self):
        for status in ["FAILURE", "WARNING", "UNKNOWN", "INFO", "SKIPPED"]:
            with self.subTest(status=status):
                self.rows[0]["status"] = status
                self.write()
                with self.assertRaises(ValueError):
                    CHECK.inventory(self.root)
        for value in [[], {}, [{"status": "SUCCESS"}]]:
            self.path.write_text(json.dumps(value))
            with self.assertRaises(ValueError):
                CHECK.inventory(self.root)

    def test_wire_observations_do_not_add_assertions(self):
        self.rows.append({"id": "wire", "name": "trace", "status": "INFO"})
        self.write()
        self.assertEqual(CHECK.inventory(self.root), self.actual)

    def test_only_explicit_named_profile_skips_are_allowed_and_never_evidence(self):
        self.rows.append({"id": "legacy", "name": "Initialize", "status": "SKIPPED"})
        self.write()
        actual = CHECK.inventory(self.root)
        self.baseline["scenarios"] = actual
        with self.assertRaisesRegex(ValueError, "Unreviewed"):
            self.validate(actual)
        self.baseline["allowed_skips"] = [{"check": ["client:auth/example", "legacy", "Initialize"],
                                           "reason": "Legacy-only operation"}]
        self.validate(actual)
        with self.assertRaisesRegex(ValueError, "lacks"):
            self.validate(actual, {"bad": {"role": "client", "scenario": "auth/example", "checks": ["legacy"]}})

    def test_harness_or_check_count_change_requires_review(self):
        self.baseline["harness"] = "@modelcontextprotocol/conformance@new"
        with self.assertRaisesRegex(ValueError, "pin"):
            self.validate()
        self.baseline["harness"] = "@modelcontextprotocol/conformance@0.2.0-alpha.12"
        self.rows *= 2
        self.write()
        with self.assertRaisesRegex(ValueError, "inventory changed"):
            self.validate(CHECK.inventory(self.root))

    def test_source_and_commit_cannot_change_during_a_run(self):
        before = {"git_commit": "a" * 40, "source_digest": "digest"}
        CHECK.validate_source(before, dict(before))
        for value in [{}, dict(before, git_commit="b" * 40), dict(before, source_digest="changed")]:
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "changed"):
                CHECK.validate_source(before, value)

    def test_new_harness_scenarios_execute_without_becoming_pinned_qualification(self):
        current = {"harness": "@modelcontextprotocol/conformance@0.3.0",
                   "protocol": "2026-07-28", "scenarios": {
                       "server": {}, "client": {"auth/example": ["2026-07-28"],
                                                 "new-scenario": ["2026-07-28"]}}}
        with self.assertRaisesRegex(ValueError, "running harness"):
            CHECK.validate_scenario_inventory(self.actual, current, "0.3.0")
        actual = dict(self.actual, **{"client:new-scenario": [
            {"id": "new-check", "name": "New", "status": "SUCCESS", "count": 1}]})
        CHECK.validate_scenario_inventory(actual, current, "0.3.0")
        CHECK.validate_exploratory(actual, self.baseline)
        with self.assertRaisesRegex(ValueError, "pin"):
            CHECK.validate(actual, self.baseline, "0.3.0", self.mapping)
        actual["client:new-scenario"][0]["status"] = "SKIPPED"
        with self.assertRaisesRegex(ValueError, "skip"):
            CHECK.validate_exploratory(actual, self.baseline)

    def test_new_harness_cannot_repeat_a_reviewed_skip(self):
        skip = {"id": "legacy", "name": "Initialize", "status": "SKIPPED", "count": 1}
        self.baseline["scenarios"]["client:auth/example"].append(skip)
        self.baseline["allowed_skips"] = [{"check": ["client:auth/example", "legacy", "Initialize"]}]
        actual = copy.deepcopy(self.baseline["scenarios"])
        CHECK.validate_exploratory(actual, self.baseline)
        actual["client:auth/example"][-1]["count"] = 2
        with self.assertRaisesRegex(ValueError, "skip"):
            CHECK.validate_exploratory(actual, self.baseline)


if __name__ == "__main__":
    unittest.main()
