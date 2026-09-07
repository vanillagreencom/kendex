#!/usr/bin/env bash
# Pins for the code paths that only exist AT A TERMINAL. The runners invoke
# every other suite headless, where `mv` never prompts and plain `mv` measures
# exactly as `mv -f` does, which is how a prompting install shipped green.
# Every case here runs under a pseudo-terminal through lib/pty.bash; the rules
# such a probe follows, and why, are in
# ../DEVELOPMENT.md § Probing a terminal-only code path. Two tables: the
# probe itself (a session body run at the cap, pinned by its state, status
# and output), and gg_install_file at a terminal (a lib tree, a source and a
# read-only destination, pinned by the session's line and what the
# destination holds after). The abandonment pair beside them needs a runner
# killed mid-session, so it stays scripted.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# shellcheck source=lib/pty.bash
. "$TEST_DIR/lib/pty.bash"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
LIB="$SKILL_DIR/scripts/lib"
ROOT="$TMP"

PASS=0
FAIL=0
assert_eq() { # LABEL EXPECT ACTUAL
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
  fi
}
filemode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# One line for a session: its state, its own status and every line it
# printed joined by ';', or `unstarted` with the reason no session ran.
# ENVS is a comma-separated list of assignments exported for the run only;
# mktemp's own words are normalised, GNU and BSD phrase them apart. The
# probe's own stdin holds a line: a spawner that forwarded it instead of
# reading /dev/null would hand it to the session's prompt.
pty_line() { # CAP CASE_FILE ENVS
  local envs=()
  [ -z "$3" ] || IFS=',' read -ra envs <<<"$3"
  (
    [ "${#envs[@]}" -eq 0 ] || export "${envs[@]}"
    if gg_pty_run "$1" "$2"; then
      printf 'state=%s rc=%s out=%s' "$GG_PTY_STATE" "$GG_PTY_RC" "$(printf '%s\n' "$GG_PTY_OUT" | LC_ALL=C paste -sd ';' -)"
    else
      printf 'unstarted err=%s' "$(printf '%s' "$GG_PTY_ERR" | sed 's/mktemp: .*/mktemp: <its words>/')"
    fi
  ) <<<"TYPED AT THE SUITE"
}

# State functions a row names: their tokens are appended after ' / '.
child() { # the process the session recorded in GG_T_PIDFILE: gone, alive, or never recorded
  local pid
  pid="$(cat "$GG_T_PIDFILE" 2>/dev/null || true)"
  if [ -z "$pid" ]; then printf 'child=unrecorded'
  elif kill -0 "$pid" 2>/dev/null; then printf 'child=alive'
  else printf 'child=gone'
  fi
}
# On a healthy run the caller's cap fires first, so the session's own
# watchdog leaves no marker beside the body: that absence says which kill it was.
capped() { child; [ -f "$GG_T_BODY.watchdog" ] && printf ' watchdog=fired' || printf ' watchdog=none'; }
unpwned() { [ -e "$ROOT/PWNED" ] && printf 'pwned=yes' || printf 'pwned=no'; }

# A `script` that answers neither grammar, first on PATH for one row.
mkdir -p "$ROOT/noscript"
printf '#!/bin/sh\necho "script: not this grammar"\nexit 1\n' >"$ROOT/noscript/script"
chmod +x "$ROOT/noscript/script"

# Table one: BODY is the session, written through printf %b (a pipe is
# \174); the row's pid file reaches it as GG_T_PIDFILE.
ROW=0
pty_rows() { # label | cap | envs | body | state | expect
  local row label cap envs body state expect actual
  for row in "$@"; do
    IFS='|' read -r label cap envs body state expect <<<"$row"
    ROW=$((ROW + 1))
    export GG_T_PIDFILE="$ROOT/pty-$ROW.pid"
    GG_T_BODY="$ROOT/pty-$ROW.sh"
    printf '%b' "$body" >"$GG_T_BODY"
    actual="$(pty_line "$cap" "$GG_T_BODY" "$envs")"
    [ -z "$state" ] || actual="$actual / $($state)"
    assert_eq "$label" "$expect" "$actual"
  done
}

