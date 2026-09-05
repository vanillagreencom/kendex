"""`[bot-instructions.exclusions] derive_render`: the install record, and what it derives.

**Skill trees come from the writer inventory, never from the declaration.**
`.kendex-generated.json` is the record kendex tracks of every path it wrote
into this repo. The manifest's `[skills.*]` rows are the request: a skill
kendex installs as another skill's dependency has no row, and deriving from
the rows left such a tree in review scope with both verbs exiting 0. A skill
installed in place is this repo's own file, and kendex lists none of its
paths, so it stays in review scope with no rule of its own here.

**The manifest is the one kendex resolves, never a hardcoded filename.** That
is `kendex.toml`, except where it declares `is_source_catalog = true` and
install state routes to the sibling `kendex-local.toml`. Opening `kendex.toml`
by name in such a repo parses a present, valid file and derives an empty set.
It decides which harness roots the repo installs.

**What a harness root contributes.** Each immediate subdirectory of a declared
render root that holds a tracked path, and never an entry at its root, whether
that entry is a file or a symlink — kendex merges its own
entries into `.claude/settings.json`, `.codex/config.toml` and
`.pi/settings.json` while the repo owns the rest, and a glob one shape too
wide would silence review on a file this repo can fix. `tree.subdirs` answers
that from the index alone, identically in both modes.
`skills/review-gate/references/vendored-paths.md` § The harness-render variant
draws the same line for the review gate's own set.
"""

import json
import tomllib

from .constants import DERIVED_REASON
from .errors import InputError, ManifestError
from . import globs

ROOT_MANIFEST = "kendex.toml"
LOCAL_MANIFEST = "kendex-local.toml"
INVENTORY = ".kendex-generated.json"
SKILLS_ROOT = ".agents/skills"

# harness -> (render root, the subtrees under it, or None for "every
# immediate subdirectory"). Copilot is the one harness whose root the repo
# also owns, so its row names the subtrees rather than taking the root.
HARNESS_ROOTS = {
    "claude": (".claude", None),
    "codex": (".codex", None),
    "cursor": (".cursor", None),
    "gemini": (".gemini", None),
    "opencode": (".opencode", None),
    "pi": (".pi", None),
    "copilot": (".github", ("agents", "hooks", "skills")),
}


class Resolved:
    def __init__(self, paths, data):
        self.paths = paths          # every manifest path actually read
        self.data = data            # the effective manifest, read once

    @property
    def chosen(self):
        return self.paths[-1]


def resolve(tree):
    """Read the manifest kendex resolves for configuration and exclusions."""
    root_text = tree.read(ROOT_MANIFEST)
    if root_text is None:
        raise ManifestError(
            f"{ROOT_MANIFEST}: absent at the repo root"
        )
    paths = [ROOT_MANIFEST]
    try:
        root = tomllib.loads(root_text)
    except tomllib.TOMLDecodeError as exc:
        raise ManifestError(f"{ROOT_MANIFEST}: not valid TOML ({exc})") from exc
    data = root
    if root.get("is_source_catalog") is True:
        local_text = tree.read(LOCAL_MANIFEST)
        if local_text is None:
            raise ManifestError(
                f"{LOCAL_MANIFEST}: absent, but {ROOT_MANIFEST} declares "
                "is_source_catalog = true, so install state routes there"
            )
        paths.append(LOCAL_MANIFEST)
        try:
            data = tomllib.loads(local_text)
        except tomllib.TOMLDecodeError as exc:
            raise ManifestError(f"{LOCAL_MANIFEST}: not valid TOML ({exc})") from exc
    return Resolved(paths, data)


def rendered_skill_trees(tree):
    """The `.agents/skills/<name>` trees the inventory lists a path under.

    Absent or unreadable is refused, never an empty set: a repo kendex has not
    rendered into has no record to derive from, and an empty derivation there
    reads exactly like a repo with nothing to exclude.
    """
    text = tree.read(INVENTORY)
    if text is None:
        raise ManifestError(
            f"{INVENTORY}: absent. kendex writes it on apply and refresh in a project "
            "it renders into, and it is the record of which trees kendex wrote — the "
            "manifest's [skills.*] rows say what was asked for, and a skill installed "
            "as another's dependency has no row. Run `kendex refresh` and track the file"
        )
    try:
        paths = json.loads(text)
    except ValueError as exc:
        raise ManifestError(f"{INVENTORY}: not valid JSON ({exc})") from exc
    if not isinstance(paths, list) or not all(isinstance(p, str) for p in paths):
        raise ManifestError(
            f"{INVENTORY}: expected a JSON array of repo-relative paths. A record this "
            "cannot read is refused rather than read as empty"
        )
    names = set()
    prefix = SKILLS_ROOT + "/"
    for path in paths:
        rest = path[len(prefix):] if path.startswith(prefix) else ""
        if "/" in rest:
            names.add(rest.split("/", 1)[0])
    return sorted(names)


def derive(tree, resolved):
    """The derived exclusion globs, lexicographic, each with the fixed reason."""
    harnesses = resolved.data.get("install", {}).get("harnesses", [])
    skills = resolved.data.get("skills", {})
    if not harnesses and not skills:
        raise ManifestError(
            f"{resolved.chosen}: declares no install — no `[install] harnesses` and no `[skills.*]` "
            "rows. Reading the wrong file and finding nothing to exclude is "
            "indistinguishable from a repo with nothing to exclude, so emptiness is the "
            "finding rather than an empty derivation"
        )
    trees = set()
    for name in rendered_skill_trees(tree):
        trees.add(_checked(f"{SKILLS_ROOT}/{name}/**", f"{INVENTORY} {SKILLS_ROOT}/{name}"))
    for harness in harnesses:
        row = HARNESS_ROOTS.get(harness)
        if row is None:
            raise ManifestError(
                f"[install] harnesses: {harness!r} has no render root in this package. "
                "Add its row rather than deriving a root that may hold repo-owned files"
            )
        root, subtrees = row
        # Only subtrees that exist: `.github` holds whichever of the copilot
        # row's three a repo installed, and deriving the other two would name
        # globs `_dead_globs` rejects as dead config no TOML edit can clear.
        present = tree.subdirs(root)
        for sub in present if subtrees is None else [s for s in subtrees if s in present]:
            trees.add(_checked(f"{root}/{sub}/**", f"[install] harnesses {harness!r}"))
    return [{"glob": g, "reason": DERIVED_REASON, "derived": True} for g in sorted(trees)]


def _checked(glob, source):
    """A derived glob, held to the same dialect every declared one meets.

    An inventory path component and an on-disk directory name become pattern
    bytes without an author writing them as a glob, and they render as prose
    on two surfaces where nothing reads them as globs at all. Refusing at the
    source names which inventory entry or manifest row produced it.
    """
    try:
        globs.check(glob, source)
    except InputError as exc:
        raise ManifestError(
            f"{exc}. A derived exclusion is rendered as a pattern on three surfaces and "
            "as prose on two, so a name outside the dialect is refused here rather than "
            "carried into an output"
        ) from exc
    return glob
