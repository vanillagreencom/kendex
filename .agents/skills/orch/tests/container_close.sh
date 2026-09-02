#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

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
while [[ $# -gt 0 ]]; do case "$1" in --search) search="$2"; shift 2 ;; *) shift ;; esac; done
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

REAL_FLOCK="$(command -v flock)"
cat > "$TMP_ROOT/bin/flock" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${FLOCK_TEST_RC:-}" ]] || exit "$FLOCK_TEST_RC"
exec "$REAL_FLOCK" "$@"
SH
chmod +x "$TMP_ROOT/bin/flock"

cat > "$SANDBOX/skills/linear/scripts/linear.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
root="$FAKE_LINEAR_ROOT"
resource="$1"; action="$2"; shift 2
printf '%s:%s\n' "$resource" "$action" >> "$root/linear.calls"
case "$resource:$action" in
  sync:--reconcile) exit 0 ;;
  cache:issues)
    sub="$1"; shift
    case "$sub" in
      get)
        state="$(cat "$root/parent.state")"; type=started
        [[ "$state" == Done ]] && type=completed
        printf '{"id":"PARENT-1","title":"Container","state":"%s","state_type":"%s"}\n' "$state" "$type"
        ;;
      children)
        shift; pending=false; format=safe
        for arg in "$@"; do [[ "$arg" == --pending ]] && pending=true; [[ "$arg" == --format=ids ]] && format=ids; done
        if $pending; then
          if [[ "$format" == ids ]]; then jq -r '.[] | select(.state_type != "completed" and .state_type != "canceled") | .id' "$root/children.json"
          else jq '[.[] | select(.state_type != "completed" and .state_type != "canceled")]' "$root/children.json"; fi
        else jq 'map(.depth //= 0)' "$root/children.json"; fi
        ;;
      *) exit 2 ;;
    esac
    ;;
  issues:validate-completion)
    mode="$(cat "$root/validation.mode")"; has_summary=false
    [[ ! -e "$root/summary.posted" ]] || has_summary=true
    case "$mode" in
      exit) echo 'validator unavailable' >&2; exit 7 ;;
      false) printf '{"all_ok":false,"results":[{"id":"PARENT-1","state_type":"started","has_summary":%s,"ok":false,"cause":"blocked"}]}\n' "$has_summary" ;;
      string_all_ok) printf '{"all_ok":"true","results":[{"id":"PARENT-1","state_type":"started","has_summary":false,"ok":true}]}\n' ;;
      missing_parent) printf '{"all_ok":true,"results":[]}\n' ;;
      duplicate_parent) printf '{"all_ok":true,"results":[{"id":"PARENT-1","state_type":"started","has_summary":false},{"id":"PARENT-1","state_type":"started","has_summary":false}]}\n' ;;
      empty_state) printf '{"all_ok":true,"results":[{"id":"PARENT-1","state_type":"","has_summary":false}]}\n' ;;
      wrong_state_type) printf '{"all_ok":true,"results":[{"id":"PARENT-1","state_type":7,"has_summary":false}]}\n' ;;
      wrong_summary_type) printf '{"all_ok":true,"results":[{"id":"PARENT-1","state_type":"started","has_summary":"false"}]}\n' ;;
      *) printf '{"all_ok":true,"results":[{"id":"PARENT-1","state_type":"started","has_summary":%s,"ok":true}]}\n' "$has_summary" ;;
    esac
    ;;
  issues:complete)
    summary=""
    while [[ $# -gt 0 ]]; do case "$1" in --summary-file) summary="$2"; shift 2 ;; *) shift ;; esac; done
    if [[ -n "$summary" ]]; then
      cp "$summary" "$root/summary.body"; printf 'summary\n' >> "$root/summary.calls"; touch "$root/summary.posted"; printf 'summary\n' >> "$root/complete.args"
    else printf 'state-only\n' >> "$root/complete.args"; fi
    printf 'close\n' >> "$root/complete.calls"
    mkdir -p "$root/complete.entries"; : > "$root/complete.entries/$$"
    [[ ! -e "$root/fail.complete.once" ]] || { rm -f "$root/fail.complete.once"; exit 9; }
    if [[ -e "$root/hold.complete" ]]; then while [[ ! -e "$root/release.complete" ]]; do sleep 0.02; done; fi
    printf 'Done\n' > "$root/parent.state"
    jq 'map(if .state_type == "canceled" then .state = "Done" | .state_type = "completed" else . end)' "$root/children.json" > "$root/children.next.$$"
    mv "$root/children.next.$$" "$root/children.json"
    printf '{"success":true,"identifier":"PARENT-1"}\n'
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$SANDBOX/skills/linear/scripts/linear.sh"

git -C "$SANDBOX" add .
git -C "$SANDBOX" commit -q -m fixture
CALLER_ONE="$TMP_ROOT/caller-one"; CALLER_TWO="$TMP_ROOT/caller-two"
git -C "$SANDBOX" worktree add -q -b caller-one "$CALLER_ONE"
git -C "$SANDBOX" worktree add -q -b caller-two "$CALLER_TWO"
SCRIPT="$SANDBOX/skills/orch/scripts/container-close"
export FAKE_LINEAR_ROOT="$TMP_ROOT/state"
export PATH="$TMP_ROOT/bin:$PATH"
export REAL_FLOCK
mkdir "$FAKE_LINEAR_ROOT" "$SANDBOX/tmp"

reset_state() {
  printf 'In Progress\n' > "$FAKE_LINEAR_ROOT/parent.state"
  printf 'normal\n' > "$FAKE_LINEAR_ROOT/validation.mode"
  rm -f "$FAKE_LINEAR_ROOT/complete.calls" "$FAKE_LINEAR_ROOT/complete.args" "$FAKE_LINEAR_ROOT/summary.calls"     "$FAKE_LINEAR_ROOT/summary.posted" "$FAKE_LINEAR_ROOT/summary.body" "$FAKE_LINEAR_ROOT/fail.complete.once"     "$FAKE_LINEAR_ROOT/hold.complete" "$FAKE_LINEAR_ROOT/release.complete" "$FAKE_LINEAR_ROOT/gh.mode" "$FAKE_LINEAR_ROOT/linear.calls"
  rm -rf "$FAKE_LINEAR_ROOT/complete.entries"; mkdir "$FAKE_LINEAR_ROOT/complete.entries"
}
run_close() { (cd "$CALLER_ONE" && "$SCRIPT" "$SANDBOX" PARENT-1); }
run_linked_close() { (cd "$CALLER_TWO" && "$SCRIPT" "$CALLER_TWO" PARENT-1); }

reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Todo","state_type":"unstarted"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
out="$(run_close)"
assert_eq "$out" "deferred CHILD-2" "pending child defers closure and is named"
[[ ! -e "$FAKE_LINEAR_ROOT/complete.calls" ]] && ok "pending child prevents parent mutation" || fail "pending child prevents parent mutation"

reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Canceled","state_type":"canceled"},{"id":"CHILD-3","title":"three","state":"Canceled","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
out="$(run_close)"
assert_eq "$out" "deferred CHILD-2 CHILD-3" "canceled descendants defer closure and are named"
[[ ! -e "$FAKE_LINEAR_ROOT/complete.calls" ]] && ok "canceled descendants prevent parent mutation" || fail "canceled descendants prevent parent mutation"
grep -Fq 'issues:validate-completion' "$FAKE_LINEAR_ROOT/linear.calls" && fail "canceled descendants stop before validation" || ok "canceled descendants stop before validation"

CANCELED_MUTANT="$SANDBOX/skills/orch/scripts/container-close-canceled-mutant"
assert_eq "$(grep -Fc 'if [[ -n "$CANCELED" ]]; then print_deferred "$CANCELED"; exit 0; fi' "$SCRIPT")" "1" "canceled control finds the refusal gate"
awk '
  index($0, "if [[ -n \"$CANCELED\" ]]; then") { print "if false; then print_deferred \"$CANCELED\"; exit 0; fi"; next }
  index($0, "[[ \"$state_type\" == \"completed\" ]]") { print "    [[ -n \"$state_type\" ]] \\"; next }
  { print }
' "$SCRIPT" > "$CANCELED_MUTANT"
chmod +x "$CANCELED_MUTANT"
reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Canceled","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
out="$("$CANCELED_MUTANT" "$SANDBOX" PARENT-1)"
assert_eq "$out:$(cat "$FAKE_LINEAR_ROOT/parent.state")" "closed PARENT-1:Done" "canceled control exposes parent mutation when refusal barriers are removed"

reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Done","state_type":"completed"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
out="$(run_close)"
assert_eq "$out" "closed PARENT-1" "completed children close the container"
assert_eq "$(cat "$FAKE_LINEAR_ROOT/complete.args")" "summary" "first completion posts the bundle summary"
assert_eq "$(cat "$FAKE_LINEAR_ROOT/summary.calls")" "summary" "first completion posts one summary"
assert_contains "$FAKE_LINEAR_ROOT/summary.body" "CHILD-1 ✓ one — PR #101" "summary preserves the first child PR"
assert_contains "$FAKE_LINEAR_ROOT/summary.body" "CHILD-2 ✓ two — PR #102" "summary preserves the second child PR"
out="$(run_close)"
assert_eq "$out" "closed PARENT-1" "completed parent returns idempotently"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "1" "completed retry does not mutate again"

reset_state
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
touch "$FAKE_LINEAR_ROOT/fail.complete.once"
rc=0; run_close >/dev/null 2>"$TMP_ROOT/partial.err" || rc=$?
[[ $rc -ne 0 ]] && ok "summary-success state-failure remains retryable" || fail "summary-success state-failure remains retryable"
assert_eq "$(cat "$FAKE_LINEAR_ROOT/parent.state")" "In Progress" "partial completion leaves the parent open"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/summary.calls" | tr -d ' ')" "1" "partial completion posts one summary"
out="$(run_close)"
assert_eq "$out" "closed PARENT-1" "partial completion retries the state transition"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/summary.calls" | tr -d ' ')" "1" "partial completion retry posts no second summary"
assert_eq "$(cat "$FAKE_LINEAR_ROOT/complete.args")" $'summary\nstate-only' "validated summary evidence selects a state-only retry"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "2" "partial completion retries mutation once"

for validation_mode in exit false string_all_ok missing_parent duplicate_parent empty_state wrong_state_type wrong_summary_type; do
  reset_state
  printf '%s\n' "$validation_mode" > "$FAKE_LINEAR_ROOT/validation.mode"
  printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
  rc=0; run_close >/dev/null 2>"$TMP_ROOT/validation-$validation_mode.err" || rc=$?
  [[ $rc -ne 0 ]] && ok "$validation_mode validation refuses closure" || fail "$validation_mode validation refuses closure"
  [[ ! -e "$FAKE_LINEAR_ROOT/complete.calls" ]] && ok "$validation_mode validation prevents parent mutation" || fail "$validation_mode validation prevents parent mutation"
done

SHAPE_MUTANT="$SANDBOX/skills/orch/scripts/container-close-shape-mutant"
assert_eq "$(grep -Fc '(.all_ok | type) == "boolean"' "$SCRIPT")" "1" "validation-shape control finds the Boolean gate"
awk '{ sub(/\(\.all_ok \| type\) == "boolean"/, "(.all_ok | type) == \"string\""); print }' "$SCRIPT" > "$SHAPE_MUTANT"
chmod +x "$SHAPE_MUTANT"
reset_state
printf 'string_all_ok\n' > "$FAKE_LINEAR_ROOT/validation.mode"
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
"$SHAPE_MUTANT" "$SANDBOX" PARENT-1 >/dev/null
[[ -e "$FAKE_LINEAR_ROOT/complete.calls" ]] && ok "validation-shape mutant accepts string true" || fail "validation-shape mutant accepts string true"

# The summary is written once — a later run short-circuits on the completed
# parent and never rebuilds it — so a lookup failure must not bake a reference
# into it. A failed or unparseable `gh pr list` exits non-zero and leaves the
# parent open, whatever the cause: the script classifies none of them, so a
# rate limit and an unauthenticated `gh` take the same path and the close is
# re-run once `gh` answers.
for gh_mode in exit invalid; do
  reset_state
  printf '%s\n' "$gh_mode" > "$FAKE_LINEAR_ROOT/gh.mode"
  printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
  rc=0; run_close >/dev/null 2>"$TMP_ROOT/gh-$gh_mode.err" || rc=$?
  assert_eq "$rc" "1" "$gh_mode PR lookup fails the close"
  [[ ! -e "$FAKE_LINEAR_ROOT/complete.calls" ]] && ok "$gh_mode PR lookup prevents parent mutation" || fail "$gh_mode PR lookup prevents parent mutation"
  assert_eq "$(cat "$FAKE_LINEAR_ROOT/parent.state")" "In Progress" "$gh_mode PR lookup leaves the parent open for the retry"
  grep -Fq 'PR' "$TMP_ROOT/gh-$gh_mode.err" && ok "$gh_mode PR lookup names the failure on stderr" || fail "$gh_mode PR lookup names the failure on stderr"
done
printf '' > "$FAKE_LINEAR_ROOT/gh.mode"

# `unavailable` is reserved for a lookup that ran, was valid, and matched no
# merged PR. Nothing else may write that token, or the permanent record cannot
# be read back.
reset_state
printf '%s\n' '[{"id":"CHILD-9","title":"nine","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
assert_eq "$(run_close)" "closed PARENT-1" "a valid lookup with no match closes the container"
assert_contains "$FAKE_LINEAR_ROOT/summary.body" "CHILD-9 ✓ nine — PR unavailable" "a valid lookup with no match records the reference unavailable"

# A missing `gh` is the one permanent cause: no retry of this close can ever
# produce the reference, so it fails open — but with its own token, so the
# record never reads as a lookup that found no PR. PATH is rebuilt without
# `gh` rather than stubbed, because `command -v` is what is under test.
mkdir -p "$TMP_ROOT/bin-nogh"
IFS=: read -ra path_dirs <<<"$PATH"
for path_dir in "${path_dirs[@]}"; do
  [[ -d "$path_dir" ]] || continue
  for exe in "$path_dir"/*; do
    exe_name="${exe##*/}"
    [[ "$exe_name" != gh ]] || continue
    [[ -f "$exe" && -x "$exe" ]] || continue
    [[ -e "$TMP_ROOT/bin-nogh/$exe_name" ]] || ln -s "$exe" "$TMP_ROOT/bin-nogh/$exe_name"
  done
done
PATH="$TMP_ROOT/bin-nogh" command -v gh >/dev/null 2>&1 \
  && fail "the gh-less PATH still resolves gh" \
  || ok "the gh-less PATH resolves no gh"
reset_state
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
rc=0; out="$(cd "$CALLER_ONE" && PATH="$TMP_ROOT/bin-nogh" "$SCRIPT" "$SANDBOX" PARENT-1 2>"$TMP_ROOT/gh-missing.err")" || rc=$?
assert_eq "$rc" "0" "a missing gh still closes the container"
assert_eq "$out" "closed PARENT-1" "a missing gh prints the close"
assert_contains "$FAKE_LINEAR_ROOT/summary.body" "CHILD-1 ✓ one — PR lookup failed" "a missing gh records a token distinct from unavailable"
assert_contains "$TMP_ROOT/gh-missing.err" "gh is not installed" "a missing gh names its permanent cause on stderr"

reset_state
printf '%s\n' '[{"id":"CHILD-1","title":{"bad":true},"state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
rc=0; run_close >/dev/null 2>"$TMP_ROOT/invalid-child.err" || rc=$?
[[ $rc -ne 0 && ! -e "$FAKE_LINEAR_ROOT/complete.calls" ]] && ok "invalid child rows prevent parent mutation" || fail "invalid child rows prevent parent mutation"

WAIT_MUTANT="$SANDBOX/skills/orch/scripts/container-close-wait-mutant"
assert_eq "$(grep -Fc 'LOCK_WAIT_SECONDS=120' "$SCRIPT")" "1" "bounded-wait control finds the production wait"
awk 'index($0, "LOCK_WAIT_SECONDS=120") { print "LOCK_WAIT_SECONDS=0"; next } { print }' "$SCRIPT" > "$WAIT_MUTANT"
chmod +x "$WAIT_MUTANT"
reset_state
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
touch "$FAKE_LINEAR_ROOT/hold.complete"
"$SCRIPT" "$CALLER_ONE" PARENT-1 > "$TMP_ROOT/race-one.out" 2>"$TMP_ROOT/race-one.err" & pid_one=$!
for _attempt in {1..100}; do
  [[ "$(find "$FAKE_LINEAR_ROOT/complete.entries" -type f | wc -l | tr -d ' ')" -ge 1 ]] && break
  sleep 0.02
done
"$WAIT_MUTANT" "$CALLER_TWO" PARENT-1 > "$TMP_ROOT/wait.out" 2>"$TMP_ROOT/wait.err"
assert_eq "$(cat "$TMP_ROOT/wait.out")" "deferred" "bounded lock conflict returns bare deferred"
(run_linked_close > "$TMP_ROOT/race-two.out" 2>"$TMP_ROOT/race-two.err") & pid_two=$!
sleep 0.2
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "1" "linked caller waits on the shared parent lock"
touch "$FAKE_LINEAR_ROOT/release.complete"
wait "$pid_one"; wait "$pid_two"
assert_eq "$(cat "$TMP_ROOT/race-one.out"):$(cat "$TMP_ROOT/race-two.out")" "closed PARENT-1:closed PARENT-1" "lock loser re-evaluates after the owner releases"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "1" "shared lock allows one parent mutation"

reset_state
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
rc=0; FLOCK_TEST_RC=74 "$SCRIPT" "$SANDBOX" PARENT-1 >/dev/null 2>"$TMP_ROOT/flock-error.err" || rc=$?
assert_eq "$rc" "1" "operational flock error fails instead of deferring"
assert_contains "$TMP_ROOT/flock-error.err" "cannot acquire lock for PARENT-1: flock exited 74" "operational flock error reports its status"
[[ ! -e "$FAKE_LINEAR_ROOT/linear.calls" ]] && ok "operational flock error stops before Linear access" || fail "operational flock error stops before Linear access"

MERGE_WORKFLOW="$REPO_ROOT/skills/orch/workflows/merge-pr.md"
grep -Fq 'scripts/container-close [MAIN_REPO_ROOT] [PARENT_ID]' "$MERGE_WORKFLOW" && ok "merge-pr passes the shared main root" || fail "merge-pr passes the shared main root"
grep -Fq 'with every stderr diagnostic from the helper' "$MERGE_WORKFLOW" && ok "merge-pr preserves closed diagnostics" || fail "merge-pr preserves closed diagnostics"
grep -Fq 'A bare `deferred` means the 120-second lock wait expired' "$MERGE_WORKFLOW" && ok "merge-pr documents the lock timeout" || fail "merge-pr documents the lock timeout"
grep -Fq 'closure for [ISSUE] has not propagated; rerun merge-pr' "$MERGE_WORKFLOW" && ok "merge-pr reruns when current issue remains pending" || fail "merge-pr reruns when current issue remains pending"

printf 'container-close: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