echo "=== gg_pty_run: the probe rules the install cases depend on ==="
pty_rows \
  'stdin, stdout and stderr are all on the pty|20||[ -t 0 ] && [ -t 1 ] && [ -t 2 ] && echo ALL-THREE\n||state=ok rc=0 out=ALL-THREE' \
  'a read from the terminal gets EOF instead of waiting: the spawner reads /dev/null|20||read -r answer </dev/tty && echo "READ $answer" \174\174 echo EOF-AT-THE-PROMPT\n||state=ok rc=0 out=EOF-AT-THE-PROMPT' \
  'control: a session that never returns is capped by the caller with its output kept, and the child it started is reaped|2||trap "" HUP\necho STARTED\nsleep 300 &\necho "$!" >"$GG_T_PIDFILE"\nwait\n|capped|state=capped rc= out=STARTED / child=gone watchdog=none' \
  "control: a session's own exit status survives the spawner|20||exit 7\n||state=ok rc=7 out=" \
  'control: a session that dies before its last line is gone and reports no status|20||echo ABOUT-TO-DIE\nkill -9 "$PPID"\nsleep 5\n||state=gone rc= out=ABOUT-TO-DIE' \
  "a script answering neither grammar is no session, named with what it said|20|PATH=$ROOT/noscript:$PATH|echo NEVER\n||unstarted err=no working pty spawner: script started no session. It said: script: not this grammar" \
  "a scratch root that cannot be made is no session, naming TMPDIR|20|TMPDIR=$ROOT/absent|echo NEVER\n||unstarted err=could not create a scratch directory under TMPDIR ($ROOT/absent): mktemp: <its words>"

