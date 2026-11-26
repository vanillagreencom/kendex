"""progress-log writes one clock-stamped record into the home handoff, or refuses and writes nothing.

--check-state lists the State entries to correct from live tracker reads.
"""
import json
import os
from pathlib import Path
import runpy
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

from mail_world import BASH, REPO, SCRIPTS, MailWorld, make_project

sys.path.insert(0, str(SCRIPTS / "lib"))
from progress import change_state, index_ends, records, state_entries  # noqa: E402

STAMP = "2026-10-18T23:05:01Z"
HANDOFF = ("# Handoff\n\n## State\n\nwork: KEN-1\n\n## Sub-agents\n\nnone\n\n## Instructions in force\n\nnone\n\n"
           "## Progress log\n\n- Id and time: P-20261018T220000Z 2026-10-18T22:00:00Z\n  - Operation: earlier\n"
           "  - Observed result and source: seen\n  - Decision: kept\n  - State change: none\n\n## Notes\n\nlast\n")
FIELDS = {"--operation": "Reply to 1791680510", "--result": "sent, receipt id=1",
          "--decision": "answer now", "--state-change": "none"}
DONE, CANCELED, OPEN = ("Done", "completed"), ("Canceled", "canceled"), ("In Progress", "started")
DUPLICATE = ("Duplicate", "duplicate")
BULK_GET = ["issues", "bulk-get", "--stdin", "--format=compact"]
PROJECT = "fbb9620e-91bb-4e78-9cb3-907fa7dd72a7"
REQUEST = "C0123ABC:1793515695.587049"
OUTCOME = "Check the vendor receipt"
ACTION = "Jarvis reads the vendor's [receipt](https://example.org/receipt)."
OTHER_REQUEST = "C0123ABC:1793515695.587050"
OTHER_COMMENT = "96b25b81-a5f7-419c-bc42-c5a35cb04249"
DELIVERY = "C0123ABC:1793515999.000100"
NAMED_WRITE = [("issues", "get"), ("issues", "get"), ("issues", "update")]
NAMED_READBACK = NAMED_WRITE + [("issues", "get"), ("comments", "list")]
OPENING = "> **Story:** " + OUTCOME + "\n\n> **Why this matters:** The user asked for it.\n\n## Done when\n\n"
FILING = "\n## Filing record\n\nJarvis request source: " + OTHER_REQUEST
SIBLING = "- [ ] Jarvis outcome " + OTHER_REQUEST + " ask 1: The vendor sends the invoice; Jarvis waits for it.\n"
OLDER = [{"id": "decision", "body": "Decision: the user approved the receipt check.\n"}]
LINEAR_SCRIPTS = SCRIPTS.parents[1] / "linear/scripts"


def linear_bash():
    """BASH when linear's own preflight accepts it, else None.

    The LINEAR stub stands in for linear.sh, which runs only under the Bash that
    preflight admits. The macOS leg carries /bin/bash 3.2 alone, where linear's
    guards are skipped rather than run under a shell linear refuses."""
    probe = subprocess.run([BASH, "-c", 'source "$1" || exit 2; linear_require_supported_bash', "linear-bash",
                            str(REPO / "skills/linear/scripts/lib/bash-version.sh")], capture_output=True, text=True, timeout=60)
    if probe.returncode not in (0, 1):
        raise RuntimeError("linear-bash-unread=%s exit=%d %s" % (BASH, probe.returncode, probe.stderr.strip()))
    return BASH if probe.returncode == 0 else None


LINEAR_BASH = linear_bash()
NO_LINEAR_BASH = BASH + " is older than the Bash linear.sh requires, so the stub skips linear's issue guards"
# Bulk and safe rows use lib/formatters.sh. Missing refs use lib/common.sh's
# linear_issue_refs_read response. The comment delete receipt is lib/common.sh's
# normalize_mutation_response; issues update --format=ids prints the identifier.
LINEAR = '''#!/usr/bin/env python3
import fcntl, json, os, subprocess, sys, time
from pathlib import Path

home = Path(os.environ["HOME"])
store = home / "linear-world.json"
args = sys.argv[1:]
verb = tuple(args[:2])
# Two writers A and B on one item: B reads the body before A writes, and B's
# write lands after A's and before A reads back. Each flag is the other
# writer's acknowledgement of its step.
writer = os.environ.get("STUB_WRITER")


def flag(name):
    return home / ("race-" + name)


def wait(name):
    deadline = time.monotonic() + 50
    while not flag(name).exists():
        if time.monotonic() > deadline:
            sys.exit(7)
        time.sleep(0.01)


racing = writer is not None and verb == ("issues", "update") and not flag(writer + "-wrote").exists()
if racing:
    wait("B-read" if writer == "A" else "A-wrote")
held = store.open("r+")
fcntl.flock(held, fcntl.LOCK_EX)
world = json.loads(held.read())
reads_stdin = verb in (("issues", "bulk-get"), ("comments", "bulk-list"))
refs = sys.stdin.read().splitlines() if reads_stdin else []
with (home / "linear-calls").open("a") as calls:
    calls.write(json.dumps([args, refs]) + "\\n")
mode = world.get("mode")
issues, comments = world["issues"], world.get("comments", {})
if verb == ("issues", "bulk-get"):
    assert args[2:] == ["--stdin", "--format=compact"] and refs
    if world.get("fail"):
        print(json.dumps({"error": "HTTP 503"}), file=sys.stderr)
        sys.exit(1)
    if any(ref.rsplit("-", 1)[-1].startswith("0") for ref in refs):
        print(json.dumps({"error": "Argument Validation Error"}), file=sys.stderr)
        sys.exit(1)
    missing = [ref for ref in refs if ref in world.get("missing", ())]
    if missing:
        print(json.dumps({"error": "Entity not found: Issue"}), file=sys.stderr)
        print(json.dumps({"error": "Issues not read: " + ", ".join(missing), "missing": missing}), file=sys.stderr)
        sys.exit(1)
    fields = ("id", "title", "state", "state_type")
    print(json.dumps([{field: issues[ref][field] for field in fields} for ref in refs if ref in issues]))
elif verb == ("issues", "list"):
    assert args[2:] == ["--project-id", world["project"], "--include-archived", "--max", "--format=safe"]
    print(json.dumps(list(issues.values())))
elif verb == ("auth-check", "--strict"):
    assert len(args) == 2
    if mode == "no-team":
        print(json.dumps({"ok": True, "team": None, "team_source": "unset", "writes_enabled": False,
                          "warnings": ["No LINEAR_TEAM configured"]}))
        sys.exit(1)
elif verb == ("issues", "create"):
    assert args[2:4] == ["--project", world["project"]] and args[-1] == "--format=ids"
    assert world["created"] not in issues
    title, description = args[args.index("--title") + 1], args[args.index("--description") + 1]
    # Run the shipped guards without the workspace and network bootstrap, under
    # the Bash linear.sh requires. A null bash is a host with none: linear
    # refuses an older shell, so its guards are not run under one.
    if world["bash"]:
        subprocess.run([world["bash"], "-c",
                        'source "$1"; source "$2"; LINEAR_REQUIRE_REACH=1; LINEAR_AGENT_LABELS=agent:runtime; '
                        'require_agent_routing_label "" "$3" && require_issue_reach "$4" 0 && require_issue_header_shape "$4"',
                        "validate-description", world["validator"], world["routing_guard"],
                        str(int("--no-agent-label" in args)), description], check=True)
    issue = {"id": world["created"], "title": title, "description": description, "project_id": world["project"]}
    issues[issue["id"]] = issue
    store.write_text(json.dumps(world))
    print(issue["id"])
elif verb == ("issues", "get"):
    if mode == "readback-unavailable" and world.get("written"):
        sys.exit(5)
    if writer == "B":
        world["gets"] = world.get("gets", 0) + 1
        store.write_text(json.dumps(world))
        if world["gets"] == 2:
            flag("B-read").touch()
    print(json.dumps({"description": "", **issues[args[2]]}))
elif verb == ("issues", "update"):
    assert args[3] == "--description" and args[5:] == ["--format=ids"]
    if mode == "update-unavailable":
        sys.exit(5)
    # wrong-body stands for another writer that changes this line each time.
    issues[args[2]]["description"] = args[4].replace("Jarvis outcome", "Jarvis outcome edited") if mode == "wrong-body" else args[4]
    world["written"] = True
    store.write_text(json.dumps(world))
    if mode == "lost-update":
        sys.exit(5)
    print(args[2])
    if racing:
        held.close()
        flag(writer + "-wrote").touch()
        if writer == "A":
            wait("B-wrote")
elif verb == ("comments", "delete"):
    for rows in comments.values():
        rows[:] = [row for row in rows if row["id"] != args[2]]
    store.write_text(json.dumps(world))
    print(json.dumps({"success": True, "identifier": None, "url": None, "data": {"success": True}}))
elif verb == ("comments", "bulk-list"):
    assert args[2:] == ["--stdin", "--format=safe"] and refs
    assert all(ref in issues for ref in refs)
    if mode == "legacy-unavailable":
        sys.exit(5)
    rows = {ref: comments.get(ref, []) for ref in refs}
    if mode == "legacy-incomplete":
        rows.pop(refs[-1])
    if mode == "legacy-malformed":
        rows[refs[-1]] = None
    print(json.dumps(rows))
elif verb == ("comments", "list"):
    assert args[2] in issues
    print(json.dumps(comments.get(args[2], [])))
else:
    sys.exit(9)
'''


def box(source, ask, text, delivered=None):
    """The outcome line workflows/tasks.md names, written out independently of the writer."""
    if delivered is None:
        return "- [ ] Jarvis outcome %s ask %d: %s\n" % (source, ask, text)
    return "- [x] Jarvis outcome %s ask %d: %s\n  Evidence: delivered %s\n" % (source, ask, text, delivered)


def state_handoff(state):
    """A handoff whose State section holds state from line 5."""
    return ("# Handoff\n\n## State\n\n" + state + "Checkpoint: checked 2000-01-01; session control; log none\n\n## Sub-agents\n\nnone\n\n## Instructions in force\n\nnone\n\n"
            "## Progress log\n\n")


def install_tracker(packages):
    stub = packages / "linear/scripts/linear.sh"
    stub.parent.mkdir(parents=True)
    stub.write_text(LINEAR)
    stub.chmod(0o755)
    return stub


def rebuild_state(checkpoint, rows, apply=change_state):
    lines = checkpoint.splitlines(keepends=True)
    for row in rows:
        lines = apply(lines, row["State change"], row["id"])
    return [entry for _, entry in state_entries(lines)]


class ProgressLogCommands(MailWorld):
    scripts = SCRIPTS

    def progress(self, *args, cwd=None):
        return self.command([sys.executable, "-B", self.scripts / "progress-log", *args], cwd or self.home)

    def log(self, fields=FIELDS, cwd=None, handoff=None):
        args = [arg for pair in fields.items() for arg in pair]
        if handoff is not None:
            args += ["--handoff", str(handoff)]
        return self.progress(*args, cwd=cwd)

    def action_args(self, *, discover=False, action=ACTION, state_key=None, source=REQUEST, ask=1, delivered=None,
                    item="KEN-1", outcome=OUTCOME):
        fields = {key: value for key, value in FIELDS.items() if key != "--state-change"}
        fields.update({"--next-action": action, "--source": source, "--ask": str(ask)})
        if discover:
            fields.update({"--task-project": PROJECT, "--outcome": outcome})
        else:
            fields["--item"] = item
        if state_key is not None:
            fields["--state-key"] = state_key
        if delivered is not None:
            fields["--delivered"] = delivered
        return fields

    def next_action(self, *, handoff=None, **action):
        return self.log(self.action_args(**action), handoff=handoff)


