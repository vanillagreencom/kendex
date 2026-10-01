"""Outbound tracker links and Slack markup read back as the text typed.

Slack escapes `&`, `<` and `>` in a message's text as `&amp;`, `&lt;` and
`&gt;`, and writes a link, a mention and a broadcast as a `<...>` token:
`<URL>`, `<URL|label>`, `<@U123>`, `<#C123|name>`, `<!here>`. Emoji stay
`:name:`. Each piece is unescaped once, so an owner who typed `&lt;` reads
`&lt;` and never `<`.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
from itertools import chain
from pathlib import Path
from typing import Callable, Dict, Optional, Tuple

from api import MARKDOWN_LIMIT
from refusals import notice

TOKEN = re.compile(r"<([^<>]*)>")
# These are literal regions in owner-authored Markdown and Slack mrkdwn.
SKIP_ZONES = {
    "fence": r"^ {0,3}(?P<fence>`{3,}|~{3,})[^\n]*\n[\s\S]*?(?:^ {0,3}(?P=fence)[`~]*[ \t]*(?:\n|$)|\Z)",
    "code": r"(?<!`)(?P<ticks>`+)(?!`)[\s\S]*?(?<!`)(?P=ticks)(?!`)",
    "markdown": r"^ {0,3}\[[^\]\n]+\]:[^\n]*|!?\[(?:\\.|[^\]\\]|\[[^\]]*\])*\](?:\((?:\\.|[^()\\]|\([^()]*\))*\)|\[[^\]\n]*\])",
    "angle": r"<[^<>\n]*>",
    "url": r"\b(?:[a-zA-Z][a-zA-Z0-9+.-]*://|www\.)[^\s<>`]+",
}
LITERAL = re.compile("|".join(SKIP_ZONES.values()), re.MULTILINE)
METADATA_SECONDS = 86400
Tracker = Tuple[re.Pattern, Callable[[str], str]]


class TrackerMetadata:
    """Per-root tracker discovery and Linear metadata, cached for one day.

    The relay is single-threaded. Failed reads are cached too: an optional
    linking failure must not block owner messages or print on every poll.
    """

    def __init__(self, clock: Callable[[], float] = time.time) -> None:
        self.clock = clock
        self.cache: Dict[Path, Tuple[float, Optional[Tracker]]] = {}
        self.warned: set = set()

    def _read(self, root: Path, argv: list) -> str:
        proc = subprocess.run(argv, cwd=root, capture_output=True, text=True, timeout=30, check=False)
        if proc.returncode != 0:
            raise ValueError(f"{argv[0]} exit={proc.returncode}")
        return proc.stdout.strip()

    def get(self, root: Path) -> Optional[Tracker]:
        """Resolve through orch-env in this root, never the relay's checkout."""
        now = self.clock()
        cached = self.cache.get(root)
        if cached is not None and now - cached[0] < METADATA_SECONDS:
            return cached[1]
        tracker = None
        try:
            team = self._read(root, [str(Path(os.environ["SLACK_ORCH_DIR"]) / "scripts/orch-env"), "LINEAR_TEAM", ""])
            if team:
                script = Path(os.environ["SLACK_LINEAR_DIR"]) / "scripts/linear.sh"
                data = json.loads(self._read(root, [str(script), "teams", "keys"]))
                slug, keys = data["urlKey"], data["keys"]
                # Linear's read action produces a workspace slug and a key array.
                if not isinstance(slug, str) or re.fullmatch(r"[a-zA-Z0-9_-]+", slug) is None:
                    raise ValueError("teams keys urlKey=invalid")
                if not isinstance(keys, list) or not keys or any(
                    not isinstance(key, str) or re.fullmatch(r"[A-Z][A-Z0-9]*", key) is None for key in keys
                ):
                    raise ValueError("teams keys keys=invalid")
                pattern = re.compile(r"\b(?:" + "|".join(re.escape(key) for key in sorted(keys, key=len, reverse=True)) + r")-[0-9]+\b")
                tracker = (pattern, lambda identifier: f"https://linear.app/{slug}/issue/{identifier}")
            else:
                # No repository is an expected state, not a linking failure.
                try:
                    repo = json.loads(self._read(root, ["gh", "repo", "view", "--json", "nameWithOwner"]))["nameWithOwner"]
                except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
                    repo = ""
                if isinstance(repo, str) and re.fullmatch(r"[\w.-]+/[\w.-]+", repo):
                    pattern = re.compile(r"(?<![\w/#])(?:[\w.-]+/[\w.-]+)?#[0-9]+\b")
                    def issue_url(identifier: str) -> str:
                        project, _, number = identifier.partition("#")
                        return f"https://github.com/{project or repo}/issues/{number}"
                    tracker = (pattern, issue_url)
        except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as err:
            if root not in self.warned:
                notice("tracker-links-unavailable", f"{root} cause={err}")
                self.warned.add(root)
        self.cache[root] = (now, tracker)
        return tracker


TRACKERS = TrackerMetadata()


def outbound(root: Path, text: str, file_comment: bool = False, fallback: bool = True) -> Tuple[str, str]:
    """Link bare tracker ids once and return the actual outbound representation.

    Expansion is measured as Markdown before choosing its representation.
    Post retains its refusal for an already oversized input; link expansion
    alone can select mrkdwn there. Files always take mrkdwn.
    """
    tracker = TRACKERS.get(root)
    parts = []
    pos = 0
    if tracker is not None:
        pattern, url = tracker
        for start, end in chain(((literal.start(), literal.end()) for literal in LITERAL.finditer(text)), [(len(text), len(text))]):
            for match in pattern.finditer(text, pos, start):
                parts.append((text[pos:match.start()], None))
                parts.append((match.group(), url(match.group())))
                pos = match.end()
            parts.append((text[pos:end], None))
            pos = end
    parts.append((text[pos:], None))
    markdown_size = sum(len(label) if target is None else len(label) + len(target) + 4 for label, target in parts)
    mrkdwn = file_comment or markdown_size > MARKDOWN_LIMIT and (fallback or len(text) <= MARKDOWN_LIMIT)
    body = "".join(label if target is None else f"<{target}|{label}>" if mrkdwn else f"[{label}]({target})" for label, target in parts)
    return body, "text" if mrkdwn else "markdown_text"


def unescape(text: str) -> str:
    """`&amp;` last, so the `&lt;` an owner typed stays `&lt;`."""
    return text.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")


def plain(text: str, user_name: Callable[[str], str]) -> str:
    """The message text as typed; `user_name` names a user id a mention
    carries with no label."""
    pieces = []
    pos = 0
    for match in TOKEN.finditer(text):
        pieces.append(unescape(text[pos : match.start()]))
        pieces.append(_token(match.group(1), user_name))
        pos = match.end()
    pieces.append(unescape(text[pos:]))
    return "".join(pieces)


def _token(inner: str, user_name: Callable[[str], str]) -> str:
    target, _, label = inner.partition("|")
    target, label = unescape(target), unescape(label)
    if target.startswith("@"):
        return "@" + (label or user_name(target[1:]))
    if target.startswith("#"):
        return "#" + (label or target[1:])
    if target.startswith("!"):
        # `<!here>`, `<!channel>`, `<!subteam^S1|@team>`, `<!date^...|fallback>`
        return label or "@" + target[1:].split("^")[0]
    return f"{label} ({target})" if label else target