# Table two: gg_install_file at a terminal. A fixture sets the lib tree the
# session sources (LIBD), the source (SRC), the read-only destination under
# R, and the TMPDIR the probe runs under (PTY_TMP). The case file goes BESIDE
# the source: gg_pty_run runs it as `bash %q`, so a hostile SRC drives that
# line's quoting too. The session refuses its own premise with a status of
# its own (3: no terminal; 4: the destination is writable, which is every
# run at euid 0) and prints REACHED with the source it was handed before
# the call, so a negative pin cannot be met by a case that never entered the
# code under test, and the name that reached it is the one the fixture chose.
install_line() { # LIBD SRC PTY_TMP
  local case_file="${2%/*}/pty-case.sh" line
  {
    printf 'set -euo pipefail\n'
    printf 'cd %q\n' "$R"
    printf 'GG_CHECK=probe\n'
    # C, because a row matches mv's own prompt and coreutils translates it.
    printf 'export LC_ALL=C\n'
    printf '[ -t 0 ] || { echo NOT-A-TERMINAL; exit 3; }\n'
    printf '[ ! -w tools/dest.tsv ] || { echo DESTINATION-IS-WRITABLE; exit 4; }\n'
    printf 'SRC=%q\n' "$2"
    printf '. %q\n' "$1/common.sh"
    printf '. %q\n' "$1/atomic-install.sh"
    printf 'echo "REACHED $SRC"\n'
    printf 'gg_tmpdir; gg_install_file "$SRC" tools/dest.tsv "the fixture"\n'
  } >"$case_file"
  line="$(pty_line 20 "$case_file" "TMPDIR=$3")"
  printf '%s / dest=%s mode=%s staged=%s' "$line" "$(cat "$R/tools/dest.tsv")" "$(filemode "$R/tools/dest.tsv")" \
    "$(find "$R/tools" -name '*gg-install*' | wc -l | tr -d ' ')"
}
# A read-only destination under R carrying CONTENT. The denial is the premise
# of every row: where it is not enforced the suite measures nothing, and says
# so once here rather than accusing the code under test.
dest() { # NAME CONTENT
  R="$ROOT/$1"
  mkdir -p "$R/tools"
  printf '%s\n' "$2" >"$R/tools/dest.tsv"
  chmod 444 "$R/tools/dest.tsv"
  [ ! -w "$R/tools/dest.tsv" ] || { echo "harness: $R/tools/dest.tsv is writable to euid $(id -u); a permission denial is not enforced here and the terminal cases cannot measure their branch" >&2; exit 2; }
}
fx_real() { dest real ORIGINAL; SRC="$ROOT/real-src.tsv"; printf 'REPLACED AT A TERMINAL\n' >"$SRC"; LIBD="$LIB"; PTY_TMP="$TMPDIR"; }
# The must-fail control: the same probe against a copy of the helper with the
# `-f` taken back out. The WHOLE lib tree is copied: common.sh bootstraps its
# neighbours off its own directory, so a mutant sited elsewhere dies at its
# first source line, before gg_install_file exists.
fx_no_f() {
  dest no-f 'NOT REPLACED'
  SRC="$ROOT/no-f-src.tsv"
  printf 'REPLACED AT A TERMINAL\n' >"$SRC"
  cp -R "$LIB" "$ROOT/lib-no-f"
  sed 's/mv -f -- /mv -- /' "$LIB/atomic-install.sh" >"$ROOT/lib-no-f/atomic-install.sh"
  LIBD="$ROOT/lib-no-f"
  PTY_TMP="$TMPDIR"
}
# A scratch root and a source whose NAMES are a space and a command
# substitution: pty.bash hands the spawner a constant command and passes its
# paths in the environment, so what this drives is the case body install_line
# writes, which bash reads. Unquoted there, the substitution runs.
HOSTILE="$ROOT/a q\$(touch $ROOT/PWNED)x dir"
fx_hostile() {
  dest hostile ORIGINAL
  mkdir -p "$HOSTILE"
  SRC="$HOSTILE/src.tsv"
  printf 'FROM A HOSTILE PATH\n' >"$SRC"
  cp -R "$LIB" "$HOSTILE/lib"
  rm -f "$ROOT/PWNED"
  LIBD="$HOSTILE/lib"
  PTY_TMP="$HOSTILE"
}
# Where mv reports the decline, the decline's own words are the evidence:
# GNU mv prompts, reads EOF, exits 1, and gg_install_why folds the prompt
# into the refusal. BSD mv answers its prompt's EOF as no and exits 0, so the
# helper reads a success, leaves the destination alone and its staging file
# beside it, which is the leak the `-f` closes there. Keyed on uname, the
# way pty.bash selects its grammar.
case "$(uname -s)" in
  Darwin) NO_F="state=ok rc=0 out=REACHED $ROOT/no-f-src.tsv / dest=NOT REPLACED mode=444 staged=1" ;;
  *) NO_F="state=ok rc=2 out=REACHED $ROOT/no-f-src.tsv;::error::probe: could not replace the fixture at tools/dest.tsv (mv: replace 'tools/dest.tsv', overriding mode 0444 (r--r--r--)? ) — inspect the file before trusting it / dest=NOT REPLACED mode=444 staged=0" ;;
esac
install_rows() { # label | fixture | state | expect
  local row label fx state expect actual
  for row in "$@"; do
    IFS='|' read -r label fx state expect <<<"$row"
    R=""
    "$fx"
    actual="$(install_line "$LIBD" "$SRC" "$PTY_TMP")"
    [ -z "$state" ] || actual="$actual / $($state)"
    assert_eq "$label" "$expect" "$actual"
  done
}

echo "=== gg_install_file: a read-only destination is replaced at a terminal too ==="
install_rows \
  "the install lands, and the destination keeps its mode|fx_real||state=ok rc=0 out=REACHED $ROOT/real-src.tsv / dest=REPLACED AT A TERMINAL mode=444 staged=0" \
  "control: without the -f the same probe leaves the destination unreplaced, the refusal carrying mv's own prompt|fx_no_f||$NO_F" \
  "control: a path that is a space and a command substitution stays a path, and nothing inside it runs|fx_hostile|unpwned|state=ok rc=0 out=REACHED $ROOT/a q\$(touch $ROOT/PWNED)x dir/src.tsv / dest=FROM A HOSTILE PATH mode=444 staged=0 / pwned=no"

