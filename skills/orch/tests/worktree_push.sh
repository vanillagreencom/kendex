#!/usr/bin/env bash
# Regression tests for worktree-push: the push wrapper that reconciles
# rebased commit SHAs in workflow state. A `rebase-map:` line from the
# worktree skill's push must land in `.rebase_map` and rewrite every recorded
# fix commit in the same call — including when the network push itself fails,
# because the rebase (and its map) happens before the push. A map the wrapper
# cannot record persists in a sidecar for the retry to consume; nothing may
# leave stale SHAs silently.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
PUSH="$REPO_ROOT/skills/orch/scripts/worktree-push"
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    pass "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    pass "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

# Stub worktree script: prints STUB_PUSH_STDOUT, exits STUB_PUSH_EXIT, and
# logs its argv so pass-through flags can be asserted.
stub="$TMP_ROOT/worktree-stub"
cat >"$stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_ARGS_LOG:-/dev/null}"
if [[ -n "${STUB_PUSH_STDOUT:-}" ]]; then
  printf '%s\n' "$STUB_PUSH_STDOUT"
fi
exit "${STUB_PUSH_EXIT:-0}"
EOF
chmod +x "$stub"
export ORCH_WORKTREE_BIN="$stub"

OLD_A="$(printf 'a%.0s' {1..39})0"
OLD_B="$(printf 'b%.0s' {1..39})1"
NEW_A="$(printf 'c%.0s' {1..39})2"
NEW_A2="$(printf 'd%.0s' {1..39})3"

wt="$TMP_ROOT/wt"
mkdir -p "$wt/tmp"
SIDECAR="$wt/tmp/worktree-push-pending-map-KEN-1.json"

# Fresh state with recorded fix commits on both surfaces: a short prefix of
# OLD_A in fixed_items; in pr_comment_review.fixes one prefix of OLD_B
# (mapped to dropped) and one longer prefix of OLD_A (mapped to a real SHA),
# so both the rewrite and the dropped-marking paths run on .fixes.
reset_state() {
  local work="$1"
  rm -rf "$work"
  mkdir -p "$work"
  rm -f "$SIDECAR"
  (cd "$work" \
    && "$STATE" init KEN-1 --agent generalist --worktree "$wt" --branch ken-1 >/dev/null \
    && "$STATE" append KEN-1 fixed_items "{\"description\":\"fix\",\"commit\":\"${OLD_A:0:7}\",\"source\":\"pr-review\"}" \
    && "$STATE" append KEN-1 pr_comment_review.fixes "{\"description\":\"reply fix\",\"commit\":\"${OLD_B:0:8}\",\"source\":\"bot\"}" \
    && "$STATE" append KEN-1 pr_comment_review.fixes "{\"description\":\"second reply fix\",\"commit\":\"${OLD_A:0:10}\",\"source\":\"bot\"}")
}

run_out="$TMP_ROOT/run.out"
run_err="$TMP_ROOT/run.err"
RUN_RC=0
run_push() {
  local work="$1"
  shift
  RUN_RC=0
  (cd "$work" && "$PUSH" "$@") >"$run_out" 2>"$run_err" || RUN_RC=$?
}

state_json() {
  cat "$1/tmp/workflow-state-KEN-1.json"
}

echo "=== push without a rebase map leaves state alone ==="

work="$TMP_ROOT/work-nomap"
reset_state "$work"
before="$(state_json "$work")"
STUB_PUSH_STDOUT="→ pushed" run_push "$work" --worktree "$wt" --issue KEN-1 --set-upstream
assert_eq "$RUN_RC" "0" "map-less push exits 0"
assert_contains "$(cat "$run_out")" "→ pushed" "push stdout is replayed"
assert_eq "$(grep -c 'sha-reconcile:' "$run_out" || true)" "0" "no reconcile line without a map"
assert_eq "$(state_json "$work")" "$before" "state is untouched without a map"

echo
echo "=== flag parsing and pass-through ==="

args_log="$TMP_ROOT/args.log"
: >"$args_log"
STUB_ARGS_LOG="$args_log" STUB_PUSH_STDOUT="" run_push "$work" --worktree "$wt" --issue KEN-1 --set-upstream
assert_contains "$(cat "$args_log")" "push $wt --set-upstream" "worktree push receives the worktree and pass-through flags"

STUB_PUSH_STDOUT="" run_push "$work" "--worktree=$wt" --issue=KEN-1
assert_eq "$RUN_RC" "0" "equals-form flags parse"

run_push "$work" --worktree "$wt" --issue KEN-1 --force
assert_eq "$RUN_RC" "1" "an unknown flag is a usage error, not a silent pass-through"
assert_contains "$(cat "$run_err")" "unknown option: --force" "the unknown flag is named"

echo
echo "=== a rebase map is recorded and recorded fix SHAs rewritten ==="

