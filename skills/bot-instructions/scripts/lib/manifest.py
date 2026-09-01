"""`[exclusions] derive_render`: the install manifest, and what it derives.

**The manifest is the one kendex resolves, never a hardcoded filename.** That
is `kendex.toml`, except in a repo whose `kendex.toml` declares
`is_source_catalog = true`, where install state routes to the sibling
`kendex-local.toml`. Opening `kendex.toml` by name in such a repo would parse a
present, valid file, derive an empty set, and pass a consistency check
comparing empty against empty.

**What a harness root contributes, and what it must not.** A harness root
holds two kinds of thing: subdirectories kendex owns whole, and root-level
files kendex merges its own entries into while the repo owns the rest —
`.claude/settings.json`, `.codex/config.toml`, `.pi/settings.json`. So the
derivation takes **each immediate subdirectory** of a declared render root and
never a file at its root. A glob one shape too wide would silence review on a
settings file this repo owns and can fix, which is the opposite of what the
derivation is for. `skills/review-gate/references/vendored-paths.md` § The
harness-render variant draws the same line for the review gate's own set and
names the merged paths.
"""

import tomllib

from .constants import DERIVED_REASON
from .errors import ManifestError

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
            continue
        if entry.get("enabled") is False:
            continue
        if entry.get("source") == "in-place":
            # This repo's own file: its content of record is edited here, so
            # it stays in review scope.
            continue
        trees.add(f".agents/skills/{name}/**")
    for harness in resolved.harnesses:
        row = HARNESS_ROOTS.get(harness)
        if row is None:
            raise ManifestError(
                f"[install] harnesses: {harness!r} has no render root in this package. "
                "Add its row rather than deriving a root that may hold repo-owned files"
            )
        root, subtrees = row
        for sub in subtrees if subtrees is not None else tree.subdirs(root):
            trees.add(f"{root}/{sub}/**")
    return [{"glob": g, "reason": DERIVED_REASON, "derived": True} for g in sorted(trees)]


def _subdirs(root_fd, rel):
    """Immediate subdirectories of a render root. A root file is never one."""
    import os
    import stat

    from .fsutil import _components, _walk_to_parent, _Missing

    try:
        dir_fd, leaf = _walk_to_parent(root_fd, _components(rel))
    except _Missing:
        return []
    try:
        try:
            here = os.open(leaf, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dir_fd)
        except OSError:
            return []
        try:
            out = []
            for name in sorted(os.listdir(here)):
                st = os.stat(name, dir_fd=here, follow_symlinks=False)
                if stat.S_ISDIR(st.st_mode):
                    out.append(name)
            return out
        finally:
            os.close(here)
    finally:
        os.close(dir_fd)
