"""The one Markdown heading predicate.

An ATX heading is one to six `#`, indented at most three spaces, **followed by
whitespace or the end of the line**. The whitespace is not optional, and three
copies of this test without it failed in three different ways:

- `render.bounds` put the `AGENTS.md` owned region's end at a `##note` line, so
  repo-authored text escaped the managed region while `tools/guard`'s own
  `^##? ` still read it as inside the section and every bot still received it.
- `spec.parse_doctrine` ended the `## Doctrine` section at a `#1917` line and
  silently dropped the rest of a doctrine block, shipping a mid-clause rule to
  all eight surfaces with the run reporting success.
- `refusals` refused any line opening with `#`, which is the fail-closed
  direction but refuses text that is a heading to no reader — `#1917` is how
  this repo writes a pull request number.

One predicate at all three sites, so those cannot disagree again. It stays
deliberately wide about INDENTATION: markdown reads a heading after three or
fewer leading spaces, so a line indented two spaces ends the owned region as
surely as one in column zero.

**The delimiter is a space or a tab, and nothing else.** `\s` reads every
Unicode space as one, and CommonMark reads none of them: `##\u00a0x` is a
paragraph to every bot, while a `\s` predicate ended the owned region there.
Put after the generated body, that left the region `drift` compares equal to a
fresh render while the unmanaged text below stayed inside the section every
bot reads — the `##note` failure this predicate was written to close, reopened
one character class wider. kendex's `tools/guard` slices the same section with
`^##? `, so anything wider here is a boundary the two of them disagree on.
"""

import re

_ATX = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]|$)")


def heading_level(line):
    """The ATX heading level of `line`, or 0 when it is not a heading."""
    m = _ATX.match(line)
    return len(m.group(1)) if m else 0
