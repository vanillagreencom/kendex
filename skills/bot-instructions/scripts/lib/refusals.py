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
_CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")
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


def _control(value):
    m = _CONTROL.search(value)
    if m:
        return f"carries the control character U+{ord(m.group()):04X}"
    return None


def _single_line(value):
    if "\n" in value or "\r" in value:
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
    "control": _control,
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

