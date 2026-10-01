"""The listener: one process, every bound root on one machine, over one
Socket Mode connection.

Slack sends each Events API envelope to one of an app's open connections,
with no pattern to which, so one relay holds its app's one connection for
every root on its machine and routes each message event by its channel. The
relay opens the connection with SLACK_APP_TOKEN, acknowledges each envelope
by its envelope_id as soon as its loop reads it, before the delivery, then
routes a message event to the root bound to its channel: a top-level
message, or a reply under a bound thread that `live` accepts. The loop is
one thread, so an envelope that waits behind a download, a catch-up, the
mailbox posts or a 429 wait past Slack's three seconds is sent again, and
the journal skips the repeat by its stamp.

An event moves no position. It writes no `seen` or `thread` line; the
catch-up writes both, and a start with no seeds writes the `seen` line of
the binding moment. The catch-up runs on the first poll after every connect
and reconnect, and on the next poll after an event whose delivery was
refused. It reads the
channel's history from the journal's position or SLACK_THREAD_DAYS back,
whichever is older, delivers the top-level messages past the position, and
reads the thread of every open ask and of every live parent whose latest
reply moved. So a message sent while the relay was disconnected, one whose
envelope never arrived, and one acknowledged before a stop cut its delivery
off all land on a catch-up, and lane-mail's delivery id judges any repeat.
The connection opens before the catch-up reads, so no message falls between
them.

Each poll, every SLACK_POLL_SECONDS, per root: re-resolve the owners when
the setting moved, run the catch-up when one is due, mark every delivered
directive the journal holds no mark for, swap the receipt mark of every
directive the overseer has read since, then read the mailbox's events and
post every owner-bound envelope not yet carried.

A directive's Slack message carries a receipt mark, a reaction and never a
message: SEEN once it lands in the mailbox, READ once the overseer's
to-lane.cursor passes it. Each mark is judged from the journal on every
poll, never from the step that delivered the directive, so a stop between
the delivery and its mark leaves the mark to the next poll.

A start whose journal holds no `start` line seeds both positions before it
reads anything: Slack from the binding moment, so a channel's earlier history is never delivered,
and the mailbox from its newest envelope, so notices and answers already
there are never re-posted. Open asks are posted whatever their age inside
SLACK_THREAD_DAYS, since they still want an answer.

While SLACK_MASTER_FILE is younger than SLACK_MASTER_MAX_AGE a master session
answers the overseer, and the relay posts no envelope from the mailbox;
reading the channel and replying there go on. When the file goes stale or
absent the relay resumes. The master's watch writes its last mailbox read
count as one bare integer in tmp/lane-mail/overseer/to-overseer.seen. A resume
skips notices on lines at or below that count and journals their ids; later
notices post. A missing or unreadable seen file skips nothing. The count is
clamped to the lines listed. Open asks post whatever their line, and a held
answer still posts so the thread of an ask the channel shows open is closed.
"""

from __future__ import annotations

import datetime
import json
import os
import time
from pathlib import Path
from typing import Callable, Dict, List, Optional, Set, Tuple

from api import MARKDOWN_LIMIT, Slack
from mailbox import LaneMail
from markup import plain
from refusals import Refusal, keyed, notice, print_refusal
from secret import check as secret_check
from secret import checked_file
from settings import MASTER, Settings
from store import (
    READ,
    SEEN,
    Binding,
    Journal,
    RelayLock,
    State,
    Thread,

    compact,
    format_at,
    parse_at,
    read_binding,
    read_journal,
    read_status,
    save_file,
    write_binding,
    write_status,
)
from websocket import Closed, WebSocket

ROUTED_SUBTYPES = {None, "file_share"}
# Seconds the relay waits for Slack's `hello` on a new connection.
HELLO_SECONDS = 10
# Seconds of silence on the connection before it pings, and as many again
# before it reads itself as dropped: `WebSocket.recv` judges both.
IDLE_SECONDS = 30
# The wait before a failed connect is tried again, doubled per failure up to
# the second figure; a drop is answered with a connect at once.
RETRY_FIRST_SECONDS = 1
RETRY_MAX_SECONDS = 60
# Seconds a relay may stay reconnecting before `listen --status` reads it as
# failing: two of the longest waits between connects.
RECONNECT_BOUND_SECONDS = 2 * RETRY_MAX_SECONDS
NOT_OWNER = "Only the channel's owners steer this session; this message is not routed."
NO_TEXT = "Only text and files are routed; this message has neither."
RECORDED = "Recorded as your answer."
ALREADY = "This question was already answered; delivered as a directive instead."
# Slack's answer when the reaction is already as the call would leave it, or
# its message is gone: nothing is left to mark.
MARK_SETTLED = {"already_reacted", "no_reaction", "message_not_found"}


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


