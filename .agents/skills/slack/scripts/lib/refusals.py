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
        "The named setting is not set. SLACK_BOT_TOKEN and SLACK_APP_TOKEN,"
        " which `listen` needs for its Socket Mode connection, live in the"
        " private env file or the process environment; SLACK_OWNERS defaults"
        " to KENDEX_USER_EMAIL, and setup's default channel name needs"
        " KENDEX_USER_HANDLE or KENDEX_USER_EMAIL. Unset is off, never half on: every missing key"
        " is named above before anything runs."
    ),
    "setting-invalid": (
        "The named setting holds a value the package cannot read; the value"
        " above says which. SLACK_POLL_SECONDS, SLACK_THREAD_DAYS and"
        " SLACK_MASTER_MAX_AGE are whole numbers of at least 1; SLACK_OWNERS"
        " is comma-separated email"
        " addresses."
    ),
    "orch-missing": (
        "The orch skill is not where the value names it: a root with no"
        " lane-mail to read or write its mailbox through, or a package run"
        " without its launcher, which names the orch install the secret-value"
        " pattern is read from. Install kendex's orch skill there, and run"
        " the package through scripts/slack."
    ),
    "channel-changed": (
        "The root's journal records deliveries in another channel, and its"
        " thread stamps mean nothing in the new one. fix= names the remedy:"
        " stop the relay, move the journal aside, then run setup again; the"
        " new channel then starts from the binding moment."
    ),
    "channel-shared": (
        "Two roots given to one relay are bound to the same channel, and"
        " each would deliver every owner message into its own mailbox."
        " fix= names the remedy: bind one of them to a channel of its own."
    ),
    "root-unbound": (
        "The root has no Slack binding. Run `slack setup` in that checkout"
        " first; the binding names the channel the relay reads."
    ),
    "root-unreadable": "The root is not a directory that can be read.",
    "root-poll-failed": "This checkout's poll failed. Other checkouts still run; this checkout retries on the next poll.",
    "binding-invalid": "The binding file is not the shape `slack setup` writes; run setup again.",
    "journal-invalid": (
        "A journal line is not one the relay writes. The journal is a"
        " transport ledger and nothing edits it by hand. Move it aside and"
        " restart: the relay then reads Slack again from the binding moment."
        " lane-mail answers each earlier owner message with the envelope"
        " that already landed. Nothing from the mailbox's past is posted but"
        " its open asks, which post again as new threads: answer the"
        " re-posted one, because replies under the relay's earlier posts are"
        " no longer read. Replies under an owner's own earlier message are"
        " read as directives. Every non-owner or empty message since the"
        " binding is answered once more."
    ),
    "slack-auth-failed": (
        "Slack refused the token. fix= names the remedy: set a live token"
        " under the setting it names, in the private env file or the process"
        " environment, then restart the relay."
    ),
    "slack-api-failed": (
        "A Slack API call did not succeed; the value names the method and"
        " Slack's error. Nothing was journaled as delivered."
    ),
    "slack-unreachable": (
        "The request never reached Slack: the connection, the TLS handshake"
        " or the write failed. Nothing is journaled; the relay makes the"
        " same call on its next poll, and `slack post` is refused with its"
        " file left on disk."
    ),
    "slack-response-lost": (
        "The request reached Slack and the answer was lost: a timeout or a"
        " dropped connection after the write. Slack may have acted on it."
        " The relay journals an envelope post lost this way as unknown,"
        " shown by --status, and never repeats it; a read is made again on"
        " the next poll. `slack post` is refused and its file stays on disk."
    ),
    "slack-invite-refused": (
        "Slack refused to invite the owners to the channel; the value names"
        " Slack's error and the owners' email addresses. No binding is"
        " written. fix= names the remedy."
    ),
    "slack-rate-limited": (
        "Slack answered 429 on every retry allowed, none for a catch-up read. The"
        " relay resumes a cut-off catch-up once Slack's Retry-After passes, makes"
        " a refused post or read again on its next poll, and a refused connect again on its"
        " reconnect wait. A `slack post` or `slack setup` refused this way"
        " sent nothing and must be run again."
    ),
    "slack-owner-unknown": (
        "Slack has no account under the named email address. fix= names the"
        " remedy: set SLACK_OWNERS to the addresses the workspace knows, or"
        " have the person join the workspace under this one."
    ),
    "slack-channel-public": (
        "The channel --take names is not private. Everything the relay posts"
        " is for the owners alone, so it binds a private channel only."
    ),
    "slack-channel-unjoined": (
        "The bot is not a member of the named private channel and cannot"
        " join one by itself. Invite the app to the channel in Slack, then"
        " run setup again."
    ),
    "relay-running": (
        "Another relay holds this checkout's lock; the value names its pid."
        " One relay serves one checkout. A channel moved between hosts is a"
        " stop there and a setup here. `compact` is refused the same way; the"
        " running relay compacts its own journal once a day."
    ),
    "lock-failed": (
        "The lock file could not be locked, for a reason other than another"
        " relay holding it; the value names the file and the error. A"
        " checkout on a mount without lock support cannot run a relay."
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
    "text-too-long": (
        "The text is longer than Slack takes as one Markdown message and is"
        " not sent; the value names its length and the limit. Send the long"
        " part as a file with --file, with a short text beside it."
    ),
    "text-not-literal": (
        "The text must reach the owner as typed, an ask's draft the owner"
        " approves, and the message is longer than Slack takes as one"
        " Markdown message. Slack's mrkdwn, the longer form, ends a code block"
        " at any run of three backticks, which the text holds, so the ask is"
        " not sent; the value names the envelope and the text's length."
        " Send it again with a shorter draft or one without that run."
    ),
    "master-file-unreadable": (
        "SLACK_MASTER_FILE names a path whose age cannot be read, for a"
        " reason other than its absence; the value names the path and the"
        " error. Nothing from the mailbox is posted until it can be read or"
        " the setting is emptied; owner messages are still delivered."
    ),
    "socket-lost": (
        "The Socket Mode connection closed, or a new one did not open; the"
        " value says why. The relay opens a new one at once, then after 1,"
        " 2, 4 and up to 60 seconds while each attempt fails, and reads the"
        " channel's history once it holds one, so a message sent in between"
        " still lands. Posts from the mailbox go on meanwhile. Once the"
        " relay has been without a connection for twice the longest wait,"
        " `listen --status` reads failing, with the last refusal as its fix=."
    ),
    "lane-mail-failed": (
        "lane-mail refused a call the relay needed; the value is its first"
        " line. After a refused write the Slack message is read again on the"
        " next poll; after a refused receipts read each :eyes: mark waits for"
        " the next poll, and the poll goes on."
    ),
    "code-unreadable": (
        "A file of the package's own code could not be read, so the relay"
        " cannot tell whether an update replaced it; the value names the"
        " file and the error. At start the relay exits 2. A running relay"
        " keeps the code it started with, and --status reads failing until"
        " the file can be read."
    ),
    "reexec-failed": (
        "The relay found an update of its code and could not start the"
        " launcher on it; the value names the launcher and the error. The"
        " relay exits, and the unit `install` wrote starts it again."
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
    "unit-inactive": (
        "The unit was enabled and started, and a moment later it is not"
        " active: the relay refused at start, and systemd restarts it every"
        " minute. fix= names the log that holds the relay's own refusal."
    ),
}


class Refusal(Exception):
    """A condition the package stops on, printed as one keyed line.

    `error` is Slack's own error code on a `slack-api-failed` refusal, carried
    as data for the callers that act on one code and empty otherwise; the
    printed value carries it as text for a reader. `retry_after` is Slack's
    Retry-After in seconds on `slack-rate-limited`."""

    def __init__(self, key: str, value: str = "", *extra_keyed: tuple, error: str = "", retry_after: float = 0.0) -> None:
        super().__init__(f"{key}={value}")
        self.key = key
        self.value = value
        self.error = error
        self.retry_after = retry_after
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
