#!/usr/bin/env python3
"""Report official MCP extension source drift without updating review baselines."""
import argparse
from datetime import datetime, timezone
import html
from http.client import HTTPException
import json
import os
from pathlib import Path
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import HTTPRedirectHandler, Request, build_opener


ORG = "modelcontextprotocol"
CATALOG = f"{ORG}/modelcontextprotocol"
SHA = re.compile(r"[0-9a-f]{40}")
NAME = re.compile(r"[A-Za-z0-9_.-]+")
BASELINE = Path(__file__).with_name("mcp_extensions_baseline.json")


class CheckError(Exception):
    """An incomplete or invalid check must not be reported as clean."""


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class GitHub:
    def __init__(self, token=None):
        self.token = token
        self.opener = build_opener(NoRedirect())
        self.trees = {}

    def get(self, path):
        headers = {"Accept": "application/vnd.github+json",
                   "User-Agent": "ArborMCP-extension-drift",
                   "X-GitHub-Api-Version": "2022-11-28"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        request = Request("https://api.github.com" + path, headers=headers)
        try:
            with self.opener.open(request, timeout=30) as response:
                body = response.read(16 * 1024 * 1024 + 1)
            if len(body) > 16 * 1024 * 1024:
                raise CheckError("GitHub response exceeds the 16 MiB limit")
            return json.loads(body)
        except HTTPError as error:
            raise CheckError(f"GitHub HTTP {error.code} for {path}") from None
        except (URLError, TimeoutError, OSError, ValueError, HTTPException):
            raise CheckError(f"Could not read valid GitHub JSON for {path}") from None

    def repositories(self):
        repositories = {}
        for page in range(1, 21):
            entries = self.get(f"/orgs/{ORG}/repos?type=all&per_page=100&page={page}")
            if not isinstance(entries, list):
                raise CheckError("Invalid organization repository listing")
            for entry in entries:
                if not isinstance(entry, dict):
                    raise CheckError("Invalid repository entry")
                name = entry.get("name", "")
                if not isinstance(name, str) or not NAME.fullmatch(name):
                    raise CheckError("Invalid repository name")
                if not isinstance(entry.get("private"), bool):
                    raise CheckError("Invalid repository visibility")
                if entry["private"]:
                    continue
                full_name = entry.get("full_name", "")
                if not isinstance(full_name, str) or full_name.lower() != f"{ORG}/{name}".lower():
                    raise CheckError("Unexpected repository owner")
                if name == "modelcontextprotocol" or name.startswith(("ext-", "experimental-ext-")):
                    branch = entry.get("default_branch")
                    if not isinstance(branch, str) or not branch or len(branch) > 255:
                        raise CheckError("Invalid default branch")
                    if not isinstance(entry.get("archived"), bool):
                        raise CheckError("Invalid repository archive state")
                    if full_name in repositories:
                        raise CheckError("Duplicate repository in paginated listing")
                    repositories[full_name] = {"branch": branch,
                                               "archived": bool(entry.get("archived"))}
            if len(entries) < 100:
                if CATALOG not in repositories:
                    raise CheckError("Official extension catalog repository is missing")
                return repositories
        raise CheckError("Repository discovery exceeded 20 pages; listing is incomplete")

    def head(self, repository, branch):
        data = self.get(f"/repos/{repository}/git/ref/heads/{quote(branch, safe='')}")
        obj = data.get("object") if isinstance(data, dict) else None
        sha = obj.get("sha") if isinstance(obj, dict) else None
        if (not isinstance(sha, str) or not SHA.fullmatch(sha) or obj.get("type") != "commit"):
            raise CheckError(f"Invalid branch revision for {repository}")
        return sha

    def files(self, repository, revision):
        key = repository, revision
        if key in self.trees:
            return self.trees[key]
        data = self.get(f"/repos/{repository}/git/trees/{revision}?recursive=1")
        if not isinstance(data, dict) or data.get("truncated") is not False:
            raise CheckError(f"Incomplete Git tree for {repository}")
        entries = data.get("tree")
        if not isinstance(entries, list):
            raise CheckError(f"Invalid Git tree for {repository}")
        files = {}
        for entry in entries:
            if not isinstance(entry, dict):
                raise CheckError(f"Invalid Git tree entry for {repository}")
            path = entry.get("path")
            if (not isinstance(path, str) or not path or any(ord(c) < 32 for c in path) or
                    any(part in {"", ".", ".."} for part in path.split("/"))):
                raise CheckError(f"Invalid Git tree path for {repository}")
            if entry.get("type") not in ("blob", "tree", "commit"):
                raise CheckError(f"Invalid Git tree object type for {repository}")
            if entry.get("type") != "blob" or not watched(repository, path):
                continue
            sha = entry.get("sha")
            if not isinstance(sha, str) or not SHA.fullmatch(sha) or path in files:
                raise CheckError(f"Invalid or duplicate Git blob for {repository}")
            files[path] = sha
        if repository == CATALOG and "docs/extensions/overview.mdx" not in files:
            raise CheckError("Official extension index was not found")
        self.trees[key] = files
        return files


def watched(repository, path):
    if repository == CATALOG:
        return path.startswith("docs/extensions/") or path in {
            "docs/seps/2133-extensions.mdx", "docs/seps/3392-extension-lifecycle.mdx",
            "seps/2133-extensions.md", "seps/3392-extension-lifecycle.md"}
    parts = path.split("/")
    if parts[0] in {"examples", "tests", "node_modules", ".github"}:
        return False
    if any(part in {"specification", "schema", "schemas", "docs"} for part in parts[:-1]):
        return True
    name = parts[-1]
    if len(parts) == 1 and (name in {"index.md", "index.mdx"} or
                            re.match(r"^(README|CHANGELOG|RELEASES)(\.|$)", name)):
        return True
    return bool(re.fullmatch(r"(?:spec\.)?(?:schema|schemas|types)\.(?:json|ts)", name))


def load_baseline(path):
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        raise CheckError("Cannot read the extension baseline") from None
    if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("sources"), dict):
        raise CheckError("Invalid extension baseline format")
    for repository, entry in data["sources"].items():
        parts = repository.split("/")
        if (len(parts) != 2 or parts[0] != ORG or not NAME.fullmatch(parts[1]) or
                (repository != CATALOG and not parts[1].startswith(("ext-", "experimental-ext-")))):
            raise CheckError("Baseline contains an unofficial extension repository")
        if (not isinstance(entry, dict) or
                not isinstance(entry.get("revision"), str) or not SHA.fullmatch(entry["revision"]) or
                entry.get("review_status") not in ("pending", "reviewed") or
                not isinstance(entry.get("archived", False), bool)):
            raise CheckError(f"Invalid baseline entry for {repository}")
    if CATALOG not in data["sources"]:
        raise CheckError("Baseline must include the official extension catalog")
    return data["sources"]


