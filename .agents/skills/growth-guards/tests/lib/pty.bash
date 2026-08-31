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
#   of a wedge. gg_pty_reap takes the session's own process group, waits up
#   to 5s for it, and says so when it could not finish — `capped` is a claim
#   that the session is gone, and a reap that did not get there reports
#   `leaked` rather than making it.
#
# What a call sets:
#
#   GG_PTY_STATE  ok      the session ran to its own end; GG_PTY_RC is its status
#                 capped  the cap fired and the session's group is gone
#                 leaked  the cap fired and the reap did not finish; GG_PTY_ERR
#                         says which way, and the scratch tree is left in place
#                 gone    the session died before its own last line
#   GG_PTY_RC     the session's own exit status, and EMPTY in any other state,
#                 so a caller reading it past a cap gets a loud comparison
#                 error rather than a zero that reads as success. The helper
#                 owns no status values of its own: a probe may exit anything.
#   GG_PTY_OUT    the session's own output (gg_pty_capture)
#
# A non-zero return means the call never started, and GG_PTY_ERR then names
# why. No spawner is one such cause, and it is a red rather than a skip: a
# case that cannot reach the terminal branch is not covering it.
#
# What a case may assert:
#
#   The EFFECT the branch has, not the spawner's status. A `mv` answered no
#   exits 1 on GNU, which gg_install_why folds into gg_install_file's own
#   exit-2 diagnostic, and 0 on BSD, where the helper reports nothing at all.
#   The destination's content is the claim both platforms carry, and
#   GG_PTY_STATE=ok is the separate claim that the probe ran rather than
#   wedged.
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
# The two platforms diverge under the helper too, which is why it normalizes
# both: the status travels in a file because BSD `script` has no util-linux
# -e, and the output starts at a marker because BSD echoes the end-of-file
# this helper delivers into the typescript ahead of the session's first line.
# The grammar itself is chosen by running each and asking the session whether
# its own fds are a terminal, never by parsing a version banner.

# Resolved once per suite by gg_pty_form: the spawner grammar that really
# yields a tty here, or `none`.
GG_PTY_FORM=""
GG_PTY_RC=""
GG_PTY_OUT=""
GG_PTY_STATE=""
GG_PTY_ERR=""
GG_PTY_CAPPED=0
GG_PTY_REAPED=""

# `script` is the one pty spawner both platforms ship, under two incompatible
# grammars: util-linux takes the command as an argument to -e -c, BSD (macOS)
# takes it after the typescript file and has no -e at all.
gg_pty_spawn() { # FORM SH_COMMAND
  case "$1" in
    util-linux) script -qec "$2" /dev/null ;;
    bsd) script -q /dev/null /bin/sh -c "$2" ;;
  esac
}

# Kill the group the SESSION runs in, then the spawner's. Both `script`
# grammars call setsid for the session, so it lives in a session and a process
# group the spawner's group never names: killing the spawner alone leaves the
# stuck child behind, and a body that ignores SIGHUP survives the pty closing
# too. That orphan then outlives the scratch directory removed below, holding
# fds inside a deleted tree while the caller is told the cap worked.
#
# The session's group is read from the file its own first line wrote, because
# nothing on this side can derive it: the spawner is between us and it.
gg_pty_reap() { # SPAWNER_PID_OR_EMPTY SID_FILE — sets GG_PTY_REAPED
  local group="" waited=0
  GG_PTY_REAPED=yes
  [ ! -f "$2" ] || group="$(tr -dc '0-9' <"$2" 2>/dev/null || true)"
  if [ -n "$group" ]; then
    # The session first, while the timeout that named it is one instant old:
    # a pid read from a file is only as current as the process it came from.
    kill -9 -- "-$group" 2>/dev/null || true
  else
    # No group to take: the session died before its first line, or this
    # host's ps answers no -o pgid=. The spawner's goes below either way, but
    # that is not the session's, and a reap that took only the spawner is the
    # leak this function exists to report rather than the cap it looks like.
    GG_PTY_REAPED=no-group
  fi
  # The spawner by group where job control gave it one, by bare pid where it
  # did not — the fallback is what makes the caller's `set -m` an optimisation
  # rather than a requirement.
  if [ -n "$1" ]; then
    kill -9 -- "-$1" 2>/dev/null || kill -9 "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
  fi
  # The reap waits up to 5s for the group to go. A group still there after
  # that is REPORTED, not absorbed: the caller removes the scratch directory
  # next, and a live session holding fds inside it is the leak. The bound
  # stays — an unbounded wait is the wedge this file exists to refuse.
  while [ -n "$group" ] && kill -0 -- "-$group" 2>/dev/null; do
    if [ "$waited" -ge 50 ]; then
      GG_PTY_REAPED=timeout
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
}

