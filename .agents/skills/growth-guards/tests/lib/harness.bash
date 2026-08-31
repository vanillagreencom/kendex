# shellcheck shell=bash
# Shared setup for the growth-guards suites. Sourced, never run as one: suite
# runners glob tests/*.sh, so both the subdirectory and the .bash name keep
# this file out of every run and out of the exec-bit lint.
#
# A suite sources this immediately after set -euo pipefail and gets:
#   TMP     a scratch root it owns, removed on exit
#   TMPDIR  inside that root, so scratch the code under test creates lands in
#           a namespace no other process writes to and can be counted
#   git     no system, global, XDG or template configuration and no repo or
#           identity variables from the caller: core.hooksPath,
#           init.templateDir and commit.gpgsign decide fixture results
#           otherwise, and GIT_DIR/GIT_INDEX_FILE leak in whenever a suite
#           runs from inside a git hook

set -euo pipefail

gg_suite="${0##*/}"
gg_suite="${gg_suite%.test.sh}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gg-${gg_suite}.XXXXXX")" || {
  echo "harness: could not create a scratch root under ${TMPDIR:-/tmp}" >&2
  exit 2
}
trap 'rm -rf -- "$TMP"' EXIT

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/xdg"
export TMPDIR="$TMP/tmp"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$TMPDIR"

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
: >"$GIT_CONFIG_GLOBAL"

# GIT_CONFIG_PARAMETERS and the GIT_CONFIG_COUNT/KEY_n/VALUE_n family carry
# configuration in the ENVIRONMENT, so a private HOME and GIT_CONFIG_NOSYSTEM
# do not stop them: either one still sets core.hooksPath or commit.gpgsign
# for every fixture below. git exports GIT_CONFIG_PARAMETERS into hooks
# whenever a caller used `git -c`, which is exactly how a suite run from a
# hook inherits them. The CLI scrubs the same names in refresh_sources.rs.
unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT 2>/dev/null || true
gg_kv=0
while [ "$gg_kv" -lt 64 ]; do
  unset "GIT_CONFIG_KEY_$gg_kv" "GIT_CONFIG_VALUE_$gg_kv" 2>/dev/null || true
  gg_kv=$((gg_kv + 1))
done
unset gg_kv

unset GIT_TEMPLATE_DIR GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX \
  GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
  GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE \
  GIT_EDITOR GIT_PAGER GIT_CEILING_DIRECTORIES 2>/dev/null || true

# --- terminal-only code paths ------------------------------------------------
#
# Every suite here runs with stdin off a pipe, so a branch that behaves
# differently at a terminal is unreachable by all of them: `mv` prompts before
# replacing a destination that denies write ONLY at a tty, which is the whole
# reason gg_install_file passes -f. Probed headless, plain `mv` and `mv -f`
# measure the same, and reverting the -f survives the suite.
#
# gg_pty_run runs a bash script file with fds 0, 1 and 2 on a pseudo-terminal.
# Two rules make such a probe safe to run, and both are why there is one
# helper rather than a `script` line per suite:
#
#   Stdin redirected. The SPAWNER reads /dev/null, so a prompt inside the
#   session is answered by EOF the moment it is written. Pre-fix code then
#   declines and reports a failure — a measurement. Without it, it waits for
#   a person who is not there.
#
#   A time cap. The session is killed after CAP seconds and reported as
#   GG_PTY_STATE=capped. A probe that HANGS yields no measurement at all, so
#   a mutation run scores it as "not killed" and prints a silent miss instead
#   of a wedge. Five probes of this path had to be killed by pid before the
#   cap existed, and gg_pty_reap is what keeps that from coming back.
#
# What a call sets:
#
#   GG_PTY_STATE  ok      the session ran to its own end; GG_PTY_RC is its status
#                 capped  the cap fired; the session was killed
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

# Resolved once per suite by gg_pty_form: the spawner grammar that really
# yields a tty here, or `none`.
GG_PTY_FORM=""
GG_PTY_RC=""
GG_PTY_OUT=""
GG_PTY_STATE=""
GG_PTY_ERR=""
GG_PTY_CAPPED=0

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
gg_pty_reap() { # SPAWNER_PID_OR_EMPTY SID_FILE
  local group="" waited=0
  [ ! -f "$2" ] || group="$(tr -dc '0-9' <"$2" 2>/dev/null || true)"
  # The session first, while the timeout that named it is one instant old: a
  # pid read from a file is only as current as the process it came from.
  [ -z "$group" ] || kill -9 -- "-$group" 2>/dev/null || true
  if [ -n "$1" ]; then
    kill -9 -- "-$1" 2>/dev/null || kill -9 "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
  fi
  # Nothing is reported capped while the session is still there. The caller
  # removes the scratch directory next, and an orphan inside it is the leak
  # this reap exists to prevent, so the wait is part of the guarantee.
  while [ -n "$group" ] && kill -0 -- "-$group" 2>/dev/null; do
    [ "$waited" -lt 50 ] || break
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
  limit=$((cap * 10))
  # Job control, so the spawner is a group of its own and the reap can take it
  # whole. The session's group is a separate matter; see gg_pty_reap.
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
  dir="$(mktemp -d "$TMPDIR/gg-ptyform.XXXXXX" 2>/dev/null)" || { GG_PTY_FORM=none; return 1; }
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
  GG_PTY_FORM=none
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
  gg_pty_form || {
    GG_PTY_ERR="no pty spawner on this host: neither script grammar opened a pseudo-terminal"
    return 1
  }
  # Named apart from the spawner, because a caller told "no spawner" over a
  # full or unwritable TMPDIR goes looking at devpts for a scratch problem.
  dir="$(mktemp -d "$TMPDIR/gg-pty.XXXXXX" 2>/dev/null)" || {
    GG_PTY_ERR="could not create a scratch directory under TMPDIR ($TMPDIR)"
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
  if [ "$GG_PTY_CAPPED" = 1 ]; then
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
  rm -rf -- "${dir:?}"
}
