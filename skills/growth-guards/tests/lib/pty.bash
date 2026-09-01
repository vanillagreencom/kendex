# shellcheck shell=bash
# Running a case AT A TERMINAL. Sourced by terminal-paths.test.sh after
# lib/harness.bash and by nothing else. Why a terminal-only branch needs a
# probe like this, and the two rules such a probe follows, are in
# DEVELOPMENT.md § Probing a terminal-only code path.
#
# Declared here rather than inherited from harness.bash, which sets the same:
# the `|| true` guards below are written for errexit, and a library that needs
# a mode says so.
set -euo pipefail

GG_PTY_RC=""
GG_PTY_OUT=""
GG_PTY_STATE=""
GG_PTY_ERR=""

# Run SCRIPT_FILE with fds 0, 1 and 2 on a pseudo-terminal, capped at CAP
# seconds. GG_PTY_STATE is `ok` (the session ran to its own end, and
# GG_PTY_RC is its status), `capped` (it was killed at the cap) or `gone` (it
# died before its last line). GG_PTY_RC is EMPTY in the last two: the helper
# owns no status values of its own, since a probe may exit anything.
# GG_PTY_OUT is the session's output. A non-zero return means no session ran
# at all, and GG_PTY_ERR names why.
gg_pty_run() { # CAP_SECONDS SCRIPT_FILE
  local cap="$1" body="$2" dir cmd pid group="" ticks=0 waited=0 raw
  GG_PTY_RC=""
  GG_PTY_OUT=""
  GG_PTY_STATE=""
  GG_PTY_ERR=""
  # 2>&1, so a failure puts mktemp's own words where the message reads them.
  dir="$(mktemp -d "$TMPDIR/gg-pty.XXXXXX" 2>&1)" || {
    GG_PTY_ERR="could not create a scratch directory under TMPDIR ($TMPDIR): $dir"
    return 1
  }
  # The session writes its own process group first, because nothing on this
  # side can derive it — the spawner is in between; then a marker where its
  # output starts; then its status in a file.
  #
  # Not one path is interpolated into it, and the command handed to the
  # spawner is a constant: every caller-controlled path travels in the
  # ENVIRONMENT instead. bash's %q emits ANSI-C quoting — $'a\nb' — for a
  # path carrying a newline or a control byte, and that is a bash extension
  # /bin/sh need not parse; dash did not before 0.5.12. A legal TMPDIR would
  # then stop the session starting. Passing the paths as values rather than
  # as syntax removes the question instead of answering it.
  cat >"$dir/session.sh" <<'SESSION'
ps -o pgid= -p $$ >"$GG_PTY_SID_FILE" 2>/dev/null || true
echo GG-PTY-BEGIN
bash "$GG_PTY_BODY_FILE"
printf '%s\n' "$?" >"$GG_PTY_RC_FILE"
SESSION
  cmd='/bin/sh "$GG_PTY_SESSION_FILE"'
  # Exported, not prefixed onto the spawn: the two grammars below would
  # otherwise carry four assignments each. Every call overwrites them.
  export GG_PTY_SESSION_FILE="$dir/session.sh" GG_PTY_SID_FILE="$dir/sid" \
    GG_PTY_BODY_FILE="$body" GG_PTY_RC_FILE="$dir/rc"
  # The grammar is SELECTED, not probed: util-linux takes the command through
  # -e -c, BSD (macOS) after the typescript file. `set -m` gives the spawner a
  # process group of its own where the platform provides one, and </dev/null
  # is the redirect that answers a prompt with EOF instead of a person.
  set -m
  case "$(uname -s)" in
    Darwin) script -q /dev/null /bin/sh -c "$cmd" >"$dir/out" 2>&1 </dev/null & ;;
    *) script -qec "$cmd" /dev/null >"$dir/out" 2>&1 </dev/null & ;;
  esac
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge $((cap * 10)) ]; then
      # The session's OWN group first: `script` setsids it, so the spawner's
      # group never names it and killing the spawner alone leaves the stuck
      # child behind. Then the spawner, by group where job control gave it
      # one and by bare pid where it did not.
      [ ! -f "$dir/sid" ] || group="$(tr -dc '0-9' <"$dir/sid" 2>/dev/null || true)"
      [ -z "$group" ] || kill -9 -- "-$group" 2>/dev/null || true
      kill -9 -- "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
      GG_PTY_STATE=capped
      break
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid" 2>/dev/null || true
  # Bounded, because the caller is told the cap worked and the tree goes next.
  while [ -n "$group" ] && [ "$waited" -lt 50 ] && kill -0 -- "-$group" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
  done
  # Everything before the marker is the TERMINAL's, not the session's: BSD
  # echoes the end-of-file this helper delivers into the typescript. No marker
  # anywhere means no session ran, and the spawner's own words are the cause.
  raw="$(tr -d '\r' <"$dir/out" 2>/dev/null || true)"
  case "$raw" in
    *GG-PTY-BEGIN*) GG_PTY_OUT="$(printf '%s\n' "$raw" | awk 'seen {print} /GG-PTY-BEGIN/ {seen = 1}')" ;;
    *)
      GG_PTY_ERR="no working pty spawner: script started no session. It said: $raw"
      rm -rf -- "${dir:?}"
      return 1
      ;;
  esac
  [ ! -f "$dir/rc" ] || GG_PTY_RC="$(cat "$dir/rc")"
  if [ "$GG_PTY_STATE" = capped ]; then
    GG_PTY_RC=""
  elif [ -n "$GG_PTY_RC" ]; then
    GG_PTY_STATE=ok
  else
    GG_PTY_STATE=gone
  fi
  rm -rf -- "${dir:?}"
}
