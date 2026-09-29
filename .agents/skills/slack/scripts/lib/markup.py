"""Slack's message markup read back as the text the owner typed.

Slack escapes `&`, `<` and `>` in a message's text as `&amp;`, `&lt;` and
`&gt;`, and writes a link, a mention and a broadcast as a `<...>` token:
`<URL>`, `<URL|label>`, `<@U123>`, `<#C123|name>`, `<!here>`. Emoji stay
`:name:`. Each piece is unescaped once, so an owner who typed `&lt;` reads
`&lt;` and never `<`.
"""

from __future__ import annotations

import re
from typing import Callable

TOKEN = re.compile(r"<([^<>]*)>")


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
