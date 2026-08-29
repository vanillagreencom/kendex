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
chmod +x "$SANDBOX/skills/orch/scripts/container-close"
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
        if $pending; then
          if [[ "$format" == ids ]]; then
            jq -r '.[] | select(.state_type != "completed" and .state_type != "canceled") | .id' "$root/children.json"
          else
            jq '[.[] | select(.state_type != "completed" and .state_type != "canceled")]' "$root/children.json"
          fi
        else
          cat "$root/children.json"
        fi
        ;;
      *) exit 2 ;;
    esac
    ;;
  issues:validate-completion)
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
mkdir "$FAKE_LINEAR_ROOT" "$SANDBOX/tmp"

reset_state() {
  printf 'In Progress\n' > "$FAKE_LINEAR_ROOT/parent.state"
  printf 'normal\n' > "$FAKE_LINEAR_ROOT/validation.mode"
  rm -f "$FAKE_LINEAR_ROOT/complete.calls" "$FAKE_LINEAR_ROOT/summary.body" \
    "$FAKE_LINEAR_ROOT/hold.complete" "$FAKE_LINEAR_ROOT/release.complete" \
    "$FAKE_LINEAR_ROOT/fail.complete.after" "$FAKE_LINEAR_ROOT/interrupt.after.complete" \
    "$FAKE_LINEAR_ROOT/fail.update.once" "$FAKE_LINEAR_ROOT/gh.mode" \
    "$SANDBOX/tmp/container-close-recovery/PARENT-1.tsv"
  rm -rf "$FAKE_LINEAR_ROOT/complete.entries"
  mkdir "$FAKE_LINEAR_ROOT/complete.entries"
}

run_close() { (cd "$CALLER_ONE" && "$SCRIPT" "$SANDBOX" PARENT-1); }

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
(cd "$CALLER_TWO" && "$SCRIPT" "$SANDBOX" PARENT-1 > "$TMP_ROOT/race-two.out" 2> "$TMP_ROOT/race-two.err") &
pid_two=$!
rc_two=0
wait "$pid_two" || rc_two=$?
touch "$FAKE_LINEAR_ROOT/release.complete"
rc_one=0
wait "$pid_one" || rc_one=$?
assert_eq "$rc_one:$rc_two" "0:0" "both racing callers return successfully"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "1" "linked worktrees perform one shared close"
assert_eq "$(cat "$TMP_ROOT/race-one.out"):$(cat "$TMP_ROOT/race-two.out")" "closed PARENT-1:deferred" "lock loser reports the documented deferred result"

RACE_MUTANT="$SANDBOX/skills/orch/scripts/container-close-race-mutant"
assert_eq "$(grep -Fc 'if ! flock -n 9; then' "$SCRIPT")" "1" "race control finds flock acquisition"
awk 'index($0, "if ! flock -n 9; then") { print "if false; then"; next } { print }' "$SCRIPT" > "$RACE_MUTANT"
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

printf 'container-close: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