class ProgressLog(ProgressLogCommands):
    def setUp(self):
        super().setUp()
        self.home = make_project(self.root / "home", overseer=False)
        for name in ("CONFIG", "DATA", "STATE", "CACHE"):
            self.env["XDG_" + name + "_HOME"] = str(self.root / name.lower())
        self.handoff = self.home / "state/handoff.md"
        self.handoff.parent.mkdir()
        self.executable("date", "#!/bin/sh\necho " + STAMP + "\n")

    def action_world(self, issues=None, comments=None, mode=""):
        packages = self.root / "action-packages"
        scripts = packages / "jarvis/scripts"
        guard = packages / "routing-guard.sh"
        if not scripts.exists():
            shutil.copytree(self.scripts, scripts)
            install_tracker(packages)
            # The function is shell-only. Keep the checkout's routing check
            # without loading auth for this stub.
            start = "\nrequire_agent_routing_label() {\n"
            source = (LINEAR_SCRIPTS / "commands/issues.sh").read_text()
            self.assertEqual(source.count(start), 1)
            body, close, _ = source.split(start, 1)[1].partition("\n}\n")
            self.assertTrue(close)
            guard.write_text(start.lstrip() + body + close)
        self.scripts = scripts
        self.action_store = self.root / "linear-world.json"
        self.action_trace = self.root / "linear-calls"
        self.action_trace.write_text("")
        self.action_store.write_text(json.dumps({"project": PROJECT, "created": "KEN-2",
                                                 "bash": LINEAR_BASH,
                                                 "validator": str(LINEAR_SCRIPTS / "lib/issue-validation.sh"), "routing_guard": str(guard),
                                                 "issues": issues if issues is not None else {"KEN-1": self.issue()},
                                                 "comments": comments or {}, "mode": mode}))

    def issue(self, item="KEN-1", title=OUTCOME, description=""):
        return {"id": item, "title": title, "description": description, "project_id": PROJECT}

    def action_calls(self, full=False):
        return [tuple(args + refs if full else args[:2])
                for args, refs in map(json.loads, self.action_trace.read_text().splitlines())]

    def world(self):
        return json.loads(self.action_store.read_text())

    def assert_action(self, item, action, state_change, ask=1):
        body = self.world()["issues"][item]["description"]
        self.assertEqual(body.splitlines().count(box(REQUEST, ask, action).rstrip("\n")), 1, body)
        saved = records(self.handoff.read_text())[-1]
        self.assertEqual(saved["State change"], state_change)
        self.assertIn("%s outcome=%s ask=%d" % (item, REQUEST, ask), saved["Observed result and source"])

    def test_next_action_named(self):
        for key in ("KEN-1", "KEN-1:", "`KEN-1`", "`" + REQUEST + ":`"):
            with self.subTest(key=key):
                target = REQUEST if REQUEST in key else "KEN-1"
                kept = "- session=control: retained\n"
                self.handoff.write_text(state_handoff("- `" + target + "`: retry\n  earlier context\n" + kept))
                self.action_world()
                result = self.next_action(state_key=key)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_action("KEN-1", ACTION, "remove State " + target)
                self.assertEqual(state_entries(self.handoff.read_text().splitlines(keepends=True))[0][1], kept)
                self.assertEqual(self.action_calls(), NAMED_READBACK)
        result = self.next_action(action="Check with the vendor after approval.")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_action("KEN-1", "Check with the vendor after approval.", "none")
        self.assertNotIn(ACTION, self.world()["issues"]["KEN-1"]["description"])
        self.assertEqual(len(records(self.handoff.read_text())), 2)
        self.assertEqual(self.action_calls(), NAMED_READBACK + NAMED_READBACK)

    def test_next_action_discovery(self):
        kept = "- session=control: retained\n"
        self.handoff.write_text(state_handoff("- " + REQUEST + ": retry\n" + kept))
        self.action_world(issues={
            "KEN-1": self.issue(description="Jarvis request source: " + REQUEST + "\n\n"
                                            "Jarvis requested outcome: Send the invoice"),
            "KEN-3": self.issue("KEN-3", description="Jarvis request source: " + OTHER_REQUEST + "\n\n"
                                                     "Jarvis requested outcome: " + OUTCOME),
        })
        first = self.next_action(discover=True, state_key=REQUEST)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assert_action("KEN-2", ACTION, "remove State " + REQUEST)
        self.assertEqual(state_entries(self.handoff.read_text().splitlines(keepends=True))[0][1], kept)
        second = self.next_action(discover=True, action="Ask the vendor to verify the receipt.")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assert_action("KEN-2", "Ask the vendor to verify the receipt.", "none")
        # A second ask of the request stays on its matter's item: a repeat
        # discovery with that ask's own outcome finds the item by its line.
        later = {"action": "Jarvis sends the receipt to the user.", "ask": 2}
        third = self.next_action(item="KEN-2", **later)
        self.assertEqual(third.returncode, 0, third.stderr)
        fourth = self.next_action(discover=True, outcome="Send the receipt to the user", **later)
        self.assertEqual(fourth.returncode, 0, fourth.stderr)
        self.assert_action("KEN-2", later["action"], "none", ask=2)
        self.assertEqual(sorted(self.world()["issues"]), ["KEN-1", "KEN-2", "KEN-3"])
        self.assertEqual(self.action_calls(), [
            ("issues", "list"), ("comments", "bulk-list"), ("auth-check", "--strict"), ("issues", "create"), ("issues", "get"),
            *NAMED_READBACK[1:],
            ("issues", "list"), *NAMED_READBACK[1:],
            *NAMED_READBACK,
            ("issues", "list"), ("issues", "get"), ("comments", "list")])

    def test_issue_guards_run_under_linear_bash(self):
        validator = self.root / "issue-validation.sh"
        source = (LINEAR_SCRIPTS / "lib/issue-validation.sh").read_text()
        start = "\nrequire_issue_header_shape() {\n"
        self.assertEqual(source.count(start), 1)
        # Lowercasing is Bash 4: it runs under the Bash linear.sh requires and
        # is a bad substitution under 3.2, so the probe shows which shell ran.
        validator.write_text(source.replace(start, start + '\tlocal probe=RAN; printf \'%s\\n\' "${probe,,}" >"$HOME/guard-probe"\n'))
        self.handoff.write_text(state_handoff("- " + REQUEST + ": retry\n"))
        self.action_world(issues={})
        world = json.loads(self.action_store.read_text())
        world["validator"] = str(validator)
        self.action_store.write_text(json.dumps(world))
        result = self.next_action(discover=True, state_key=REQUEST)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(("issues", "create"), self.action_calls())
        probe = self.root / "guard-probe"
        if LINEAR_BASH is None:
            self.assertFalse(probe.exists())
            self.skipTest(NO_LINEAR_BASH)
        self.assertEqual(probe.read_text(), "ran\n")

    def binding_cases(self):
        source = "Original request: [thread](" + REQUEST + ")"
        paired = [{"id": "binding", "body": source + "\nOutcome: " + OUTCOME}]
        return (
            ("description-source-and-title", self.issue(description=source), [], "KEN-1"),
            ("one-source-across-records", self.issue(title="Vendor follow-up", description=source),
             [{"id": "outcome", "body": "Outcome: " + OUTCOME}], "KEN-1"),
            ("comment-source-and-title", self.issue(), [{"id": "source", "body": source}], "KEN-1"),
            ("legacy-comment-only", self.issue(title="Vendor follow-up"), paired, "KEN-1"),
            ("legacy-description-and-later-binding",
             self.issue(title="Vendor follow-up", description="Original request: `" + OTHER_REQUEST +
                                                              "`\nOutcome: Send the invoice"), paired, "KEN-1"),
            ("unrelated-action-cites-request",
             self.issue(description="Original request: " + OTHER_REQUEST + "\nOutcome: " + OUTCOME),
             [{"id": OTHER_COMMENT, "body": "Jarvis next action: Read the reply to " + REQUEST +
                                            " before following up on the vendor receipt.\n"}], "KEN-2"),
            ("canonical-description-and-later-binding",
             self.issue(title="Vendor follow-up", description="Jarvis request source: " + OTHER_REQUEST +
                                                              "\n\nJarvis requested outcome: Send the invoice"),
             paired, "KEN-1"),
            ("canonical-description-and-different-outcome",
             self.issue(title="Vendor follow-up", description="Jarvis request source: " + REQUEST +
                                                              "\n\nJarvis requested outcome: Send the invoice"),
             paired, "KEN-1"),
        )

    def assert_binding_case(self, issue, comments, expected_item):
        self.handoff.write_text(state_handoff("- " + REQUEST + ": retry\n"))
        self.action_world(issues={"KEN-1": issue, "KEN-3": self.issue("KEN-3", title="Different work")},
                          comments={"KEN-1": comments})
        result = self.next_action(discover=True, state_key=REQUEST)
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = records(self.handoff.read_text())[-1]
        item = saved["Observed result and source"].splitlines()[-1].split()[3]
        self.assertEqual(item, expected_item, "discovery chose the wrong binding")
        self.assertEqual(saved["State change"], "remove State " + REQUEST)
        bulk, = [call for call in self.action_calls(full=True) if call[:2] == ("comments", "bulk-list")]
        self.assertEqual(bulk[2:], ("--stdin", "--format=safe", "KEN-1", "KEN-3"))
        world = self.world()
        self.assertEqual(world["comments"], {"KEN-1": comments})
        self.assertIn(box(REQUEST, 1, ACTION).rstrip("\n"), world["issues"][expected_item]["description"].splitlines())
        self.assertEqual(self.action_calls().count(("issues", "create")), int(expected_item != "KEN-1"))

    def test_next_action_binding_evidence(self):
        for name, *case in self.binding_cases():
            with self.subTest(case=name):
                self.assert_binding_case(*case)

    def test_next_action_discovery_refusals(self):
        before = state_handoff("- " + REQUEST + ": retry\n").encode()
        cases = (
            ("legacy-incomplete", "tracker-unread=comments bulk-list", "bulk-list"),
            ("legacy-malformed", "tracker-unread=comments bulk-list", "bulk-list"),
            ("legacy-unavailable", "tracker-unavailable=comments bulk-list", "bulk-list"),
            ("no-team", "tracker-team-missing=LINEAR_TEAM", "--strict"),
        )
        for mode, diagnostic, last in cases:
            with self.subTest(mode=mode):
                self.handoff.write_bytes(before)
                issues = None
                if mode == "no-team":
                    issues = {}
                elif mode == "legacy-incomplete":
                    issues = {"KEN-1": self.issue(description="Jarvis request source: " + REQUEST +
                                                              "\n\nJarvis requested outcome: " + OUTCOME)}
                self.action_world(issues=issues, mode=mode)
                result = self.next_action(discover=True, state_key=REQUEST)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertTrue(result.stderr.startswith("progress-log: " + diagnostic + " "), result.stderr)
                self.assertEqual(self.handoff.read_bytes(), before)
                command = ("auth-check", last) if mode == "no-team" else ("comments", last)
                self.assertEqual(self.action_calls(), [("issues", "list"), command])
                if mode == "no-team":
                    self.assertRegex(result.stderr, r"fix=\S+/workflows/setup-linear\.md#steps\n$")

    def test_next_action_refusals(self):
        changed = NAMED_READBACK[:-1] + NAMED_READBACK[1:-1]
        for mode, diagnostic, calls in (
            ("update-unavailable", "tracker-unavailable=issues update", NAMED_WRITE),
            ("lost-update", "tracker-unavailable=issues update", NAMED_WRITE),
            ("readback-unavailable", "tracker-unavailable=issues get", NAMED_READBACK[:-1]),
            ("wrong-body", "tracker-body-changed=KEN-1", changed),
        ):
            with self.subTest(mode=mode):
                result = self.assert_next_action_refusal(mode, diagnostic, calls)
                resume = result.stderr.rstrip("\n").partition(" resume=")[2]
                if mode == "wrong-body":
                    args = [arg for pair in self.action_args().items() for arg in pair]
                    self.assertEqual(shlex.split(resume), [str(self.scripts / "progress-log"), *args])
                else:
                    self.assertEqual(resume, "")
        world = self.world()
        world["mode"] = ""
        self.action_store.write_text(json.dumps(world))
        result = self.next_action()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_action("KEN-1", ACTION, "remove State KEN-1")
        self.assertEqual(self.action_calls(), changed + NAMED_READBACK)

    def assert_next_action_refusal(self, mode, diagnostic, calls):
        before = state_handoff("- KEN-1: retry\n").encode()
        self.handoff.write_bytes(before)
        self.action_world(mode=mode)
        result = self.next_action()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertTrue(result.stderr.startswith("progress-log: " + diagnostic + " "), result.stderr)
        self.assertEqual(self.handoff.read_bytes(), before)
        self.assertEqual(self.action_calls(), calls)
        return result

    def test_next_action_writes_nothing_when_ambiguous(self):
        marker = "Jarvis request source: " + REQUEST + "\n\nJarvis requested outcome: " + OUTCOME
        before = state_handoff("- KEN-1: retry\n").encode()
        for issues, comments, discover, local, reason in (
            ({"KEN-1": self.issue(description=marker), "KEN-2": self.issue("KEN-2", description=marker)}, {}, True,
             before, "tracker-item-ambiguous=KEN-1,KEN-2"),
            ({"KEN-1": self.issue(title="Vendor follow-up", description="Original request: " + REQUEST)}, {}, True,
             before, "tracker-item-ambiguous=KEN-1"),
            ({"KEN-1": self.issue(description="Original request: " + REQUEST + "\nOutcome: " + OUTCOME)},
             {"KEN-1": [{"id": "outcome", "body": "Outcome: Send the invoice"}]}, True,
             before, "tracker-item-ambiguous=KEN-1"),
            ({"KEN-1": self.issue(title="Vendor follow-up", description="Original request: " + OTHER_REQUEST)},
             {"KEN-1": [{"id": "source", "body": "Original request: " + REQUEST},
                        {"id": "result", "body": "Outcome: " + OUTCOME}]}, True,
             before, "tracker-item-ambiguous=KEN-1"),
            ({"KEN-1": self.issue(description=OPENING + box(REQUEST, 1, "first") + box(REQUEST, 1, "second"))}, {},
             False, before, "tracker-line-ambiguous=KEN-1"),
            (None, {}, False, state_handoff("- KEN-1: retry\n- `KEN-1`: retry\n").encode(), "state-entry-ambiguous=KEN-1"),
        ):
            with self.subTest(reason=reason):
                self.handoff.write_bytes(local)
                self.action_world(issues, comments)
                result = self.next_action(discover=discover)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(result.stderr.split(" (", 1)[0].split(" fix=", 1)[0], "progress-log: " + reason)
                self.assertEqual(self.handoff.read_bytes(), local)
                self.assertTrue(all(verb in ("get", "list", "bulk-list") for _, verb in self.action_calls()))

    def outcome_cases(self):
        """Each case's writes in order: (write, mode, the Done when lines after it, or None for a refusal).

        Every item starts with SIBLING, another outcome's line, and OLDER, an
        earlier comment; a write changes only its own outcome's lines.
        """
        asked = "Jarvis asks the vendor for the receipt."
        revised = "Jarvis asks the vendor for the corrected receipt."
        returned = "The vendor sent the receipt; Jarvis sends it to the user."
        later = "C0123ABC:1793515700.000200"
        return (
            ("two messages on one item", (
                ({}, "", [box(REQUEST, 1, asked)]),
                ({"source": later, "action": revised}, "", [box(REQUEST, 1, asked), box(later, 1, revised)]),
            )),
            ("two asks from one message", (
                ({}, "", [box(REQUEST, 1, asked)]),
                ({"ask": 2, "action": returned}, "", [box(REQUEST, 1, asked), box(REQUEST, 2, returned)]),
            )),
            ("a revision, then its delivery", (
                ({}, "", [box(REQUEST, 1, asked)]),
                ({"action": revised}, "", [box(REQUEST, 1, revised)]),
                ({"action": revised, "delivered": DELIVERY}, "", [box(REQUEST, 1, revised, DELIVERY)]),
            )),
            # The work is done once the vendor answers; the line stays open
            # until the result reaches the user.
            ("a result owed to the user", (
                ({}, "", [box(REQUEST, 1, asked)]),
                ({"action": returned}, "", [box(REQUEST, 1, returned)]),
                ({"action": returned, "delivered": DELIVERY}, "", [box(REQUEST, 1, returned, DELIVERY)]),
            )),
            # The write lands but its receipt is lost; the successor runs the same command.
            ("a failed write across a hand-over", (
                ({}, "lost-update", None),
                ({}, "", [box(REQUEST, 1, asked)]),
            )),
        )

    def test_outcome_lines(self):
        before = state_handoff("- KEN-1: retry\n")
        for name, writes in self.outcome_cases():
            with self.subTest(case=name):
                self.handoff.write_text(before)
                self.action_world(issues={"KEN-1": self.issue(description=OPENING + SIBLING + FILING)},
                                  comments={"KEN-1": OLDER})
                for write, mode, lines in writes:
                    world = self.world()
                    world["mode"] = mode
                    self.action_store.write_text(json.dumps(world))
                    held = self.handoff.read_text()
                    result = self.next_action(**{"action": "Jarvis asks the vendor for the receipt.", **write})
                    world = self.world()
                    self.assertEqual(world["comments"], {"KEN-1": OLDER})
                    if lines is None:
                        self.assertEqual(result.returncode, 2, result.stderr)
                        self.assertEqual(self.handoff.read_text(), held)
                        continue
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(world["issues"]["KEN-1"]["description"], OPENING + SIBLING + "".join(lines) + FILING)
                self.assertEqual(state_entries(self.handoff.read_text().splitlines(keepends=True)), [])

    def test_two_writers_keep_both_lines(self):
        self.action_world(issues={"KEN-1": self.issue(description=OPENING + SIBLING + FILING)},
                          comments={"KEN-1": OLDER})
        writes = {"A": {"action": "Jarvis asks the vendor for the receipt."},
                  "B": {"ask": 2, "action": "Jarvis sends the receipt to the user."}}
        running = {}
        for writer, write in writes.items():
            handoff = self.home / ("state/%s.md" % writer)
            handoff.write_text(state_handoff("- KEN-1: retry\n"))
            args = [arg for pair in self.action_args(**write).items() for arg in pair]
            running[writer] = subprocess.Popen(
                [sys.executable, "-B", self.scripts / "progress-log", *args, "--handoff", str(handoff)],
                cwd=self.home, env={**self.env, "STUB_WRITER": writer}, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True)
        for writer, process in running.items():
            _, stderr = process.communicate(timeout=60)
            self.assertEqual(process.returncode, 0, writer + ": " + stderr)
        # B's write replaced A's first one; A read that back and applied its line again.
        self.assertEqual(self.world()["issues"]["KEN-1"]["description"],
                         OPENING + SIBLING + box(REQUEST, 2, writes["B"]["action"])
                         + box(REQUEST, 1, writes["A"]["action"]) + FILING)
        self.assertEqual(self.world()["comments"], {"KEN-1": OLDER})

    def test_legacy_next_action_retires_after_readback(self):
        legacy = {"id": OTHER_COMMENT, "body": "Jarvis next action: Jarvis reads the vendor reply.\n"}
        for mode, kept in (("wrong-body", OLDER + [legacy]), ("", OLDER)):
            with self.subTest(mode=mode or "reads back"):
                self.handoff.write_text(state_handoff("- KEN-1: retry\n"))
                self.action_world(issues={"KEN-1": self.issue(description=OPENING + SIBLING + FILING)},
                                  comments={"KEN-1": OLDER + [legacy]}, mode=mode)
                result = self.next_action()
                self.assertEqual(result.returncode, 2 if mode else 0, result.stderr)
                self.assertEqual(self.world()["comments"], {"KEN-1": kept})
        self.assertEqual(self.action_calls()[-3:], [("comments", "list"), ("comments", "delete"), ("comments", "list")])
        self.assertIn("Retired comment=%s %s" % (OTHER_COMMENT, legacy["body"].strip()),
                      records(self.handoff.read_text())[-1]["Observed result and source"])

    def assert_home_check(self, expected, handoff=None):
        args = [] if handoff is None else ["--handoff", str(handoff)]
        result = self.command([sys.executable, "-B", self.scripts / "progress-log", *args], self.home)
        self.assertEqual(result.returncode, 1 if expected else 0, result.stderr)
        # The commit-lane diagnostic contract carries file, line and rule.
        actual = [tuple(line.split()[index].split("=", 1)[1] for index in (1, 2, 3))
                  for line in result.stderr.splitlines()]
        self.assertEqual(actual, expected)

    def test_home_structure(self):
        memory = self.home / "memory"
        memory.mkdir()
        note = memory / "facts.md"
        fields = "- Source: owner statement\n- Date: 2000-01-01\n- Supersedes: none\n"
        good = "# Facts\n\n### Access\n" + fields + "\nThe folder opens.\n"
        states = "- KEN-1: next\n- session=control: hold\n- wake=mail: wait\n- ask=owner: await reply\n"
        rows = []
        values = (("Source", "owner statement"), ("Date", "2000-01-01"), ("Supersedes", "none"))
        for shape in ("{field}:", "**{field}:**", "**{field}**:"):
            formatted = "".join("- " + shape.format(field=field) + " " + value + "\n" for field, value in values)
            populated = good.replace(fields, formatted)
            rows.append((shape + " populated", populated, states, []))
            inline = " · ".join(shape.format(field=field) + " " + value for field, value in values) + "\n"
            rows.append((shape + " inline", good.replace(fields, inline), states, []))
            for field, value in values:
                label = "- " + shape.format(field=field)
                for replacement in ("", label + " \t\n"):
                    rows.append((shape + " " + field, populated.replace(label + " " + value + "\n", replacement), states,
                                 [("memory/facts.md", "3", "memory-field-" + field.lower())]))
        rows.append(("idless", good, "- Call the vendor\n", [("state/handoff.md", "5", "state-id")]))
        rows.append(("checkpoint", good, "Checkpoint: checked 2000-01-01; log none\n" + states, []))
        rows.append(("predecessor", good, "Predecessor archive: [earlier](archive/earlier.md)\n" + states, []))
        archive = self.home / "state/archive/earlier.md"
        archive.parent.mkdir()
        archive.write_text("# Earlier handoff\n")
        self.assertEqual(self.command(["git", "add", "state/archive"], self.home).returncode, 0)
        for name, text, state, expected in rows:
            with self.subTest(row=name, text=text):
                note.write_text(text)
                self.handoff.write_text(state_handoff(state))
                staged = self.command(["git", "add", "memory", "state/handoff.md"], self.home)
                self.assertEqual(staged.returncode, 0, staged.stderr)
                # A good unstaged replacement must not hide the staged violation.
                note.write_text(good)
                self.handoff.write_text(state_handoff(states))
                self.assert_home_check(expected)
        # Index text is outside this structural contract; freshness is consumer policy.
        (memory / "MEMORY.md").write_text("# Memory index\nUnspecified row syntax is left alone.\n")
        self.assertEqual(self.command(["git", "add", "memory", "state/handoff.md"], self.home).returncode, 0)
        self.assert_home_check([])
        for selected in ("state/handoff.md", self.handoff):
            with self.subTest(selector=selected):
                result = self.command([sys.executable, "-B", self.scripts / "progress-log",
                                       "--handoff", str(selected)], self.home)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "")

    def test_initial_metadata_block(self):
        memory = self.home / "memory"
        memory.mkdir()
        note = memory / "facts.md"
        fields = ("Source: owner.", "Date: 2000-01-02.", "Supersedes: none.")
        rows = (
            ("inline", " ".join(fields) + "\n\nBody.\n", []),
            ("multiline", "\n".join(fields) + "\n\nBody.\n", []),
            ("leading blanks", "\n\n" + "\n".join(fields), []),
            ("split block", " ".join(fields[:2]) + "\n\nBody.\n\n" + fields[2],
             [("memory/facts.md", "1", "memory-field-supersedes")]),
            ("separated fields", " ".join(fields[:2]) + "\n\n" + fields[2],
             [("memory/facts.md", "1", "memory-field-supersedes")]),
            ("body first", "Body.\n\n" + " ".join(fields),
             [("memory/facts.md", "1", "memory-field-" + field) for field in ("source", "date", "supersedes")]),
        )
        for label, body, expected in rows:
            with self.subTest(row=label):
                note.write_text("### Fact\n" + body)
                self.assertEqual(self.command(["git", "add", "memory"], self.home).returncode, 0)
                note.write_text("### Fact\n" + " ".join(fields))
                self.assert_home_check(expected)

    def test_selected_commit_handoff(self):
        selected = self.home / "state/delegate/handoff.md"
        selected.parent.mkdir()
        good = state_handoff("- KEN-1: next\n")
        selected.write_text(good)
        archive = selected.parent / "archive/earlier.md"
        archive.parent.mkdir()
        default_archive = self.home / "state/archive/earlier.md"
        default_archive.parent.mkdir()
        default_archive.write_text("# Unrelated default archive\n")
        self.assertEqual(self.command(["git", "add", "--all"], self.home).returncode, 0)
        self.assertEqual(self.command(["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                                       "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                                       "commit", "-qm", "established selected handoff"], self.home).returncode, 0)
        for selector in ("state/delegate/handoff.md", selected):
            # session.md's replacement workflow archives beside the selected handoff.
            for label, content, tracked, expected in (
                    ("valid", good, False, []),
                    ("required section", good.replace("## Sub-agents", "## Other"), False,
                     [("state/delegate/handoff.md", "1", "handoff-sub-agents")]),
                    ("deleted", None, False,
                     [("state/delegate/handoff.md", "1", "recovery-entry-missing")]),
                    ("selected archive", state_handoff("Predecessor archive: [earlier](archive/earlier.md)\n"), True, []),
                    ("selected home-relative archive", state_handoff("Predecessor archive: [earlier](state/delegate/archive/earlier.md)\n"), True, []),
                    ("missing selected archive", state_handoff("Predecessor archive: [earlier](archive/earlier.md)\n"), False,
                     [("state/delegate/handoff.md", "5", "predecessor-archive")]),
                    ("missing home-relative selected archive", state_handoff("Predecessor archive: [earlier](state/delegate/archive/earlier.md)\n"), False,
                     [("state/delegate/handoff.md", "5", "predecessor-archive")]),
                    ("default home-relative archive", state_handoff("Predecessor archive: [earlier](state/archive/earlier.md)\n"), False, [])):
                with self.subTest(selector=selector, row=label):
                    if content is None:
                        selected.unlink()
                    else:
                        selected.write_text(content)
                    if tracked:
                        archive.write_text("# Selected predecessor\n")
                    else:
                        archive.unlink(missing_ok=True)
                    # Default violations are irrelevant when an override selects another file.
                    self.handoff.write_text("## State\n")
                    self.assertEqual(self.command(["git", "add", "--all"], self.home).returncode, 0)
                    selected.write_text(good)
                    # Neither an unstaged archive nor an unstaged deletion changes the candidate.
                    if tracked:
                        archive.unlink()
                    else:
                        archive.write_text("# Unstaged predecessor\n")
                    self.assert_home_check(expected, selector)
        self.assertEqual(self.command(["git", "add", "--all"], self.home).returncode, 0)
        self.assert_home_check([("state/handoff.md", "1", "handoff-sub-agents"),
                                ("state/handoff.md", "1", "handoff-section"),
                                ("state/handoff.md", "1", "handoff-section")])

    def test_predecessor_tracked_symlinks(self):
        archive = self.home / "state/archive"
        stored = self.home / "stored"
        stored.mkdir()
        (stored / "earlier.md").write_text("# Earlier handoff\n")
        self.handoff.write_text(state_handoff("Predecessor archive: [earlier](state/archive/earlier.md)\n"))
        rows = (("../stored", True, []),
                ("../stored", False, [("state/handoff.md", "5", "predecessor-archive")]),
                ("../../outside", True, [("state/handoff.md", "5", "predecessor-archive")]),
                ("archive", True, [("state/handoff.md", "5", "predecessor-archive")]))
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "earlier.md").write_text("# Outside handoff\n")
        for target, committed, expected in rows:
            with self.subTest(target=target, committed=committed):
                if archive.is_symlink():
                    archive.unlink()
                archive.symlink_to(target, target_is_directory=True)
                self.assertEqual(self.command(["git", "add", "state", "stored"], self.home).returncode, 0)
                if not committed:
                    self.assertEqual(self.command(["git", "rm", "--cached", "stored/earlier.md"], self.home).returncode, 0)
                # The index owns resolution, even with an unstaged link replacement.
                archive.unlink()
                archive.symlink_to("../stored" if expected else "../../outside", target_is_directory=True)
                self.assert_home_check(expected)

    def test_home_relations(self):
        # Notes 24; Handoff 34; Progress records 87; replacement 102.
        memory = self.home / "memory"
        memory.mkdir()
        old = "### Prior\nSource: owner · Date: 2000-01-01 · Supersedes: none\n"
        new = "### Current\nSource: owner · Date: 2000-01-01 · Supersedes: [Prior](facts.md#prior)\n"
        good = old + "Replaced by: note=Current\n" + new
        rows = (
            ("retained", good, state_handoff("- KEN-1: next\n"), []),
            ("missing prior", new, state_handoff("- KEN-1: next\n"),
             [("memory/facts.md", "1", "memory-supersedes")]),
            ("missing linked file", new.replace("facts.md#prior", "absent.md#prior"), state_handoff("- KEN-1: next\n"),
             [("memory/facts.md", "1", "memory-supersedes")]),
            ("free-form prior", good.replace("[Prior](facts.md#prior)", "Prior in facts.md"),
             state_handoff("- KEN-1: next\n"), []),
            ("split legacy marking", old + "Superseded.\nReplacement: Current.\n" + new.replace("[Prior](facts.md#prior)", "Prior in facts.md"),
             state_handoff("- KEN-1: next\n"), []),
            ("historical marking required", old + new, state_handoff("- KEN-1: next\n"),
             [("memory/facts.md", "3", "memory-replaced-current")]),
            ("file link", good.replace("[Prior](facts.md#prior)", "[old subject](facts.md)"),
             state_handoff("- KEN-1: next\n"), []),
            ("optional link title", good.replace("[Prior](facts.md#prior)", '[Prior](facts.md#prior "Historical note")'),
             state_handoff("- KEN-1: next\n"), []),
            ("external source", good.replace("[Prior](facts.md#prior)", "[prior](https://example.com/facts#prior)"),
             state_handoff("- KEN-1: next\n"), []),
            ("duplicate", good, state_handoff("- KEN-1: next\n- KEN-1: other\n"),
             [("state/handoff.md", "6", "state-entry-ambiguous")]),
            ("duplicate colon spelling", good, state_handoff("- KEN-1: next\n- KEN-1:: other\n"),
             [("state/handoff.md", "6", "state-entry-ambiguous")]),
            ("duplicate backtick spelling", good, state_handoff("- KEN-1: next\n- `KEN-1`: other\n"),
             [("state/handoff.md", "6", "state-entry-ambiguous")]),
            ("missing agents", good, state_handoff("- KEN-1: next\n").replace("## Sub-agents", "## Others"),
             [("state/handoff.md", "1", "handoff-sub-agents")]),
            ("missing archive", good, state_handoff("Predecessor archive: [earlier](archive/earlier.md)\n"),
             [("state/handoff.md", "5", "predecessor-archive")]),
        )
        for name, note, handoff, expected in rows:
            with self.subTest(row=name):
                (memory / "facts.md").write_text(note)
                self.handoff.write_text(handoff)
                self.assertEqual(self.command(["git", "add", "memory", "state/handoff.md"], self.home).returncode, 0)
                self.assert_home_check(expected)

    def test_recovery_contract(self):
        self.assert_home_check([])  # No committed recovery entry points in a new home.
        # Synthetic controls from KEN-5209's approved package/consumer table.
        current = "### Alpha\nSource: owner. Date: 2000-01-02. Supersedes: none.\n"
        checkpoint = "Checkpoint: 2000-01-02T00:00:00Z, session 2, log none\n"
        handoff = state_handoff("- SESSION 2 session=2 pane=current\n").replace(
            "Checkpoint: checked 2000-01-01; session control; log none\n", checkpoint)
        index = "# Memory\n\n| Location | Read when |\n|---|---|\n| [Facts](facts.md) | Before matching work |\n"
        base = {"memory/facts.md": current, "memory/MEMORY.md": index, "state/handoff.md": handoff}
        for name, text in base.items():
            path = self.home / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.assertEqual(self.command(["git", "add", "--all"], self.home).returncode, 0)
        self.assertEqual(self.command(["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                                       "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                                       "commit", "-qm", "established recovery"], self.home).returncode, 0)
        replaced = current + "Replaced by: note=Beta\n" + current.replace("Alpha", "Beta").replace("none.", "note=Alpha.")
        rows = [
            ("metadata history", {"memory/facts.md": "### Alpha\n#### History\n" + current.split("\n", 1)[1]}, "memory-field-source"),
            ("ambiguous heading", {"memory/facts.md": replaced + current}, "memory-supersedes"),
            ("unknown heading", {"memory/facts.md": current.replace("none.", "note=Unknown note.")}, "memory-supersedes"),
            ("undated self", {"memory/facts.md": current.replace("none.", "prior-version: undated.")}, "memory-self-date"),
            ("still current", {"memory/facts.md": replaced.replace("Replaced by: note=Beta\n", "")}, "memory-replaced-current"),
            ("index subject", {"memory/MEMORY.md": index + "\n### Unsourced\n"}, "memory-field-source"),
            ("established index", {"memory/MEMORY.md": None}, "recovery-entry-missing"),
            ("established store", {"memory/MEMORY.md": None, "memory/facts.md": None}, "recovery-entry-missing"),
            ("copied session", {"state/handoff.md": handoff.replace("SESSION 2 session=2", "SESSION 0 session=0")}, "session-checkpoint"),
            ("duplicate session", {"state/handoff.md": handoff.replace("## Sub-agents", "- SESSION 2 ask=second\n\n## Sub-agents")}, "session-ambiguous"),
            ("missing session checkpoint", {"state/handoff.md": handoff.replace("session 2", "no session")}, "session-checkpoint"),
            ("established handoff", {"state/handoff.md": None}, "recovery-entry-missing"),
            ("duplicate section", {"state/handoff.md": handoff + "\n## Instructions in force\n"}, "handoff-section"),
        ]
        accepted = [
            ("explicit replacement", {"memory/facts.md": replaced}),
            ("dated self", {"memory/facts.md": current.replace("none.", "prior-version: 2000-01-01.")}),
            ("qualified duplicate across files", {"memory/other.md": current,
                "memory/facts.md": replaced.replace("note=Alpha.", "[Alpha](facts.md#alpha).")}),
            ("consumer legacy identity", {"memory/facts.md": current.replace("none.", "Alpha in old records.")}),
            ("routing layout", {"memory/MEMORY.md": index.replace("| Read when |", "| Read when | Extra |")}),
            ("empty State", {"state/handoff.md": state_handoff("")}),
        ]
        # Each rule retains its own plain-current acceptance paired with refusal.
        cases = [(name + " plain current", {}, None) for name, _, _ in rows] + rows
        cases += [(name, changes, None) for name, changes in accepted]
        for name, changes, refusal in cases:
            with self.subTest(row=name):
                contents = dict(base, **changes)
                for path in (self.home / "memory").glob("*.md"):
                    path.unlink()
                if self.handoff.exists():
                    self.handoff.unlink()
                for relative, text in contents.items():
                    if text is not None:
                        (self.home / relative).write_text(text)
                self.assertEqual(self.command(["git", "add", "--all"], self.home).returncode, 0)
                result = self.command([sys.executable, "-B", self.scripts / "progress-log"], self.home)
                kinds = [line.split("rule=", 1)[1].split()[0] for line in result.stderr.splitlines() if "rule=" in line]
                self.assertEqual(result.returncode, 1 if refusal else 0, result.stderr)
                if refusal:
                    self.assertIn(refusal, kinds, result.stderr)
                else:
                    self.assertEqual(kinds, [])

    def test_session_writer_checkpoint(self):
        # progress-log's State writer is the producer; the commit lane reads its output.
        rows = (
            ("named session", "", "session=control", "Hold", "control"),
            # A trailing colon is key spelling; an inner one is part of the id.
            ("named session colon id", "", "session=control:west:", "Hold", "control:west"),
            ("named ask", "", "ask=owner", "Hold session=control", "control"),
            ("bare session", "- session=control Hold\n", None, None, "control"),
            ("SESSION label", "- SESSION control session=control\n", None, None, "control"),
            ("standalone SESSION", "- SESSION control\n", None, None, "control"),
        )
        for name, initial, key, action, identity in rows:
            for checkpoint in (identity, "different"):
                with self.subTest(row=name, checkpoint=checkpoint):
                    source = state_handoff(initial).replace("session control;", "session " + checkpoint + ";")
                    self.handoff.write_text(source)
                    if key is not None:
                        result = self.log(dict(FIELDS, **{"--state-change": "set State " + key + " " + action}))
                        self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(self.command(["git", "add", "state/handoff.md"], self.home).returncode, 0)
                    checked = self.command([sys.executable, "-B", self.scripts / "progress-log"], self.home)
                    self.assertEqual(checked.returncode, 0 if checkpoint == identity else 1, checked.stderr)
                    rules = [line.split("rule=", 1)[1].split()[0] for line in checked.stderr.splitlines()]
                    self.assertEqual(rules, [] if checkpoint == identity else ["session-checkpoint"])

    def test_home_structure_control(self):
        mutations = (
            ('for field in ("Source", "Date", "Supersedes", "Replaced by"):', 'for field in ():', "test_home_structure"),
            ('selected = os.path.relpath(handoff, home)', 'selected = str(DEFAULT_HANDOFF)',
             "test_selected_commit_handoff"),
            ('os.path.relpath(archive_dir(handoff) / path.removeprefix("archive/"), home)', '"state/" + path',
             "test_selected_commit_handoff"),
            ('if not tracked_archive(home, target, tracked):', 'if target not in tracked:',
             "test_predecessor_tracked_symlinks"),
        )
        for old, new, method in mutations:
            with self.subTest(mutation=new), tempfile.TemporaryDirectory(dir=self.root) as folder:
                copy = Path(folder) / "jarvis/scripts"
                shutil.copytree(SCRIPTS, copy)
                script = copy / "progress-log"
                source = script.read_text()
                self.assertEqual(source.count(old), 1)
                script.write_text(source.replace(old, new))
                case = ProgressLog(methodName=method)
                case.scripts = copy
                case.setUp()
                try:
                    with self.assertRaises(AssertionError):
                        getattr(case, method)()
                finally:
                    case.doCleanups()

    def test_records(self):
        # Each row: handoff text, fields, then the whole expected handoff or
        # the refusal. owner-unanswered and the successor read this form.
        record = ("- Id and time: P-20261018T230501Z " + STAMP + "\n  - Operation: Reply to 1791680510\n"
                  "  - Observed result and source: sent, receipt id=1\n  - Decision: answer now\n"
                  "  - State change: none\n")
        unterminated = HANDOFF.replace("\n\n## Notes\n\nlast\n", "")
        rows = (
            ("appends", HANDOFF, FIELDS,
             HANDOFF.replace("none\n\n## Notes", "none\n" + record + "\n## Notes")),
            ("unterminated", unterminated, FIELDS, unterminated + "\n" + record),
            ("empty section", "## Progress log", FIELDS, "## Progress log\n\n" + record),
            ("empty operation", HANDOFF, dict(FIELDS, **{"--operation": " "}), "field-empty=operation"),
            ("empty decision", HANDOFF, dict(FIELDS, **{"--decision": ""}), "field-empty=decision"),
            ("typed time", HANDOFF, dict(FIELDS, **{"--result": "23:04Z sent"}), "time-typed=observed-result-and-source"),
            ("typed stamp", HANDOFF, dict(FIELDS, **{"--operation": "2026-10-18T23:04 reply"}), "time-typed=operation"),
            ("no section", HANDOFF.replace("## Progress log", "## Log"), FIELDS, "section-missing=Progress log"),
            ("ambiguous section", HANDOFF + "\n## Progress log\n", FIELDS, "section-ambiguous=Progress log"),
        )
        for name, text, fields, expected in rows:
            with self.subTest(row=name):
                self.handoff.write_text(text)
                result = self.log(fields)
                if not expected.startswith(("#", "- ")):
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertTrue(result.stderr.startswith("progress-log: " + expected + " fix="), result.stderr)
                    self.assertTrue(result.stderr.split(" fix=", 1)[1].strip().endswith("long-session.md#progress-records"))
                    self.assertEqual(self.handoff.read_text(), text)
                    continue
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.handoff.read_text(), expected)
                self.assertEqual(records(expected)[-1]["at"], STAMP)
        # A second record in the same second keeps a distinct id.
        self.handoff.write_text(HANDOFF)
        self.assertEqual(self.log().returncode, 0)
        self.assertEqual(self.log().returncode, 0)
        self.assertEqual([row["id"] for row in records(self.handoff.read_text())][1:],
                         ["P-20261018T230501Z", "P-20261018T230501Z-2"])

    def assert_state_change(self, change, expected):
        result = self.log(dict(FIELDS, **{"--state-change": change}))
        self.assertEqual(result.returncode, 0, result.stderr)
        text = self.handoff.read_text()
        self.assertEqual([entry for _, entry in state_entries(text.splitlines(keepends=True))], expected)
        self.assertEqual(records(text)[-1]["State change"], change)
        return text

    def test_state_replacement_and_removal(self):
        retained = '- session=control: Runs on control; hold review for KEN-1; wake=mail; report covered through C1:1791680510.123\n'
        old = state_handoff(retained + '- KEN-1: old next action\n  old account that must go\n')
        self.handoff.write_text(old)
        replacement = '- KEN-1: Read the reply (record=P-20261018T230501Z)\n'
        self.assert_state_change('set State KEN-1 Read the reply', [retained, replacement])
        self.assert_state_change('remove State KEN-1', [retained])
        self.assert_state_change('set State KEN-2 Retry unread evidence',
                                 [retained, '- KEN-2: Retry unread evidence (record=P-20261018T230501Z-3)\n'])
        # A disabled writer must fail the same production-output assertion.
        with tempfile.TemporaryDirectory(dir=self.root) as folder:
            copy = Path(folder) / 'jarvis'
            shutil.copytree(SCRIPTS.parent / 'scripts', copy / 'scripts')
            script = copy / 'scripts/progress-log'
            source = script.read_text()
            target = 'return change_state(lines, change, identity), change'
            self.assertEqual(source.count(target), 1)
            script.write_text(source.replace(target, 'return list(lines), change'))
            original, self.scripts = self.scripts, copy / 'scripts'
            try:
                self.handoff.write_text(old)
                with self.assertRaises(AssertionError):
                    self.assert_state_change('set State KEN-1 Read the reply', [retained, replacement])
            finally:
                self.scripts = original

    def test_state_change_refusals_write_nothing(self):
        rows = (
            ('set State KEN-1', HANDOFF, 'state-change-invalid'),
            ('remove State KEN-1 extra', HANDOFF, 'state-change-invalid'),
            ('set State KEN-1 next\nsecond action', HANDOFF, 'state-change-invalid'),
            ('set State KEN-1 next', HANDOFF.replace('## State', '## Other'), 'section-missing'),
            ('set State KEN-1 next', HANDOFF + '\n## State\n', 'section-ambiguous'),
            ('set State KEN-1 next', state_handoff('- KEN-1: first\n- KEN-1: second\n'), 'state-entry-ambiguous'),
        )
        for change, before, key in rows:
            with self.subTest(change=change, key=key):
                self.handoff.write_text(before)
                result = self.log(dict(FIELDS, **{"--state-change": change}))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(result.stderr.split('=', 1)[0], 'progress-log: ' + key)
                self.assertEqual(self.handoff.read_text(), before)

    def test_state_key_spellings_name_one_entry(self):
        retained = '- KEN-2: keep\n'
        self.handoff.write_text(state_handoff(retained))
        for index, key in enumerate(('KEN-1', 'KEN-1:', '`KEN-1`')):
            with self.subTest(set=key):
                suffix = '' if index == 0 else '-' + str(index + 1)
                self.assert_state_change('set State %s step %d' % (key, index),
                                         [retained, '- KEN-1: step %d (record=P-20261018T230501Z%s)\n' % (index, suffix)])
        self.assert_state_change('remove State KEN-1', [retained])
        before = self.handoff.read_text()
        result = self.log(dict(FIELDS, **{"--state-change": 'remove State KEN-1'}))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stderr.split('=', 1)[0], 'progress-log: state-entry-missing')
        self.assertEqual(self.handoff.read_text(), before)
        # Openings earlier writers and agents stored, reached by every typed spelling.
        for stored in ('- KEN-1:: old\n', '- `KEN-1`: old\n'):
            for key in ('KEN-1', 'KEN-1:', '`KEN-1`'):
                with self.subTest(stored=stored, remove=key):
                    lines = state_handoff(retained + stored).splitlines(keepends=True)
                    removed = change_state(lines, 'remove State ' + key, 'P-1')
                    self.assertEqual([entry for _, entry in state_entries(removed)], [retained])

    def test_successor_rebuilds_checkpoint_and_later_records(self):
        # Each fixture is a checkpoint and later records, never the live home.
        rows = (
            ('session and wake', '- session=control: old location\n- wake=mail: old registration\n',
             [('set State session=control Runs on control; hold review; reports covered through C1:1791680510.123',
               '- session=control: Runs on control; hold review; reports covered through C1:1791680510.123'),
              ('set State wake=mail Wait for registered mailbox wake in run/mail',
               '- wake=mail: Wait for registered mailbox wake in run/mail')]),
            ('open ask', '- ask=C1:1791680510.123: old question\n',
             [('set State ask=C1:1791680510.123 Await answer to "Should we ship today?"',
               '- ask=C1:1791680510.123: Await answer to "Should we ship today?"')]),
            ('unfinished operation', '- KEN-1: old operation\n  old accumulated account\n',
             [('set State KEN-1 Read existing child output at run/child/result before resuming',
               '- KEN-1: Read existing child output at run/child/result before resuming')]),
            ('unavailable tracker read', '- KEN-1: old tracker evidence\n',
             [('set State KEN-1 Retry unavailable tracker read; evidence unread',
               '- KEN-1: Retry unavailable tracker read; evidence unread')]),
        )
        for name, checkpoint, changes in rows:
            with self.subTest(case=name):
                before = state_handoff(checkpoint)
                self.handoff.write_text(before)
                expected = []
                for index, (change, entry) in enumerate(changes):
                    result = self.log(dict(FIELDS, **{"--state-change": change}))
                    self.assertEqual(result.returncode, 0, result.stderr)
                    suffix = '' if index == 0 else '-' + str(index + 1)
                    expected.append(entry + ' (record=P-20261018T230501Z' + suffix + ')\n')
                actual = self.handoff.read_text()
                self.assertEqual(rebuild_state(before, records(actual)), expected)
                self.assertEqual([entry for _, entry in state_entries(actual.splitlines(keepends=True))], expected)

    def test_unwritable_and_subdirectory(self):
        result = self.log()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stderr.split("=", 1)[0], "progress-log: handoff-missing")
        self.assertFalse(self.handoff.exists())
        self.handoff.write_text(HANDOFF)
        self.handoff.chmod(0o444)
        try:
            result = self.log()
            self.assertEqual(result.returncode, 2)
            self.assertTrue(result.stderr.startswith("progress-log: handoff-unwritable="), result.stderr)
            self.assertEqual(self.handoff.read_text(), HANDOFF)
        finally:
            self.handoff.chmod(0o644)
        inside = self.home / "notes/deeper"
        inside.mkdir(parents=True)
        result = self.log(cwd=inside)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(records(self.handoff.read_text())), 2)
        self.assertFalse((inside / "state").exists())

    def test_selected_handoff(self):
        self.handoff.write_text(HANDOFF)
        selected = self.home / "state/delegate/handoff.md"
        selected.parent.mkdir()
        inside = self.home / "notes/deeper"
        inside.mkdir(parents=True)
        for target in ("state/delegate/handoff.md", selected):
            with self.subTest(target=target):
                selected.write_text(HANDOFF)
                for suffix in ("", "-2"):
                    result = self.log(cwd=inside, handoff=target)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    row = records(selected.read_text())[-1]
                    self.assertEqual(row["id"], "P-20261018T230501Z" + suffix)
                    self.assertEqual(row["at"], STAMP)
                    self.assertEqual(row["Operation"], FIELDS["--operation"])
                    self.assertEqual(row["Observed result and source"], FIELDS["--result"])
                    self.assertEqual(row["Decision"], FIELDS["--decision"])
                    self.assertEqual(row["State change"], FIELDS["--state-change"])
                before, after = HANDOFF.split("## Progress log", 1)[0], "## Notes\n\nlast\n"
                self.assertTrue(selected.read_text().startswith(before))
                self.assertTrue(selected.read_text().endswith(after))
                self.assertEqual(self.handoff.read_text(), HANDOFF)
        for text, mode, category in (
                (None, 0o644, "handoff-missing"),
                (HANDOFF, 0o444, "handoff-unwritable"),
                ("## State\nunchanged\n", 0o644, "section-missing"),
                (HANDOFF + "\n## Progress log\n", 0o644, "section-ambiguous")):
            with self.subTest(category=category):
                selected.unlink(missing_ok=True)
                if text is not None:
                    selected.write_text(text)
                    selected.chmod(mode)
                try:
                    result = self.log(cwd=inside, handoff="state/delegate/handoff.md")
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual(result.stderr.split("=", 1)[0], "progress-log: " + category)
                    if text is None:
                        self.assertFalse(selected.exists())
                    else:
                        self.assertEqual(selected.read_text(), text)
                    self.assertEqual(self.handoff.read_text(), HANDOFF)
                finally:
                    if selected.exists():
                        selected.chmod(0o644)
        # The selected-target assertions must reject a writer that ignores the option.
        with tempfile.TemporaryDirectory() as folder:
            copy = Path(folder) / "jarvis"
            shutil.copytree(SCRIPTS.parent / "scripts", copy / "scripts")
            script = copy / "scripts/progress-log"
            source = script.read_text()
            old = ", args.handoff), values)"
            self.assertEqual(source.count(old), 1)
            script.write_text(source.replace(old, ", DEFAULT_HANDOFF), values)"))
            scripts, self.scripts = self.scripts, copy / "scripts"
            try:
                with self.assertRaises(AssertionError):
                    selected.write_text(HANDOFF)
                    result = self.log(handoff=selected)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(records(selected.read_text())[-1]["at"], STAMP)
            finally:
                self.scripts = scripts

    def test_archive_index(self):
        # Each row: archived files under state/, the INDEX.md text before,
        # --handoff, --archived, then the INDEX.md text after or the
        # refusal. owner-unanswered reads this line to skip an archive.
        dated = ("## Progress log\n\n- Id and time: P-20261018T230559Z 2026-10-18T23:05:59Z\n  - Operation: later\n"
                 "- Id and time: P-20261017T220000Z 2026-10-17T22:00:00Z\n  - Operation: earlier\n")
        line = "- 2026/h.md dates=2026-10-17T22:00Z..2026-10-18T23:05Z\n"
        archive = self.home / "state/archive"
        rows = (
            ("dated", {"archive/2026/h.md": dated}, None, None, "state/archive/2026/h.md", line),
            ("absolute and appended", {"archive/2026/h.md": dated}, "- old.md dates=x..y", None,
             archive / "2026/h.md", "- old.md dates=x..y\n" + line),
            ("legacy entry", {"archive/l.md": dated + "- 22:00Z Handled 1791680510\n"}, None, None,
             "state/archive/l.md", "- l.md dates=unread..unread\n"),
            ("no record", {"archive/e.md": "# Handoff\n"}, None, None, "state/archive/e.md",
             "- e.md dates=unread..unread\n"),
            ("selected handoff", {"delegate/archive/h.md": dated}, None, "state/delegate/handoff.md",
             "state/delegate/archive/h.md", "- h.md dates=2026-10-17T22:00Z..2026-10-18T23:05Z\n"),
            ("outside the archive", {"handoff.md": dated}, None, None, "state/handoff.md", "archive-outside"),
            ("another handoff's archive", {"archive/h.md": dated}, None, "state/delegate/handoff.md",
             "state/archive/h.md", "archive-outside"),
            ("missing", {}, None, None, "state/archive/h.md", "archive-missing"),
            ("unreadable", {"archive/h.md": b"\xff"}, None, None, "state/archive/h.md", "archive-unreadable"),
        )
        for name, files, before, handoff, archived, expected in rows:
            with self.subTest(row=name):
                shutil.rmtree(self.home / "state", ignore_errors=True)
                for path, data in files.items():
                    target = self.home / "state" / path
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(data if isinstance(data, bytes) else data.encode())
                index = self.home / ("state/delegate/archive" if handoff else "state/archive") / "INDEX.md"
                if before is not None:
                    index.write_text(before)
                args = ["--archived", str(archived)] + (["--handoff", handoff] if handoff else [])
                result = self.command([sys.executable, "-B", self.scripts / "progress-log", *args], self.home)
                if not expected.startswith("- "):
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual(result.stderr.split("=", 1)[0], "progress-log: " + expected)
                    self.assertFalse(index.exists())
                    continue
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([row.split(" entries=", 1)[0] for row in index.read_text().splitlines()],
                                 expected.splitlines())
        # An INDEX.md that cannot take the line refuses.
        shutil.rmtree(self.home / "state")
        (archive / "INDEX.md").mkdir(parents=True)
        archive.joinpath("h.md").write_text(dated)
        result = self.command([sys.executable, "-B", self.scripts / "progress-log", "--archived",
                               "state/archive/h.md"], self.home)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stderr.split("=", 1)[0], "progress-log: index-unwritable")

    def test_archive_facts_and_import(self):
        # Retained facts are expected independently of the parser; the index
        # consumer can locate the archive and source entry before reading it.
        dated = ("## Progress log\n\n"
                 "- Id and time: P-20261017T220000Z 2026-10-17T22:00:00Z\n"
                 "  - Operation: Rule on KEN-12, owner C0123ABC:1793515695.587049 session=42\n"
                 "  - Observed result and source: checked KEN-12 session=ignored\n"
                 "  - Decision: session=42 session=group-a lesson retained\n"
                 "  - State change: none\n"
                 "- Id and time: P-20261018T230559Z 2026-10-18T23:05:59Z\n"
                 "  - Operation: Handle 1793515834-3208082-27491; 123 01234567-89ab-cdef-0123-456789abcdef\n"
                 "  - Observed result and source: unread\n"
                 "  - Decision: no reply\n"
                 "  - State change: none\n")
        facts = [{"id": "P-20261017T220000Z", "line": 3, "at": "2026-10-17T22:00:00Z",
                  "sessions": ["42", "group-a"], "trackers": ["KEN-12"], "messages": ["C0123ABC:1793515695.587049"]},
                 {"id": "P-20261018T230559Z", "line": 8, "at": "2026-10-18T23:05:59Z",
                  "sessions": "unread", "trackers": "unread", "messages": ["1793515834-3208082-27491"]}]
        legacy = "\n- 11:00Z Ruled on KEN-18 session=prior-7\n  owner 1793515834-3208082-27491\n"
        rows = (("dated", dated, facts, "2026-10-18T23:05Z"),
                ("legacy", dated + legacy, facts + [
                    {"id": "unread", "line": 14, "at": "unread", "sessions": ["prior-7"], "trackers": ["KEN-18"],
                     "messages": ["1793515834-3208082-27491"], "time": "11:00Z"}], None),
                ("unavailable facts", "# Retained archive\n", [], None))
        archive = self.home / "state/archive"
        archive.mkdir()
        source, index = archive / "a.md", archive / "INDEX.md"
        untouched = "- lost.md dates=unread..unread source=receipt-7\n"
        for name, text, expected, end in rows:
            with self.subTest(row=name):
                source.write_bytes(text.encode())
                index.write_text("# Archives\n" + untouched)
                command = [sys.executable, "-B", self.scripts / "progress-log", "--archived", "state/archive/a.md"]
                result = self.command(command, self.home)
                self.assertEqual(result.returncode, 0, result.stderr)
                retained = index.read_text()
                line = retained.splitlines()[-1]
                self.assertEqual(line.split()[1], "a.md")
                fields = dict(field.split("=", 1) for field in line.split()[2:])
                self.assertEqual(json.loads(fields["entries"]), expected)
                self.assertEqual(index_ends(retained), {"lost.md": None, "a.md": end})
                # Import the pre-enrichment row while preserving its provenance.
                original = ("# Archives\n" + line.split(" entries=", 1)[0] + " origin=retained source=entry-42\n"
                            "- a.md dates=unread..unread origin=older\n" + untouched)
                index.write_text(original)
                previous = None
                for _ in range(2):
                    result = self.command(command, self.home)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    imported = index.read_text()
                    self.assertEqual(result.stdout.split("indexed ", 1)[1], imported.splitlines()[1] + "\n")
                    self.assertEqual(imported.splitlines()[0], "# Archives")
                    imported_fields = dict(field.split("=", 1) for field in imported.splitlines()[1].split()[2:])
                    self.assertEqual(json.loads(imported_fields.pop("entries")), expected)
                    self.assertEqual(imported_fields, dict(dates=fields["dates"], origin="retained", source="entry-42"))
                    self.assertEqual(imported.splitlines()[2].split(" entries=", 1)[0],
                                     "- a.md dates=unread..unread origin=older")
                    self.assertEqual(index_ends(imported), {"a.md": None, "lost.md": None})
                    self.assertTrue(imported.endswith(untouched))
                    self.assertEqual(source.read_bytes(), text.encode())
                    if _:
                        self.assertEqual(imported, previous)
                    previous = imported
                # Missing or unreadable evidence keeps the retained index whole.
                for data, key in ((None, "archive-missing"), (b"\xff", "archive-unreadable")):
                    source.unlink(missing_ok=True)
                    if data is not None:
                        source.write_bytes(data)
                    result = self.command(command, self.home)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual(result.stderr.split("=", 1)[0], "progress-log: " + key)
                    self.assertEqual(index.read_text(), previous)

    def test_archive_facts_control(self):
        with tempfile.TemporaryDirectory() as folder:
            copy = Path(folder) / "scripts"
            shutil.copytree(SCRIPTS, copy)
            library = copy / "lib/progress.py"
            source = library.read_text()
            old = 'json.dumps(entries, separators=(",", ":"))'
            self.assertEqual(source.count(old), 1)
            library.write_text(source.replace(old, 'json.dumps([], separators=(",", ":"))'))
            case = ProgressLog(methodName="test_archive_facts_and_import")
            case.scripts = copy
            case.setUp()
            try:
                with self.assertRaises(AssertionError):
                    case.test_archive_facts_and_import()
            finally:
                case.doCleanups()

    def check(self, world, handoff=None):
        """Run --check-state from the installed copy of self.scripts beside a linear stub reading world."""
        packages = self.root / "packages"
        shutil.rmtree(packages, ignore_errors=True)
        shutil.copytree(self.scripts, packages / "jarvis/scripts")
        (self.root / "linear-calls").unlink(missing_ok=True)
        if world is not None:
            install_tracker(packages)
            issues = {}
            for ref, row in world.get("issues", {}).items():
                state, state_type = row[-2:]
                issues[ref] = {"id": row[0] if len(row) == 3 else ref, "title": "",
                               "state": state, "state_type": state_type}
            (self.root / "linear-world.json").write_text(json.dumps({**world, "issues": issues}))
        args = ["--check-state"] + (["--handoff", str(handoff)] if handoff else [])
        result = self.command([sys.executable, "-B", packages / "jarvis/scripts/progress-log", *args], self.home)
        calls = self.root / "linear-calls"
        return result, [json.loads(row) for row in calls.read_text().splitlines()] if calls.exists() else []

    def test_check_state(self):
        # Each row: State text, the tracker world (None: no linear package),
        # then the listed lines, the summary counts, the exit, the stderr key
        # and each bulk read's refs. The writer corrects what is listed.
        issues = {"KEN-1": DONE, "KEN-3": OPEN, "KEN-4": CANCELED, "KEN-5": DUPLICATE}
        rows = (
            ("closed and id-less listed", "- KEN-1 shipped\n- Call the vendor\n- KEN-3 in review\n", {"issues": issues},
             ["closed line=5 ids=KEN-1:Done", "unbound line=6"], (3, 1, 1, 0, 0), 0, None, [["KEN-1", "KEN-3"]]),
            ("both removed", "- KEN-3 in review\n", {"issues": issues}, [], (1, 0, 0, 0, 0), 0, None, [["KEN-3"]]),
            ("canceled", "- KEN-4 dropped\n", {"issues": issues}, ["closed line=5 ids=KEN-4:Canceled"],
             (1, 1, 0, 0, 0), 0, None, [["KEN-4"]]),
            ("duplicate", "- KEN-5 filed twice\n", {"issues": issues}, ["closed line=5 ids=KEN-5:Duplicate"],
             (1, 1, 0, 0, 0), 0, None, [["KEN-5"]]),
            ("mixed kept", "- KEN-1 and KEN-3\n", {"issues": issues}, [], (1, 0, 0, 0, 0), 0, None, [["KEN-1", "KEN-3"]]),
            ("open child keeps its parent, State ends at its heading", "- KEN-1 parent\n  - KEN-3 child\n\n## Notes\n- KEN-1 again\n",
             {"issues": issues}, [], (1, 0, 0, 0, 0), 0, None, [["KEN-1", "KEN-3"]]),
            ("mailbox and Slack ids bind", "- Reply to 1793515834-3208082-27491\n- Thread C0123ABC:1793515695.587049\n",
             {"issues": issues}, [], (2, 0, 0, 0, 0), 0, None, []),
            ("a date binds nothing", "- Checked 2026-11-02 at P-20261102T080000Z\n", {"issues": issues},
             ["unbound line=5"], (1, 0, 1, 0, 0), 0, None, []),
            ("not an issue", "- UTF-8 names\n- KEN-1 shipped\n", {"issues": issues, "missing": ["UTF-8"]},
             ["not-issue line=5 ids=UTF-8", "unbound line=5", "closed line=6 ids=KEN-1:Done"], (2, 1, 1, 0, 1), 0, None,
             [["UTF-8", "KEN-1"], ["KEN-1"]]),
            ("zero-numbered tokens bind nothing", "- KEN-4849 read HYPRLAND-0.57-FALLBACK-FACTS-2026-11-02.md and PP-06\n",
             {"issues": dict(issues, **{"KEN-4849": DONE})}, ["closed line=5 ids=KEN-4849:Done"], (1, 1, 0, 0, 0), 0,
             None, [["KEN-4849"]]),
            ("tracker failure", "- KEN-1 shipped\n- Call the vendor\n", {"issues": issues, "fail": True},
             ["unread line=5 ids=KEN-1", "unbound line=6"], (2, 0, 1, 1, 0), 1, "tracker-unavailable=exit-1",
             [["KEN-1"]]),
            ("no linear package", "- KEN-1 shipped\n- Call the vendor\n", None,
             ["unread line=5 ids=KEN-1", "unbound line=6"], (2, 0, 1, 1, 0), 1, "tracker-unavailable=linear-missing", []),
            ("moved issue", "- KEN-7 shipped\n", {"issues": {"KEN-7": ("KEN-9",) + DONE}},
             ["unread line=5 ids=KEN-7"], (1, 0, 0, 1, 0), 1, "tracker-unmatched=KEN-7", [["KEN-7"]]),
            ("no section", "# Handoff\n\n## Progress log\n", {"issues": issues}, "section-missing=State", None, 2, None, []),
            ("ambiguous section", state_handoff("- KEN-1\n") + "## State\n", {"issues": issues},
             "section-ambiguous=State", None, 2, None, []),
            ("no handoff", None, {"issues": issues}, "handoff-missing", None, 2, None, []),
        )
        for name, state, world, listed, counts, code, key, reads in rows:
            with self.subTest(row=name):
                self.handoff.unlink(missing_ok=True)
                if state is not None:
                    self.handoff.write_text(state if state.startswith("#") else state_handoff(state))
                before = self.handoff.read_bytes() if state is not None else None
                result, calls = self.check(world)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(calls, [[BULK_GET, refs] for refs in reads])
                self.assertEqual(self.handoff.read_bytes() if state is not None else None, before)
                if counts is None:
                    self.assertEqual(result.stdout, "")
                    self.assertEqual(result.stderr.split(" fix=", 1)[0].split("=", 1)[0],
                                     "progress-log: " + listed.split("=", 1)[0])
                    self.assertTrue(result.stderr.startswith("progress-log: " + listed), result.stderr)
                    self.assertTrue(result.stderr.strip().endswith("long-session.md#handoff"), result.stderr)
                    continue
                summary = "checked entries=%d closed=%d unbound=%d unread=%d not-issue=%d" % counts
                self.assertEqual(result.stdout.splitlines(), ["progress-log: " + line for line in listed + [summary]])
                if key is None:
                    self.assertEqual(result.stderr, "")
                else:
                    self.assertTrue(result.stderr.startswith("progress-log: " + key + (" " if "unavailable" in key else "\n")),
                                    result.stderr)

    def test_check_selected_handoff(self):
        self.handoff.write_text(state_handoff("- Call the vendor\n"))
        selected = self.home / "state/delegate/handoff.md"
        selected.parent.mkdir()
        selected.write_text(state_handoff("- KEN-3 in review\n- KEN-1 shipped\n"))
        for target in ("state/delegate/handoff.md", selected):
            with self.subTest(target=target):
                result, calls = self.check({"issues": {"KEN-1": DONE, "KEN-3": OPEN}}, handoff=target)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), [
                    "progress-log: closed line=6 ids=KEN-1:Done",
                    "progress-log: checked entries=2 closed=1 unbound=0 unread=0 not-issue=0"])
                self.assertEqual(calls, [[BULK_GET, ["KEN-3", "KEN-1"]]])

    def test_check_state_control(self):
        # A closed rule that drops Canceled and Duplicate must fail their rows;
        # the earlier tracker pattern must fail the zero-numbered row.
        for old, new in (('CLOSED_TYPES = ("completed", "canceled", "duplicate")', 'CLOSED_TYPES = ("completed",)'),
                         ('_TRACKER_ID = r"[A-Z][A-Z0-9]*-[1-9]\\d*"', '_TRACKER_ID = r"[A-Z][A-Z0-9]*-\\d+"')):
            with self.subTest(mutation=new), tempfile.TemporaryDirectory() as folder:
                copy = Path(folder) / "jarvis/scripts"
                shutil.copytree(SCRIPTS, copy)
                library = copy / "lib/progress.py"
                source = library.read_text()
                self.assertEqual(source.count(old), 1)
                library.write_text(source.replace(old, new))
                case = ProgressLog(methodName="test_check_state")
                case.scripts = copy
                case.setUp()
                try:
                    with self.assertRaises(AssertionError):
                        case.test_check_state()
                finally:
                    case.doCleanups()

    def test_instrument_control(self):
        # A typed-in time, not the clock read, must fail the record row.
        with tempfile.TemporaryDirectory() as folder:
            copy = Path(folder) / "jarvis"
            shutil.copytree(SCRIPTS.parent / "scripts", copy / "scripts")
            shutil.copytree(SCRIPTS.parent / "references", copy / "references")
            script = copy / "scripts/progress-log"
            source = script.read_text()
            old = "    stamp = clock()\n"
            self.assertEqual(source.count(old), 1)
            script.write_text(source.replace(old, '    stamp = "2026-10-18T23:00:00Z"\n'))
            case = ProgressLog(methodName="test_records")
            case.scripts = copy / "scripts"
            case.setUp()
            try:
                with self.assertRaises(AssertionError):
                    case.test_records()
            finally:
                case.doCleanups()


