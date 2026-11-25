"""Request identity, source evidence and the actual page/action operations."""
import argparse
import base64
import copy
from contextlib import redirect_stderr, redirect_stdout
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

from mail_world import BASH, MailWorld, REPO, control_account, make_project

LIB = Path(os.environ.get("JARVIS_TEST_SKILLS", str(REPO / "skills"))) / "jarvis/scripts/lib"
os.environ["JARVIS_BASH"] = BASH
sys.path.insert(0, str(LIB))
import owner_asks
from session import Refusal, Session


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
# beside it and each filtered comment request to .comment-ids. Past
# TRACKER_REQUEST_LIMIT requests, the tracker refuses. A
# create appends its input and Authorization header to a .writes file and,
# while a .create file lists outcomes, takes the first: "lost" stores the
# comment and answers HTTP 500, "failed" answers 500 alone. As Linear keeps a
# comment id unique, a create naming a stored id is refused.
TRACKER_API = r'''
import json, os, re, sys
from pathlib import Path
config = sys.stdin.read()
payload = json.loads(json.loads(next(line[7:] for line in config.splitlines() if line.startswith('data = '))))
query, variables = payload['query'], payload.get('variables') or {}
path = Path(os.environ['TRACKER_DATABASE'])
database = json.loads(path.read_text())
mode_path = path.with_suffix('.mode')
mode = mode_path.read_text() if mode_path.exists() else 'present'
operation = next(name for name in ('GetUserByEmail', 'TeamKeys', 'ListIssues', 'GetIssueWithBundle', 'ListComments',
                                   'IssueRefs', 'BulkGetComments', 'CreateComment', 'OwnerReply', 'OwnerRuling') if name in query)
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
def stored(key):
    return next(((identifier, row) for identifier, rows in database['issues'].items() for row in rows if row['id'] == key),
                (None, None))
if operation == 'CreateComment':
    fields = variables['input']
    authorization = next(line for line in config.splitlines() if 'Authorization: ' in line)
    with path.with_suffix('.writes').open('a') as writes:
        writes.write(json.dumps({'input': fields, 'authorization': authorization}) + '\n')
    create = path.with_suffix('.create')
    outcomes = create.read_text().split() if create.exists() else []
    outcome = outcomes.pop(0) if outcomes else 'stored'
    create.write_text(' '.join(outcomes))
    if stored(fields.get('id'))[1] is not None:
        print(json.dumps({'errors': [{'message': 'Comment id is taken'}]}) + '___HTTP_CODE___200', end='')
        sys.exit(0)
    if outcome != 'failed':
        issue_ref = fields['issueId']
        identifier = issue_ref[:-len('-uuid')] if issue_ref.endswith('-uuid') else issue_ref
        actor = 'app-id' if 'Bearer tracker-app-fixture' in authorization else 'owner-id'
        comment_id = fields.get('id') or 'minted-%d' % len(database['issues'][identifier])
        database['issues'][identifier].append({
            'id': comment_id, 'body': fields['body'],
            'user_id': actor, 'user': 'Owner' if actor == 'owner-id' else 'Application', 'user_email': 'owner@example.test',
            'created_at': '2026-11-02T00:00:00Z', 'updated_at': '2026-11-02T00:00:00Z',
            'parent_id': fields.get('parentId'), 'url': 'https://linear.app/example/issue/' + identifier + '#reply'})
        path.write_text(json.dumps(database))
    if outcome in ('lost', 'failed'):
        print('___HTTP_CODE___500', end='')
        sys.exit(0)
    identifier, row = stored(comment_id)
    if outcome == 'malformed':
        row = dict(row, id='wrong-receipt-id')
    data = {'commentCreate': {'success': True, 'comment': {
        'id': row['id'], 'body': row['body'], 'createdAt': row['created_at'], 'updatedAt': row['updated_at'],
        'user': {'name': row['user'], 'email': row['user_email']}, 'issue': {'identifier': identifier, 'updatedAt': row['updated_at']}}}}
elif operation in ('OwnerReply', 'OwnerRuling'):
    identifier, row = stored(variables['id'])
    if row is None:
        print(json.dumps({'errors': [{'message': 'Entity not found: Comment'}]}) + '___HTTP_CODE___200', end='')
        sys.exit(0)
    data = {'comment': {'id': row['id'], 'body': row['body'], 'parent': {'id': row['parent_id']} if row['parent_id'] else None,
                        'issue': {'id': identifier + '-uuid', 'identifier': identifier}}}
elif 'GetUserByEmail' in query:
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
elif operation == 'BulkGetComments':
    ids = variables['filter']['id']['in']
    cursor = variables.get('after') if re.search(r'\bafter\s*:\s*\$after\b', query) else None
    with path.with_suffix('.comment-ids').open('a') as log:
        log.write(json.dumps({'after': cursor, 'ids': ids}) + '\n')
    selected = set(ids)
    matches = [row for rows in database['issues'].values() for row in rows if row['id'] in selected]
    offset = int(cursor or 0)
    end = offset + variables['first']
    page = connection([comment(row) for row in matches[offset:end]])
    if end < len(matches):
        page['pageInfo'] = {'hasNextPage': True, 'endCursor': str(end)}
    data = {'comments': page}
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
    """The public source projection, and the delivery owner's answers: each
    OUTCOMES entry, True, False or an exception, answers one delivery."""
    def __init__(self, home, count=1):
        self.data = projection(home, count)
        self.collections = 0
        self.deliveries, self.outcomes = [], []

    stable = owner_asks.Sources.stable

    def collect(self, requests=()):
        self.collections += 1
        return copy.deepcopy(self.data)

    def deliver(self, route, body, key, retry):
        self.deliveries.append({"route": route, "body": body, "key": key, "retry": retry})
        outcome = self.outcomes.pop(0) if self.outcomes else True
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


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

    def act(self, action, row, request_id, owner=None, **fields):
        owner = owner or self.owner
        request = {"requestId": request_id, "expectedRevision": row["revision"], **fields}
        with owner.session.locked():
            return owner.act(owner.read(), action, row["id"], request)

    def later(self, row, request_id, owner=None, **fields):
        return self.act("later", row, request_id, owner, **fields)

    def test_distinct_comments_exact_mirrors_and_original_metadata(self):
        data = projection(str(self.home), 2)
        first = data["tracker"]["requests"][0]["comment"]
        ask = {"id": "actual-mail-id", "from": "overseer:repo", "at": "2026-10-30T01:00:00Z", "text": "Mailbox original",
               "tracker_posted": True, "issue": "KEN-1", "tracker_comment": first["id"]}
        data["mailboxes"] = [{"destination": "local", "root": "/canonical/repo", "asks": [ask], "outward": {"rows": [ask]},
                              "links": {ask["id"]: {"url": first["url"]}}}]
        rows, _ = owner_asks.source_rows(data)
        self.assertEqual(len(rows), 2)
        self.assertEqual({row["askedBy"]["id"] for row in rows.values()}, {"overseer:repo", "requester"})
        self.assertEqual({row["askedAt"] for row in rows.values()}, {"2026-10-30T01:00:00Z", first["created_at"]})
        for linked in (False, True):
            with self.subTest(confirmed=linked):
                ask["tracker_posted"] = linked
                ask["tracker_comment"] = "unrelated"
                rows, _ = owner_asks.source_rows(data)
                self.assertEqual(len(rows), 3)
        data["mailboxes"][0]["asks"].append(dict(ask, id="another-real-ask"))
        data["mailboxes"][0]["links"]["another-real-ask"] = {"url": first["url"]}
        self.assertEqual(len(owner_asks.source_rows(data)[0]), 4)

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
        self.assertEqual(self.source.collections, 2)
        self.now += 1
        ids = []
        pages = [first]
        for _ in range(2):
            cursor = pages[-1]["nextCursor"]
            self.assertIsNotNone(cursor)
            pages.append(self.page(cursor=cursor, owner=self.new_owner()))
            self.assertNotEqual(pages[-1]["nextCursor"], cursor)
        self.assertEqual(self.source.collections, 2)
        for page in pages:
            self.assertLessEqual(len(page["rows"]), 32)
            self.assertLessEqual(len(owner_asks.encoded(page).encode()) + 1, 16 * 1024)
            self.assertEqual(page["activeCount"], 70)
            self.assertEqual(page["revision"], first["revision"])
            self.assertEqual(page["observedAt"], first["observedAt"])
            ids.extend(row["id"] for row in page["rows"])
        self.assertEqual([page["complete"] for page in pages], [False, False, True])
        self.assertIsNone(pages[-1]["nextCursor"])
        self.assertEqual(len(ids), 70)
        self.assertEqual(len(set(ids)), 70)
        self.assertEqual(self.page("snoozed")["revision"], first["revision"])
        self.assertEqual(self.page(cursor=first["nextCursor"]), pages[1])
        self.assertEqual(self.source.collections, 4)

        refreshed = self.page()
        self.assertEqual(refreshed["revision"], first["revision"])
        self.assertEqual(self.source.collections, 6)
        with self.assertRaises(owner_asks.Unavailable):
            self.page(cursor=first["nextCursor"])
        self.assertEqual(self.source.collections, 6)

        self.source.data["tracker"]["requests"].pop()
        other_view = self.page("snoozed")
        self.assertEqual(other_view["activeCount"], 69)
        self.assertNotEqual(other_view["revision"], refreshed["revision"])
        self.assertEqual(self.source.collections, 8)
        with self.assertRaises(owner_asks.Unavailable):
            self.page(cursor=refreshed["nextCursor"])
        self.assertEqual(self.source.collections, 8)

        updated = self.page()
        self.assertEqual(updated["revision"], other_view["revision"])
        self.assertEqual(self.source.collections, 10)
        snooze = self.later(updated["rows"][0], "hide-row", until=owner_asks.iso(self.now + 3600))
        self.assertEqual(snooze["kind"], "accepted")
        self.assertEqual(self.source.collections, 12)
        with self.assertRaises(owner_asks.Unavailable):
            self.page(cursor=updated["nextCursor"])
        self.assertEqual(self.source.collections, 12)

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

    def test_reply_and_done_go_once_through_the_rows_own_conversation(self):
        # Each source's row answers through its own conversation: a mailbox
        # ask through its mailbox, a tracker item under its question.
        worlds = [("tracker", projection, {"source": "linear", "issueUuid": "issue-uuid", "question": "request-0"}),
                  ("mailbox", mailbox_projection,
                   {"source": "mailbox", "destination": "local", "root": "/canonical/repo", "ask": "mail-ask"})]
        actions = [("reply", "Use the second option.", "open", "Use the second option."),
                   ("done", "Merged as abc123.", "checking", owner_asks.DONE_CLAIM + "\n\nMerged as abc123."),
                   ("done", "", "checking", owner_asks.DONE_CLAIM)]
        for (name, world, route), (action, text, shown, body) in itertools.product(worlds, actions):
            with self.subTest(source=name, action=action, text=text):
                self.owner.session.path.unlink(missing_ok=True)
                self.source.data, self.source.deliveries = world(str(self.home)), []
                row = self.page()["rows"][0]
                receipt = self.act(action, row, "act-" + action, text=text)
                self.assertEqual((receipt["kind"], receipt["state"], receipt["cause"]), ("accepted", shown, ""))
                delivery, = self.source.deliveries
                self.assertEqual((delivery["route"], delivery["body"], delivery["retry"]), (route, body, False))
                # An acknowledged request answers its receipt again and sends nothing.
                self.assertEqual(self.act(action, row, "act-" + action, text=text), receipt)
                self.assertEqual(len(self.source.deliveries), 1)
                # The fake delivery does not change canonical source evidence.
                after, = self.page()["rows"]
                self.assertEqual((after["id"], after["state"]), (row["id"], shown))
        refusals = [("blank reply", "reply", {"text": " \n"}, True, "open"),
                    ("text not a string", "done", {"text": 7}, True, "open"),
                    ("stale revision", "reply", {"text": "Yes", "expectedRevision": "older"}, True, "open"),
                    ("closed first", "reply", {"text": "Yes"}, False, "closed")]
        for name, action, fields, outcome, shown in refusals:
            with self.subTest(refusal=name):
                self.owner.session.path.unlink(missing_ok=True)
                self.source.data, self.source.deliveries, self.source.outcomes = mailbox_projection(str(self.home)), [], [outcome]
                row = self.page()["rows"][0]
                request = dict({"requestId": name, "expectedRevision": row["revision"]}, **fields)
                with self.owner.session.locked():
                    receipt = self.owner.act(self.owner.read(), action, row["id"], request)
                self.assertEqual((receipt["kind"], receipt["state"]), ("refused", shown))
                self.assertTrue(owner_asks.printable(receipt["cause"]))
                self.assertEqual(len(self.source.deliveries), int(outcome is False))

    def test_uncertain_delivery_settles_only_by_its_own_identity(self):
        for action in ("reply", "done"):
            with self.subTest(action=action):
                self.owner.session.path.unlink(missing_ok=True)
                self.source.data, self.source.deliveries = projection(str(self.home)), []
                self.source.outcomes = [owner_asks.Unavailable(owner_asks.DELIVERY_UNCONFIRMED)]
                row = self.page()["rows"][0]
                with self.assertRaises(owner_asks.Unavailable):
                    self.act(action, row, "uncertain", text="Yes")
                self.assertIsNone(self.owner.read()["requests"].get("uncertain", {}).get("receipt", "unsaved"))
                # The list moved on meanwhile; the retry still names the saved
                # delivery, with its identity, and no revision test.
                self.source.data["tracker"]["requests"][0]["comment"]["body"] += " edited"
                receipt = self.act(action, row, "uncertain", text="Yes")
                self.assertEqual(receipt["kind"], "accepted")
                first, retry = self.source.deliveries
                self.assertEqual((retry["key"], retry["body"], retry["route"], retry["retry"]),
                                 (first["key"], first["body"], first["route"], True))
                # Another payload under the identity refuses and sends nothing.
                self.assertEqual(self.act(action, row, "uncertain", text="No")["kind"], "refused")
                self.assertEqual(len(self.source.deliveries), 2)

    def test_done_checking_survives_later_and_ends_with_membership(self):
        row = self.page()["rows"][0]
        self.assertEqual(self.later(row, "snooze", until=owner_asks.iso(self.now + 60))["state"], "snoozed")
        snoozed = self.page("snoozed")["rows"][0]
        # Done on a snoozed ask replaces the snooze with the claim.
        self.assertEqual(self.act("done", snoozed, "claim", text="Shipped")["state"], "checking")
        checking = self.page()["rows"][0]
        self.assertEqual((checking["state"], checking["snoozedUntil"]), ("checking", None))
        self.assertEqual(self.later(checking, "snooze-claim", until=owner_asks.iso(self.now + 60))["state"], "snoozed")
        self.now += 60
        self.assertEqual(self.page()["rows"][0]["state"], "checking")
        self.source.data["tracker"]["requests"] = []
        self.assertEqual(self.page()["rows"], [])
        self.assertEqual(self.owner.read()["deltas"], {})

    def test_snooze_restores_and_follows_complete_current_view_membership(self):
        row = self.page()["rows"][0]
        self.assertEqual(row["actions"], {name: {"allowed": True, "reason": ""} for name in ("reply", "done", "later")})
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
                    # The closure is the stream's last line, after the command's.
                    payload = call.kwargs["data"].rsplit("\n", 1)[1]
                    self.assertEqual(json.loads(payload)["files"]["mailbox/scripts/lane-mail"], caller)
                else:
                    self.assertEqual(argv[0], BASH)
                    self.assertIn(str(packages / "mailbox/scripts/lane-mail"), argv)

    def test_tracker_and_destinations_are_read_side_by_side(self):
        # Each chain's first read waits, bounded, until every chain has
        # started: the tracker, the local destination and one remote host.
        # Read in turn, a chain that starts first waits out its bound.
        session = self.owner.session
        session.deadline = owner_asks.time.monotonic() + 60
        sources = owner_asks.Sources(session, {"JARVIS_MAIN_HOST": "", "JARVIS_REMOTE_HOSTS": "r1"})
        started = {chain: threading.Event() for chain in ("tracker", "local", "ssh:r1")}
        waited = []

        def meet(own):
            started[own].set()
            bound = owner_asks.time.monotonic() + 5
            if not all(event.wait(max(0, bound - owner_asks.time.monotonic())) for event in started.values()):
                waited.append(own)

        def settings(package, script, args=()):
            meet("tracker")
            return {"configured": False, "cause": "settings-unset"}

        def registered(target):
            meet(target.key)
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
                 'result = watch.run(watch.host_args(target, "bash -s"), data=command + "\\n" + payload,',
                 'result = watch.run(["ssh", target.host, "bash -s"], data=command + "\\n" + payload,',
                 "OwnerAsksContract.test_reads_run_caller_code_as_the_destination_account", "(destination='ssh:control')"),
                # The command quoted through the host's login shell, the
                # route a host read took before it went to bash -s.
                ("jarvis/scripts/lib/owner_asks.py",
                 'watch.host_args(target, "bash -s"), data=command + "\\n" + payload,',
                 'watch.host_args(target, "bash -c " + shlex.quote(command)), data=payload,',
                 "PublicOwnerAsks.test_remote_read_answers_alike_under_each_login_shell", "(login='fish')"),
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
                # One chain waits for a worker until another chain ends.
                ("jarvis/scripts/lib/owner_asks.py", "max_workers=1 + len(targets)", "max_workers=2",
                 "OwnerAsksContract.test_tracker_and_destinations_are_read_side_by_side", None),
                # The main runs its own full deadline inside the satellite's.
                ("jarvis/scripts/lib/owner_asks.py", 'JARVIS_OWNER_ASK_BUDGET="$budget" ', "",
                 "PublicOwnerAsks.test_satellite_returns_the_main_answer_given_inside_its_budget", None),
                # A fresh delivery identity on every send: a retry after a
                # lost acknowledgement appends the answer twice.
                ("jarvis/scripts/lib/owner_asks.py", 'delivery = "owner-ask-" + key', 'delivery = "owner-ask-" + str(uuid.uuid4())',
                 "PublicOwnerAsks.test_mailbox_answers_land_once_in_the_asks_own_mailbox", "(destination='ssh:fixture')"),
                # A reply Linear mints its own id for.
                ("jarvis/scripts/lib/owner_asks.py", '"--id", key, "--no-attribution"', '"--no-attribution"',
                 "PublicOwnerAsks.test_tracker_answers_post_once_with_the_main_credential", "(action='reply', create='stored')"),
                # The owner's text posted under an agent's attribution line.
                ("jarvis/scripts/lib/owner_asks.py", '"--id", key, "--no-attribution", "--body-file"', '"--id", key, "--body-file"',
                 "PublicOwnerAsks.test_tracker_answers_post_once_with_the_main_credential", "(action='reply', create='stored')"),
                # A host shell left running after the bootstrap, which reads
                # the owner's text that follows the command as script.
                ("jarvis/scripts/lib/watch.py", 'command = ("exec python3 -I -c "', 'command = ("python3 -I -c "',
                 "PublicOwnerAsks.test_failed_answer_runs_none_of_its_text", None),
                # A retry that resends without reading whether the first landed.
                ("jarvis/scripts/lib/owner_asks.py", "        if retry:\n            read = ", "        if False:\n            read = ",
                 "PublicOwnerAsks.test_tracker_answers_post_once_with_the_main_credential", "(action='reply', create='lost')"),
                # The intent written only after the send.
                ("jarvis/scripts/lib/owner_asks.py", "        self.session.write(state)\n        return self.deliver(state, entry, retry=False)",
                 "        return self.deliver(state, entry, retry=False)",
                 "OwnerAsksContract.test_uncertain_delivery_settles_only_by_its_own_identity", "(action='reply')"),
                # A saved delivery judged again as a new request.
                ("jarvis/scripts/lib/owner_asks.py", "            return self.deliver(state, previous, retry=True)", "            pass",
                 "OwnerAsksContract.test_uncertain_delivery_settles_only_by_its_own_identity", "(action='reply')"),
                ("jarvis/scripts/lib/owner_asks.py", 'state["deltas"][key] = {"checking": True}', 'state["deltas"][key] = {}',
                 "OwnerAsksContract.test_done_checking_survives_later_and_ends_with_membership", None),
                ("jarvis/scripts/lib/owner_asks.py", "if result.returncode == 2 and CLOSED.match(result.stderr):", "if False:",
                 "PublicOwnerAsks.test_answer_to_a_closed_ask_adds_nothing", None),
                ("jarvis/scripts/lib/owner_asks.py",
                 'for name in $(compgen -e); do case $name in GIT_TRACE*) unset "$name" ;; esac; done\n    ', "",
                 "PublicOwnerAsks.test_each_registered_folder_answers_through_its_own_mailbox", "(folder='outside-git-traced')"),
                ("jarvis/scripts/lib/forward.py", 'reached is not None and reached in partial.split("\\n")', "False",
                 "PublicOwnerAsks.test_satellite_names_a_slow_main_apart_from_an_unreachable_one", "(main='reached')"),
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
        self.home = make_project(self.root / "main", overseer=self._testMethodName != "test_runtime_ruling_survives_tracker_actor_change")
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
        # read may hold asks, so it makes the list unavailable. Git's trace
        # output ahead of its die text leaves the outcome as it was.
        cases = [("outside-git", "plain", False), ("outside-git-traced", "plain", False), ("git-metadata", "bare", False),
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
                traced = {"GIT_TRACE": "1", "GIT_TRACE2": "1"} if name.endswith("-traced") else {}
                with patch.dict(self.env, traced):
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

    # ssh HOST COMMAND, as watch.host_args spells it, with COMMAND parsed by
    # the host's login shell LOGIN_SHELL. fish's language docs, § Quotes: in
    # single quotes only \' and \\ are escapes; in double quotes only \", \$,
    # \\ and a backslash-newline; fish 3.7.0 reads 'a\\b' as a\b where sh
    # keeps both backslashes. Syntax the model leaves out exits 98, so the
    # model never reads a command differently from fish unseen.
    LOGIN_SSH = r'''
