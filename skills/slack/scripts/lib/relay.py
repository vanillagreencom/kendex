"""The listener: one process, every bound root of one person, polling.

Each poll, per root: re-resolve the owners when the setting moved, read the
channel's history since the journal's position, follow every parent whose
replies moved, read every open ask's thread, every tenth poll read the other
bound threads younger than SLACK_THREAD_DAYS, then read the mailbox's events
and post every owner-bound envelope not yet carried.

A start with no journal seeds both positions before it reads anything: Slack
from the binding moment, so a channel's earlier history is never delivered,
and the mailbox from its newest envelope, so notices and answers already
there are never re-posted. Open asks are posted whatever their age inside
SLACK_THREAD_DAYS, since they still want an answer.
"""

from __future__ import annotations

import datetime
import os
import time
from pathlib import Path
from typing import Callable, Dict, List, Optional

from api import Slack
from mailbox import LaneMail
from refusals import Refusal, keyed, print_refusal
from secret import check as secret_check
from secret import checked_file
from settings import Settings
from store import (
    Binding,
    Journal,
    RelayLock,
    State,
    compact,
    journal_exists,
    parse_at,
    read_binding,
    read_journal,
    read_status,
    write_binding,
    write_status,
)

ROUTED_SUBTYPES = {None, "file_share"}
OTHER_THREADS_EVERY = 10
NOT_OWNER = "Only the channel's owners steer this session; this message is not routed."
NO_TEXT = "Only text is routed; a file alone is not."
RECORDED = "Recorded as your answer."
ALREADY = "This question was already answered; delivered as a directive instead."


def at_epoch(at: str) -> float:
    """An envelope's `at` as epoch seconds; lane-mail wrote it."""
    try:
        return parse_at(at)
    except ValueError as err:
        raise Refusal("lane-mail-failed", f"envelope at={at}") from err


def resolve_owner_ids(api: Slack, owners: List[str]) -> Dict[str, str]:
    ids = {}
    for email in owners:
        try:
            answer = api.get("users.lookupByEmail", email=email)
        except Refusal as err:
            if err.key == "slack-api-failed" and err.error == "users_not_found":
                raise Refusal("slack-owner-unknown", f"{email} fix=set SLACK_OWNERS to addresses this workspace knows") from err
            raise
        ids[email] = str(answer["user"]["id"])
    return ids


def mention(binding: Binding) -> str:
    return " ".join(f"<@{binding.owner_ids[o]}>" for o in binding.owners if o in binding.owner_ids)


