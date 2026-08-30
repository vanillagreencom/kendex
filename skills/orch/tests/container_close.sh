#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
assert_eq() { [[ "$1" == "$2" ]] && ok "$3" || { printf '        expected: %s\n        got:      %s\n' "$2" "$1"; fail "$3"; }; }
assert_contains() { grep -Fq "$2" "$1" && ok "$3" || fail "$3"; }
assert_no_runs() {
  local count
  count="$(find "$SANDBOX/tmp" -maxdepth 1 -type d -name 'container-close-PARENT-1.*' -print | wc -l | tr -d ' ')"
  assert_eq "$count" "0" "$1"
}

SANDBOX="$TMP_ROOT/repo"
mkdir -p "$SANDBOX/skills/orch/scripts" "$SANDBOX/skills/linear/scripts" "$TMP_ROOT/bin"
cp "$REPO_ROOT/skills/orch/scripts/container-close" "$SANDBOX/skills/orch/scripts/container-close"
cp "$REPO_ROOT/skills/orch/scripts/git-context" "$SANDBOX/skills/orch/scripts/git-context"
chmod +x "$SANDBOX/skills/orch/scripts/container-close" "$SANDBOX/skills/orch/scripts/git-context"
git init -q "$SANDBOX"
git -C "$SANDBOX" config user.email test@example.com
git -C "$SANDBOX" config user.name test
printf 'tmp/\n' > "$SANDBOX/.gitignore"

cat > "$TMP_ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
search=""
while [[ $# -gt 0 ]]; do
  case "$1" in --search) search="$2"; shift 2 ;; *) shift ;; esac
done
mode="$(cat "$FAKE_LINEAR_ROOT/gh.mode" 2>/dev/null || true)"
[[ "$mode" != exit ]] || { echo 'gh unavailable' >&2; exit 7; }
[[ "$mode" != invalid ]] || { printf 'not-json\n'; exit 0; }
case "$search" in
  CHILD-1) printf '[{"number":101,"headRefName":"child-1","mergedAt":"2026-01-01","isCrossRepository":false}]\n' ;;
  CHILD-2) printf '[{"number":102,"headRefName":"bot/child-2-fix","mergedAt":"2026-01-02","isCrossRepository":false}]\n' ;;
  *) printf '[]\n' ;;
esac
SH
chmod +x "$TMP_ROOT/bin/gh"

REAL_MV="$(command -v mv)"
cat > "$TMP_ROOT/bin/mv" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
target=""
for arg in "$@"; do target="$arg"; done
if [[ -n "${RECOVERY_PUBLISH_TARGET:-}" && "$target" == "$RECOVERY_PUBLISH_TARGET" ]]; then
  count=0
  [[ ! -e "${MV_SHIM_COUNT:?}" ]] || count="$(cat "$MV_SHIM_COUNT")"
  count=$((count + 1))
  printf '%s\n' "$count" > "$MV_SHIM_COUNT"
  case "${MV_SHIM_MODE:-}" in
    interrupt-once) [[ $count -ne 1 ]] || kill -TERM "$PPID" ;;
    fail-once) [[ $count -ne 1 ]] || exit 75 ;;
  esac
fi
exec "$REAL_MV" "$@"
SH
chmod +x "$TMP_ROOT/bin/mv"

cat > "$SANDBOX/skills/linear/scripts/linear.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
root="$FAKE_LINEAR_ROOT"
resource="$1"
action="$2"
shift 2
case "$resource:$action" in
  sync:--reconcile) exit 0 ;;
  cache:issues)
    sub="$1"; shift
    case "$sub" in
      get)
        state="$(cat < "$root/parent.state")"
        type=started
        [[ "$state" == Done ]] && type=completed
        printf '{"id":"PARENT-1","title":"Container","state":"%s","state_type":"%s"}\n' "$state" "$type"
        ;;
      children)
        shift
        pending=false format=safe
        for arg in "$@"; do
          [[ "$arg" == --pending ]] && pending=true
          [[ "$arg" == --format=ids ]] && format=ids
        done
        if [[ -e "$root/late.cascade.on.children" ]]; then
          rm -f "$root/late.cascade.on.children"
          jq 'map(if .state_type == "canceled" then .state = "Done" | .state_type = "completed" else . end)' \
            "$root/children.json" > "$root/children.next.$$"
          mv "$root/children.next.$$" "$root/children.json"
        fi
        if [[ -e "$root/fresh.conflict.on.children" ]]; then
          rm -f "$root/fresh.conflict.on.children"
          jq 'map(if .id == "CHILD-2" then .state = "Canceled Again" else . end)' \
            "$root/children.json" > "$root/children.next.$$"
          mv "$root/children.next.$$" "$root/children.json"
        fi
        if $pending; then
          if [[ "$format" == ids ]]; then
            jq -r '.[] | select(.state_type != "completed" and .state_type != "canceled") | .id' "$root/children.json"
          else
            jq '[.[] | select(.state_type != "completed" and .state_type != "canceled")]' "$root/children.json"
          fi
        else
          jq 'map(.depth //= 0)' "$root/children.json"
        fi
        ;;
      *) exit 2 ;;
    esac
    ;;
  issues:validate-completion)
    if [[ -e "$root/complete.on.fresh.conflict" ]]; then
      printf 'Done\n' > "$root/parent.state"
      jq 'map(if .state_type == "canceled" then .state = "Done" | .state_type = "completed" else . end)' \
        "$root/children.json" > "$root/children.next.$$"
      mv "$root/children.next.$$" "$root/children.json"
    fi
    mode="$(cat < "$root/validation.mode")"
    case "$mode" in
      exit) echo 'validator unavailable' >&2; exit 7 ;;
      false) printf '{"all_ok":false,"results":[{"id":"PARENT-1","state_type":"started","ok":false,"cause":"blocked"}]}\n' ;;
      completed)
        jq 'map(if .state_type == "canceled" then .state = "Done" | .state_type = "completed" else . end)' \
          "$root/children.json" > "$root/children.next"
        mv "$root/children.next" "$root/children.json"
        printf '{"all_ok":true,"results":[{"id":"PARENT-1","state_type":"completed","ok":true}]}\n'
        ;;
      *) printf '{"all_ok":true,"results":[{"id":"PARENT-1","state_type":"started","ok":true}]}\n' ;;
    esac
    ;;
  issues:complete)
    summary=""
    while [[ $# -gt 0 ]]; do
      case "$1" in --summary-file) summary="$2"; shift 2 ;; *) shift ;; esac
    done
    cp "$summary" "$root/summary.body.$$"
    mv "$root/summary.body.$$" "$root/summary.body"
    printf 'close\n' >> "$root/complete.calls"
    mkdir -p "$root/complete.entries"
    : > "$root/complete.entries/$$"
    [[ ! -e "$root/fail.complete.before" ]] || exit 9
    if [[ -e "$root/hold.complete" ]]; then
      while [[ ! -e "$root/release.complete" ]]; do sleep 0.02; done
    fi
    printf 'Done\n' > "$root/parent.state.$$"
    mv "$root/parent.state.$$" "$root/parent.state"
    jq 'map(if .state_type == "canceled" then .state = "Done" | .state_type = "completed" else . end)' \
      "$root/children.json" > "$root/children.next.$$"
    mv "$root/children.next.$$" "$root/children.json"
    [[ ! -e "$root/fail.complete.after" ]] || exit 9
    [[ ! -e "$root/interrupt.after.complete" ]] || kill -TERM "$PPID"
    printf '{"success":true,"identifier":"PARENT-1"}\n'
    ;;
  issues:bulk-get)
    ids="$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))')"
    jq --argjson ids "$ids" '[.[] | select(.id as $id | $ids | index($id))]' "$root/children.json"
    ;;
  issues:update)
    id="$1"; shift
    [[ "$1" == --state ]]
    wanted="$2"
    if [[ -e "$root/fail.update.once" && "$(cat "$root/fail.update.once")" == "$id" ]]; then
      rm -f "$root/fail.update.once"
      exit 8
    fi
    printf '%s\n' "$id" >> "$root/update.calls"
    if [[ -e "$root/update.noop" ]]; then
      printf '{"success":true}\n'
      exit 0
    fi
    type=started
    [[ "$wanted" == Canceled ]] && type=canceled
    jq --arg id "$id" --arg state "$wanted" --arg type "$type" \
      'map(if .id == $id then .state = $state | .state_type = $type else . end)' \
      "$root/children.json" > "$root/children.next.$$"
    mv "$root/children.next.$$" "$root/children.json"
    printf '{"success":true}\n'
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$SANDBOX/skills/linear/scripts/linear.sh"

