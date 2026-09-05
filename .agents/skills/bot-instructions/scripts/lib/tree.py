"""The tree a verb judges: the working tree, or the index.

`check` reads the working tree by default. Under `--staged` it reads the index
— and the index for **every render input**, not only the outputs. Outputs-only
would be wrong in both directions in the pre-commit lane this mode exists for:
a commit staging a TOML change with its re-rendered outputs would red, because
the outputs came from the index while the render was built from a worktree
TOML that may have moved on; and an unstaged doctrine edit would silently
decide what the staged outputs were compared against.

A file absent from the index is that absence, not its worktree copy.
"""

import subprocess

from . import fsutil
from .errors import ManifestError, SourceUnavailable


class Worktree:
    def __init__(self, root):
        self.root = root
        self._paths = None

    def read(self, rel):
        return fsutil.read_text(self.root, rel)

    def walk(self, prefix):
        return fsutil.walk(self.root, prefix)

    def subdirs(self, rel):
        return _subdirs(self.tracked(), rel)

    def tracked(self):
        # Memoised: `manifest.derive` asks per harness row and runs twice per
        # check, so an uncached read spawns git once per row per pass.
        if self._paths is None:
            self._paths = _git(self.root, ["ls-files", "-z"])
        return self._paths


class Index:
    """The staged state, read as blobs."""

    def __init__(self, root):
        self.root = root
        self._paths = None
        self._repo_ok = False

    def _ensure_repo(self):
        """One check that git can answer about this tree at all.

        `git cat-file blob :path` exits 128 both for a path absent from the
        index and for a directory that is not a repository, and the two are
        told apart only by stderr text. Confirming the repository once turns
        every later 128 into the absence it is, without matching on prose git
        is free to reword.
        """
        if self._repo_ok:
            return
        _run(self.root, ["rev-parse", "--git-dir"])
        self._repo_ok = True

    def read(self, rel):
        self._ensure_repo()
        done = subprocess.run(
            ["git", "-C", self.root, "cat-file", "blob", f":{rel}"],
            capture_output=True, check=False,
        )
        if done.returncode != 0:
            # The repository answered a moment ago, so this is the blob being
            # absent from the index — the state `--staged` exists to judge.
            return None
        return fsutil.decode_text(done.stdout, rel)

    def walk(self, prefix):
        return [p for p in self.tracked() if p.startswith(prefix + "/")]

    def subdirs(self, rel):
        return _subdirs(self.tracked(), rel)

    def tracked(self):
        if self._paths is None:
            self._paths = _git(self.root, ["ls-files", "-z"])
        return self._paths


def _subdirs(tracked, rel):
    """Immediate subdirectories of a render root that hold a tracked path.

    One function over the index in both modes, so a worktree render and a
    `--staged` check of it cannot derive different sets.

    A regular file directly under the root contributes nothing, which is the
    rule `.claude/settings.json` needs: a glob one shape too wide would
    silence review on a settings file this repo owns and can fix. A symlink
    entry contributes nothing either, whatever its target. git stores one as a
    blob, and a pull request editing the tree behind it carries the tree's
    real path in its diff, never the path through the link, so a glob under
    the link matches no diff path on any bot. The consumer repos link per
    skill (`.claude/skills/code-quality`), whose tracked path already carries
    the further slash this rule reads.

    **A render root the index holds as an entry of its own is refused**, not
    derived as empty. An empty answer here means the root holds no tracked
    subdirectory; it must not also mean the root is not a directory.
    """
    if rel in tracked:
        raise ManifestError(
            f"{rel}: the index tracks this render root as a file or a symlink, not as a "
            "directory, so no subdirectory under it can be derived and the tree it "
            "stands for would be left in review scope. Track the tree at this path, or "
            "drop the harness that declares this root"
        )
    out = set()
    prefix = rel + "/"
    for path in tracked:
        if path.startswith(prefix):
            rest = path[len(prefix):]
            if "/" in rest:
                out.add(rest.split("/", 1)[0])
    return sorted(out)


def _run(root, args):
    """Run git, or raise. A nonzero exit is never an empty answer.

    Returning `[]` when git could not answer is indistinguishable from a repo
    that tracks nothing, and the clause downstream that exists for the second
    case then silently absorbs the first.
    """
    try:
        done = subprocess.run(["git", "-C", root] + args, capture_output=True, check=False)
    except OSError as exc:
        raise SourceUnavailable(f"git {' '.join(args)}", f"cannot run git ({exc.strerror})") from exc
    if done.returncode != 0:
        detail = done.stderr.decode("utf-8", "replace").strip().split("\n")[0] or "no diagnostic"
        raise SourceUnavailable(f"git {' '.join(args)}", f"exited {done.returncode}: {detail}")
    return done


def _git(root, args):
    """Every path git prints, decoded with `surrogateescape`.

    Neither of the two modes the rest of this package chooses between, because
    a path is neither content nor display text. Strict would refuse a working
    repo: a name that is not UTF-8 is legal on every filesystem this runs on.
    Lossy would DESTROY the name, and the reopen would then address a
    different path.
    """
    raw = _run(root, args).stdout.decode("utf-8", "surrogateescape")
    return [p for p in raw.split("\0") if p]


def open_tree(root, staged):
    return Index(root) if staged else Worktree(root)