class RootRelay:
    def __init__(self, path: Path, settings: Settings, api: Slack, clock: Callable[[], float]) -> None:
        self.path = path
        self.settings = settings
        self.api = api
        self.clock = clock
        self.mail = LaneMail(path)
        self.binding = read_binding(path)
        self.fresh = not journal_exists(path)
        self.state: State = read_journal(path)
        self.journal = Journal(path, self.state)
        self.lock = RelayLock(path)
        self.skipped: set = set()
        self.last_ok: Optional[float] = None
        self.post_failed: Optional[Refusal] = None
        # The status record carries the poll count and the compaction day
        # across restarts; the journal holds deliveries and positions alone.
        record = read_status(path) or {}
        self.polls = int(record.get("polls", 0))
        self.compacted_day: str = str(record.get("compacted_day", ""))

    @property
    def channel(self) -> str:
        return self.binding.channel

    def owners_current(self) -> None:
        """The setting is the authority: a binding resolved from another
        owners list is re-resolved before anything more is delivered."""
        if self.binding.owners != self.settings.owners:
            ids = resolve_owner_ids(self.api, self.settings.owners)
            self.binding = Binding(
                self.channel, self.binding.channel_name, self.binding.bound_at, list(self.settings.owners), ids
            )
            write_binding(self.path, self.binding)

    def seed(self) -> None:
        """The positions a start with no journal begins from, journaled so a
        restart keeps them: Slack's history past the binding moment, and the
        mailbox past its newest envelope."""
        self.journal.append(t="seen", ts=self.binding.bound_at)
        # `at` is a whole second, so the envelopes stamped in the newest
        # second are named by id: one written later in that second is new.
        newest = ""
        ids: List[str] = []
        for envelope in self.mail.events():
            at = str(envelope["at"])
            if newest == "" or at_epoch(at) > at_epoch(newest):
                newest, ids = at, [str(envelope["id"])]
            elif at == newest:
                ids.append(str(envelope["id"]))
        self.journal.append(t="start", at=newest, ids=ids)
        self.fresh = False

    # -- inbound: Slack to the mailbox --------------------------------------

    def poll(self, bot_user: str) -> None:
        self.owners_current()
        self.polls += 1
        self.post_failed = None
        if self.fresh:
            self.seed()
        self.read_history(bot_user)
        self.read_threads(bot_user)
        self.post_events()
        if self.post_failed is not None:
            raise self.post_failed
        self.last_ok = self.clock()

    def read_history(self, bot_user: str) -> None:
        messages = list(
            self.api.paged("conversations.history", "messages", channel=self.channel, oldest=self.state.seen_ts)
        )
        messages.sort(key=lambda m: float(m["ts"]))
        for message in messages:
            self.bind_file_share(message)
            self.handle(message, bot_user)
            thread = self.state.threads.get(message["ts"])
            latest = message.get("latest_reply")
            if thread is not None and latest and float(latest) > float(thread.seen):
                self.read_replies(thread, bot_user)
        if messages:
            self.journal.append(t="seen", ts=messages[-1]["ts"])

    def bind_file_share(self, message: Dict) -> None:
        for item in message.get("files") or []:
            file_id = str(item.get("id", ""))
            if file_id in self.state.pending_files:
                self.journal.append(t="bound", file=file_id, id=self.state.pending_files[file_id], ts=message["ts"])

    def read_threads(self, bot_user: str) -> None:
        horizon = self.settings.horizon(self.clock())
        tenth = self.polls % OTHER_THREADS_EVERY == 0
        for thread in list(self.state.threads.values()):
            if thread.open or (tenth and float(thread.ts) >= horizon):
                self.read_replies(thread, bot_user)

    def read_replies(self, thread, bot_user: str) -> None:
        replies = list(
            self.api.paged("conversations.replies", "messages", channel=self.channel, ts=thread.ts, oldest=thread.seen)
        )
        replies = [r for r in replies if r["ts"] != thread.ts and float(r["ts"]) > float(thread.seen)]
        replies.sort(key=lambda m: float(m["ts"]))
        for reply in replies:
            self.handle(reply, bot_user)
        if replies:
            self.journal.append(t="thread", ts=thread.ts, seen=replies[-1]["ts"])

    def handle(self, message: Dict, bot_user: str) -> None:
        ts = str(message["ts"])
        # The journal skips a stamp it already carried; lane-mail's locked
        # check judges any stamp the journal lost, the crash between the
        # append and the mark, and answers it with the envelope that landed.
        if ts in self.state.delivered or ts in self.state.ignored:
            return
        if message.get("bot_id") or message.get("user") == bot_user:
            return
        if message.get("subtype") not in ROUTED_SUBTYPES:
            return
        thread_ts = str(message.get("thread_ts") or ts)
        user = str(message.get("user", ""))
        if user not in self.binding.owner_ids.values():
            self.api.post("chat.postMessage", channel=self.channel, thread_ts=thread_ts, text=NOT_OWNER)
            self.journal.append(t="in", channel=self.channel, ts=ts, kind="ignored", reason="not-owner")
            return
        text = (message.get("text") or "").strip()
        if not text:
            self.api.post("chat.postMessage", channel=self.channel, thread_ts=thread_ts, text=NO_TEXT)
            self.journal.append(t="in", channel=self.channel, ts=ts, kind="ignored", reason="no-text")
            return
        delivery = f"{self.channel}:{ts}"
        thread = self.state.threads.get(thread_ts) if thread_ts != ts else None
        # The mailbox judges whether an ask is still open; the journal's own
        # flag only decides how often the thread is read.
        if thread is not None and thread.kind == "ask":
            outcome, answer_id = self.mail.resolve(thread.envelope, text, delivery)
            if outcome == "resolved":
                self.journal.append(t="in", channel=self.channel, ts=ts, kind="answer", id=answer_id, thread=thread_ts)
                self.journal.append(t="resolved", id=thread.envelope)
                self.api.post("chat.postMessage", channel=self.channel, thread_ts=thread_ts, text=RECORDED)
                return
            self.api.post("chat.postMessage", channel=self.channel, thread_ts=thread_ts, text=ALREADY)
        envelope = self.mail.send_directive(text, delivery)
        self.journal.append(t="in", channel=self.channel, ts=ts, kind="directive", id=envelope, thread=thread_ts)

    # -- outbound: the mailbox to Slack --------------------------------------

    def post_events(self) -> None:
        events = self.mail.events()
        answered = {e.get("re") for e in events if e.get("kind") == "answer"}
        horizon = self.settings.horizon(self.clock())
        start = at_epoch(self.state.start_at) if self.state.start_at else None
        for envelope in events:
            env_id = str(envelope["id"])
            if env_id in self.state.carried or env_id in self.skipped:
                continue
            at = at_epoch(str(envelope["at"]))
            # `store.compact` drops an `out` line by this same age, so an
            # envelope whose line it may drop must never post again.
            if at < horizon:
                self.skipped.add(env_id)
                continue
            box = envelope.get("box")
            kind = envelope.get("kind")
            if box == "to-overseer" and envelope.get("to") == "owner" and kind == "ask":
                if env_id in answered:
                    self.skipped.add(env_id)
                else:
                    self.post_ask(envelope)
            elif start is not None and (at < start or at == start and env_id in self.state.start_ids):
                self.skipped.add(env_id)
            elif box == "to-overseer" and envelope.get("to") == "owner" and kind == "notice":
                self.post_notice(envelope)
            elif box == "to-lane" and kind == "answer":
                self.post_answer(envelope)
            else:
                self.skipped.add(env_id)

    def _out(self, envelope: Dict, kind: str, state: str, **fields: object) -> None:
        """One `out` line. Each carries the envelope's `at`, the age
        `store.compact` judges the line by."""
        self.journal.append(
            t="out", channel=self.channel, id=str(envelope["id"]), kind=kind, state=state, at=str(envelope["at"]), **fields
        )

    def post_refused(self, err: Refusal, envelope: Dict, kind: str) -> None:
        """Slack's refusal of one post, by key: a lost response is journaled
        unknown and never repeated; a dead token stops the relay; anything
        else fails this poll and leaves the envelope for the next."""
        if err.key == "slack-response-lost":
            self._out(envelope, kind, "unknown")
            print_refusal(err)
            return
        if err.key == "slack-auth-failed":
            raise err
        if self.post_failed is None:
            self.post_failed = Refusal(err.key, f"{err.value} id={envelope['id']}")

    def _send(self, envelope: Dict, kind: str, text: str, thread_ts: Optional[str], attach: str = "") -> Optional[str]:
        """The one outbound rule: the text and any attached file pass the
        secret-value check, a refusal there journaled refused and printed;
        then the file is uploaded with the text as its comment, or the text
        posted, Slack's refusal to `post_refused`. Returns the message ts or
        the upload's file id; None when nothing landed."""
        env_id = str(envelope["id"])
        try:
            secret_check(text.encode(), f"id={env_id}")
            data = checked_file(attach, f"id={env_id} file={attach}") if attach else None
        except Refusal as err:
            self._out(envelope, kind, "refused", reason=err.key)
            print_refusal(err)
            return None
        try:
            if data is not None:
                return self.api.upload(Path(attach).name, data, self.channel, text, thread_ts)
            return str(self.api.post("chat.postMessage", channel=self.channel, text=text, thread_ts=thread_ts)["ts"])
        except Refusal as err:
            self.post_refused(err, envelope, kind)
            return None

    def post_ask(self, envelope: Dict) -> None:
        options = ", ".join(envelope.get("options") or [])
        lines = [f"{mention(self.binding)} Question from {envelope.get('from', 'overseer')}:", envelope.get("text", "")]
        tail = []
        if options:
            tail.append(f"Options: {options}.")
        if envelope.get("recommend"):
            tail.append(f"Recommended: {envelope['recommend']}.")
        if envelope.get("deadline"):
            tail.append(f"It stands at {envelope['deadline']} unless you reply in this thread.")
        if tail:
            lines.append(" ".join(tail))
        ts = self._send(envelope, "ask", "\n".join(lines), None)
        if ts is not None:
            self._out(envelope, "ask", "open", thread=ts)

    def post_notice(self, envelope: Dict) -> None:
        ref = envelope.get("ref")
        thread_ts = self.state.by_envelope.get(str(ref)) if ref else None
        attach = str(envelope.get("attach") or "")
        landed = self._send(envelope, "notice", envelope.get("text", ""), thread_ts, attach)
        if landed is None:
            return
        if attach:
            self._out(envelope, "notice", "file", file=landed)
        else:
            self._out(envelope, "notice", "resolved", thread=thread_ts or landed)

    def post_answer(self, envelope: Dict) -> None:
        ask_id = str(envelope.get("re", ""))
        thread_ts = self.state.by_envelope.get(ask_id)
        if thread_ts is None:
            self.skipped.add(str(envelope["id"]))
            return
        if envelope.get("by") == "default":
            text = f"No answer by the deadline: {envelope.get('text', '')} stands."
        else:
            text = f"Answered in the chat: {envelope.get('text', '')}"
        if self._send(envelope, "answer", text, thread_ts) is not None:
            self._out(envelope, "answer", "resolved", thread=thread_ts)
            self.journal.append(t="resolved", id=ask_id)

    # -- the record --status reads --------------------------------------------

    def budget_per_minute(self) -> float:
        per_poll = 1 + sum(1 for t in self.state.threads.values() if t.open)
        horizon = self.settings.horizon(self.clock())
        others = sum(1 for t in self.state.threads.values() if not t.open and float(t.ts) >= horizon)
        polls_per_minute = 60.0 / self.settings.poll_seconds
        return per_poll * polls_per_minute + others * polls_per_minute / OTHER_THREADS_EVERY

    def compact_daily(self, today: str) -> None:
        """Once a day, on the first poll of a new UTC day; the first start
        only records the day, so `slack compact` is what compacts sooner."""
        if self.compacted_day == today:
            return
        if self.compacted_day:
            compact(self.path, self.settings.horizon(self.clock()))
            self.state = read_journal(self.path)
            self.journal = Journal(self.path, self.state)
        self.compacted_day = today

    def record_status(self, ok: bool, error: str = "") -> None:
        delivered = max(self.state.delivered, key=float, default="")
        write_status(
            self.path,
            {
                "pid": os.getpid(),
                "compacted_day": self.compacted_day,
                "channel": self.channel,
                "poll_seconds": self.settings.poll_seconds,
                "polls": self.polls,
                "last_poll": self.clock(),
                "last_poll_ok": ok,
                "last_error": error,
                "last_delivered_ts": delivered,
                "seen_ts": self.state.seen_ts,
                "unknown": sorted(self.state.unknown),
                "refused": sorted(self.state.refused),
                "open_asks": sorted(t.envelope for t in self.state.threads.values() if t.open),
                "calls_last_minute": self.api.calls_last_minute(),
                "budget_per_minute": round(self.budget_per_minute(), 1),
            },
        )