git -C "$SANDBOX" add .
git -C "$SANDBOX" commit -q -m fixture
CALLER_ONE="$TMP_ROOT/caller-one"
CALLER_TWO="$TMP_ROOT/caller-two"
git -C "$SANDBOX" worktree add -q -b caller-one "$CALLER_ONE"
git -C "$SANDBOX" worktree add -q -b caller-two "$CALLER_TWO"

SCRIPT="$SANDBOX/skills/orch/scripts/container-close"
RECOVERY="$SANDBOX/tmp/container-close-recovery/PARENT-1.tsv"
export FAKE_LINEAR_ROOT="$TMP_ROOT/state"
export PATH="$TMP_ROOT/bin:$PATH"
export REAL_MV
mkdir "$FAKE_LINEAR_ROOT" "$SANDBOX/tmp"

reset_state() {
  printf 'In Progress\n' > "$FAKE_LINEAR_ROOT/parent.state"
  printf 'normal\n' > "$FAKE_LINEAR_ROOT/validation.mode"
  rm -f "$FAKE_LINEAR_ROOT/complete.calls" "$FAKE_LINEAR_ROOT/summary.body" \
    "$FAKE_LINEAR_ROOT/hold.complete" "$FAKE_LINEAR_ROOT/release.complete" \
    "$FAKE_LINEAR_ROOT/fail.complete.after" "$FAKE_LINEAR_ROOT/interrupt.after.complete" \
    "$FAKE_LINEAR_ROOT/fail.complete.before" "$FAKE_LINEAR_ROOT/fail.update.once" "$FAKE_LINEAR_ROOT/gh.mode" \
    "$FAKE_LINEAR_ROOT/late.cascade.on.children" \
    "$FAKE_LINEAR_ROOT/fresh.conflict.on.children" "$FAKE_LINEAR_ROOT/update.calls" \
    "$FAKE_LINEAR_ROOT/complete.on.fresh.conflict" "$FAKE_LINEAR_ROOT/update.noop" \
    "$RECOVERY"
  rm -rf "$FAKE_LINEAR_ROOT/complete.entries"
  mkdir "$FAKE_LINEAR_ROOT/complete.entries"
}

run_close() { (cd "$CALLER_ONE" && "$SCRIPT" "$SANDBOX" PARENT-1); }
run_linked_close() { (cd "$CALLER_TWO" && "$SCRIPT" "$CALLER_TWO" PARENT-1); }

reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Todo","state_type":"unstarted"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
out="$(run_close)"
assert_eq "$out" "deferred CHILD-2" "pending child defers closure and is named"
[[ ! -e "$FAKE_LINEAR_ROOT/complete.calls" ]] && ok "deferred closure does not call complete" || fail "deferred closure does not call complete"