work="$TMP_ROOT/work-map"
reset_state "$work"
map_out="rebase-map: $OLD_A $NEW_A
rebase-map: $OLD_B dropped"
STUB_PUSH_STDOUT="$map_out" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "0" "mapped push exits 0"
assert_eq "$(state_json "$work" | jq -r ".rebase_map[\"$OLD_A\"]")" "$NEW_A" "old→new mapping recorded"
assert_eq "$(state_json "$work" | jq -r ".rebase_map[\"$OLD_B\"]")" "dropped" "dropped mapping recorded literally"
assert_eq "$(state_json "$work" | jq -r '.fixed_items[0].commit')" "${NEW_A:0:7}" "fixed_items short SHA rewritten, truncated to recorded length"
assert_eq "$(state_json "$work" | jq -r '.pr_comment_review.fixes[0].commit')" "dropped:${OLD_B:0:8}" "dropped mapping marks the recorded commit unpublishable"
assert_eq "$(state_json "$work" | jq -r '.pr_comment_review.fixes[1].commit')" "${NEW_A:0:10}" "pr_comment_review.fixes SHA rewritten, truncated to recorded length"
assert_contains "$(cat "$run_out")" "sha-reconcile: rebase_map +2, fixed_items 1 rewritten, pr_comment_review.fixes 2 rewritten" "reconcile summary reports what changed"
[[ ! -f "$SIDECAR" ]] && pass "sidecar deleted after a successful state write" || fail "sidecar deleted after a successful state write"

echo
echo "=== a second push chains through the already-rewritten SHA ==="

STUB_PUSH_STDOUT="rebase-map: $NEW_A $NEW_A2" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "0" "second mapped push exits 0"
assert_eq "$(state_json "$work" | jq -r '.rebase_map | length')" "3" "second map merges into rebase_map"
assert_eq "$(state_json "$work" | jq -r '.fixed_items[0].commit')" "${NEW_A2:0:7}" "already-rewritten SHA follows the new mapping"
assert_eq "$(state_json "$work" | jq -r '.pr_comment_review.fixes[0].commit')" "dropped:${OLD_B:0:8}" "a dropped-marked commit stays marked across pushes"

echo
echo "=== a failed push still applies its map (rebase precedes the push) ==="

work="$TMP_ROOT/work-failed"
reset_state "$work"
STUB_PUSH_STDOUT="rebase-map: $OLD_A $NEW_A" STUB_PUSH_EXIT=7 run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "7" "push failure keeps the push's exit code"
assert_eq "$(state_json "$work" | jq -r ".rebase_map[\"$OLD_A\"]")" "$NEW_A" "map from a failed push is still recorded"
assert_eq "$(state_json "$work" | jq -r '.fixed_items[0].commit')" "${NEW_A:0:7}" "fix SHA rewritten even though the push failed"
[[ ! -f "$SIDECAR" ]] && pass "sidecar consumed on the failed-push path too" || fail "sidecar consumed on the failed-push path too"

echo
echo "=== a map the wrapper cannot record persists for the retry ==="

# No state file: the push landed, the SHAs are stale, and silence here is the
# exact failure mode the wrapper exists to close — the map waits in the
# sidecar and the next run consumes it before pushing.
work="$TMP_ROOT/work-nostate"
rm -rf "$work" && mkdir -p "$work"
rm -f "$SIDECAR"
STUB_PUSH_STDOUT="rebase-map: $OLD_A $NEW_A" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "1" "missing state file fails the call"
assert_contains "$(cat "$run_err")" "NOT recorded" "missing state names the unreconciled-SHA consequence"
[[ -f "$SIDECAR" ]] && pass "unapplied map persists in the sidecar" || fail "unapplied map persists in the sidecar"

(cd "$work" \
  && "$STATE" init KEN-1 --agent generalist --worktree "$wt" --branch ken-1 >/dev/null \
  && "$STATE" append KEN-1 fixed_items "{\"description\":\"fix\",\"commit\":\"${OLD_A:0:7}\",\"source\":\"pr-review\"}")
STUB_PUSH_STDOUT="→ pushed" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "0" "retry after repairing state exits 0"
assert_eq "$(state_json "$work" | jq -r '.fixed_items[0].commit')" "${NEW_A:0:7}" "retry consumes the sidecar map before pushing"
[[ ! -f "$SIDECAR" ]] && pass "sidecar deleted after the retry applies it" || fail "sidecar deleted after the retry applies it"

work="$TMP_ROOT/work-badmap"
reset_state "$work"
STUB_PUSH_STDOUT="rebase-map: not-a-sha $NEW_A" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "1" "unparseable map line fails the call"
assert_contains "$(cat "$run_err")" "NOT reconciled" "unparseable map names the unreconciled-SHA consequence"
[[ ! -f "$SIDECAR" ]] && pass "no sidecar is written for an unparseable map" || fail "no sidecar is written for an unparseable map"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
