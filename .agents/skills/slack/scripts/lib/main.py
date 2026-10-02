"""Entry point: argv to one verb, every refusal one keyed line, exit 2."""

from __future__ import annotations

import argparse
import os
import sys
import textwrap
import time
from pathlib import Path
from typing import List

import verbs
from refusals import EXPLAIN, Refusal, print_refusal
from relay import Relay
from settings import load

HELP = """\
Usage: slack setup [--root ROOT] [--name NAME | --take CHANNEL_ID]
       slack listen --root ROOT [--root ROOT]... [--once]
       slack listen --status --root ROOT [--root ROOT]...
       slack post [--root ROOT] [--channel ID] --text TEXT [--mention]
                  [--file PATH] [--thread TS] [--update TS]
       slack compact [--root ROOT]...
       slack thread TS [--root ROOT] [--limit N]
       slack install --root ROOT [--root ROOT]... [--print]

Relays one checkout's overseer mailbox to one private Slack channel and back,
owner messages over Slack's Socket Mode, reading and writing the mailbox only
through that checkout's lane-mail. A root is a checkout; without --root, the
checkout the command runs in.

setup     resolve every SLACK_OWNERS address to a Slack user, create the
          private channel or find it by name (--name; default
          <checkout>-<owner's local part>), or adopt an existing private one
          by id (--take), invite the owners, write the binding
          tmp/slack/binding.json, and restart the relay unit `install` wrote
          when one stands
listen    the relay: one Socket Mode connection opened with SLACK_APP_TOKEN
          for every root, each envelope acknowledged as soon as the loop
          reads it on a separate reader, before delivery; API and mailbox
          waits do not block acknowledgements or pong replies. Messages route
          by channel; delivered= names ts, mailbox id and live/catch-up path.
          At every connect and reconnect,
          per root, one history read that delivers what arrived while
          disconnected; every SLACK_POLL_SECONDS, per root, the mailbox's
          events; owner text lands as a directive or, in a question's
          thread, as its answer, each with --delivery-id channel:ts; asks,
          notices and rulings land in Slack as standard
          Markdown, one past 12,000 characters as mrkdwn, a report as its
          file with the notice as its mrkdwn comment. A post Slack refuses fails the poll and is made again on
          the next one; an envelope post whose response was lost is
          journaled unknown and never repeated. One relay per checkout, held
          by an OS lock; two roots bound to one channel are refused; --once
          opens no connection, polls each root once, history read included,
          and exits 0 when every poll succeeded, 1 for a retryable poll
          failure. A fatal refusal, such as a dead token, exits 2. A
          change to the package's code that holds for two polls re-executes
          the relay in place, which reads its settings again, once the
          relay is connected and holds no refused live delivery
  --status  one `slack-relay=ROOT state=ok|failing|stale|never` line per
          root from the relay's status record, with the connection state
          and the fingerprint of the running code as code=;
          failing too while the relay has been reconnecting past twice its
          longest wait
post      one message to the bound channel, or --channel for another, its
          text sent as standard Markdown of at most 12,000 characters;
          link expansion past that cap selects Slack's mrkdwn instead;
          --mention prefixes every owner; --file uploads the file with the
          text as its comment instead, in Slack's mrkdwn and outside the
          12,000-character cap;
          --thread replies only in a thread; --update edits the message at that
          ts. Text and file bytes are refused when they match the
          secret-value pattern
thread    print the requested thread as plain text, oldest first; TS names
          its root or a reply; --limit caps the messages printed, otherwise
          all cursor pages are read. No thread is read by default
compact   drop journal lines resolved or ignored longer ago than
          SLACK_THREAD_DAYS; open questions and positions stay. The relay runs
          it once a day; a root whose relay is running is refused
install   write the systemd user unit for `listen` over the roots given, then
          daemon-reload, enable and restart it, so a running relay takes the
          new roots; --print writes the unit to stdout only

Process settings, read once from the launch checkout's private env and settings
files, with caller exports taking precedence: SLACK_BOT_TOKEN, SLACK_APP_TOKEN (listen without
--once), SLACK_OWNERS (default KENDEX_USER_EMAIL), SLACK_POLL_SECONDS (15),
SLACK_THREAD_DAYS (7) and SLACK_API_URL (default https://slack.com/api).
SLACK_MASTER_FILE (empty) and SLACK_MASTER_MAX_AGE (600) are read per root
from that root's files, with the original caller exports taking precedence.
A relative file path starts at its root; ~ expands to the home directory.
While its file is younger than its age bound, listen holds only that root's
mailbox posts and --status shows held-by=master. A root naming no file has
no hold. README.md says what posts on resume.

Non-fatal diagnostics on stderr:
  envelope-field=ROOT id=ID field=FIELD
    Missing or invalid line/count fields disable master-read suppression.
    Other invalid fields skip that envelope. The relay continues.

""" + textwrap.fill(
    "Keyed lines, `slack: <key>=<value>` first: bound, posted, uploaded, updated,"
    " compacted, installed, enabled, active, restarted, listening, connected,"
    " reconnected, reloading, slack-relay on stdout; tracker-links-unavailable is a non-fatal"
    " notice on stdout; refusals on stderr with exit 2: python3 and"
    " settings-unreadable from the launcher before Python starts, then "
    + ", ".join(EXPLAIN) + ".",
    width=78, break_on_hyphens=False,
) + "\n"


class Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:  # type: ignore[override]
        raise Refusal("usage", message)


def roots_of(values: List[str]) -> List[Path]:
    roots = []
    for value in values or [str(Path.cwd())]:
        path = Path(value)
        if not path.is_dir():
            raise Refusal("root-unreadable", value)
        roots.append(Path(os.path.realpath(path)))
    return roots


def build() -> Parser:
    parser = Parser(prog="slack", add_help=False)
    parser.add_argument("-h", "--help", action="store_true")
    verbs = parser.add_subparsers(dest="verb")
    p = verbs.add_parser("setup", add_help=False)
    p.add_argument("--root")
    p.add_argument("--name")
    p.add_argument("--take")
    p = verbs.add_parser("listen", add_help=False)
    p.add_argument("--root", action="append")
    p.add_argument("--once", action="store_true")
    p.add_argument("--status", action="store_true")
    p = verbs.add_parser("post", add_help=False)
    p.add_argument("--root")
    p.add_argument("--channel")
    p.add_argument("--text")
    p.add_argument("--file")
    p.add_argument("--mention", action="store_true")
    p.add_argument("--thread")

    p.add_argument("--update")
    p = verbs.add_parser("compact", add_help=False)
    p.add_argument("--root", action="append")
    p = verbs.add_parser("thread", add_help=False)
    p.add_argument("ts")
    p.add_argument("--root")
    p.add_argument("--limit", type=int)
    p = verbs.add_parser("install", add_help=False)
    p.add_argument("--root", action="append")
    p.add_argument("--print", action="store_true")
    return parser


def run(argv: List[str]) -> int:
    args = build().parse_args(argv)
    if args.help or args.verb is None:
        sys.stdout.write(HELP)
        return 0
    if args.verb == "setup":
        if args.name and args.take:
            raise Refusal("usage", "--name and --take are exclusive")
        return verbs.setup(roots_of([args.root] if args.root else [])[0], args.name, args.take)
    if args.verb == "listen":
        if not args.root:
            raise Refusal("usage", "listen needs at least one --root")
        roots = roots_of(args.root)
        if args.status:
            return verbs.status(roots, time.time())
        settings = load(need_app_token=not args.once)
        relay = Relay(roots, settings, verbs.api_for(settings))
        return relay.run(args.once)
    if args.verb == "post":
        if not args.text and not args.file:
            raise Refusal("usage", "post needs --text or --file")
        if args.update and args.file:
            raise Refusal("usage", "--update edits text and takes no --file")
        root = roots_of([args.root] if args.root else [])[0]
        return verbs.post(root, args.channel, args.text, args.file, args.mention, args.thread, args.update)
    if args.verb == "compact":
        return verbs.compact_roots(roots_of(args.root or []))
    if args.verb == "thread":
        if args.limit is not None and args.limit < 1:
            raise Refusal("usage", "--limit must be positive")
        return verbs.thread(roots_of([args.root] if args.root else [])[0], args.ts, args.limit)
    if args.verb == "install":
        if not args.root:
            raise Refusal("usage", "install needs at least one --root")
        return verbs.install(roots_of(args.root), args.print)
    raise Refusal("usage", f"unknown verb {args.verb}")


def main() -> int:
    try:
        return run(sys.argv[1:])
    except Refusal as err:
        print_refusal(err)
        return 2
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
