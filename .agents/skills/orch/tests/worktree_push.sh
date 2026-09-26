#!/usr/bin/env bash
# Tests for worktree-push: the push wrapper that reconciles
# rebased commit SHAs in workflow state. A `rebase-map:` line from the
# worktree skill's push must land in `.rebase_map` and rewrite every recorded
# fix commit in the same call — including when the network push itself fails,
# because the rebase (and its map) happens before the push. A map the wrapper
# cannot record is reported, with the replayed transcript as its only
# surviving copy; nothing may leave stale SHAs silently. A completed restack
# leaves its own map in the worktree instead of on a stream, so that file is
# consumed and deleted before the push, and its hop is applied before the
# push's own so a record moved twice ends on the final SHA.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

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

# Physical: on macOS the temp root sits under /var -> /private/var, and the
# scripts print the resolved path.
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT
# The mode a fix round runs is read from the project's settings, and orch-env
# reads the process environment first: a developer's own range command would
# otherwise decide the fix receipts' acceptance.
unset DEV_VALIDATE_RANGE_CMD
mkdir -p "$TMP_ROOT/linear/scripts"
cat > "$TMP_ROOT/linear/scripts/linear.sh" <<'SH'
#!/usr/bin/env bash
set -eu
row="$(jq -c --arg id "$4" '.[] | select(.identifier == $id)' .cache/linear/issues.json)"
[[ -n "$row" ]] || exit 1
jq -n --argjson issue "$row" '{issue: $issue}'
SH
chmod +x "$TMP_ROOT/linear/scripts/linear.sh"
ROUND_WRITE_BIN="$(copy_scripts live)/dev-round-write"

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
# logs its argv so pass-through flags can be asserted. It also does what the
# real push does with a map it derives: appends it to the worktree's map file
# as its own hop, which is the channel worktree-push reconciles from. A stub
# that only printed would exercise a transcript nothing reads.
stub="$TMP_ROOT/worktree-stub"
cat >"$stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_ARGS_LOG:-/dev/null}"
if [[ -n "${STUB_PUSH_STDOUT:-}" ]]; then
  printf '%s\n' "$STUB_PUSH_STDOUT"
  stub_map="$(printf '%s\n' "$STUB_PUSH_STDOUT" | grep '^rebase-map: ' || true)"
  if [[ -n "$stub_map" && -n "${2:-}" ]]; then
    stub_file="$(git -C "$2" rev-parse --git-path kendex-rebase-map)"
    [[ "$stub_file" == /* ]] || stub_file="$2/$stub_file"
    printf 'rebase-hop:\n%s\n' "$stub_map" >>"$stub_file"
  fi
fi
exit "${STUB_PUSH_EXIT:-0}"
EOF
chmod +x "$stub"
export ORCH_WORKTREE_BIN="$stub"

OLD_A="$(printf 'a%.0s' {1..39})0"
OLD_B="$(printf 'b%.0s' {1..39})1"
NEW_A="$(printf 'c%.0s' {1..39})2"
NEW_A2="$(printf 'd%.0s' {1..39})3"

# The pushed worktree is a real git checkout: a fix round's record lives in ITS
# tmp/, never in the state directory.
wt="$TMP_ROOT/wt"
git init -q -b main "$wt"
mkdir -p "$wt/tmp"

# The worktree-private file every rewrite records its map in. It outlives the
# run that wrote it by design, so each block starts from a clean one: a record
# left by the block above would refuse the next block's push before it ran.
restack_map_file="$(git -C "$wt" rev-parse --git-path kendex-rebase-map)"
[[ "$restack_map_file" == /* ]] || restack_map_file="$wt/$restack_map_file"

# Fresh state with recorded fix commits on both surfaces: a short prefix of
# OLD_A in fixed_items; in pr_comment_review.fixes one prefix of OLD_B
# (mapped to dropped) and one longer prefix of OLD_A (mapped to a real SHA),
# so both the rewrite and the dropped-marking paths run on .fixes.
reset_state() {
  local work="$1"
  rm -f "$restack_map_file"
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
assert_eq "$(cat "$run_out")" "→ pushed" "push stdout is replayed"
assert_eq "$(grep -c 'sha-reconcile:' "$run_out" || true)" "0" "no reconcile line without a map"
assert_eq "$(grep -c 'restack-reconcile:' "$run_out" || true)" "0" "no restack-hop line without a pending restack map"
assert_eq "$(state_json "$work")" "$before" "state is untouched without a map"

echo
echo "=== flag parsing and pass-through ==="

args_log="$TMP_ROOT/args.log"
: >"$args_log"
STUB_ARGS_LOG="$args_log" STUB_PUSH_STDOUT="" run_push "$work" --worktree "$wt" --issue KEN-1 --set-upstream
assert_contains "$(cat "$args_log")" "push $wt --set-upstream" "worktree push receives the worktree and pass-through flags"

STUB_PUSH_STDOUT="" run_push "$work" "--worktree=$wt" --issue=KEN-1
assert_eq "$RUN_RC" "0" "equals-form flags parse"

# the wrapper keeps no copy of push's flag vocabulary. A flag it does
# not own is forwarded verbatim, and `worktree push` — which fails closed on an
# unknown flag — is the one that rejects it.
: >"$args_log"
STUB_ARGS_LOG="$args_log" STUB_PUSH_STDOUT="" run_push "$work" --worktree "$wt" --issue KEN-1 --no-rebase --future-flag
assert_contains "$(cat "$args_log")" "push $wt --no-rebase --future-flag" "flags the wrapper does not own are forwarded verbatim, in order"

: >"$args_log"
STUB_ARGS_LOG="$args_log" STUB_PUSH_EXIT=1 run_push "$work" --worktree "$wt" --issue KEN-1 --force
assert_eq "$RUN_RC" "1" "a flag push rejects fails the wrapper with push's own exit code"
assert_contains "$(cat "$args_log")" "push $wt --force" "the rejected flag reached push rather than being screened here"

# a mangled --state-dir (--sate-dir here, a transposition no prefix
# guess catches) is push's to reject, not this wrapper's — the flag vocabulary
# lives in one place. This case runs the REAL worktree script, so the two
# scripts' wiring is held: the argument order the wrapper sends, and push's
# own diagnostic reaching the caller. It runs FROM the worktree because the
# worktree script resolves its project at startup and refuses before parsing
# anything when its working directory is not a repository.
work="$TMP_ROOT/work-owned-typo"
reset_state "$work"
typo_before="$(state_json "$work")"
RUN_RC=0
(cd "$wt" && ORCH_WORKTREE_BIN="$REPO_ROOT/skills/worktree/scripts/worktree" \
  "$PUSH" --worktree "$wt" --issue KEN-1 --state-dir "$work/tmp" "--sate-dir=$TMP_ROOT/elsewhere") \
  >"$run_out" 2>"$run_err" || RUN_RC=$?
assert_eq "$RUN_RC" "1" "the real push refuses a transposed owned flag through this wrapper"
assert_contains "$(cat "$run_err")" "--sate-dir=$TMP_ROOT/elsewhere" "push's own diagnostic reaches the caller"
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
assert_eq "$(grep '^sha-reconcile:' "$run_out")" "sha-reconcile: map_entries=2 fixed_items=1 pr_fixes=2" "reconcile summary reports what changed"

echo
echo "=== a second push chains through the already-rewritten SHA ==="

STUB_PUSH_STDOUT="rebase-map: $NEW_A $NEW_A2" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "0" "second mapped push exits 0"
assert_eq "$(state_json "$work" | jq -r '.rebase_map | length')" "3" "second map merges into rebase_map"
assert_eq "$(state_json "$work" | jq -r '.fixed_items[0].commit')" "${NEW_A2:0:7}" "already-rewritten SHA follows the new mapping"
assert_eq "$(state_json "$work" | jq -r '.pr_comment_review.fixes[0].commit')" "dropped:${OLD_B:0:8}" "a dropped-marked commit stays marked across pushes"

echo
echo "=== a restack's pending map is consumed before the push, and chains into it ==="

work="$TMP_ROOT/work-restack"
reset_state "$work"
printf 'rebase-hop:\nrebase-map: %s %s\nrebase-map: %s dropped\n' "$OLD_A" "$NEW_A" "$OLD_B" >"$restack_map_file"
STUB_PUSH_STDOUT="→ pushed" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "0" "a consumed restack map exits 0"
assert_eq "$(grep '^restack-reconcile:' "$run_out")" "restack-reconcile: map_entries=2 fixed_items=1 pr_fixes=2" \
  "the restack hop reports under its own key"
assert_eq "$(grep -c '^sha-reconcile:' "$run_out" || true)" "0" \
  "a push that printed no map of its own reports no push hop"
assert_eq "$(state_json "$work" | jq -r ".rebase_map[\"$OLD_A\"]")" "$NEW_A" "the restack hop is recorded in rebase_map"
assert_eq "$(state_json "$work" | jq -r '.fixed_items[0].commit')" "${NEW_A:0:7}" "the restack hop rewrites the recorded fix SHA"
assert_eq "$(state_json "$work" | jq -r '.pr_comment_review.fixes[0].commit')" "dropped:${OLD_B:0:8}" \
  "a dropped restack mapping marks the recorded commit unpublishable"
assert_eq "$([[ -e "$restack_map_file" ]] && echo present || echo absent)" "absent" \
  "the file is deleted once its mappings are in workflow state"

# Both hops in one call. Each reconciliation compares a record against its
# original value, so only applying the restack hop first carries the record
# from OLD_A through NEW_A to NEW_A2; one merged map would leave it at NEW_A.
work="$TMP_ROOT/work-restack-chain"
reset_state "$work"
printf 'rebase-hop:\nrebase-map: %s %s\n' "$OLD_A" "$NEW_A" >"$restack_map_file"
STUB_PUSH_STDOUT="rebase-map: $NEW_A $NEW_A2" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "0" "both hops in one call exit 0"
assert_eq "$(grep '^restack-reconcile:' "$run_out")" "restack-reconcile: map_entries=1 fixed_items=1 pr_fixes=1" \
  "the restack hop reports first"
assert_eq "$(grep '^sha-reconcile:' "$run_out")" "sha-reconcile: map_entries=1 fixed_items=1 pr_fixes=1" \
  "the push hop reports second"
assert_eq "$(state_json "$work" | jq -r '.fixed_items[0].commit')" "${NEW_A2:0:7}" \
  "the record follows both hops to the final SHA"
assert_eq "$([[ -e "$restack_map_file" ]] && echo present || echo absent)" "absent" "the chained call deletes the file too"

# Two restacks before one push: one file, two hops. Read as one map, both would
# be compared against the record's pre-hop SHA and it would stop at NEW_A, a
# commit the second restack rewrote away and no branch has. Each hop is its own
# reconciliation, so the record arrives at the SHA the branch actually carries.
work="$TMP_ROOT/work-restack-twice"
reset_state "$work"
printf 'rebase-hop:\nrebase-map: %s %s\nrebase-hop:\nrebase-map: %s %s\n' \
  "$OLD_A" "$NEW_A" "$NEW_A" "$NEW_A2" >"$restack_map_file"
STUB_PUSH_STDOUT="→ pushed" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "0" "a file holding two restack hops exits 0"
assert_eq "$(grep -c '^restack-reconcile:' "$run_out")" "2" "each hop reports its own summary line"
assert_eq "$(state_json "$work" | jq -r '.fixed_items[0].commit')" "${NEW_A2:0:7}" \
  "the record follows both restack hops to the SHA the branch carries"
assert_eq "$(state_json "$work" | jq -r '.pr_comment_review.fixes[1].commit')" "${NEW_A2:0:10}" \
  "and so does the longer prefix recorded on the other surface"
assert_eq "$(state_json "$work" | jq -r '.rebase_map | length')" "2" "both hops merge into rebase_map"
assert_eq "$([[ -e "$restack_map_file" ]] && echo present || echo absent)" "absent" \
  "the file is deleted once every hop is recorded"

# A file the wrapper cannot turn into a mapping is the writer's own defect, and
# deleting it would lose the only record of a rewrite that already happened.
work="$TMP_ROOT/work-restack-junk"
reset_state "$work"
junk_before="$(state_json "$work")"
printf 'not a map line\n' >"$restack_map_file"
: >"$args_log"
STUB_ARGS_LOG="$args_log" STUB_PUSH_STDOUT="→ pushed" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "1" "a restack map file that is not a hop record refuses"
assert_eq "$(grep '^worktree-push:' "$run_err")" \
  "worktree-push: restack-map-grammar file=$restack_map_file hops_applied=0" \
  "the refusal names the file whose grammar it could not apply, and that no hop landed"
assert_eq "$([[ -s "$args_log" ]] && echo ran || echo no)" "no" "the refusal lands before the push"
assert_eq "$(state_json "$work")" "$junk_before" "the refused run leaves workflow state alone"
assert_eq "$([[ -e "$restack_map_file" ]] && echo present || echo absent)" "present" "the unconsumed file is left in place"

# Hops are written at their boundary, so a valid hop before a malformed one is
# already in workflow state when the refusal lands. The refusal reports how
# many landed: telling the operator nothing did would send them to re-apply
# work that is done.
work="$TMP_ROOT/work-restack-partial"
reset_state "$work"
printf 'rebase-hop:\nrebase-map: %s %s\nrebase-hop:\nnot a map line\n' "$OLD_A" "$NEW_A" >"$restack_map_file"
: >"$args_log"
STUB_ARGS_LOG="$args_log" STUB_PUSH_STDOUT="→ pushed" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "1" "a malformed hop after a valid one refuses"
assert_eq "$(grep '^worktree-push:' "$run_err")" \
  "worktree-push: restack-map-grammar file=$restack_map_file hops_applied=1" \
  "the refusal reports the hop that did land"
assert_eq "$(state_json "$work" | jq -r '.fixed_items[0].commit')" "${NEW_A:0:7}" \
  "and that hop is in workflow state, as the count says"
assert_eq "$([[ -s "$args_log" ]] && echo ran || echo no)" "no" "the refusal still lands before the push"
assert_eq "$([[ -e "$restack_map_file" ]] && echo present || echo absent)" "present" \
  "the whole file is kept, the applied hop included"

# No record at all. The restack already made recorded SHAs stale wherever they
# were written, so this refuses before the push and keeps the file; the message
# is the one for an absent record, not the one for a record that could not be
# written, because there is nothing here to repair.
work="$TMP_ROOT/work-restack-nostate"
rm -f "$restack_map_file"
rm -rf "$work" && mkdir -p "$work"
printf 'rebase-hop:\nrebase-map: %s %s\n' "$OLD_A" "$NEW_A" >"$restack_map_file"
: >"$args_log"
STUB_ARGS_LOG="$args_log" STUB_PUSH_STDOUT="→ pushed" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "1" "a restack map with no record to move refuses"
assert_eq "$(grep '^worktree-push:' "$run_err")" \
  "worktree-push: restack-map-nostate issue=KEN-1 state=$work/tmp/workflow-state-KEN-1.json file=$restack_map_file" \
  "the refusal names the absent record, not a write that failed"
assert_contains "$(cat "$run_err")" "Init the record and re-run, or remove the map file." \
  "and sends the operator at the record, not at repairing one that does not exist"
assert_eq "$([[ -s "$args_log" ]] && echo ran || echo no)" "no" "the unrecordable map refuses before the push"
assert_eq "$([[ -e "$restack_map_file" ]] && echo present || echo absent)" "present" "the unrecorded file is left in place"

# A rebase that rewrote the branch without a derivable map is recorded in the
# same file. No mapping repairs that rewrite, so this refuses under its own key
# before any hop is applied rather than under the grammar refusal, which would
# be a correct refusal carrying the wrong cause.
work="$TMP_ROOT/work-restack-unmapped"
reset_state "$work"
unmapped_before="$(state_json "$work")"
printf 'rebase-hop:\nrebase-map: %s %s\nrebase-unmapped: %s\n' "$OLD_A" "$NEW_A" "$OLD_B" >"$restack_map_file"
: >"$args_log"
STUB_ARGS_LOG="$args_log" STUB_PUSH_STDOUT="→ pushed" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "1" "a recorded unmapped rewrite refuses"
assert_eq "$(grep '^worktree-push:' "$run_err")" \
  "worktree-push: rebase-unmapped head=$OLD_B file=$restack_map_file" \
  "the refusal names the head the rewrite started from, under its own key"
assert_eq "$(grep -c '^restack-reconcile:' "$run_out" || true)" "0" \
  "no hop is applied while the unmapped rewrite stands"
assert_eq "$(state_json "$work")" "$unmapped_before" "workflow state is left alone"
assert_eq "$([[ -s "$args_log" ]] && echo ran || echo no)" "no" "the refusal lands before the push"
assert_eq "$([[ -e "$restack_map_file" ]] && echo present || echo absent)" "present" \
  "the whole file is kept for the operator to read"
rm -f "$restack_map_file"

# A record that exists but cannot be written: the hop is not recorded, and the
# refusal says so under its own key with the count of what did land. chmod mode
# bits do not bind root, so the denial is probed and the case skipped visibly
# where it cannot take effect.
work="$TMP_ROOT/work-restack-unwritable"
reset_state "$work"
unwritable_before="$(state_json "$work")"
printf 'rebase-hop:\nrebase-map: %s %s\n' "$OLD_A" "$NEW_A" >"$restack_map_file"
chmod a-w "$work/tmp"
if touch "$work/tmp/.write-probe" 2>/dev/null; then
  rm -f "$work/tmp/.write-probe"
  chmod u+w "$work/tmp"
  rm -f "$restack_map_file"
  printf '  skip  %s\n' "unwritable-state case: chmod a-w does not deny writes here (running as root?)"
else
  : >"$args_log"
  STUB_ARGS_LOG="$args_log" STUB_PUSH_STDOUT="→ pushed" run_push "$work" --worktree "$wt" --issue KEN-1
  chmod u+w "$work/tmp"
  assert_eq "$RUN_RC" "1" "a hop that cannot be written refuses"
  assert_eq "$(grep '^worktree-push:' "$run_err")" \
    "worktree-push: restack-map-write issue=KEN-1 state=$work/tmp/workflow-state-KEN-1.json file=$restack_map_file hops_applied=0" \
    "the refusal names the unwritten hop and that none landed before it"
  assert_eq "$(state_json "$work")" "$unwritable_before" "the unwritable state is left untouched"
  assert_eq "$([[ -s "$args_log" ]] && echo ran || echo no)" "no" "the unwritten hop refuses before the push"
  assert_eq "$([[ -e "$restack_map_file" ]] && echo present || echo absent)" "present" "the unrecorded file is kept"
  rm -f "$restack_map_file"
fi

# A consumed file that cannot be deleted would be read again by a later run,
# so the call fails rather than reporting success over a file it still owns.
# chmod mode bits do not bind root, so the denial is probed and the case
# skipped visibly where it cannot take effect.
work="$TMP_ROOT/work-restack-stuck"
reset_state "$work"
printf 'rebase-hop:\nrebase-map: %s %s\n' "$OLD_A" "$NEW_A" >"$restack_map_file"
restack_map_dir="$(dirname "$restack_map_file")"
chmod a-w "$restack_map_dir"
if touch "$restack_map_dir/.write-probe" 2>/dev/null; then
  rm -f "$restack_map_dir/.write-probe"
  chmod u+w "$restack_map_dir"
  rm -f "$restack_map_file"
  printf '  skip  %s\n' "undeletable-map case: chmod a-w does not deny writes here (running as root?)"
else
  : >"$args_log"
  STUB_ARGS_LOG="$args_log" STUB_PUSH_STDOUT="→ pushed" run_push "$work" --worktree "$wt" --issue KEN-1
  chmod u+w "$restack_map_dir"
  assert_eq "$RUN_RC" "1" "a consumed file that cannot be deleted fails the call"
  assert_eq "$(grep '^worktree-push:' "$run_err")" "worktree-push: restack-map-clear file=$restack_map_file" \
    "the failure names the file a later run would read again"
  assert_eq "$([[ -s "$args_log" ]] && echo ran || echo no)" "no" "the undeletable file refuses before the push"
  rm -f "$restack_map_file"
fi

echo
echo "=== a live fix round refuses the push before anything is rebased ==="

# The round record pins the base snapshot dev-artifact-check compares against;
# the rebase this wrapper runs would move the branch off it. The refusal lands
# BEFORE the push, so nothing is rebased and nothing needs hand repair.
live_wt="$TMP_ROOT/live-wt"
mkdir -p "$live_wt"
git -C "$live_wt" init -q -b main
git -C "$live_wt" config user.email test@example.com
git -C "$live_wt" config user.name Test
git -C "$live_wt" config commit.gpgsign false
git -C "$live_wt" commit -q --allow-empty -m delegation-base
live_old="$(git -C "$live_wt" rev-parse HEAD)"
init_growth_state "$STATE" "$live_wt" KEN-LIVE seed 1000000
mkdir -p "$live_wt/.cache/linear"
printf '[{"identifier":"KEN-LIVE","description":"**Expected delta**: 1000000 lines, 1000000 test lines"}]\n' \
  > "$live_wt/.cache/linear/issues.json"
printf '.cache/\n' >> "$(git -C "$live_wt" rev-parse --path-format=absolute --git-path info/exclude)"
"$ROUND_WRITE" --worktree "$live_wt" --issue KEN-LIVE --round-id 1-1 --item 1 live "tools/guard on a staged render" >/dev/null
git -C "$live_wt" commit -q --allow-empty -m round-fix
live_head="$(git -C "$live_wt" rev-parse HEAD)"

live_state="$TMP_ROOT/live-state"
mkdir -p "$live_state"
(cd "$live_state" && "$STATE" init KEN-LIVE --agent generalist \
  --worktree "$live_wt" --branch main >/dev/null \
  && "$STATE" set KEN-LIVE dev_round_id 1-1)
live_args="$TMP_ROOT/live-args.log"
: > "$live_args"
STUB_ARGS_LOG="$live_args" STUB_PUSH_STDOUT="rebase-map: $live_old $live_head" \
  run_push "$live_state" --worktree "$live_wt" --issue KEN-LIVE
assert_eq "$RUN_RC" "1" "a live round record refuses the push"
assert_eq "$(grep '^worktree-push:' "$run_err")" "worktree-push: live-round round=1-1 worktree=$live_wt" "the refusal names the live round"
assert_eq "$([[ -s "$live_args" ]] && echo ran || echo no)" "no" \
  "the refusal lands before the push: the pushed-through command never ran"
assert_eq "$(cat "$live_state/tmp/workflow-state-KEN-LIVE.json" | jq -r '.rebase_map // "none"')" "none" \
  "a refused run records no rebase map"

# The round closes when its dev-return receipt lands: the push then proceeds.
"$RETURN_WRITE" --worktree "$live_wt" --kind fix --issue KEN-LIVE --round-id 1-1 \
  --branch main --commit "$live_head" --validate pass --validate-run-dir "$(round_run_dir "$TMP_ROOT/run-livewt-1-1-1" "$live_wt" KEN-LIVE 1-1)" --item 1 Applied done >/dev/null
assert_eq "$("$ARTIFACT_CHECK" --worktree "$live_wt" --issue KEN-LIVE --round-id 1-1 \
  --expect-items-from-round | jq -r '.reason')" "valid" "the returned round accepts"
: > "$live_args"
STUB_ARGS_LOG="$live_args" STUB_PUSH_STDOUT="rebase-map: $live_old $live_head" \
  run_push "$live_state" --worktree "$live_wt" --issue KEN-LIVE
assert_eq "$RUN_RC" "0" "a returned round no longer blocks the push"
assert_eq "$(cat "$live_state/tmp/workflow-state-KEN-LIVE.json" | jq -r ".rebase_map[\"$live_old\"]")" \
  "$live_head" "the unblocked push records its map"

# One test per conjunct of the gate: deleting any of them reds the suite.

# The record's existence is the conjunct that decides in the PERMISSIVE
# direction, so only a passing push can prove it. An implement round mints a
# round id through `workflow-state new-round-id` and never runs dev-round-write, so its state
# names a round with no record at all: without this check every such push would
# refuse, and a suite of refusal assertions alone would call that correct.
(cd "$live_state" && "$STATE" set KEN-LIVE dev_round_id 9-9)
assert_eq "$([[ -e "$live_wt/tmp/dev-round-KEN-LIVE-9-9.json" ]] && echo present || echo absent)" "absent" \
  "control: the implement round names a round id with no record on disk"
: > "$live_args"
# A mapping this state has never seen, so only THIS push can have recorded it.
STUB_ARGS_LOG="$live_args" STUB_PUSH_STDOUT="rebase-map: $OLD_B $NEW_A" \
  run_push "$live_state" --worktree "$live_wt" --issue KEN-LIVE
assert_eq "$RUN_RC" "0" "a round id with no record does not block the push"
assert_eq "$([[ -s "$live_args" ]] && echo ran || echo no)" "ran" \
  "the unblocked implement round reaches the push"
assert_eq "$(cat "$live_state/tmp/workflow-state-KEN-LIVE.json" | jq -r ".rebase_map[\"$OLD_B\"]")" \
  "$NEW_A" "the unblocked implement round still reconciles its map"
(cd "$live_state" && "$STATE" set KEN-LIVE dev_round_id 1-1)

# Must-fail control: with the refusal removed, the live round is pushed over.
# The copy carries the whole scripts directory so the mutant resolves its
# siblings (workflow-state) exactly as the real script does.
mutant_root="$TMP_ROOT/live-refusal-mutant"
mkdir -p "$mutant_root"
cp -R "$REPO_ROOT/skills/orch/scripts" "$mutant_root/"
live_mutant="$mutant_root/scripts/worktree-push"
assert_eq "$(grep -c 'refuse_live_round "\$active_round"' "$live_mutant")" "1" \
  "control finds exactly one live-round refusal to remove"
sed -i.bak 's/refuse_live_round "\$active_round"/: "no refusal"/' "$live_mutant"
chmod +x "$live_mutant"
assert_eq "$(grep -c 'refuse_live_round "\$active_round"' "$live_mutant")" "0" \
  "control removes the refusal only from its private copy"
rm -f "$live_wt/tmp/dev-return-KEN-LIVE-1-1.json"
: > "$live_args"
mutant_rc=0
(cd "$live_state" && STUB_ARGS_LOG="$live_args" STUB_PUSH_STDOUT="" \
  "$live_mutant" --worktree "$live_wt" --issue KEN-LIVE) >/dev/null 2>&1 || mutant_rc=$?
assert_eq "$mutant_rc" "0" "control: the mutant pushes the live round"
assert_eq "$([[ -s "$live_args" ]] && echo ran || echo no)" "ran" \
  "control: the mutant reached the push the refusal blocks"

echo
echo "=== --check-live-round answers the question alone, for the restack path ==="

# merge-pr's restack cycle rebases without reaching the push, so it asks here.
# Exit 0 permits the rebase, 3 is a live round, and anything else is a question
# left unanswered — which is not permission.
check_args="$TMP_ROOT/check-args.log"
: > "$check_args"
# The must-fail control above left -1 live; land its receipt again so
# this block starts from a branch that may be rebased.
"$RETURN_WRITE" --worktree "$live_wt" --kind fix --issue KEN-LIVE --round-id 1-1 \
  --branch main --commit "$live_head" --validate pass --validate-run-dir "$(round_run_dir "$TMP_ROOT/run-livewt-1-1-2" "$live_wt" KEN-LIVE 1-1)" --item 1 Applied done >/dev/null
STUB_ARGS_LOG="$check_args" run_push "$live_state" --check-live-round \
  --worktree "$live_wt" --issue KEN-LIVE
assert_eq "$RUN_RC" "0" "with no live round the check permits the rebase"
assert_eq "$([[ -s "$check_args" ]] && echo ran || echo no)" "no" \
  "the check pushes nothing, whatever its answer"
(cd "$live_state" && "$STATE" set KEN-LIVE dev_round_id 1-1)
rm -f "$live_wt/tmp/dev-return-KEN-LIVE-1-1.json"
STUB_ARGS_LOG="$check_args" run_push "$live_state" --check-live-round \
  --worktree "$live_wt" --issue KEN-LIVE
assert_eq "$RUN_RC" "3" "a live round answers 3, distinct from every other refusal"
assert_eq "$(grep '^worktree-push:' "$run_err")" "worktree-push: live-round round=1-1 worktree=$live_wt" "the check names the live round"
assert_eq "$([[ -s "$check_args" ]] && echo ran || echo no)" "no" \
  "the live answer still pushes nothing"

# A state that cannot be read is not a state with no round. Each arm stubs one
# answer, and the honest stub above is the control that they are the cause.
check_stub_root="$TMP_ROOT/check-stub"
mkdir -p "$check_stub_root"
cp -R "$REPO_ROOT/skills/orch/scripts" "$check_stub_root/"
check_stub="$check_stub_root/scripts/worktree-push"
cat > "$check_stub_root/scripts/workflow-state" <<'EOF'
#!/usr/bin/env bash
# Answers the two state reads worktree-push makes, honestly unless told
# otherwise: the identity reads must pass so each case fails for its own
# reason, and only the named answer is broken.
mode=""
for arg in "$@"; do
  case "$arg" in
  exists) mode=exists ;;
  get) mode=get ;;
  *issue_id*) [[ "$mode" == get ]] && { printf 'KEN-LIVE\n'; exit 0; } ;;
  *dev_round_id*)
    [[ "$mode" == get ]] || continue
    [[ "${STUB_GET:-}" == fail ]] && exit 5
    printf '\n'
    exit 0
    ;;
  esac
done
# The honest answer is a variable, not a default word: Bash 3.2 keeps the
# backslash of a `\}` inside `${var:-word}`, which is not JSON.
honest='{"path":"/x","exists":true}'
if [[ "$mode" == exists ]]; then
  [[ "${STUB_EXISTS:-}" == fail ]] && exit 7
  printf '%s\n' "${STUB_EXISTS_JSON:-$honest}"
fi
exit 0
EOF
chmod +x "$check_stub_root/scripts/workflow-state" "$check_stub"
# Every refusal in this script exits 1, so the exit code alone cannot tell one
# arm from the one below it: each case asserts the message its own arm prints.
check_err="$TMP_ROOT/check-stub.err"
check_rc() {
  local rc=0
  (cd "$live_state" && "$@" --check-live-round --worktree "$live_wt" --issue KEN-LIVE) \
    >/dev/null 2>"$check_err" || rc=$?
  printf '%s' "$rc"
}
assert_eq "$(check_rc env "$check_stub")" "0" \
  "control: an honest stub answering no round permits the rebase"
assert_eq "$(check_rc env STUB_EXISTS=fail "$check_stub")" "1" \
  "an exists that fails hands back rather than permitting"
assert_eq "$(grep '^worktree-push:' "$check_err")" "worktree-push: state-resolve issue=KEN-LIVE exit=7" \
  "and hands back through the arm that names the failed exists"
assert_eq "$(check_rc env STUB_EXISTS_JSON='{"path":"/x","exists":"maybe"}' "$check_stub")" "1" \
  "an answer that is neither yes nor no hands back"
assert_eq "$(grep '^worktree-push:' "$check_err")" 'worktree-push: state-answer issue=KEN-LIVE answer={"path":"/x","exists":"maybe"}' \
  "and hands back through the arm that names the malformed answer"
assert_eq "$(check_rc env STUB_GET=fail "$check_stub")" "1" \
  "a round read that fails hands back rather than permitting"
assert_eq "$(grep '^worktree-push:' "$check_err")" "worktree-push: round-read issue=KEN-LIVE" \
  "and hands back through the arm that names the failed round read"

# Check mode forwards nothing to the push, so an argument it cannot honour
# would vanish and the answer would be about a state the caller never asked
# for. A mistyped --state-dir is the case: refuse instead of permitting.
assert_eq "$(check_rc "$REPO_ROOT/skills/orch/scripts/worktree-push" --sate-dir=/nowhere)" "1" \
  "an argument check mode cannot honour refuses rather than permits"
assert_eq "$(grep '^worktree-push:' "$check_err")" "worktree-push: check-argument argument=--sate-dir=/nowhere" \
  "and the refusal names the argument it could not honour"

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
rm -f "$restack_map_file"
rm -rf "$work" && mkdir -p "$work"
STUB_PUSH_STDOUT="rebase-map: $OLD_A $NEW_A" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "1" "missing state file fails the call"
assert_eq "$(grep '^worktree-push:' "$run_err")" \
  "worktree-push: restack-map-nostate issue=KEN-1 state=$work/tmp/workflow-state-KEN-1.json file=$restack_map_file push-exit=0" \
  "missing state names the unreconciled-SHA consequence"
work="$TMP_ROOT/work-badmap"
reset_state "$work"
STUB_PUSH_STDOUT="rebase-map: not-a-sha $NEW_A" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "1" "unparseable map line fails the call"
assert_eq "$(grep '^worktree-push:' "$run_err")" \
  "worktree-push: map-sha field=old sha=not-a-sha file=$restack_map_file hops_applied=0 push-exit=0" \
  "unparseable map names the unreconciled-SHA consequence"

# An unparseable map on a FAILED push keeps the push's exit code — exit 1
# must never dress a failed push as a landed one.
reset_state "$work"
STUB_PUSH_STDOUT="rebase-map: not-a-sha $NEW_A" STUB_PUSH_EXIT=7 run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "7" "unparseable map on a failed push keeps the push's exit code"
assert_eq "$(grep '^worktree-push:' "$run_err")" \
  "worktree-push: map-sha field=old sha=not-a-sha file=$restack_map_file hops_applied=0 push-exit=7" \
  "the failed-push parse error still names the consequence"

echo
echo "=== a repaired state and a re-run reconcile the map the failure kept ==="

# The map is not in the transcript, it is in the worktree's map file, and a
# failed reconcile keeps that file. So repairing the state and re-running IS
# the repair here: the kept hop is consumed before the retry's own push, which
# rebases nothing and prints nothing of its own.
work="$TMP_ROOT/work-rerun"
rm -f "$restack_map_file"
rm -rf "$work" && mkdir -p "$work"
STUB_PUSH_STDOUT="rebase-map: $OLD_A $NEW_A" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "1" "the run that cannot record its map fails"
assert_eq "$(grep '^worktree-push:' "$run_err")" \
  "worktree-push: restack-map-nostate issue=KEN-1 state=$work/tmp/workflow-state-KEN-1.json file=$restack_map_file push-exit=0" \
  "the diagnostic identifies the stranded map"

# Repair the state exactly as an operator would, then re-run.
(cd "$work" \
  && "$STATE" init KEN-1 --agent generalist --worktree "$wt" --branch ken-1 >/dev/null \
  && "$STATE" append KEN-1 fixed_items "{\"description\":\"fix\",\"commit\":\"${OLD_A:0:7}\",\"source\":\"pr-review\"}")
STUB_PUSH_STDOUT="→ pushed" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "0" "the re-run reports success"
assert_eq "$(state_json "$work" | jq -r '.fixed_items[0].commit')" "${NEW_A:0:7}" \
  "the re-run reconciles the SHA the failed run could not"
assert_eq "$(state_json "$work" | jq -r ".rebase_map[\"$OLD_A\"]")" "$NEW_A" \
  "the kept map reaches workflow state on the re-run"
assert_eq "$([[ -e "$restack_map_file" ]] && echo present || echo absent)" "absent" \
  "and the file goes once its hop is recorded"

echo
echo "=== the arguments must match the state they would rewrite ==="

# The resolved state is both what the reconcile rewrites and what names the
# round authorization whose base_sha dev-artifact-check diffs against HEAD.
# Linked worktrees share one git common dir, so a state belonging to another
# issue or another worktree must refuse BEFORE the push rebases anything.
mismatch_args_log="$TMP_ROOT/mismatch-args.log"

work="$TMP_ROOT/work-mismatch"
rm -f "$restack_map_file"
rm -rf "$work" && mkdir -p "$work/tmp"
printf '%s\n' '{"issue_id":"KEN-9","worktree":"","fixed_items":[],"pr_comment_review":{"fixes":[]}}' >"$work/tmp/workflow-state-KEN-1.json"
: >"$mismatch_args_log"
STUB_ARGS_LOG="$mismatch_args_log" STUB_PUSH_STDOUT="→ pushed" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "1" "a state recording another issue id refuses"
assert_eq "$(grep '^worktree-push:' "$run_err")" "worktree-push: issue-mismatch issue=KEN-1 recorded=KEN-9" "the issue mismatch is named"
# BSD wc right-aligns its count in a fixed-width field, so `$(wc -l <f)` reads
# "       0" on macOS and "0" on GNU; every count below is compared as a
# string, so the blanks come off at the measurement.
assert_eq "$(wc -l <"$mismatch_args_log" | tr -d ' ')" "0" "the push never ran against a mismatched issue id"

other_wt="$TMP_ROOT/other-wt"
mkdir -p "$other_wt"
work="$TMP_ROOT/work-wt-mismatch"
rm -f "$restack_map_file"
rm -rf "$work" && mkdir -p "$work"
(cd "$work" && "$STATE" init KEN-1 --agent generalist --worktree "$other_wt" --branch ken-1 >/dev/null)
: >"$mismatch_args_log"
STUB_ARGS_LOG="$mismatch_args_log" STUB_PUSH_STDOUT="→ pushed" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "1" "a state recording another worktree refuses"
assert_eq "$(grep '^worktree-push:' "$run_err")" "worktree-push: worktree-mismatch issue=KEN-1 recorded=$other_wt worktree=$wt" "the worktree mismatch is named"
assert_eq "$(wc -l <"$mismatch_args_log" | tr -d ' ')" "0" "the push never ran against a mismatched worktree"

echo
echo "=== a dying stdout cannot lose the map ==="

# The map arrives as a hop in the worktree's map file, so a full stdout (every
# print fails) costs the transcript and nothing else: the mapping still reaches
# state. /dev/full is Linux-only; on hosts without it the case is skipped visibly.
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

# The transcript is replayed for the caller and never read, so a map file this
# cannot parse still shows what the push reported — the malformed line beside
# the valid ones.
work="$TMP_ROOT/work-parsefail-replay"
reset_state "$work"
map_out="rebase-map: $OLD_A $NEW_A
rebase-map: not-a-sha $NEW_A2"
STUB_PUSH_STDOUT="$map_out" run_push "$work" --worktree "$wt" --issue KEN-1
assert_eq "$RUN_RC" "1" "a malformed line beside a valid one still fails the call"
assert_contains "$(cat "$run_out")" "rebase-map: $OLD_A $NEW_A" "the valid map line survives in the replayed transcript"
assert_contains "$(cat "$run_out")" "rebase-map: not-a-sha $NEW_A2" "the malformed map line survives in the replayed transcript"
# Once, not twice: this is the failure path, and the diagnostic must not print
# the transcript a second time over a record the caller is reading.
assert_eq "$(grep -c "^rebase-map: $OLD_A $NEW_A\$" "$run_out")" "1" \
  "and each record appears once, the diagnostic replaying nothing of its own"

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
  assert_eq "$(grep '^worktree-push:' "$run_err")" \
    "worktree-push: restack-map-write issue=KEN-1 state=$work/tmp/workflow-state-KEN-1.json file=$restack_map_file hops_applied=0 push-exit=0" \
    "the failure names the unreconciled SHAs"
  assert_eq "$(state_json "$work")" "$before" "the unwritable state is left untouched"
  assert_contains "$(cat "$run_out")" "rebase-map: $OLD_A $NEW_A" "the map's own lines survive in the replayed transcript"
fi

echo
echo "=== a bare-numeric key resolves to its exact file, never to issue-N ==="

# workflow-state resolves every key to its exact file, so `--issue 7` reaches
# workflow-state-7.json and nothing else. worktree-push must resolve it the
# same way: with no state under that key the rebase map has nowhere to land,
# which is a loud failure — never a silent bind to the issue-7 record.
work="$TMP_ROOT/work-numeric"
rm -f "$restack_map_file"
mkdir -p "$work"
git -C "$wt" config user.email test@example.com
git -C "$wt" config user.name Test
git -C "$wt" commit -q --allow-empty -m numeric-base
numeric_old="$(git -C "$wt" rev-parse HEAD)"
git -C "$wt" commit -q --allow-empty -m numeric-restack
numeric_new="$(git -C "$wt" rev-parse HEAD)"
(cd "$work" \
  && "$STATE" init issue-7 --agent generalist --worktree "$wt" --branch issue-7 >/dev/null \
  && "$STATE" append issue-7 fixed_items "{\"description\":\"fix\",\"commit\":\"${numeric_old:0:7}\",\"source\":\"pr-review\"}")
numeric_args_log="$TMP_ROOT/numeric-args.log"
: >"$numeric_args_log"
STUB_ARGS_LOG="$numeric_args_log" STUB_PUSH_STDOUT="rebase-map: $numeric_old $numeric_new" \
  run_push "$work" --worktree "$wt" --issue 7
assert_eq "$RUN_RC" "1" "a bare-numeric issue whose state does not exist fails the landed push"
assert_eq "$(wc -l <"$numeric_args_log" | tr -d ' ')" "1" \
  "the push itself ran — the failure is reconciliation, not a pre-push refusal"
assert_eq "$(grep '^worktree-push:' "$run_err")" \
  "worktree-push: restack-map-nostate issue=7 state=$work/tmp/workflow-state-7.json file=$restack_map_file push-exit=0" \
  "the failure names the exact key it resolved, not the issue-7 file"
assert_eq "$(jq -r '.fixed_items[0].commit' "$work/tmp/workflow-state-issue-7.json")" "${numeric_old:0:7}" \
  "the issue-7 record is left alone by a bare-numeric call"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
