"""The tree a verb judges: the working tree, or the index.

`check` reads the working tree by default. Under `--staged` it reads the index
— and the index for **every render input**, not only the outputs. Outputs-only
would be wrong in both directions in the pre-commit lane this mode exists for:
a commit staging a TOML change with its re-rendered outputs would red, because
the outputs came from the index while the render was built from a worktree
TOML that may have moved on; and an unstaged doctrine edit would silently
decide what the staged outputs were compared against, passing or failing on
bytes nobody is committing.

A file absent from the index is that absence, not its worktree copy.
"""

import subprocess

from . import fsutil
from .errors import ManifestError, SourceUnavailable


class Worktree:
    """Every read walks from a repo-root descriptor with no-follow flags."""

    def __init__(self, root):
        self.root = root
        self.fd = fsutil.open_root(root)
        self._paths = None

    def read(self, rel):
        return fsutil.read_text(self.fd, rel)

    def walk(self, prefix):
        return fsutil.walk(self.fd, prefix)

    def subdirs(self, rel):
        return _subdirs(self.tracked(), rel)

    def tracked(self):
        # Memoised, the way `Index.tracked` is. `manifest.derive` asks per
        # harness row and runs twice per check, so an uncached read here spawns
        # git once per row per pass instead of once per run. Nothing reads the
        # list after the write phase: `render_verb` validates, then writes.
        if self._paths is None:
            self._paths = _git(self.root, ["ls-files", "-z"])
        return self._paths


class Index:
    """The staged state, read as blobs. Containment is not a question here:
    a blob has no path components to redirect through."""

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
            # absent from the index — which is a state, and the one `--staged`
            # exists to judge.
            return None
        # The same strict decode `Worktree.read` uses. Two trees that answer
        # differently would be the worst version of this: `--staged` is the
        # pre-commit lane, so a lossy read there green-lights a commit whose
        # bytes no `render` can produce and whose `check` reds.
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

    One function, so a worktree render and a `--staged` check of it cannot
    derive different sets: `git ls-files` is the index in both modes, and a
    filesystem walk here answered a different question. It answered it worse,
    too — an untracked or gitignored subdirectory of a render root
    (`.claude/todos`) derived a glob matching nothing, which `_dead_globs`
    then rejected as dead config with no edit that could clear it, and a
    render root reached through a symlink derived nothing at all while the
    index still carried the tree, so both sides of `exclusion-consistency`
    agreed on empty and the run reported a clean pass.

    A root-level file is never a subdirectory, which is the rule
    `.claude/settings.json` needs: a glob one shape too wide would silence
    review on a settings file this repo owns and can fix.

    **A render root the index holds as an entry of its own is refused**, not
    derived as empty. Once a harness root is actually staged as a symlink git
    stores `.claude` as that one entry and the tree under its real name, so no
    tracked path opens with `.claude/` and this returns the empty set — the
    harness tree silently back in review scope, on both verbs, with nothing
    saying so. That is the empty-derivation failure this function was written
    to close, arriving through the state its first fixture never entered. An
    empty answer here means the root holds no tracked subdirectory; it must
    not also mean the root is not a directory.
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
    case then silently absorbs the first: `agents-section`'s nested-`AGENTS.md`
    tracked-path read loses its entire input and the run reports a clean pass.
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
    # Lossy, and named as the exception in `renders.md` § Common rules beside
    # the rule it is an exception to: that rule is about FILE CONTENT, and a
    # path is bytes to git. `ls-files -z` emits whatever names the repo holds,
    # so a repo tracking one that is not UTF-8 is a working repo rather than a
    # repo to refuse; the substituted name matches no glob and reads as an odd
    # name in a report. `fsutil.decode_text` answers the content question.
    return [p for p in _run(root, args).stdout.decode("utf-8", "replace").split("\0") if p]


def open_tree(root, staged):
    return Index(root) if staged else Worktree(root)
