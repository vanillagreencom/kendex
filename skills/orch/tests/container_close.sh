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

SANDBOX="$TMP_ROOT/repo"
mkdir -p "$SANDBOX/skills/orch/scripts" "$SANDBOX/skills/linear/scripts"
cp "$REPO_ROOT/skills/orch/scripts/container-close" "$SANDBOX/skills/orch/scripts/container-close"
chmod +x "$SANDBOX/skills/orch/scripts/container-close"
git init -q "$SANDBOX"

cat > "$SANDBOX/skills/linear/scripts/linear.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
root="$FAKE_LINEAR_ROOT"
resource="$1"
action="$2"
shift 2
case "$resource:$action" in
  sync:--reconcile)
    exit 0
    ;;
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
    printf '{"all_ok":true,"results":[{"id":"PARENT-1","ok":true}]}\n'
    ;;
  issues:complete)
    summary=""
    while [[ $# -gt 0 ]]; do
      case "$1" in --summary-file) summary="$2"; shift 2 ;; *) shift ;; esac
    done
    grep -Fq '## Bundle Complete' "$summary"
    printf 'close\n' >> "$root/complete.calls"
    sleep 0.3
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
SCRIPT="$SANDBOX/skills/orch/scripts/container-close"
export FAKE_LINEAR_ROOT="$TMP_ROOT/state"
mkdir "$FAKE_LINEAR_ROOT"

reset_state() {
  printf 'In Progress\n' > "$FAKE_LINEAR_ROOT/parent.state"
  rm -f "$FAKE_LINEAR_ROOT/complete.calls"
}

reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Todo","state_type":"unstarted"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
out="$(cd "$SANDBOX" && "$SCRIPT" PARENT-1)"
assert_eq "$out" "deferred CHILD-2" "pending child defers closure and is named"
[[ ! -e "$FAKE_LINEAR_ROOT/complete.calls" ]] && ok "deferred closure does not call complete" || fail "deferred closure does not call complete"

reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Canceled","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
out="$(cd "$SANDBOX" && "$SCRIPT" PARENT-1)"
assert_eq "$out" "closed PARENT-1" "completed children close the container"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "1" "container completion runs once"
assert_eq "$(jq -r '.[] | select(.id == "CHILD-2") | .state_type' "$FAKE_LINEAR_ROOT/children.json")" "canceled" "cascade repair restores a canceled child"
[[ ! -e "$SANDBOX/tmp/container-canceled-PARENT-1.lst" ]] && ok "successful repair removes its snapshot" || fail "successful repair removes its snapshot"
out="$(cd "$SANDBOX" && "$SCRIPT" PARENT-1)"
assert_eq "$out" "closed PARENT-1" "a repeated close is idempotent"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "1" "idempotent close does not post twice"

reset_state
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
(cd "$SANDBOX" && "$SCRIPT" PARENT-1 > "$TMP_ROOT/race-one.out") &
pid_one=$!
(cd "$SANDBOX" && "$SCRIPT" PARENT-1 > "$TMP_ROOT/race-two.out") &
pid_two=$!
wait "$pid_one"; rc_one=$?
wait "$pid_two"; rc_two=$?
assert_eq "$rc_one:$rc_two" "0:0" "both racing callers return successfully"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "1" "two callers perform one close"
assert_eq "$(cat "$TMP_ROOT/race-one.out"):$(cat "$TMP_ROOT/race-two.out")" "closed PARENT-1:closed PARENT-1" "both callers observe the closed container"

MUTANT="$SANDBOX/skills/orch/scripts/container-close-mutant"
match_count="$(grep -Fc 'if mkdir "$LOCK_DIR" 2>/dev/null; then' "$SCRIPT")"
assert_eq "$match_count" "1" "race control finds the lock acquisition"
sed 's/if mkdir "$LOCK_DIR" 2>\/dev\/null; then/if :; then/' "$SCRIPT" > "$MUTANT"
chmod +x "$MUTANT"
reset_state
(cd "$SANDBOX" && "$MUTANT" PARENT-1 > "$TMP_ROOT/mutant-one.out" 2> "$TMP_ROOT/mutant-one.err") &
pid_one=$!
(cd "$SANDBOX" && "$MUTANT" PARENT-1 > "$TMP_ROOT/mutant-two.out" 2> "$TMP_ROOT/mutant-two.err") &
pid_two=$!
wait "$pid_one"
wait "$pid_two"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "2" "race control fails without the per-parent lock"

MERGE_WORKFLOW="$REPO_ROOT/skills/orch/workflows/merge-pr.md"
grep -Fq 'scripts/container-close [PARENT_ID]' "$MERGE_WORKFLOW" && ok "merge-pr delegates container closure to the script" || fail "merge-pr delegates container closure to the script"
grep -Fq 'mkdir [MAIN_REPO_ROOT]/tmp/container-close' "$MERGE_WORKFLOW" && fail "merge-pr removes the prose lock procedure" || ok "merge-pr removes the prose lock procedure"

printf 'container-close: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
