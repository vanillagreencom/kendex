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
    cp "$summary" "$root/summary.body"
    printf 'close\n' >> "$root/complete.calls"
    if [[ -e "$root/hold.complete" ]]; then
      while [[ ! -e "$root/release.complete" ]]; do sleep 0.02; done
    fi
    printf 'Done\n' > "$root/parent.state"
    jq 'map(if .state_type == "canceled" then .state = "Done" | .state_type = "completed" else . end)' \
      "$root/children.json" > "$root/children.next"
    mv "$root/children.next" "$root/children.json"
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
    type=started
    [[ "$wanted" == Canceled ]] && type=canceled
    jq --arg id "$id" --arg state "$wanted" --arg type "$type" \
      'map(if .id == $id then .state = $state | .state_type = $type else . end)' \
      "$root/children.json" > "$root/children.next"
    mv "$root/children.next" "$root/children.json"
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
export FAKE_LINEAR_ROOT="$TMP_ROOT/state"
export PATH="$TMP_ROOT/bin:$PATH"
mkdir "$FAKE_LINEAR_ROOT" "$SANDBOX/tmp"

reset_state() {
  printf 'In Progress\n' > "$FAKE_LINEAR_ROOT/parent.state"
  printf 'normal\n' > "$FAKE_LINEAR_ROOT/validation.mode"
  rm -f "$FAKE_LINEAR_ROOT/complete.calls" "$FAKE_LINEAR_ROOT/summary.body" \
    "$FAKE_LINEAR_ROOT/hold.complete" "$FAKE_LINEAR_ROOT/release.complete"
}

run_close() { (cd "$CALLER_ONE" && "$SCRIPT" "$SANDBOX" PARENT-1); }

reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Todo","state_type":"unstarted"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
out="$(run_close)"
assert_eq "$out" "deferred CHILD-2" "pending child defers closure and is named"
[[ ! -e "$FAKE_LINEAR_ROOT/complete.calls" ]] && ok "deferred closure does not call complete" || fail "deferred closure does not call complete"

printf 'sentinel\n' > "$TMP_ROOT/unrelated"
ln -s "$TMP_ROOT/unrelated" "$SANDBOX/tmp/container-canceled-PARENT-1.lst"
reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Canceled","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
out="$(run_close 2>"$TMP_ROOT/close.err")"
assert_eq "$out" "closed PARENT-1" "completed children close the container"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "1" "container completion runs once"
assert_eq "$(jq -r '.[] | select(.id == "CHILD-2") | .state_type' "$FAKE_LINEAR_ROOT/children.json")" "canceled" "cascade repair restores a canceled child"
assert_contains "$TMP_ROOT/close.err" "restored CHILD-2 to Canceled" "cascade repair reports the restored child"
assert_contains "$FAKE_LINEAR_ROOT/summary.body" "CHILD-1 ✓ one — PR #101" "bundle summary preserves a child PR reference"
assert_eq "$(cat "$TMP_ROOT/unrelated")" "sentinel" "private state ignores a planted shared snapshot symlink"
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
assert_eq "$(grep -Fc 'all_ok // false' "$SCRIPT")" "1" "refusal control finds the live validation gate"
awk 'index($0, "all_ok // false") { print "if false; then"; next } { print }' "$SCRIPT" > "$REFUSAL_MUTANT"
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
for _attempt in {1..100}; do [[ -s "$FAKE_LINEAR_ROOT/complete.calls" ]] && break; sleep 0.02; done
[[ -s "$FAKE_LINEAR_ROOT/complete.calls" ]] || fail "race winner never entered completion"
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
reset_state
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
touch "$FAKE_LINEAR_ROOT/hold.complete"
(cd "$CALLER_ONE" && "$RACE_MUTANT" "$SANDBOX" PARENT-1 >/dev/null 2>&1) & pid_one=$!
(cd "$CALLER_TWO" && "$RACE_MUTANT" "$SANDBOX" PARENT-1 >/dev/null 2>&1) & pid_two=$!
for _attempt in {1..100}; do [[ -e "$FAKE_LINEAR_ROOT/complete.calls" ]] && [[ "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls")" -eq 2 ]] && break; sleep 0.02; done
touch "$FAKE_LINEAR_ROOT/release.complete"
rc_one=0; wait "$pid_one" || rc_one=$?
rc_two=0; wait "$pid_two" || rc_two=$?
assert_eq "$rc_one:$rc_two" "0:0" "mutant race statuses remain observable under errexit"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "2" "race control fails without flock"

reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
out="$(run_close)"
assert_eq "$out" "closed PARENT-1" "empty canceled state is safe under nounset"
assert_no_runs "empty-array repair leaves no private current state"

MERGE_WORKFLOW="$REPO_ROOT/skills/orch/workflows/merge-pr.md"
grep -Fq 'scripts/container-close [MAIN_REPO_ROOT] [PARENT_ID]' "$MERGE_WORKFLOW" && ok "merge-pr passes the shared main root" || fail "merge-pr passes the shared main root"
grep -Fq 'restored [CHILD_ID] to [STATE]' "$MERGE_WORKFLOW" && ok "merge-pr reports cascade restorations" || fail "merge-pr reports cascade restorations"

printf 'container-close: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