# One capped spawn, used by every probe here — gg_pty_form's own included,
# since a spawner that blocks allocating a pty would otherwise wedge the suite
# before a single case ran, which is the rule this file states and may not
# drop for its own setup.
gg_pty_bounded() { # CAP_SECONDS FORM SH_COMMAND SID_FILE OUT_FILE
  local cap="$1" form="$2" cmd="$3" sidfile="$4" outfile="$5" pid ticks=0 limit
  GG_PTY_CAPPED=0
  GG_PTY_REAPED=""
  limit=$((cap * 10))
  # Job control, which gives the spawner a process group of its own where the
  # platform provides one; gg_pty_reap falls back to the bare pid where it
  # does not. The session's group is a separate matter; see there.
  set -m
  gg_pty_spawn "$form" "$cmd" >"$outfile" 2>&1 </dev/null &
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

# Which grammar this host answers, decided by RUNNING each one and asking the
# session whether its own fds are a terminal — never by parsing a version
# banner. A spawner that is present but cannot open a pty (a container with no
# devpts) fails the same probe, which is the answer that matters.
gg_pty_form() {
  local dir form cmd
  [ -z "$GG_PTY_FORM" ] || { [ "$GG_PTY_FORM" != none ]; return; }
  # 2>&1 rather than 2>/dev/null: on failure mktemp's own words ARE the cause,
  # and they land in $dir, which the branch below reads and then clears. On
  # success mktemp writes the path and nothing else.
  #
  # No memo is recorded here. `none` is reserved for "both grammars ran and
  # neither opened a pty"; latching it for a scratch-root fault would answer
  # the same wrong cause for the rest of the run, with TMPDIR long fixed.
  dir="$(mktemp -d "$TMPDIR/gg-ptyform.XXXXXX" 2>&1)" || {
    GG_PTY_ERR="could not create a scratch directory under TMPDIR ($TMPDIR): $dir"
    return 1
  }
  {
    printf '%s\n' 'ps -o pgid= -p $$ >"$2" 2>/dev/null || true'
    printf '%s\n' '[ -t 0 ] && [ -t 1 ] && [ -t 2 ] && : >"$1"'
  } >"$dir/probe.sh"
  for form in util-linux bsd; do
    rm -f -- "$dir/mark" "$dir/sid"
    # %q at every spawn site: $dir descends from TMPDIR, which the caller owns,
    # and an unquoted path with a space or a metacharacter lands in an `sh -c`
    # string as syntax rather than as a path.
    printf -v cmd '/bin/sh %q %q %q' "$dir/probe.sh" "$dir/mark" "$dir/sid"
    gg_pty_bounded 5 "$form" "$cmd" "$dir/sid" /dev/null
    if [ -f "$dir/mark" ]; then
      GG_PTY_FORM="$form"
      rm -rf -- "${dir:?}"
      return 0
    fi
  done
  rm -rf -- "${dir:?}"
  # Both grammars ran and neither opened a pty. That, and only that, is none.
  GG_PTY_FORM=none
  GG_PTY_ERR="no pty spawner on this host: neither script grammar opened a pseudo-terminal"
  return 1
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
  # gg_pty_form names its own cause, and the specific one survives: a sealed
  # TMPDIR reported as a missing spawner sends an operator after devpts.
  gg_pty_form || {
    [ -n "$GG_PTY_ERR" ] || GG_PTY_ERR="the pty spawner could not be resolved"
    return 1
  }
  # Named apart from the spawner, because a caller told "no spawner" over a
  # full or unwritable TMPDIR goes looking at devpts for a scratch problem.
  dir="$(mktemp -d "$TMPDIR/gg-pty.XXXXXX" 2>&1)" || {
    GG_PTY_ERR="could not create a scratch directory under TMPDIR ($TMPDIR): $dir"
    return 1
  }
  # The session's own group, its output marker, and its status, in that order.
  #
  # The GROUP, first line, because gg_pty_reap cannot derive it from this side
  # and `$$` is not it: util-linux `script` runs the command through $SHELL,
  # which need not exec away.
  #
  # The MARKER is where the session's own output starts. What precedes it is
  # the TERMINAL's, not the script's: BSD echoes the end-of-file character
  # this helper delivers, and renders it as `^D` plus the backspaces that
  # erase it, so a suite comparing output would be asserting about the pty on
  # one platform and about nothing on the other.
  #
  # The STATUS travels in a file, which doubles as the done marker: -e relays
  # it on util-linux and BSD script has no equivalent, and a status read off
  # the spawner would mean something different per platform.
  {
    printf 'ps -o pgid= -p $$ >%q 2>/dev/null || true\n' "$dir/sid"
    printf 'echo GG-PTY-BEGIN\n'
    printf 'bash %q\n' "$body"
    printf 'printf %%s\\\\n "$?" >%q\n' "$dir/rc"
  } >"$dir/session.sh"
  printf -v cmd '/bin/sh %q' "$dir/session.sh"
  gg_pty_bounded "$cap" "$GG_PTY_FORM" "$cmd" "$dir/sid" "$dir/out"
  gg_pty_capture "$dir/out"
  if [ "$GG_PTY_CAPPED" = 1 ] && [ "$GG_PTY_REAPED" != yes ]; then
    # The cap fired and the reap did not finish. `capped` would say the
    # session is gone, which is the one thing this branch cannot claim.
    GG_PTY_STATE=leaked
    case "$GG_PTY_REAPED" in
      no-group) GG_PTY_ERR="the session never recorded its process group, so only the spawner's was killed" ;;
      *) GG_PTY_ERR="the session's process group was still alive 5s after SIGKILL" ;;
    esac
  elif [ "$GG_PTY_CAPPED" = 1 ]; then
    GG_PTY_STATE=capped
  elif [ -f "$dir/rc" ]; then
    GG_PTY_STATE=ok
    GG_PTY_RC="$(cat "$dir/rc")"
  else
    # No status file: the session never reached its own last line. GG_PTY_RC
    # stays empty rather than standing in for one, so nothing here can be
    # mistaken for something the probe returned.
    GG_PTY_STATE=gone
  fi
  # A tree a live session may hold fds in is left where it is, and the caller
  # is told. Removing it is what turns an incomplete reap into an orphan
  # running inside a deleted directory.
  if [ "$GG_PTY_STATE" = leaked ]; then
    GG_PTY_ERR="$GG_PTY_ERR; the scratch directory is left in place at $dir"
  else
    rm -rf -- "${dir:?}"
  fi
}
