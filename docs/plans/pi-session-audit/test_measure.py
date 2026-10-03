#!/usr/bin/env python3
"""Tests for measure.py: python3 docs/plans/pi-session-audit/test_measure.py

Expected values are counted by hand from the fixtures, never read back from
measure.py. The drift tests read pi-extensions source, so they need the
repository checkout this file sits in.
"""

import contextlib
import gzip
from unittest import mock
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


def make_item(root, repo, item, tar_from=None):
    """Copy the KEN-9 fixture records into root/repo/item, with a tmp-1.tgz."""
    directory = os.path.join(root, repo, item)
    shutil.copytree(os.path.join(FIXTURES, "archive", "kendex", "KEN-9"), directory)
    subprocess.run(["tar", "-czf", os.path.join(directory, "tmp-1.tgz"), "-C", os.path.join(FIXTURES, "archive-members"), "records"],
                   check=True, env={"PATH": os.environ["PATH"]})
    return directory


class Archive(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.dir = make_item(self.tmp, "kendex", "KEN-9")
        self.oversee = "kendex=" + os.path.join(FIXTURES, "oversee", "workflow-state-oversee.json")
        self.brief = "kendex=" + os.path.join(FIXTURES, "oversee", "brief-tail-template.md")

    def test_one_item(self):
        work = os.path.realpath(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, work)
        before = (sorted(os.listdir(self.dir)), sorted(os.listdir(work)))
        cwd = os.getcwd()
        os.chdir(work)
        try:
            code, out, err = run(["archive", "--dir", self.dir, "--oversee-state", self.oversee, "--brief-tail", self.brief, "--min-free-gb", "0"])
        finally:
            os.chdir(cwd)
        # Members stream to memory: nothing lands in the item or working directory.
        self.assertEqual((sorted(os.listdir(self.dir)), sorted(os.listdir(work))), before)
        self.assertEqual(code, 0)
        self.assertIn("Filesystem", err)
        self.assertEqual(len(out.splitlines()), 1)
        data = json.loads(out)
        self.assertEqual((data["repo"], data["item"], data["harness"]), ("kendex", "KEN-9", "pi"))
        self.assertEqual(data["token_totals"]["claude"], {"input": 11, "output": 21, "cache_read": 31, "cache_write": 41, "total": 104, "unknown": 0})
        self.assertEqual(data["token_totals"]["pi"]["total"], 10)
        self.assertEqual([e["error"] for e in data["errors"]], ["token-record-shape harness=pi model=bad"])
        archive = data["tmp_archives"][0]
        # The close-out evidence copy of the mailbox is read but not counted
        # twice; the overseer's mailbox in the same archive is not this item's.
        self.assertEqual((archive["members"], archive["skipped"], len(archive["read"])), (6, 2, 4))
        self.assertEqual(data["lane_status"][0]["keys"], ["at", "state"])
        self.assertEqual(data["lane_mail"]["by_kind"], {"ask": 2, "notice": 1})
        self.assertEqual(len(data["lane_mail"]["asks"]), 2)
        self.assertIn("pi-background-tasks", data["lane_mail"]["asks"][0]["terms"])
        self.assertEqual(data["lane_mail"]["asks"][1]["terms"], [])
        self.assertEqual(data["item_state"], {"cycles": 2, "rereview_cycles": 1, "pr_comment_iterations": 3, "fixes": 2, "skipped": 1, "escalated_items": 1})
        self.assertEqual(len(data["oversee"]["lanes"]), 1)
        self.assertEqual(data["oversee"]["fleet_log"], {"rows": 2, "by_kind": {"ruling": 1, "close": 1}, "relaunch_rows": 1})
        # Launched 00:00, merged 05:00, paused 01:00-02:00.
        self.assertEqual(data["outcome"], {"merged": True, "wall_secs": 4 * 3600, "paused_secs": 3600, "fix_rounds": 1,
                                           "stopped_parked_or_paused": True, "tier": None})
        self.assertEqual(data["brief_tail"], {"clauses": 5, "harness_only": {"pi": 1, "claude": 1, "copilot": 1}})

    def test_member_cap(self):
        with mock.patch.object(measure, "MEMBER_CAP_BYTES", 8):
            code, out, _ = run(["archive", "--dir", self.dir, "--min-free-gb", "0"])
        self.assertEqual(code, 0)
        data = json.loads(out)
        self.assertEqual(data["tmp_archives"][0]["read"], [])
        capped = [e for e in data["errors"] if e["error"] == "member over 8 bytes"]
        self.assertEqual(len(capped), 4)

    def test_null_count_is_kept_as_unknown(self):
        path = os.path.join(self.dir, "tokens-sb2.json")
        with open(path, "w") as handle:
            json.dump({"harnesses": {"codex": {"files": 1, "unreadable": 0, "unrecorded": 0,
                                               "models": {"gpt-6.1-sol": [5, 6, 7, None]}}}, "at": "2026-10-05T01:00:00Z"}, handle)
        code, out, _ = run(["archive", "--dir", self.dir, "--min-free-gb", "0"])
        self.assertEqual(code, 0)
        data = json.loads(out)
        self.assertEqual(data["token_totals"]["codex"], {"input": 5, "output": 6, "cache_read": 7, "cache_write": 0, "total": 18, "unknown": 1})
        row = data["token_records"][1]["harnesses"]["codex"]["models"]["gpt-6.1-sol"]
        self.assertEqual((row["cache_write"], row["unknown"]), (None, ["cache_write"]))

    def test_root_sweep_and_since(self):
        make_item(self.tmp, "fleet", "FLT-1")
        old = make_item(self.tmp, "vg", "VG-1")
        for name in os.listdir(old):
            path = os.path.join(old, name)
            if name.startswith("tokens-"):
                with open(path) as handle:
                    record = json.load(handle)
                record["at"] = "2026-09-20T00:00:00Z"
                with open(path, "w") as handle:
                    json.dump(record, handle)
            else:
                os.utime(path, (1758326400, 1758326400))  # 2025-09-20
        os.makedirs(os.path.join(self.tmp, "kendex", "oversee"))
        code, out, err = run(["archive", "--root", self.tmp, "--since", "2026-10-01", "--oversee-state", self.oversee, "--min-free-gb", "0"])
        self.assertEqual(code, 0)
        items = [(o["repo"], o["item"]) for o in map(json.loads, out.splitlines())]
        self.assertEqual(items, [("fleet", "FLT-1"), ("kendex", "KEN-9")])
        self.assertEqual(err.count("Filesystem"), 4)
        self.assertIn('measure: archive-done={"emitted": 2, "items": 4, "no_records": 2}', err)
        # fleet has no oversee state: its outcome is unknown, not unmerged.
        self.assertIsNone(json.loads(out.splitlines()[0])["outcome"]["merged"])

    def test_disk_low_stops_before_the_item(self):
        code, out, err = run(["archive", "--root", self.tmp, "--min-free-gb", "1000000000"])
        self.assertEqual((code, out), (3, ""))
        self.assertTrue(err.splitlines()[-2].startswith("measure: disk-low="))

    def test_refusals(self):
        self.assertEqual(run(["archive", "--dir", os.path.join(self.tmp, "absent")])[:2], (2, ""))
        self.assertEqual(run(["archive", "--root", self.tmp, "--oversee-state", "no-equals-sign"])[:2], (2, ""))
        self.assertEqual(run(["archive", "--root", self.tmp, "--since", "October"])[:2], (2, ""))


def archive_object(item, harness, total, merged=True, repo="kendex", model="claude-opus-5-5",
                   extra_tokens=(), asks=0, lane=True, unrecorded=0, lane_extra=None, null_side=None):
    """A schema-1 archive line, the shape the overseer's run produced.
    `merged=False` writes the lane with no cycle record, as the real
    cycle-less lanes are."""
    tokens = {harness: {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "total": total}}
    for other in extra_tokens:
        tokens[other] = {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "total": 1}
    stamps = {"launched": "2026-10-02T00:00:00Z", "merged": "2026-10-02T01:00:00Z"}
    lanes = [dict({"item": item, "harness": harness, "model": model, "status": "done",
                   "cycle": {"stamps": stamps, "rounds": {"fix": 1}} if merged else None}, **(lane_extra or {}))] if lane else []
    record = {"file": "tokens-x.json", "at": "2026-10-02T02:00:00Z",
              "harnesses": {h: {"files": 1, "unreadable": 0, "unrecorded": unrecorded if h == harness else 0,
                                "models": {model: t}} for h, t in tokens.items()}}
    if null_side:
        # A side harness whose only row has a null count: no known tokens.
        record["harnesses"][null_side] = {"files": 1, "unreadable": 0, "unrecorded": 0,
                                          "models": {"gpt-6.1-sol": {"input": 0, "output": 0, "cache_read": 0, "cache_write": None,
                                                                      "total": 0, "unknown": ["cache_write"]}}}
        tokens[null_side] = {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "total": 0, "unknown": 1}
    return {"schema": "pi-session-audit/archive/1", "mode": "archive", "repo": repo, "item": item,
            "token_records": [record], "token_totals": tokens, "tmp_archives": [{"file": "tmp-1.tgz"}],
            "lane_mail": {"asks": [{"id": "a%d" % i, "terms": []} for i in range(asks)] * 2},
            "oversee": {"lanes": lanes, "fleet_log": {"rows": 1, "by_kind": {"ruling": 1}, "relaunch_rows": 0}}}


class Aggregate(unittest.TestCase):
    MEASURE = "1 total tokens per merged item"

    def test_judged_with_eight_pi_items(self):
        objects = [archive_object("PI-%d" % i, "pi", i, model="github-copilot/claude-opus-5.5") for i in range(1, 9)]
        objects += [archive_object("CL-%d" % i, "claude", i) for i in range(1, 21)]
        objects.append(archive_object("PI-9", "pi", 1000, merged=False))
        objects.append(archive_object("CX-1", "codex", 5, model="gpt-6.1-sol"))
        table = measure.aggregate(objects, {})
        row = table["all"][self.MEASURE]
        self.assertEqual(row["verdict"], "judged")
        self.assertEqual(row["cells"]["pi"], {"n": 8, "items": 8, "median": 4.5, "p90": 8})
        # Nearest rank: ceil(0.9 * 20) = 18th of 20.
        self.assertEqual(row["cells"]["claude"], {"n": 20, "items": 20, "median": 10.5, "p90": 18})
        self.assertEqual(row["cells"]["codex"], {"n": 1, "items": 1, "verdict": "outside the comparison"})
        self.assertTrue(row["source"].startswith("tokens-*.json"))
        # Both spellings of the model fall in one family row.
        family = table["by_model"][self.MEASURE]["claude-opus-5.5"]["cells"]
        self.assertEqual((family["pi"]["n"], family["claude"]["n"]), (8, 20))
        # PI-9's lane has no cycle record: its merge is unknown, not "not merged".
        not_merged = table["all"]["5 share not merged"]["cells"]["pi"]
        self.assertEqual((not_merged["n"], not_merged["share"]), (8, 0.0))

    def test_seven_pi_items_is_too_small(self):
        objects = [archive_object("PI-%d" % i, "pi", i) for i in range(1, 8)]
        objects += [archive_object("CL-%d" % i, "claude", 10 * i) for i in range(1, 10)]
        row = measure.aggregate(objects, {})["all"][self.MEASURE]
        self.assertEqual(row["verdict"], "too small to judge")
        for harness in ("pi", "claude"):
            self.assertNotIn("median", row["cells"][harness])
            self.assertEqual(row["cells"][harness]["verdict"], "too small to judge")
        self.assertEqual(row["cells"]["claude"]["n"], 9)

    def test_exclusions_and_asks(self):
        objects = [archive_object("PI-1", "pi", 5, extra_tokens=("copilot",), asks=3),
                   archive_object("proof-1a", "pi", 5),
                   archive_object("FLT-1", "pi", 0, lane=False),
                   archive_object("issue-2708", "claude", 5)]
        table = measure.aggregate(objects, {})
        inputs = table["inputs"]
        # A GitHub issue-N key is a work item; proof-1a is a probe.
        self.assertEqual((inputs["probe_items_excluded"], inputs["no_harness_excluded"], inputs["items"]), (1, 1, 2))
        self.assertEqual(inputs["items_by_lead"], {"pi": 1, "claude": 1})
        self.assertEqual(inputs["mixed_token_items_by_lead"], {"pi": 1})
        self.assertEqual(inputs["tokens_under_another_lead"], {"copilot under pi": {"items": 1, "median_total": 1, "max_total": 1}})
        # PI-1 holds copilot tokens beside its lead: no measure-1 point.
        self.assertEqual({h: c["n"] for h, c in table["all"][self.MEASURE]["cells"].items()}, {"claude": 1})
        # Each ask appears twice in the line; one per envelope id counts.
        self.assertEqual(len(measure.normalize(objects[0], {})["asks"]), 3)

    def test_item_identity_ignores_the_callers_issue_pattern(self):
        # kendex.settings.toml sets GH_ISSUE_PATTERN=ken-[0-9]+; the archive
        # spans fleet, vg and talk trackers, which that setting must not drop.
        objects = [archive_object(key, "pi", 5) for key in ("KEN-1", "FLT-2", "vg-3", "TLK-4", "issue-5", "proof-3342777", "fleet-probe-v23-max")]
        issues = {key: {"estimate": 1, "agent": "agent:runtime"} for key in ("KEN-1", "FLT-2", "VG-3", "TLK-4", "kendex/issue-5")}
        with mock.patch.dict(os.environ, {"GH_ISSUE_PATTERN": "ken-[0-9]+"}):
            table = measure.aggregate(objects, issues)
        self.assertEqual((table["inputs"]["items"], table["inputs"]["probe_items_excluded"]), (5, 2))
        # proof-3342777 has a tracker id's shape but no tracker entry.
        self.assertIsNone(measure.work_item_id("proof-3342777", issues, "fleet"))
        self.assertEqual(measure.work_item_id("vg-3", issues, "vg"), "VG-3")
        self.assertEqual(measure.work_item_id("proof-3342777", {}, "fleet"), "PROOF-3342777")

    def test_issue_n_is_qualified_by_repository(self):
        # issue-1 in two repositories is two items; a match in kendex keeps
        # vg's issue-1 in the unmatched totals.
        objects = [archive_object("issue-1", "claude", 5, repo="kendex"), archive_object("PI-1", "pi", 3, repo="kendex"),
                   archive_object("issue-1", "claude", 7, repo="vg")]
        issues = {key: {"estimate": 1, "agent": "agent:runtime"} for key in ("kendex/issue-1", "PI-1", "vg/issue-1")}
        table = measure.aggregate(objects, issues)
        claude = table["all"][self.MEASURE]["cells"]["claude"]
        self.assertEqual((claude["n"], claude["items"]), (2, 2))
        self.assertEqual(sorted(table["matched"][self.MEASURE]), ["kendex|agent:runtime|1-2"])
        self.assertEqual(table["unmatched"][self.MEASURE]["cells"]["claude"]["n"], 1)

    def test_incomplete_and_null_side_runs_leave_measure_one(self):
        objects = [archive_object("PI-%d" % i, "pi", i) for i in range(1, 9)]
        objects.append(archive_object("PI-9", "pi", 900, unrecorded=1))
        objects.append(archive_object("PI-10", "pi", 1000, null_side="codex"))
        refused = archive_object("PI-11", "pi", 1100)
        refused["errors"] = [{"path": "tokens-x.json", "error": "token-record-shape harness=pi model=bad"}]
        objects.append(refused)
        table = measure.aggregate(objects, {})
        self.assertEqual(table["inputs"]["incomplete_token_items_by_harness"], {"pi": 2, "codex": 1})
        self.assertEqual(table["inputs"]["mixed_token_items_by_lead"], {"pi": 1})
        self.assertEqual(table["all"][self.MEASURE]["cells"]["pi"]["n"], 8)

    def test_lane_outcome_shapes(self):
        # Parking is the `parked` object; a lane's status never reads parked.
        parked = archive_object("PI-1", "pi", 5, lane_extra={"parked": {"pr": 1, "at": "2026-10-02T00:20:00Z"}})
        # A pause that runs past the merge counts only up to it, and overlaps
        # with the standing park count once: 00:20 to 01:00.
        parked["oversee"]["lanes"][0]["pauses"] = [{"from": "2026-10-02T00:30:00Z", "to": "2026-10-02T03:00:00Z", "cause": "parked"}]
        out = measure.lane_outcome(parked["oversee"]["lanes"][0])
        self.assertEqual((out["paused_secs"], out["wall_secs"], out["stopped_parked_or_paused"]), (2400, 1200, True))
        parked_only = archive_object("PI-3", "pi", 5, lane_extra={"parked": {"pr": 1, "at": "2026-10-02T00:20:00Z"}})
        self.assertTrue(measure.lane_outcome(parked_only["oversee"]["lanes"][0])["stopped_parked_or_paused"])
        cycleless = measure.lane_outcome(archive_object("PI-2", "pi", 5, merged=False)["oversee"]["lanes"][0])
        self.assertEqual((cycleless["merged"], cycleless["wall_secs"], cycleless["stopped_parked_or_paused"]), (None, None, False))

    def test_ask_groups(self):
        for row in measure.ASK_GROUPS:
            with self.subTest(group=row["group"]):
                self.assertEqual(measure.ask_group(row["example"]), row["group"])
        self.assertEqual(measure.ask_group("PR opened"), "other")
        # An ask matching two groups takes the first in table order.
        self.assertEqual(measure.ask_group("review failed"), "failing receipt or validation")
        line = archive_object("PI-1", "pi", 5)
        line["lane_mail"]["asks"] = [{"id": "x", "terms": [], "excerpt": "returned FAILING"}, {"id": "y", "terms": [], "excerpt": "Merge it?"}]
        foreign = archive_object("PI-2", "pi", 5)
        foreign["lane_mail"]["asks"] = [{"id": "z", "terms": [], "excerpt": "From nowhere."}]
        foreign["tmp_archives"] = [{"file": "tmp-1.tgz", "read": [{"member": "kendex/tmp/lane-mail/overseer/to-overseer.jsonl", "kind": "to-overseer"}]}]
        table = measure.aggregate([line, foreign], {})
        self.assertEqual(table["ask_groups"], {"pi": {"items": 1, "asks": 2, "failing receipt or validation": 1, "merge or review gate": 1}})
        self.assertEqual(table["inputs"]["foreign_mailbox_items_by_lead"], {"pi": 1})
        self.assertEqual(table["all"]["3 tool calls per session"]["verdict"], "not sampled (n=0)")

    def test_matched_strata_and_unmatched_totals(self):
        objects = [archive_object("PI-1", "pi", 5), archive_object("CL-1", "claude", 7),
                   archive_object("CL-2", "claude", 9), archive_object("PI-2", "pi", 3), archive_object("PI-3", "pi", 4)]
        issues = {"PI-1": {"estimate": 2, "agent": "agent:runtime"}, "CL-1": {"estimate": 1, "agent": "agent:runtime"},
                  "CL-2": {"estimate": 3, "agent": "agent:runtime"}, "PI-2": {"estimate": 0, "agent": "agent:runtime"},
                  "PI-3": {"estimate": 1, "agent": "agent:rust"}}
        table = measure.aggregate(objects, issues)
        matched = table["matched"][self.MEASURE]
        self.assertEqual(sorted(matched), ["kendex|agent:runtime|1-2"])
        self.assertEqual({h: c["n"] for h, c in matched["kendex|agent:runtime|1-2"]["cells"].items()}, {"pi": 1, "claude": 1})
        unmatched = table["unmatched"][self.MEASURE]["cells"]
        # A stratum holding Pi alone (agent:rust) is no match.
        self.assertEqual({h: c["n"] for h, c in unmatched.items()}, {"pi": 2, "claude": 1})
        self.assertEqual(table["inputs"]["matched_strata"], 1)

    def test_reads_gzip_lines_and_live_fixture(self):
        code, out, _ = run(["live", "--home", os.path.join(FIXTURES, "home"), "--item", "KEN-9", "--repo", "kendex"])
        self.assertEqual(code, 0)
        tmp = os.path.realpath(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        path = os.path.join(tmp, "lines.jsonl.gz")
        with gzip.open(path, "wt", encoding="utf-8") as handle:
            handle.write(json.dumps(archive_object("PI-1", "pi", 5)) + "\n" + out * 3)
        code, out, _ = run(["aggregate", path])
        self.assertEqual(code, 0)
        calls = json.loads(out)["all"]["3 tool calls per session"]
        # Nine Pi sessions (lead, fork, subagent, three times) are one item:
        # the floor counts items, not sessions.
        self.assertEqual(calls["verdict"], "too small to judge")
        self.assertEqual({h: (c["n"], c["items"]) for h, c in calls["cells"].items()}, {"pi": (9, 1), "claude": (6, 1), "copilot": (3, 1)})
        code, out, err = run(["aggregate", os.path.join(FIXTURES, "oversee", "brief-tail-template.md")])
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
