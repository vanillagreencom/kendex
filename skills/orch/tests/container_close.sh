#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
# Resolved, because container-close prints its held paths under the physical
# repository root, and macOS's temporary directory sits under the /var link.
TMP_ROOT="$(mktemp -d)" || { echo "container_close: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "container_close: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "container_close: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

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

# container-close refuses to run without flock(1), so this suite cannot
# execute on a host that has none. It says so and reds: under `set -e` the
# bare `command -v` below died here with no output at all, which reads from
# the outside like a suite that ran and printed nothing. macOS ships no
# flock — it is util-linux — so a stock Mac reds here; the macOS CI leg
# supplies flock for exactly this reason.
if ! REAL_FLOCK="$(command -v flock)"; then
  printf 'FAIL: container-close requires flock(1) and this host has none, so nothing below could run. Install flock (util-linux) and re-run.\n' >&2
  exit 1
fi
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
  issues:get)
    state="$(cat "$root/parent.state")"; type=started
    [[ "$state" == Done ]] && type=completed
    printf '{"id":"PARENT-1","title":"Container","state":"%s","state_type":"%s"}\n' "$state" "$type"
    ;;
  issues:children)
    shift; pending=false; format=safe
    for arg in "$@"; do [[ "$arg" == --pending ]] && pending=true; [[ "$arg" == --format=ids ]] && format=ids; done
    if $pending; then
      if [[ "$format" == ids ]]; then jq -r '.[] | select(.state_type != "completed" and .state_type != "canceled") | .id' "$root/children.json"
      else jq '[.[] | select(.state_type != "completed" and .state_type != "canceled")]' "$root/children.json"; fi
    else jq 'map(.depth //= 0)' "$root/children.json"; fi
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
    ratelimit="$(cat "$root/ratelimit.complete.once" 2>/dev/null || true)"
    rm -f "$root/ratelimit.complete.once"
    # The reset linear_requests_reset prints: a UTC time, or `unavailable`.
    reset="$(cat "$root/ratelimit.reset" 2>/dev/null || printf '2026-10-05T16:00:00Z')"
    rate_line="{\"error\":\"Rate limited. Requests-Reset=$reset\",\"code\":\"RATELIMITED\",\"requests_reset\":\"$reset\"}"
    if [[ "$ratelimit" == comment ]]; then
      printf 'ratelimit\n' >> "$root/complete.calls"
      printf '%s\n' "$rate_line" '{"error": "Completion summary comment failed for PARENT-1. Issue state unchanged."}' >&2
      exit 1
    fi
    if [[ -n "$summary" ]]; then
      cp "$summary" "$root/summary.body"; printf 'summary\n' >> "$root/summary.calls"; touch "$root/summary.posted"; printf 'summary\n' >> "$root/complete.args"
    else printf 'state-only\n' >> "$root/complete.args"; fi
    printf 'close\n' >> "$root/complete.calls"
    mkdir -p "$root/complete.entries"; : > "$root/complete.entries/$$"
    [[ ! -e "$root/fail.complete.once" ]] || { rm -f "$root/fail.complete.once"; exit 9; }
    if [[ "$ratelimit" == update ]]; then
      printf '%s\n' "$rate_line" '{"error": "State transition to Done failed after the summary comment was posted."}' >&2
      exit 1
    fi
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
HELD_DIR="$SANDBOX/tmp/container-close-held/PARENT-1"

