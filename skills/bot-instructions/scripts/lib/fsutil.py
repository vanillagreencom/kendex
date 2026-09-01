"""Contained opens, atomic replacement, and the render lock.

SKILL.md § Every open is contained is the contract, and the rule is about
opens rather than about outputs: resolving a path, checking it, then opening
it proves a property about the name and not about the file the open lands on.
So every open here walks from a repo-root descriptor, one component at a time,
with directory and no-follow flags. A symlink anywhere in the path fails.
"""

import errno
import os
import stat

from .errors import ContainmentError, RenderError

_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
_DIRECTORY = getattr(os, "O_DIRECTORY", 0)

RUN_DIR = ".bot-instructions"
LOCK_NAME = "render.lock"
MANIFEST_NAME = "render-manifest.json"


class _Missing(Exception):
    """An intermediate directory is absent, so the path is."""


def _is_symlink(name, dir_fd):
    """Whether a failed `O_DIRECTORY|O_NOFOLLOW` open landed on a symlink.

    The errno alone cannot say. Linux answers **ENOTDIR** for a symlink to a
    directory here, not ELOOP, and ENOTDIR is also what an ordinary file
    gives — so an errno test either treats a symlinked tree as absent or an
    ordinary file as a containment breach. This asks the filesystem instead.

    It is what makes the ELOOP branches below reachable at all. Grouping
    ENOTDIR with ENOENT in `walk` made a symlinked scanned tree an EMPTY walk:
    `orphan`'s only enumeration source returned nothing, its one clause about
    a scanned tree had no input, and `check` reported a clean pass on a read
    that leaves the repo root.
    """
    try:
        return stat.S_ISLNK(os.lstat(name, dir_fd=dir_fd).st_mode)
    except OSError:
        return False


def _components(rel):
    parts = [p for p in rel.split("/") if p]
    if not parts or any(p in (".", "..") for p in parts):
        raise ContainmentError(f"{rel}: not a repo-relative path this package will open")
    return parts


def open_root(root):
    try:
        return os.open(root, os.O_RDONLY | _DIRECTORY | _NOFOLLOW)
    except OSError as exc:
        raise ContainmentError(f"{root}: cannot open the repo root ({exc.strerror})") from exc


def _walk_to_parent(root_fd, parts, create=False):
    """Descend to the parent of the last component. Returns (fd, leaf)."""
    fd = os.dup(root_fd)
    try:
        for part in parts[:-1]:
            try:
                nxt = os.open(part, os.O_RDONLY | _DIRECTORY | _NOFOLLOW, dir_fd=fd)
            except OSError as exc:
                if exc.errno == errno.ENOENT and not create:
                    # An absent intermediate directory means the file is
                    # absent, which is a state, not a containment failure.
                    raise _Missing() from exc
                if create and exc.errno == errno.ENOENT:
                    os.mkdir(part, 0o755, dir_fd=fd)
                    nxt = os.open(part, os.O_RDONLY | _DIRECTORY | _NOFOLLOW, dir_fd=fd)
                elif exc.errno in (errno.ELOOP, errno.EMLINK) or _is_symlink(part, fd):
                    raise ContainmentError(
                        f"{'/'.join(parts)}: component {part!r} is a symlink; "
                        "no component of a path this package opens may redirect"
                    ) from exc
                else:
                    raise ContainmentError(
                        f"{'/'.join(parts)}: cannot descend into {part!r} ({exc.strerror})"
                    ) from exc
            os.close(fd)
            fd = nxt
        return fd, parts[-1]
    except BaseException:
        os.close(fd)
        raise


def read_file(root_fd, rel):
    """Bytes at `rel`, or None when it is absent. Never follows a symlink."""
    parts = _components(rel)
    try:
        dir_fd, leaf = _walk_to_parent(root_fd, parts)
    except _Missing:
        return None
    try:
        try:
            fd = os.open(leaf, os.O_RDONLY | _NOFOLLOW, dir_fd=dir_fd)
        except OSError as exc:
            if exc.errno == errno.ENOENT:
                return None
            if exc.errno in (errno.ELOOP, errno.EMLINK):
                raise ContainmentError(f"{rel}: is a symlink and is not followed") from exc
            raise ContainmentError(f"{rel}: cannot open ({exc.strerror})") from exc
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise ContainmentError(f"{rel}: is not a regular file")
            return _read_all(fd)
        finally:
            os.close(fd)
    finally:
        os.close(dir_fd)


def _read_all(fd):
    chunks = []
    while True:
        chunk = os.read(fd, 1 << 16)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)


def decode_text(raw, rel):
    """The one strict decode: text this run judges by, or writes back.

    A lossy decode is safe only where the text is read and thrown away. Two
    places it is not. A read a validator judges by: a substituted byte makes
    the run report on bytes the repo does not hold. And a read-modify-write:
    the new bytes are derived from this text, so the substitution is written
    back over content outside the region this package owns.

    Both tree implementations read through here, so `check` and
    `check --staged` answer the same question about the same repo. The write
    phase asks for it by content mode — `writer._gate`, whose `data=` form
    decodes lossily for the marker test, writes none of it, and reports the
    repair so a replaced corruption is not silent.

    FILE CONTENT is the whole of what this covers. A path list from git is
    bytes to git and stays lossy in `tree._git`, which is the one exception
    `renders.md` § Common rules names beside the rule.
    """
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise RenderError(f"{rel}: is not UTF-8 ({exc.reason})") from exc


def read_text(root_fd, rel):
    raw = read_file(root_fd, rel)
    if raw is None:
        return None
    return decode_text(raw, rel)


def walk(root_fd, rel, _depth=0):
    """Every regular file below `rel`, repo-relative, sorted.

    A symlink met on the way is a finding rather than something to follow:
    `orphan` sweeps trees named by the tree under judgment, and a symlinked
    directory there is a read out of the repo. `orphan` is the only caller —
    `agents-section` filters the tracked path list and walks nothing.
    """
    if _depth > 64:
        raise ContainmentError(f"{rel}: directory nesting past 64 levels")
    parts = _components(rel)
    try:
        dir_fd, leaf = _walk_to_parent(root_fd, parts)
    except _Missing:
        return []
    out = []
    try:
        try:
            here = os.open(leaf, os.O_RDONLY | _DIRECTORY | _NOFOLLOW, dir_fd=dir_fd)
        except OSError as exc:
            # The symlink test comes FIRST: ENOTDIR is both "a symlink to a
            # directory" and "an ordinary file at this path", and only the
            # second of those is a state rather than a read out of the repo.
            if exc.errno in (errno.ELOOP, errno.EMLINK) or _is_symlink(leaf, dir_fd):
                raise ContainmentError(f"{rel}: is a symlink and is not walked") from exc
            if exc.errno in (errno.ENOENT, errno.ENOTDIR):
                return []
            raise ContainmentError(f"{rel}: cannot walk ({exc.strerror})") from exc
        try:
            for name in sorted(os.listdir(here)):
                child = f"{rel}/{name}"
                st = os.stat(name, dir_fd=here, follow_symlinks=False)
                if stat.S_ISDIR(st.st_mode):
                    out.extend(walk(root_fd, child, _depth + 1))
                elif stat.S_ISREG(st.st_mode):
                    out.append(child)
                elif stat.S_ISLNK(st.st_mode):
                    raise ContainmentError(
                        f"{child}: is a symlink inside a tree this package walks"
                    )
        finally:
            os.close(here)
    finally:
        os.close(dir_fd)
    return out

