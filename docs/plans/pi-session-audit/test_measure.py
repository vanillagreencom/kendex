#!/usr/bin/env python3
"""Tests for measure.py: python3 docs/plans/pi-session-audit/test_measure.py

Expected values are counted by hand from the fixtures, never read back from
measure.py. The drift tests read pi-extensions source, so they need the
repository checkout this file sits in.
"""

import contextlib
import io
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

import measure

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
EXTENSIONS = os.path.join(REPO, "pi-extensions")


def run(argv):
    out = io.StringIO()
    err = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = measure.main(argv)
    return code, out.getvalue(), err.getvalue()


def sources():
    """(package, path, text) for every non-test TypeScript file of every package."""
    for package in sorted(os.listdir(EXTENSIONS)):
        root = os.path.join(EXTENSIONS, package)
        if not os.path.isfile(os.path.join(root, "package.json")):
            continue
        for directory, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs if d not in ("node_modules", "tests", "__tests__", "test", "bundle")]
            for name in files:
                if name.endswith(".ts") and not name.endswith((".test.ts", ".d.ts", ".bench.ts")):
                    path = os.path.join(directory, name)
                    with open(path, "r", encoding="utf-8") as handle:
                        yield package, path, handle.read()


class ClassifierTable(unittest.TestCase):
    # Each row: text, kind, tool, expected class, expected rule.
    ROWS = (
        ("Operation aborted", "tool", "bash", "interrupted", "interrupted"),
        ('Validation failed for tool "subagent":\n  - task: required', "tool", "subagent", "model", "pi-arguments-invalid"),
        ("Tool web_serach not found", "tool", "web_serach", "model", "pi-tool-unknown"),
        ("<tool_use_error>File has not been read yet.</tool_use_error>", "tool", "Edit", "model", "claude-tool-use-error"),
        ("hook-registry-unreadable=tool_call\nNo hook ran. bad json", "tool", "bash", "extension", "pi-hooks-registry-unreadable"),
        ("child failed: boom", "tool", "subagent", "extension", "our-tool"),
        ("skill-load-check: unloaded=linear\nload it", "tool", "bash", "repository", "hook-refusal"),
        ("PreToolUse:Bash hook error: [x]: skill-load-check: unloaded=linear", "tool", "Bash", "repository", "hook-refusal"),
        ("error: tests failed in pi-extensions/pi-qol\n\nCommand exited with code 1", "tool", "bash", "repository", "command-exit"),
        ("Exit code 2\nls: cannot access", "tool", "Bash", "repository", "command-exit"),
        ("Command timed out after 120 seconds", "tool", "bash", "repository", "command-exit"),
        ("TypeError: boom\n    at /h/.pi/agent/packages/@vanillagreen/pi-tool-renderer/x.ts:1", "tool", "read", "extension", "names-package"),
        ("ENOENT: no such file or directory, access '/w/x'", "tool", "read", "model", "file-arguments"),
        ("Found 2 occurrences of the text in a.ts. The text must be unique.", "tool", "edit", "model", "file-arguments"),
        ("something else entirely", "tool", "read", "unclassified", "none"),
        ("terminated", "turn", None, "provider", "turn-error"),
        ("Error: pi-claude-bridge query failed", "turn", None, "extension", "names-package"),
    )

    def test_rows(self):
        for text, kind, tool, cls, rule in self.ROWS:
            with self.subTest(text=text):
                got = measure.classify(text, kind, tool)
                self.assertEqual((got[0], got[1]), (cls, rule))

    def test_every_rule_example(self):
        # Each table row's own example reaches that row.
        for row in measure.ERROR_RULES:
            tool = "subagent" if row.get("tool") == "ours" else None
            with self.subTest(rule=row["rule"]):
                self.assertEqual(measure.classify(row["example"], "turn" if row["kind"] == "turn" else "tool", tool)[1], row["rule"])


