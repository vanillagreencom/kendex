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
    are made of nothing but allowed bytes.
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
    # Last, so every clause above owns its own message. The dialect's class
    # permits `[` and `]` and says nothing about what goes between them, and a
    # `[...]` here reaches a regex character class, so proving it compiles at
    # input makes a reversed range a `toml-schema` finding naming its key
    # rather than a traceback out of the dead-exclusion clause much later.
    _translate(glob, where)


def check_list(globs, where):
    """An empty glob list is an error wherever a glob list is required."""
    from .errors import InputError

    if not isinstance(globs, list):
        raise InputError(f"{where}: expected an array of strings")
    if not globs:
        raise InputError(f"{where}: empty glob list")
    for i, g in enumerate(globs):
        check(g, f"{where}[{i}]")


def _collapse(pattern):
    """Consecutive `**/` runs to one, which no match result depends on.

    `**/` translates to `(?:[^/]*/)*`, and nesting those is exponential, which
    `_dead_globs` pays over every tracked path in the repo. `**/**/` covers
    exactly what `**/` covers, so this rewrites the pattern and not its
    meaning.
    """
    while "**/**/" in pattern:
        pattern = pattern.replace("**/**/", "**/")
    return pattern


def _translate(pattern, where=None):
    """Dialect glob to regex. `**` crosses `/`; `*` and `?` do not.

    A trailing `/**` keeps its slash, so `a/**` matches every path under `a`
    and never a tracked file named `a` — which is what `git ls-files --
    ':(glob)a/**'` answers. `tests/globs.test.sh` measures the pair against
    git's wildmatch, which `renders.md` names as the engine the dialect
    targets.

    **A pattern holding no wildcard covers the paths beneath it**, which is
    git's own rule for a pathspec, and the boundary is git's too: `*`, `?` and
    `[` are what `has_wildcard` looks for, and one of them anywhere turns the
    prefix rule off.

    The compile is guarded because the dialect's character class is wider than
    a regex character class: `[z-a]` is made of permitted bytes and is a
    reversed range `re` refuses. The refusal quotes the glob AS WRITTEN rather
    than the collapsed pattern `re` saw. `where` is the key it came from;
    `matching()` has none, and its unprefixed form is a backstop.
    """
    from .errors import InputError

    as_written = pattern
    pattern = _collapse(pattern)
    # git's own test for whether a pathspec is a literal path, and so a
    # directory prefix rather than a name to match exactly.
    literal = not any(c in pattern for c in "*?[")
    out = ["^"]
    i, n = 0, len(pattern)
    while i < n:
        c = pattern[i]
        if pattern.startswith("**", i):
            if pattern.startswith("**/", i):
                out.append("(?:[^/]*/)*")
                i += 3
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
    out.append("(?:/.*)?$" if literal else "$")
    try:
        return re.compile("".join(out))
    except re.error as exc:
        head = f"{where}: " if where is not None else ""
        raise InputError(
            f"{head}glob {as_written!r} is in the dialect's character class but is not "
            f"a pattern this package can match ({exc}). A `[...]` class here reaches a "
            "regex character class, where a reversed range is an error"
        ) from exc


def matching(pattern, paths):
    """Every path in `paths` the pattern covers."""
    rx = _translate(pattern)
    return [p for p in paths if rx.match(p)]