def compare(client, baseline):
    discovered = client.repositories()
    results = []
    for repository in sorted(baseline.keys() | discovered.keys()):
        previous = baseline.get(repository)
        result = {"repository": repository,
                  "baseline_revision": previous["revision"] if previous else None,
                  "review_status": previous["review_status"] if previous else "pending",
                  "added": [], "modified": [], "removed": []}
        if repository not in discovered:
            result.update(status="missing_repository", current_revision=None, needs_review=True)
        else:
            metadata = discovered[repository]
            revision = client.head(repository, metadata["branch"])
            current = client.files(repository, revision)
            old = client.files(repository, previous["revision"]) if previous else {}
            result.update(current_revision=revision, archived=metadata["archived"],
                          added=sorted(current.keys() - old.keys()),
                          removed=sorted(old.keys() - current.keys()),
                          modified=sorted(p for p in current.keys() & old.keys() if current[p] != old[p]))
            archive_changed = previous is not None and metadata["archived"] != previous.get("archived", False)
            result["archive_state_changed"] = archive_changed
            changed = any(result[k] for k in ("added", "modified", "removed")) or archive_changed
            status = "new_repository" if previous is None else "changed" if changed else "unchanged"
            result.update(status=status, needs_review=changed or previous is None or
                          result["review_status"] == "pending")
        results.append(result)
    return {"status": "complete", "checked_at": datetime.now(timezone.utc).isoformat(),
            "needs_review": any(r["needs_review"] for r in results), "sources": results}


