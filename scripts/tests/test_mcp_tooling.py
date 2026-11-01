"""Unknown new scenarios and incomplete upstream inventories cannot look clean."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "tooling", Path(__file__).resolve().parents[1] / "check_mcp_tooling.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class ToolingTest(unittest.TestCase):
    def setUp(self):
        self.inventory = {role: {"scenario": ["2026-07-28"]} for role in CHECK.HEADINGS.values()}
        self.baseline = {"packages": {"@modelcontextprotocol/client": "2.4.0"},
                         "scenarios": copy.deepcopy(self.inventory)}
        self.releases = {"@modelcontextprotocol/client": {"versions": ["2.4.0"],
                        "time": {"2.4.0": "2026-10-25T00:00:00Z"}}}

    def compare(self):
        return CHECK.compare(self.baseline, self.releases, self.inventory, "0.2.0-alpha.12")

    def test_new_removed_and_retargeted_scenarios_require_review(self):
        self.inventory["client"]["new-extension"] = ["2026-07-28"]
        del self.inventory["server"]["scenario"]
        self.inventory["authorization"]["scenario"] = ["2027-01-01"]
        report = self.compare()
        self.assertTrue(report["needs_review"])
        self.assertEqual(len(report["scenario_changes"]), 3)
        self.assertEqual(report["review_key"], self.compare()["review_key"])

    def test_sdk_release_drift_does_not_advance_pins(self):
        release = self.releases["@modelcontextprotocol/client"]
        release["versions"].append("2.5.0")
        release["time"]["2.5.0"] = "2026-11-01T00:00:00Z"
        self.assertTrue(self.compare()["needs_review"])
        self.assertEqual(self.baseline["packages"]["@modelcontextprotocol/client"], "2.4.0")

    def test_incomplete_or_duplicate_cli_inventory_is_rejected(self):
        complete = "\n".join(f"{heading}\n  - scenario [2026-07-28]" for heading in CHECK.HEADINGS)
        self.assertEqual(CHECK.scenarios(complete), self.inventory)
        for broken in ["", complete.split("Client scenarios")[0], complete + "\nunknown format",
                       complete + "\n  - scenario [2026-07-28]"]:
            with self.subTest(broken=broken), self.assertRaises(CHECK.ToolingError):
                CHECK.scenarios(broken)

    def test_empty_registry_response_is_an_error(self):
        self.releases["@modelcontextprotocol/client"]["versions"] = []
        with self.assertRaises(CHECK.ToolingError):
            self.compare()

    def test_calendar_versions_from_an_older_generation_are_not_newer_releases(self):
        release = self.releases["@modelcontextprotocol/client"]
        release["versions"].append("2026.8.31")
        release["time"]["2026.8.31"] = "2026-08-31T00:00:00Z"
        self.assertFalse(self.compare()["needs_review"])
        with patch.object(CHECK, "command", return_value=json.dumps(release)):
            self.assertEqual(CHECK.newest_harness(), "2.4.0")

    def test_missing_publication_times_cannot_look_unchanged(self):
        self.releases["@modelcontextprotocol/client"]["time"] = {}
        with self.assertRaises(CHECK.ToolingError):
            self.compare()

    def test_review_ids_survive_additional_unrelated_release_observations(self):
        release = self.releases["@modelcontextprotocol/client"]
        release["versions"].append("2.5.0")
        release["time"]["2.5.0"] = "2026-11-01T00:00:00Z"
        first = self.compare()["release_changes"][0]
        reviews = {first["review_key"]: {"id": "UPSTREAM-1", "status": "open"}}
        release["versions"].append("2.6.0")
        release["time"]["2.6.0"] = "2026-11-02T00:00:00Z"
        report = CHECK.compare(self.baseline, self.releases, self.inventory, "0.2.0-alpha.12", reviews)
        self.assertEqual(report["release_changes"][0]["tracking_id"], "UPSTREAM-1")
        self.assertEqual(report["release_changes"][0]["review_key"], first["review_key"])
        self.assertIsNone(report["release_changes"][1]["tracking_id"])
        self.assertTrue(report["needs_review"])


if __name__ == "__main__":
    unittest.main()
