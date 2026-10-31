"""Offline regressions for complete discovery and immutable extension comparisons."""
import importlib.util
from http.client import IncompleteRead
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch


SPEC = importlib.util.spec_from_file_location(
    "extension_check", Path(__file__).resolve().parents[1] / "check_mcp_extensions.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)
OLD, NEW = "a" * 40, "b" * 40
CATALOG, TASKS = CHECK.CATALOG, "modelcontextprotocol/ext-tasks"


def entry(revision=OLD, status="reviewed"):
    return {"revision": revision, "review_status": status}


class FakeGitHub:
    def __init__(self, repositories, files):
        self.discovered = repositories
        self.contents = files

    def repositories(self):
        return {name: {"branch": "main", "archived": False} for name in self.discovered}

    def head(self, repository, branch):
        return NEW

    def files(self, repository, revision):
        return self.contents[repository, revision]


class ExtensionCheckTest(unittest.TestCase):
    def test_added_modified_and_removed_files_use_pinned_revisions(self):
        client = FakeGitHub([CATALOG, TASKS], {
            (CATALOG, OLD): {"overview": OLD}, (CATALOG, NEW): {"overview": OLD},
            (TASKS, OLD): {"specification/keep.md": OLD, "schema/removed.json": OLD},
            (TASKS, NEW): {"specification/keep.md": NEW, "schema/added.json": NEW}})
        report = CHECK.compare(client, {CATALOG: entry(), TASKS: entry()})
        tasks = next(s for s in report["sources"] if s["repository"] == TASKS)
        self.assertEqual(tasks["added"], ["schema/added.json"])
        self.assertEqual(tasks["modified"], ["specification/keep.md"])
        self.assertEqual(tasks["removed"], ["schema/removed.json"])
        self.assertTrue(tasks["needs_review"])
        rendered = CHECK.markdown(report)
        self.assertIn(f"/blob/{OLD}/schema/removed.json", rendered)
        self.assertIn(f"/compare/{OLD}...{NEW}", rendered)

    def test_new_and_missing_repositories_are_not_silently_dropped(self):
        experimental = "modelcontextprotocol/experimental-ext-example"
        client = FakeGitHub([CATALOG, experimental], {
            (CATALOG, OLD): {}, (CATALOG, NEW): {},
            (experimental, NEW): {"README.md": NEW}})
        report = CHECK.compare(client, {CATALOG: entry(), TASKS: entry()})
        states = {s["repository"]: s["status"] for s in report["sources"]}
        self.assertEqual(states[TASKS], "missing_repository")
        self.assertEqual(states[experimental], "new_repository")
        self.assertTrue(report["needs_review"])

    def test_pending_inventory_still_requires_review_with_identical_files(self):
        client = FakeGitHub([CATALOG], {(CATALOG, OLD): {}, (CATALOG, NEW): {}})
        report = CHECK.compare(client, {CATALOG: entry(status="pending")})
        self.assertTrue(report["needs_review"])
        self.assertEqual(report["sources"][0]["status"], "unchanged")
        report = CHECK.compare(client, {CATALOG: entry()})
        self.assertFalse(report["needs_review"])

    def test_repository_discovery_follows_pages_not_number_of_extensions(self):
        def repo(name):
            return {"name": name, "full_name": f"modelcontextprotocol/{name}",
                    "private": False, "default_branch": "main", "archived": False}
        client = CHECK.GitHub()
        with patch.object(client, "get", side_effect=[
                [repo("modelcontextprotocol")] + [repo(f"ordinary-{n}") for n in range(99)],
                [repo("ext-tasks"), repo("experimental-ext-example")]]) as get:
            repos = client.repositories()
        self.assertEqual(get.call_count, 2)
        self.assertIn(TASKS, repos)
        self.assertIn("modelcontextprotocol/experimental-ext-example", repos)

    def test_truncated_discovery_and_git_trees_are_errors(self):
        client = CHECK.GitHub()
        ordinary = {"name": "ordinary", "full_name": "modelcontextprotocol/ordinary", "private": False}
        with patch.object(client, "get", return_value=[ordinary] * 100):
            with self.assertRaisesRegex(CHECK.CheckError, "incomplete"):
                client.repositories()
        with patch.object(client, "get", return_value={"tree": [], "truncated": True}):
            with self.assertRaisesRegex(CHECK.CheckError, "Incomplete Git tree"):
                client.files(TASKS, OLD)

    def test_source_scope_includes_current_nested_schemas_and_lifecycle_moves(self):
        for path in ["specification/archived/tasks/tasks.md", "schema/2026-07-28/schema.ts",
                     "packages/ext-tasks/schema/v2/schema.json", "src/generated/schema.ts",
                     "schema.ts", "docs/specification.md", "README.md", "RELEASES.md"]:
            self.assertTrue(CHECK.watched(TASKS, path), path)
        for path in ["src/index.ts", "package-lock.json", "examples/demo/schema.ts", ".github/test.yml"]:
            self.assertFalse(CHECK.watched(TASKS, path), path)
        self.assertTrue(CHECK.watched(CATALOG, "docs/extensions/new-extension/overview.mdx"))
        self.assertFalse(CHECK.watched(CATALOG, "docs/specification/draft/server/tools.mdx"))

    def test_archiving_a_repository_is_reported_even_without_file_changes(self):
        client = FakeGitHub([CATALOG], {(CATALOG, OLD): {}, (CATALOG, NEW): {}})
        with patch.object(client, "repositories", return_value={
                CATALOG: {"branch": "main", "archived": True}}):
            report = CHECK.compare(client, {CATALOG: entry()})
        self.assertTrue(report["needs_review"])
        self.assertTrue(report["sources"][0]["archive_state_changed"])
        self.assertIn("Repository archived: True", CHECK.markdown(report))

    def test_invalid_branch_response_does_not_become_a_clean_check(self):
        client = CHECK.GitHub()
        for response in [{"object": []}, {"object": {"sha": OLD, "type": "tree"}}, []]:
            with patch.object(client, "get", return_value=response):
                with self.assertRaises(CHECK.CheckError):
                    client.head(TASKS, "main")

    def test_success_preserves_the_baseline_and_emits_reviewable_artifacts(self):
        client = FakeGitHub([CATALOG], {(CATALOG, OLD): {}, (CATALOG, NEW): {"docs/extensions/new.mdx": NEW}})
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline = root / "baseline.json"
            baseline.write_text(json.dumps({"version": 1, "sources": {CATALOG: entry()}}))
            original = baseline.read_bytes()
            with patch.object(CHECK, "GitHub", return_value=client):
                self.assertEqual(CHECK.main(["--baseline", str(baseline), "--output", str(root / "out")]), 0)
            self.assertEqual(baseline.read_bytes(), original)
            report = json.loads((root / "out/report.json").read_text())
            self.assertEqual(report["status"], "complete")
            self.assertTrue(report["needs_review"])
            self.assertIn("docs/extensions/new.mdx", (root / "out/report.md").read_text())

    def test_malformed_baselines_are_rejected_before_network_access(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "baseline.json"
            for sources in [{}, {CATALOG: entry("main")},
                            {CATALOG: entry(), "other-org/ext-example": entry()}]:
                path.write_text(json.dumps({"version": 1, "sources": sources}))
                with self.assertRaises(CHECK.CheckError):
                    CHECK.load_baseline(path)

    def test_failure_emits_error_reports_and_never_updates_baseline(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline = root / "baseline.json"
            baseline.write_text(json.dumps({"version": 1, "sources": {CATALOG: entry()}}))
            original = baseline.read_bytes()
            with patch.object(CHECK.GitHub, "repositories", side_effect=CHECK.CheckError("HTTP 403")):
                self.assertEqual(CHECK.main(["--baseline", str(baseline), "--output", str(root / "out")]), 1)
            self.assertEqual(baseline.read_bytes(), original)
            report = json.loads((root / "out/report.json").read_text())
            self.assertEqual(report["status"], "error")
            self.assertIn("Check incomplete", (root / "out/report.md").read_text())

    def test_truncated_response_still_emits_an_explicit_incomplete_report(self):
        response = MagicMock()
        response.__enter__.return_value.read.side_effect = IncompleteRead(b"partial response", 20)
        opener = MagicMock()
        opener.open.return_value = response
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline = root / "baseline.json"
            baseline.write_text(json.dumps({"version": 1, "sources": {CATALOG: entry()}}))
            with patch.object(CHECK, "build_opener", return_value=opener):
                self.assertEqual(CHECK.main(["--baseline", str(baseline), "--output", str(root / "out")]), 1)
            report = json.loads((root / "out/report.json").read_text())
            self.assertEqual(report["status"], "error")
            self.assertIn("Check incomplete", (root / "out/report.md").read_text())


if __name__ == "__main__":
    unittest.main()
