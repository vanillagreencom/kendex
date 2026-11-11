#!/usr/bin/env bash
# lib/lane-claims.sh's reader over the rows of earlier installs, in a store
# several homes share: a record whose process another account owns (kill -0
# refused as EPERM) is kept and read live, while one whose process is gone
# (ESRCH) is pruned. Each row plants a record in the store's own row format
# and runs against the shipped library and, as its must-fail control,
# against a private copy with that rule undone.
# Inputs: skills/agent-runtime/, skills/agent-runtime/scripts/, skills/change-scope/references/,
# skills/change-scope/scripts/, skills/communication/references/reports.md, skills/mailbox/scripts/,
# skills/orch/runtime/, skills/orch/scripts/, skills/orch/tests/.
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
# A process that runs for the whole suite: this shell. The EPERM rows refuse
# kill -0 on it the way the kernel refuses a process another account owns.
LIVE_PID="$$"

# observe DIR LIB KIND SERVER EPERM [PS_RC] — plants one KIND record (claim or
# reserve) in the store's row format into the fresh store DIR, then reads it
# through LIB in the count form with no tmux server enumerable and kill -0 on
# EPERM refused. With PS_RC, `ps` answers that status without looking.
# Prints `files=<n> live=<n>`.
observe() {
  local dir="$1" lib="$2" kind="$3" server="$4" eperm="$5" ps_rc="${6:-}"
  (
    # shellcheck source=/dev/null
    source "$lib"
    tmux() { return 1; }
    kill() { [[ "$2" == "$eperm" ]] && return 1; builtin kill "$@"; }
    [[ -z "$ps_rc" ]] || ps() { return "$ps_rc"; }
    mkdir -p -- "$dir" || exit 1
    if [[ "$kind" == reserve ]]; then
      printf '%s\t-\t\tlane-a\t2026-01-01T00:00:00Z\t%s\t\t\tplan\n' "$server" "$TMP_ROOT/fleet.json" > "$dir/claim.a.reserve"
    else
      printf '%s\t%%3\t%s\tlane-a\t2026-01-01T00:00:00Z\t\t%s\t\tplan\n' "$server" "$TMP_ROOT/home-a/.1claude" "$TMP_ROOT/home-a/.1claude" > "$dir/claim.a.claim"
    fi
    live="$(lane_claims_read "$dir" count)" || exit 1
    files="$(find "$dir" -name "*.$kind" | grep -c . || true)"
    printf 'files=%s live=%s\n' "$files" "$(grep -c . <<<"$live" || true)"
  )
}

mutant() { # NAME OLD NEW
  local scripts
  scripts="$(mutant_scripts "$1" lib/lane-claims.sh)" || exit 1
  mutate_file "$scripts/lib/lane-claims.sh" "$2" "$3"
  printf '%s\n' "$scripts/lib/lane-claims.sh"
}
EPERM_DEAD="$(mutant mutant-eperm-dead '  kill -0 "$1" 2>/dev/null && return 0
  ps -p "$1" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 1 ]]' '  kill -0 "$1" 2>/dev/null')"
RESERVE_KILL="$(mutant mutant-reserve-kill '! lane_claims_pid_runs "$server" || live_now=1' '! kill -0 "$server" 2>/dev/null || live_now=1')"
PS_ERROR_DEAD="$(mutant mutant-ps-error-dead '[[ "$rc" -ne 1 ]]' '[[ "$rc" -eq 0 ]]')"

# label|lib|kind|server|eperm pid|ps status|expect; an empty ps status is the real ps
ROWS=(
  "a claim whose server another account owns is kept and read live|$SHIPPED|claim|$LIVE_PID|$LIVE_PID||files=1 live=1"
  "a reservation whose launcher another account owns is kept and counted|$SHIPPED|reserve|$LIVE_PID|$LIVE_PID||files=1 live=1"
  "a claim whose server is gone is pruned|$SHIPPED|claim|$DEAD_PID|-||files=0 live=0"
  "a reservation whose launcher is gone is pruned|$SHIPPED|reserve|$DEAD_PID|-||files=0 live=0"
  "control: an EPERM read as gone deletes the other account's live claim|$EPERM_DEAD|claim|$LIVE_PID|$LIVE_PID||files=0 live=0"
  "a claim whose server refuses kill -0 and ps cannot read is kept|$SHIPPED|claim|$LIVE_PID|$LIVE_PID|2|files=1 live=1"
  "control: kill -0 at the reservation read prunes the other account's reservation|$RESERVE_KILL|reserve|$LIVE_PID|$LIVE_PID||files=0 live=0"
  "control: a ps that cannot answer read as gone deletes the claim|$PS_ERROR_DEAD|claim|$LIVE_PID|$LIVE_PID|2|files=0 live=0"
)
# Root may signal every process, so no real pid refuses it with EPERM.
if [[ "$(id -u)" -ne 0 ]]; then
  ROWS+=("a claim on pid 1, which this account may not signal, is kept|$SHIPPED|claim|1|-||files=1 live=1")
fi
n=0
for row in "${ROWS[@]}"; do
  n=$((n + 1))
  IFS='|' read -r label lib kind server eperm ps_rc expect <<<"$row"
  got="$(observe "$TMP_ROOT/store$n" "$lib" "$kind" "$server" "$eperm" "$ps_rc" 2>"$TMP_ROOT/err")" || got="observe-failed"
  assert_eq "$got" "$expect" "$label" "$TMP_ROOT/err"
done

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