class Live(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        code, out, _ = run(["live", "--home", os.path.join(FIXTURES, "home"), "--item", "KEN-9"])
        assert code == 0, code
        cls.data = json.loads(out)
        cls.by_path = {s["path"]: s for s in cls.data["sessions"]}

    def test_stores(self):
        stores = self.data["stores"]
        self.assertEqual(stores["pi"]["files"], 2)
        self.assertEqual(stores["pi-kendex"]["skipped_non_session"], 1)
        self.assertEqual(stores["claude"]["files"], 2)
        # ~/.claude/projects links into ~/.claude-shared/projects: read once.
        self.assertEqual(stores["claude-local"]["files"], 0)
        self.assertEqual(stores["copilot:.copilot"]["files"], 1)
        self.assertEqual(len(self.data["errors"]), 1)

    def test_pi_tokens_and_fork_dedupe(self):
        lead = self.by_path["--work--/a_s1.jsonl"]["tokens"]
        self.assertEqual((lead["input"], lead["output"], lead["cache_read"], lead["cache_write"], lead["total"]),
                         (111, 26, 2600, 50, 2787))
        fork = self.by_path["--work--/b_fork.jsonl"]
        self.assertEqual(fork["tokens"]["total"], 4)
        self.assertEqual(fork["tools"]["results"], 0)
        self.assertEqual(self.data["duplicate_assistant_messages"], 1)

    def test_pi_context(self):
        context = self.by_path["--work--/a_s1.jsonl"]["context"]
        self.assertEqual(context["system_messages"], 2)
        self.assertEqual(context["addendum_by_package"]["pi-questions"], len("\nAsk with question.\n"))
        self.assertEqual(context["tool_definitions"]["ours"]["pi-agents-tmux"]["tools"], ["subagent"])
        self.assertNotIn("pi-background-tasks", context["tool_definitions"]["ours"])
        self.assertEqual(context["tool_definitions"]["builtin"]["tools"], 1)
        self.assertEqual(context["custom_messages"]["kendex-task-panel:context"]["package"], "pi-task-panel")
        self.assertEqual(context["custom_entries"]["kendex-background-tasks:state"]["count"], 1)
        self.assertEqual(context["nested_agents_md"]["parts"], 1)
        policy = context["output_policy"]
        self.assertEqual((policy["truncated"], policy["minimized_only"], policy["minimized_lines"]), (1, 1, 7))
        self.assertEqual(policy["before_bytes"] - policy["after_bytes"], 1000 - len("fatal: bad object\n\nCommand exited with code 128"))
        self.assertEqual(self.by_path["--work--/a_s1.jsonl"]["owed_turns"], 1)

    def test_pi_errors(self):
        tools = self.by_path["--work--/a_s1.jsonl"]["tools"]
        self.assertEqual((tools["calls"], tools["results"], tools["errors"]), (5, 5, 4))
        self.assertEqual(tools["errors_by_class"], {"extension": 1, "model": 1, "provider": 1, "repository": 1, "unclassified": 0})
        sub = self.by_path["s1/pi-agents-tmux/sessions/scout.jsonl"]
        self.assertTrue(sub["subagent"])
        self.assertEqual(sub["tools"]["error_rows"][0]["package"], "pi-web-tools")

    def test_claude(self):
        lead = self.by_path["-work/c1.jsonl"]
        tokens = lead["tokens"]
        # m1 spans three lines with one usage; m2 is one line.
        self.assertEqual((tokens["input"], tokens["output"], tokens["cache_read"], tokens["cache_write"], tokens["recorded"]),
                         (4, 12, 100, 20, 2))
        self.assertEqual(lead["tools"]["calls"], 2)
        self.assertEqual(lead["tools"]["errors_by_class"], {"extension": 0, "model": 1, "provider": 1, "repository": 1, "unclassified": 0})
        self.assertEqual(lead["owed_turns"], 1)
        self.assertTrue(self.by_path["-work/c1/subagents/agent-a.jsonl"]["subagent"])

    def test_copilot(self):
        session = self.by_path["u1/events.jsonl"]
        self.assertEqual(session["tokens"]["total"], 34)
        self.assertEqual(session["models"], {"claude-opus-5.5": 3})
        self.assertEqual(session["tools"]["errors_by_class"]["unclassified"], 1)
        self.assertEqual(session["tools"]["error_rows"][0]["excerpt"], "boom")
        self.assertEqual(session["owed_turns"], "not recorded")

    def test_append_system_and_artifacts(self):
        self.assertEqual(self.data["append_system"]["pi-questions"], len("\nQ1\n"))
        self.assertEqual(self.data["output_policy_artifacts"], {"files": 1, "bytes": 10})


class Archive(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.dir = os.path.join(self.tmp, "kendex", "KEN-9")
        shutil.copytree(os.path.join(FIXTURES, "archive", "kendex", "KEN-9"), self.dir)
        subprocess.run(["tar", "-czf", os.path.join(self.dir, "tmp-1.tgz"), "-C", os.path.join(FIXTURES, "archive-members"), "records"],
                       check=True, env={"PATH": os.environ["PATH"]})
        self.oversee = os.path.join(FIXTURES, "oversee", "workflow-state-oversee.json")
        self.brief = os.path.join(FIXTURES, "oversee", "brief-tail-template.md")

    def test_archive(self):
        code, out, err = run(["archive", "--dir", self.dir, "--oversee-state", self.oversee, "--brief-tail", self.brief, "--min-free-gb", "0"])
        self.assertEqual(code, 0)
        self.assertIn("Filesystem", err)
        data = json.loads(out)
        self.assertEqual((data["repo"], data["item"]), ("kendex", "KEN-9"))
        self.assertEqual(data["token_totals"]["claude"], {"input": 11, "output": 21, "cache_read": 31, "cache_write": 41, "total": 104})
        self.assertEqual(data["token_totals"]["pi"]["total"], 10)
        self.assertEqual([e["error"] for e in data["errors"]], ["token-record-shape harness=pi model=bad"])
        archive = data["tmp_archives"][0]
        self.assertEqual((archive["members"], archive["skipped"], len(archive["read"])), (4, 1, 3))
        self.assertEqual(data["lane_status"][0]["keys"], ["at", "state"])
        self.assertEqual(data["lane_mail"]["by_kind"], {"ask": 2, "notice": 1})
        self.assertIn("pi-background-tasks", data["lane_mail"]["asks"][0]["terms"])
        self.assertEqual(data["lane_mail"]["asks"][1]["terms"], [])
        self.assertEqual(data["item_state"], {"cycles": 2, "rereview_cycles": 1, "pr_comment_iterations": 3, "fixes": 2, "skipped": 1, "escalated_items": 1})
        self.assertEqual(len(data["oversee"]["lanes"]), 1)
        self.assertEqual(data["oversee"]["fleet_log"], {"rows": 2, "by_kind": {"ruling": 1, "close": 1}, "relaunch_rows": 1})
        self.assertEqual(data["brief_tail"], {"clauses": 5, "harness_only": {"pi": 1, "claude": 1, "copilot": 1}})

    def test_disk_low_stops_with_nothing_on_stdout(self):
        code, out, err = run(["archive", "--dir", self.dir, "--min-free-gb", "1000000000"])
        self.assertEqual((code, out), (3, ""))
        self.assertTrue(err.splitlines()[-2].startswith("measure: disk-low="))

    def test_missing_dir(self):
        code, out, _ = run(["archive", "--dir", os.path.join(self.tmp, "absent")])
        self.assertEqual((code, out), (2, ""))


class SourceDrift(unittest.TestCase):
    """measure.py's ownership tables against pi-extensions source.

    Extraction covers: inline `name: "x"` within the registerTool call,
    `create*ToolDefinition` defaults and their string-argument aliases, and
    the `"grep" | "find" | "ls"` union. A registration spelled any other way
    is missed (under-inclusion stays open beyond the floor below).
    """

    def registered(self):
        found = {}
        factory_default = {}
        for package, _, text in sources():
            for match in re.finditer(r"export function (create\w+ToolDefinition)\(", text):
                signature = text[match.end():text.index("{\n", match.end())]
                default = re.search(r'name = "([a-z_]+)"', signature)
                body = re.search(r'name: "([a-z_]+)"', text[match.end():match.end() + 600])
                factory_default[match.group(1)] = (package, (default or body).group(1))
        for package, _, text in sources():
            for match in re.finditer(r"pi\.registerTool(?:<[^>]*>)?\(", text):
                window = text[match.end():match.end() + 600]
                first = re.search(r"\bname: (\"[a-z_]+\"|toolName)", window) if window.lstrip().startswith("{") else None
                inline = first if first and first.group(1) != "toolName" else None
                factory = re.match(r"\s*(create\w+ToolDefinition)\(([^)]*)\)", window)
                union = first if first and first.group(1) == "toolName" else None
                if inline:
                    found[inline.group(1).strip('"')] = package
                elif factory:
                    alias = re.search(r'"([a-z_]+)"', factory.group(2))
                    found[alias.group(1) if alias else factory_default[factory.group(1)][1]] = package
                elif union:
                    for name in re.search(r'toolName: ((?:"[a-z]+" \| )*"[a-z]+")', text).group(1).split(" | "):
                        found[name.strip('"')] = package
                else:
                    self.fail("unreadable registerTool site in %s: %r" % (package, window[:80]))
        return found

    def test_packages_match_directories(self):
        on_disk = sorted(p for p in os.listdir(EXTENSIONS) if os.path.isfile(os.path.join(EXTENSIONS, p, "package.json")))
        self.assertEqual(sorted(measure.PACKAGES), on_disk)

    def test_tool_owners_match_source(self):
        found = self.registered()
        # Floor: the extractor is broken, not the source sparse, below this.
        self.assertGreaterEqual(len(found), 30, "registerTool extractor found too few tools")
        self.assertEqual(found.get("subagent"), "pi-agents-tmux")
        ours = {name: package for name, package in found.items() if name not in measure.PASS_THROUGH_OVERRIDES}
        self.assertEqual(ours, measure.TOOL_OWNERS)
        self.assertEqual({n for n, p in found.items() if n in measure.PASS_THROUGH_OVERRIDES and p == "pi-tool-renderer"},
                         set(measure.PASS_THROUGH_OVERRIDES))

    def test_custom_types_map_to_their_package(self):
        seen = 0
        for package, path, text in sources():
            if package == "pi-caveman":
                continue
            values = re.findall(r'customType: "([^"]+)"', text)
            values += re.findall(r'(?:_TYPE|CUSTOM_TYPE) = "([^"]+)"', text)
            for value in values:
                seen += 1
                with self.subTest(value=value, path=path):
                    self.assertEqual(measure.custom_type_owner(value), package)
        self.assertGreaterEqual(seen, 15, "customType extractor found too few values")


if __name__ == "__main__":
    unittest.main()
