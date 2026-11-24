"""`[bot-instructions]`: the schema, and the `toml-schema` validator.

The schema is closed. An unknown key, an unknown table, a value of the wrong
type, or an absent required key is an error naming the key — a typo like
`[bot-instructions.bot]`, `derive_renders` or `review_only` would otherwise be ignored while
defaults produced plausible output.

KEYS below is the schema. The required-key clause derives from its `required`
column rather than restating which fields are required, because a restated
list falls behind the column. A string key's content refusals are the row of
`repo-toml.md` § The content refusals that names it, found by that name, so
the schema carries no copy of which key is under which refusal.
"""

import functools

from .constants import (
    CODE_REVIEW_TREE,
    DEFAULT_CODE_REVIEW_PATH,
    DEFAULT_COPILOT_CHARS,
    DEFAULT_QODO_LINES,
    MARKER_PATH_CLASS,
    RESERVED_SURFACE_NAMES,
)
from .errors import InputError
from . import globs, refusals, repo_toml, spec

# table -> key -> (type, required, default)
KEYS = {
    "repo": {
        "name": (str, True, None),
        "summary": (str, True, None),
        "tracker": (str, False, None),
        "code_review_path": (str, False, DEFAULT_CODE_REVIEW_PATH),
    },
    "bots": {
        k: (bool, False, False)
        for k in (
            "codex", "copilot", "coderabbit", "qodo",
            "qodo_best_practices", "qodo_review_md", "macroscope",
        )
    },
    "cadence": {
        "coderabbit_incremental": (bool, False, True),
        "coderabbit_drafts": (bool, False, False),
        "qodo_commands": (list, False, ["/agentic_review"]),
        "qodo_push_trigger": (bool, False, False),
    },
    "tone": {"coderabbit": (str, False, None)},
    # What a bot keeps between pull requests. `false` renders CodeRabbit's
    # `knowledge_base.opt_out = true`: no stored learnings, issue or pull
    # request context. Code guidelines and web search are stateless and stay
    # on, so the `AGENTS.md` route survives an opt-out.
    "retention": {"coderabbit": (bool, False, True)},
    "budgets": {
        "copilot_chars": (int, False, DEFAULT_COPILOT_CHARS),
        "qodo_best_practices_lines": (int, False, DEFAULT_QODO_LINES),
    },
    "exclusions": {"derive_render": (bool, False, False), "path": (list, False, [])},
}

SURFACE_KEYS = {
    "name": (str, True, None),
    "globs": (list, True, None),
    "exclude_globs": (list, False, None),
    "reviewer_only": (bool, False, False),
    "instructions": (str, True, None),
}

EXCLUSION_KEYS = {
    "glob": (str, True, None),
    "reason": (str, True, None),
}

SURFACE = "[[bot-instructions.surface]]"
EXCLUSION = "[[bot-instructions.exclusions.path]]"
# Both override tables' values, under one row.
DOCTRINE_VALUES = "[bot-instructions.doctrine.*] values"


def _strings(prefix, schema):
    return {f"{prefix} {key}" for key, (want, _, _) in schema.items() if want is str}


# Every name a content-refusal row can carry: each string input `_table`
# reads, by the name it looks its row up under, plus the override values.
INPUTS = frozenset(
    set().union(*(_strings(f"[bot-instructions.{name}]", schema) for name, schema in KEYS.items()))
    | _strings(SURFACE, SURFACE_KEYS)
    | _strings(EXCLUSION, EXCLUSION_KEYS)
    | {DOCTRINE_VALUES}
)

TOP_LEVEL = frozenset({"schema", "surface", "doctrine"}) | frozenset(KEYS)


class Config:
    def __init__(self, data, where):
        self.where = where
        self.raw = data
        self.repo = data["repo"]
        self.bots = data["bots"]
        self.cadence = data["cadence"]
        self.tone = data["tone"]
        self.retention = data["retention"]
        self.budgets = data["budgets"]
        self.exclusions = data["exclusions"]
        self.surfaces = data["surface"]
        self.doctrine_append = data["doctrine"]["append"]
        self.doctrine_replace = data["doctrine"]["replace"]