reset_state() {
  printf 'In Progress\n' > "$FAKE_LINEAR_ROOT/parent.state"
  printf 'normal\n' > "$FAKE_LINEAR_ROOT/validation.mode"
  rm -f "$FAKE_LINEAR_ROOT/complete.calls" "$FAKE_LINEAR_ROOT/complete.args" "$FAKE_LINEAR_ROOT/summary.calls"     "$FAKE_LINEAR_ROOT/summary.posted" "$FAKE_LINEAR_ROOT/summary.body" "$FAKE_LINEAR_ROOT/fail.complete.once"     "$FAKE_LINEAR_ROOT/hold.complete" "$FAKE_LINEAR_ROOT/release.complete" "$FAKE_LINEAR_ROOT/gh.mode" "$FAKE_LINEAR_ROOT/linear.calls" \
    "$FAKE_LINEAR_ROOT/ratelimit.complete.once" "$FAKE_LINEAR_ROOT/ratelimit.reset" "$HELD_DIR/summary.md" "$HELD_DIR/children.tsv"
  [[ ! -d "$HELD_DIR" ]] || rmdir "$HELD_DIR"
  rm -rf "$FAKE_LINEAR_ROOT/complete.entries"; mkdir "$FAKE_LINEAR_ROOT/complete.entries"
}
run_close() { (cd "$CALLER_ONE" && "$SCRIPT" "$SANDBOX" PARENT-1); }
run_linked_close() { (cd "$CALLER_TWO" && "$SCRIPT" "$CALLER_TWO" PARENT-1); }

reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Todo","state_type":"unstarted"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
out="$(run_close)"
assert_eq "$out" "deferred CHILD-2" "pending child defers closure and is named"
[[ ! -e "$FAKE_LINEAR_ROOT/complete.calls" ]] && pass "pending child prevents parent mutation" || fail "pending child prevents parent mutation"

reset_state
printf '%s\n' '[{"id":"CHILD-2","title":"two","state":"Canceled","state_type":"canceled"},{"id":"CHILD-3","title":"three","state":"Canceled","state_type":"canceled"},{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
out="$(run_close)"
assert_eq "$out" "deferred CHILD-2 CHILD-3" "canceled descendants defer closure and are named"
[[ ! -e "$FAKE_LINEAR_ROOT/complete.calls" ]] && pass "canceled descendants prevent parent mutation" || fail "canceled descendants prevent parent mutation"
assert_file_not_contains "$FAKE_LINEAR_ROOT/linear.calls" 'issues:validate-completion' "canceled descendants stop before validation"

# The suite's one must-fail control: the canceled-descendant refusal removed.
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
assert_file_contains "$FAKE_LINEAR_ROOT/summary.body" "CHILD-1 ✓ one — PR #101" "summary preserves the first child PR"
assert_file_contains "$FAKE_LINEAR_ROOT/summary.body" "CHILD-2 ✓ two — PR #102" "summary preserves the second child PR"
out="$(run_close)"
assert_eq "$out" "closed PARENT-1" "completed parent returns idempotently"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "1" "completed retry does not mutate again"

reset_state
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
touch "$FAKE_LINEAR_ROOT/fail.complete.once"
rc=0; run_close >/dev/null 2>"$TMP_ROOT/partial.err" || rc=$?
[[ $rc -ne 0 ]] && pass "summary-success state-failure remains retryable" || fail "summary-success state-failure remains retryable"
assert_eq "$(cat "$FAKE_LINEAR_ROOT/parent.state")" "In Progress" "partial completion leaves the parent open"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/summary.calls" | tr -d ' ')" "1" "partial completion posts one summary"
out="$(run_close)"
assert_eq "$out" "closed PARENT-1" "partial completion retries the state transition"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/summary.calls" | tr -d ' ')" "1" "partial completion retry posts no second summary"
assert_eq "$(cat "$FAKE_LINEAR_ROOT/complete.args")" $'summary\nstate-only' "validated summary evidence selects a state-only retry"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/complete.calls" | tr -d ' ')" "2" "partial completion retries mutation once"

