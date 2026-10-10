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
import sys
import time
from dataclasses import dataclass
from itertools import chain
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence, Tuple, Union

from api import MARKDOWN_LIMIT
from refusals import Refusal, keyed, notice
from secret import pattern as secret_pattern

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
REFERENCES = re.compile(r"(?<![\w/#])(?:[\w.-]+(?:/[\w.-]+)?)?#[0-9]+\b|\b[0-9a-fA-F]{4,64}\b")


class TrackerMetadata:
    """Per-root tracker discovery and Linear metadata, cached for one day.

    The relay is single-threaded. Failed reads are cached too: an optional
    linking failure must not block owner messages or print on every poll.
    """

    def __init__(self, clock: Callable[[], float] = time.time) -> None:
        self.clock = clock
        self.cache: Dict[Path, Tuple[float, Optional[Tracker]]] = {}
        self.repositories: Dict[Path, Tuple[float, str]] = {}
        self.warned: set = set()

    def _read(self, root: Path, argv: list) -> str:
        proc = subprocess.run(argv, cwd=root, capture_output=True, text=True, timeout=30, check=False)
        if proc.returncode != 0:
            raise ValueError(f"{argv[0]} exit={proc.returncode}")
        return proc.stdout.strip()

    def repository(self, root: Path) -> str:
        cached = self.repositories.get(root)
        now = self.clock()
        if cached is not None and now - cached[0] < METADATA_SECONDS:
            return cached[1]
        try:
            repo = json.loads(self._read(root, ["gh", "repo", "view", "--json", "nameWithOwner"]))["nameWithOwner"]
            if not isinstance(repo, str) or re.fullmatch(r"[\w.-]+/[\w.-]+", repo) is None:
                repo = ""
        except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
            repo = ""
        self.repositories[root] = (now, repo)
        return repo

    def references(self, root: Path) -> Tuple[re.Pattern, Callable[[str], Optional[str]]]:
        resolved: Dict[str, Optional[str]] = {}

        def url(identifier: str) -> Optional[str]:
            if identifier in resolved:
                return resolved[identifier]
            repo = self.repository(root) if "/" not in identifier else ""
            target = None
            cause = "repository-unknown"
            if "#" in identifier:
                project, _, number = identifier.partition("#")
                if "/" in project:
                    target = f"https://github.com/{project}/pull/{number}"
                elif repo and (not project or project.casefold() == repo.split("/")[1].casefold()):
                    target = f"https://github.com/{repo}/pull/{number}"
            elif repo:
                cause = "commit-unresolved"
                try:
                    env = {key: os.environ[key] for key in ("PATH", "HOME", "LANG") if key in os.environ}
                    proc = subprocess.run(["git", "rev-parse", "--disambiguate=" + identifier.lower()],
                                          cwd=root, env=env, capture_output=True, text=True, timeout=30, check=False)
                    commit = proc.stdout.strip()
                    if proc.returncode == 0 and re.fullmatch(r"[0-9a-fA-F]{40,64}", commit):
                        proc = subprocess.run(["git", "cat-file", "-t", commit], cwd=root, env=env,
                                              capture_output=True, text=True, timeout=30, check=False)
                        if proc.returncode == 0 and proc.stdout.strip() == "commit":
                            target = f"https://github.com/{repo}/commit/{commit}"
                except (OSError, subprocess.SubprocessError):
                    pass
            if target is None:
                print(keyed("reference-link-unavailable", f"{identifier} root={root} cause={cause}"), file=sys.stderr, flush=True)
            resolved[identifier] = target
            return target

        return REFERENCES, url

    def get(self, root: Path) -> Optional[Tracker]:
        """Read workspace keys in this root, never the relay's checkout."""
        now = self.clock()
        cached = self.cache.get(root)
        if cached is not None and now - cached[0] < METADATA_SECONDS:
            return cached[1]
        tracker = None
        try:
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
        except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as err:
            if root not in self.warned:
                notice("tracker-links-unavailable", f"{root} cause={err}")
                self.warned.add(root)
        self.cache[root] = (now, tracker)
        return tracker


