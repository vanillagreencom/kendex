"""One process-counting fixture, shared by lane-mail and the watch suites."""

import os
from pathlib import Path
import shlex
import sys


def install(root, search_path, bash, target=None):
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
                            f"printf 'w %s %s %s %s\\n' '$$' \"$PPID\" {shlex.quote(executable.name)} "
                            f'"${{_KENDEX_PROCESS_COUNT_OWNER:-0}}" '
                            f">>{shlex.quote(str(root / 'external'))}; fi\n"
                            "unset _KENDEX_PROCESS_COUNT_OWNER\n"
                            f"exec {shlex.quote(str(executable))} \"$@\"\n".replace("'$$'", '"$$"'))
            dest.chmod(0o755)
    prefix = ""
    if target:
        prefix = (f"case \"$0\" in */{shlex.quote(Path(target).name)}) ;; *) return ;; esac\n"
                  f'printf "%s\\n" "$$" >{shlex.quote(str(root / "existing"))}\n'
                  '_KENDEX_PROCESS_COUNT_OWNER=$$; export _KENDEX_PROCESS_COUNT_OWNER\n')
    (root / "target").write_text(target or "")
    (root / "bash-env").write_text(
        prefix + f"exec 19>>{shlex.quote(str(root / 'trace'))}\n"
        "BASH_XTRACEFD=19\nPS4='+count:${BASHPID:-$$}: '\nset -x\n")
    (root / "bash").write_text(bash)
    (root / "active").write_text("yes\n")


def reset(root):
    for name in ("trace", "external", "existing"):
        (Path(root) / name).write_text("")


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


def total(trace, external, existing, direct=False, command=None):
    """Count synthetic or recorded IDs without querying live processes."""
    exec_pids = {line.split()[1] for line in external}
    bash_pids = set()
    for line in trace:
        if line == "count:end":
            break
        if line.startswith("+") and line.lstrip("+").startswith("count:"):
            bash_pids.add(line.lstrip("+").split(":", 2)[1])
    if not direct:
        return len(bash_pids - exec_pids - existing) + len(external)
    # Wrappers clear the target tag before exec, so a stub's own children
    # carry no ownership. A pipeline's parent shell can launch only external
    # commands and emit no trace; an owned wrapper still identifies that PID.
    births = (bash_pids - existing) if command is None else set()
    for line in external:
        _, pid, parent, name, owner = line.split()
        if owner in existing and pid not in existing:
            if command is None:
                births.add(pid)
                if parent not in existing:
                    births.add(parent)
            elif command == name:
                births.add(pid)
    return len(births)


def count(root, command=None):
    root = Path(root)
    external = (root / "external").read_text().splitlines() if (root / "external").exists() else []
    existing = set((root / "existing").read_text().splitlines()) if (root / "existing").exists() else set()
    trace = (root / "trace").read_text(errors="surrogateescape").splitlines()
    direct = (root / "target").exists() and bool((root / "target").read_text())
    print(total(trace, external, existing, direct, command))


if __name__ == "__main__":
    if sys.argv[1] == "install":
        install(*sys.argv[2:])
    elif sys.argv[1] == "watch":
        watch(*sys.argv[2:])
    elif sys.argv[1] == "reset":
        reset(sys.argv[2])
    else:
        count(*sys.argv[2:])
