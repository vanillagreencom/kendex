"""Linux: lead a session on the terminal at fd 0 and run one command as its child.

op_fifo.run_work starts this file as a session leader under the app integration. The 1Password desktop app names
the session's top-level process in its approval prompt and aborts a call that has none, so op runs one level below
a leader that holds the terminal, as it does under a terminal shell.

Usage: python3 -I op_tty.py STATUS_FD COMMAND [ARG...]. A start that fails writes its errno to STATUS_FD; the exit
status is the command's own, and a command a signal ended ends this process with the same signal.
"""
import fcntl
import os
import signal
import subprocess
import sys
import termios


def main():
    status = int(sys.argv[1])
    # The command inherits every other descriptor run_work passed, a script's checked descriptor among them.
    os.set_inheritable(status, False)
    try:
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        child = subprocess.Popen(sys.argv[2:], stdin=subprocess.DEVNULL, close_fds=False)
    except OSError as error:
        os.write(status, str(error.errno).encode())
        return 127
    os.close(status)
    code = child.wait()
    if code < 0:
        signal.signal(-code, signal.SIG_DFL)
        signal.raise_signal(-code)
        # Only a signal whose default action ends the process ends a child.
        raise AssertionError("signal %d did not end op_tty.py" % -code)
    return code


if __name__ == "__main__":
    sys.exit(main())
