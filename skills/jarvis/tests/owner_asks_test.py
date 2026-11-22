"""Request identity, source evidence and the actual page/action operations."""
import base64
import copy
from contextlib import redirect_stderr
import io
import itertools
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

from mail_world import BASH, MailWorld, REPO, make_project

LIB = Path(os.environ.get("JARVIS_TEST_SKILLS", str(REPO / "skills"))) / "jarvis/scripts/lib"
os.environ["JARVIS_BASH"] = BASH
sys.path.insert(0, str(LIB))
import owner_asks
from session import Session


def request_comment(key="request-1", text="Question"):
    return {"id": key, "body": text, "user_id": "requester", "user": "Original asker",
            "user_email": "asker@example.test", "created_at": "2026-11-01T03:00:00Z",
            "updated_at": "2026-11-01T03:00:00Z", "parent_id": None,
            "url": "https://linear.app/example/issue/KEN-1#comment-" + key}


def projection(home, count=1):
    comments = [request_comment("request-" + str(i), "Question " + str(i)) for i in range(count)]
    return {"home": home, "config": {"configured": True}, "mailboxes": [],
            "tracker": {"workspace": "example", "issues": [{"uuid": "issue-uuid", "comments": comments}],
                        "requests": [{"issue": "KEN-1", "issueUuid": "issue-uuid", "thread": comment["id"], "comment": comment}
                                     for comment in comments]}}


def mailbox_projection(home):
    ask = {"id": "mail-ask", "from": "overseer:repo", "at": "2026-11-01T02:00:00Z", "text": "Mailbox question"}
    return {"home": home, "config": {"configured": False}, "tracker": None,
            "mailboxes": [{"destination": "local", "root": "/canonical/repo", "asks": [ask],
                           "outward": {"rows": [ask]},
                           "links": {ask["id"]: {"url": "https://linear.app/example/issue/KEN-1#comment-mirror"}}}]}


# Linear's GraphQL endpoint for the readers the list uses, over the issues
# in TRACKER_DATABASE: {"issues": {IDENTIFIER: [comment rows]}, "assigned":
# [the owner's labelled view]}. A .mode file beside it fails, truncates or
# omits the assigned view. Each request appends its operation to a .log file
# beside it; past TRACKER_REQUEST_LIMIT requests, the tracker refuses.
TRACKER_API = r'''
import json, os, sys
from pathlib import Path
config = sys.stdin.read()
payload = json.loads(json.loads(next(line[7:] for line in config.splitlines() if line.startswith('data = '))))
query, variables = payload['query'], payload.get('variables') or {}
path = Path(os.environ['TRACKER_DATABASE'])
database = json.loads(path.read_text())
mode_path = path.with_suffix('.mode')
mode = mode_path.read_text() if mode_path.exists() else 'present'
operation = next(name for name in ('GetUserByEmail', 'TeamKeys', 'ListIssues', 'GetIssueWithBundle', 'ListComments',
                                   'IssueRefs') if name in query)
if operation == 'IssueRefs':
    operation += ' ' + variables['filter']['id']['in'][0].split('-')[0]
with path.with_suffix('.log').open('a') as log:
    log.write(operation + '\n')
if len(path.with_suffix('.log').read_text().splitlines()) > int(os.environ.get('TRACKER_REQUEST_LIMIT', '1000000')):
    print('___HTTP_CODE___403', end='')
    sys.exit(0)
def connection(nodes):
    return {'nodes': nodes, 'pageInfo': {'hasNextPage': False, 'endCursor': None}}
def comment(row):
    return dict(id=row['id'], body=row['body'], createdAt=row['created_at'], updatedAt=row['updated_at'],
                user={'id': row['user_id'], 'name': row['user'], 'email': row['user_email']},
                parent={'id': row['parent_id']} if row['parent_id'] else None, url=row['url'])
def issue(identifier, **fields):
    return dict(id=identifier + '-uuid', identifier=identifier, url='https://linear.app/example/issue/' + identifier, **fields)
def comments(identifier):
    return connection(list(map(comment, database['issues'][identifier])))
if 'GetUserByEmail' in query:
    data = {'users': connection([dict(id='owner-id', name='Owner', email='owner@example.test',
                                     url='https://linear.app/example/profiles/owner')])}
elif 'TeamKeys' in query:
    data = {'organization': {'urlKey': 'example', 'teams': connection([])}}
elif 'ListIssues' in query:
    if mode == 'failed':
        print('___HTTP_CODE___403', end='')
        sys.exit(0)
    issues = connection([] if mode == 'omitted' else [issue(identifier, updatedAt='2026-11-01T01:00:00Z')
                                                      for identifier in database['assigned']])
    if mode == 'incomplete':
        issues['pageInfo'] = {'hasNextPage': True, 'endCursor': None}
    data = {'issues': issues}
elif 'GetIssueWithBundle' in query:
    data = {'issue': issue(variables['id'], labels=connection([]), relations=connection([]),
                           inverseRelations=connection([]), children=connection([]))}
elif 'ListComments' in query:
    data = {'issue': issue(variables['issueId'], comments=comments(variables['issueId']))}
elif 'IssueRefs' in query:
    # Linear's page of 50, the size the reader asks for.
    refs = variables['filter']['id']['in']
    offset = int(variables.get('after') or 0)
    page = connection([issue(ref, comments=comments(ref)) for ref in refs[offset:offset + 50]])
    if offset + 50 < len(refs):
        page['pageInfo'] = {'hasNextPage': True, 'endCursor': str(offset + 50)}
    data = {'issues': page}
else:
    raise RuntimeError(query)
print(json.dumps({'data': data})+'___HTTP_CODE___200', end='')
'''


class CanonicalFixture:
    """The public source projection."""
    def __init__(self, home, count=1):
        self.data = projection(home, count)

    def stable(self):
        return copy.deepcopy(self.data)


