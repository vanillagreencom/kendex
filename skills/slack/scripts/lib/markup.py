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
from typing import Callable, Dict, List, NamedTuple, Optional, Sequence, Tuple, Union

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
LITERAL = re.compile("|".join(f"(?P<zone_{name}>{zone})" for name, zone in SKIP_ZONES.items()), re.MULTILINE)
METADATA_SECONDS = 86400
Tracker = Tuple[re.Pattern, Callable[[str], str]]
# A commit is 7 to 64 hex characters with a letter, outside a hyphenated
# word: years, "ISO-8601" and UUID groups are not commits.
REFERENCES = re.compile(r"(?<![\w/#])(?:[\w.-]+(?:/[\w.-]+)?)?#[0-9]+\b"
                        r"|(?<![\w-])(?=[0-9a-fA-F]{7,64}(?![\w-]))[0-9]*[a-fA-F][0-9a-fA-F]*")
# Standard Markdown forms that mrkdwn writes differently; a heading or bold
# span is also where a tracker link adds no bold of its own.
HEADING = re.compile(r"^ {0,3}#{1,6}[ \t]+(\S.*?)(?:[ \t]+#+)?[ \t]*$", re.MULTILINE)
BOLD = re.compile(r"\*\*(?=\S)(.+?)(?<=\S)\*\*")
BULLET = re.compile(r"^([ \t]*)[-*+][ \t]+", re.MULTILINE)
# A leading quote marker is mrkdwn's own; every other `&`, `<` and `>` is text.
CONTROL = re.compile(r"(^[ \t]*(?:>[ \t]*)+)|[&<>]", re.MULTILINE)
SLACK_TOKEN = re.compile(r"<(?:[@#!]|[a-zA-Z][a-zA-Z0-9+.-]*:)[^<>\n]*>")
INLINE_LINK = re.compile(r"\[(.*)\]\(([a-zA-Z][a-zA-Z0-9+.-]*:[^\s|<>]*)\)")


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
                notice("tracker-links-unavailable", f"{root} cause={err}", file=sys.stderr)
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


class Link(NamedTuple):
    """A linked reference. A tracker issue shows its id bracketed and bold;
    `bold` says the text around it is already bold."""

    label: str
    url: str
    issue: bool
    bold: bool


# A run of outbound text: plain, a link, or a block.
Part = Union[str, Link, Verbatim]


def outbound(root: Path, text: Union[str, Sequence[Union[str, Verbatim]]], file_comment: bool = False,
             fallback: bool = True) -> Tuple[str, str]:
    """Link bare tracker ids once and return the actual outbound representation.

    `text` is one string, or strings and `Verbatim` blocks in order; a
    string is linked, a block never is. A file comment's standard Markdown
    is converted to mrkdwn; messages retain standard Markdown, including
    after link expansion. A text matching the secret pattern returns as
    written, unlinked and unconverted, so the caller's check refuses the
    bytes that matched. `fallback` remains accepted for the explicit
    single-message post caller.
    """
    pieces = [text] if isinstance(text, str) else list(text)
    written = "".join(_render(piece, mrkdwn=False) for piece in pieces)
    # Linking or conversion can join a character to a match and hide it.
    preserve = secret_pattern().search(written.encode()) is not None
    if preserve:
        return written, "text" if file_comment else "markdown_text"
    tracker = TRACKERS.get(root)
    references = TRACKERS.references(root)
    parts: List[Part] = []
    for piece in pieces:
        if isinstance(piece, Verbatim):
            parts.append(piece)
        else:
            parts.extend(_linked(piece, tracker, references))
    markdown = "".join(_render(part, mrkdwn=False) for part in parts)
    mrkdwn = file_comment
    if not mrkdwn:
        return markdown, "markdown_text"
    return _mrkdwn(parts), "text"