import os, sys

def fish_words(text):
    words, word, quote, started, i = [], "", None, False, 0
    while i < len(text):
        c = text[i]
        escapes = {"'": "\\'", '"': '\\"$'}.get(quote, "")
        if quote is None and c in " \t\n":
            if started:
                words.append(word)
            word, started = "", False
        elif quote is None and c in "'\"":
            quote, started = c, True
        elif quote is None and (c.isalnum() or c in "-_./,:=@%+"):
            word, started = word + c, True
        elif quote is not None and c == quote:
            quote = None
        elif quote is not None and c == "\\" and i + 1 < len(text) and text[i + 1] in escapes:
            word, i = word + text[i + 1], i + 1
        elif quote == '"' and (c == "$" or text[i:i + 2] == "\\\n"):
            sys.exit(98)
        elif quote is not None:
            word += c
        else:
            sys.exit(98)
        i += 1
    if quote is not None:
        sys.exit(98)
    return words + [word] if started else words

if len(sys.argv) != 3 or sys.argv[1] != "fixture":
    sys.exit(96)
command = sys.argv[2]
if command == "kendex project list --json":
    with open(os.environ["REMOTE_REGISTRY"]) as registry:
        sys.stdout.write(registry.read())
    sys.exit()
argv = ["sh", "-c", command] if os.environ["LOGIN_SHELL"] == "sh" else fish_words(command)
os.execvp(argv[0], argv)
'''

    def test_remote_read_answers_alike_under_each_login_shell(self):
        remote = make_project(self.root / "remote")
        remote_registry = self.root / "remote-registry"
        self.register(remote_registry, remote)
        self.env.update(REMOTE_REGISTRY=str(remote_registry))
        (self.home / "kendex.settings.toml").write_text('[env]\nJARVIS_REMOTE_HOSTS="fixture"\n')
        self.executable("ssh", "#!" + sys.executable + "\n" + self.LOGIN_SSH)
        self.mail(remote, "ask", "Remote original", "--to", "owner", "--options", "a,b", "--reserved")
        self.tracker_api([])
        rows = {}
        for login in ("sh", "fish"):
            with self.subTest(login=login):
                self.env["LOGIN_SHELL"] = login
                result, page = self.run_cli()
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                rows[login] = page["rows"]
                self.assertEqual([row["what"] for row in rows[login]], ["Remote original"])
                self.assertEqual(rows[login], rows["sh"])

    def test_mailbox_reads_leave_their_stdin_unread(self):
        # A host read runs them with bash -s's script stream as stdin, where
        # a read would take the bytes after their own command.
        ask = self.mail(self.home, "ask", "Question", "--to", "owner", "--options", "a,b", "--reserved")
        mail = LIB.parents[2] / "mailbox/scripts/lane-mail"
        reads = [("pending", ["--to", "owner"]), ("events", ["--box", "to-overseer"])]
        for verb, options in reads:
            with self.subTest(verb=verb):
                read, write = os.pipe()
                os.write(write, b"stream\n")
                os.close(write)
                with os.fdopen(read, "rb") as stream:
                    result = subprocess.run([BASH, str(mail), verb, "--item", "overseer", "--root", str(self.home), *options],
                                            stdin=stream, cwd=self.home, env=self.env, capture_output=True, text=True, timeout=60)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(ask, result.stdout)
                    self.assertEqual(stream.read(), b"stream\n")

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
        self.command([LIB.parents[2] / "mailbox/scripts/lane-mail", "resolve", "--item", "overseer", "--id", ask],
                     self.home).check_returncode()
        result, page = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual((page["activeCount"], page["rows"]), (0, []))

    def test_tracker_asks_settle_by_exact_question_comment(self):
        (self.home / "kendex.settings.toml").write_text(
            '[env]\nORCH_OWNER_EMAIL="owner@example.test"\nORCH_OWNER_ASK_LABEL="owner-waiting"\n')
        mention = "https://linear.app/example/profiles/owner "
        answered = request_comment("answered", mention + "Answered through a reply chain")
        replaced = request_comment("replaced", "**Replaced** by a newer question. Answer that one only.\n\n~~" + mention + "Old question~~")
        waiting = request_comment("waiting", mention + "Still needs an answer")
        unstruck = request_comment("unstruck", "**Replaced** by a newer question. Answer that one only.\n\n" + mention + "A real question")
        discussion = dict(request_comment("discussion", "Could you confirm?"), parent_id="answered")
        owner = {"user_id": "owner-id", "user": "Owner", "user_email": "owner@example.test"}
        reply = dict(request_comment("reply", "Proceed"), parent_id="discussion", **owner)
        no_answer = "This question closed with no answer.\n"
        nonowner_reply = dict(request_comment("nonowner", "I can help"), parent_id="waiting")
        quoted_mark = dict(request_comment("quoted-mark", no_answer), parent_id="waiting", user_id="peer")
        malformed_mark = dict(request_comment("malformed-mark", no_answer + "That closure was premature."), parent_id="waiting")
        wrong_item_reply = dict(request_comment("wrong-item", "Proceed"), parent_id="waiting", **owner)
        top_level_answer = dict(request_comment("top-level", "Proceed"), **owner)
        done_claim = dict(request_comment("claim", owner_asks.DONE_CLAIM + "\n\nDone evidence"), parent_id="waiting", **owner)
        self.tracker_api([answered, replaced, waiting, unstruck, discussion, reply, nonowner_reply,
                          quoted_mark, malformed_mark,
                          top_level_answer, done_claim], {"KEN-2": [wrong_item_reply]}, assigned=["KEN-1", "KEN-2"])

        result, page = self.run_cli()

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual({row["link"]["url"] for row in page["rows"]}, {waiting["url"], unstruck["url"]})
        self.assertEqual(page["activeCount"], 2)

    def test_runtime_ruling_survives_tracker_actor_change(self):
        (self.home / "kendex.settings.toml").write_text(
            '[env]\nORCH_OWNER_EMAIL="owner@example.test"\nORCH_OWNER_ASK_LABEL="owner-waiting"\n')
        issue, question_id = "KEN-7", "01234567-89ab-4def-8123-456789abcdef"
        bodies = {
            "explicit": "This question closed with no answer.\n",
            "text": "This question closed on your answer.\n\n**Decided by**: owner\n\n**Ruling**: Approved.\n",
            "default": "This question closed at its deadline with no answer, so its recommendation stands.\n"
                       "\n**Decided by**: recommendation\n\n**Ruling**: yes\n",
            "legacy": "This question closed on its answer.\n\n**Ruling**: Historical answer.\n",
        }
        # The orch watch integration supplies the actual argv for all four
        # outcomes. The standalone Jarvis suite also drives the shipped writer.
        native_args = json.loads(os.environ.get("KENDEX_TEST_RULING_ARGS", "null"))
        argv_by_kind = native_args if native_args is not None else {
            kind: ["comments", "create", issue + "-uuid", "--body", body, "--parent", question_id, "--owner-ruling"]
            for kind, body in bodies.items()}
        self.assertEqual(set(argv_by_kind), set(bodies))
        # Exercise the default attribution serializer without building a second
        # watch binary just to resolve unrelated lane attribution in this fixture.
        writer = self.root / "writer" / "linear"
        shutil.copytree(LIB.parents[2] / "linear", writer)
        linear = writer / "scripts/linear.sh"
        mention = "https://linear.app/example/profiles/owner "
        peer = request_comment("11111111-2222-4333-8444-555555555555", mention + "Peer discussion")
        direct = request_comment("direct", mention + "Owner replies in Linear")
        owner_reply = dict(request_comment("owner-reply", "Proceed"), parent_id=direct["id"], user_id="owner-id")
        cases = [(kind, "prior-actor") for kind in bodies] + [("explicit", "app-id")]
        for kind, asker in cases:
            with self.subTest(ruling=kind, asker=asker):
                question = dict(request_comment(question_id, mention + "Closed question"), user_id=asker)
                database = self.tracker_api([], {issue: [question, peer, direct, owner_reply]}, assigned=[issue])
                self.env.pop("LINEAR_API_KEY_OVERRIDE")
                self.env["LINEAR_APP_TOKEN"] = "tracker-app-fixture"
                args = argv_by_kind[kind]
                database.with_suffix(".create").write_text("malformed" if kind == "text" else "")
                result = self.command([BASH, linear, *args], self.home)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                copied = self.command([BASH, linear, "comments", "create", issue, "--body", bodies[kind],
                                       "--parent", peer["id"], "--no-attribution"], self.home)
                self.assertEqual(copied.returncode, 0, copied.stderr + copied.stdout)
                world = json.loads(database.read_text())
                ruling, = [row for row in world["issues"][issue] if row["parent_id"] == question_id]
                self.assertEqual(ruling["user_id"], "app-id")
                self.assertEqual(ruling["body"].split("\n\n", 1)[1], bodies[kind] + "\n")
                result, page = self.run_cli()
                self.assertEqual((result.returncode, page.get("activeCount")), (0, 1), result.stderr + result.stdout)
                self.assertEqual(page["rows"][0]["link"]["url"], peer["url"])

                if kind == "explicit" and asker == "prior-actor":
                    repeated = self.command([BASH, linear, *args], self.home)
                    self.assertEqual(repeated.returncode, 0, repeated.stderr + repeated.stdout)
                    self.assertEqual(json.loads(repeated.stdout)["data"]["comment"]["id"], ruling["id"])
                    self.assertEqual(json.loads(database.read_text()), world)
                    ruling["parent_id"] = peer["id"]
                    database.write_text(json.dumps(world))
                    collision = self.command([BASH, linear, *args], self.home)
                    self.assertNotEqual(collision.returncode, 0)
                    result, page = self.run_cli()
                    self.assertEqual((result.returncode, page.get("activeCount")), (0, 2))

    def test_replacement_outcome_uses_the_predecessors_exact_comment_and_item(self):
        (self.home / "kendex.settings.toml").write_text(
            '[env]\nORCH_OWNER_EMAIL="owner@example.test"\nORCH_OWNER_ASK_LABEL="owner-waiting"\n')
        mention = "https://linear.app/example/profiles/owner "
        old = request_comment("earlier", mention + "Earlier question")
        waiting = request_comment("waiting", mention + "Another question")
        self.tracker_api([old, waiting])
        ask = self.mail(self.home, "ask", "Replacement question", "--to", "owner", "--options", "a,b", "--reserved")
        self.command([LIB.parents[2] / "mailbox/scripts/lane-mail", "resolve", "--item", "overseer", "--id", ask],
                     self.home).check_returncode()
        path = self.home / "tmp/lane-mail/overseer/to-overseer.jsonl"
        records = [json.loads(line) for line in path.read_text().split("\n") if line]
        replacing = next(record for record in records if record["id"] == ask)
        replacing["replaces"] = [
            {"id": "old-ask", "tracker_comment": old["id"], "identity": {"identifier": "KEN-99", "uuid": "KEN-1-uuid"}},
            {"id": "other-ask", "tracker_comment": waiting["id"], "identity": {"identifier": "KEN-1", "uuid": "KEN-2-uuid"}},
        ]
        outcome = {"kind": "replacement", "from": replacing["from"], "re": ask, "at": replacing["at"], "text": ""}
        for status, expected in (("incomplete", [old, waiting]), ("in-force", [waiting])):
            with self.subTest(outcome=status):
                event = dict(outcome, id=ask + "-replacement-" + status, outcome=status)
                path.write_text("".join(json.dumps(record) + "\n" for record in [*records, event]))
                result, page = self.run_cli()
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                self.assertEqual({row["link"]["url"] for row in page["rows"]}, {comment["url"] for comment in expected})

    def act_cli(self, action, row, request_id, **fields):
        payload = json.dumps(dict({"requestId": request_id, "expectedRevision": row["revision"]}, **fields))
        return self.run_cli(action, None, payload, "--id", row["id"])

    # ssh fixture COMMAND, run here. While SSH_DROP names a file, the next
    # answer send runs whole and then loses its answer, as a dropped
    # connection does. While SSH_BREAK names a file, an answer send runs with
    # a TMPDIR that does not exist, so its mktemp fails before it reads the
    # text. SSH_STREAM keeps every byte the main sent.
    DROPPING_SSH = r'''
