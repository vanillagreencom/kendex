r"""The Markdown heading predicates: what a reader calls a heading.

An ATX heading is one to six `#`, indented at most three spaces, **followed by
a space, a tab, or the end of the line**. One predicate at all three sites —
`render.bounds`, `spec.parse_doctrine`, `refusals` — so a section terminator
and a refusal cannot disagree about where a section ends.

Wide about INDENTATION: markdown reads a heading after three or fewer leading
spaces, so a line indented two spaces ends the owned region as surely as one
in column zero. Exact about the DELIMITER: `\s` reads every Unicode space as
one and CommonMark reads none of them, so `##\u00a0x` is a paragraph to every
bot, and `#1917` is how this repo writes a pull request number. kendex's
`tools/guard` slices the same section with `^##? `, so anything wider here is a
boundary the two of them disagree on.

**Setext takes two lines**, so it is a second function rather than a wider
`heading_level`, and `setext_level` answers about the UNDERLINE alone: the two
readings need opposite widths. A REFUSAL is fail-closed when it is wide, so
`refusals` asks both predicates and treats any underline under a non-blank
line as a heading. A SECTION TERMINATOR is fail-closed when it is exact, and
whether a `---` is a setext underline or a line inside a fenced block cannot
be told from the line and the one above it, so `render.bounds` and
`spec.parse_doctrine` stay ATX — what keeps that safe is the refusal, which
keeps a setext underline out of every string they parse.
"""

import re

_ATX = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]|$)")
# A run of one character, `=` or `-`, indented at most three spaces, with only
# whitespace after it. CommonMark puts no limit on the run's length.
_SETEXT = re.compile(r"^ {0,3}(=+|-+)[ \t]*$")


def heading_level(line):
    """The ATX heading level of `line`, or 0 when it is not a heading."""
    m = _ATX.match(line)
    return len(m.group(1)) if m else 0


def setext_level(line):
    """The level an underline gives the line above it, or 0.

    `=` is level 1 and `-` is level 2. Says nothing about the line above:
    whether there is a paragraph there is the caller's question, and only the
    caller knows which way it needs to be wrong.
    """
    m = _SETEXT.match(line)
    if not m:
        return 0
    return 1 if m.group(1)[0] == "=" else 2
