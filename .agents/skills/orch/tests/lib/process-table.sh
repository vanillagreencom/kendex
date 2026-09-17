# shellcheck shell=bash
#
# The process table a wake row reads, owned in ONE place.
#
# `lane_session_state` (orch/scripts/open-terminal) answers from two readers of
# THIS MACHINE: `ps -A`, over every process named for the harness on the box,
# and `readlink /proc/<pid>/cwd` for each one it finds. It refuses the whole
# lane as `unjudged` on the first pid whose cwd it cannot read. A colleague's
# Claude Code session, or a root-owned one, is such a pid, so an unstubbed row
# answers by whoever else is logged in — and the pre-commit chain and
# `.github/workflows/skill-tests.yml` both run the suites holding these rows.
# A row that instead waits for its OWN fixture process to appear in the host's
# table is the same dependence wearing a timeout: the wait gives up and the row
# proceeds against a table its process never reached.
#
# Those two commands are the whole of that reading, and nothing else a wake
# reaches calls either, so the pair is the whole of the isolation. Stubbing it
# turns a row's process precondition into a table written here, stated up front
# and true at the instant the wake reads it.
#
# A row needing a REAL process — one whose `/proc/<pid>/environ` the wake reads,
# which no table stands in for — keeps it, names that pid in the table, and
# asserts the pid before the wake rather than waiting for `ps` to show it.
#
# Sourced, never run.

# proc_table_install DIR — write the stub pair into DIR. Put DIR on the PATH of
# the wake under test and export these three beside it:
#
#   PROC_TABLE        the file `ps` prints, one `PID PPID COMM` row per line
#   PROC_CWD_FILE     optional `PID<TAB>CWD` lines; a pid listed here gets that
#                     cwd from `readlink`, which is how a row states a process
#                     sitting in the lane's worktree without starting one
#   PROC_HIDDEN_PIDS  optional space-separated pids whose /proc cwd `readlink`
#                     refuses, the shape a root-owned session leaves
#
# `readlink` defers to the real reader for every path no row claims, so the stub
# never breaks the rest of the wake. The last argument is the path, read off a
# loop rather than `${@: -1}`, which the Bash 3.2 floor does not promise.
proc_table_install() { # DIR
  mkdir -p "$1"
  cat > "$1/ps" <<'PS_STUB'
#!/usr/bin/env bash
cat -- "${PROC_TABLE:?proc-table: PROC_TABLE names no file}"
PS_STUB
  cat > "$1/readlink" <<'READLINK_STUB'
#!/usr/bin/env bash
last=""
for a in "$@"; do last="$a"; done
for p in ${PROC_HIDDEN_PIDS:-}; do
  [[ "$last" != "/proc/$p/cwd" ]] || exit 1
done
if [[ -n "${PROC_CWD_FILE:-}" && -f "${PROC_CWD_FILE:-}" && "$last" == /proc/*/cwd ]]; then
  claimed="${last#/proc/}"
  claimed="${claimed%/cwd}"
  # The file arrives on stdin: `--` after an awk program is read as a FILENAME,
  # not as an end-of-options marker, and a redirect needs neither.
  if answer="$(awk -F'\t' -v p="$claimed" '$1 == p { print $2; f = 1; exit } END { if (!f) exit 1 }' < "$PROC_CWD_FILE")"; then
    printf '%s\n' "$answer"
    exit 0
  fi
fi
exec /usr/bin/readlink "$@"
READLINK_STUB
  chmod +x "$1/ps" "$1/readlink"
}

# proc_table_write FILE ROW... — replace FILE with one `PID PPID COMM` row per
# argument. No argument writes an empty table: the box runs no harness at all,
# which is the precondition of every row expecting the wake to go through.
proc_table_write() { # FILE ROW...
  local file="$1" row
  shift
  : > "$file"
  for row in ${1+"$@"}; do printf '%s\n' "$row" >> "$file"; done
}

# proc_cwd_write FILE PID=CWD... — replace FILE with one `PID<TAB>CWD` line per
# argument, the cwd `readlink` answers for that pid.
proc_cwd_write() { # FILE PID=CWD...
  local file="$1" entry
  shift
  : > "$file"
  for entry in ${1+"$@"}; do
    printf '%s\t%s\n' "${entry%%=*}" "${entry#*=}" >> "$file"
  done
}
