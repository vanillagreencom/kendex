"""Every keyed line the package prints, and the one place their text lives.

A refusal or notice opens with ``slack: <key>=<value>``: a stable key for the
condition and the value acted on. The English explanation follows on later
lines. A caller parses the first line and never the rest.
"""

from __future__ import annotations

import sys

NAME = "slack"

EXPLAIN = {
    "usage": "Usage: slack --help",
    "setting-missing": (
        "The named setting is not set. SLACK_BOT_TOKEN lives in the private"
        " env file or the process environment; SLACK_OWNERS defaults to"
        " KENDEX_USER_EMAIL. Unset is off, never half on: every missing key"
        " is named above before anything runs."
    ),
    "setting-invalid": (
        "The named setting holds a value the package cannot read; the value"
        " above says which. SLACK_POLL_SECONDS and SLACK_THREAD_DAYS are"
        " whole numbers of at least 1; SLACK_OWNERS is comma-separated email"
        " addresses."
    ),
    "orch-missing": (
        "The root has no orch skill installed, so it has no lane-mail to read"
        " or write its mailbox through. Install kendex's orch skill there."
    ),
    "root-unbound": (
        "The root has no Slack binding. Run `slack setup` in that checkout"
        " first; the binding names the channel the relay reads."
    ),
    "root-unreadable": "The root is not a directory that can be read.",
    "binding-invalid": "The binding file is not the shape `slack setup` writes; run setup again.",
    "journal-invalid": (
        "A journal line is not one the relay writes. The journal is a"
        " transport ledger and nothing edits it by hand. Move it aside and"
        " restart: the relay then reads Slack again from the binding moment,"
        " which lane-mail answers with the envelopes that already landed,"
        " posts nothing from the mailbox's past but its open asks, which"
        " appear once more, and routes replies under earlier threads as"
        " directives."
    ),
    "slack-auth-failed": (
        "Slack refused the token. fix= names the remedy: set a live"
        " SLACK_BOT_TOKEN in the private env file or the process environment,"
        " then restart the relay."
    ),
    "slack-api-failed": (
        "A Slack API call did not succeed; the value names the method and"
        " Slack's error. Nothing was journaled as delivered."
    ),
    "slack-unreachable": (
        "The request never reached Slack: the connection, the TLS handshake"
        " or the write failed. Nothing is journaled; the relay makes the"
        " same call on its next poll, and a post is refused with its file"
        " left on disk."
    ),
    "slack-response-lost": (
        "The request reached Slack and the answer was lost: a timeout or a"
        " dropped connection after the write. Slack may have acted on it, so"
        " the relay journals the envelope as unknown, shown by --status, and"
        " never repeats it; a post is refused and its file stays on disk."
    ),
    "slack-invite-refused": (
        "Slack refused to invite the owners to the channel; the value names"
        " Slack's error and the owner ids. No binding is written. fix= names"
        " the remedy."
    ),
    "slack-rate-limited": (
        "Slack answered 429 on every retry the relay allows. Lower the call"
        " rate: raise SLACK_POLL_SECONDS on this home."
    ),
    "slack-owner-unknown": (
        "Slack has no account under the named email address. fix= names the"
        " remedy: set SLACK_OWNERS to the addresses the workspace knows, or"
        " have the person join the workspace under this one."
    ),
    "slack-channel-unjoined": (
        "The bot is not a member of the named private channel and cannot"
        " join one by itself. Invite the app to the channel in Slack, then"
        " run setup again."
    ),
    "relay-running": (
        "Another relay holds this checkout's lock; the value names its pid."
        " One relay serves one checkout. A channel moved between hosts is a"
        " stop there and a setup here."
    ),
    "secret-value": (
        "The text or file matches the secret-value pattern and is not sent."
        " Nothing that matches leaves this host through the relay."
    ),
    "secret-pattern-invalid": (
        "The secret-value pattern file does not hold exactly one pattern"
        " line; the relay sends nothing until it does."
    ),
    "file-unreadable": "The file to send could not be read.",
    "post-failed": "The post did not land; the line above says why. The file stays on disk.",
    "lane-mail-failed": (
        "lane-mail refused a write the relay needed; the value is its first"
        " line. The Slack message is read again on the next poll."
    ),
    "unit-unwritable": "The systemd unit file could not be written at the path named.",
    "systemctl-missing": (
        "systemctl is not on PATH, so the unit was written and not enabled;"
        " the value names what to run."
    ),
    "systemctl-failed": (
        "systemctl refused the command named, with that exit status; the"
        " unit was written. Run the command by hand and read its error."
    ),
}


class Refusal(Exception):
    """A condition the package stops on, printed as one keyed line."""

    def __init__(self, key: str, value: str = "", *extra_keyed: tuple) -> None:
        super().__init__(f"{key}={value}")
        self.key = key
        self.value = value
        self.extra_keyed = list(extra_keyed)


def keyed(key: str, value: str) -> str:
    return f"{NAME}: {key}={value}"


def print_refusal(err: Refusal) -> None:
    lines = [keyed(err.key, err.value)]
    lines.extend(keyed(k, v) for k, v in err.extra_keyed)
    lines.append(EXPLAIN[err.key])
    print("\n".join(lines), file=sys.stderr, flush=True)


def notice(key: str, value: str) -> None:
    """A keyed line on stdout for a condition that stops nothing."""
    print(keyed(key, value), flush=True)
