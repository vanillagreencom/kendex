# shellcheck shell=bash
# Running a case AT A TERMINAL. Sourced by terminal-paths.test.sh after
# lib/harness.bash, and by nothing else: the pty is what one suite needs, not
# setup every suite pays for at source time.
#
# Declared here rather than inherited from harness.bash, which sets the same:
# every helper below is written for errexit — the `|| true` guards around the
# kills exist because of it — and a library that needs a mode says so.
set -euo pipefail

# A suite run with stdin off a terminal cannot reach a branch that only
# exists at a tty, so a probe written headless measures nothing there: `mv`
# prompts before replacing a destination that denies write ONLY at a tty,
# which is the whole reason gg_install_file passes -f. Probed headless, plain
# `mv` and `mv -f` measure the same, and reverting the -f survives every
# OTHER suite in this family. Where a suite's own stdin IS a terminal the
# branch is live and unguarded: index-reads.test.sh installs onto a 0444
# destination, and with the -f reverted such a run reaches the prompt and
# waits for a person.
#
# gg_pty_run runs a bash script file with fds 0, 1 and 2 on a pseudo-terminal.
# Two rules make such a probe safe to run, and both are why there is one
# helper rather than a `script` line per suite:
#
#   Stdin redirected. The SPAWNER reads /dev/null, so a prompt inside the
#   session is answered by EOF the moment it is written and the session
#   returns instead of waiting for a person who is not there. WHAT it returns
#   differs by platform, which is why a case asserts on the destination.
#
#   A time cap. The session is killed after CAP seconds and reported as
#   GG_PTY_STATE=capped. A probe that HANGS yields no measurement at all, so
#   a mutation run scores it as "not killed" and prints a silent miss instead
#   of a wedge. The teardown kills the session's own process group, because
#   `script` puts the session in a group of its own and killing the spawner
#   alone leaves the stuck child behind.
#
# What a call sets:
#
#   GG_PTY_STATE  ok      the session ran to its own end; GG_PTY_RC is its status
#                 capped  the cap fired and the session was killed
#                 gone    the session died before its own last line
#   GG_PTY_RC     the session's own exit status, and EMPTY in any other state,
#                 so a caller reading it past a cap gets a loud comparison
#                 error rather than a zero that reads as success. The helper
#                 owns no status values of its own: a probe may exit anything.
#   GG_PTY_OUT    the session's own output (gg_pty_capture)
#
# A non-zero return means the call never started. GG_PTY_ERR then names why,
# and no working `script` is one such cause — a RED rather than a skip, since
# a case that cannot reach the terminal branch is not covering it. This file
# spawns through util-linux `script -qec` alone, so a host whose `script` does
# not answer that grammar is exactly such a host.
#
# What a case may assert:
#
#   The EFFECT the branch has, not the spawner's status. Whether the
#   destination was replaced is what the branch does; a status is what one
#   `mv` on one host chose to say about it. GG_PTY_STATE=ok is the separate
#   claim that the probe ran rather than wedged.
#
#   Positive evidence that the code under test was entered, paired with every
#   negative. An unreplaced destination is also what a session that never got
#   there leaves behind, which is why the mutant control echoes a marker
#   before the call it measures and requires it back.
#
#   The premise, inside the session. A destination that denies write is what
#   makes `mv` prompt, and at euid 0 mode 0444 is not enforced — so without
#   that check a root run covers nothing and says nothing.
#
# The status travels in a file because a status read off the spawner would
# mean something different per platform, and the output starts at a marker
# because a terminal writes into the typescript on its own account.

GG_PTY_RC=""
GG_PTY_OUT=""
GG_PTY_STATE=""
GG_PTY_ERR=""
GG_PTY_CAPPED=0

# Kill the group the SESSION runs in, then the spawner's. `script` calls
# setsid for the session, so it lives in a process group the spawner's group
# never names: killing the spawner alone leaves the stuck child behind, and a
# body that ignores SIGHUP survives the pty closing too.
#
# The session's group is read from the file its own first line wrote, because
# nothing on this side can derive it: the spawner is between us and it.
gg_pty_reap() { # SPAWNER_PID SID_FILE
  local group="" waited=0
  [ ! -f "$2" ] || group="$(tr -dc '0-9' <"$2" 2>/dev/null || true)"
  # The session first, while the timeout that named it is one instant old: a
  # pid read from a file is only as current as the process it came from.
  [ -z "$group" ] || kill -9 -- "-$group" 2>/dev/null || true
  # The spawner by group where job control gave it one, by bare pid where it
  # did not — the fallback is what makes the caller's `set -m` an optimisation
  # rather than a requirement.
  kill -9 -- "-$1" 2>/dev/null || kill -9 "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
  # Then wait for the group to go, up to 5s, before the caller removes the
  # scratch directory the session was running in. The bound stays — an
  # unbounded wait is the wedge this file exists to refuse.
  while [ -n "$group" ] && kill -0 -- "-$group" 2>/dev/null; do
    [ "$waited" -lt 50 ] || break
    sleep 0.1
    waited=$((waited + 1))
  done
}

