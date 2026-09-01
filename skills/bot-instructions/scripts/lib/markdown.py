r"""The Markdown heading predicates: what a reader calls a heading.

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

**Setext is the second way to write a heading, and it takes two lines**, so it
is a second function rather than a wider `heading_level`. `Injected` over a
line of `===` is an H1 to every CommonMark reader, and an ATX-only refusal let
repo text carry one into every output that carries repo prose.

`setext_level` answers about the UNDERLINE alone and the caller supplies the
line above, which is what keeps the two readings of this module apart:

- A REFUSAL is fail-closed when it is wide. `refusals` asks both predicates,
  treating any underline under a non-blank line as a heading. A false positive
  there costs an author a rewrite of a string; a false negative puts a
  structural heading into a generated file.
- A SECTION TERMINATOR is fail-closed when it is exact, and ends early when it
  is wide — which is the `##note` failure itself. Whether a `---` is a setext
  underline or a line inside a fenced code block cannot be told from the line
  and the one above it: `renders.md`'s own frontmatter example is `---` under a
  fence opener. So `render.bounds` and `spec.parse_doctrine` stay ATX, and
  what keeps that honest is the refusal above — no doctrine block and no repo
  string can carry a setext underline in the first place.
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
