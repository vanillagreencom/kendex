"""One process-counting fixture, shared by lane-mail and the watch suites."""

import os
from pathlib import Path
import shlex
import sys


def install(root, search_path, bash):
    root = Path(root)
    (root / "bin").mkdir(parents=True)
    for directory in search_path.split(os.pathsep):
        directory = Path(directory or ".").absolute()
        if not directory.is_dir():
            continue
        for executable in directory.iterdir():
            dest = root / "bin" / executable.name
            if dest.exists() or not executable.is_file() or not os.access(executable, os.X_OK):
                continue
            dest.write_text("#!/bin/sh\n"
                            f"if [ -s {shlex.quote(str(root / 'active'))} ]; then "
                            f"printf 'w %s %s\\n' '$$' {shlex.quote(executable.name)} "
                            f">>{shlex.quote(str(root / 'external'))}; fi\n"
                            f"exec {shlex.quote(str(executable))} \"$@\"\n".replace("'$$'", '"$$"'))
            dest.chmod(0o755)
    (root / "bash-env").write_text(
        f"exec 19>>{shlex.quote(str(root / 'trace'))}\n"
        "BASH_XTRACEFD=19\nPS4='+count:${BASHPID:-$$}: '\nset -x\n")
    (root / "bash").write_text(bash)
    (root / "active").write_text("yes\n")


def watch(root, mode):
    root = Path(root)
    (root / "active").write_text("")
    trace = shlex.quote(str(root / "trace"))
    external = shlex.quote(str(root / "external"))
    active = shlex.quote(str(root / "active"))
    existing = shlex.quote(str(root / "existing"))
    begin = 'mail_turn' if mode == "mail" else 'tick_wait'
    end = '[[ "$long_now" -eq 0 ]]' if mode == "mail" else 'run_end'
    with (root / "bash-env").open("a") as stream:
        stream.write("_pc_open=0\n_pc_count() {\ncase \"$BASH_COMMAND\" in\n"
                     f"{shlex.quote(begin)}) if [[ $_pc_open == 0 ]]; then "
                     f": >{trace}; : >{external}; printf yes >{active}; "
                     f'printf "%s\\n" "$BASHPID" >{existing}; _pc_open=1; fi ;;\n'
                     f"{shlex.quote(end)}) if [[ $_pc_open == 1 ]]; then printf '\\ncount:end\\n' >>{trace}; : >{active}; "
                     "set +x; _pc_open=2; fi ;;\nesac\n}\ntrap _pc_count DEBUG\n")


def count(root):
    root = Path(root)
    external = (root / "external").read_text().splitlines() if (root / "external").exists() else []
    exec_pids = {line.split()[1] for line in external}
    existing = set((root / "existing").read_text().splitlines()) if (root / "existing").exists() else set()
    bash_pids = set()
    for line in (root / "trace").read_text(errors="surrogateescape").splitlines():
        if line == "count:end":
            break
        if line.startswith("+") and line.lstrip("+").startswith("count:"):
            bash_pids.add(line.lstrip("+").split(":", 2)[1])
    print(len(bash_pids - exec_pids - existing) + len(external))


if __name__ == "__main__":
    if sys.argv[1] == "install":
        install(*sys.argv[2:])
    elif sys.argv[1] == "watch":
        watch(*sys.argv[2:])
    else:
        count(sys.argv[2])