def newest(events: List[Dict]) -> Tuple[str, List[str]]:
    """The mailbox's newest `at` and the ids stamped in that second: `at` is a
    whole second, so one written later in that second is named apart."""
    at_newest = ""
    ids: List[str] = []
    for envelope in events:
        at = str(envelope["at"])
        if at_newest == "" or at_epoch(at) > at_epoch(at_newest):
            at_newest, ids = at, [str(envelope["id"])]
        elif at == at_newest:
            ids.append(str(envelope["id"]))
    return at_newest, ids


def before(floor_at: str, floor_ids: Set[str], at: float, env_id: str) -> bool:
    """Whether an envelope stamped `at` is at or before the `start` floor."""
    if not floor_at:
        return False
    floor = at_epoch(floor_at)
    return at < floor or at == floor and env_id in floor_ids



def local_time(at: str) -> str:
    """An `at`-shaped stamp as Slack's date token, which each reader's Slack
    shows in that reader's own time zone and clock format; the stamp is the
    fallback a client that cannot render the token shows."""
    return f"<!date^{int(at_epoch(at))}^{{date_short_pretty}} at {{time}}|{at}>"


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
        self.state: State = read_journal(path)
        self.journal = Journal(path, self.state)
        self.lock = RelayLock(path)
        self.skipped: set = set()
        self.last_ok: Optional[float] = None
        self.post_failed: Optional[Refusal] = None
        self.names: Dict[str, str] = {}
        # False until a catch-up has read the channel since the last connect
        # or the last refused event delivery.
        self.caught_up = False
        # The status record carries the compaction day across restarts; the
        # journal holds deliveries and positions alone.
        record = read_status(path) or {}
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
        """The positions a start with no seeds begins from, journaled so a
        restart keeps them: Slack's history past the binding moment, and the
        mailbox past its newest envelope. `start` goes last, so a stop
        between the two lines seeds again."""
        self.journal.append(t="seen", ts=self.binding.bound_at)
        at, ids = newest(self.mail.events())
        self.journal.append(t="start", at=at, ids=ids)

    # -- inbound: Slack to the mailbox --------------------------------------

    def ready(self) -> None:
        """What every delivery needs first: the owners as the setting names
        them, and the seeds of a start whose journal holds none: a journal
        of connection lines alone, which a connect writes before the first
        poll, is not seeded."""
        self.owners_current()
        if not self.state.seeded:
            self.seed()

    def poll(self, bot_user: str) -> None:
        self.ready()
        self.post_failed = None
        if not self.caught_up:
            self.catch_up(bot_user)
        self.mark_seen()
        self.mark_read()
        now = self.clock()
        touched = self.master_touched()
        if touched is not None and now - touched < self.settings.master_max_age:
            if not self.state.held:
                self.journal.append(t="hold", at=format_at(touched))
        else:
            events = self.mail.events()
            if self.state.held:
                self.resume(events)
            else:
                self.post_events(self.routes(events))
        if self.post_failed is not None:
            raise self.post_failed
        self.last_ok = self.clock()

    def live(self, thread: Thread) -> bool:
        """Whether a reply under `thread` is routed: under an open ask
        always, under any other while its parent is younger than
        SLACK_THREAD_DAYS."""
        return thread.open or float(thread.ts) >= self.settings.horizon(self.clock())

    def catch_up(self, bot_user: str) -> None:
        """The history read the module docstring states. The read reaches
        SLACK_THREAD_DAYS back even when the position is younger, since a
        parent's `latest_reply` is how a reply sent while disconnected is
        found; only a message past the position is delivered."""
        horizon = self.settings.horizon(self.clock())
        position = self.state.seen_ts
        oldest = position if float(position) <= horizon else f"{horizon:.6f}"
        messages = list(self.api.paged("conversations.history", "messages", channel=self.channel, oldest=oldest))
        messages.sort(key=lambda m: float(m["ts"]))
        new = [m for m in messages if float(m["ts"]) > float(position)]
        for message in new:
            self.bind_file_share(message)
            self.handle(message, bot_user)
        replied = {str(m["ts"]): float(m["latest_reply"]) for m in messages if m.get("latest_reply")}
        for thread in list(self.state.threads.values()):
            if thread.open or self.live(thread) and replied.get(thread.ts, 0.0) > float(thread.seen):
                self.read_replies(thread, bot_user)
        if new:
            self.journal.append(t="seen", ts=new[-1]["ts"])
        self.caught_up = True

    def on_message(self, message: Dict, bot_user: str) -> None:
        """One message event off the connection, routed as the catch-up
        routes it: a reply only under a bound thread `live` accepts."""
        self.ready()
        ts = str(message["ts"])
        thread_ts = str(message.get("thread_ts") or ts)
        if thread_ts != ts:
            thread = self.state.threads.get(thread_ts)
            if thread is None or not self.live(thread):
                return
        else:
            self.bind_file_share(message)
        self.handle(message, bot_user)
        self.mark_seen()

    def bind_file_share(self, message: Dict) -> None:
        for item in message.get("files") or []:
            file_id = str(item.get("id", ""))
            if file_id in self.state.pending_files:
                self.journal.append(t="bound", file=file_id, id=self.state.pending_files[file_id], ts=message["ts"])

    def read_replies(self, thread: Thread, bot_user: str) -> None:
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
        text = plain((message.get("text") or "").strip(), self.user_name)
        lines = ([text] if text else []) + self.fetch_files(message)
        if not lines:
            self.api.post("chat.postMessage", channel=self.channel, thread_ts=thread_ts, text=NO_TEXT)
            self.journal.append(t="in", channel=self.channel, ts=ts, kind="ignored", reason="no-text")
            return
        text = "\n".join(lines)
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

    def react(self, method: str, ts: str, name: str) -> bool:
        """One reaction on the message at `ts`; False when Slack refused it,
        the refusal printed and the mark left to the next poll. A mark is a
        courtesy: its failure fails no poll and holds no delivery back, and a
        dead token still stops the relay."""
        try:
            self.api.post(method, channel=self.channel, timestamp=ts, name=name)
        except Refusal as err:
            if err.key == "slack-auth-failed":
                raise
            if err.error not in MARK_SETTLED:
                print_refusal(err)
                return False
        return True

    def mark_seen(self) -> None:
        """Mark SEEN every delivered directive no mark line names: one this
        poll delivered, one whose mark Slack refused, and one a stop left
        unmarked. A stop after Slack took the reaction and before its line
        is answered already_reacted, which settles it."""
        for ts in sorted(self.state.directives.difference(self.state.marks), key=float):
            if self.react("reactions.add", ts, SEEN):
                self.journal.append(t="mark", ts=ts, name=SEEN)

    def mark_read(self) -> None:
        """Swap SEEN for READ on every directive the overseer has read. A
        swap Slack refused, or a receipts read lane-mail refused, is made
        again on the next poll."""
        seen = [ts for ts, name in self.state.marks.items() if name == SEEN]
        if not seen:
            return
        try:
            read = self.mail.read_directives()
        except Refusal as err:
            print_refusal(err)
            return
        for ts in seen:
            if self.state.delivered.get(ts) not in read:
                continue
            if self.react("reactions.remove", ts, SEEN) and self.react("reactions.add", ts, READ):
                self.journal.append(t="mark", ts=ts, name=READ)

    def user_name(self, user_id: str) -> str:
        """The name Slack shows for a user a message mentions, asked once
        per relay; the id itself when Slack refuses to say."""
        if user_id not in self.names:
            try:
                user = self.api.get("users.info", user=user_id)["user"]
            except Refusal as err:
                if err.key == "slack-auth-failed":
                    raise
                print_refusal(err)
                return user_id
            profile = user.get("profile") or {}
            self.names[user_id] = str(profile.get("display_name") or profile.get("real_name") or user.get("name") or user_id)
        return self.names[user_id]

    def fetch_files(self, message: Dict) -> List[str]:
        """One line per file of an owner's message: the path it was saved
        to, or `file <id> not fetched: <why>`, so the message lands whether
        or not its files do."""
        lines = []
        for item in message.get("files") or []:
            file_id = str(item.get("id", ""))
            # Slack sends a file hidden by the plan's limit, or deleted, with
            # no download url.
            url = str(item.get("url_private_download") or "")
            if not url:
                lines.append(f"file {file_id} not fetched: no download url")
                continue
            given = item.get("size")
            size = given if isinstance(given, int) else None
            try:
                saved = save_file(
                    self.path, file_id, str(item.get("name") or ""), lambda out: self.api.download(url, size, out)
                )
            except Refusal as err:
                lines.append(f"file {file_id} not fetched: {err.value}")
                continue
            except OSError as err:
                lines.append(f"file {file_id} not fetched: {err.strerror or err}")
                continue
            lines.append(str(saved))
        return lines

    # -- outbound: the mailbox to Slack --------------------------------------

    def master_touched(self) -> Optional[float]:
        """SLACK_MASTER_FILE's mtime; None for an empty setting or an absent
        file, which is no master."""
        path = self.settings.master_file
        if not path:
            return None
        try:
            return os.stat(path).st_mtime
        except FileNotFoundError:
            return None
        except OSError as err:
            raise Refusal("master-file-unreadable", f"{path} ({err.strerror})") from err

    def master_read(self, events: List[Dict]) -> Optional[int]:
        """The master's seen line count, clamped to this mailbox snapshot;
        None when absent, unreadable or not a bare nonnegative integer."""
        path = self.path / "tmp/lane-mail/overseer/to-overseer.seen"
        try:
            text = path.read_text().strip()
            if not text.isascii() or not text.isdecimal():
                return None
            count = int(text)
        except (OSError, UnicodeError, ValueError):
            return None
        counts = [e["count"] for e in events if e["box"] == "to-overseer"]
        if None in counts:
            return None
        lines = max(counts, default=0)
        return min(count, lines)

    def resume(self, events: List[Dict]) -> None:
        """End a hold, post unread notices and open asks, then journal the
        seen count, skipped notice ids and asks whose posts landed."""
        seen = self.master_read(events)
        routed = self.routes(events, seen or 0)
        skipped = [str(envelope["id"]) for envelope, route in routed if route == "seen"]
        asks: List[str] = []
        # Stamp the resume now, not when presence expired: skipped notices
        # can be newer, and must stay carried until their age bars a post.
        at = format_at(self.clock())
        # A dead token can stop before a read notice; suppression is complete
        # before any post, while asks records only the posts that landed.
        try:
            self.post_events(routed, asks)
        finally:
            self.journal.append(
                t="resume", from_at=self.state.hold_at, at=at,
                seen=seen if seen is not None else "none", skipped=skipped, asks=asks
            )

    def routes(self, events: List[Dict], seen: int = 0) -> List[Tuple[Dict, str]]:
        """Each envelope not yet carried and what it takes: `ask`, `notice`,
        `answer`, `seen` for a notice the master read on resume, or `skip`
        for another that never posts."""
        answered = {e.get("re") for e in events if e.get("kind") == "answer"}
        horizon = self.settings.horizon(self.clock())
        state = self.state

        routed = []
        for envelope in events:
            env_id = str(envelope["id"])
            if env_id in state.carried or env_id in self.skipped:
                continue
            at = at_epoch(str(envelope["at"]))
            box = envelope.get("box")
            kind = envelope.get("kind")
            owner = box == "to-overseer" and envelope.get("to") == "owner"
            # `store.compact` drops an `out` line by this same age, so an
            # envelope whose line it may drop must never post again.
            if owner and kind == "notice" and envelope["line"] is not None and envelope["line"] <= seen:
                route = "seen"
            elif at < horizon:
                route = "skip"
            elif owner and kind == "ask":
                route = "skip" if env_id in answered else "ask"
            elif before(state.start_at, state.start_ids, at, env_id):
                route = "skip"
            elif owner and kind == "notice":
                route = "notice"
            elif box == "to-lane" and kind == "answer":
                route = "answer"
            else:
                route = "skip"
            routed.append((envelope, route))
        return routed

    def post_events(
        self, routed: List[Tuple[Dict, str]], landed: Optional[List[str]] = None
    ) -> None:
        """Posts what `routes` gives each envelope; `landed`, when given,
        collects the ids of the asks whose post landed."""
        for envelope, route in routed:
            if route == "ask":
                if self.post_ask(envelope) and landed is not None:
                    landed.append(str(envelope["id"]))
            elif route == "notice":
                self.post_notice(envelope)
            elif route == "answer":
                self.post_answer(envelope)
            elif route in ("skip", "seen"):
                self.skipped.add(str(envelope["id"]))
            else:
                raise AssertionError(f"route={route}")

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
        posted as standard Markdown, Slack's refusal to `post_refused`. A
        text past the `markdown_text` cap goes as `text`, Slack's mrkdwn,
        its Markdown marks shown literally: an ask or an answer the owner
        never sees would stand at its deadline unread. Returns the message
        ts or the upload's file id; None when nothing landed."""
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
            body_arg = "markdown_text" if len(text) <= MARKDOWN_LIMIT else "text"
            return str(self.api.post("chat.postMessage", channel=self.channel, thread_ts=thread_ts, **{body_arg: text})["ts"])
        except Refusal as err:
            self.post_refused(err, envelope, kind)
            return None

    def post_ask(self, envelope: Dict) -> bool:
        """Whether the ask landed and its `open` line was journaled."""
        options = ", ".join(envelope.get("options") or [])
        lines = [f"{mention(self.binding)} Question from {envelope.get('from', 'overseer')}:", envelope.get("text", "")]
        tail = []
        if options:
            tail.append(f"Options: {options}.")
        if envelope.get("recommend"):
            tail.append(f"Recommended: {envelope['recommend']}.")
        if envelope.get("deadline"):
            tail.append(f"It stands at {local_time(str(envelope['deadline']))} unless you reply in this thread.")
        if tail:
            lines.append(" ".join(tail))
        ts = self._send(envelope, "ask", "\n\n".join(lines), None)
        if ts is None:
            return False
        self._out(envelope, "ask", "open", thread=ts)
        return True

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

    def record_status(self, ok: bool, error: str, connection: str, since: str, connection_error: str) -> None:
        delivered = max(self.state.delivered, key=float, default="")
        write_status(
            self.path,
            {
                "pid": os.getpid(),
                "compacted_day": self.compacted_day,
                "channel": self.channel,
                "poll_seconds": self.settings.poll_seconds,
                "last_poll": self.clock(),
                "last_poll_ok": ok,
                "last_error": error,
                "last_delivered_ts": delivered,
                "seen_ts": self.state.seen_ts,
                "unknown": sorted(self.state.unknown),
                "refused": sorted(self.state.refused),
                "open_asks": sorted(t.envelope for t in self.state.threads.values() if t.open),
                "calls_last_minute": self.api.calls_last_minute(),
                "connection": connection,
                "connection_since": since,
                "connection_error": connection_error,
                "held_by": MASTER if self.state.held else "",

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
        self.by_channel = {root.channel: root for root in self.roots}
        for root in self.roots:
            root.lock.acquire()
        self.bot_user = str(api.get("auth.test")["user_id"])
        self.socket: Optional[WebSocket] = None
        # `connected`, `reconnecting` while the relay tries to open a
        # connection, or `disconnected` for a run that opens none; `since`
        # is the UTC second the state began.
        self.connection = "disconnected"
        self.since = format_at(clock())
        # The last refused connect or drop while the relay reconnects; empty
        # once a connection opens.
        self.connection_error = ""
        self.opened = False

    def poll_once(self) -> bool:
        """One poll of every root; False when any root's poll was refused."""
        clean = True
        today = datetime.datetime.fromtimestamp(self.clock(), datetime.timezone.utc).date().isoformat()
        for root in self.roots:
            try:
                root.compact_daily(today)
                root.poll(self.bot_user)
                root.record_status(True, "", self.connection, self.since, self.connection_error)
            except Exception as err:
                if isinstance(err, Refusal) and err.key == "slack-auth-failed":
                    raise
                error = f"{err.key}={err.value}" if isinstance(err, Refusal) else f"{type(err).__name__}: {err}"
                status_error = ""
                try:
                    root.record_status(False, error, self.connection, self.since, self.connection_error)
                except Exception as status_err:
                    # A broken root can also refuse its status write. Keep the
                    # poll's single diagnostic and continue to the next root.
                    status_error = f" status={type(status_err).__name__}: {status_err}"
                failure = Refusal(err.key, f"{err.value} root={root.path}{status_error}") if isinstance(err, Refusal) else Refusal(
                    "root-poll-failed", f"{root.path} cause={error}{status_error}"
                )
                print_refusal(failure)
                clean = False
        return clean

    def run(self, once: bool) -> int:
        """`--once` is one poll of every root with no connection, its
        catch-up included; otherwise the connection loop, which a dead token
        alone ends."""
        print(keyed("listening", f"{len(self.roots)} poll_seconds={self.settings.poll_seconds}"), flush=True)
        if once:
            return 0 if self.poll_once() else 1
        app_api = Slack(self.settings.app_token, self.settings.api_url, token_name="SLACK_APP_TOKEN", scope="connections:write")
        next_poll = retry_at = self.clock()
        delay = RETRY_FIRST_SECONDS
        while True:
            if self.socket is None and self.clock() >= retry_at:
                if self.open(app_api):
                    delay = RETRY_FIRST_SECONDS
                    next_poll = self.clock()
                else:
                    retry_at = self.clock() + delay
                    delay = min(2 * delay, RETRY_MAX_SECONDS)
            if self.clock() >= next_poll:
                self.poll_once()
                next_poll = self.clock() + self.settings.poll_seconds
            if self.socket is None:
                self.sleep(max(0.0, min(next_poll, retry_at) - self.clock()))
                continue
            self.listen_until(next_poll)
            if self.socket is None:
                retry_at = self.clock()

    def set_connection(self, connection: str) -> None:
        """The connection state as the next status record shows it; `since`
        moves only when the state changes."""
        if connection != self.connection:
            self.connection = connection
            self.since = format_at(self.clock())

    def refused(self, err: Refusal) -> None:
        """A connect refused or a connection dropped: printed, and carried
        as the connection error while the relay reconnects."""
        print_refusal(err)
        self.connection_error = f"{err.key}={err.value}"
        self.set_connection("reconnecting")

    def open(self, app_api: Slack) -> bool:
        """A new connection, ready once Slack's `hello` arrives: journaled
        `connect` the first time and `reconnect` after, every root's
        catch-up then due. False, with the refusal printed, when Slack or
        the network refused it; a token no retry mends stops the relay."""
        try:
            url = str(app_api.post("apps.connections.open")["url"])
            socket = WebSocket.connect(url, IDLE_SECONDS)
        except Refusal as err:
            if err.key == "slack-auth-failed":
                raise
            self.refused(err)
            return False
        except Closed as err:
            self.refused(Refusal("socket-lost", str(err)))
            return False
        try:
            hello = json.loads(socket.recv(HELLO_SECONDS) or "{}")
            if not isinstance(hello, dict) or hello.get("type") != "hello":
                raise Closed("no hello")
        except (Closed, ValueError) as err:
            socket.close()
            self.refused(Refusal("socket-lost", f"hello ({err})"))
            return False
        self.socket = socket
        self.set_connection("connected")
        self.connection_error = ""
        kind = "reconnect" if self.opened else "connect"
        self.opened = True
        for root in self.roots:
            root.journal.append(t=kind, at=self.since)
            root.caught_up = False
        notice(kind + "ed", self.since)
        return True

    def drop(self, reason: str) -> None:
        """The connection closed, journaled `disconnect` with `reason`."""
        assert self.socket is not None, "drop needs an open connection"
        self.socket.close()
        self.socket = None
        self.set_connection("reconnecting")
        for root in self.roots:
            root.journal.append(t="disconnect", at=self.since, reason=reason)
        self.refused(Refusal("socket-lost", reason))

    def listen_until(self, deadline: float) -> None:
        """Envelopes off the connection until `deadline` or a drop, the
        silent drop `WebSocket.recv` finds among them."""
        socket = self.socket
        assert socket is not None, "listen needs an open connection"
        while self.clock() < deadline:
            try:
                text = socket.recv(deadline - self.clock())
                if text is not None:
                    self.envelope(socket, text)
            except Closed as err:
                self.drop(str(err))
                return
            if self.socket is None:
                return

    def envelope(self, socket: WebSocket, text: str) -> None:
        """One envelope: acknowledged by its envelope_id before anything
        else, since the catch-up delivers what a stop after the
        acknowledgement cuts off, and the journal skips an envelope Slack
        sent again. A `disconnect` drops the connection for a
        new one; a message event goes to the root bound to its channel, and
        a refused delivery leaves that root's catch-up due; every other
        envelope stops at the acknowledgement."""
        try:
            envelope = json.loads(text)
        except ValueError as err:
            raise Closed("envelope not JSON") from err
        if not isinstance(envelope, dict):
            raise Closed("envelope not an object")
        if envelope.get("envelope_id"):
            socket.send_text(json.dumps({"envelope_id": envelope["envelope_id"]}))
        if envelope.get("type") == "disconnect":
            self.drop(f"slack-{envelope.get('reason', 'unknown')}")
            return
        if envelope.get("type") != "events_api":
            return
        event = (envelope.get("payload") or {}).get("event") or {}
        root = self.by_channel.get(str(event.get("channel", "")))
        if event.get("type") != "message" or root is None:
            return
        try:
            root.on_message(event, self.bot_user)
        except Refusal as err:
            if err.key == "slack-auth-failed":
                raise
            print_refusal(err)
            root.caught_up = False