class ConsumerRecovery(ProgressLogCommands):
    SELECTED = "state/predecessor.md"
    SESSION = ("session=control", "Control holds review and has reported through C1:1791680510.123")
    WAKE = ("wake=mail", "Wait for registered mailbox wake in run/mail")
    ASK = ("ask=C1:1791680510.123", 'Await answer to "Should we ship today?"')
    OPERATION = ("KEN-3", "Read run/child/result before resuming the operation without a receipt")
    UNREAD = ("KEN-4", "Retry unavailable tracker read before acting")
    PENDING = {"KEN-1": "Check the vendor receipt", "KEN-2": "Wait for the rollout approval"}
    NEXT_ACTION = {("KEN-1", REQUEST, "1"): box(REQUEST, 1, ACTION).rstrip("\n")}

    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        packages = self.root / ".agents/skills"
        package = packages / "jarvis"
        shutil.copytree(SCRIPTS.parent, package, ignore=shutil.ignore_patterns("tests", "__pycache__"))
        self.scripts = package / "scripts"
        self.tracker = install_tracker(packages)
        self.store = self.root / "linear-world.json"
        self.trace = self.root / "linear-calls"
        self.home = self.root
        self.env = {"HOME": str(self.root), "PATH": os.defpath, "PYTHONDONTWRITEBYTECODE": "1",
                    "GIT_CEILING_DIRECTORIES": str(self.root.parent)}
        for name in ("CONFIG", "DATA", "STATE", "CACHE"):
            self.env["XDG_" + name + "_HOME"] = str(self.root / name.lower())
        self.package_paths = {str(path.relative_to(self.root)) for path in (package, *package.rglob("*"))}
        self.handoffs = []
        self.addCleanup(self.check_home)

    def check_home(self):
        allowed = self.package_paths.copy()
        for path in [self.tracker, self.store, self.trace, *self.handoffs]:
            while path != self.root:
                allowed.add(str(path.relative_to(self.root)))
                path = path.parent
        inventory = {str(path.relative_to(self.root)): path for path in self.root.rglob("*")}
        if self._testMethodName == "test_consumer_start_and_handoff":
            files = sorted(name for name, path in inventory.items() if path.is_file())
            print("Consumer home files: " + ", ".join(files), flush=True)
        extra = inventory.keys() - allowed
        self.assertFalse(extra, "Unexpected paths in the consumer home: " + ", ".join(sorted(extra)))
        self.assertFalse([name for name, path in inventory.items() if path.is_symlink()],
                         "Consumer home entries must not point outside the fixture")

    def seed_tracker(self, pending):
        state, state_type = OPEN
        issues = {item: {"id": item, "title": title, "project_id": PROJECT,
                         "state": state, "state_type": state_type} for item, title in pending.items()}
        self.store.write_text(json.dumps({"project": PROJECT, "issues": issues, "comments": {}}))

    def tracker_read(self, home, *args):
        result = self.command([self.tracker, *args], home)
        result.check_returncode()
        return json.loads(result.stdout)

    def handoff(self, home, selected, text):
        path = home / selected
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        self.handoffs.append(path)
        return path

    def record_state(self, change, *, handoff=None, home=None, **observations):
        result = self.log({**FIELDS, **observations, "--state-change": change}, cwd=home, handoff=handoff)
        self.assertEqual(result.returncode, 0, result.stderr)

    def predecessor(self, *, interrupted):
        empty = state_handoff("")
        default = self.handoff(self.home, "state/handoff.md", empty)
        predecessor = self.handoff(self.home, self.SELECTED, empty)
        self.seed_tracker({**self.PENDING, "KEN-3": "Resume the operation", "KEN-4": "Read tracker evidence"})
        outcomes = [(self.SESSION, "retained"), (self.WAKE, "retained"), (self.ASK, "retained")]
        if interrupted:
            outcomes.extend([(self.OPERATION, "unread, no receipt"), (self.UNREAD, "unread, tracker unavailable")])
        expected = {}
        for (key, text), result in outcomes:
            self.record_state(f"set State {key} {text}", handoff=self.SELECTED,
                              **{"--operation": f"Retain {key}", "--result": result, "--decision": text})
            saved = predecessor.read_text()
            identity = records(saved)[-1]["id"]
            expected[key] = f"- {key}: {text} (record={identity})\n"
            if key == self.SESSION[0]:
                first = identity
                checkpoint = saved[:saved.index("## Progress log")]
                checkpoint = checkpoint.replace("log none", f"log {first} through {first}") + "## Progress log\n\n"
        result = self.next_action(handoff=self.SELECTED)
        self.assertEqual(result.returncode, 0, result.stderr)
        text = predecessor.read_text()
        self.assertEqual(default.read_text(), empty)
        covered, *later = records(text)
        self.assertEqual(covered["id"], first)
        return empty, checkpoint, covered, later, text, expected

    def replay_route(self, checkpoint, rows, apply, route):
        entries = rebuild_state(checkpoint, rows, apply)
        confirmed = {}
        # progress-log records the tracker destination in Observed result and source.
        prefix = "Tracker next action: "
        for row in rows:
            for line in row["Observed result and source"].splitlines():
                if not line.startswith(prefix):
                    continue
                item, outcome, ask = (line[len(prefix):].split(" ") + ["", ""])[:3]
                if not (item and outcome.startswith("outcome=") and ask.startswith("ask=")):
                    continue
                key = (item, outcome[len("outcome="):], ask[len("ask="):])
                operation = "%s | tracker issues get %s outcome=%s ask=%s" % (route, *key)
                try:
                    issue = self.tracker_read(self.home, "issues", "get", item, "--format=safe")
                except subprocess.CalledProcessError as error:
                    print(f"{operation} | exit={error.returncode} {error.stderr.strip()}".rstrip(), flush=True)
                    continue
                except (OSError, subprocess.SubprocessError, ValueError) as error:
                    print(f"{operation} | {error}", flush=True)
                    continue
                if not isinstance(issue, dict) or not isinstance(issue.get("description"), str):
                    print(f"{operation} | invalid tracker response", flush=True)
                    continue
                opening = " Jarvis outcome %s ask %s: " % key[1:]
                matches = [text for text in issue["description"].splitlines()
                           if text[:5] in ("- [ ]", "- [x]") and text[5:].startswith(opening)]
                if len(matches) == 1:
                    confirmed[key] = matches[0]
        return entries, confirmed

    def assert_recovered(self, path, entries, expected, confirmed):
        outcomes = {
            "session and wake": all(expected[key] in entries for key in (self.SESSION[0], self.WAKE[0])),
            "open ask": expected[self.ASK[0]] in entries,
            "unfinished operation": expected[self.OPERATION[0]] in entries,
            "unavailable tracker read": expected[self.UNREAD[0]] in entries,
            "work next action": (confirmed == self.NEXT_ACTION
                                 and not any("KEN-1" in entry for entry in entries)),
        }
        for name, recovered in outcomes.items():
            print(f"{path} | {name} | {'recovered' if recovered else 'not-recovered'}", flush=True)
        return [name for name, recovered in outcomes.items() if not recovered]

    def test_consumer_start_and_handoff(self):
        print("Scripted recovery only. This test does not run the model's prose steps. "
              "Fixed fixture choices stand in for the model choosing a replay route, "
              "judging whether an open item supplies a State entry, and writing records to their homes.", flush=True)
        empty, checkpoint, covered, later, text, expected = self.predecessor(interrupted=True)
        apply = runpy.run_path(str(self.scripts / "lib/progress.py"))["change_state"]
        routes = (
            ("cold Start", checkpoint, later),
            ("hand-over", empty, [covered, *later]),
        )
        missing = []
        for route, starting_state, rows in routes:
            entries, confirmed = self.replay_route(starting_state, rows, apply, route)
            missing.extend(f"{route}: {name}" for name in self.assert_recovered(route, entries, expected, confirmed))
        self.assertEqual(missing, [])
        self.assertEqual([entry for _, entry in state_entries(text.splitlines(keepends=True))], list(expected.values()))
        # A failed live read in Start leaves the selected handoff available for retry.
        world = json.loads(self.store.read_text())
        self.store.write_text(json.dumps({**world, "fail": True}))
        earlier_calls = len(self.trace.read_text().splitlines())
        check = self.progress("--check-state", "--handoff", self.SELECTED)
        self.assertEqual(check.returncode, 1, check.stderr)
        calls = [json.loads(line) for line in self.trace.read_text().splitlines()[earlier_calls:]]
        self.assertEqual(calls, [[BULK_GET, [self.OPERATION[0], self.UNREAD[0]]]], check.stderr)
        cause, _, detail = check.stderr.strip().partition(" detail=")
        self.assertEqual(cause, "progress-log: tracker-unavailable=exit-1", check.stderr)
        self.assertEqual(json.loads(detail), {"error": "HTTP 503"})
        self.assertTrue(any(line.startswith("progress-log: unread line=") and line.endswith(" ids=KEN-4")
                            for line in check.stdout.splitlines()), check.stdout)
        self.assertEqual((self.home / self.SELECTED).read_text(), text)

    def test_consumer_migrated_pending_work(self):
        self.seed_tracker(self.PENDING)
        pending = []
        for name in ("fresh", "migrated"):
            home = self.root / name
            legacy = "" if name == "fresh" else "".join(f"- {key}: {title}\n" for key, title in self.PENDING.items())
            handoff = self.handoff(home, "state/handoff.md", state_handoff(legacy))
            check = self.progress("--check-state", cwd=home)
            self.assertEqual(check.returncode, 0, check.stderr)
            self.assertIn(f"entries={len(self.PENDING) if legacy else 0} ", check.stdout)
            items = self.tracker_read(home, "issues", "list", "--project-id", PROJECT,
                                      "--include-archived", "--max", "--format=safe")
            pending.append({item["id"]: item["title"] for item in items if item["state_type"] == OPEN[1]})
            if name == "migrated":
                for key in pending[-1]:
                    self.record_state("remove State " + key, home=home)
            self.assertEqual(state_entries(handoff.read_text().splitlines(keepends=True)), [],
                             f"{name} home still has tracker work in State")
        self.assertEqual(pending, [self.PENDING, self.PENDING])
        print("Pending work in fresh and migrated homes: " + ", ".join(pending[0]) + " | no State pointers", flush=True)

    def test_consumer_transfer_routes(self):
        apply = runpy.run_path(str(self.scripts / "lib/progress.py"))["change_state"]
        for scenario, interrupted in (("clean", False), ("interrupted", True)):
            with self.subTest(transfer=scenario):
                empty, checkpoint, covered, later, _, expected = self.predecessor(interrupted=interrupted)
                ordinary = self.replay_route(checkpoint, later, apply, "checkpoint replay")
                full = self.replay_route(empty, [covered, *later], apply, "full replay")
                self.assertEqual(ordinary, full, f"{scenario} transfer: replay routes differ")
                self.assertEqual(full, (list(expected.values()), self.NEXT_ACTION))
                print(f"{scenario} transfer | checkpoint and full replay agree on State and tracker comments", flush=True)


if __name__ == "__main__":
    os.umask(0o022)
    unittest.main(defaultTest="ProgressLog")
