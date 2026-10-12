#!/usr/bin/env bash
# Process cost of the shipped watcher, with its pre-batch implementation as
# the must-fail control. Both consume the same offline PR rows and clock.
# The fixture is the original script from 50e8d04bb, before KEN-3891.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# macOS CI deliberately runs Bash 3.2 to prove consumer compatibility.
# Its shell has no distinct subshell PIDs; the Linux leg owns this count.
if [[ -z "${BASHPID:-}" ]] || ((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 401)); then
  printf 'process-count: unavailable=bash-pid-tracing shell=%s\n' "$BASH_VERSION"
  exit 0
fi
. "$TEST_DIR/lib/pr-watch-fixture.sh"
. "$TEST_DIR/lib/process-count.sh"

COUNT_DIR="$TMP_ROOT/count"
pc_install "$COUNT_DIR" "$TMP_ROOT/bin:$PATH"
mkdir -p "$TMP_ROOT/before/lib"
cp "$TEST_DIR/fixtures/pr-watch-before.txt" "$TMP_ROOT/before/pr-watch.sh"
cp "$TMP_ROOT/scripts/lib/"* "$TMP_ROOT/before/lib/"
chmod +x "$TMP_ROOT/before/pr-watch.sh"

pass_cost() { # PRS [PAGES] [NAMED] sets COST, GH_CALLS, JQ_CALLS, OUT
  local rows n flags=(--awaiting-after 60)
  rows="$(jq -cn --argjson n "$1" --argjson r "$(pr_row 1)" '[range(1; $n + 1) as $i | $r | .number = $i]')"
  if [[ "${3:-}" == named ]]; then
    for ((n=1; n <= $1; n++)); do flags+=("$n"); done
  fi
  pc_reset "$COUNT_DIR"
  run_watch "PATH=$COUNT_DIR/bin:$TMP_ROOT/bin:$PATH;BASH_ENV=$COUNT_DIR/bash-env;STUB_OPEN_PRS=$rows;STUB_DECISION=REVIEW_REQUIRED;STUB_HEAD_DATE=$OLD;STUB_THREADS_PAGES=${2:-1}" "${flags[@]}"
  assert_eq "$RC $(grep -c "$(printf '\tawaiting-stale\t')" <<<"$OUT" || true)" "1 $1" "$1 stale PRs print $1 lines"
  [[ -s "$COUNT_DIR/main" && -s "$COUNT_DIR/trace" ]] || { printf 'process-count: missing-watcher-trace\n' >&2; exit 1; }
  COST="$(pc_births "$COUNT_DIR")"
  GH_CALLS="$(pc_births "$COUNT_DIR" gh)"
  JQ_CALLS="$(pc_births "$COUNT_DIR" jq)"
  printf 'pass evidence: watch=%s prs=%s pages=%s mode=%s births=%s gh=%s jq=%s\n' "${WATCH_BIN#"$TMP_ROOT"/}" "$1" "${2:-1}" "${3:-list}" "$COST" "$GH_CALLS" "$JQ_CALLS"
}

echo '=== one first-page read per repository, independent of PRs and lines ==='
for mode in list named; do
  for prs in 2 8 16; do
    pass_cost "$prs" 1 "$mode"
    [[ "$prs" != 2 ]] || BASE_COST="$COST"
    assert_eq "$COST" "$BASE_COST" "$mode: $prs PRs start as many processes as 2 PRs"
    assert_eq "$GH_CALLS" 1 "$mode: $prs first-page PRs make exactly one gh call"
    assert_eq "$JQ_CALLS" 1 "$mode: $prs first-page PRs use one jq reduction"
  done
done

echo '=== extra thread pages share a round across every PR ==='
for prs in 2 8 16; do
  pass_cost "$prs" 2
  [[ "$prs" != 2 ]] || BASE_COST="$COST"
  assert_eq "$COST" "$BASE_COST" "$prs PRs share the extra page without per-PR processes"
  assert_eq "$GH_CALLS" 2 "$prs PRs share one extra gh call for the next page depth"
done

echo '=== original watcher grows with PRs on the same fixture ==='
for prs in 2 8 16; do
  WATCH_BIN="$LIVE_WATCH"
  pass_cost "$prs"
  LIVE_OUT="$OUT"
  WATCH_BIN="$TMP_ROOT/before/pr-watch.sh"
  pass_cost "$prs"
  assert_eq "$OUT" "$LIVE_OUT" "$prs PRs preserve the original attention records byte for byte"
  if [[ "$prs" == 2 ]]; then
    BEFORE_COST="$COST"
  else
    control_rc=0
    (FAIL=0; assert_eq "$COST" "$BEFORE_COST" 'original watcher keeps process cost flat' >/dev/null; [[ "$FAIL" -eq 0 ]]) || control_rc=$?
    assert_eq "$control_rc" 1 "must-fail: the original watcher grows at $prs PRs"
  fi
done

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