def _typed(value, want, where):
    if want is bool:
        if not isinstance(value, bool):
            raise InputError(f"{where}: expected a boolean, got {type(value).__name__}")
    elif want is int:
        if isinstance(value, bool) or not isinstance(value, int):
            raise InputError(f"{where}: expected an integer, got {type(value).__name__}")
    elif not isinstance(value, want):
        raise InputError(f"{where}: expected {want.__name__}, got {type(value).__name__}")
    return value


def _table(raw, name, schema, where, prefix):
    """Read one closed table: unknown keys, wrong types, absent required keys,
    and each value's content refusals, the row named `prefix key`."""
    given = raw.get(name, {})
    if not isinstance(given, dict):
        raise InputError(f"{where}: expected a table")
    out = {}
    for key in given:
        if key not in schema:
            raise InputError(f"{where}: unknown key {key!r}")
    rows = refusals.rows()
    for key, (want, required, default) in schema.items():
        if key in given:
            value = _typed(given[key], want, f"{where} {key}")
            if f"{prefix} {key}" in rows:
                refusals.apply(f"{prefix} {key}", value, f"{where} {key}")
            out[key] = value
        elif required:
            raise InputError(f"{where}: required key {key!r} is absent")
        else:
            out[key] = default
    return out


def parse(raw, where):
    if not isinstance(raw, dict):
        raise InputError(f"{where}: expected a table")
    for key in raw:
        if key not in TOP_LEVEL:
            raise InputError(f"{where}: unknown table or key {key!r}")
    if "schema" not in raw:
        raise InputError(f"{where}: required key 'schema' is absent")
    if _typed(raw["schema"], int, f"{where} schema") != 1:
        raise InputError(
            f"{where}: schema = {raw['schema']!r}; this generator knows 1 and refuses a "
            "value it does not know rather than rendering a partly understood file"
        )
    _refusal_inputs()
    data = {
        name: _table(raw, name, schema, f"{where} [bot-instructions.{name}]", f"[bot-instructions.{name}]")
        for name, schema in KEYS.items()
    }
    data["exclusions"]["path"] = _exclusions(raw.get("exclusions", {}), where)
    data["surface"] = surfaces(raw.get("surface", []), f"{where} [[bot-instructions.surface]]")
    data["doctrine"] = _doctrine(raw.get("doctrine", {}), where)
    _cadence(data["cadence"], where)
    _budgets(data["budgets"], where)
    _code_review_path(data["repo"]["code_review_path"], where)
    _cross_flags(data, where)
    return Config(data, where)


