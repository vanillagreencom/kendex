"""The write phase: the marker gate, atomic replacement, the lock, the manifest.

Two properties the spec requires do not compose into one mechanism, and the
implementation settles which wins rather than pretending both hold.

**Atomicity wins.** Every replacement is temp-write-then-rename, so an
interrupt leaves the old bytes and never a truncated file. That matters most
for `AGENTS.md`, the doctrine root three of the five bots read.

**The marker gate is narrowed, not closed.** A rename replaces a path, not the
descriptor the marker was read from, so no single file is both marker-checked
and replaced. What this does: opens the target no-follow at replacement time,
reads the marker from that descriptor, records the file's identity, and
re-checks that identity immediately before the rename. The residual window is
from that last check to the rename. The lock closes the concurrent-render
case; an editor or a formatter landing in that window is not closed by
anything portable, and the spec says so rather than claiming it is.
"""

import errno
import json
import os
import stat

from . import marker as marker_mod
from .constants import MARKER_TOKEN
from .errors import ContainmentError, LockError, RenderError
from .fsutil import RUN_DIR, LOCK_NAME, MANIFEST_NAME, _components, _walk_to_parent, _read_all

_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


def _identity(st):
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns)


def _gate(dir_fd, leaf, rel, require_marker):
    """Read the marker off the file opened for the replacement.

    Returns the identity to re-check before the rename, or None when the path
    is absent — a path this package is creating has nothing to protect.
    """
    try:
        fd = os.open(leaf, os.O_RDONLY | _NOFOLLOW, dir_fd=dir_fd)
    except OSError as exc:
        if exc.errno == errno.ENOENT:
            return None
        if exc.errno in (errno.ELOOP, errno.EMLINK):
            raise ContainmentError(f"{rel}: is a symlink and is never replaced") from exc
        raise RenderError(f"{rel}: cannot open to check the marker ({exc.strerror})") from exc
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise ContainmentError(f"{rel}: is not a regular file")
        existing = _read_all(fd).decode("utf-8", "replace")
        if require_marker and not marker_mod.at_canonical_position(rel, existing):
            raise RenderError(
                f"{rel}: carries no {MARKER_TOKEN!r} marker at its canonical position, so "
                "it is the repo's own file and render will not replace it — run `adopt` "
                "to take it over. A marker further down the file is quoted content, not "
                "ownership"
            )
        return _identity(st)
    finally:
        os.close(fd)


def replace(root_fd, rel, data, require_marker=True):
    """Replace `rel` with `data`, atomically, behind the marker gate."""
    if isinstance(data, str):
        data = data.encode("utf-8")
    parts = _components(rel)
    dir_fd, leaf = _walk_to_parent(root_fd, parts, create=True)
    tmp = f".{leaf}.bot-instructions-tmp.{os.getpid()}"
    try:
        before = _gate(dir_fd, leaf, rel, require_marker)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644, dir_fd=dir_fd)
        try:
            os.write(fd, data)
            os.fsync(fd)
        finally:
            os.close(fd)
        try:
            _recheck(dir_fd, leaf, rel, before)
            os.rename(tmp, leaf, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        except BaseException:
            _unlink_quiet(dir_fd, tmp)
            raise
        _fsync_dir(dir_fd)
    finally:
        os.close(dir_fd)


def _recheck(dir_fd, leaf, rel, before):
    try:
        st = os.stat(leaf, dir_fd=dir_fd, follow_symlinks=False)
    except OSError as exc:
        if exc.errno == errno.ENOENT:
            now = None
        else:
            raise RenderError(f"{rel}: cannot re-check before the rename ({exc.strerror})") from exc
    else:
        if stat.S_ISLNK(st.st_mode):
            raise ContainmentError(f"{rel}: became a symlink between the gate and the write")
        now = _identity(st)
    if now != before:
        raise RenderError(
            f"{rel}: changed between the marker check and the write; nothing was "
            "replaced at that path. Re-run render."
        )


def _unlink_quiet(dir_fd, name):
    try:
        os.unlink(name, dir_fd=dir_fd)
    except OSError:
        pass


def _fsync_dir(dir_fd):
    try:
        os.fsync(dir_fd)
    except OSError:
        pass


class RenderLock:
    """One render at a time. A second one refuses rather than interleaving."""

    def __init__(self, root_fd):
        self.root_fd = root_fd
        self.fd = None

    def __enter__(self):
        _ensure_run_dir(self.root_fd)
        rel = f"{RUN_DIR}/{LOCK_NAME}"
        dir_fd, leaf = _walk_to_parent(self.root_fd, _components(rel), create=True)
        try:
            try:
                self.fd = os.open(leaf, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644, dir_fd=dir_fd)
            except OSError as exc:
                if exc.errno == errno.EEXIST:
                    raise LockError(
                        f"another render holds {rel}. If no render is running, that lock "
                        "is from an interrupted one: read it, then delete it."
                    ) from exc
                raise RenderError(f"{rel}: cannot lock ({exc.strerror})") from exc
            os.write(self.fd, f"pid {os.getpid()}\n".encode())
        finally:
            os.close(dir_fd)
        return self

    def __exit__(self, *_exc):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
        # Releasing must not raise: an exception here would replace whatever
        # the render was already failing on with a worse-diagnosed one.
        _remove(self.root_fd, f"{RUN_DIR}/{LOCK_NAME}")
        return False


def _ensure_run_dir(root_fd):
    try:
        os.mkdir(RUN_DIR, 0o755, dir_fd=root_fd)
    except OSError as exc:
        if exc.errno != errno.EEXIST:
            raise RenderError(f"{RUN_DIR}: cannot create ({exc.strerror})") from exc


MANIFEST_REL = f"{RUN_DIR}/{MANIFEST_NAME}"


def write_manifest(root_fd, paths):
    """Record every path about to be replaced, before the first replacement.

    A failure part way through leaves this behind, so a re-run finishes the
    set and `check` reds on every path still carrying the old bytes until it
    does.
    """
    _ensure_run_dir(root_fd)
    body = json.dumps({"pending": list(paths)}, indent=2, sort_keys=True) + "\n"
    replace(root_fd, MANIFEST_REL, body, require_marker=False)


def read_manifest(root_fd):
    from .fsutil import read_text

    raw = read_text(root_fd, MANIFEST_REL)
    if raw is None:
        return None
    try:
        return json.loads(raw).get("pending", [])
    except ValueError as exc:
        raise RenderError(f"{MANIFEST_REL}: unparseable ({exc})") from exc


def clear_manifest(root_fd):
    _remove(root_fd, MANIFEST_REL)


def _remove(root_fd, rel):
    """Best-effort unlink of a path this package created under RUN_DIR."""
    from .fsutil import _Missing

    try:
        dir_fd, leaf = _walk_to_parent(root_fd, _components(rel))
    except (_Missing, ContainmentError, OSError):
        return
    try:
        _unlink_quiet(dir_fd, leaf)
    finally:
        os.close(dir_fd)