# A rate-limited completion is a hold, never a failure: the parent stays open
# and unread, the reset reaches stdout, and the summary the run built is kept
# so the resumed run posts it. The resume below fails every PR lookup, so only
# a reused summary can close it.
reset_state
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
printf 'comment\n' > "$FAKE_LINEAR_ROOT/ratelimit.complete.once"
rc=0; out="$(run_close 2>"$TMP_ROOT/held.err")" || rc=$?
assert_eq "$rc:$out" "0:held PARENT-1 2026-10-05T16:00:00Z" "a rate-limited completion holds with its reset" "$TMP_ROOT/held.err"
assert_eq "$(cat "$FAKE_LINEAR_ROOT/parent.state")" "In Progress" "a held completion leaves the parent open"
assert_eq "$(tail -n 1 "$FAKE_LINEAR_ROOT/linear.calls")" "issues:complete" "a held completion reads nothing after the rate limit"
assert_file_contains "$TMP_ROOT/held.err" '"code":"RATELIMITED"' "a held completion forwards the rate-limit line"
assert_file_contains "$TMP_ROOT/held.err" "container-close: completion-held parent-id=PARENT-1 requests-reset=2026-10-05T16:00:00Z summary=$HELD_DIR/summary.md" "a held completion names its kept summary"
assert_file_contains "$HELD_DIR/summary.md" "CHILD-1 ✓ one — PR #101" "a held completion keeps the summary it built"
printf 'exit\n' > "$FAKE_LINEAR_ROOT/gh.mode"
rc=0; out="$(run_close 2>"$TMP_ROOT/resume.err")" || rc=$?
assert_eq "$rc:$out" "0:closed PARENT-1" "the resumed run closes on the kept summary without a PR lookup" "$TMP_ROOT/resume.err"
assert_file_contains "$FAKE_LINEAR_ROOT/summary.body" "CHILD-1 ✓ one — PR #101" "the resumed run posts the kept summary"
[[ ! -e "$HELD_DIR" ]] && pass "a closed parent releases its held inputs" || fail "a closed parent releases its held inputs"

# A rate limit whose answer carried no usable reset header still holds, and
# the machine-read stdout line and keyed field carry `unavailable` as given.
reset_state
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
printf 'comment\n' > "$FAKE_LINEAR_ROOT/ratelimit.complete.once"
printf 'unavailable\n' > "$FAKE_LINEAR_ROOT/ratelimit.reset"
rc=0; out="$(run_close 2>"$TMP_ROOT/held-unavailable.err")" || rc=$?
assert_eq "$rc:$out" "0:held PARENT-1 unavailable" "a rate limit with no reset time holds" "$TMP_ROOT/held-unavailable.err"
assert_file_contains "$TMP_ROOT/held-unavailable.err" "container-close: completion-held parent-id=PARENT-1 requests-reset=unavailable summary=$HELD_DIR/summary.md" "a hold with no reset time keys its reset as unavailable"
assert_eq "$(cat "$FAKE_LINEAR_ROOT/parent.state")" "In Progress" "a hold with no reset time leaves the parent open"

# Controls: the hold branch and the kept-summary reuse, each disabled in a copy.
HOLD_MUTANT="$SANDBOX/skills/orch/scripts/container-close-hold-mutant"
REUSE_MUTANT="$SANDBOX/skills/orch/scripts/container-close-reuse-mutant"
assert_eq "$(grep -Fc 'if [[ -n "$REQUESTS_RESET" ]]; then' "$SCRIPT")" "1" "hold control finds the hold branch"
assert_eq "$(grep -Fc 'if [[ -f "$HELD_SUMMARY" ]] && cmp' "$SCRIPT")" "1" "reuse control finds the kept-summary reuse"
awk 'index($0, "if [[ -n \"$REQUESTS_RESET\" ]]; then") { sub(/if /, "if false \\&\\& ") } { print }' "$SCRIPT" > "$HOLD_MUTANT"
awk 'index($0, "if [[ -f \"$HELD_SUMMARY\" ]] && cmp") { sub(/if /, "if false \\&\\& ") } { print }' "$SCRIPT" > "$REUSE_MUTANT"
chmod +x "$HOLD_MUTANT" "$REUSE_MUTANT"
cmp -s "$SCRIPT" "$HOLD_MUTANT" && fail "hold control changes the copy" || pass "hold control changes the copy"
cmp -s "$SCRIPT" "$REUSE_MUTANT" && fail "reuse control changes the copy" || pass "reuse control changes the copy"
reset_state
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
printf 'comment\n' > "$FAKE_LINEAR_ROOT/ratelimit.complete.once"
rc=0; out="$(cd "$CALLER_ONE" && "$HOLD_MUTANT" "$SANDBOX" PARENT-1 2>/dev/null)" || rc=$?
assert_eq "$rc:$out" "1:" "hold control exposes a rate limit reported as a failed close"
reset_state
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
printf 'comment\n' > "$FAKE_LINEAR_ROOT/ratelimit.complete.once"
run_close >/dev/null 2>&1
printf 'exit\n' > "$FAKE_LINEAR_ROOT/gh.mode"
rc=0; out="$(cd "$CALLER_ONE" && "$REUSE_MUTANT" "$SANDBOX" PARENT-1 2>/dev/null)" || rc=$?
assert_eq "$rc:$(cat "$FAKE_LINEAR_ROOT/parent.state")" "1:In Progress" "reuse control exposes a resume that looks the PRs up again"

