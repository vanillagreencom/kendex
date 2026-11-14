"""One tmux socket folder per test run, emptied when the run ends.

The runtime passes its tmux calls an environment without TMUX_TMPDIR
(session.py environment()), so the variable alone would not reach the
servers it starts. A `tmux` shim first on PATH sets it on every call
instead: tests and runtime alike resolve tmux through PATH, and every
fixture that starts tmux builds its PATH from this process's. At exit, pass or fail, every server
in the folder is stopped and the folder is removed, and so when SIGTERM ends the run, as the
battery runner stops an overdue suite.
"""
import atexit
import os
from pathlib import Path
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

SCOPE = "JARVIS_TEST_TMUX_SCOPE"


def isolate():
    # A test process its run starts keeps the run's folder: the run's exit
    # stops what both started.
    if os.environ.get(SCOPE):
        return
    real = shutil.which("tmux")
    # Without tmux no row can start a server; rows that need one refuse on their own.
    if real is None:
        return
    # A socket path fits 104 bytes on macOS. Where TMPDIR is too long for one
    # (macOS's per-user folder, a lane's worktree tmp/), /tmp holds the
    # folder; the budget leaves 56 bytes for a server label, past the
    # suites' longest, "jarvis-" + 32 hex + "-unrelated".
    base = tempfile.gettempdir()
    if len(base) + len("/jarvis-tmux-XXXXXXXX/sockets/tmux-%d/" % os.getuid()) + 56 > 104:
        base = "/tmp"
    root = Path(tempfile.mkdtemp(prefix="jarvis-tmux-", dir=base))
    sockets, shims = root / "sockets", root / "bin"
    sockets.mkdir()
    shims.mkdir()
    (shims / "tmux").write_text("#!/bin/sh\nTMUX_TMPDIR=%s exec %s \"$@\"\n" % (shlex.quote(str(sockets)), shlex.quote(real)))
    (shims / "tmux").chmod(0o755)
    os.environ.update({SCOPE: str(root), "TMUX_TMPDIR": str(sockets),
                       "PATH": str(shims) + os.pathsep + os.environ["PATH"]})
    owner = os.getpid()
    # SIGKILL runs no exit and no handler. The guard, in a session of its own
    # and deaf to the signals a terminal or a runner sends the run's group,
    # reads a pipe whose one writer is this process: the run's exit writes the
    # word that lets it go, and the end of file alone, which the kernel gives
    # however this process ends, makes it release the folder. It shares the
    # run's stderr, so a caller reading that to its end waits for the release.
    watch = ("import os, signal, sys\n"
             "from pathlib import Path\n"
             "for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):\n"
             "    signal.signal(signum, signal.SIG_IGN)\n"
             "if not sys.stdin.buffer.read() and Path(sys.argv[2]).is_dir():\n"
             "    sys.path.insert(0, sys.argv[1])\n"
             "    from tmux_scope import release\n"
             "    release(Path(sys.argv[2]), sys.argv[3], os.getpid())\n")
    guard = subprocess.Popen([sys.executable, "-I", "-c", watch, str(Path(__file__).resolve().parent), str(root), real],
                             stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, start_new_session=True)
    # Registered first, so it runs after the release.
    atexit.register(guard.communicate, b"released")
    atexit.register(release, root, real, owner)
    # SIGTERM's default action skips atexit. A disposition the caller set stands.
    if signal.getsignal(signal.SIGTERM) == signal.SIG_DFL:
        signal.signal(signal.SIGTERM, lambda signum, frame: terminated(root, real, owner, signum))
    return guard


def serving(path):
    with socket.socket(socket.AF_UNIX) as probe:
        try:
            probe.connect(str(path))
        except (FileNotFoundError, ConnectionRefusedError):
            return False
    return True


def terminated(root, real, owner, signum):
    # SystemExit would not end the run: unittest records it as a row error and
    # goes on. The default action ends it with the signal's own status, and a
    # second SIGTERM during the release ends it at once.
    signal.signal(signum, signal.SIG_DFL)
    try:
        release(root, real, owner)
    finally:
        os.kill(os.getpid(), signum)


def release(root, real, owner):
    # A forked child that exits through Python runs this too; only the run's own process releases.
    if os.getpid() != owner:
        return
    servers = sorted((root / "sockets").glob("tmux-*/*"))
    for server in servers:
        subprocess.run([real, "-S", str(server), "kill-server"], capture_output=True, timeout=10)
    # kill-server returns before its server exits; a server that ended no longer accepts a connection.
    deadline = time.monotonic() + 10
    while any(serving(server) for server in servers):
        if time.monotonic() > deadline:
            # Keep the folder: removing a live server's socket strands it unreachable.
            print("tmux-scope: server-left folder=" + str(root), file=sys.stderr)
            return
        time.sleep(0.05)
    shutil.rmtree(root)