def _code_review_path(path, where):
    """The pointed file's path: a markdown file directly under CODE_REVIEW_TREE.

    Shape only. Whether it collides with another output is decided where the
    whole output set exists, in `render.build`, against that set rather than
    against a second list of the paths this package writes.

    The class is `spec.in_path_class`, the one this package writes every path
    in; refused rather than escaped, like every other path it writes down.

    **The tree clause is what keeps a retired path findable.** `orphan` walks
    CODE_REVIEW_TREE, so a file left at a path an earlier value named is
    scanned, removed by `render` and reported by `check`. A freely placed path would be a marked file carrying
    the whole doctrine that nothing looks at once the key moves or `codex`
    goes false, and `render` would report clean while the old file stayed
    active. The same clause keeps every written path inside the tree this
    package's `repo-effects.writes` discloses.
    """
    w = f"{where} [bot-instructions.repo] code_review_path"
    if not spec.in_path_class(path):
        raise InputError(
            f"{w}: {path!r} must be non-empty and hold only [{MARKER_PATH_CLASS}]. "
            "This package refuses a path it would otherwise have to escape into a "
            "comment, a YAML sequence and three surfaces' prose"
        )
    if not path.endswith(".md"):
        raise InputError(f"{w}: {path!r} does not end in `.md`, and this render is markdown")
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise InputError(
            f"{w}: {path!r} is not a repo-relative path — an empty, `.` or `..` "
            "component, a leading slash among them, reaches outside the repository"
        )
    if parts[:-1] != CODE_REVIEW_TREE.split("/"):
        raise InputError(
            f"{w}: {path!r} is not directly under {CODE_REVIEW_TREE}/. That tree is "
            "the one `orphan` walks, so a file left at a path this key used to name "
            "is removed rather than left active; it is also the tree this package "
            "declares it writes"
        )
    if parts[-1].lower() == "agents.md":
        raise InputError(
            f"{w}: {path!r} is an AGENTS.md. Every harness loads one at the start of "
            "every session for the directory it sits in, which is the cost this file "
            "exists to move out of the root one. Case-insensitively, because a "
            "case-insensitive filesystem loads `agents.md` as that file"
        )
    if parts[-1] != parts[-1].lower():
        raise InputError(
            f"{w}: {path!r} has an upper-case basename. `[[bot-instructions.surface]] "
            "name` is lower-case by its own refusal, so every surface renders a "
            "lower-case basename into this same directory; an upper-case one here "
            "case-folds onto one of them. `render`'s collision clause compares path "
            "strings, and a case-insensitive filesystem would then keep whichever "
            "file was written last while the run reported writing both"
        )


def _exclusions(table, where):
    entries = table.get("path", [])
    if not isinstance(entries, list):
        raise InputError(f"{where} [[bot-instructions.exclusions.path]]: expected an array of tables")
    out = []
    for i, entry in enumerate(entries):
        w = f"{where} [[bot-instructions.exclusions.path]][{i}]"
        if not isinstance(entry, dict):
            raise InputError(f"{w}: expected a table")
        out.append(_table({"e": entry}, "e", EXCLUSION_KEYS, w, EXCLUSION))
        globs.check(out[-1]["glob"], f"{w} glob")
    return out


def surfaces(entries, where):
    """Judge a surface list: the manifest's own, and the spec copy's defaults.

    `where` names the list, so a refusal points at the file that holds it.
    """
    if not isinstance(entries, list):
        raise InputError(f"{where}: expected an array of tables")
    out = []
    seen = set()
    for i, entry in enumerate(entries):
        w = f"{where}[{i}]"
        if not isinstance(entry, dict):
            raise InputError(f"{w}: expected a table")
        s = _table({"e": entry}, "e", SURFACE_KEYS, w, SURFACE)
        name = s["name"]
        if not name or not all(c.islower() or c.isdigit() or c == "-" for c in name) \
                or not name.isascii():
            raise InputError(f"{w} name: {name!r} must be non-empty and hold only [a-z0-9-]")
        if name in RESERVED_SURFACE_NAMES:
            raise InputError(
                f"{w} name: {name!r} is reserved — it is a path this package or Macroscope "
                "already governs, and a surface claiming it would lose a file to write order"
            )
        if name in seen:
            raise InputError(f"{w} name: {name!r} is declared twice")
        seen.add(name)
        if not s["instructions"].strip():
            raise InputError(
                f"{w} instructions: empty. A surface renders a `path_instructions` entry "
                "with no text, a `.instructions.md` with a marker and nothing under it, "
                "and a best-practices section with no body — guidance that costs its "
                "bots a read and says nothing. Drop the surface instead"
            )
        globs.check_list(s["globs"], f"{w} globs")
        if s["exclude_globs"] is not None:
            globs.check_list(s["exclude_globs"], f"{w} exclude_globs")
        out.append(s)
    return out