printf 'sentinel\n' > "$TMP_ROOT/unrelated"
reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Canceled","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
mkdir -p "$(dirname "$RECOVERY")"
ln -s "$TMP_ROOT/unrelated" "$RECOVERY"
rc=0
run_close >"$TMP_ROOT/recovery-symlink.out" 2>"$TMP_ROOT/recovery-symlink.err" || rc=$?
[[ $rc -ne 0 ]] && ok "shared recovery symlink fails closed" || fail "shared recovery symlink fails closed"
assert_eq "$(cat "$TMP_ROOT/unrelated")" "sentinel" "recovery refusal leaves a planted symlink target untouched"
rm -f -- "$RECOVERY"
out="$(run_close 2>"$TMP_ROOT/close.err")"
assert_eq "$out" "closed PARENT-1" "completed children close the container"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "1" "container completion runs once"
assert_eq "$(jq -r '.[] | select(.id == "CHILD-2") | .state_type' "$FAKE_LINEAR_ROOT/children.json")" "canceled" "cascade repair restores a canceled child"
assert_contains "$TMP_ROOT/close.err" "restored CHILD-2 to Canceled" "cascade repair reports the restored child"
assert_contains "$FAKE_LINEAR_ROOT/summary.body" "CHILD-1 ✓ one — PR #101" "bundle summary preserves a child PR reference"
assert_contains "$FAKE_LINEAR_ROOT/summary.body" "CHILD-2 canceled two — PR #102" "bundle summary marks a canceled child distinctly"
grep -Fq 'CHILD-2 ✓' "$FAKE_LINEAR_ROOT/summary.body" && fail "bundle summary does not check-mark a canceled child" || ok "bundle summary does not check-mark a canceled child"
assert_no_runs "successful closure removes private run state"
out="$(run_close)"
assert_eq "$out" "closed PARENT-1" "a repeated close is idempotent"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "1" "idempotent close does not post twice"

reset_state
printf 'completed\n' > "$FAKE_LINEAR_ROOT/validation.mode"
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Canceled","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
out="$(run_close 2>"$TMP_ROOT/live-completed.err")"
assert_eq "$out" "closed PARENT-1" "live completed validation returns the idempotent result"
[[ ! -e "$FAKE_LINEAR_ROOT/complete.calls" ]] && ok "live completed validation posts no duplicate summary" || fail "live completed validation posts no duplicate summary"
assert_eq "$(jq -r '.[] | select(.id == "CHILD-2") | .state_type' "$FAKE_LINEAR_ROOT/children.json")" "canceled" "live completed validation still repairs canceled children"
assert_contains "$TMP_ROOT/live-completed.err" "restored CHILD-2 to Canceled" "live completed repair is reported"

reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Canceled","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
touch "$FAKE_LINEAR_ROOT/interrupt.after.complete"
rc=0
run_close >"$TMP_ROOT/interrupted.out" 2>"$TMP_ROOT/interrupted.err" || rc=$?
[[ $rc -ne 0 ]] && ok "interrupted close is not reported as success" || fail "interrupted close is not reported as success"
[[ -s "$RECOVERY" ]] && ok "interrupted close keeps its durable recovery record" || fail "interrupted close keeps its durable recovery record"
assert_eq "$(jq -r '.[] | select(.id == "CHILD-2") | .state_type' "$FAKE_LINEAR_ROOT/children.json")" "completed" "interrupted close leaves the cascade visible"
rm -f "$FAKE_LINEAR_ROOT/interrupt.after.complete"
out="$(run_close 2>"$TMP_ROOT/interrupted-retry.err")"
assert_eq "$out" "closed PARENT-1" "completed fast path consumes interrupted recovery"
assert_eq "$(jq -r '.[] | select(.id == "CHILD-2") | .state_type' "$FAKE_LINEAR_ROOT/children.json")" "canceled" "interrupted recovery restores the child"
[[ ! -e "$RECOVERY" ]] && ok "verified interrupted recovery removes its record" || fail "verified interrupted recovery removes its record"

reset_state
printf '%s\n' '[{"id":"CHILD-3","title":"three","state":"Canceled","state_type":"canceled"},{"id":"CHILD-2","title":"two","state":"Canceled","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
printf 'CHILD-3\n' > "$FAKE_LINEAR_ROOT/fail.update.once"
rc=0
run_close >"$TMP_ROOT/partial.out" 2>"$TMP_ROOT/partial.err" || rc=$?
[[ $rc -ne 0 ]] && ok "partial repair is not reported as closed" || fail "partial repair is not reported as closed"
assert_eq "$(jq -r '.[] | select(.id == "CHILD-2") | .state_type' "$FAKE_LINEAR_ROOT/children.json")" "canceled" "partial repair keeps the restored child"
assert_eq "$(jq -r '.[] | select(.id == "CHILD-3") | .state_type' "$FAKE_LINEAR_ROOT/children.json")" "completed" "partial repair leaves the failed child visible"
[[ -s "$RECOVERY" ]] && ok "partial repair keeps the full recovery record" || fail "partial repair keeps the full recovery record"
out="$(run_close 2>"$TMP_ROOT/partial-retry.err")"
assert_eq "$out" "closed PARENT-1" "completed fast path retries partial repair"
assert_eq "$(jq -r '.[] | select(.id == "CHILD-3") | .state_type' "$FAKE_LINEAR_ROOT/children.json")" "canceled" "partial repair retry restores the remaining child"
[[ ! -e "$RECOVERY" ]] && ok "verified partial repair removes its record" || fail "verified partial repair removes its record"

reset_state
printf 'Done\n' > "$FAKE_LINEAR_ROOT/parent.state"
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Todo","state_type":"unstarted"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
mkdir -p "$(dirname "$RECOVERY")"
printf 'resolved\nCHILD-2\tCanceled\t0\n' > "$RECOVERY"
rc=0
run_close >/dev/null 2>"$TMP_ROOT/unexpected-repair.err" || rc=$?
[[ $rc -ne 0 ]] && ok "unexpected repair state fails closed" || fail "unexpected repair state fails closed"
assert_contains "$TMP_ROOT/unexpected-repair.err" "recovery conflict for PARENT-1: repair found child CHILD-2 in unexpected state Todo" "unexpected-state conflict names its cause"
assert_contains "$TMP_ROOT/unexpected-repair.err" "$RECOVERY" "unexpected-state conflict names the recovery record"
assert_contains "$TMP_ROOT/unexpected-repair.err" "reconcile Linear state, then remove" "unexpected-state conflict gives the remedy"
[[ -s "$RECOVERY" ]] && ok "unexpected-state conflict retains recovery" || fail "unexpected-state conflict retains recovery"