class OwnerAsksContract(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.home = Path(self.scratch.name).resolve()
        self.now = 1793494800
        self.source = CanonicalFixture(str(self.home))
        self.environment = patch.dict(os.environ, {"XDG_STATE_HOME": str(self.home / "runtime")})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.owner = self.new_owner()

    def new_owner(self):
        session = Session(str(self.home))
        session.path = session.path.with_name("owner-asks.json")
        return owner_asks.OwnerAsks(session, self.source, lambda: self.now)

    def page(self, view="active", cursor=None, owner=None):
        owner = owner or self.owner
        with owner.session.locked():
            return owner.page(owner.read(), view, cursor)

    def later(self, row, request_id, owner=None, **fields):
        owner = owner or self.owner
        request = {"requestId": request_id, "expectedRevision": row["revision"], **fields}
        with owner.session.locked():
            return owner.later(owner.read(), row["id"], request)

    def test_distinct_comments_exact_mirrors_and_original_metadata(self):
        data = projection(str(self.home), 2)
        first = data["tracker"]["requests"][0]["comment"]
        ask = {"id": "actual-mail-id", "from": "overseer:repo", "at": "2026-10-30T01:00:00Z", "text": "Mailbox original",
               "tracker_posted": True, "issue": "KEN-1", "tracker_comment": first["id"]}
        data["mailboxes"] = [{"destination": "local", "root": "/canonical/repo", "asks": [ask], "outward": {"rows": [ask]},
                              "links": {ask["id"]: {"url": first["url"]}}}]
        rows = owner_asks.source_rows(data)
        self.assertEqual(len(rows), 2)
        self.assertEqual({row["askedBy"]["id"] for row in rows.values()}, {"overseer:repo", "requester"})
        self.assertEqual({row["askedAt"] for row in rows.values()}, {"2026-10-30T01:00:00Z", first["created_at"]})
        for linked in (False, True):
            with self.subTest(confirmed=linked):
                ask["tracker_posted"] = linked
                ask["tracker_comment"] = "unrelated"
                rows = owner_asks.source_rows(data)
                self.assertEqual(len(rows), 3)
        data["mailboxes"][0]["asks"].append(dict(ask, id="another-real-ask"))
        data["mailboxes"][0]["links"]["another-real-ask"] = {"url": first["url"]}
        self.assertEqual(len(owner_asks.source_rows(data)), 4)

    def test_mailbox_ask_links_are_its_tracker_mirror_or_null(self):
        # Beside a linked ask, one with no tracker mirror lists with a null
        # link; a mirror link that is not HTTP is never shown.
        mirror = "https://linear.app/example/issue/KEN-1#comment-mirror"
        cases = [("mirror", {"url": mirror}, mirror), ("unposted", None, None),
                 ("not-http", {"url": "javascript:alert(1)"}, owner_asks.Unavailable)]
        for name, link, expected in cases:
            with self.subTest(link=name):
                self.source.data = data = mailbox_projection(str(self.home))
                mailbox = data["mailboxes"][0]
                beside = dict(mailbox["asks"][0], id="beside-ask", text="Linked neighbour")
                mailbox["asks"].append(beside)
                mailbox["links"] = {beside["id"]: {"url": mirror}}
                if link is not None:
                    mailbox["links"]["mail-ask"] = link
                if expected is owner_asks.Unavailable:
                    with self.assertRaises(owner_asks.Unavailable):
                        self.page()
                    continue
                links = {row["what"]: row["link"] and row["link"]["url"] for row in self.page()["rows"]}
                self.assertEqual(links, {"Mailbox question": expected, "Linked neighbour": mirror})

    def test_complete_row_and_byte_paging_and_stale_cursors(self):
        self.source.data = projection(str(self.home), 70)
        first = self.page()
        ids = []
        page = first
        while True:
            self.assertLessEqual(len(page["rows"]), 32)
            self.assertLessEqual(len(owner_asks.encoded(page).encode()) + 1, 16 * 1024)
            self.assertEqual(page["activeCount"], 70)
            self.assertEqual(page["revision"], first["revision"])
            ids.extend(row["id"] for row in page["rows"])
            if page["complete"]:
                self.assertIsNone(page["nextCursor"])
                break
            cursor = page["nextCursor"]
            page = self.page(cursor=cursor)
            self.assertNotEqual(page["nextCursor"], cursor)
        self.assertEqual(len(set(ids)), 70)
        self.assertEqual(self.page("snoozed")["revision"], first["revision"])
        self.source.data["tracker"]["requests"][0]["comment"]["body"] += " changed"
        with self.assertRaises(owner_asks.Unavailable):
            self.page(cursor=first["nextCursor"])
        self.source.data = projection(str(self.home))
        self.source.data["tracker"]["requests"][0]["comment"]["body"] = "x" * (16 * 1024)
        with self.assertRaises(owner_asks.Unavailable):
            self.page()

    def test_later_receipt_replay_precedes_revision(self):
        row = self.page()["rows"][0]
        until = owner_asks.iso(self.now + 3600)
        first = self.later(row, "same-request", until=until)
        self.assertEqual((first["kind"], first["state"]), ("accepted", "snoozed"))
        # The accepted snooze moved the revision; the retry still answers its receipt.
        self.assertEqual(self.later(row, "same-request", until=until), first)
        conflict = self.later(row, "same-request", until=owner_asks.iso(self.now + 7200))
        self.assertEqual((conflict["kind"], conflict["state"]), ("refused", None))
        stale = self.later(row, "other-request", until=until)
        self.assertEqual((stale["kind"], stale["state"]), ("refused", "snoozed"))

    def test_snooze_restores_and_follows_complete_current_view_membership(self):
        row = self.page()["rows"][0]
        # KEN-5390 adds Reply and Done; each row says so and allows Later.
        self.assertEqual({name: action["allowed"] for name, action in row["actions"].items()},
                         {"reply": False, "done": False, "later": True})
        self.assertTrue(all(owner_asks.printable(row["actions"][name]["reason"]) for name in ("reply", "done")))
        self.assertEqual(row["actions"]["later"]["reason"], "")
        for until in ("2026-11-01T10:00:00", "2020-01-01T00:00:00Z", "not-time"):
            self.assertEqual(self.later(row, until, until=until)["kind"], "refused")
        later = owner_asks.iso(self.now + 3600)
        self.assertEqual(self.later(row, "later", until=later)["state"], "snoozed")
        self.assertEqual(self.page()["activeCount"], 0)
        snoozed = self.page("snoozed")["rows"][0]
        self.assertEqual(snoozed["snoozedUntil"], later)
        self.now += 3600
        restored = self.page()["rows"][0]
        self.assertEqual((restored["state"], restored["snoozedUntil"]), ("open", None))
        self.assertEqual((restored["id"], restored["askedAt"], restored["link"]), (snoozed["id"], row["askedAt"], row["link"]))
        # A complete read alone owns membership, for either source: a tracker
        # view that omits the request, a read mailbox that no longer holds the
        # ask (closed, or compacted after closing) and a root no longer read.
        omissions = [
            ("tracker", projection, lambda data: data["tracker"].update(requests=[])),
            ("mailbox-closed", mailbox_projection, lambda data: data["mailboxes"][0].update(asks=[])),
            ("mailbox-root-unread", mailbox_projection, lambda data: data.update(mailboxes=[])),
        ]
        for (name, world, omit), action in itertools.product(omissions, (None, "later")):
            with self.subTest(source=name, action=action):
                # Each row starts from an empty action record of its own.
                self.owner.session.path.unlink(missing_ok=True)
                self.source.data = world(str(self.home))
                row = self.page()["rows"][0]
                if action:
                    receipt = self.later(row, "membership-" + name, until=owner_asks.iso(self.now + 60))
                    self.assertEqual((receipt["kind"], receipt["state"]), ("accepted", "snoozed"))
                else:
                    self.assertEqual(self.owner.read()["deltas"], {})
                before = self.owner.session.path.read_bytes()
                # The canonical reader refuses failed/incomplete traversals;
                # neither refusal supplies an empty membership result.
                with patch.object(self.source, "stable", side_effect=owner_asks.Unavailable("Source traversal incomplete")):
                    with self.assertRaises(owner_asks.Unavailable):
                        self.page()
                self.assertEqual(self.owner.session.path.read_bytes(), before)
                omit(self.source.data)
                for view in ("active", "snoozed"):
                    page = self.page(view)
                    self.assertEqual((page["activeCount"], page["snoozedCount"], page["rows"], page["complete"]),
                                     (0, 0, [], True))
                self.assertEqual(self.owner.read()["deltas"], {})

    def test_overlapping_actions_have_one_winner(self):
        row = self.page()["rows"][0]
        barrier, answers = threading.Barrier(2), []
        failures = []
        def act(key):
            try:
                owner = self.new_owner()
                barrier.wait(timeout=5)
                answers.append(self.later(row, key, owner=owner, until=owner_asks.iso(self.now + 60)))
            except BaseException as error:
                failures.append(error)
        threads = [threading.Thread(target=act, args=(str(i),)) for i in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=20)
            self.assertFalse(thread.is_alive())
        self.assertEqual(failures, [])
        self.assertEqual(sorted(answer["kind"] for answer in answers), ["accepted", "refused"])

    def test_required_dependency_diagnostics_preserve_safe_cause(self):
        session = self.owner.session
        session.deadline = owner_asks.time.monotonic() + 10
        sources = owner_asks.Sources(session, {})
        secret = "sk-" + "a" * 30
        failures = [
            (None, owner_asks.watch.Failure("lane-mail", "timeout", None, "deadline"),
             ["lane-mail", "timeout", "None"]),
            (None, OSError(13, "permission denied"), ["mailbox/lane-mail", "PermissionError", "13"]),
            ("remote", subprocess.CompletedProcess([], 255, "", "ssh: connect to host remote refused " + secret),
             ["mailbox/lane-mail", "exit", "255"]),
            (None, subprocess.CompletedProcess([], 7, "", "lane-mail: mailbox-unreadable=" + secret),
             ["mailbox/lane-mail", "refusal", "mailbox-unreadable"]),
        ]
        for host, failure, key in failures:
            with self.subTest(host=host, failure=type(failure).__name__):
                target = owner_asks.watch.Destination("ssh:remote" if host else "local", host, None)
                dependency = patch.object(owner_asks.watch, "run", **({"side_effect": failure} if isinstance(failure, Exception)
                                                                   else {"return_value": failure}))
                with dependency, self.assertRaises(owner_asks.Unavailable) as raised:
                    sources.call(target, str(self.home), "mailbox", "lane-mail", ["pending"])
                with redirect_stderr(io.StringIO()) as output:
                    owner_asks.diagnostic(raised.exception, "owner-asks-list")
                lines = output.getvalue().splitlines()
                self.assertEqual(len(lines), 1)
                record = json.loads(lines[0].split("=", 1)[1])
                self.assertEqual(record["destination"], target.key + ":" + str(self.home))
                self.assertEqual(record["key"], key)
                self.assertNotIn(secret, lines[0])

    def test_reads_run_caller_code_as_the_destination_account(self):
        session = self.owner.session
        session.env["JARVIS_BASH"] = BASH
        session.deadline = owner_asks.time.monotonic() + 10
        packages = owner_asks.watch.LIB.parents[2]
        caller = base64.b64encode((packages / "mailbox/scripts/lane-mail").read_bytes()).decode()
        installed = self.home / ".agents/skills/mailbox/scripts/lane-mail"
        root = str(self.home)
        answers = [{"registered": root, "mailbox": root}, {"root": root, "pending": "", "outward": "count=0 first=\n"}]

        def answer(argv, cwd=None, data=None, operation=None, timeout=60):
            return subprocess.CompletedProcess(argv, 0, "".join(json.dumps(line) + "\n" for line in answers), "")

        cases = [
            ("local", None, {}, False),
            ("ssh:remote", "remote", {"JARVIS_REMOTE_HOSTS": "remote"}, False),
            ("ssh:control", "control", {"JARVIS_CONTROL_HOST": "control", "JARVIS_CONTROL_USER": "overseer"}, True),
        ]
        for destination, host, settings, control in cases:
            with self.subTest(destination=destination):
                sources = owner_asks.Sources(session, dict(settings, JARVIS_MAIN_HOST=""))
                target = next(target for target in owner_asks.watch.destinations(sources.settings)
                              if target.key == destination)
                with patch.object(owner_asks.watch, "run", side_effect=answer) as transport:
                    self.assertEqual([record["root"] for record in sources.mailboxes(target, [root])], [root])
                # The read reaches one account in one call and runs the
                # caller's lane-mail, never the one installed in the checkout.
                call, = transport.call_args_list
                argv = list(map(str, call.args[0]))
                self.assertNotIn(str(installed), " ".join(argv))
                if host:
                    self.assertEqual(argv[:2], ["ssh", host])
                    self.assertEqual(argv[2].startswith("sudo -n -H -u overseer -- bash -l -c "), control)
                    self.assertEqual(json.loads(call.kwargs["data"])["files"]["mailbox/scripts/lane-mail"], caller)
                else:
                    self.assertEqual(argv[0], BASH)
                    self.assertIn(str(packages / "mailbox/scripts/lane-mail"), argv)

    def test_tracker_and_destinations_are_read_side_by_side(self):
        # Each chain's first read waits, bounded, for the other chain to
        # start. Read in turn, the first chain waits out its bound.
        session = self.owner.session
        session.deadline = owner_asks.time.monotonic() + 60
        sources = owner_asks.Sources(session, {"JARVIS_MAIN_HOST": ""})
        started = {"tracker": threading.Event(), "local": threading.Event()}
        waited = []

        def meet(own, other):
            started[own].set()
            if not started[other].wait(5):
                waited.append(own)

        def settings(package, script, args=()):
            meet("tracker", "local")
            return {"configured": False, "cause": "settings-unset"}

        def registered(target):
            meet("local", "tracker")
            return []

        with patch.object(sources, "caller", side_effect=settings), patch.object(sources, "registered", side_effect=registered):
            with patch.object(sources, "mailboxes", return_value=[]):
                self.assertEqual(sources.collect()["mailboxes"], [])
        self.assertEqual(waited, [])

    def test_controls_reject_each_guarded_regression(self):
        # Keep the mutant outside the worktree and acquire only its own
        # scratch directory. The original suite supplies all test fixtures.
        directory = REPO.parent / "tmp"
        directory.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="owner-asks-control-", dir=directory) as allocation:
            skills = Path(allocation).resolve() / "skills"
            for package in ("jarvis", "orch", "mailbox", "linear", "slack"):
                shutil.copytree(REPO / "skills" / package / "scripts", skills / package / "scripts")
            references = skills / "orch/references"
            references.mkdir()
            shutil.copyfile(REPO / "skills/orch/references/secret-value.ere", references / "secret-value.ere")
            mutations = [
                ("jarvis/scripts/lib/owner_asks.py", 'previous = state["requests"].get(request["requestId"])', 'previous = None',
                 "OwnerAsksContract.test_later_receipt_replay_precedes_revision", None),
                ("jarvis/scripts/lib/owner_asks.py", 'PAGE_BYTES = 16 * 1024', 'PAGE_BYTES = 32 * 1024',
                 "OwnerAsksContract.test_complete_row_and_byte_paging_and_stale_cursors", None),
                ("jarvis/scripts/lib/owner_asks.py", 'closed_keys = [key for key in state["deltas"] if key not in rows]', "closed_keys = []",
                 "OwnerAsksContract.test_snooze_restores_and_follows_complete_current_view_membership",
                 "source='mailbox-root-unread'"),
                # A plain ssh login, the account a control host's reads took
                # before they went through watch.host_args.
                ("jarvis/scripts/lib/owner_asks.py",
                 'result = watch.run(watch.host_args(target, "bash -c " + shlex.quote(command)), data=payload,',
                 'result = watch.run(["ssh", target.host, "bash -c " + shlex.quote(command)], data=payload,',
                 "OwnerAsksContract.test_reads_run_caller_code_as_the_destination_account", "(destination='ssh:control')"),
                # The checkout's installed lane-mail, the route a read took
                # before Sources carried its own.
                ("jarvis/scripts/lib/owner_asks.py", '"$BASH" "$mail" pending --item overseer',
                 '"$BASH" .agents/skills/mailbox/scripts/lane-mail pending --item overseer',
                 "PublicOwnerAsks.test_remote_list_runs_caller_code_on_checkout_data", "(checkout_code=True)"),
                ("jarvis/scripts/lib/owner_asks.py", "    0:false:* | '128::fatal: not a git repository (or any '*)",
                 "    '128::fatal: not a git repository (or any '*)",
                 "PublicOwnerAsks.test_each_registered_folder_answers_through_its_own_mailbox", "(folder='git-metadata')"),
                ("jarvis/scripts/lib/owner_asks.py", "    0:false:* | '128::fatal: not a git repository (or any '*)",
                 "    0:false:* | 128::*)",
                 "PublicOwnerAsks.test_each_registered_folder_answers_through_its_own_mailbox", "(folder='dangling-gitfile')"),
                ("jarvis/scripts/lib/owner_asks.py", 'common="$(mailbox_common_root "$root" && printf .)"',
                 'common="$(mailbox_common_root "$root")"',
                 "PublicOwnerAsks.test_each_registered_folder_answers_through_its_own_mailbox", "(folder='trailing\\n')"),
                ("jarvis/scripts/lib/owner_asks.py", 'or link is not None and not http(link["url"]))', 'or False)',
                 "OwnerAsksContract.test_mailbox_ask_links_are_its_tracker_mirror_or_null", "(link='not-http')"),
                # A tracker read per posted issue, each spending the call's
                # one deadline in turn.
                ("jarvis/scripts/lib/owner_asks.py",
                 'read = self.caller("linear", "linear.sh", ["comments", "bulk-list", "--format=safe", *issues])',
                 'read = {issue.upper(): self.caller("linear", "linear.sh", ["comments", "list", issue, "--format=safe"])'
                 ' for issue in issues}',
                 "PublicOwnerAsks.test_list_reads_this_homes_tracker_and_mailboxes_within_its_budget", "(view='active')"),
                # The tracker and destination chains read in turn.
                ("jarvis/scripts/lib/owner_asks.py", "max_workers=1 + len(targets)", "max_workers=1",
                 "OwnerAsksContract.test_tracker_and_destinations_are_read_side_by_side", None),
                ("slack/scripts/lib/settings.py", 'exec "$reader" -I -c', 'exec "$reader" -c',
                 "PublicOwnerAsks.test_carried_presence_preserves_root_settings_and_permission", "(name='renew')"),
            ]
            for name, old, replacement, case, row in mutations:
                with self.subTest(case=case, mutant=replacement):
                    path = skills / name
                    original = path.read_text()
                    self.assertEqual(original.count(old), 1)
                    mutant = original.replace(old, replacement)
                    self.assertNotEqual(mutant, original)
                    path.write_text(mutant)
                    try:
                        env = dict(os.environ, JARVIS_TEST_SKILLS=str(skills))
                        result = subprocess.run([BASH, str(REPO / "skills/jarvis/tests/owner-asks.test.sh"), case],
                                                env=env, capture_output=True, text=True, timeout=300)
                    finally:
                        path.write_text(original)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("FAILED (failures=", result.stderr)
                    self.assertNotIn("ERROR:", result.stderr)
                    if row is not None:
                        self.assertIn(row, result.stderr)