class Relay:
    def __init__(
        self,
        roots: List[Path],
        settings: Settings,
        api: Slack,
        clock: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self.settings = settings
        self.api = api
        self.clock = clock
        self.sleep = sleep
        self.roots = [RootRelay(root, settings, api, clock) for root in roots]
        # Two roots on one channel would each deliver every owner message
        # into their own mailbox and both post there.
        first: Dict[str, Path] = {}
        for root in self.roots:
            other = first.setdefault(root.channel, root.path)
            if other != root.path:
                raise Refusal(
                    "channel-shared", f"{root.channel} roots={other},{root.path} fix=run `slack setup --name NAME` in one of them"
                )
        for root in self.roots:
            root.lock.acquire()
        self.bot_user = str(api.get("auth.test")["user_id"])

    def poll_once(self) -> bool:
        """One poll of every root; False when any root's poll was refused."""
        clean = True
        today = datetime.datetime.fromtimestamp(self.clock(), datetime.timezone.utc).date().isoformat()
        for root in self.roots:
            try:
                root.compact_daily(today)
                root.poll(self.bot_user)
                root.record_status(True)
            except Refusal as err:
                if err.key == "slack-auth-failed":
                    raise
                print_refusal(err)
                root.record_status(False, f"{err.key}={err.value}")
                clean = False
        return clean

    def run(self, once: bool) -> int:
        print(keyed("listening", f"{len(self.roots)} poll_seconds={self.settings.poll_seconds}"), flush=True)
        while True:
            clean = self.poll_once()
            if once:
                return 0 if clean else 1
            self.sleep(self.settings.poll_seconds)
