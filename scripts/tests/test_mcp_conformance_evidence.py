"""A successful process exit cannot hide skipped or missing extension checks."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location(
    "evidence", Path(__file__).resolve().parents[1] / "check_conformance_evidence.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class EvidenceTest(unittest.TestCase):
    def test_missing_new_and_skipped_checks_fail(self):
        text = json.dumps([{"id": "auth-check", "status": "SUCCESS"}], indent=2)
        actual = CHECK.inventory("Harness output\n" + text + "\nSummary")
        baseline = {"execution": copy.deepcopy(actual), "allowed_skips": []}
        CHECK.validate(actual, baseline)
        for status in ["SKIPPED", "FAILURE", "WARNING"]:
            changed = CHECK.inventory(json.dumps([{"id": "auth-check", "status": status}], indent=2))
            with self.subTest(status=status), self.assertRaises(ValueError):
                CHECK.validate(changed, baseline)
        for changed in [{"arrays": 0, "checks": []}, CHECK.inventory(text + "\n" + text)]:
            with self.assertRaises(ValueError):
                CHECK.validate(changed, baseline)

    def test_empty_truncated_and_unknown_results_fail(self):
        for text in ["Process exited 0", "[\n", "[\n]\n", '[\n{"id":"a","status":"NEW"}]']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                CHECK.inventory(text)


if __name__ == "__main__":
    unittest.main()
