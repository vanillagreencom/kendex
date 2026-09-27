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
from settings import Settings
from store import (
    Binding,
    Journal,
    RelayLock,
    State,
    compact,
    journal_exists,
    read_binding,
    read_journal,
    read_status,
    write_binding,
    write_status,
)

ROUTED_SUBTYPES = {None, "file_share"}
OTHER_THREADS_EVERY = 10
AT_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
NOT_OWNER = "Only the channel's owners steer this session; this message is not routed."
NO_TEXT = "Only text is routed; a file alone is not."
RECORDED = "Recorded as your answer."
ALREADY = "This question was already answered; delivered as a directive instead."


def at_epoch(at: str) -> float:
    """An envelope's `at`, the UTC second lane-mail stamps, as epoch seconds."""
    try:
        stamp = datetime.datetime.strptime(at, AT_FORMAT)
    except ValueError as err:
        raise Refusal("lane-mail-failed", f"envelope at={at}") from err
    return stamp.replace(tzinfo=datetime.timezone.utc).timestamp()


def resolve_owner_ids(api: Slack, owners: List[str]) -> Dict[str, str]:
    ids = {}
    for email in owners:
        try:
            answer = api.get("users.lookupByEmail", email=email)
        except Refusal as err:
            if err.key == "slack-api-failed" and err.value.endswith("error=users_not_found"):
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
        newest = ""
        for envelope in self.mail.events():
            if newest == "" or at_epoch(str(envelope["at"])) > at_epoch(newest):
                newest = str(envelope["at"])
        self.journal.append(t="start", at=newest)
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
        horizon = self.clock() - self.settings.thread_days * 86400
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
        horizon = self.clock() - self.settings.thread_days * 86400
        start = at_epoch(self.state.start_at) if self.state.start_at else None
        for envelope in events:
            env_id = str(envelope["id"])
            if env_id in self.state.carried or env_id in self.skipped:
                continue
            at = at_epoch(str(envelope["at"]))
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
            elif start is not None and at <= start:
                self.skipped.add(env_id)
            elif box == "to-overseer" and envelope.get("to") == "owner" and kind == "notice":
                self.post_notice(envelope)
            elif box == "to-lane" and kind == "answer":
                self.post_answer(envelope)
            else:
                self.skipped.add(env_id)

    def post_refused(self, err: Refusal, env_id: str, kind: str) -> None:
        """Slack's refusal of one post, by key: a lost response is journaled
        unknown and never repeated; a dead token stops the relay; anything
        else fails this poll and leaves the envelope for the next."""
        if err.key == "slack-response-lost":
            self.journal.append(t="out", channel=self.channel, id=env_id, kind=kind, state="unknown")
            print_refusal(err)
            return
        if err.key == "slack-auth-failed":
            raise err
        if self.post_failed is None:
            self.post_failed = Refusal(err.key, f"{err.value} id={env_id}")

    def _post(self, envelope: Dict, kind: str, text: str, thread_ts: Optional[str]) -> Optional[str]:
        """One chat.postMessage, or None when it did not land."""
        env_id = str(envelope["id"])
        try:
            secret_check(text.encode(), f"id={env_id}")
        except Refusal as err:
            self.journal.append(t="out", channel=self.channel, id=env_id, kind=kind, state="refused", reason=err.key)
            print_refusal(err)
            return None
        try:
            answer = self.api.post("chat.postMessage", channel=self.channel, text=text, thread_ts=thread_ts)
        except Refusal as err:
            self.post_refused(err, env_id, kind)
            return None
        return str(answer["ts"])

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
        ts = self._post(envelope, "ask", "\n".join(lines), None)
        if ts is not None:
            self.journal.append(t="out", channel=self.channel, id=str(envelope["id"]), kind="ask", state="open", thread=ts)

    def post_notice(self, envelope: Dict) -> None:
        env_id = str(envelope["id"])
        ref = envelope.get("ref")
        thread_ts = self.state.by_envelope.get(str(ref)) if ref else None
        text = envelope.get("text", "")
        attach = envelope.get("attach")
        if not attach:
            ts = self._post(envelope, "notice", text, thread_ts)
            if ts is not None:
                self.journal.append(
                    t="out", channel=self.channel, id=env_id, kind="notice", state="resolved", thread=thread_ts or ts
                )
            return
        try:
            data = Path(attach).read_bytes()
            secret_check(text.encode(), f"id={env_id}")
            secret_check(data, f"id={env_id} file={attach}")
        except OSError:
            self.journal.append(t="out", channel=self.channel, id=env_id, kind="notice", state="refused", reason="file-unreadable")
            print_refusal(Refusal("file-unreadable", str(attach)))
            return
        except Refusal as err:
            self.journal.append(t="out", channel=self.channel, id=env_id, kind="notice", state="refused", reason=err.key)
            print_refusal(err)
            return
        try:
            file_id = self.api.upload(Path(attach).name, data, self.channel, text, thread_ts)
        except Refusal as err:
            self.post_refused(err, env_id, "notice")
            return
        self.journal.append(t="out", channel=self.channel, id=env_id, kind="notice", state="file", file=file_id)

    def post_answer(self, envelope: Dict) -> None:
        env_id = str(envelope["id"])
        ask_id = str(envelope.get("re", ""))
        thread_ts = self.state.by_envelope.get(ask_id)
        if thread_ts is None:
            self.skipped.add(env_id)
            return
        if envelope.get("by") == "default":
            text = f"No answer by the deadline: {envelope.get('text', '')} stands."
        else:
            text = f"Answered in the chat: {envelope.get('text', '')}"
        ts = self._post(envelope, "answer", text, thread_ts)
        if ts is not None:
            self.journal.append(t="out", channel=self.channel, id=env_id, kind="answer", state="resolved", thread=thread_ts)
            self.journal.append(t="resolved", id=ask_id)

    # -- the record --status reads --------------------------------------------

    def budget_per_minute(self) -> float:
        per_poll = 1 + sum(1 for t in self.state.threads.values() if t.open)
        horizon = self.clock() - self.settings.thread_days * 86400
        others = sum(1 for t in self.state.threads.values() if not t.open and float(t.ts) >= horizon)
        polls_per_minute = 60.0 / self.settings.poll_seconds
        return per_poll * polls_per_minute + others * polls_per_minute / OTHER_THREADS_EVERY

    def compact_daily(self, today: str, cutoff: float) -> None:
        """Once a day, on the first poll of a new UTC day; the first start
        only records the day, so `slack compact` is what compacts sooner."""
        if self.compacted_day == today:
            return
        if self.compacted_day:
            compact(self.path, cutoff)
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
        for root in self.roots:
            root.lock.acquire()
        self.bot_user = str(api.get("auth.test")["user_id"])

    def poll_once(self) -> bool:
        """One poll of every root; False when any root's poll was refused."""
        clean = True
        today = datetime.datetime.fromtimestamp(self.clock(), datetime.timezone.utc).date().isoformat()
        cutoff = self.clock() - self.settings.thread_days * 86400
        for root in self.roots:
            try:
                root.compact_daily(today, cutoff)
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
