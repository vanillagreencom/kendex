"""`bot-instructions.toml`: the schema, and the `toml-schema` validator.

The schema is closed. An unknown key, an unknown table, a value of the wrong
type, or an absent required key is an error naming the key — a typo like
`[bot]`, `derive_renders` or `review_only` would otherwise be ignored while
defaults produced plausible output.

KEYS below is the schema. The required-key clause derives from its `required`
column rather than restating which fields are required, because a restated
list falls behind the column.
"""

import tomllib

from .constants import (
    DEFAULT_COPILOT_CHARS,
    DEFAULT_QODO_LINES,
    QODO_VERBS,
    RESERVED_SURFACE_NAMES,
)
from .errors import InputError
from . import globs, refusals

# table -> key -> (type, required, default, refusal row or None)
KEYS = {
    "repo": {
        "name": (str, True, None, "[repo] name"),
        "summary": (str, True, None, "[repo] summary"),
        "tracker": (str, False, None, "[repo] tracker"),
    },
    "bots": {
        k: (bool, False, False, None)
        for k in (
            "codex", "copilot", "coderabbit", "qodo",
            "qodo_best_practices", "qodo_review_md", "macroscope",
        )
    },
    "cadence": {
        "coderabbit_incremental": (bool, False, True, None),
        "coderabbit_drafts": (bool, False, False, None),
        "qodo_commands": (list, False, ["/agentic_review"], None),
        "qodo_push_trigger": (bool, False, False, None),
    },
    "tone": {"coderabbit": (str, False, None, "[tone] coderabbit")},
    "budgets": {
        "copilot_chars": (int, False, DEFAULT_COPILOT_CHARS, None),
        "qodo_best_practices_lines": (int, False, DEFAULT_QODO_LINES, None),
    },
    "exclusions": {"derive_render": (bool, False, False, None), "path": (list, False, [], None)},
}

SURFACE_KEYS = {
    "name": (str, True, None, None),
    "globs": (list, True, None, None),
    "exclude_globs": (list, False, None, None),
    "reviewer_only": (bool, False, False, None),
    "instructions": (str, True, None, "[[surface]] instructions"),
}

EXCLUSION_KEYS = {
    "glob": (str, True, None, None),
    "reason": (str, True, None, "[[exclusions.path]] reason"),
}

TOP_LEVEL = frozenset({"schema", "surface", "doctrine"}) | frozenset(KEYS)


class Config:
    def __init__(self, data):
        self.raw = data
        self.repo = data["repo"]
        self.bots = data["bots"]
        self.cadence = data["cadence"]
        self.tone = data["tone"]
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


def _table(raw, name, schema, where):
    """Read one closed table: unknown keys, wrong types, absent required keys."""
    given = raw.get(name, {})
    if not isinstance(given, dict):
        raise InputError(f"{where}: expected a table")
    out = {}
    for key in given:
        if key not in schema:
            raise InputError(f"{where}: unknown key {key!r}")
    for key, (want, required, default, row) in schema.items():
        if key in given:
            value = _typed(given[key], want, f"{where} {key}")
            if row:
                refusals.apply(row, value, f"{where} {key}")
            out[key] = value
        elif required:
            raise InputError(f"{where}: required key {key!r} is absent")
        else:
            out[key] = default
    return out


def parse(text, where="bot-instructions.toml"):
    try:
        raw = tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        raise InputError(f"{where}: not valid TOML ({exc})") from exc
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
    data = {name: _table(raw, name, schema, f"{where} [{name}]") for name, schema in KEYS.items()}
    data["exclusions"]["path"] = _exclusions(raw.get("exclusions", {}), where)
    data["surface"] = _surfaces(raw.get("surface", []), where)
    data["doctrine"] = _doctrine(raw.get("doctrine", {}), where)
    _cadence(data["cadence"], where)
    _budgets(data["budgets"], where)
    _cross_flags(data, where)
    return Config(data)


def _exclusions(table, where):
    entries = table.get("path", [])
    if not isinstance(entries, list):
        raise InputError(f"{where} [[exclusions.path]]: expected an array of tables")
    out = []
    for i, entry in enumerate(entries):
        w = f"{where} [[exclusions.path]][{i}]"
        if not isinstance(entry, dict):
            raise InputError(f"{w}: expected a table")
        out.append(_table({"e": entry}, "e", EXCLUSION_KEYS, w))
        globs.check(out[-1]["glob"], f"{w} glob")
    return out


def _surfaces(entries, where):
    if not isinstance(entries, list):
        raise InputError(f"{where} [[surface]]: expected an array of tables")
    out = []
    seen = set()
    for i, entry in enumerate(entries):
        w = f"{where} [[surface]][{i}]"
        if not isinstance(entry, dict):
            raise InputError(f"{w}: expected a table")
        s = _table({"e": entry}, "e", SURFACE_KEYS, w)
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
    # `[doctrine.r]: unknown table`, which is the wrong cause entirely.
    if not isinstance(table, dict):
        raise InputError(f"{where} [doctrine]: expected a table, got {type(table).__name__}")
    for key in table:
        if key not in out:
            raise InputError(f"{where} [doctrine.{key}]: unknown table")
    for kind in out:
        given = table.get(kind, {})
        if not isinstance(given, dict):
            raise InputError(f"{where} [doctrine.{kind}]: expected a table")
        for block, value in given.items():
            w = f"{where} [doctrine.{kind}] {block}"
            _typed(value, str, w)
            refusals.apply("[doctrine.*] values", value, w)
            out[kind][block] = value
    return out


def _cadence(cadence, where):
    for i, verb in enumerate(cadence["qodo_commands"]):
        w = f"{where} [cadence] qodo_commands[{i}]"
        _typed(verb, str, w)
        if verb not in QODO_VERBS:
            raise InputError(
                f"{w}: {verb!r} is not one of {', '.join(sorted(QODO_VERBS))}"
            )
        if any(c.isspace() for c in verb) or "--" in verb:
            raise InputError(
                f"{w}: {verb!r} carries whitespace or an inline `--` override, which "
                "could null the guidance this render just wrote while qodo-parity passed"
            )


def _budgets(budgets, where):
    for key, value in budgets.items():
        if value <= 0:
            raise InputError(f"{where} [budgets] {key}: must be positive, got {value}")


def _cross_flags(data, where):
    bots = data["bots"]
    if (bots["qodo_best_practices"] or bots["qodo_review_md"]) and not bots["qodo"]:
        raise InputError(
            f"{where} [bots]: qodo_best_practices or qodo_review_md is true with qodo false, "
            "so the file it renders has no reader"
        )
    if (bots["copilot"] or bots["coderabbit"]) and not bots["codex"]:
        raise InputError(
            f"{where} [bots]: copilot or coderabbit is true with codex false. Both read the "
            "AGENTS.md section — CodeRabbit through code_guidelines, Copilot code review "
            "directly — so without it .coderabbit.yaml carries one doctrine block and the "
            "Copilot pointer aims at a section that does not exist"
        )
    routes = ("copilot", "coderabbit", "macroscope", "qodo_best_practices")
    if data["surface"] and not any(bots[r] for r in routes):
        raise InputError(
            f"{where}: a non-empty [[surface]] set with {', '.join(routes)} all false. Those "
            "four are every route surface text has, so these surfaces are instructions "
            "nothing will ever read"
        )
