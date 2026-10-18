"""One process-counting fixture, shared by lane-mail and the watch suites."""

import os
from pathlib import Path
import shlex
import sys


def install(root, search_path, bash, target=None, mode=None, *fixtures):
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
                            f"printf 'w %s %s %s %s\\n' \"$$\" \"$PPID\" {shlex.quote(executable.name)} "
                            f'"${{_KENDEX_PROCESS_COUNT_OWNER:-0}}" '
                            f">>{shlex.quote(str(root / 'external'))}; fi\n" +
                            (f"printf '%s %s %s %s\\n' \"$$\" \"$PPID\" \"${{_KENDEX_PROCESS_COUNT_OWNER:-0}}\" "
                             f"\"${{_KENDEX_PROCESS_COUNT_STEP:-outside}}\" >>{shlex.quote(str(root / 'steps'))}\n"
                             if mode in ("passes", "complete") else "") +
                            "unset _KENDEX_PROCESS_COUNT_OWNER\n"
                            f"exec {shlex.quote(str(executable))} \"$@\"\n")
            dest.chmod(0o755)
    prefix = ""
    if mode == "complete" and fixtures:
        fixture_pattern = "|".join(shlex.quote(str(Path(path))) + "/*" for path in fixtures)
        prefix = (f'case "$0" in {fixture_pattern})\n'
                  f'printf "%s %s fixture %s\\n" "$BASHPID" "$PPID" "${{_KENDEX_PROCESS_COUNT_STEP:-outside}}" >>{shlex.quote(str(root / "steps"))}\n'
                  'unset _KENDEX_PROCESS_COUNT_STEP _KENDEX_PROCESS_COUNT_OWNER\nset +x\nreturn ;; esac\n')
    if target:
        if mode == "passes":
            # Absolute Bash helpers bypass PATH wrappers. Record their entry,
            # then clear ownership before any fixture implementation runs.
            prefix = (f"case \"$0\" in */{shlex.quote(Path(target).name)}) ;; *)\n"
                      'if [[ ${_KENDEX_PROCESS_COUNT_OWNER:-0} != 0 ]]; then\n'
                      f"printf '%s %s %s %s\\n' \"$BASHPID\" \"$PPID\" \"$_KENDEX_PROCESS_COUNT_OWNER\" "
                      f"\"${{_KENDEX_PROCESS_COUNT_STEP:-outside}}\" >>{shlex.quote(str(root / 'steps'))}\n"
                      'fi\nunset _KENDEX_PROCESS_COUNT_OWNER\nreturn ;; esac\n')
        prefix += (f"case \"$0\" in */{shlex.quote(Path(target).name)}) ;; *) return ;; esac\n"
                  f'printf "%s\\n" "$$" >{shlex.quote(str(root / "existing"))}\n'
                  '_KENDEX_PROCESS_COUNT_OWNER=$$; export _KENDEX_PROCESS_COUNT_OWNER\n')
    (root / "target").write_text(target or "")
    (root / "bash-env").write_text(
        prefix + f"exec 19>>{shlex.quote(str(root / 'trace'))}\n"
        "BASH_XTRACEFD=19\nPS4='+count:${BASHPID:-$$}: '\nset -x\n")
    (root / "bash").write_text(bash)
    (root / "active").write_text("yes\n")
    if mode in ("passes", "complete"):
        (root / "steps").write_text("")
    if mode == "complete":
        with (root / "bash-env").open("a") as stream:
            stream.write('''
_pc_step() {
  local i
  case "$BASH_COMMAND" in
    mail_turn|long_pass)
      _KENDEX_PROCESS_COUNT_STEP=$BASH_COMMAND.fixture
      export _KENDEX_PROCESS_COUNT_STEP
      return ;;
  esac
  case "$0" in */oversee-watch)
    _KENDEX_PROCESS_COUNT_STEP=outside
    for ((i=1; i<${#FUNCNAME[@]}; i++)); do
      case ${FUNCNAME[$i]} in
        mail_turn|long_pass)
          _KENDEX_PROCESS_COUNT_STEP=${FUNCNAME[$i]}.fixture
          break ;;
      esac
    done
    export _KENDEX_PROCESS_COUNT_STEP ;;
  esac
}
set -T
trap _pc_step DEBUG
PS4='+count:${BASHPID:-$$}:${_KENDEX_PROCESS_COUNT_STEP:-outside}: '
''')
    elif mode == "passes":
        with (root / "bash-env").open("a") as stream:
            stream.write("""
_pc_step() {
  local i
  _KENDEX_PROCESS_COUNT_STEP=outside
  for ((i=1; i<${#FUNCNAME[@]}; i++)); do
    case ${FUNCNAME[$i]} in
      mail_turn|long_pass)
        _KENDEX_PROCESS_COUNT_STEP="${FUNCNAME[$i]}.${FUNCNAME[$((i > 1 ? i - 1 : i))]}"
        break ;;
    esac
  done
  export _KENDEX_PROCESS_COUNT_STEP
}
set -T
trap _pc_step DEBUG
PS4='+count:${BASHPID:-$$}:${_KENDEX_PROCESS_COUNT_STEP:-outside}: '
""")


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