# One capped spawn. util-linux `script -qec` is the only grammar here: the
# command goes to -e -c, and the spawner's own stdin is /dev/null so a prompt
# inside the session meets EOF instead of a person.
gg_pty_bounded() { # CAP_SECONDS SH_COMMAND SID_FILE OUT_FILE
  local cap="$1" cmd="$2" sidfile="$3" outfile="$4" pid ticks=0 limit
  GG_PTY_CAPPED=0
  limit=$((cap * 10))
  # Job control, which gives the spawner a process group of its own where the
  # platform provides one; gg_pty_reap falls back to the bare pid where it
  # does not. The session's group is a separate matter; see there.
  set -m
  script -qec "$cmd" /dev/null >"$outfile" 2>&1 </dev/null &
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$limit" ]; then
      gg_pty_reap "$pid" "$sidfile"
      GG_PTY_CAPPED=1
      return 0
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid" 2>/dev/null || true
}

# The session's own output: the typescript from the marker line on, with the
# pty's carriage returns dropped. A capture carrying no marker is handed back
# WHOLE — the session died before its first line, and hiding that behind an
# empty result would turn a spawn failure into a silent pass.
gg_pty_capture() { # TYPESCRIPT
  local raw
  raw="$(tr -d '\r' <"$1" 2>/dev/null || true)"
  case "$raw" in
    *GG-PTY-BEGIN*) GG_PTY_OUT="$(printf '%s\n' "$raw" | awk 'seen {print} /GG-PTY-BEGIN/ {seen = 1}')" ;;
    *) GG_PTY_OUT="$raw" ;;
  esac
}

gg_pty_run() { # CAP_SECONDS SCRIPT_FILE
  local cap="$1" body="$2" dir cmd
  GG_PTY_RC=""
  GG_PTY_OUT=""
  GG_PTY_STATE=""
  GG_PTY_ERR=""
  # 2>&1 rather than 2>/dev/null: on failure mktemp's own words ARE the cause,
  # and they land in $dir, which the branch below reads. On success mktemp
  # writes the path and nothing else. Named apart from the spawner, because a
  # caller told "no spawner" over a full or unwritable TMPDIR goes looking at
  # devpts for a scratch problem.
  dir="$(mktemp -d "$TMPDIR/gg-pty.XXXXXX" 2>&1)" || {
    GG_PTY_ERR="could not create a scratch directory under TMPDIR ($TMPDIR): $dir"
    return 1
  }
  # The session's own group, its output marker, and its status, in that order.
  #
  # The GROUP, first line, because gg_pty_reap cannot derive it from this side
  # and `$$` is not it: `script` runs the command through $SHELL, which need
  # not exec away.
  #
  # The MARKER is where the session's own output starts. What precedes it is
  # the TERMINAL's, not the script's, and it is also how this function knows a
  # session ran at all.
  #
  # The STATUS travels in a file, which doubles as the done marker.
  #
  # %q at every path written into a shell: $dir descends from TMPDIR and $body
  # from the caller, and an unquoted path with a space or a metacharacter
  # lands in a shell script as syntax rather than as a path.
  {
    printf 'ps -o pgid= -p $$ >%q 2>/dev/null || true\n' "$dir/sid"
    printf 'echo GG-PTY-BEGIN\n'
    printf 'bash %q\n' "$body"
    printf 'printf %%s\\\\n "$?" >%q\n' "$dir/rc"
  } >"$dir/session.sh"
  printf -v cmd '/bin/sh %q' "$dir/session.sh"
  gg_pty_bounded "$cap" "$cmd" "$dir/sid" "$dir/out"
  # No marker anywhere in the typescript means no session ran — the spawner
  # is absent, or does not answer this grammar. Its own words are the cause,
  # and they are the whole answer to "why did nothing happen here".
  if ! grep -q GG-PTY-BEGIN "$dir/out" 2>/dev/null; then
    GG_PTY_ERR="no working pty spawner: util-linux \`script -qec\` started no session. It said: $(tr -d '\r' <"$dir/out" 2>/dev/null || true)"
    rm -rf -- "${dir:?}"
    return 1
  fi
  gg_pty_capture "$dir/out"
  [ ! -f "$dir/rc" ] || GG_PTY_RC="$(cat "$dir/rc")"
  if [ "$GG_PTY_CAPPED" = 1 ]; then
    GG_PTY_STATE=capped
  elif [ -n "$GG_PTY_RC" ]; then
    GG_PTY_STATE=ok
  else
    # No status file: the session never reached its own last line. GG_PTY_RC
    # stays empty rather than standing in for one, so nothing here can be
    # mistaken for something the probe returned.
    GG_PTY_STATE=gone
  fi
  # A capped session never ran its last line, so a status found in its tree is
  # not one it chose to return.
  [ "$GG_PTY_STATE" = ok ] || GG_PTY_RC=""
  rm -rf -- "${dir:?}"
}
