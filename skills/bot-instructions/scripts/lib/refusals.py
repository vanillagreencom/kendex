"""The content refusals, as one table.

`schemas/repo-toml.md` § The content refusals is the spec's statement of this.
ROWS below encodes every row of that table whose refusals are content classes,
and is the only predicate their callers run. `toml-schema` applies the rows
whose source is `bot-instructions.toml`; the render-side second check applies
the `doctrine block text` row, because doctrine text does not come through
that file at all.

**Two of the table's ten rows are enforced elsewhere, and this is not their
copy.** The glob row — `[[surface]] globs`, `exclude_globs`,
`[[exclusions.path]] glob` — is `globs.check`, whose character class and
path-shape clauses are its own; the `[cadence] qodo_commands` row is
`config._cadence` reading `constants.QODO_VERBS`. Both are cited from the
table rather than restated here, and a reader counting clauses off it lands on
three structures, not one. `tests/toml-schema.test.sh` holds the table against
these three, so a row added to either side without the other reds.

Refusals, not escapes: every class here is refused at input. The render
escapes only what a format requires of text already known to be legal.
"""

import re

from .constants import MARKER_TOKEN
from .errors import InputError

# markdown reads `#` as a heading after three or fewer leading spaces, so the
# wide form is the one the outputs need: a line indented two spaces before `#`
# ends the `AGENTS.md` owned region just as surely as one in column zero.
_HEADING = re.compile(r"^ {0,3}#")
# C0 less tab and newline, DEL, and the three characters ABOVE the C0 range
# that a reader still breaks a line on: NEL, LINE SEPARATOR and PARAGRAPH
# SEPARATOR. YAML 1.1 lists all three as line breaks, and PyYAML, libyaml,
# go-yaml and Psych all act on them, so a `.coderabbit.yaml` carrying one is
# read as more lines than this package wrote — a rendered comment becomes a
# `path_filters:` key, an entry loses its `!`, and the exclusion list becomes
# an allowlist. Python's own `str.splitlines` breaks on the same three, which
# is why `heading` and `frontmatter` already see them and a two-character
# `\n`/`\r` test does not.
_CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f\u0085\u2028\u2029]")
_BREAK_NAMES = {
    "\x85": "NEL",
    "\u2028": "LINE SEPARATOR",
    "\u2029": "PARAGRAPH SEPARATOR",
}
_NAME_CLASS = re.compile(r"^[A-Za-z0-9._-]+$")


def _heading(value):
    for line in value.splitlines():
        if _HEADING.match(line):
            return f"line {line.strip()!r} is a markdown heading"
    return None


def _frontmatter(value):
    for line in value.splitlines():
        if line == "---":
            return "a line is exactly `---`, which opens YAML frontmatter"
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
    """The `control` predicate. Public, because the emitter and the reader run it.

    A narrower copy of this test downstream is how a character the table
    refuses reaches a rendered file anyway: the rows here cover the values
    that arrive through `bot-instructions.toml`, and `yamlemit` also emits
    doctrine text and schema defaults, which do not.
    """
    m = _CONTROL.search(value)
    if m is None:
        return None
    ch = m.group()
    if ch in _BREAK_NAMES:
        return (f"carries U+{ord(ch):04X} {_BREAK_NAMES[ch]}, which a YAML reader "
                "breaks a line on and this one does not")
    return f"carries the control character U+{ord(ch):04X}"


def _single_line(value):
    # The appended `.` is the load-bearing part, and it has its own control:
    # `splitlines` DROPS a trailing break, so without it `"a\n"` and `"a"`
    # both read as one line and a `reason` ending in a newline passes.
    #
    # `splitlines` over a `\n`/`\r` test is defence in depth rather than a
    # clause of its own. Every row marked `single-line` pairs it with a
    # predicate that already refuses the rest of the break set — `control` on
    # `[[exclusions.path]] reason`, `name-class` on `[repo] name` and
    # `[repo] tracker` — so no input distinguishes the two forms, and a
    # control for that width would need a row this table does not have.
    if len(f"{value}.".splitlines()) > 1:
        return "must be a single line"
    return None


def _name_class(value):
    if not _NAME_CLASS.match(value):
        return "must be non-empty and hold only [A-Za-z0-9._-]"
    return None


def _ascii(value):
    try:
        value.encode("ascii")
    except UnicodeEncodeError as exc:
        return f"must be ASCII; byte {exc.object[exc.start]!r} is not"
    return None


# One row per input string, one predicate list per row, mirroring the columns
# of `repo-toml.md` § The content refusals. `enforcer` names which side reads
# the value, and it is why the doctrine row is not a `toml-schema` clause: the
# value is in the spec copy, not in `bot-instructions.toml`.
ROWS = {
    "[repo] name": (["single-line", "name-class"], "toml-schema"),
    "[repo] tracker": (["single-line", "name-class"], "toml-schema"),
    "[repo] summary": (
        ["heading", "frontmatter", "marker", "toml-delimiter", "control"],
        "toml-schema",
    ),
    "[[surface]] instructions": (
        ["heading", "frontmatter", "marker", "control"],
        "toml-schema",
    ),
    "[doctrine.*] values": (
        ["heading", "frontmatter", "marker", "toml-delimiter", "control"],
        "toml-schema",
    ),
    "doctrine block text": (
        ["heading", "frontmatter", "marker", "toml-delimiter", "control"],
        "render-side",
    ),
    "[[exclusions.path]] reason": (
        ["marker", "comment-close", "control", "single-line"],
        "toml-schema",
    ),
    "[tone] coderabbit": (["control", "ascii"], "toml-schema"),
}

_PREDICATES = {
    "heading": _heading,
    "frontmatter": _frontmatter,
    "marker": _marker,
    "comment-close": _comment_close,
    "toml-delimiter": _toml_delimiter,
    "control": control,
    "single-line": _single_line,
    "name-class": _name_class,
    "ascii": _ascii,
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