reset_state
printf 'Done\n' > "$FAKE_LINEAR_ROOT/parent.state"
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Done","state_type":"completed"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
printf 'resolved\nCHILD-2\tCanceled\t0\n' > "$RECOVERY"
touch "$FAKE_LINEAR_ROOT/update.noop"
rc=0
run_close >/dev/null 2>"$TMP_ROOT/verification-repair.err" || rc=$?
[[ $rc -ne 0 ]] && ok "failed repair verification fails closed" || fail "failed repair verification fails closed"
assert_contains "$TMP_ROOT/verification-repair.err" "recovery conflict for PARENT-1: repair could not verify child CHILD-2 at Canceled" "verification conflict names its cause"
assert_contains "$TMP_ROOT/verification-repair.err" "$RECOVERY" "verification conflict names the recovery record"
assert_contains "$TMP_ROOT/verification-repair.err" "reconcile Linear state, then remove" "verification conflict gives the remedy"
[[ -s "$RECOVERY" ]] && ok "verification conflict retains recovery" || fail "verification conflict retains recovery"

reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Canceled","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
touch "$FAKE_LINEAR_ROOT/fail.complete.before"
rc=0
run_close >/dev/null 2>"$TMP_ROOT/open-unchanged.err" || rc=$?
[[ $rc -ne 0 ]] && ok "failed completion leaves open-parent recovery for retry" || fail "failed completion leaves open-parent recovery for retry"
rm -f "$FAKE_LINEAR_ROOT/fail.complete.before"
out="$(run_close 2>"$TMP_ROOT/open-unchanged-retry.err")"
assert_eq "$out" "closed PARENT-1" "open parent carries unchanged recovery through retry"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "2" "unchanged recovery retries parent completion once"
[[ ! -e "$RECOVERY" ]] && ok "successful retry consumes unchanged recovery" || fail "successful retry consumes unchanged recovery"

reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Canceled","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
touch "$FAKE_LINEAR_ROOT/fail.complete.before"
rc=0
run_close >/dev/null 2>"$TMP_ROOT/late-cascade-first.err" || rc=$?
[[ $rc -ne 0 ]] && ok "late-cascade fixture keeps the first recovery record" || fail "late-cascade fixture keeps the first recovery record"
rm -f "$FAKE_LINEAR_ROOT/fail.complete.before"
touch "$FAKE_LINEAR_ROOT/late.cascade.on.children"
out="$(run_close 2>"$TMP_ROOT/late-cascade-retry.err")"
assert_eq "$out" "closed PARENT-1" "late cascade retry closes the parent"
assert_eq "$(jq -r '.[] | select(.id == "CHILD-2") | .state_type' "$FAKE_LINEAR_ROOT/children.json")" "canceled" "merged recovery restores a cascade after the open-parent check"
[[ ! -e "$RECOVERY" ]] && ok "late cascade repair removes the merged recovery" || fail "late cascade repair removes the merged recovery"

LATE_MUTANT="$SANDBOX/skills/orch/scripts/container-close-late-mutant"
assert_eq "$(grep -Fc '"$ACTIVE_ROWS" "$SNAPSHOT" >> "$recovery_tmp"' "$SCRIPT")" "1" "late-cascade control finds recovery merging"
awk 'index($0, "\"$ACTIVE_ROWS\" \"$SNAPSHOT\" >> \"$recovery_tmp\"") { print "    " sprintf("%c", 39) " \"$SNAPSHOT\" >> \"$recovery_tmp\" || {"; next } { print }' "$SCRIPT" > "$LATE_MUTANT"
chmod +x "$LATE_MUTANT"
reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Canceled","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
touch "$FAKE_LINEAR_ROOT/fail.complete.before"
rc=0
"$SCRIPT" "$SANDBOX" PARENT-1 >/dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] && ok "late-cascade mutant fixture keeps recovery" || fail "late-cascade mutant fixture keeps recovery"
rm -f "$FAKE_LINEAR_ROOT/fail.complete.before"
touch "$FAKE_LINEAR_ROOT/late.cascade.on.children"
rc=0
"$LATE_MUTANT" "$SANDBOX" PARENT-1 >/dev/null 2>"$TMP_ROOT/late-mutant.err" || rc=$?
[[ $rc -ne 0 ]] && ok "late-cascade control fails when fresh snapshot replaces recovery" || fail "late-cascade control fails when fresh snapshot replaces recovery"
assert_eq "$(jq -r '.[] | select(.id == "CHILD-2") | .state_type' "$FAKE_LINEAR_ROOT/children.json")" "completed" "late-cascade mutant loses the recorded restoration"

reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Canceled","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
touch "$FAKE_LINEAR_ROOT/fail.complete.before"
rc=0
run_close >/dev/null 2>"$TMP_ROOT/merge-conflict-first.err" || rc=$?
[[ $rc -ne 0 ]] && ok "merge-conflict fixture keeps durable recovery" || fail "merge-conflict fixture keeps durable recovery"
rm -f "$FAKE_LINEAR_ROOT/fail.complete.before"
touch "$FAKE_LINEAR_ROOT/fresh.conflict.on.children"
touch "$FAKE_LINEAR_ROOT/complete.on.fresh.conflict"
MV_INTERRUPT_COUNT="$TMP_ROOT/mv-interrupt.count"
export RECOVERY_PUBLISH_TARGET="$RECOVERY" MV_SHIM_MODE=interrupt-once MV_SHIM_COUNT="$MV_INTERRUPT_COUNT"
rc=0
run_close >/dev/null 2>"$TMP_ROOT/merge-conflict.err" || rc=$?
unset RECOVERY_PUBLISH_TARGET MV_SHIM_MODE MV_SHIM_COUNT
[[ $rc -ne 0 ]] && ok "conflicting durable and fresh recovery rows fail closed" || fail "conflicting durable and fresh recovery rows fail closed"
assert_eq "$(cat "$MV_INTERRUPT_COUNT")" "1" "termination arrives immediately before atomic unresolved publication"
assert_contains "$TMP_ROOT/merge-conflict.err" "recovery conflict for PARENT-1: durable and fresh rows disagree" "publish conflict names its cause"
assert_contains "$TMP_ROOT/merge-conflict.err" "$RECOVERY" "publish conflict names the active recovery path"
assert_contains "$TMP_ROOT/merge-conflict.err" "reconcile Linear state, then remove" "publish conflict gives the reconciliation remedy"
assert_eq "$(cat "$RECOVERY")" $'unresolved\nCHILD-2\tCanceled\t0\tdurable\nCHILD-2\tCanceled Again\t0\tfresh' "publish conflict atomically activates both tagged alternatives"
assert_eq "$(jq -r '.[] | select(.id == "CHILD-2") | .state_type' "$FAKE_LINEAR_ROOT/children.json")" "completed" "parent completion cascades during conflicting merge"

