"""The glob dialect: one pattern five engines read alike.

`schemas/repo-toml.md` § The glob dialect is the contract. The class is stated
as the permitted characters rather than as a list of banned sequences, because
a ban list closes the shapes someone thought of and a character class closes
the rest.

The matcher below is this package's own, used only by the dead-exclusion
clause and by the vector harness. It is deliberately the strict reading:
`**` crosses `/`, `*` and `?` do not.
"""

import re

# The dialect's class. `**` is the two-character form of `*`, so the class
# holds `*` once.
ALLOWED = frozenset(
    "abcdefghijklmnopqrstuvwxyz"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "0123456789"
    "._-/"
    "*?[]"
)

# Named for the error message alone. The dialect refuses everything outside
# ALLOWED; these are the shapes an author is most likely to reach for, and
# saying which one they used beats saying a byte was not permitted.
NAMED_REJECTS = (
    ("{", "a brace — CodeRabbit joins multi-globs with braces and sparse-checkout does not read them"),
    ("}", "a brace — CodeRabbit joins multi-globs with braces and sparse-checkout does not read them"),
    ("!", "a negation — path_filters is exclusion-only and the generator writes the `!` itself"),
    (",", "a comma — Copilot's applyTo splits on it"),
    ("\\", "a backslash — the engines disagree about what it escapes"),
    ('"', "a double quote"),
    ("(", "an extglob"),
    ("#", "a comment character — it would comment out the entry in .coderabbit.yaml"),
    ("\n", "a newline — every line of .macroscope/ignore.md is a pattern"),
    ("\t", "a tab"),
)


def check(glob, where):
    """Refuse a glob outside the dialect. Returns None; raises the message.

    Each refusal below is its own clause with its own control, per
    `validators.md` § Controls. The class catches none of the path-shape
    clauses: `.` and `/` are permitted characters, so `../**` and `/src/**`
    are made of nothing but allowed bytes, and the class constrains which
    characters may appear rather than requiring one to.
    """
    from .errors import InputError

    if not isinstance(glob, str):
        raise InputError(f"{where}: glob must be a string, got {type(glob).__name__}")
    if glob == "":
        raise InputError(f"{where}: empty glob — its effect differs on every engine")
    for ch, why in NAMED_REJECTS:
        if ch in glob:
            raise InputError(f"{where}: glob {glob!r} carries {why}")
    bad = [c for c in glob if c not in ALLOWED]
    if bad:
        raise InputError(
            f"{where}: glob {glob!r} carries {bad[0]!r}, outside the dialect's "
            "character class A-Z a-z 0-9 . _ - / * ? [ ]"
        )
    if glob.startswith("/"):
        raise InputError(f"{where}: glob {glob!r} has a leading `/`, which the engines anchor differently")
    if glob.endswith("/"):
        raise InputError(f"{where}: glob {glob!r} has a trailing `/`")
    parts = glob.split("/")
    if any(p == ".." for p in parts):
        raise InputError(
            f"{where}: glob {glob!r} has a `..` component — path_filters reaches "
            "`git sparse-checkout`, where that is a path escape"
        )
    if any(p == "" for p in parts):
        raise InputError(f"{where}: glob {glob!r} has an empty component")


def check_list(globs, where):
    """An empty glob list is an error wherever a glob list is required."""
    from .errors import InputError

    if not isinstance(globs, list):
        raise InputError(f"{where}: expected an array of strings")
    if not globs:
        raise InputError(f"{where}: empty glob list")
    for i, g in enumerate(globs):
        check(g, f"{where}[{i}]")


def _translate(pattern):
    """Dialect glob to regex. `**` crosses `/`; `*` and `?` do not.

    `a/**` matches `a` itself, which is how every engine here reads "this
    directory and below" — the dead-exclusion clause would otherwise call a
    tree exclusion dead in a repo tracking only the directory's own files.
    """
    out = ["^"]
    i, n = 0, len(pattern)
    while i < n:
        c = pattern[i]
        if pattern.startswith("**", i):
            trailing_slash = pattern.startswith("**/", i)
            if trailing_slash:
                out.append("(?:[^/]*/)*")
                i += 3
            elif out and out[-1] == "/":
                out.pop()
                out.append("(?:/.*)?")
                i += 2
            else:
                out.append(".*")
                i += 2
            continue
        if c == "*":
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        elif c == "[":
            j = pattern.find("]", i + 1)
            if j != -1:
                out.append("[" + pattern[i + 1 : j].replace("\\", "\\\\") + "]")
                i = j + 1
                continue
            out.append(re.escape(c))
        else:
            out.append(re.escape(c))
        i += 1
    out.append("$")
    return re.compile("".join(out))


def matches(pattern, path):
    """Does `path` fall under `pattern` in this dialect's reading?"""
    return _translate(pattern).match(path) is not None


def matching(pattern, paths):
    """Every path in `paths` the pattern covers."""
    rx = _translate(pattern)
    return [p for p in paths if rx.match(p)]