def continuations(text: str) -> List[str]:
    """Partition final Markdown at its API cap, keeping literal regions whole
    and closing/reopening an oversized fence with the same info string.
    Numbering sits outside the content and counts toward the same cap."""
    if len(text) <= MARKDOWN_LIMIT:
        return [text]
    count = 2
    while True:
        capacity = MARKDOWN_LIMIT - len(f"Part {count}/{count}\n\n")
        chunks = _partition(text, capacity)
        if len(str(len(chunks))) == len(str(count)):
            return [f"Part {i}/{len(chunks)}\n\n{chunk}" for i, chunk in enumerate(chunks, 1)]
        count = len(chunks)


def _partition(text: str, capacity: int) -> List[str]:
    chunks: List[str] = []
    current = ""

    def ordinary(run: str) -> None:
        nonlocal current
        while run:
            room = capacity - len(current)
            if len(run) <= room:
                current += run
                return
            # Prefer paragraph, then line, then word boundaries without
            # discarding the separator or moving it inside a code fence.
            cut = run.rfind("\n\n", 0, room)
            if cut >= 0:
                cut += 2
            else:
                cut = run.rfind("\n", 0, room)
                if cut >= 0:
                    cut += 1
                else:
                    cut = run.rfind(" ", 0, room)
                    cut = cut + 1 if cut >= 0 else room
            if cut:
                current += run[:cut]
                run = run[cut:]
            chunks.append(current)
            current = ""

    pos = 0
    for match in LITERAL.finditer(text):
        # Keep a fitting line's marker and formatting with its links.
        line_start = text.rfind("\n", 0, match.start()) + 1
        line_end = text.find("\n", match.start())
        line_end = len(text) if line_end < 0 else line_end + 1
        if pos <= line_start and match.end() <= line_end and line_end - line_start <= capacity:
            ordinary(text[pos:line_start])
            pos = line_start
            if len(current) + line_end - line_start > capacity:
                chunks.append(current)
                current = ""
        ordinary(text[pos:match.start()])
        literal = match.group()
        if len(literal) > capacity:
            fence = match.group("fence")
            if fence is None:
                raise Refusal("text-too-long", f"literal chars={len(literal)} limit={MARKDOWN_LIMIT}")
            if current:
                chunks.append(current)
                current = ""
            opening, content = literal.split("\n", 1)
            closing = re.search(r"^ {0,3}" + re.escape(fence) + r"[`~]*[ \t]*(?:\n|$)\Z", content, re.MULTILINE)
            ending = content[closing.start():] if closing else fence
            content = content[:closing.start()] if closing else content
            room = capacity - len(opening) - 1 - len(ending) - 1
            if room <= 0:
                raise Refusal("text-too-long", f"fence chars={len(opening)} limit={MARKDOWN_LIMIT}")
            while len(content) > room:
                cut = content.rfind("\n", 0, room)
                cut = cut + 1 if cut >= 0 else room
                fragment, content = content[:cut], content[cut:]
                # The extra newline belongs to the wrapper, so fragments
                # keep even a split in the middle of a literal line exact.
                chunks.append(opening + "\n" + fragment + "\n" + ending)
            separator = "" if content.endswith("\n") else "\n"
            current = opening + "\n" + content + separator + ending
        else:
            if len(current) + len(literal) > capacity:
                # A word joined to the literal, such as a link's bold
                # marker, moves with it to the next part.
                cut = max(current.rfind(" "), current.rfind("\n")) + 1
                if cut == 0 or len(current) - cut + len(literal) > capacity:
                    cut = len(current)
                chunks.append(current[:cut])
                current = current[cut:]
            current += literal
        pos = match.end()
    ordinary(text[pos:])
    if current:
        chunks.append(current)
    return chunks


def _linked(text: str, tracker: Optional[Tracker], references: Tuple[re.Pattern, Callable[[str], Optional[str]]]) -> List[Part]:
    """`text` as plain runs and bare tracker ids with their URLs; literal
    regions are never linked."""
    parts: List[Part] = []
    pos = 0
    reference_pattern, reference_url = references
    masked = _masked(text)
    strong = [(m.start(), m.end()) for m in chain(BOLD.finditer(masked), HEADING.finditer(masked))]
    pattern = re.compile(reference_pattern.pattern + ("|" + tracker[0].pattern if tracker is not None else ""))
    for start, end in chain(((literal.start(), literal.end()) for literal in LITERAL.finditer(text)), [(len(text), len(text))]):
        for match in pattern.finditer(text, pos, start):
            identifier = match.group()
            issue = reference_pattern.fullmatch(identifier) is None
            target = tracker[1](identifier) if issue else reference_url(identifier)
            bold = any(s <= match.start() and match.end() <= e for s, e in strong)
            parts.append(text[pos:match.start()])
            parts.append(Link(identifier, target, issue, bold) if target is not None else identifier)
            pos = match.end()
        parts.append(text[pos:end])
        pos = end
    parts.append(text[pos:])
    return parts