def safe_text(value):
    return (html.escape(value, quote=True).replace("`", "&#96;").replace("|", "&#124;")
            .replace("\\", "\\\\").replace("[", "\\[").replace("]", "\\]"))


def markdown(report):
    lines = ["# MCP extension source check", ""]
    if report["status"] == "error":
        return "\n".join(lines + ["**Check incomplete. No clean-drift conclusion is available.**", "",
                                     safe_text(report["error"]), ""])
    lines += [f"Checked: {report['checked_at']}", "",
              "This is source drift detection, not an implementation compatibility verdict.",
              "A pending baseline is an initial inventory, not a reviewed implementation pin.", "",
              "| Source | Change | Review | Added / modified / removed |",
              "| --- | --- | --- | --- |"]
    for source in report["sources"]:
        repo = source["repository"]
        counts = " / ".join(str(len(source[k])) for k in ("added", "modified", "removed"))
        lines.append(f"| [{repo}](https://github.com/{repo}) | {source['status']} | "
                     f"{source['review_status']} | {counts} |")
    for source in report["sources"]:
        if not source["needs_review"]:
            continue
        repo = source["repository"]
        old, current = source["baseline_revision"], source["current_revision"]
        lines += ["", f"## {repo}", ""]
        if source["status"] == "missing_repository":
            lines += ["No longer present in complete public repository discovery. Check for a rename,",
                      "removal or visibility change before changing local support."]
            continue
        if old:
            lines += [f"[Baseline source](https://github.com/{repo}/tree/{old}) → "
                      f"[Current source](https://github.com/{repo}/tree/{current}).",
                      f"[Commit comparison](https://github.com/{repo}/compare/{old}...{current}).", ""]
        else:
            lines += [f"New official extension repository at `{current}`.", ""]
        if source["review_status"] == "pending":
            lines += ["Implementation applicability/compatibility assessment is still pending.", ""]
        if source["archived"] or source["archive_state_changed"]:
            lines += [f"Repository archived: {source['archived']}. Archive state changed: "
                      f"{source['archive_state_changed']}.", ""]
        for kind in ("added", "modified", "removed"):
            revision = old if kind == "removed" else current
            for path in source[kind]:
                url = f"https://github.com/{repo}/blob/{revision}/{quote(path, safe='/')}"
                lines.append(f"- {kind}: [{safe_text(path)}]({url})")
    lines += ["", "Review relevant specifications/schemas and local regressions before manually",
              "advancing a baseline revision or marking it reviewed. This check never updates",
              "baselines, dependencies, generated code or protocol behavior.", ""]
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, default=BASELINE)
    parser.add_argument("--output", type=Path, default=Path("tmp/mcp-extensions"))
    args = parser.parse_args(argv)
    try:
        report = compare(GitHub(os.environ.get("GITHUB_TOKEN")), load_baseline(args.baseline))
        code = 0
    except CheckError as error:
        report = {"status": "error", "error": str(error)}
        code = 1
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    (args.output / "report.md").write_text(markdown(report))
    if code:
        print("Extension source check incomplete; see report.md", file=sys.stderr)
    else:
        pending = sum(r["needs_review"] for r in report["sources"])
        print(f"Checked {len(report['sources'])} sources; {pending} need review.")
        if pending and os.environ.get("GITHUB_ACTIONS") == "true":
            print("::warning::Official MCP extension sources need review; see the job summary and report artifact.")
    return code


if __name__ == "__main__":
    sys.exit(main())