echo "=== an abandoned session ends itself ==="
# A suite killed mid-run takes the poll loop with it, and `script` has
# already setsid'd the session out of every group that killer could name, so
# the cap on this side stops existing. What is left is the deadline the
# session holds over itself. The body traps HUP and TERM away, so nothing
# short of the SIGKILL that deadline sends can end it, and the marker beside
# the body is written by that watchdog alone: a dead child is also what a
# collapsing spawner leaves, so the marker is what says WHICH kill fired. The
# in-session kill runs under /bin/sh, dash on the CI runner, so the marker is
# the dash measurement too.
cat >"$ROOT/abandon-runner.sh" <<'RUNNER'
set -euo pipefail
. "$1"
gg_pty_run 2 "$2" || true
RUNNER
# Run a case under PTY_LIB through a runner, kill the runner once the session
# has a child to leave behind, wait up to SECONDS for that child to go, and
# report it with the watchdog marker. The session's group is reaped before
# the line is returned, by the group the session recorded: a run that timed
# out waiting for the pid file has no child handle, and that is exactly the
# run with nothing else to reap by. The cap is 2 and the session's deadline
# sits five seconds past it; the seconds are slack for a loaded box.
abandon_line() { # PTY_LIB NAME SECONDS
  local lib="$1" body="$ROOT/abandon-$2.sh" pidfile="$ROOT/abandon-$2.pid" scratch runner i=0 pid group="" state watchdog
  printf 'trap "" HUP TERM\necho STARTED\nsleep 300 &\necho "$!" >%q\nwait\n' "$pidfile" >"$body"
  scratch="$(mktemp -d "$ROOT/abandon-$2.XXXXXX")"
  TMPDIR="$scratch" bash "$ROOT/abandon-runner.sh" "$lib" "$body" >/dev/null 2>&1 &
  runner=$!
  while [ "$i" -lt 60 ] && [ ! -s "$pidfile" ]; do
    sleep 0.25
    i=$((i + 1))
  done
  kill -9 "$runner" 2>/dev/null || true
  wait "$runner" 2>/dev/null || true
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  group="$(cat "$scratch"/gg-pty.*/sid 2>/dev/null | tr -dc '0-9' || true)"
  state=child=unrecorded
  if [ -n "$pid" ]; then
    state=child=alive
    i=0
    while [ "$i" -lt "$3" ]; do
      if ! kill -0 "$pid" 2>/dev/null; then state=child=gone; break; fi
      sleep 1
      i=$((i + 1))
    done
  fi
  [ -f "$body.watchdog" ] && watchdog=fired || watchdog=none
  # bash, so `--` guards a group id; the session-side kill cannot use it and says why.
  [ -z "$group" ] || kill -9 -- "-$group" 2>/dev/null || true
  printf '%s watchdog=%s' "$state" "$watchdog"
}
# The must-fail control: a copy of pty.bash whose watchdog never starts.
# Without it the session outlives the run, which is the leak; the pinned
# `alive` after the deadline is reachable only from a copy the edit took.
NO_DEADLINE="$ROOT/pty-no-deadline.bash"
sed 's/if \[ -n "$gg_pgid" \]; then/if false; then/' "$TEST_DIR/lib/pty.bash" >"$NO_DEADLINE"
assert_eq "the session ends itself once the run that started it is gone, by its own deadline" "child=gone watchdog=fired" "$(abandon_line "$TEST_DIR/lib/pty.bash" real 20)"
assert_eq "control: without that deadline the abandoned session is still running past it" "child=alive watchdog=none" "$(abandon_line "$NO_DEADLINE" mutant 12)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