# A kept summary lists the children it was built from; a changed set rebuilds.
reset_state
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
printf 'comment\n' > "$FAKE_LINEAR_ROOT/ratelimit.complete.once"
run_close >/dev/null 2>&1
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"},{"id":"CHILD-2","title":"two","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
assert_eq "$(run_close 2>/dev/null)" "closed PARENT-1" "a changed child set resumes the close"
assert_file_contains "$FAKE_LINEAR_ROOT/summary.body" "CHILD-2 ✓ two — PR #102" "a changed child set rebuilds the kept summary"

# Rate-limited after the summary posted: the hold still keeps the summary it
# built, and the resume's validation finds the posted one, so it sets Done
# without posting the kept copy and releases it.
reset_state
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
printf 'update\n' > "$FAKE_LINEAR_ROOT/ratelimit.complete.once"
assert_eq "$(run_close 2>"$TMP_ROOT/held-update.err")" "held PARENT-1 2026-10-05T16:00:00Z" "a rate-limited state transition holds"
assert_file_contains "$TMP_ROOT/held-update.err" "container-close: completion-held parent-id=PARENT-1 requests-reset=2026-10-05T16:00:00Z summary=$HELD_DIR/summary.md" "a held state transition names the summary it kept"
assert_eq "$(cd "$HELD_DIR" && ls -A)" $'children.tsv\nsummary.md' "a held state transition keeps the summary and its child rows"
assert_eq "$(run_close 2>/dev/null)" "closed PARENT-1" "a held state transition resumes"
assert_eq "$(cat "$FAKE_LINEAR_ROOT/complete.args")" $'summary\nstate-only' "a held state transition resumes without the summary"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/summary.calls" | tr -d ' ')" "1" "a held state transition posts one summary"
[[ ! -e "$HELD_DIR" ]] && pass "a resumed state transition releases its held inputs" || fail "a resumed state transition releases its held inputs"

for validation_mode in exit false string_all_ok missing_parent duplicate_parent empty_state wrong_state_type wrong_summary_type; do
  reset_state
  printf '%s\n' "$validation_mode" > "$FAKE_LINEAR_ROOT/validation.mode"
  printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
  rc=0; run_close >/dev/null 2>"$TMP_ROOT/validation-$validation_mode.err" || rc=$?
  [[ $rc -ne 0 ]] && pass "$validation_mode validation refuses closure" || fail "$validation_mode validation refuses closure"
  [[ ! -e "$FAKE_LINEAR_ROOT/complete.calls" ]] && pass "$validation_mode validation prevents parent mutation" || fail "$validation_mode validation prevents parent mutation"
done

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
  [[ ! -e "$FAKE_LINEAR_ROOT/complete.calls" ]] && pass "$gh_mode PR lookup prevents parent mutation" || fail "$gh_mode PR lookup prevents parent mutation"
  assert_eq "$(cat "$FAKE_LINEAR_ROOT/parent.state")" "In Progress" "$gh_mode PR lookup leaves the parent open for the retry"
  assert_file_contains "$TMP_ROOT/gh-$gh_mode.err" 'PR' "$gh_mode PR lookup names the failure on stderr"
done
printf '' > "$FAKE_LINEAR_ROOT/gh.mode"

