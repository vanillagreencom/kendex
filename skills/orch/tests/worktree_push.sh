#!/usr/bin/env bash
# Regression tests for worktree-push: the push wrapper that reconciles
# rebased commit SHAs in workflow state. A `rebase-map:` line from the
# worktree skill's push must land in `.rebase_map` and rewrite every recorded
# fix commit in the same call — including when the network push itself fails,
# because the rebase (and its map) happens before the push. A map the wrapper
# cannot record is reported, with the replayed transcript as its only
# surviving copy; nothing may leave stale SHAs silently.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
PUSH="$REPO_ROOT/skills/orch/scripts/worktree-push"
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
ROUND_WRITE_BIN="$REPO_ROOT/skills/orch/scripts/dev-round-write"
ROUND_WRITE=round_write
RETURN_WRITE="$REPO_ROOT/skills/orch/scripts/dev-return-write"
ARTIFACT_CHECK="$REPO_ROOT/skills/orch/scripts/dev-artifact-check"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

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

round_write() {
  growth_round_write "$STATE" "$ROUND_WRITE_BIN" "$@"
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

# The pushed worktree is a real git checkout: round authorizations live in ITS git
# dir, never in the tree and never in the state directory.
wt="$TMP_ROOT/wt"
git init -q -b main "$wt"
mkdir -p "$wt/tmp"

# Fresh state with recorded fix commits on both surfaces: a short prefix of
# OLD_A in fixed_items; in pr_comment_review.fixes one prefix of OLD_B
# (mapped to dropped) and one longer prefix of OLD_A (mapped to a real SHA),
# so both the rewrite and the dropped-marking paths run on .fixes.
reset_state() {
  local work="$1"
  rm -rf "$work"
  mkdir -p "$work"
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

# KEN-570: the wrapper keeps no copy of push's flag vocabulary. A flag it does
# not own is forwarded verbatim, and `worktree push` — which fails closed on an
# unknown flag — is the one that rejects it.
: >"$args_log"
STUB_ARGS_LOG="$args_log" STUB_PUSH_STDOUT="" run_push "$work" --worktree "$wt" --issue KEN-1 --no-rebase --future-flag
assert_contains "$(cat "$args_log")" "push $wt --no-rebase --future-flag" "flags the wrapper does not own are forwarded verbatim, in order"

: >"$args_log"
STUB_ARGS_LOG="$args_log" STUB_PUSH_EXIT=1 run_push "$work" --worktree "$wt" --issue KEN-1 --force
assert_eq "$RUN_RC" "1" "a flag push rejects fails the wrapper with push's own exit code"
assert_contains "$(cat "$args_log")" "push $wt --force" "the rejected flag reached push rather than being screened here"

# KEN-570: a mangled --state-dir (--sate-dir here, a transposition no prefix
# guess catches) is push's to reject, not this wrapper's — the flag vocabulary
# lives in one place. This case runs the REAL worktree script, so the two
# scripts' wiring is held: the argument order the wrapper sends, and push's
# own diagnostic reaching the caller. It runs FROM the worktree because the
# worktree script resolves its project at startup and exits 128 before
# parsing anything when its working directory is not a repository.
work="$TMP_ROOT/work-owned-typo"
reset_state "$work"
typo_before="$(state_json "$work")"
RUN_RC=0
(cd "$wt" && ORCH_WORKTREE_BIN="$REPO_ROOT/skills/worktree/scripts/worktree" \
  "$PUSH" --worktree "$wt" --issue KEN-1 --state-dir "$work/tmp" "--sate-dir=$TMP_ROOT/elsewhere") \
  >"$run_out" 2>"$run_err" || RUN_RC=$?
assert_eq "$RUN_RC" "1" "the real push refuses a transposed owned flag through this wrapper"
assert_contains "$(cat "$run_err")" "unknown option '--sate-dir=$TMP_ROOT/elsewhere' for push" "push's own diagnostic reaches the caller"
assert_eq "$(state_json "$work")" "$typo_before" "a push that printed no map rewrites nothing"

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

echo
echo "=== a second push chains through the already-rewritten SHA ==="

STUB_PUSH_STDOUT="rebase-map: $NEW_A $NEW_A2" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "0" "second mapped push exits 0"
assert_eq "$(state_json "$work" | jq -r '.rebase_map | length')" "3" "second map merges into rebase_map"
assert_eq "$(state_json "$work" | jq -r '.fixed_items[0].commit')" "${NEW_A2:0:7}" "already-rewritten SHA follows the new mapping"
assert_eq "$(state_json "$work" | jq -r '.pr_comment_review.fixes[0].commit')" "dropped:${OLD_B:0:8}" "a dropped-marked commit stays marked across pushes"

echo
echo "=== restack remaps the exact fix-round snapshot ==="

restack_wt="$TMP_ROOT/restack-wt"
mkdir -p "$restack_wt"
git -C "$restack_wt" init -q -b main
git -C "$restack_wt" config user.email test@example.com
git -C "$restack_wt" config user.name Test
git -C "$restack_wt" config commit.gpgsign false
git -C "$restack_wt" commit -q --allow-empty -m delegation-base
restack_old="$(git -C "$restack_wt" rev-parse HEAD)"
init_growth_state "$STATE" "$restack_wt" KEN-RESTACK seed 1000000
"$ROUND_WRITE" --worktree "$restack_wt" --issue KEN-RESTACK --round-id 1-1 --item 1 restack >/dev/null
mkdir -p "$restack_wt/tools"
printf 'upstream\n' > "$restack_wt/tools/upstream-tool"
git -C "$restack_wt" add tools/upstream-tool
git -C "$restack_wt" commit -q -m upstream-protected-addition
restack_base="$(git -C "$restack_wt" rev-parse HEAD)"
printf 'round fix\n' > "$restack_wt/README.md"
git -C "$restack_wt" add README.md
git -C "$restack_wt" commit -q -m round-fix
restack_head="$(git -C "$restack_wt" rev-parse HEAD)"
"$RETURN_WRITE" --worktree "$restack_wt" --kind fix --issue KEN-RESTACK --round-id 1-1 \
  --branch main --commit "$restack_head" --validate pass --item 1 Applied done >/dev/null
before_restack="$($ARTIFACT_CHECK --worktree "$restack_wt" --issue KEN-RESTACK --round-id 1-1 2>/dev/null || true)"
assert_eq "$(jq -r '.reason' <<<"$before_restack")" "unapproved_additions" \
  "old delegation snapshot sees the upstream protected addition"

restack_state="$TMP_ROOT/restack-state"
mkdir -p "$restack_state"
(cd "$restack_state" && "$STATE" init KEN-RESTACK --agent generalist \
  --worktree "$restack_wt" --branch main >/dev/null \
  && "$STATE" set KEN-RESTACK dev_round_id 1-1)
STUB_PUSH_STDOUT="rebase-map: $restack_old $restack_base" \
  run_push "$restack_state" --worktree "$restack_wt" --issue KEN-RESTACK
assert_eq "$RUN_RC" "0" "restack map and authorization reconciliation succeed together"
restack_auth="$restack_wt/.git/kendex/dev-round-authorizations/KEN-RESTACK-1-1.json"
restack_recovery="$restack_wt/tmp/dev-round-KEN-RESTACK-1-1.json"
assert_eq "$(jq -r '.base_sha' "$restack_auth")" "$restack_base" "external authorization moves to the restacked base snapshot"
assert_eq "$(jq -r '.base_sha' "$restack_recovery")" "$restack_base" "recovery copy moves to the same restacked base snapshot"
after_restack="$($ARTIFACT_CHECK --worktree "$restack_wt" --issue KEN-RESTACK --round-id 1-1)"
assert_eq "$(jq -r '.reason' <<<"$after_restack")" "valid" \
  "upstream protected addition is outside the remapped round snapshot"
assert_eq "$(jq -r '.live' "$restack_auth")" "false" "accepted round authorization is retired"

rm -f "$restack_recovery"
STUB_PUSH_STDOUT="rebase-map: $restack_base $restack_head" \
  run_push "$restack_state" --worktree "$restack_wt" --issue KEN-RESTACK
assert_eq "$RUN_RC" "0" "accepted historical round missing recovery does not block a later map"
assert_eq "$(jq -r '.base_sha' "$restack_auth")" "$restack_base" \
  "retired authorization is not remapped"

"$ROUND_WRITE" --worktree "$restack_wt" --issue KEN-RESTACK --round-id 3-3 --item 1 active >/dev/null
rm -f "$restack_wt/tmp/dev-round-KEN-RESTACK-3-3.json"
(cd "$restack_state" && "$STATE" set KEN-RESTACK dev_round_id 3-3)
STUB_PUSH_STDOUT="rebase-map: $restack_head $restack_base" \
  run_push "$restack_state" --worktree "$restack_wt" --issue KEN-RESTACK
assert_eq "$RUN_RC" "1" "active authorization missing recovery fails reconciliation closed"
assert_contains "$(cat "$run_err")" "recovery copy missing or not regular" \
  "active missing-recovery refusal names the required copy"
rm -f "$restack_wt/.git/kendex/dev-round-authorizations/KEN-RESTACK-3-3.json"

"$ROUND_WRITE" --worktree "$restack_wt" --issue KEN-RESTACK --round-id 4-4 --item 1 divergent >/dev/null
divergent_recovery="$restack_wt/tmp/dev-round-KEN-RESTACK-4-4.json"
jq '.adds = ["tools/not-authorized"]' "$divergent_recovery" > "$TMP_ROOT/divergent-recovery.json"
mv "$TMP_ROOT/divergent-recovery.json" "$divergent_recovery"
(cd "$restack_state" && "$STATE" set KEN-RESTACK dev_round_id 4-4)
STUB_PUSH_STDOUT="rebase-map: $restack_head $restack_base" \
  run_push "$restack_state" --worktree "$restack_wt" --issue KEN-RESTACK
assert_eq "$RUN_RC" "1" "divergent authorization copies fail reconciliation closed"
assert_contains "$(cat "$run_err")" "authorization and recovery copy diverge" \
  "divergence refusal names the violated round invariant"

echo
echo "=== a failed push still applies its map (rebase precedes the push) ==="

work="$TMP_ROOT/work-failed"
reset_state "$work"
STUB_PUSH_STDOUT="rebase-map: $OLD_A $NEW_A" STUB_PUSH_EXIT=7 run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "7" "push failure keeps the push's exit code"
assert_eq "$(state_json "$work" | jq -r ".rebase_map[\"$OLD_A\"]")" "$NEW_A" "map from a failed push is still recorded"
assert_eq "$(state_json "$work" | jq -r '.fixed_items[0].commit')" "${NEW_A:0:7}" "fix SHA rewritten even though the push failed"

echo
echo "=== a map the wrapper cannot record is reported, never swallowed ==="

# No state file: the push landed and the SHAs are stale. Silence here is the
# exact failure mode the wrapper exists to close, so the call fails, names the
# consequence, and replays the map's own lines in the transcript.
work="$TMP_ROOT/work-nostate"
rm -rf "$work" && mkdir -p "$work"
STUB_PUSH_STDOUT="rebase-map: $OLD_A $NEW_A" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "1" "missing state file fails the call"
assert_contains "$(cat "$run_err")" "NOT recorded" "missing state names the unreconciled-SHA consequence"
work="$TMP_ROOT/work-badmap"
reset_state "$work"
STUB_PUSH_STDOUT="rebase-map: not-a-sha $NEW_A" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "1" "unparseable map line fails the call"
assert_contains "$(cat "$run_err")" "NOT reconciled" "unparseable map names the unreconciled-SHA consequence"

# An unparseable map on a FAILED push keeps the push's exit code — exit 1
# must never dress a failed push as a landed one.
reset_state "$work"
STUB_PUSH_STDOUT="rebase-map: not-a-sha $NEW_A" STUB_PUSH_EXIT=7 run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "7" "unparseable map on a failed push keeps the push's exit code"
assert_contains "$(cat "$run_err")" "NOT reconciled" "the failed-push parse error still names the consequence"

echo
echo "=== a repaired state and a re-run do not reconcile the stranded map ==="

# The header contract and the failure diagnostic once told the operator to
# repair state and re-run. The sidecar that made that true is gone: the rebase
# already happened, so the retry's push prints no map, reconciles nothing, and
# exits 0 over the same stale record. Both surfaces must say so, or a stale
# SHA gets published in the belief the retry fixed it.
work="$TMP_ROOT/work-rerun"
rm -rf "$work" && mkdir -p "$work"
STUB_PUSH_STDOUT="rebase-map: $OLD_A $NEW_A" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "1" "the run that cannot record its map fails"
assert_contains "$(cat "$run_err")" "Re-running this command does NOT repair them" \
  "the diagnostic denies that a bare re-run repairs the record"
assert_contains "$(cat "$run_err")" "workflow-state update" "the diagnostic names the manual repair"

# Repair the state exactly as an operator would, then re-run.
(cd "$work" \
  && "$STATE" init KEN-1 --agent generalist --worktree "$wt" --branch ken-1 >/dev/null \
  && "$STATE" append KEN-1 fixed_items "{\"description\":\"fix\",\"commit\":\"${OLD_A:0:7}\",\"source\":\"pr-review\"}")
STUB_PUSH_STDOUT="→ pushed" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "0" "the re-run reports success"
assert_eq "$(state_json "$work" | jq -r '.fixed_items[0].commit')" "${OLD_A:0:7}" \
  "the re-run leaves the stale SHA stale, so it is not the repair"
assert_eq "$(state_json "$work" | jq -r '.rebase_map | length')" "0" \
  "the stranded map never reaches workflow state on the re-run"

# `--help` prints the leading comment block, so the exit-code table is a
# runtime surface and its recovery instruction is held to the same truth.
help_out="$("$PUSH" --help)"
assert_contains "$help_out" "re-running does not repair them" \
  "the exit-code table denies that a re-run repairs the record"
assert_contains "$help_out" "workflow-state update" "the exit-code table names the manual repair"

# Exit 1 covers two families and they want opposite repairs. The refusals
# asserted below (bad arguments, a state that does not resolve or does not
# match) exit before the push, so for them the sentences above are all false --
# nothing was rebased, no map was printed, and correcting the arguments and
# re-running IS the repair. Each family carries its own row or the split rots
# back into one sentence that misdirects half the operators who read it.
assert_contains "$help_out" "the run refused before the push" \
  "the exit-code table carries a row for the family where the push never ran"
assert_contains "$help_out" "Nothing was pushed and nothing was rebased" \
  "the never-ran row denies the rebase the post-push row asserts"
assert_contains "$help_out" "there is nothing to hand-apply" \
  "the never-ran row sends the operator back through the command instead of workflow-state"
assert_eq "$(grep -cE '^ *1 \(' <<<"$help_out")" "2" \
  "the exit-1 families are two rows, not one"

echo
echo "=== the arguments must match the state they would rewrite ==="

# The resolved state is both what the reconcile rewrites and what names the
# round authorization whose base_sha dev-artifact-check diffs against HEAD.
# Linked worktrees share one git common dir, so a state belonging to another
# issue or another worktree must refuse BEFORE the push rebases anything.
mismatch_args_log="$TMP_ROOT/mismatch-args.log"

work="$TMP_ROOT/work-mismatch"
rm -rf "$work" && mkdir -p "$work/tmp"
printf '%s\n' '{"issue_id":"KEN-9","worktree":"","fixed_items":[],"pr_comment_review":{"fixes":[]}}' >"$work/tmp/workflow-state-KEN-1.json"
: >"$mismatch_args_log"
STUB_ARGS_LOG="$mismatch_args_log" STUB_PUSH_STDOUT="→ pushed" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "1" "a state recording another issue id refuses"
assert_contains "$(cat "$run_err")" "refusing to rewrite another issue" "the issue mismatch is named"
assert_eq "$(wc -l <"$mismatch_args_log")" "0" "the push never ran against a mismatched issue id"

other_wt="$TMP_ROOT/other-wt"
mkdir -p "$other_wt"
work="$TMP_ROOT/work-wt-mismatch"
rm -rf "$work" && mkdir -p "$work"
(cd "$work" && "$STATE" init KEN-1 --agent generalist --worktree "$other_wt" --branch ken-1 >/dev/null)
: >"$mismatch_args_log"
STUB_ARGS_LOG="$mismatch_args_log" STUB_PUSH_STDOUT="→ pushed" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "1" "a state recording another worktree refuses"
assert_contains "$(cat "$run_err")" "refusing to rewrite another worktree" "the worktree mismatch is named"
assert_eq "$(wc -l <"$mismatch_args_log")" "0" "the push never ran against a mismatched worktree"

echo
echo "=== a dying stdout cannot lose the map ==="

# The map is parsed and persisted before the transcript replay, so even a
# full stdout (every print fails) leaves the mapping recorded in state.
# /dev/full is Linux-only; on hosts without it the case is skipped visibly.
if [[ -e /dev/full && -w /dev/full ]]; then
  work="$TMP_ROOT/work-devfull"
  reset_state "$work"
  RUN_RC=0
  (cd "$work" && STUB_PUSH_STDOUT="rebase-map: $OLD_A $NEW_A" "$PUSH" --worktree "$wt" --issue KEN-1) >/dev/full 2>"$run_err" || RUN_RC=$?
  [[ "$RUN_RC" -ne 0 ]] && pass "a dying stdout is reported as a failure" || fail "a dying stdout is reported as a failure"
  assert_eq "$(state_json "$work" | jq -r ".rebase_map[\"$OLD_A\"]")" "$NEW_A" "the map reaches workflow state despite the dead stdout"
  assert_eq "$(state_json "$work" | jq -r '.fixed_items[0].commit')" "${NEW_A:0:7}" "the fix SHA is rewritten despite the dead stdout"
else
  printf '  skip  %s\n' "dying-stdout case: /dev/full not available on this host"
fi

echo
echo "=== a parse failure still shows the map in the transcript ==="

# The completed rebase cannot regenerate the map, so the replayed transcript
# is its only surviving copy — valid lines beside the malformed one included.
work="$TMP_ROOT/work-parsefail-replay"
reset_state "$work"
map_out="rebase-map: $OLD_A $NEW_A
rebase-map: not-a-sha $NEW_A2"
STUB_PUSH_STDOUT="$map_out" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "1" "a malformed line beside a valid one still fails the call"
assert_contains "$(cat "$run_out")" "rebase-map: $OLD_A $NEW_A" "the valid map line survives in the replayed transcript"
assert_contains "$(cat "$run_out")" "rebase-map: not-a-sha $NEW_A2" "the malformed map line survives in the replayed transcript"

echo
echo "=== an unwritable state directory fails the landed push loudly ==="

# A state write that cannot land leaves the recorded SHAs stale, so the call
# fails and says so rather than exiting 0 on a push that landed. chmod mode
# bits do not bind root
# (CAP_DAC_OVERRIDE writes straight through them), so the denial is probed
# and the case skipped visibly where it cannot take effect — mirroring the
# /dev/full gate above.
work="$TMP_ROOT/work-rostate"
reset_state "$work"
before="$(state_json "$work")"
chmod a-w "$work/tmp"
if touch "$work/tmp/.write-probe" 2>/dev/null; then
  rm -f "$work/tmp/.write-probe"
  chmod u+w "$work/tmp"
  printf '  skip  %s\n' "unwritable-state-dir case: chmod a-w does not deny writes here (running as root?)"
else
  STUB_PUSH_STDOUT="rebase-map: $OLD_A $NEW_A" run_push "$work" --worktree "$wt" --issue KEN-1
  chmod u+w "$work/tmp"
  assert_eq "$RUN_RC" "1" "a failed state write fails the landed push"
  assert_contains "$(cat "$run_err")" "NOT recorded" "the failure names the unreconciled SHAs"
  assert_eq "$(state_json "$work")" "$before" "the unwritable state is left untouched"
  assert_contains "$(cat "$run_out")" "rebase-map: $OLD_A $NEW_A" "the map's own lines survive in the replayed transcript"
fi

echo
echo "=== the bare-numeric alias binds, not refuses ==="

# Issue N stored under issue-N is the one accepted spelling difference: the
# aliased state and authorization are this issue's records, and the push must
# reconcile both through the resolved key.
work="$TMP_ROOT/work-alias"
rm -rf "$work" && mkdir -p "$work"
git -C "$wt" config user.email test@example.com
git -C "$wt" config user.name Test
git -C "$wt" commit -q --allow-empty -m alias-base
alias_old="$(git -C "$wt" rev-parse HEAD)"
init_growth_state "$STATE" "$wt" issue-7 seed 1000000
"$ROUND_WRITE" --worktree "$wt" --issue issue-7 --round-id 5-5 --item 1 alias >/dev/null
git -C "$wt" commit -q --allow-empty -m alias-restack
alias_new="$(git -C "$wt" rev-parse HEAD)"
(cd "$work" \
  && "$STATE" init issue-7 --agent generalist --worktree "$wt" --branch issue-7 >/dev/null \
  && "$STATE" set issue-7 dev_round_id 5-5 \
  && "$STATE" append issue-7 fixed_items "{\"description\":\"fix\",\"commit\":\"${alias_old:0:7}\",\"source\":\"pr-review\"}")
STUB_PUSH_STDOUT="rebase-map: $alias_old $alias_new" run_push "$work" --worktree "$wt" --issue 7
assert_eq "$RUN_RC" "0" "a bare-numeric issue binds to its issue-N state instead of refusing"
assert_eq "$(jq -r '.fixed_items[0].commit' "$work/tmp/workflow-state-issue-7.json")" "${alias_new:0:7}" "the aliased record's fix SHA is rewritten"
alias_auth="$wt/.git/kendex/dev-round-authorizations/issue-7-5-5.json"
alias_recovery="$wt/tmp/dev-round-issue-7-5-5.json"
assert_eq "$(jq -r '.base_sha' "$alias_auth")" "$alias_new" "the aliased authorization follows the resolved state key"
assert_eq "$(jq -r '.base_sha' "$alias_recovery")" "$alias_new" "the aliased recovery copy follows the resolved state key"

echo
echo "=== an ambiguous state key refuses before pushing ==="

# Files under BOTH the bare-numeric and the issue-N key make the
# reconciliation target ambiguous (workflow-state exists exits 2). Proceeding
# would land a rebase whose map has no definite record to land in — the push
# must not run at all.
work="$TMP_ROOT/work-ambiguous"
rm -rf "$work" && mkdir -p "$work"
(cd "$work" \
  && "$STATE" init issue-7 --agent generalist --worktree "$wt" --branch issue-7 >/dev/null \
  && "$STATE" init 7 --agent generalist --worktree "$wt" --branch issue-7 >/dev/null)
ambig_args_log="$TMP_ROOT/ambig-args.log"
: >"$ambig_args_log"
STUB_ARGS_LOG="$ambig_args_log" STUB_PUSH_STDOUT="rebase-map: $OLD_A $NEW_A" \
  run_push "$work" --worktree "$wt" --issue 7
assert_eq "$RUN_RC" "1" "an ambiguous state key fails the call"
assert_contains "$(cat "$run_err")" "ambiguous" "the refusal names the ambiguity"
assert_eq "$(wc -l <"$ambig_args_log")" "0" "the push never runs against an ambiguous state"

echo
echo "=== duplicate subjects cannot advance an authorization base ==="

duplicate_wt="$TMP_ROOT/duplicate-subject-wt"
mkdir -p "$duplicate_wt"
git -C "$duplicate_wt" init -q -b main
git -C "$duplicate_wt" config user.email test@example.com
git -C "$duplicate_wt" config user.name Test
printf 'first\n' >"$duplicate_wt/first.txt"
git -C "$duplicate_wt" add first.txt
git -C "$duplicate_wt" commit -q -m 'same subject'
duplicate_first="$(git -C "$duplicate_wt" rev-parse HEAD)"
init_growth_state "$STATE" "$duplicate_wt" KEN-DUPLICATE seed 1000000
"$ROUND_WRITE" --worktree "$duplicate_wt" --issue KEN-DUPLICATE --round-id 1-1 --item 1 duplicate >/dev/null
printf 'second\n' >"$duplicate_wt/second.txt"
git -C "$duplicate_wt" add second.txt
git -C "$duplicate_wt" commit -q -m 'same subject'
duplicate_second="$(git -C "$duplicate_wt" rev-parse HEAD)"
duplicate_state="$TMP_ROOT/duplicate-subject-state"
mkdir -p "$duplicate_state"
(cd "$duplicate_state" && "$STATE" init KEN-DUPLICATE --agent generalist \
  --worktree "$duplicate_wt" --branch main >/dev/null \
  && "$STATE" set KEN-DUPLICATE dev_round_id 1-1)
STUB_PUSH_STDOUT="rebase-map: $duplicate_first $duplicate_second
rebase-map: $duplicate_second dropped" \
  run_push "$duplicate_state" --worktree "$duplicate_wt" --issue KEN-DUPLICATE
assert_eq "$RUN_RC" "1" "same-subject drop and survive mapping fails closed"
assert_contains "$(cat "$run_err")" "ambiguous authorization base" \
  "the refusal names the authorization mapping ambiguity"
duplicate_auth="$duplicate_wt/.git/kendex/dev-round-authorizations/KEN-DUPLICATE-1-1.json"
assert_eq "$(jq -r '.base_sha' "$duplicate_auth")" "$duplicate_first" \
  "an ambiguous mapping does not advance the authorization base"

"$ROUND_WRITE" --worktree "$duplicate_wt" --issue KEN-DUPLICATE --round-id 2-2 --item 1 positional >/dev/null
duplicate_equal_old="$(git -C "$duplicate_wt" rev-parse HEAD)"
git -C "$duplicate_wt" commit -q --allow-empty -m 'same subject'
duplicate_equal_new_first="$(git -C "$duplicate_wt" rev-parse HEAD)"
git -C "$duplicate_wt" commit -q --allow-empty -m 'same subject'
duplicate_equal_new_second="$(git -C "$duplicate_wt" rev-parse HEAD)"
(cd "$duplicate_state" && "$STATE" set KEN-DUPLICATE dev_round_id 2-2)
STUB_PUSH_STDOUT="rebase-map: $duplicate_first $duplicate_equal_new_first
rebase-map: $duplicate_equal_old $duplicate_equal_new_second" \
  run_push "$duplicate_state" --worktree "$duplicate_wt" --issue KEN-DUPLICATE
assert_eq "$RUN_RC" "0" "equal-count duplicate subjects keep positional authorization mapping"
duplicate_equal_auth="$duplicate_wt/.git/kendex/dev-round-authorizations/KEN-DUPLICATE-2-2.json"
assert_eq "$(jq -r '.base_sha' "$duplicate_equal_auth")" "$duplicate_equal_new_second" \
  "equal-count mapping advances the authorization base by position"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