import os, subprocess, sys
from pathlib import Path
if len(sys.argv) != 3 or sys.argv[1] != "fixture":
    sys.exit(96)
data = sys.stdin.buffer.read()
with open(os.environ["SSH_STREAM"], "ab") as stream:
    stream.write(data)
answer = b"send --item overseer --root" in data
env = dict(os.environ)
if answer and Path(os.environ.get("SSH_BREAK", "/nonexistent")).exists():
    env["TMPDIR"] = os.environ["SSH_BREAK"] + "/missing"
result = subprocess.run([os.environ["SSH_BASH"], "-c", sys.argv[2]], input=data, capture_output=True, env=env)
drop = Path(os.environ["SSH_DROP"])
if drop.exists() and answer:
    drop.unlink()
    sys.exit(255)
sys.stdout.buffer.write(result.stdout)
sys.stderr.buffer.write(result.stderr)
sys.exit(result.returncode)
'''

    def test_mailbox_answers_land_once_in_the_asks_own_mailbox(self):
        # The local home, and a control host whose overseers run as their own
        # account with credentials of their own. An answer reaches either as
        # mailbox data; no credential of either side reaches the other.
        account = self.root / "overseer-account"
        clone = make_project(account / "dev/app")
        sudo_log = control_account(self.executable, self.bin, account, [clone])
        self.register(account / "registry", clone)
        (clone / ".env.local").write_text('LINEAR_API_KEY="destination-linear-key"\nSLACK_BOT_TOKEN="destination-slack"\n')
        stream, drop = self.root / "ssh-stream", self.root / "ssh-drop"
        self.env.update(ACCOUNT=str(account), SSH_STREAM=str(stream), SSH_DROP=str(drop), SSH_BASH=BASH)
        self.executable("ssh", "#!" + sys.executable + "\n" + self.DROPPING_SSH)
        (self.home / "kendex.settings.toml").write_text('[env]\nJARVIS_CONTROL_HOST="fixture"\nJARVIS_CONTROL_USER="overseer"\n')
        writes = self.tracker_api([]).with_suffix(".writes")
        self.env["LINEAR_API_KEY_OVERRIDE"] = "main-linear-key"
        roots = {"local": self.home, "ssh:fixture": clone}
        asks = {name: self.mail(root, "ask", "Asked at " + name, "--to", "owner", "--options", "a,b", "--reserved")
                for name, root in roots.items()}
        for name, root in roots.items():
            with self.subTest(destination=name):
                result, page = self.run_cli()
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                row, = [row for row in page["rows"] if row["what"] == "Asked at " + name]
                if name != "local":
                    # The answer lands, its acknowledgement is lost, and the
                    # identical retry names the landed answer.
                    drop.touch()
                    result, lost = self.act_cli("reply", row, "reply-" + name, text="Second option")
                    self.assertEqual((result.returncode, lost.get("kind")), (1, "unavailable"), result.stderr)
                result, receipt = self.act_cli("reply", row, "reply-" + name, text="Second option")
                self.assertEqual((result.returncode, receipt.get("kind"), receipt.get("state")), (0, "accepted", "open"), result.stderr)
                result, page = self.run_cli()
                row, = [row for row in page["rows"] if row["what"] == "Asked at " + name]
                result, receipt = self.act_cli("done", row, "done-" + name, text="Merged")
                self.assertEqual((result.returncode, receipt.get("kind"), receipt.get("state")), (0, "accepted", "checking"),
                                 result.stderr)
                answers = [(envelope["from"], envelope["re"], envelope["closes"], envelope["text"])
                           for envelope in self.box(root, "to-lane") if envelope["kind"] == "answer"]
                self.assertEqual(answers, [("owner", asks[name], False, "Second option"),
                                           ("owner", asks[name], False, owner_asks.DONE_CLAIM + "\n\nMerged")])
                result, page = self.run_cli()
                row, = [row for row in page["rows"] if row["what"] == "Asked at " + name]
                self.assertEqual(row["state"], "checking")
        self.assertEqual({line.split("\t", 1)[0] for line in sudo_log.read_text().splitlines()}, {"overseer"})
        self.assertFalse(writes.exists())
        self.assertNotIn(b"main-linear-key", stream.read_bytes())

    def test_failed_answer_runs_none_of_its_text(self):
        # A host whose answer send fails before it reads the owner's text,
        # text that holds shell commands. None of it runs on the host.
        remote = make_project(self.root / "remote")
        remote_registry = self.root / "remote-registry"
        self.register(remote_registry, remote)
        broken, marker = self.root / "broken", self.root / "text-ran"
        broken.mkdir()
        self.env.update(REMOTE_REGISTRY=str(remote_registry), SSH_STREAM=str(self.root / "ssh-stream"),
                        SSH_DROP=str(self.root / "ssh-drop"), SSH_BREAK=str(broken), SSH_BASH=BASH)
        self.executable("ssh", "#!" + sys.executable + "\n" + 'import os, sys\n'
                        'if sys.argv[2:] == ["kendex project list --json"]:\n'
                        '    sys.stdout.write(open(os.environ["REMOTE_REGISTRY"]).read())\n    sys.exit()\n' + self.DROPPING_SSH)
        (self.home / "kendex.settings.toml").write_text('[env]\nJARVIS_REMOTE_HOSTS="fixture"\n')
        self.tracker_api([])
        self.mail(remote, "ask", "Remote question", "--to", "owner", "--options", "a,b", "--reserved")
        result, page = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        row, = page["rows"]
        text = "Ran `touch %s` already\ntouch %s\n$(touch %s)" % (marker, marker, marker)
        result, answer = self.act_cli("reply", row, "broken-host", text=text)
        self.assertEqual((result.returncode, answer.get("kind")), (1, "unavailable"), result.stderr)
        self.assertFalse(marker.exists())
        self.assertEqual([row for row in self.box(remote, "to-lane") if row["kind"] == "answer"], [])

    def test_answer_to_a_closed_ask_adds_nothing(self):
        # A delegate's close that lands between the list and the answer.
        ask = self.mail(self.home, "ask", "Question", "--to", "owner", "--options", "a,b", "--reserved")
        self.command([LIB.parents[2] / "mailbox/scripts/lane-mail", "resolve", "--item", "overseer", "--id", ask],
                     self.home).check_returncode()
        with patch.dict(os.environ, dict(self.env, JARVIS_BASH=BASH), clear=True):
            session = Session(str(self.home))
            session.path = session.path.with_name("owner-asks.json")
            session.deadline = owner_asks.time.monotonic() + 60
            sources = owner_asks.Sources(session, {"JARVIS_MAIN_HOST": ""})
            route = {"source": "mailbox", "destination": "local", "root": str(self.home), "ask": ask}
            try:
                delivered = sources.deliver(route, "Too late", "late-key", False)
            except owner_asks.Unavailable as error:
                delivered = error
            self.assertIs(delivered, False)
        self.assertEqual([row["kind"] for row in self.box(self.home, "to-lane")], ["resolution"])

    def test_tracker_answers_post_once_with_the_main_credential(self):
        (self.home / "kendex.settings.toml").write_text(
            '[env]\nORCH_OWNER_EMAIL="owner@example.test"\nORCH_OWNER_ASK_LABEL="owner-waiting"\n')
        original = request_comment("request", "https://linear.app/example/profiles/owner Question")
        cases = [("reply", "stored", "open"), ("reply", "lost", "open"), ("reply", "failed", "open"), ("done", "lost", "checking")]
        # The main home's one credential; an inherited one would outrank it.
        self.env = {key: value for key, value in self.env.items() if not key.startswith("LINEAR_")}
        for action, outcome, shown in cases:
            with self.subTest(action=action, create=outcome):
                database = self.tracker_api([original])
                self.env["LINEAR_API_KEY_OVERRIDE"] = "main-linear-key"
                writes, create = database.with_suffix(".writes"), database.with_suffix(".create")
                writes.unlink(missing_ok=True)
                create.write_text("" if outcome == "stored" else outcome)
                for state in (self.root / "runtime").rglob("owner-asks.json"):
                    state.unlink()
                result, page = self.run_cli()
                row, = page["rows"]
                request = action + "-" + outcome
                result, receipt = self.act_cli(action, row, request, text="Answer " + outcome)
                if outcome != "stored":
                    self.assertEqual((result.returncode, receipt.get("kind")), (1, "unavailable"))
                    result, receipt = self.act_cli(action, row, request, text="Answer " + outcome)
                self.assertEqual((result.returncode, receipt.get("kind"), receipt.get("state")), (0, "accepted", shown), result.stderr)
                replies = [comment for comment in json.loads(database.read_text())["issues"]["KEN-1"]
                           if comment["parent_id"] == original["id"]]
                self.assertEqual(len(replies), 1)
                # The owner's own text, opened by no agent attribution line.
                text = "Answer " + outcome
                self.assertEqual(replies[0]["body"].rstrip("\n"), owner_asks.DONE_CLAIM + "\n\n" + text if action == "done" else text)
                sent = [json.loads(line) for line in writes.read_text().splitlines()]
                self.assertEqual({(write["input"]["id"], write["input"]["issueId"], write["input"]["parentId"]) for write in sent},
                                 {(replies[0]["id"], "KEN-1-uuid", original["id"])})
                self.assertTrue(all("main-linear-key" in write["authorization"] for write in sent), sent)
                self.assertEqual(len(sent), 2 if outcome == "failed" else 1)

    def test_tracker_reply_settles_selected_question(self):
        (self.home / "kendex.settings.toml").write_text(
            '[env]\nORCH_OWNER_EMAIL="owner@example.test"\nORCH_OWNER_ASK_LABEL="owner-waiting"\n')
        mention = "https://linear.app/example/profiles/owner "
        outer = request_comment("outer", mention + "Outer question")
        for case, parent, actor in (("nested", outer["id"], "owner-id"), ("application", None, "app-id")):
            with self.subTest(case=case):
                question = dict(request_comment("selected", mention + "Answer this question"), parent_id=parent)
                database = self.tracker_api([outer, question], {"KEN-2": []}, assigned=["KEN-1", "KEN-2"])
                if actor == "app-id":
                    self.env.pop("LINEAR_API_KEY_OVERRIDE")
                    self.env["LINEAR_APP_TOKEN"] = "tracker-app-fixture"
                result, page = self.run_cli()
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                selected, = [row for row in page["rows"] if row["link"]["url"] == question["url"]]
                if parent is not None:
                    self.assertEqual(len({row["threadRef"] for row in page["rows"]}), 1)
                result, receipt = self.act_cli("reply", selected, case, text="Proceed")
                self.assertEqual((result.returncode, receipt.get("kind")), (0, "accepted"))
                world = json.loads(database.read_text())
                reply, = [comment for comment in world["issues"]["KEN-1"] if comment["body"].rstrip("\n") == "Proceed"]
                self.assertEqual((reply["parent_id"], reply["user_id"]), (question["id"], actor))

                if actor == "app-id":
                    moved = copy.deepcopy(world)
                    moved["issues"]["KEN-1"][-1]["parent_id"] = outer["id"]
                    database.write_text(json.dumps(moved))
                    result, page = self.run_cli()
                    self.assertEqual((result.returncode, page.get("activeCount")), (0, 2))
                    moved = copy.deepcopy(world)
                    moved["issues"]["KEN-2"].append(moved["issues"]["KEN-1"].pop())
                    database.write_text(json.dumps(moved))
                    result, page = self.run_cli()
                    self.assertEqual((result.returncode, page.get("activeCount")), (0, 2))
                    database.write_text(json.dumps(world))

                result, page = self.run_cli()
                self.assertEqual((result.returncode, page.get("activeCount")), (0, 1), result.stderr + result.stdout)
                remaining, = page["rows"]
                self.assertEqual(remaining["link"]["url"], outer["url"])
                if actor == "app-id":
                    result, receipt = self.act_cli("done", remaining, "application-done", text="Evidence")
                    self.assertEqual((result.returncode, receipt.get("state")), (0, "checking"))
                    result, page = self.run_cli()
                    checking, = page["rows"]
                    self.assertEqual((result.returncode, checking["state"]), (0, "checking"))

    def test_legacy_nested_reply_retries_at_its_saved_parent(self):
        (self.home / "kendex.settings.toml").write_text(
            '[env]\nORCH_OWNER_EMAIL="owner@example.test"\nORCH_OWNER_ASK_LABEL="owner-waiting"\n')
        mention = "https://linear.app/example/profiles/owner "
        outer = request_comment("outer", mention + "Outer question")
        inner = dict(request_comment("inner", mention + "Inner question"), parent_id=outer["id"])
        database = self.tracker_api([outer, inner])
        result, page = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        selected, = [row for row in page["rows"] if row["link"]["url"] == inner["url"]]
        path, = (self.root / "runtime").rglob("owner-asks.json")
        state = json.loads(path.read_text())
        request = {"requestId": "legacy", "expectedRevision": selected["revision"], "text": "Proceed"}
        comment = "7cdde53c-3df9-4d9a-9772-20c93fa3e98f"
        state["requests"]["legacy"] = {"key": comment, "body": request["text"], "receipt": None,
            "payload": {"id": selected["id"], "action": "reply", "request": request},
            "route": {"source": "linear", "issueUuid": "KEN-1-uuid", "thread": outer["id"]}}
        path.write_text(json.dumps(state))

        result, receipt = self.act_cli("reply", selected, "legacy", text=request["text"])
        self.assertEqual((result.returncode, receipt.get("kind")), (0, "accepted"))
        write, = [json.loads(line)["input"] for line in database.with_suffix(".writes").read_text().splitlines()]
        self.assertEqual((write["id"], write["parentId"]), (comment, outer["id"]))
        result, page = self.run_cli()
        self.assertEqual((result.returncode, page.get("activeCount")), (0, 2))

    def test_list_reads_this_homes_tracker_and_mailboxes_within_its_budget(self):
        # The main home's tracker as read on 2026-11-22: posted owner asks on
        # 171 issues in the 30 days before and 22 open owner-gated items, here
        # through four overseer mailboxes. Extend the posted workload to one
        # more than Linear's largest page (250, lib/pages.sh). A whole `linear.sh issues get` took
        # 0.42 s on that home, so this tracker answers the requests 14 s holds
        # at that cost and refuses the next one. The list runs with a deadline
        # no CPU load reaches: the request count, not this runner's clock,
        # decides the claim.
        comment_page_size, assigned, mailboxes = 250, 22, 4
        posted = comment_page_size + 1
        limit = int(owner_asks.CALL_SECONDS / 0.42)
        (self.home / "kendex.settings.toml").write_text(
            '[env]\nORCH_OWNER_EMAIL="owner@example.test"\nORCH_OWNER_ASK_LABEL="owner-waiting"\n')
        requests = {"OWN-%d" % n: [request_comment("waiting-%d" % n, "https://linear.app/example/profiles/owner Waiting %d" % n)]
                    for n in range(assigned)}
        issues = ["ASK-%d" % n for n in range(posted)]
        continuation_issue = issues[0]
        mirrors = {issue: [request_comment("mirror-" + issue, "Posted ask on " + issue)]
                   for issue in [*issues[1:], continuation_issue]}
        for issue in issues[:mailboxes]:
            mirrors[issue][:0] = [request_comment(f"unrelated-{issue}-{n}") for n in range(75)]
        log = self.tracker_api([], dict(requests, **mirrors), assigned=list(requests)).with_suffix(".log")
        comment_reads = log.with_suffix(".comment-ids")
        expected_ids = sorted("mirror-" + issue for issue in issues)
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
                # The continuation mirror belongs to the earliest visible ask.
                at = "2026-10-30T00:00:00Z" if issue == continuation_issue else "2026-10-31T00:00:00Z"
                ask = dict(envelope, id="%s-%d" % (stem, len(rows) // 2 + 1), at=at,
                           issue=issue, text="Asked on " + issue)
                rows += [ask, {"id": ask["id"] + "-tracker", "kind": "tracker-posted", "at": ask["at"], "from": ask["from"],
                               "re": ask["id"], "issue": issue, "tracker_label": "owner-waiting",
                               "tracker_comment": "mirror-" + issue, "text": ""}]
            path.write_text("".join(json.dumps(record) + "\n" for record in rows))
        self.register(self.registry, self.home, *roots)
        for view in ("active", "snoozed"):
            with self.subTest(view=view), patch.dict(os.environ, dict(self.env, JARVIS_BASH=BASH), clear=True):
                log.write_text("")
                comment_reads.write_text("")
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
                self.assertLessEqual(len(operations), limit)
                reads = [json.loads(line) for line in comment_reads.read_text().splitlines()]
                self.assertEqual([read['after'] for read in reads], [None, str(comment_page_size)] * 2)
                for read in reads:
                    self.assertEqual(sorted(read['ids']), expected_ids)
                self.assertEqual([operation for operation in operations if operation.startswith("IssueRefs")],
                                 ["IssueRefs OWN"] * (2 * -(-assigned // 50)))
                self.assertFalse({"ListComments", "GetIssueWithBundle"} & set(operations))
                self.assertEqual((page["activeCount"], page["snoozedCount"]), (posted + assigned, 0))
                self.assertEqual(bool(page["rows"]), view == "active")
                # Each ask links the mirror comment on its own issue.
                if view == "active":
                    self.assertEqual(page["rows"][0]["what"], "Asked on " + continuation_issue)
                self.assertEqual({row["what"]: row["link"]["url"] for row in page["rows"]},
                                 {row["what"]: request_comment("mirror-" + row["what"].split()[-1])["url"]
                                  for row in page["rows"]})

    # ssh -o BatchMode=yes -o ConnectTimeout=N DEST COMMAND, as forward.host_call spells it, run here.
    SSH = '#!' + BASH + '\nset -euo pipefail\nshift 4\nshift\nexec ' + BASH + ' -c "$1"\n'

    def satellite_list(self, main, seconds):
        """`owner-asks list` in this process on a satellite of MAIN whose CALL_SECONDS is SECONDS:
        its exit, its answer and its failure records."""
        satellite = self.root / "satellite"
        if not satellite.exists():
            make_project(satellite, overseer=False)
        (satellite / "kendex.settings.toml").write_text('[env]\nJARVIS_MAIN_HOST="main:' + str(main) + '"\n')
        args = argparse.Namespace(action="list", view="active", cursor=None, home=str(satellite))
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.dict(os.environ, dict(self.env, JARVIS_BASH=BASH), clear=True), patch.object(owner_asks, "CALL_SECONDS", seconds):
            with redirect_stdout(stdout), redirect_stderr(stderr):
                code = owner_asks.main(args, Session, Refusal)
        records = [json.loads(line.split("=", 1)[1]) for line in stderr.getvalue().splitlines()
                   if line.startswith("jarvis-session: owner-asks-failure=")]
        return code, json.loads(stdout.getvalue()), records

    def test_satellite_returns_the_main_answer_given_inside_its_budget(self):
        # The main's registry read never answers, so the main spends the
        # whole budget it holds and answers with that read's own cause. Real
        # time decides only which deadline comes first: the main's is three
        # seconds short of the satellite's.
        self.executable("kendex", "#!/bin/sh\nexec sleep 10\n")
        self.executable("ssh", self.SSH)
        with patch.object(owner_asks, "TRANSPORT_SECONDS", 3):
            code, answer, records = self.satellite_list(self.home, 5)
        self.assertEqual((code, answer["kind"]), (1, "unavailable"))
        self.assertEqual([(record["key"][:2], record["destination"]) for record in records],
                         [(["project-list", "timeout"], "local")])

    def test_satellite_names_a_slow_main_apart_from_an_unreachable_one(self):
        # A main past every deadline of its own, and a host whose connect never completes.
        slow = self.root / "slow-main"
        script = slow / ".agents/skills/jarvis/scripts/jarvis-session"
        script.parent.mkdir(parents=True)
        script.write_text("exec sleep 10\n")
        rows = [("reached", self.SSH, "main-slow"),
                ("unreached", "#!/bin/sh\nexec sleep 10\n", "main-unreachable")]
        for name, ssh, cause in rows:
            with self.subTest(main=name):
                self.executable("ssh", ssh)
                code, answer, records = self.satellite_list(slow, 3)
                self.assertEqual((code, answer["kind"]), (1, "unavailable"))
                self.assertEqual([record["key"] for record in records], [["main-home", "transport", cause]])

    def test_satellite_uses_the_same_main_receipt_without_local_state(self):
        satellite = make_project(self.root / "satellite", overseer=False)
        (satellite / "kendex.settings.toml").write_text('[env]\nJARVIS_MAIN_HOST="main:' + str(self.home) + '"\n')
        self.executable("ssh", self.SSH)
        result, main = self.run_cli()
        result, remote = self.run_cli(home=satellite)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual((remote["homeId"], remote["revision"]), (main["homeId"], main["revision"]))
        self.assertEqual(len(list((self.root / "runtime").rglob("owner-asks.json"))), 1)


if __name__ == "__main__":
    unittest.main()