def _doctrine(table, where):
    out = {"append": {}, "replace": {}}
    # Typed before it is iterated, the way `_table` types its siblings:
    # untyped, a string iterates character by character and reports
    # `[bot-instructions.doctrine.r]: unknown table`, which is the wrong cause entirely.
    if not isinstance(table, dict):
        raise InputError(f"{where} [bot-instructions.doctrine]: expected a table, got {type(table).__name__}")
    for key in table:
        if key not in out:
            raise InputError(f"{where} [bot-instructions.doctrine.{key}]: unknown table")
    for kind in out:
        given = table.get(kind, {})
        if not isinstance(given, dict):
            raise InputError(f"{where} [bot-instructions.doctrine.{kind}]: expected a table")
        for block, value in given.items():
            w = f"{where} [bot-instructions.doctrine.{kind}] {block}"
            _typed(value, str, w)
            refusals.apply(DOCTRINE_VALUES, value, w)
            out[kind][block] = value
    return out


def _refusal_inputs():
    """Every content-refusal row names an input something applies it to.

    A row is looked up by its input's name, so a row whose name nothing
    carries, a misspelt key or a non-string one, refuses nothing while the
    table reads as though it did.
    """
    for label in refusals.rows():
        if label not in INPUTS and label != refusals.DOCTRINE_TEXT:
            raise repo_toml.refused(
                f"content-refusal row {label!r} names no string input this package reads, "
                "so it would refuse nothing"
            )


@functools.cache
def qodo_verbs():
    """`repo-toml.md` § `[bot-instructions.cadence]`'s verb table: verb -> role.

    That table is the one statement of the set `qodo_commands` accepts and of
    which half `qodo-parity` requires guidance for. A role outside the two the
    table defines would read as not review and silence `qodo-parity`, so it is
    refused.
    """
    header, body = repo_toml.table("Verb")
    if "Role" not in header:
        raise repo_toml.refused("the verb table has no Role column")
    role_at = header.index("Role")
    out = {}
    for cells in body:
        verb, role = cells[0].replace("`", ""), cells[role_at]
        if role not in ("review", "not review"):
            raise repo_toml.refused(f"verb {verb!r} has role {role!r}, neither `review` nor `not review`")
        if verb in out:
            raise repo_toml.refused(f"the verb table has two rows for {verb!r}")
        out[verb] = role
    return out


def _cadence(cadence, where):
    verbs = qodo_verbs()
    for i, verb in enumerate(cadence["qodo_commands"]):
        w = f"{where} [bot-instructions.cadence] qodo_commands[{i}]"
        _typed(verb, str, w)
        if verb not in verbs:
            raise InputError(
                f"{w}: {verb!r} is not one of {', '.join(sorted(verbs))}"
            )
        if any(c.isspace() for c in verb) or "--" in verb:
            raise InputError(
                f"{w}: {verb!r} carries whitespace or an inline `--` override, which "
                "could null the guidance this render just wrote while qodo-parity passed"
            )


def _budgets(budgets, where):
    for key, value in budgets.items():
        if value <= 0:
            raise InputError(f"{where} [bot-instructions.budgets] {key}: must be positive, got {value}")


def _cross_flags(data, where):
    bots = data["bots"]
    if (bots["qodo_best_practices"] or bots["qodo_review_md"]) and not bots["qodo"]:
        raise InputError(
            f"{where} [bot-instructions.bots]: qodo_best_practices or qodo_review_md is true with qodo false, "
            "so the file it renders has no reader"
        )
    if (bots["copilot"] or bots["coderabbit"]) and not bots["codex"]:
        raise InputError(
            f"{where} [bot-instructions.bots]: copilot or coderabbit is true with codex false. That "
            "flag is what writes the pointed code_review_path file both of them read, so "
            "without it .coderabbit.yaml names a code_guidelines.filePatterns entry "
            "matching nothing and the Copilot pointer aims at a file that does not exist"
        )
    routes = ("copilot", "coderabbit", "macroscope", "qodo_best_practices")
    if data["surface"] and not any(bots[r] for r in routes):
        raise InputError(
            f"{where}: a non-empty [[bot-instructions.surface]] set with {', '.join(routes)} all false. Those "
            "four are every route surface text has, so these surfaces are instructions "
            "nothing will ever read"
        )