class PublicOwnerAsks(MailWorld):
    def setUp(self):
        super().setUp()
        self.home = make_project(self.root / "main")
        for package in ("jarvis", "linear", "slack"):
            directory = self.home / ".agents/skills" / package
            directory.symlink_to(REPO / "skills" / package, target_is_directory=True)
        # kendex project list --json, the registry form a program reads.
        self.executable("kendex", '#!/bin/sh\ncase "$*" in "project list --json" | "project list") cat "$REGISTRY" ;; *) exit 97 ;; esac\n')
        self.register(self.registry, self.home)
        self.env.update(XDG_STATE_HOME=str(self.root / "runtime"))
        self.env.pop("PYTHONPATH", None)

    @staticmethod
    def register(registry, *folders, state="ok", main=None):
        registry.write_text(json.dumps([{"folder": str(folder), "state": state,
                                         "worktree": {"main": str(main)} if main else None} for folder in folders]))

    def run_cli(self, action="list", home=None, payload=None, *args, view="active", skills=None):
        script = (skills / "jarvis/scripts" if skills else LIB.parent) / "jarvis-session"
        command = [BASH, script, "owner-asks", action, "--home", home or self.home, *args]
        if action == "list":
            command += ["--view", view]
        result = subprocess.run(list(map(str, command)), env=self.env, text=True, input=payload,
                                capture_output=True, cwd=self.home, timeout=20)
        return result, json.loads(result.stdout)

    def test_canonical_empty_absence_and_unreadable_source(self):
        result, page = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual((page["activeCount"], page["snoozedCount"], page["rows"], page["complete"]), (0, 0, [], True))
        self.executable("kendex", "#!/bin/sh\nprintf 'kendex: registry=unreadable\\n' >&2\nexit 1\n")
        result, error = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(error["kind"], "unavailable")
        self.assertNotIn("activeCount", error)
        records = [json.loads(line.split("=", 1)[1]) for line in result.stderr.splitlines()
                   if line.startswith("jarvis-session: owner-asks-failure=")]
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["key"], ["project-list", "refusal", "registry"])
        self.assertEqual(records[0]["destination"], "local")

    def test_complete_discovery_preserves_registration_outcomes(self):
        for state in ("folder-not-found", "not-a-folder", "unreadable"):
            with self.subTest(state=state):
                self.register(self.registry, self.home, state=state)
                result, error = self.run_cli()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(error["kind"], "unavailable")
                record = json.loads(result.stderr.split("owner-asks-failure=", 1)[1])
                self.assertEqual(record["key"], ["project-list", "registration-unreadable", state])
                self.assertNotIn("activeCount", error)

    def tracker_api(self, comments, issues=None, assigned=("KEN-1",)):
        """Linear's API for the caller's reads, answered from COMMENTS on issue KEN-1 and any further ISSUES."""
        database = self.root / "tracker.json"
        database.write_text(json.dumps({"issues": dict(issues or {}, **{"KEN-1": comments}), "assigned": list(assigned)}))
        self.env.update(TRACKER_DATABASE=str(database), LINEAR_API_KEY_OVERRIDE="fixture", LINEAR_FORMAT="raw")
        self.executable("curl", "#!" + sys.executable + "\n" + TRACKER_API)
        return database

    @staticmethod
    def mirror(root, ask, comment):
        """The tracker-posted record lane-mail appends once owner_tracker_ask retains COMMENT: the ask's link."""
        path = root / "tmp/lane-mail/overseer/to-overseer.jsonl"
        # jq -c leaves U+2028/U+2029 raw inside its JSON lines: split at LF only.
        records = [json.loads(line) for line in path.read_text().split("\n") if line]
        envelope = next(record for record in records if record["id"] == ask)
        envelope["issue"] = "KEN-1"
        records.append({"id": ask + "-tracker", "kind": "tracker-posted", "at": envelope["at"],
                        "from": envelope["from"], "re": ask, "issue": "KEN-1", "tracker_label": "owner-waiting",
                        "tracker_comment": comment, "text": ""})
        path.write_text("".join(json.dumps(record) + "\n" for record in records))

    def test_each_registered_folder_answers_through_its_own_mailbox(self):
        self.tracker_api([request_comment("mirror", "Tracker copy")])
        # Folder names reach the reads exactly: a carriage return and a
        # trailing line feed are path bytes. Only a work tree holds a
        # mailbox: a folder outside any git repository, or git metadata with
        # no work tree, adds no asks. lane-mail itself refuses an ask there,
        # and so it does under a trailing line feed. A repository git cannot
        # read may hold asks, so it makes the list unavailable.
        cases = [("outside-git", "plain", False), ("git-metadata", "bare", False),
                 ("carriage\rreturn", "project", True), ("trailing\n", "project", False),
                 ("dangling-gitfile", "dangling", None)]
        for name, kind, asked in cases:
            with self.subTest(folder=name):
                folder = self.root / "registered" / name
                if kind == "project":
                    make_project(folder)
                else:
                    folder.mkdir(parents=True)
                if kind == "bare":
                    self.command(["git", "init", "-q", "--bare", folder], folder).check_returncode()
                if kind == "dangling":
                    (folder / ".git").write_text("gitdir: " + str(self.root / "gone") + "\n")
                expected = []
                if asked:
                    expected.append("Asked in " + name)
                    self.mirror(folder, self.mail(folder, "ask", expected[0], "--to", "owner", "--options", "a,b", "--reserved"),
                                "mirror")
                self.register(self.registry, self.home, folder)
                result, page = self.run_cli()
                if asked is None:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(page["kind"], "unavailable")
                    continue
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                self.assertEqual([row["what"] for row in page["rows"]], expected)

    def test_checkout_supplies_data_never_code_or_settings(self):
        # The folder ends like a plain-row worktree note; the registry's
        # folder field names it exactly.
        local = make_project(self.root / "local ' source;$  (worktree)")
        self.register(self.registry, local)
        # lane-mail's jq -c leaves U+2028/U+2029 raw inside its JSON lines.
        what = "Local original second line next paragraph"
        ask = self.mail(local, "ask", what, "--to", "owner", "--options", "a,b", "--reserved")
        self.tracker_api([request_comment("mirror", "Tracker copy")])
        self.mirror(local, ask, "mirror")
        marker = self.root / "executed-local-checkout"
        planted = 'from pathlib import Path\nPath(' + repr(str(marker)) + ').touch()\nraise SystemExit(91)\n'
        for module in ("json", "base64"):
            (local / (module + ".py")).write_text(planted)
        pythonpath = local / "checkout-python"
        pythonpath.mkdir()
        for module in ("argparse", "verbs", "http"):
            (pythonpath / (module + ".py")).write_text(planted)
        cases = [
            ("cwd", {}),
            ("pythonpath", {"PYTHONPATH": "./checkout-python"}),
            ("invalid", {"LINEAR_API_KEY": "invalid", "ORCH_STATE_DIR": "/nonexistent"}),
        ]
        for name, values in cases:
            with self.subTest(setting=name):
                (local / "kendex.settings.toml").write_text(
                    "[env]\n" + "".join(key + "=" + json.dumps(value) + "\n" for key, value in values.items()))
                result, page = self.run_cli()
                self.assertFalse(marker.exists(), "local-source-checkout-executed: " + name)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                row, = page["rows"]
                self.assertEqual((row["what"], row["askedAt"]), (what, self.box(local, "to-overseer")[0]["at"]))
                self.assertEqual(row["link"]["url"], request_comment("mirror")["url"])

    def test_remote_list_runs_caller_code_on_checkout_data(self):
        remote = make_project(self.root / "remote (owner)")
        self.command(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
                      "commit", "--allow-empty", "-m", "fixture"], remote).check_returncode()
        linked = self.root / "linked"
        self.command(["git", "worktree", "add", "-q", "-b", "linked", linked], remote).check_returncode()
        remote_registry = self.root / "remote-registry"
        log = self.root / "ssh.log"
        self.env.update(REMOTE_REGISTRY=str(remote_registry), SSH_LOG=str(log))
        (self.home / "kendex.settings.toml").write_text('[env]\nJARVIS_REMOTE_HOSTS="fixture"\n')
        # ssh HOST COMMAND, as watch.host_args spells it; each call is logged.
        self.executable("ssh", '#!' + BASH + '\nset -euo pipefail\n[ "$#" = 2 ] && [ "$1" = fixture ] || exit 96\n' +
                        'printf "%s\\n" "${2:0:40}" >>"$SSH_LOG"\n' +
                        'if [ "$2" = "kendex project list --json" ]; then cat "$REMOTE_REGISTRY"; exit; fi\n' +
                        'exec ' + BASH + ' -c "$2"\n')
        ask = self.mail(remote, "ask", "Remote original", "--to", "owner", "--options", "a,b", "--reserved")
        self.tracker_api([request_comment("mirror", "Tracker copy")])
        self.mirror(remote, ask, "mirror")
        # The host's transport cost is per destination: a worktree beside its
        # main checkout adds no call.
        calls = []
        for folders in ((remote,), (linked, remote)):
            self.register(remote_registry, *folders, main=remote if len(folders) > 1 else None)
            log.write_text("")
            result, page = self.run_cli()
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(page["activeCount"], 1)
            calls.append(len(log.read_text().splitlines()))
        self.assertEqual(calls[0], calls[1])
        executed = self.root / "executed-checkout-code"
        marker = 'from pathlib import Path\nPath(' + repr(str(executed)) + ').touch()\nraise SystemExit(91)\n'
        for checkout_code in (False, True):
            with self.subTest(checkout_code=checkout_code):
                if checkout_code:
                    for module in ("base64", "json"):
                        (remote / (module + ".py")).write_text(marker)
                    for package, entry in (("jarvis", "lib/jarvis-env.sh"), ("mailbox", "lane-mail"),
                                           ("mailbox", "lib/common-root.sh"), ("linear", "linear.sh")):
                        scripts = remote / ".agents/skills" / package / "scripts"
                        if scripts.is_symlink():
                            scripts.unlink()
                        path = scripts / entry
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_text('#!' + BASH + '\ntouch "' + str(executed) + '"\nexit 91\n')
                        path.chmod(0o755)
                    pythonpath = remote / "checkout-python"
                    pythonpath.mkdir()
                    for module in ("argparse", "verbs"):
                        (pythonpath / (module + ".py")).write_text(marker)
                    (remote / "kendex.settings.toml").write_text('[env]\nPYTHONPATH="./checkout-python"\n')
                result, page = self.run_cli()
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                row, = page["rows"]
                self.assertEqual((row["what"], row["link"]["url"]), ("Remote original", request_comment("mirror")["url"]))
                self.assertFalse(executed.exists(), "checkout-code-executed")

    def test_carried_presence_preserves_root_settings_and_permission(self):
        remote = make_project(self.root / "remote ' presence;$")
        marker = self.root / "executed-presence-checkout"
        (remote / "json.py").write_text('from pathlib import Path\nPath(' + repr(str(marker)) +
                                        ').touch()\nraise SystemExit(91)\n')
        registry = self.root / "presence-registry"
        registry.write_text(str(remote) + "\n")
        self.env.update(REMOTE_ROOT=str(remote), REMOTE_REGISTRY=str(registry))
        self.executable("ssh", '#!' + BASH + '\nset -euo pipefail\ncd -- "$REMOTE_ROOT"\n' +
                        'export REGISTRY="$REMOTE_REGISTRY"\nexec ' + BASH + ' -s\n')
        # The production owner keeps the fd3 payload separate from this
        # permission dialogue. Only the local live-session answer is injected.
        code = '''import json,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import watch
settings=dict(JARVIS_LOG_DIR=sys.argv[3],JARVIS_CONTROL_HOST='',JARVIS_MAIN_HOST='',
              JARVIS_REMOTE_HOSTS='fixture',JARVIS_WAKE_SETTLE_SECS='0')
owner=watch.Watch(Path(sys.argv[2]),sys.argv[4],settings)
answers=iter(json.loads(sys.argv[5]))
owner.live=lambda: next(answers)
print(json.dumps(owner._presence('ssh:fixture')))
'''
        cases = [("renew", [True, True, True], 600, "ok"),
                 ("revoke", [True, True, False], 600, "skipped"),
                 ("refusal", [True, True, True], 0, "failed")]
        for name, permission, age, expected in cases:
            with self.subTest(name=name):
                hold = remote / (name + " ' hold;$")
                (remote / "kendex.settings.toml").write_text(
                    '[env]\nSLACK_JARVIS_SESSION_FILE=' + json.dumps(hold.name) +
                    '\nSLACK_JARVIS_SESSION_MAX_AGE=' + json.dumps(str(age)) + '\n')
                result = subprocess.run([sys.executable, "-c", code, str(LIB), str(self.home),
                                         str(self.root / "presence-log"), BASH, json.dumps(permission)],
                                        env=self.env, cwd=self.home, capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)
                rows = json.loads(result.stdout)
                self.assertEqual([(row[0], row[1]) for row in rows], [(str(remote), expected)])
                if expected == "failed":
                    self.assertEqual(rows[0][2]["key"], ["presence-settings", "refusal", "setting-invalid"])
                else:
                    self.assertIsNone(rows[0][2])
                self.assertEqual(hold.exists(), expected == "ok")
                self.assertFalse(marker.exists())

    def test_tracker_view_membership_and_exact_mirror(self):
        (self.home / "kendex.settings.toml").write_text(
            '[env]\nORCH_OWNER_EMAIL="owner@example.test"\nORCH_OWNER_ASK_LABEL="owner-waiting"\n')
        original = request_comment("request", "https://linear.app/example/profiles/owner Question")
        database = self.tracker_api([original])
        mode_path = database.with_suffix(".mode")
        result, page = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        row, = page["rows"]
        self.assertEqual((row["kind"], row["askedBy"]["id"], row["askedAt"], row["link"]["url"]),
                         ("tracker-item", original["user_id"], original["created_at"], original["url"]))
        payload = json.dumps({"requestId": "membership-later", "expectedRevision": row["revision"],
                              "until": owner_asks.iso(owner_asks.time.time() + 3600)})
        result, receipt = self.run_cli("later", None, payload, "--id", row["id"])
        self.assertEqual((result.returncode, receipt["state"]), (0, "snoozed"))
        state_path, = (self.root / "runtime").rglob("owner-asks.json")
        before = state_path.read_bytes()
        for mode in ("failed", "incomplete"):
            with self.subTest(mode=mode):
                mode_path.write_text(mode)
                result, unavailable = self.run_cli()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(unavailable["kind"], "unavailable")
                self.assertEqual(state_path.read_bytes(), before)
        mode_path.write_text("omitted")
        result, page = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual((page["activeCount"], page["snoozedCount"], page["rows"], page["complete"]), (0, 0, [], True))
        self.assertEqual(json.loads(state_path.read_text())["deltas"], {})

        # The real mailbox fold and both real Linear readers consume the
        # tracker-posted record: the request comment is the ask's mirror.
        mode_path.write_text("present")
        ask = self.mail(self.home, "ask", "Mirrored owner ask", "--to", "owner", "--options", "a,b", "--reserved")
        self.mirror(self.home, ask, "request")
        result, mirrored = self.run_cli()
        self.assertEqual(result.returncode, 0, "safe-mirror-read: " + result.stderr + result.stdout)
        self.assertEqual(mirrored["activeCount"], 1)
        self.assertEqual((mirrored["rows"][0]["kind"], mirrored["rows"][0]["what"], mirrored["rows"][0]["link"]["url"]),
                         ("jarvis-ask", "Mirrored owner ask", original["url"]))

    def test_list_reads_this_homes_tracker_and_mailboxes_within_its_budget(self):
        # The main home's tracker as read on 2026-11-22: posted owner asks on
        # 171 issues in the 30 days before and 22 open owner-gated items, here
        # through four overseer mailboxes. A whole `linear.sh issues get` took
        # 0.42 s on that home, so this tracker answers the requests 14 s holds
        # at that cost and refuses the next one. The list runs with a deadline
        # no CPU load reaches: the request count, not this runner's clock,
        # decides the claim.
        posted, assigned, mailboxes = 171, 22, 4
        limit = int(owner_asks.CALL_SECONDS / 0.42)
        (self.home / "kendex.settings.toml").write_text(
            '[env]\nORCH_OWNER_EMAIL="owner@example.test"\nORCH_OWNER_ASK_LABEL="owner-waiting"\n')
        requests = {"OWN-%d" % n: [request_comment("waiting-%d" % n, "https://linear.app/example/profiles/owner Waiting %d" % n)]
                    for n in range(assigned)}
        issues = ["ASK-%d" % n for n in range(posted)]
        mirrors = {issue: [request_comment("mirror-" + issue, "Posted ask on " + issue)] for issue in issues}
        log = self.tracker_api([], dict(requests, **mirrors), assigned=list(requests)).with_suffix(".log")
        self.env.update(TRACKER_REQUEST_LIMIT=str(limit))
        roots = [make_project(self.root / ("mailbox-%d" % n)) for n in range(mailboxes)]
        for number, root in enumerate(roots):
            template = self.mail(root, "ask", "Template", "--to", "owner", "--options", "a,b", "--reserved")
            path = root / "tmp/lane-mail/overseer/to-overseer.jsonl"
            records = [json.loads(line) for line in path.read_text().split("\n") if line]
            envelope, = [record for record in records if record["id"] == template]
            stem = template.rsplit("-", 1)[0]
            rows = []
            for issue in issues[number::mailboxes]:
                # Older than the tracker rows, so the first page holds asks.
                ask = dict(envelope, id="%s-%d" % (stem, len(rows) // 2 + 1), at="2026-10-31T00:00:00Z",
                           issue=issue, text="Asked on " + issue)
                rows += [ask, {"id": ask["id"] + "-tracker", "kind": "tracker-posted", "at": ask["at"], "from": ask["from"],
                               "re": ask["id"], "issue": issue, "tracker_label": "owner-waiting",
                               "tracker_comment": "mirror-" + issue, "text": ""}]
            path.write_text("".join(json.dumps(record) + "\n" for record in rows))
        self.register(self.registry, self.home, *roots)
        pages = -(-posted // 50) + -(-assigned // 50)
        for view in ("active", "snoozed"):
            with self.subTest(view=view), patch.dict(os.environ, dict(self.env, JARVIS_BASH=BASH), clear=True):
                log.write_text("")
                session = Session(str(self.home))
                session.path = session.path.with_name("owner-asks.json")
                session.deadline = owner_asks.time.monotonic() + 600
                owner = owner_asks.OwnerAsks(session, owner_asks.Sources(session, owner_asks.watch.config(BASH, str(self.home))))
                try:
                    with session.locked():
                        page = owner.page(owner.read(), view, None)
                except owner_asks.Unavailable as error:
                    self.fail("unavailable after %d tracker requests: %s" % (len(log.read_text().splitlines()), error))
                operations = log.read_text().splitlines()
                # Two collects, each one bulk read per 50 issues and no read per issue.
                self.assertLessEqual(len(operations), limit)
                self.assertEqual(sum(operation.startswith("IssueRefs") for operation in operations), 2 * pages)
                self.assertFalse({"ListComments", "GetIssueWithBundle"} & set(operations))
                self.assertEqual((page["activeCount"], page["snoozedCount"]), (posted + assigned, 0))
                self.assertEqual(bool(page["rows"]), view == "active")
                # Each ask links the mirror comment on its own issue.
                self.assertEqual({row["what"]: row["link"]["url"] for row in page["rows"]},
                                 {row["what"]: request_comment("mirror-" + row["what"].split()[-1])["url"]
                                  for row in page["rows"]})

    def test_satellite_uses_the_same_main_receipt_without_local_state(self):
        satellite = make_project(self.root / "satellite", overseer=False)
        (satellite / "kendex.settings.toml").write_text('[env]\nJARVIS_MAIN_HOST="main:' + str(self.home) + '"\n')
        self.executable("ssh", '#!' + BASH + '\nset -euo pipefail\nshift 4\nshift\nexec ' + BASH + ' -c "$1"\n')
        result, main = self.run_cli()
        result, remote = self.run_cli(home=satellite)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual((remote["homeId"], remote["revision"]), (main["homeId"], main["revision"]))
        self.assertEqual(len(list((self.root / "runtime").rglob("owner-asks.json"))), 1)


if __name__ == "__main__":
    unittest.main()
