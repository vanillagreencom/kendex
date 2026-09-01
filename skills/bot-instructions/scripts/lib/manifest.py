"""`[exclusions] derive_render`: the install manifest, and what it derives.

**The manifest is the one kendex resolves, never a hardcoded filename.** That
is `kendex.toml`, except where it declares `is_source_catalog = true` and
install state routes to the sibling `kendex-local.toml`. Opening `kendex.toml`
by name in such a repo parses a present, valid file and derives an empty set.

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

import tomllib

from .constants import DERIVED_REASON
from .errors import InputError, ManifestError
from . import globs

ROOT_MANIFEST = "kendex.toml"
LOCAL_MANIFEST = "kendex-local.toml"

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
    def __init__(self, paths, harnesses, skills):
        self.paths = paths          # every manifest path actually read
        self.harnesses = harnesses
        self.skills = skills        # name -> source


def resolve(tree):
    """Read the manifest kendex resolves. Returns (Resolved, [paths read])."""
    root_text = tree.read(ROOT_MANIFEST)
    if root_text is None:
        raise ManifestError(
            f"{ROOT_MANIFEST}: absent, and `[exclusions] derive_render` is true. A repo "
            "the generator cannot derive from says so rather than shipping a short list"
        )
    paths = [ROOT_MANIFEST]
    try:
        root = tomllib.loads(root_text)
    except tomllib.TOMLDecodeError as exc:
        raise ManifestError(f"{ROOT_MANIFEST}: not valid TOML ({exc})") from exc
    chosen, data = ROOT_MANIFEST, root
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
        chosen = LOCAL_MANIFEST
    harnesses = data.get("install", {}).get("harnesses", [])
    skills = data.get("skills", {})
    if not harnesses and not skills:
        raise ManifestError(
            f"{chosen}: declares no install — no `[install] harnesses` and no `[skills.*]` "
            "rows. Reading the wrong file and finding nothing to exclude is "
            "indistinguishable from a repo with nothing to exclude, so emptiness is the "
            "finding rather than an empty derivation"
        )
    return Resolved(paths, list(harnesses), skills), paths


def derive(tree, resolved):
    """The derived exclusion globs, lexicographic, each with the fixed reason."""
    trees = set()
    for name, entry in resolved.skills.items():
        if not isinstance(entry, dict):
            # Loud, like every neighbour here. Skipping the row would leave a
            # vendored tree in review scope with both verbs exiting 0 —
            # "nothing found" standing in for "I could not tell".
            raise ManifestError(
                f"[skills.{name}]: expected a table, got {type(entry).__name__}. The row "
                "decides whether that tree is excluded from review, and a row this cannot "
                "read is refused rather than skipped"
            )
        if entry.get("enabled") is False:
            continue
        if entry.get("source") == "in-place":
            # This repo's own file: its content of record is edited here, so
            # it stays in review scope.
            continue
        trees.add(_checked(f".agents/skills/{name}/**", f"[skills.{name}]"))
    for harness in resolved.harnesses:
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

    A manifest key and an on-disk directory name become pattern bytes without
    an author writing them as a glob, and they render as prose on two surfaces
    where nothing reads them as globs at all. Refusing at the source names
    which manifest row produced it.
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
