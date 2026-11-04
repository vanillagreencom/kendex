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
from relay import listen
from settings import load

HELP = """\
Usage: slack setup [--root ROOT] [--name NAME | --take CHANNEL_ID]
       slack listen --root ROOT [--root ROOT]... [--once]
       slack listen --status --root ROOT [--root ROOT]...
       slack post [--root ROOT] [--channel ID] --text TEXT [--mention]
                  [--file PATH]... [--thread TS] [--update TS]
       slack read --channel ID (--ts TS | --latest N)
       slack compact [--root ROOT]...
       slack thread TS [--root ROOT] [--limit N]
       slack install --root ROOT [--root ROOT]... [--print]

Relays one checkout's overseer mailbox to one private Slack channel and back,
owner messages over Slack's Socket Mode. Reads use the mailbox package installed
beside Slack. Writes use each bound checkout's lane-mail. A root is a checkout;
without --root, use the checkout the command runs in.

setup     resolve every SLACK_OWNERS address to a Slack user, create the
          private channel or find it by name (--name; default
          <person>-<repo>-<side>: KENDEX_USER_HANDLE, else KENDEX_USER_EMAIL's
          local part; origin's repository name, else the checkout's; vm where
          the orch lane host is hosted, else local; a bound checkout keeps
          its channel), or adopt an existing
          private one by id (--take), invite the owners, set the channel's
          purpose where it is empty, write the binding
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
          notices and rulings land in Slack as standard Markdown.
          Reports continue in formatted parts when needed; normal and overdue
          questions past 12,000 characters after expansion are refused.
          An attached report lands as its file with the notice as its mrkdwn
          comment. A post Slack refuses fails the poll and is made again on
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
          longest wait; a missing or unreadable tmp/slack/binding.json
          reports state=failing cause=binding-missing|binding-unreadable,
          whatever the connection, with fix=slack setup --take CHANNEL --root DIR
post      one message to the bound channel, or --channel for another, its
          text sent as standard Markdown of at most 12,000 characters
          after link expansion; larger text is refused;
          --mention prefixes every owner, unless the root's Jarvis session
          hold stands, which posts with no mention and prints mention-held
          on stderr; repeat --file to upload related files as one share with
          the text as their comment instead, in Slack's mrkdwn and outside the
          12,000-character cap;
          --thread replies only in a thread; --update edits the message at that
          ts. Text and file bytes are refused when they match the
          secret-value pattern
read      read the named channel without a binding or owner settings, using
          the same token settings as post --channel; --ts reads a message
          and its replies, --latest reads the newest N top-level messages.
          Print oldest first: slack: ts=TS edited=TS|- bot=ID|user=ID text=TEXT.
          text is the last field; backslash, newline and carriage return
          become \\\\, \\n and \\r. Slack markup stays literal. An empty channel
          prints nothing. --latest must be positive
thread    print the requested thread as plain text, oldest first, each
          message headed by its author (owner or app, or another person's
          Slack user id) and UTC time; TS names
          its root or a reply; --limit caps the messages printed, otherwise
          all cursor pages are read. No thread is read by default
compact   drop journal lines resolved or ignored longer ago than
          SLACK_THREAD_DAYS; open questions, positions and reader delivery
          marks stay. The relay runs
          it once a day; a root whose relay is running is refused
install   write the systemd user unit for `listen` over the roots given, then
          daemon-reload, enable and restart it, so a running relay takes the
          new roots; --print writes the unit to stdout only

Process settings, read once from the launch checkout's private env and settings
files, with caller exports taking precedence: SLACK_BOT_TOKEN, SLACK_APP_TOKEN (listen without
--once), SLACK_OWNERS (default KENDEX_USER_EMAIL), KENDEX_USER_HANDLE (setup's
channel name; default KENDEX_USER_EMAIL's local part), SLACK_POLL_SECONDS (15),
SLACK_THREAD_DAYS (7) and SLACK_API_URL (default https://slack.com/api).
The optional slash commands and Home tab, each off while empty:
SLACK_STATUS_COMMAND and SLACK_ASKS_COMMAND, the command lines /lanes and
/asks reply with the output of; SLACK_REPORT_ROOT, the --root checkout whose
overseer mailbox /report writes one directive to; SLACK_HOME_COMMAND, the
command line whose output the Home tab shows. A command line runs with no
shell; after 10 seconds TERM and then KILL stop its process group.
Each stdout/stderr capture is bounded to 4 * the 12,000-character post cap
plus 4096 bytes (52,096 bytes). Excess is drained and discarded. A cut is
noted in the reply; oversized successful stdout is withheld in full because
whole-output secret checking is unavailable. Stderr stays on relay stderr.
On Linux the child sets and verifies oom_score_adj=1000 before target exec;
macOS skips scoring. A missing Linux interface permits an unscored command
with a diagnostic; an actual score I/O failure refuses that command's start.
The unit keeps MemoryMax and uses OOMPolicy=continue. These reduce risk,
not guarantee survival. No unit counters are acquired; SIGKILL alone is not
reported as OOM, a victim identity or a configured memory-limit event.
SLACK_JARVIS_SESSION_FILE (empty) and SLACK_JARVIS_SESSION_MAX_AGE (600) are read per root
at every poll, using the settings reader when that root's files change,
with the original caller exports taking precedence. Other settings need
slack setup or a restart.
A relative file path starts at its root; ~ expands to the home directory.
While its file is younger than its age bound, --status shows held-by=jarvis.
A root naming no file has no hold. README.md defines the Jarvis session hold and resume.

Stalled-worker diagnostic on stderr, exit 2:
  worker-stalled=STAGE age=SECONDS bound=SECONDS
    STAGE names the worker operation that stopped making progress.
    age is seconds since startup or the last completed poll, connect
    attempt, API operation, copied download chunk or configured command
    run.
    bound is SLACK_POLL_SECONDS plus
    RECONNECT_BOUND_SECONDS. The failed exit lets a service configured
    with Restart=on-failure restart the relay.

Non-fatal diagnostics on stderr:
  setting-renamed old=KEY new=KEY
    A retired presence key supplies the value; the new key is unset.
    Printed once per old key and process, including across package reloads.
  reference-link-unavailable=REFERENCE root=ROOT cause=CAUSE
    A PR repository or commit hash cannot be resolved. The text is sent unchanged.
  envelope-field=ROOT id=ID field=FIELD
    Missing or invalid line/count fields disable Jarvis-read suppression.
    Other invalid fields skip that envelope. The relay continues.
  handle-from-email=LOCAL
    KENDEX_USER_HANDLE is unset; setup names the channel after LOCAL.
  purpose-unset=CHANNEL error=ERROR
    Slack refused the channel purpose. setup still binds.
  command-failed=SETTING cause=start|timeout|exit-N|empty
    The command line SETTING names failed or printed nothing. The reply
    or Home tab names the cause and carries none of the command's output.
  command-score-unavailable=SETTING cause=absent
    The Linux scoring interface is absent; the command ran unscored.
  command-output-cut=SETTING stream=stderr bytes=N
    Stderr exceeded its capture bound; only its retained prefix is local.
  secret-check-incomplete=command=SETTING
    Oversized successful stdout is withheld, including its retained prefix.
  command-unanswerable=COMMAND
    A slash command arrived with no response_url; nothing ran.
  home-not-enabled=setting|slack
    SLACK_HOME_COMMAND is unset, or Slack answered views.publish with
    not_enabled. Printed once per process; Home stays off until a restart
    and the relay keeps running.

""" + textwrap.fill(
    "Keyed lines, `slack: <key>=<value>` first: bound, posted, uploaded, updated,"
    " compacted, installed, enabled, active, restarted, listening, connected,"
    " reconnected, reloading, slack-relay, ts on stdout; tracker-links-unavailable is a non-fatal"
    " notice on stderr; worker-stalled is on stderr with exit 2;"
    " refusals on stderr with exit 2: python3 and"
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
    p.add_argument("--file", action="append")
    p.add_argument("--mention", action="store_true")
    p.add_argument("--thread")

    p.add_argument("--update")
    p = verbs.add_parser("read", add_help=False)
    p.add_argument("--channel", required=True)
    selector = p.add_mutually_exclusive_group(required=True)
    selector.add_argument("--ts")
    selector.add_argument("--latest", type=int)
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
        return listen(roots, settings, verbs.api_for(settings), args.once)
    if args.verb == "post":
        if not args.text and not args.file:
            raise Refusal("usage", "post needs --text or --file")
        if args.update and args.file:
            raise Refusal("usage", "--update edits text and takes no --file")
        root = roots_of([args.root] if args.root else [])[0]
        return verbs.post(root, args.channel, args.text, args.file, args.mention, args.thread, args.update)
    if args.verb == "read":
        if args.latest is not None and args.latest < 1:
            raise Refusal("usage", "--latest must be positive")
        return verbs.read(args.channel, args.ts, args.latest)
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