before_unresolved="$(cat "$RECOVERY")"
rc=0
run_close >/dev/null 2>"$TMP_ROOT/unresolved-retry.err" || rc=$?
[[ $rc -ne 0 ]] && ok "completed parent refuses unresolved automatic repair" || fail "completed parent refuses unresolved automatic repair"
assert_contains "$TMP_ROOT/unresolved-retry.err" "unresolved durable and fresh alternatives require operator reconciliation" "unresolved retry names its cause"
assert_contains "$TMP_ROOT/unresolved-retry.err" "$RECOVERY" "unresolved retry names the active envelope"
assert_contains "$TMP_ROOT/unresolved-retry.err" "reconcile Linear state, then remove" "unresolved retry gives the remedy"
assert_eq "$(cat "$RECOVERY")" "$before_unresolved" "completed retry retains both unresolved alternatives"
assert_eq "$(jq -r '.[] | select(.id == "CHILD-2") | .state_type' "$FAKE_LINEAR_ROOT/children.json")" "completed" "unresolved retry refuses stale restoration"
[[ ! -e "$FAKE_LINEAR_ROOT/update.calls" ]] && ok "unresolved retry performs no repair mutation" || fail "unresolved retry performs no repair mutation"

reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Canceled","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
touch "$FAKE_LINEAR_ROOT/fail.complete.before"
rc=0
run_close >/dev/null 2>"$TMP_ROOT/publication-failure-first.err" || rc=$?
[[ $rc -ne 0 ]] && ok "publication-failure fixture keeps resolved recovery" || fail "publication-failure fixture keeps resolved recovery"
rm -f "$FAKE_LINEAR_ROOT/fail.complete.before"
touch "$FAKE_LINEAR_ROOT/fresh.conflict.on.children" "$FAKE_LINEAR_ROOT/complete.on.fresh.conflict"
MV_FAILURE_COUNT="$TMP_ROOT/mv-failure.count"
export RECOVERY_PUBLISH_TARGET="$RECOVERY" MV_SHIM_MODE=fail-once MV_SHIM_COUNT="$MV_FAILURE_COUNT"
rc=0
run_close >/dev/null 2>"$TMP_ROOT/publication-failure.err" || rc=$?
unset RECOVERY_PUBLISH_TARGET MV_SHIM_MODE MV_SHIM_COUNT
[[ $rc -ne 0 ]] && ok "rename retry still reports the unresolved conflict" || fail "rename retry still reports the unresolved conflict"
assert_eq "$(cat "$MV_FAILURE_COUNT")" "2" "failed atomic publication retries once"
assert_eq "$(cat "$RECOVERY")" $'unresolved\nCHILD-2\tCanceled\t0\tdurable\nCHILD-2\tCanceled Again\t0\tfresh' "rename retry activates both recoverable alternatives"
before_unresolved="$(cat "$RECOVERY")"
rc=0
run_close >/dev/null 2>"$TMP_ROOT/publication-failure-retry.err" || rc=$?
[[ $rc -ne 0 ]] && ok "completed retry refuses the publication-failure envelope" || fail "completed retry refuses the publication-failure envelope"
assert_eq "$(cat "$RECOVERY")" "$before_unresolved" "publication-failure retry retains both alternatives"
assert_eq "$(jq -r '.[] | select(.id == "CHILD-2") | .state_type' "$FAKE_LINEAR_ROOT/children.json")" "completed" "publication-failure retry cannot apply stale recovery"

reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"ancestor","state":"Canceled","state_type":"canceled","depth":0},{"id":"CHILD-1","title":"done","state":"Done","state_type":"completed","depth":0}]' > "$FAKE_LINEAR_ROOT/children.json"
touch "$FAKE_LINEAR_ROOT/fail.complete.before"
rc=0
run_close >/dev/null 2>"$TMP_ROOT/depth-first.err" || rc=$?
[[ $rc -ne 0 ]] && ok "depth-order fixture records the ancestor" || fail "depth-order fixture records the ancestor"
assert_eq "$(cat "$RECOVERY")" $'resolved\nCHILD-2\tCanceled\t0' "resolved envelope persists child depth"
rm -f "$FAKE_LINEAR_ROOT/fail.complete.before"
jq '. += [{"id":"CHILD-3","title":"descendant","state":"Canceled","state_type":"canceled","depth":1}]' \
  "$FAKE_LINEAR_ROOT/children.json" > "$FAKE_LINEAR_ROOT/children.with-descendant"
mv "$FAKE_LINEAR_ROOT/children.with-descendant" "$FAKE_LINEAR_ROOT/children.json"
touch "$FAKE_LINEAR_ROOT/interrupt.after.complete"
rc=0
run_close >/dev/null 2>"$TMP_ROOT/depth-interrupt.err" || rc=$?
[[ $rc -ne 0 ]] && ok "depth-order fixture interrupts before repair" || fail "depth-order fixture interrupts before repair"
assert_eq "$(sed '1d' "$RECOVERY" | cut -f1)" $'CHILD-3\nCHILD-2' "merged recovery sorts descendants before ancestors"
assert_eq "$(sed '1d' "$RECOVERY" | cut -f3)" $'1\n0' "merged recovery stores descending depth"
rm -f "$FAKE_LINEAR_ROOT/interrupt.after.complete"
out="$(run_close 2>"$TMP_ROOT/depth-retry.err")"
assert_eq "$out" "closed PARENT-1" "depth-ordered retry closes the parent"
assert_eq "$(cat "$FAKE_LINEAR_ROOT/update.calls")" $'CHILD-3\nCHILD-2' "repair restores the descendant before its ancestor"

