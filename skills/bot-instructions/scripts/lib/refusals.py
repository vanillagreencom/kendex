"""The content refusals, as one table.

`schemas/repo-toml.md` § The content refusals is the spec's statement of this.
Every row here refuses text that would break the STRUCTURE of a file this
package emits; a value this package merely dislikes is not refused.
`toml-schema` applies the rows whose source is `bot-instructions.toml`; the
render-side second check applies the `doctrine block text` row, because
doctrine text does not come through that file at all.

**Two of the table's rows are enforced elsewhere, and this is not their copy.**
The glob row is `globs.check`; the `[cadence] qodo_commands` row is
`config._cadence` reading `constants.QODO_VERBS`. `tests/toml-schema.test.sh`
holds the table against these three, so a row added to either side without the
other reds.

Refusals, not escapes: every class here is refused at input. The render
escapes only what a format requires of text already known to be legal.
"""

import re

from .constants import MARKER_TOKEN
from .errors import InputError
from . import markdown

# C0 less tab and newline, DEL, and the three characters ABOVE the C0 range
# that a reader still breaks a line on: NEL, LINE SEPARATOR and PARAGRAPH
# SEPARATOR. YAML 1.1 lists all three as line breaks, and PyYAML, libyaml,
# go-yaml and Psych all act on them, so a `.coderabbit.yaml` carrying one is
# read as more lines than this package wrote — a rendered comment becomes a
# `path_filters:` key, an entry loses its `!`, and the exclusion list becomes
# an allowlist.
_CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f\u0085\u2028\u2029]")
_BREAK_NAMES = {
    "\x85": "NEL",
    "\u2028": "LINE SEPARATOR",
    "\u2029": "PARAGRAPH SEPARATOR",
}


def _heading(value):
    """ATX and setext alike: no repo or doctrine string carries a heading.

    `render.bounds` ends the `AGENTS.md` owned region at the next level-1 or
    level-2 heading, so repo text carrying one puts everything below it
    outside the region every render rewrites while the bots still read it.
    Wide on purpose: any underline under a non-blank line is refused, and
    `markdown.py` says why the section terminators cannot read it that way.
    """
    previous = ""
    for line in value.splitlines():
        if markdown.heading_level(line):
            return f"line {line.strip()!r} is a markdown heading"
        if previous.strip() and markdown.setext_level(line):
            return (f"line {line.strip()!r} underlines {previous.strip()!r}, "
                    "which is a markdown heading")
        previous = line
    return None


def _marker(value):
    if MARKER_TOKEN in value:
        return f"carries the marker text {MARKER_TOKEN!r}, which decides file ownership"
    return None


def _comment_close(value):
    if "-->" in value:
        return "carries `-->`, which would close the HTML comment it renders inside"
    return None


def _toml_delimiter(value):
    if '"""' in value:
        return 'carries `"""`, which would close the TOML multi-line string it renders inside'
    return None


def control(value):
    """The `control` predicate. Public, because `coderabbit-schema` runs it
    over the document it validates: a default in the vendored schema does not
    arrive through `bot-instructions.toml` and so meets no row here."""
    m = _CONTROL.search(value)
    if m is None:
        return None
    ch = m.group()
    if ch in _BREAK_NAMES:
        return (f"carries U+{ord(ch):04X} {_BREAK_NAMES[ch]}, which a YAML reader "
                "breaks a line on and this one does not")
    return f"carries the control character U+{ord(ch):04X}"


def _single_line(value):
    # A `[[exclusions.path]] reason` runs one line inside a YAML comment and
    # one line in `.macroscope/ignore.md`; a break puts its tail into the
    # first as structure beside `path_filters` and into the second as a
    # pattern. `control` does not cover `\n`.
    #
    # The appended `.` is the load-bearing part: `splitlines` DROPS a trailing
    # break, so without it `"a\n"` and `"a"` both read as one line.
    if len(f"{value}.".splitlines()) > 1:
        return "must be a single line"
    return None


# One row per input string, one predicate list per row, mirroring the columns
# of `repo-toml.md` § The content refusals. The second element names which
# side reads the value, and it is why the doctrine row is not a `toml-schema`
# clause: that value is in the spec copy, not in `bot-instructions.toml`.
_STRUCTURAL = ["single-line", "marker", "toml-delimiter", "control"]

ROWS = {
    "[repo] name": (_STRUCTURAL, "toml-schema"),
    "[repo] tracker": (_STRUCTURAL, "toml-schema"),
    "[repo] summary": (["heading", "marker", "toml-delimiter", "control"], "toml-schema"),
    "[[surface]] instructions": (["heading", "marker", "control"], "toml-schema"),
    "[doctrine.*] values": (["heading", "marker", "toml-delimiter", "control"], "toml-schema"),
    "doctrine block text": (["heading", "marker", "toml-delimiter", "control"], "render-side"),
    "[[exclusions.path]] reason": (
        ["marker", "comment-close", "control", "single-line"],
        "toml-schema",
    ),
    "[tone] coderabbit": (["control"], "toml-schema"),
}

_PREDICATES = {
    "heading": _heading,
    "marker": _marker,
    "comment-close": _comment_close,
    "toml-delimiter": _toml_delimiter,
    "control": control,
    "single-line": _single_line,
}


def apply(row, value, where):
    """Run one row's refusals over `value`. Raises InputError on the first."""
    if row not in ROWS:
        raise KeyError(f"no refusal row named {row!r}")
    if not isinstance(value, str):
        raise InputError(f"{where}: expected a string, got {type(value).__name__}")
    for name in ROWS[row][0]:
        why = _PREDICATES[name](value)
        if why is not None:
            raise InputError(f"{where}: {why} ({name} refusal, {row})")
