"""The tables of `schemas/repo-toml.md` this package reads as data.

The content refusals and the Qodo verb set are each stated once, in a table
there, and arrive here as rows, so a row added to the table is the whole
change (`validators.md` § Cross-file sets).

Read from the running copy, never from `--spec`: both tables decide what this
code accepts. `kendex verify` runs a trusted copy of this package from outside
the project with `--spec` naming the copy installed inside it, so a spec-copy
read would let the tree under judgment loosen the checker that judges it.
"""

import functools
import os
import re

from .errors import SpecError

PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "schemas",
    "repo-toml.md",
)


@functools.cache
def _lines():
    try:
        with open(PATH, encoding="utf-8") as fh:
            return fh.read().splitlines()
    except (OSError, UnicodeError) as exc:
        raise refused(f"the running copy's schema could not be read: {exc}") from exc


def _cells(line):
    """The cells of a `|` line, whatever its indent, else None."""
    if not line.lstrip(" \t").startswith("|"):
        return None
    return [c.strip() for c in line.strip().strip("|").split("|")]


def _row(n, line, first):
    """The cells of line `n` of the `first` table, else None.

    The one test for its header, its separator and its body lines. A `|` line
    is a row only in column zero: an indented one is refused rather than read
    or skipped, since reading it would rest on an indent rule GFM's table
    section does not state.
    """
    cells = _cells(line)
    if cells is not None and not line.startswith("|"):
        raise refused(f"line {n + 1} of the {first!r} table is indented: {line!r}")
    return cells


def table(first):
    """The one table whose header row opens with the cell `first`.

    Returns the header cells and the body rows' cells. The table runs to the
    first blank line, where GFM breaks a table (GFM spec § Tables), and every
    line before it is read as a row or refused. Zero or two such tables, a
    missing separator row, a line that is no row, a row with a different cell
    count, or no body row is refused rather than read as a shorter set.
    """
    lines = _lines()
    starts = [i for i, ln in enumerate(lines) if (_cells(ln) or [""])[0] == first]
    if len(starts) != 1:
        raise refused(f"found {len(starts)} tables headed {first!r}; exactly one is required")
    head = starts[0]
    header = _row(head, lines[head], first)
    separator = _row(head + 1, lines[head + 1], first) if head + 1 < len(lines) else None
    if not separator or not all(re.fullmatch(r":?-+:?", c) for c in separator):
        raise refused(f"the {first!r} table has no separator row under its header")
    rows = []
    for n in range(head + 2, len(lines)):
        line = lines[n]
        if not line.strip():
            break
        cells = _row(n, line, first)
        if cells is None:
            raise refused(f"line {n + 1} of the {first!r} table is no row: {line!r}")
        if len(cells) != len(header):
            raise refused(
                f"the {first!r} table row {cells[0]!r} has {len(cells)} cells; its header has "
                f"{len(header)}"
            )
        rows.append(cells)
    if not rows:
        raise refused(f"the {first!r} table has no rows")
    return header, rows


def refused(message):
    """A refusal naming this file, for this module and for a reader that
    judges a row's cells."""
    error = SpecError(f"{PATH}: {message}")
    error.subject = PATH
    return error