DEPTH_MUTANT="$SANDBOX/skills/orch/scripts/container-close-depth-mutant"
assert_eq "$(grep -Fc 'if (depths[order[j]] > depths[order[i]])' "$SCRIPT")" "1" "depth-order control finds descending sort"
awk 'index($0, "if (depths[order[j]] > depths[order[i]])") { print "          if (0) { swap=order[i]; order[i]=order[j]; order[j]=swap }"; next } { print }' "$SCRIPT" > "$DEPTH_MUTANT"
chmod +x "$DEPTH_MUTANT"
reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"ancestor","state":"Canceled","state_type":"canceled","depth":0},{"id":"CHILD-1","title":"done","state":"Done","state_type":"completed","depth":0}]' > "$FAKE_LINEAR_ROOT/children.json"
touch "$FAKE_LINEAR_ROOT/fail.complete.before"
rc=0
"$SCRIPT" "$SANDBOX" PARENT-1 >/dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] && ok "depth-order mutant fixture records the ancestor" || fail "depth-order mutant fixture records the ancestor"
rm -f "$FAKE_LINEAR_ROOT/fail.complete.before"
jq '. += [{"id":"CHILD-3","title":"descendant","state":"Canceled","state_type":"canceled","depth":1}]' \
  "$FAKE_LINEAR_ROOT/children.json" > "$FAKE_LINEAR_ROOT/children.with-descendant"
mv "$FAKE_LINEAR_ROOT/children.with-descendant" "$FAKE_LINEAR_ROOT/children.json"
touch "$FAKE_LINEAR_ROOT/interrupt.after.complete"
rc=0
"$DEPTH_MUTANT" "$SANDBOX" PARENT-1 >/dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] && ok "depth-order mutant interrupts before repair" || fail "depth-order mutant interrupts before repair"
assert_eq "$(sed '1d' "$RECOVERY" | cut -f1)" $'CHILD-2\nCHILD-3' "depth-order control fails when merged rows keep insertion order"

reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Canceled","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
touch "$FAKE_LINEAR_ROOT/fail.complete.before"
rc=0
run_close >"$TMP_ROOT/open-recovery.out" 2>"$TMP_ROOT/open-recovery.err" || rc=$?
[[ $rc -ne 0 ]] && ok "failed parent completion keeps the parent open" || fail "failed parent completion keeps the parent open"
[[ -s "$RECOVERY" ]] && ok "failed parent completion keeps its recovery record" || fail "failed parent completion keeps its recovery record"
rm -f "$FAKE_LINEAR_ROOT/fail.complete.before"
jq 'map(if .id == "CHILD-2" then .state = "Done" | .state_type = "completed" else . end)' \
  "$FAKE_LINEAR_ROOT/children.json" > "$FAKE_LINEAR_ROOT/children.independent"
mv "$FAKE_LINEAR_ROOT/children.independent" "$FAKE_LINEAR_ROOT/children.json"
rc=0
run_close >"$TMP_ROOT/open-recovery-retry.out" 2>"$TMP_ROOT/open-recovery-retry.err" || rc=$?
[[ $rc -ne 0 ]] && ok "open parent cannot authorize recovery over an independently completed child" || fail "open parent cannot authorize recovery over an independently completed child"
assert_contains "$TMP_ROOT/open-recovery-retry.err" "parent is open and child CHILD-2 moved from Canceled to Done" "authorization refusal names the changed child"
assert_contains "$TMP_ROOT/open-recovery-retry.err" "$RECOVERY" "authorization refusal names the durable recovery path"
assert_contains "$TMP_ROOT/open-recovery-retry.err" "reconcile Linear state, then remove" "authorization refusal gives the reconciliation remedy"
assert_eq "$(jq -r '.[] | select(.id == "CHILD-2") | .state_type' "$FAKE_LINEAR_ROOT/children.json")" "completed" "authorization refusal preserves the independent completion"
[[ -s "$RECOVERY" ]] && ok "authorization refusal preserves the recovery record" || fail "authorization refusal preserves the recovery record"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "1" "authorization refusal does not retry parent completion"

AUTH_MUTANT="$SANDBOX/skills/orch/scripts/container-close-auth-mutant"
assert_eq "$(grep -Fxc 'check_open_recovery' "$SCRIPT")" "1" "authorization control finds the open-parent boundary"
awk '$0 == "check_open_recovery" { print "repair_canceled"; next } { print }' "$SCRIPT" > "$AUTH_MUTANT"
chmod +x "$AUTH_MUTANT"
reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Canceled","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
touch "$FAKE_LINEAR_ROOT/fail.complete.before"
rc=0
"$SCRIPT" "$SANDBOX" PARENT-1 >/dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] && ok "authorization mutant fixture keeps its recovery record" || fail "authorization mutant fixture keeps its recovery record"
rm -f "$FAKE_LINEAR_ROOT/fail.complete.before"
jq 'map(if .id == "CHILD-2" then .state = "Done" | .state_type = "completed" else . end)' \
  "$FAKE_LINEAR_ROOT/children.json" > "$FAKE_LINEAR_ROOT/children.independent"
mv "$FAKE_LINEAR_ROOT/children.independent" "$FAKE_LINEAR_ROOT/children.json"
"$AUTH_MUTANT" "$SANDBOX" PARENT-1 >/dev/null 2>&1
assert_eq "$(jq -r '.[] | select(.id == "CHILD-2") | .state_type' "$FAKE_LINEAR_ROOT/children.json")" "canceled" "authorization control fails when open parents may restore children"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "2" "authorization mutant retries parent completion"

reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Canceled","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
touch "$FAKE_LINEAR_ROOT/fail.complete.after"
out="$(run_close 2>"$TMP_ROOT/recovered-completion.err")"
assert_eq "$out" "closed PARENT-1" "recovered completion failure still returns closed"
assert_contains "$TMP_ROOT/recovered-completion.err" "completion command failed after PARENT-1 reached Done" "closed preserves its recovered-completion diagnostic"
assert_contains "$TMP_ROOT/recovered-completion.err" "restored CHILD-2 to Canceled" "closed preserves its repair diagnostic"

