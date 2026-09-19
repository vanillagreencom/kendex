#!/usr/bin/env bash
# The mkdir fallback: the message it writes for a held lock and the elapsed
# wait limit, and the signal disposition it must never leave a held mutex in.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/lanes-fixture.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/bin" "$SCRATCH/held.lock.d"
ln -s "$(command -v mkdir)" "$SCRATCH/bin/mkdir"
rc=0
PATH="$SCRATCH/bin" /bin/bash -c 'source "$1"; orch_take_lock 200 "$2" 0' bash \
  "$ROOT/skills/orch/scripts/lib/file-lock.sh" "$SCRATCH/held.lock" >"$SCRATCH/out" 2>"$SCRATCH/err" || rc=$?
[[ "$rc" -eq 1 && ! -s "$SCRATCH/out" ]]
[[ "$(sed -n '1p' "$SCRATCH/err")" == "file-lock: lock-timeout lock-file=$SCRATCH/held.lock wait-s=0" ]]

# The operator's escape hatch is a command, so it is run rather than read.
REMEDY="$(sed -n '2p' "$SCRATCH/err" | sed 's/^.*remove it: //')"
[[ -n "$REMEDY" ]]
eval "$REMEDY"
[[ ! -d "$SCRATCH/held.lock.d" ]]

# A held mutex and the signals a ceiling sends. `refresh_claude_token` replaces
# these handlers while it renames the credentials file, and what it puts back
# decides whether the mutex survives the ceiling: `trap -` restores the DEFAULT
# disposition, which kills the shell with no trap at all, the EXIT trap
# included. The holder is reached the way `lanes` reaches it, one command
# substitution inside another and blocked in a third, because which of those a
# shell waits in decides whether bash runs its handler.
if command -v timeout > /dev/null 2>&1; then
  NOFLOCK="$SCRATCH/path-without-flock"
  mkdir -p "$NOFLOCK"
  (
    IFS=:
    for d in $PATH; do
      [[ -d "$d" ]] || continue
      ln -s "$d"/* "$NOFLOCK"/ 2> /dev/null || true
    done
  )
  rm -f -- "$NOFLOCK/flock"
  [[ ! -x "$NOFLOCK/flock" ]]

  # RESTORE is what the holder runs after its own window, the one line under
  # test; every other byte of the two runs is identical.
  # The settled state is read through lib/lanes-fixture.sh's `settled_mutex`,
  # the one reading of a reaped lock the suites that bound a renewal share.
  # TRIES is its second argument: the held row below passes a short one, since
  # a row expecting `held` polls to the ceiling whatever the budget.
  reaped_mutex() { # NAME RESTORE [TRIES]
    local lock="$SCRATCH/$1.lock"
    cat > "$SCRATCH/$1.sh" << EOF
set -uo pipefail
. "$ROOT/skills/orch/scripts/lib/file-lock.sh"
renew() {
  exec 9> "$lock"
  orch_take_lock 9 "$lock" 30 || exit 1
  $2
  written=\$(sleep 30)
  printf %s "\$written"
}
measure() { local out; out=\$(renew) || return 1; printf %s "\$out"; }
record=\$(measure)
EOF
    PATH="$NOFLOCK" timeout 1 bash "$SCRATCH/$1.sh" > /dev/null 2>&1 || true
    settled_mutex "$lock.d" "${3:-}"
  }

  [[ "$(reaped_mutex rearmed orch_arm_lock_signals)" == released ]]
  # The inverse, and the must-fail control for the row above it: the same
  # holder clearing the handlers instead of restoring them keeps the mutex,
  # which is the state every later renewal on that file would wait on.
  [[ "$(reaped_mutex cleared 'trap - INT TERM' 10)" == held ]]
else
  printf 'file-lock messages: skip a reaped mutex, this host has no timeout to bound one with\n'
fi
printf 'file-lock messages: pass\n'
