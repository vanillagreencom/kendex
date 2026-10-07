#!/usr/bin/env bash
# lib/lane-claims.sh in a store several homes share: a claim is written
# group-readable under any umask, and a claim whose tmux server another account
# owns (kill -0 refused as EPERM) is kept and read live, while one whose server
# is gone (ESRCH) is pruned. Each row runs against the shipped library and,
# as its must-fail control, against a private copy with that rule undone.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TMP_ROOT="$(mktemp -d)" || { echo "lane-claims: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lane-claims: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lane-claims: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

SHIPPED="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lib/lane-claims.sh"
# Above pid_max on Linux and macOS: no process has it, so kill -0 meets ESRCH.
DEAD_PID=2147483647
# A process that runs for the whole suite: this shell. The EPERM row refuses
# kill -0 on it the way the kernel refuses a process another account owns.
LIVE_PID="$$"

# observe DIR LIB SERVER EPERM — writes one claim under umask 077 through LIB
# into the fresh store DIR, then reads it with no tmux server enumerable and
# kill -0 on EPERM refused.
# Prints `group=<r|-> files=<n> live=<n>`.
observe() {
  local dir="$1" lib="$2" server="$3" eperm="$4"
  (
    # shellcheck source=/dev/null
    source "$lib"
    tmux() { return 1; }
    kill() { [[ "$2" == "$eperm" ]] && return 1; builtin kill "$@"; }
    umask 077
    lane_claim_write "$dir" "$server" %3 "$TMP_ROOT/home-a/.1claude" lane-a ""
    group="$(ls -l "$dir"/*.claim)" || exit 1
    group="${group:4:1}"
    live="$(lane_claims_read "$dir")" || exit 1
    files="$(find "$dir" -name '*.claim' | grep -c . || true)"
    printf 'group=%s files=%s live=%s\n' "$group" "$files" "$(grep -c . <<<"$live" || true)"
  )
}

mutant() { # NAME OLD NEW
  local scripts
  scripts="$(mutant_scripts "$1" lib/lane-claims.sh)" || exit 1
  mutate_file "$scripts/lib/lane-claims.sh" "$2" "$3"
  printf '%s\n' "$scripts/lib/lane-claims.sh"
}
MODE600="$(mutant mutant-mode-600 '  chmod g+r -- "$tmp" || { rm -f -- "$tmp"; return 1; }
' '')"
EPERM_DEAD="$(mutant mutant-eperm-dead '  kill -0 "$1" 2>/dev/null && return 0
  ps -p "$1" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 1 ]]' '  kill -0 "$1" 2>/dev/null')"

# label|lib|server|eperm pid|expect
ROWS=(
  "a claim written under umask 077 is group-readable|$SHIPPED|$LIVE_PID|-|group=r files=1 live=1"
  "a claim whose server another account owns is kept and read live|$SHIPPED|$LIVE_PID|$LIVE_PID|group=r files=1 live=1"
  "a claim whose server is gone is pruned|$SHIPPED|$DEAD_PID|-|group=r files=0 live=0"
  "control: mktemp's mode 600 left standing hides the claim from the group|$MODE600|$LIVE_PID|-|group=- files=1 live=1"
  "control: an EPERM read as gone deletes the other account's live claim|$EPERM_DEAD|$LIVE_PID|$LIVE_PID|group=r files=0 live=0"
)
# Root may signal every process, so no real pid refuses it with EPERM.
if [[ "$(id -u)" -ne 0 ]]; then
  ROWS+=("a claim on pid 1, which this account may not signal, is kept|$SHIPPED|1|-|group=r files=1 live=1")
fi
n=0
for row in "${ROWS[@]}"; do
  n=$((n + 1))
  IFS='|' read -r label lib server eperm expect <<<"$row"
  got="$(observe "$TMP_ROOT/store$n" "$lib" "$server" "$eperm" 2>"$TMP_ROOT/err")" || got="observe-failed"
  assert_eq "$got" "$expect" "$label" "$TMP_ROOT/err"
done

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