for summary_mode in exit invalid; do
  reset_state
  printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
  printf '%s\n' "$summary_mode" > "$FAKE_LINEAR_ROOT/gh.mode"
  rc=0
  run_close >"$TMP_ROOT/summary-$summary_mode.out" 2>"$TMP_ROOT/summary-$summary_mode.err" || rc=$?
  [[ $rc -ne 0 ]] && ok "$summary_mode PR producer failure refuses closure" || fail "$summary_mode PR producer failure refuses closure"
  [[ ! -e "$FAKE_LINEAR_ROOT/complete.calls" ]] && ok "$summary_mode PR producer failure happens before completion" || fail "$summary_mode PR producer failure happens before completion"
  assert_eq "$(cat "$FAKE_LINEAR_ROOT/parent.state")" "In Progress" "$summary_mode PR producer failure keeps the parent open"
done

reset_state
printf '%s\n' '[{"id":"CHILD-1","title":{"bad":true},"state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
rc=0
run_close >"$TMP_ROOT/summary-rows.out" 2>"$TMP_ROOT/summary-rows.err" || rc=$?
[[ $rc -ne 0 ]] && ok "invalid child summary rows refuse closure" || fail "invalid child summary rows refuse closure"
[[ ! -e "$FAKE_LINEAR_ROOT/complete.calls" ]] && ok "invalid child summary rows fail before completion" || fail "invalid child summary rows fail before completion"

for validation_mode in exit false; do
  reset_state
  printf '%s\n' "$validation_mode" > "$FAKE_LINEAR_ROOT/validation.mode"
  printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Canceled","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
  rc=0
  run_close >"$TMP_ROOT/validation-$validation_mode.out" 2>"$TMP_ROOT/validation-$validation_mode.err" || rc=$?
  [[ $rc -ne 0 ]] && ok "$validation_mode validation refuses closure" || fail "$validation_mode validation refuses closure"
  [[ ! -e "$FAKE_LINEAR_ROOT/complete.calls" ]] && ok "$validation_mode validation does not call complete" || fail "$validation_mode validation does not call complete"
  assert_contains "$TMP_ROOT/validation-$validation_mode.err" "completion validation" "$validation_mode validation reports its cause"
  assert_no_runs "$validation_mode validation removes private run state"
done

REFUSAL_MUTANT="$SANDBOX/skills/orch/scripts/container-close-refusal-mutant"
assert_eq "$(grep -Fc 'if [[ "$ALL_OK" != "true" ]]; then' "$SCRIPT")" "1" "refusal control finds the live validation gate"
awk 'index($0, "if [[ \"$ALL_OK\" != \"true\" ]]; then") { print "if false; then"; next } { print }' "$SCRIPT" > "$REFUSAL_MUTANT"
chmod +x "$REFUSAL_MUTANT"
reset_state
printf 'false\n' > "$FAKE_LINEAR_ROOT/validation.mode"
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
"$REFUSAL_MUTANT" "$SANDBOX" PARENT-1 >/dev/null
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "1" "refusal control fails when the all_ok gate is removed"

reset_state
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
touch "$FAKE_LINEAR_ROOT/hold.complete"
(cd "$CALLER_ONE" && "$SCRIPT" "$SANDBOX" PARENT-1 > "$TMP_ROOT/race-one.out" 2> "$TMP_ROOT/race-one.err") &
pid_one=$!
for _attempt in {1..100}; do
  [[ "$(find "$FAKE_LINEAR_ROOT/complete.entries" -type f | wc -l | tr -d ' ')" -ge 1 ]] && break
  sleep 0.02
done
[[ "$(find "$FAKE_LINEAR_ROOT/complete.entries" -type f | wc -l | tr -d ' ')" -ge 1 ]] || fail "race winner never entered completion"
(run_linked_close > "$TMP_ROOT/race-two.out" 2> "$TMP_ROOT/race-two.err") &
pid_two=$!
sleep 2.2
[[ ! -s "$TMP_ROOT/race-two.out" ]] && ok "lock loser waits beyond the old two-second bound" || fail "lock loser waits beyond the old two-second bound"
touch "$FAKE_LINEAR_ROOT/release.complete"
rc_one=0
wait "$pid_one" || rc_one=$?
rc_two=0
wait "$pid_two" || rc_two=$?
assert_eq "$rc_one:$rc_two" "0:0" "both racing callers return successfully"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "1" "main and linked checkout callers share one close"
assert_eq "$(cat "$TMP_ROOT/race-one.out"):$(cat "$TMP_ROOT/race-two.out")" "closed PARENT-1:closed PARENT-1" "lock loser re-evaluates after the owner releases"

WAIT_MUTANT="$SANDBOX/skills/orch/scripts/container-close-wait-mutant"
assert_eq "$(grep -Fc 'LOCK_WAIT_SECONDS=120' "$SCRIPT")" "1" "bounded-wait control finds the production wait"
assert_eq "$(grep -Fc 'if ! flock -w "$LOCK_WAIT_SECONDS" 9; then' "$SCRIPT")" "1" "bounded-wait control finds lock acquisition"
awk 'index($0, "LOCK_WAIT_SECONDS=120") { print "LOCK_WAIT_SECONDS=0"; next } { print }' "$SCRIPT" > "$WAIT_MUTANT"
chmod +x "$WAIT_MUTANT"
reset_state
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
touch "$FAKE_LINEAR_ROOT/hold.complete"
"$SCRIPT" "$SANDBOX" PARENT-1 > "$TMP_ROOT/wait-owner.out" 2> "$TMP_ROOT/wait-owner.err" & pid_one=$!
for _attempt in {1..100}; do
  [[ "$(find "$FAKE_LINEAR_ROOT/complete.entries" -type f | wc -l | tr -d ' ')" -ge 1 ]] && break
  sleep 0.02
done
"$WAIT_MUTANT" "$CALLER_TWO" PARENT-1 > "$TMP_ROOT/wait-mutant.out" 2> "$TMP_ROOT/wait-mutant.err"
assert_eq "$(cat "$TMP_ROOT/wait-mutant.out")" "deferred" "bounded-wait control fails with a single nonblocking attempt"
touch "$FAKE_LINEAR_ROOT/release.complete"
wait "$pid_one"

