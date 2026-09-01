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


class Worktree:
    """Every read walks from a repo-root descriptor with no-follow flags."""

    def __init__(self, root):
        self.root = root
        self.fd = fsutil.open_root(root)

    def read(self, rel):
        return fsutil.read_text(self.fd, rel)

    def walk(self, prefix):
        return fsutil.walk(self.fd, prefix)

    def subdirs(self, rel):
        from .manifest import _subdirs

        return _subdirs(self.fd, rel)

    def tracked(self):
        return _git(self.root, ["ls-files", "-z"])


class Index:
    """The staged state, read as blobs. Containment is not a question here:
    a blob has no path components to redirect through."""

    def __init__(self, root):
        self.root = root
        self._paths = None

    def read(self, rel):
        done = subprocess.run(
            ["git", "-C", self.root, "cat-file", "blob", f":{rel}"],
            capture_output=True, check=False,
        )
        if done.returncode != 0:
            return None
        return done.stdout.decode("utf-8", "replace")

    def walk(self, prefix):
        return [p for p in self.tracked() if p.startswith(prefix + "/")]

    def subdirs(self, rel):
        out = set()
        for path in self.tracked():
            if path.startswith(rel + "/"):
                rest = path[len(rel) + 1:]
                if "/" in rest:
                    out.add(rest.split("/", 1)[0])
        return sorted(out)

    def tracked(self):
        if self._paths is None:
            self._paths = _git(self.root, ["ls-files", "-z"])
        return self._paths


def _git(root, args):
    done = subprocess.run(["git", "-C", root] + args, capture_output=True, check=False)
    if done.returncode != 0:
        return []
    return [p for p in done.stdout.decode("utf-8", "replace").split("\0") if p]


def open_tree(root, staged):
    return Index(root) if staged else Worktree(root)