def read_trace(root):
    return (Path(root) / "trace").read_text(errors="surrogateescape").splitlines()


def count(root, command=None):
    root = Path(root)
    external = (root / "external").read_text().splitlines() if (root / "external").exists() else []
    existing = set((root / "existing").read_text().splitlines()) if (root / "existing").exists() else set()
    trace = read_trace(root)
    direct = (root / "target").exists() and bool((root / "target").read_text())
    print(total(trace, external, existing, direct, command))



def pass_births(trace, external, existing, complete=False):
    """Attribute each target-owned birth to its pass and immediate step."""
    births = {}
    for line in trace:
        line = line.lstrip("+")
        if line.startswith("count:") and len(line.split(":", 3)) == 4:
            _, pid, step, _ = line.split(":", 3)
            if pid not in existing and step.startswith(("mail_turn.", "long_pass.")):
                births.setdefault(pid, step)
    for line in external:
        pid, parent, owner, step = line.split()
        if complete:
            owner = next(iter(existing), "0")
        if owner in existing and step.startswith(("mail_turn.", "long_pass.")):
            if pid not in existing:
                births[pid] = step
            if parent not in existing:
                births.setdefault(parent, step)
    if complete:
        rows = [line.split() for line in external]
        fixtures = {pid for pid, _, owner, _ in rows if owner == "fixture"}
        for _ in rows:
            changed = False
            for pid, parent, _, _ in rows:
                if pid not in births and parent in births and parent not in fixtures and pid not in existing:
                    births[pid] = births[parent]
                    changed = True
            if not changed:
                break
    return births


def pass_counts(trace, external, existing, complete=False):
    from collections import Counter
    return Counter(pass_births(trace, external, existing, complete).values())


def steps(root, complete=False):
    root = Path(root)
    counts = pass_counts(
        read_trace(root),
        (root / "steps").read_text().splitlines(),
        set((root / "existing").read_text().splitlines()),
        complete,
    )
    for step, value in sorted(counts.items()):
        print(f"{step}={value}")
    for name in ("mail_turn", "long_pass"):
        print(f"{name}={sum(value for step, value in counts.items() if step.startswith(name + '.'))}")
    if complete:
        from collections import Counter
        names = {line.split()[1]: line.split()[3] for line in (root / "external").read_text().splitlines()}
        commands = Counter()
        for pid, step in pass_births(read_trace(root), (root / "steps").read_text().splitlines(),
                                     set((root / "existing").read_text().splitlines()), True).items():
            commands[step.split(".", 1)[0], names.get(pid, "bash")] += 1
        for (step, name), value in sorted(commands.items()):
            print(f"{step} command={name} starts={value}")

if __name__ == "__main__":
    if sys.argv[1] == "install":
        install(*sys.argv[2:])
    elif sys.argv[1] == "steps":
        steps(sys.argv[2])
    elif sys.argv[1] == "complete-steps":
        steps(sys.argv[2], True)
    elif sys.argv[1] == "watch":
        watch(*sys.argv[2:])
    elif sys.argv[1] == "reset":
        reset(sys.argv[2])
    else:
        count(*sys.argv[2:])