def _held(match: re.Match) -> bool:
    """A literal region stays as written; an angle run that is not a Slack
    token is text, its `<` and `>` escaped in mrkdwn."""
    return match.group("zone_angle") is None or SLACK_TOKEN.fullmatch(match.group()) is not None


def _masked(text: str) -> str:
    """`text` with each literal region `_mrkdwn` holds aside as a run of
    neutral characters of the same length, so a bold or heading test sees
    the spans both routes format: a `**` inside code is not a bold marker.
    A fence keeps its newlines, so the lines around it stay lines."""

    def mask(match: re.Match) -> str:
        literal = match.group()
        if not _held(match):
            return literal
        if match.group("zone_fence") is not None:
            return re.sub(r"[^\n]", "x", literal)
        return "x" * len(literal)

    return LITERAL.sub(mask, text)


def _render(part: Part, mrkdwn: bool) -> str:
    if isinstance(part, str):
        return part
    if isinstance(part, Verbatim):
        return part.mrkdwn() if mrkdwn else part.markdown()
    label = f"[{part.label}]" if part.issue else part.label
    star = "*" if part.issue and not part.bold else ""
    if mrkdwn:
        return f"{star}<{part.url}|{label}>{star}"
    label = label.replace("[", r"\[").replace("]", r"\]")
    return f"{star * 2}[{label}]({part.url}){star * 2}"


def _mrkdwn(parts: List[Part]) -> str:
    """Standard Markdown as mrkdwn: headings and `**bold**` as `*bold*`,
    list markers as `•`, inline links as `<url|label>`, and `&`, `<`, `>`
    escaped. Code, Slack tokens, bare URLs and any form not read here stay
    as written; code is escaped, so it reads as typed.

    Links and blocks, then literal regions, stand in as one placeholder
    character the text lacks, so line rules see whole lines around them."""
    plain = "".join(part for part in parts if isinstance(part, str))
    free = (chr(code) for code in range(0xE000, 0xF900) if chr(code) not in plain)
    held, zoned = next(free), next(free)
    atoms = [_render(part, mrkdwn=True) for part in parts if not isinstance(part, str)]
    text = "".join(part if isinstance(part, str) else held for part in parts)
    zones: List[str] = []

    def zone(match: re.Match) -> str:
        literal = match.group()
        if not _held(match):
            return literal
        if match.group("zone_markdown") is not None:
            link = INLINE_LINK.fullmatch(literal)
            if link is not None:
                label = re.sub(r"\\([!-/:-@\[-`{-~])", r"\1", link.group(1))
                literal = f"<{link.group(2)}|{escape(label)}>"
        elif match.group("zone_fence") is not None or match.group("zone_code") is not None:
            literal = escape(literal)
        # A fence's closing newline stays text, so the next line starts a line.
        tail = "\n" if literal.endswith("\n") else ""
        zones.append(literal[: len(literal) - len(tail)])
        return zoned + tail

    text = LITERAL.sub(zone, text)
    text = CONTROL.sub(lambda m: m.group(1) or escape(m.group()), text)
    text = HEADING.sub(lambda m: "*" + BOLD.sub(r"\1", m.group(1)) + "*", text)
    text = BULLET.sub("\\1• ", text)
    text = BOLD.sub(r"*\1*", text)
    for mark, values in ((zoned, zones), (held, atoms)):
        assert text.count(mark) == len(values), "mrkdwn placeholder count changed"
        pieces = text.split(mark)
        text = pieces[0] + "".join(value + piece for value, piece in zip(values, pieces[1:]))
    return text


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
