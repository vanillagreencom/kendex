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
# WHAT THE PAIR COVERS, stated once and pointed at rather than restated: the
# process table and the cwd read. A row's precondition for those two becomes a
# table written here, true at the instant the wake reads it.
#
# WHAT STILL REACHES THE HOST, so a row arranges it for itself:
#
#   /proc/<pid>       `lane_session_state` tests the directory to tell a process
#                     that exited from one whose cwd it may not read, and it
#                     answers `unjudged` for the whole lane before any of that
#                     when /proc itself is absent; `proc_table_readable` below
#                     is that condition, and a row on a box without /proc takes
#                     its expectation from the predicate rather than from a
#                     second copy of the test
#   /proc/<pid>/environ and the session file named after the pid — the claude
#                     arm reads both, so a row meaning `idle` keeps a REAL
#                     process, names that pid in the table, and asserts it
#                     before the wake rather than waiting for `ps` to show it
#   `pgrep -P`        `lane_state` runs it through `pane_has_child` when the
#                     pane's foreground command is a bare shell;
#                     lib/oversee-watch-harness.sh owns that stub, and a suite
#                     with a row reaching it sources that library as well
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
#
# The real reader is resolved HERE, and callers must therefore install before
# DIR reaches any PATH, or the stub would resolve itself. A hard-coded
# /usr/bin/readlink exits 127 on a host that keeps it elsewhere, a Nix profile
# or a stripped image among them, and every unclaimed /proc read would then
# fail: rows staging a pid with no cwd entry would read `unjudged` for a reason
# no row states.
proc_table_install() { # DIR
  local real_readlink
  real_readlink="$(command -v readlink)" ||
    { printf 'proc-table: no-readlink\nreadlink is not on PATH, so the stub has no reader to defer to\n' >&2; return 1; }
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
READLINK_STUB
  printf 'exec "%s" "$@"\n' "$real_readlink" >> "$1/readlink"
  chmod +x "$1/ps" "$1/readlink"
}

# proc_table_readable — 0 where the producer can read a process at all, 1 where
# it cannot. `lane_session_state` returns `unjudged` for the whole lane the
# moment it holds a harness-named pid on a box with no /proc, which is every
# macOS run, so a row expecting anything the producer can only reach by reading
# a process takes its expectation from here. The three shapes a caller needs are
# its own: rewrite the row's expectation, skip a mutant block, or swap an
# assertion. The test itself lives once, beside the table it belongs to.
proc_table_readable() {
  [[ -d /proc/self ]]
}

# proc_table_write FILE ROW... — replace FILE with one `PID PPID COMM` row per
# argument. No argument writes an empty table: the box runs no harness at all.
#
# What the producer reads is narrower than that, and it is what a row wanting
# its wake to go through must arrange: no process named for the harness whose
# /proc cwd is the lane's worktree. An empty table is one way to reach it; a
# table listing harness processes that sit elsewhere is another, and it is the
# one a row uses to show the producer walking past a stranger's session.
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