COMMON_ROOT_MUTANT="$SANDBOX/skills/orch/scripts/container-close-root-mutant"
assert_eq "$(grep -Fc 'common-root "$REPOSITORY_CHECKOUT"' "$SCRIPT")" "1" "common-root control finds shared-root resolution"
awk '
  index($0, "MAIN_REPO_ROOT=\"$(\"$GIT_CONTEXT\" common-root") { print "MAIN_REPO_ROOT=\"$REPOSITORY_CHECKOUT\""; getline; next }
  { print }
' "$SCRIPT" > "$COMMON_ROOT_MUTANT"
chmod +x "$COMMON_ROOT_MUTANT"
reset_state
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
touch "$FAKE_LINEAR_ROOT/hold.complete"
"$SCRIPT" "$SANDBOX" PARENT-1 >/dev/null 2>&1 & pid_one=$!
"$COMMON_ROOT_MUTANT" "$CALLER_TWO" PARENT-1 >/dev/null 2>&1 & pid_two=$!
for _attempt in {1..100}; do
  [[ "$(find "$FAKE_LINEAR_ROOT/complete.entries" -type f | wc -l | tr -d ' ')" -eq 2 ]] && break
  sleep 0.02
done
touch "$FAKE_LINEAR_ROOT/release.complete"
rc_one=0; wait "$pid_one" || rc_one=$?
rc_two=0; wait "$pid_two" || rc_two=$?
assert_eq "$rc_one:$rc_two:$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "0:0:2" "common-root control fails when callers keep checkout-local locks"

RACE_MUTANT="$SANDBOX/skills/orch/scripts/container-close-race-mutant"
assert_eq "$(grep -Fc 'if ! flock -w "$LOCK_WAIT_SECONDS" 9; then' "$SCRIPT")" "1" "race control finds flock acquisition"
awk 'index($0, "if ! flock -w \"$LOCK_WAIT_SECONDS\" 9; then") { print "if false; then"; next } { print }' "$SCRIPT" > "$RACE_MUTANT"
chmod +x "$RACE_MUTANT"
race_failures=0
for _iteration in {1..10}; do
  reset_state
  printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
  touch "$FAKE_LINEAR_ROOT/hold.complete"
  (cd "$CALLER_ONE" && "$RACE_MUTANT" "$SANDBOX" PARENT-1 >/dev/null 2>&1) & pid_one=$!
  (cd "$CALLER_TWO" && "$RACE_MUTANT" "$SANDBOX" PARENT-1 >/dev/null 2>&1) & pid_two=$!
  for _attempt in {1..100}; do
    [[ "$(find "$FAKE_LINEAR_ROOT/complete.entries" -type f | wc -l | tr -d ' ')" -eq 2 ]] && break
    sleep 0.02
  done
  touch "$FAKE_LINEAR_ROOT/release.complete"
  rc_one=0; wait "$pid_one" || rc_one=$?
  rc_two=0; wait "$pid_two" || rc_two=$?
  calls="$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')"
  [[ "$rc_one:$rc_two:$calls" == "0:0:2" ]] || race_failures=$((race_failures + 1))
done
assert_eq "$race_failures" "0" "race control fails without flock in 10 stable runs"

SUMMARY_MUTANT="$SANDBOX/skills/orch/scripts/container-close-summary-mutant"
assert_eq "$(grep -Fc 'canceled) MARKER="canceled" ;;' "$SCRIPT")" "1" "summary control finds the canceled marker"
awk 'index($0, "canceled) MARKER=\"canceled\" ;;") { print "    canceled) MARKER=\"✓\" ;;"; next } { print }' "$SCRIPT" > "$SUMMARY_MUTANT"
chmod +x "$SUMMARY_MUTANT"
reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Canceled","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
"$SUMMARY_MUTANT" "$SANDBOX" PARENT-1 >/dev/null 2>&1
assert_contains "$FAKE_LINEAR_ROOT/summary.body" "CHILD-2 ✓ two" "summary control fails when canceled children get the completed marker"

reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
rc=0
run_close >"$TMP_ROOT/stateless.out" 2>"$TMP_ROOT/stateless.err" || rc=$?
[[ $rc -ne 0 ]] && ok "stateless canceled child refuses closure" || fail "stateless canceled child refuses closure"
assert_contains "$TMP_ROOT/stateless.err" "recovery record for CHILD-2 has no state" "stateless refusal names the child"
[[ ! -e "$FAKE_LINEAR_ROOT/complete.calls" ]] && ok "stateless refusal happens before completion" || fail "stateless refusal happens before completion"

STATELESS_MUTANT="$SANDBOX/skills/orch/scripts/container-close-stateless-mutant"
assert_eq "$(grep -Fc '[[ -n "$state" ]] || { echo "container-close: recovery record for $id has no state"' "$SCRIPT")" "1" "stateless control finds the live refusal"
awk 'index($0, "[[ -n \"$state\" ]] || { echo \"container-close: recovery record for $id has no state\"") { print "    [[ -n \"$state\" ]] || true"; next } { print }' "$SCRIPT" > "$STATELESS_MUTANT"
chmod +x "$STATELESS_MUTANT"
reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
"$STATELESS_MUTANT" "$SANDBOX" PARENT-1 >/dev/null 2>&1
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "1" "stateless control fails when the refusal is removed"

MERGE_WORKFLOW="$REPO_ROOT/skills/orch/workflows/merge-pr.md"
grep -Fq 'scripts/container-close [MAIN_REPO_ROOT] [PARENT_ID]' "$MERGE_WORKFLOW" && ok "merge-pr passes the shared main root" || fail "merge-pr passes the shared main root"
grep -Fq 'with every stderr diagnostic from the helper' "$MERGE_WORKFLOW" && ok "merge-pr preserves every closed diagnostic" || fail "merge-pr preserves every closed diagnostic"
grep -Fq '120-second lock wait expired' "$MERGE_WORKFLOW" && ok "merge-pr documents the production lock timeout" || fail "merge-pr documents the production lock timeout"

printf 'container-close: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