# `unavailable` is reserved for a lookup that ran, was valid, and matched no
# merged PR. Nothing else may write that token, or the permanent record cannot
# be read back.
reset_state
printf '%s\n' '[{"id":"CHILD-9","title":"nine","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
assert_eq "$(run_close)" "closed PARENT-1" "a valid lookup with no match closes the container"
assert_file_contains "$FAKE_LINEAR_ROOT/summary.body" "CHILD-9 ✓ nine — PR unavailable" "a valid lookup with no match records the reference unavailable"

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
  || pass "the gh-less PATH resolves no gh"
reset_state
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
rc=0; out="$(cd "$CALLER_ONE" && PATH="$TMP_ROOT/bin-nogh" "$SCRIPT" "$SANDBOX" PARENT-1 2>"$TMP_ROOT/gh-missing.err")" || rc=$?
assert_eq "$rc" "0" "a missing gh still closes the container"
assert_eq "$out" "closed PARENT-1" "a missing gh prints the close"
assert_file_contains "$FAKE_LINEAR_ROOT/summary.body" "CHILD-1 ✓ one — PR lookup failed" "a missing gh records a token distinct from unavailable"
assert_file_contains "$TMP_ROOT/gh-missing.err" "container-close: gh-missing child-id=CHILD-1" "a missing gh names its permanent cause on stderr"

reset_state
printf '%s\n' '[{"id":"CHILD-1","title":{"bad":true},"state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
rc=0; run_close >/dev/null 2>"$TMP_ROOT/invalid-child.err" || rc=$?
[[ $rc -ne 0 && ! -e "$FAKE_LINEAR_ROOT/complete.calls" ]] && pass "invalid child rows prevent parent mutation" || fail "invalid child rows prevent parent mutation"

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
[[ -f "$SANDBOX/tmp/container-close.lock" ]] && pass "repository lock remains for later closers" || fail "repository lock remains for later closers"
[[ ! -e "$SANDBOX/tmp/container-close-PARENT-1.lock" ]] && pass "parent lock does not remain" || fail "parent lock does not remain"

exec 8>>"$SANDBOX/tmp/container-close.lock"
flock 8
"$WAIT_MUTANT" "$CALLER_TWO" PARENT-2 > "$TMP_ROOT/other-parent.out" 2>"$TMP_ROOT/other-parent.err"
assert_eq "$(cat "$TMP_ROOT/other-parent.out")" "deferred" "a different parent waits on the repository lock"
flock -u 8
exec 8>&-

reset_state
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
rc=0; FLOCK_TEST_RC=74 "$SCRIPT" "$SANDBOX" PARENT-1 >/dev/null 2>"$TMP_ROOT/flock-error.err" || rc=$?
assert_eq "$rc" "1" "operational flock error fails instead of deferring"
assert_file_contains "$TMP_ROOT/flock-error.err" "container-close: lock-failed parent-id=PARENT-1 lock-rc=74" "operational flock error reports its status"
[[ ! -e "$FAKE_LINEAR_ROOT/linear.calls" ]] && pass "operational flock error stops before Linear access" || fail "operational flock error stops before Linear access"

MERGE_WORKFLOW="$REPO_ROOT/skills/orch/workflows/merge-pr.md"
assert_file_contains "$MERGE_WORKFLOW" 'scripts/container-close [MAIN_REPO_ROOT] [PARENT_ID]' "merge-pr passes the shared main root"
assert_file_contains "$MERGE_WORKFLOW" 'with every stderr diagnostic from the helper' "merge-pr preserves closed diagnostics"
assert_file_contains "$MERGE_WORKFLOW" 'A bare `deferred` means the 120-second lock wait expired' "merge-pr documents the lock timeout"
assert_file_contains "$MERGE_WORKFLOW" 'closure for [ISSUE] has not propagated; rerun merge-pr' "merge-pr reruns when current issue remains pending"

rc=0
"$SCRIPT" >/dev/null 2>"$TMP_ROOT/arguments.err" || rc=$?
assert_eq "$rc:$(sed -n '1p' "$TMP_ROOT/arguments.err")" "2:container-close: invalid-arguments count=0" "missing operands identify the argument count"

printf 'container-close: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
