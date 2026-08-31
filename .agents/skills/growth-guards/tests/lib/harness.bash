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
#   A time cap. The session is killed by process group after CAP seconds and
#   reported as GG_PTY_RC=124. A probe that HANGS yields no measurement at
#   all, so a mutation run scores it as "not killed" and prints a silent miss
#   instead of a wedge. Five probes of this path had to be killed by pid
#   before the cap existed.
#
# Sets GG_PTY_RC to the script's own exit status and GG_PTY_OUT to its own
# output, the terminal's rendering of both stripped out by gg_pty_capture.
# Returns non-zero only when the host has no working spawner — which is a
# red, not a skip: a case that cannot reach the terminal branch is not
# covering it.

# Resolved once per suite by gg_pty_form: the spawner grammar that really
# yields a tty here, or `none`.
GG_PTY_FORM=""
GG_PTY_RC=0
GG_PTY_OUT=""

# `script` is the one pty spawner both platforms ship, under two incompatible
# grammars: util-linux takes the command as an argument to -e -c, BSD (macOS)
# takes it after the typescript file and has no -e at all.
gg_pty_spawn() { # FORM SH_COMMAND
  case "$1" in
    util-linux) script -qec "$2" /dev/null ;;
    bsd) script -q /dev/null /bin/sh -c "$2" ;;
  esac
}

# Which grammar this host answers, decided by RUNNING each one and asking the
# session whether its own fds are a terminal — never by parsing a version
# banner. A spawner that is present but cannot open a pty (a container with no
# devpts) fails the same probe, which is the answer that matters.
gg_pty_form() {
  local dir form
  [ -z "$GG_PTY_FORM" ] || { [ "$GG_PTY_FORM" != none ]; return; }
  dir="$(mktemp -d "$TMPDIR/gg-ptyform.XXXXXX")" || { GG_PTY_FORM=none; return 1; }
  printf '%s\n' '[ -t 0 ] && [ -t 1 ] && [ -t 2 ] && : >"$1"' >"$dir/probe.sh"
  for form in util-linux bsd; do
    rm -f -- "$dir/mark"
    gg_pty_spawn "$form" "/bin/sh $dir/probe.sh $dir/mark" >/dev/null 2>&1 </dev/null || true
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
  local cap="$1" body="$2" dir pid ticks=0 limit
  GG_PTY_RC=0
  GG_PTY_OUT=""
  gg_pty_form || return 1
  dir="$(mktemp -d "$TMPDIR/gg-pty.XXXXXX")" || return 1
  # The status travels in a FILE, not out of the spawner: -e relays it on
  # util-linux and BSD script has no equivalent, so a suite reading the
  # spawner's own status would assert something different per platform.
  #
  # The marker line is where the session's own output starts. What precedes
  # it is the TERMINAL's, not the script's: BSD echoes the end-of-file
  # character this helper delivers, and renders it as `^D` plus the
  # backspaces that erase it, so a suite comparing output would be asserting
  # about the pty on one platform and about nothing on the other.
  {
    printf 'echo GG-PTY-BEGIN\n'
    printf 'bash %q\n' "$body"
    printf 'printf %%s\\\\n "$?" >%q\n' "$dir/rc"
  } >"$dir/session.sh"
  limit=$((cap * 10))
  # Job control, so the session gets a process group of its own and the cap
  # below can take the whole tree. Killing the spawner alone leaves the child
  # that is actually stuck behind — the pid-hunting this cap exists to end.
  set -m
  gg_pty_spawn "$GG_PTY_FORM" "/bin/sh $dir/session.sh" >"$dir/out" 2>&1 </dev/null &
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$limit" ]; then
      kill -9 -- "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      gg_pty_capture "$dir/out"
      GG_PTY_RC=124
      rm -rf -- "${dir:?}"
      return 0
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid" 2>/dev/null || true
  gg_pty_capture "$dir/out"
  # No status file means the session never reached its own last line: the
  # spawner died before running it. Distinct from any status the script can
  # return, so it cannot be read as one.
  if [ -f "$dir/rc" ]; then GG_PTY_RC="$(cat "$dir/rc")"; else GG_PTY_RC=125; fi
  rm -rf -- "${dir:?}"
}