TRACKERS = TrackerMetadata()


@dataclass(frozen=True)
class Verbatim:
    """Text the owner must read exactly as typed, an ask's draft: one code
    block, never linked. The caller places it on lines of its own. `what`
    names it in a refusal."""

    text: str
    what: str

    def markdown(self) -> str:
        """A fence longer than any backtick run in the text, so no line of
        the text closes it and Slack shows the text as typed."""
        longest = max((len(run) for run in re.findall(r"`+", self.text)), default=0)
        fence = "`" * max(3, longest + 1)
        return f"{fence}\n{self.text}\n{fence}"

    def mrkdwn(self) -> str:
        """mrkdwn's code block, its control characters escaped. mrkdwn has
        one fence, three backticks, so a text holding that run would close
        the block early and cannot be shown as typed: `text-not-literal`."""
        if "```" in self.text:
            raise Refusal("text-not-literal", f"{self.what} chars={len(self.text)}")
        return f"```\n{escape(self.text)}\n```"


# A run of outbound text: plain, a tracker link as (label, url), or a block.
Part = Union[str, Tuple[str, str], Verbatim]


def outbound(root: Path, text: Union[str, Sequence[Union[str, Verbatim]]], file_comment: bool = False,
             fallback: bool = True) -> Tuple[str, str]:
    """Link bare tracker ids once and return the actual outbound representation.

    `text` is one string, or strings and `Verbatim` blocks in order; a
    string is linked, a block never is. Expansion is measured as Markdown
    before choosing its representation. Post retains its refusal for an
    already oversized input; link expansion alone can select mrkdwn there.
    Files always take mrkdwn.
    """
    pieces = [text] if isinstance(text, str) else list(text)
    # Expansion must not hide a match from the caller's refusal check.
    preserve = secret_pattern().search("".join(_render(piece, mrkdwn=False) for piece in pieces).encode()) is not None
    tracker = TRACKERS.get(root)
    references = TRACKERS.references(root)
    parts: List[Part] = []
    for piece in pieces:
        if isinstance(piece, Verbatim) or preserve:
            parts.append(piece)
        else:
            parts.extend(_linked(piece, tracker, references))
    markdown = "".join(_render(part, mrkdwn=False) for part in parts)
    input_size = sum(len(piece) if isinstance(piece, str) else len(piece.markdown()) for piece in pieces)
    mrkdwn = file_comment or len(markdown) > MARKDOWN_LIMIT and (fallback or input_size <= MARKDOWN_LIMIT)
    if not mrkdwn:
        return markdown, "markdown_text"
    return "".join(_render(part, mrkdwn=True) for part in parts), "text"


def _linked(text: str, tracker: Optional[Tracker], references: Tuple[re.Pattern, Callable[[str], Optional[str]]]) -> List[Part]:
    """`text` as plain runs and bare tracker ids with their URLs; literal
    regions are never linked."""
    parts: List[Part] = []
    pos = 0
    reference_pattern, reference_url = references
    pattern = re.compile(reference_pattern.pattern + ("|" + tracker[0].pattern if tracker is not None else ""))
    for start, end in chain(((literal.start(), literal.end()) for literal in LITERAL.finditer(text)), [(len(text), len(text))]):
        for match in pattern.finditer(text, pos, start):
            identifier = match.group()
            target = reference_url(identifier) if reference_pattern.fullmatch(identifier) else tracker[1](identifier)
            parts.append(text[pos:match.start()])
            parts.append((identifier, target) if target is not None else identifier)
            pos = match.end()
        parts.append(text[pos:end])
        pos = end
    parts.append(text[pos:])
    return parts


def _render(part: Part, mrkdwn: bool) -> str:
    if isinstance(part, str):
        return part
    if isinstance(part, Verbatim):
        return part.mrkdwn() if mrkdwn else part.markdown()
    label, target = part
    return f"<{target}|{label}>" if mrkdwn else f"[{label}]({target})"


def escape(text: str) -> str:
    """Slack's three control characters as entities, `&` first so an
    entity the text already holds reads back as typed."""
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


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
