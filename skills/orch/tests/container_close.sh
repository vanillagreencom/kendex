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
source "$TEST_DIR/lib/growth-state.sh"

SANDBOX="$TMP_ROOT/repo"
mkdir -p "$SANDBOX/skills/linear/scripts/lib" "$SANDBOX/skills/orch/scripts" "$SANDBOX/skills/linear/scripts" "$SANDBOX/skills/mailbox" "$TMP_ROOT/bin"
cp -R "$REPO_ROOT/skills/mailbox/scripts" "$SANDBOX/skills/mailbox/scripts"
cp "$REPO_ROOT/skills/linear/scripts/lib/issue-validation.sh" "$SANDBOX/skills/linear/scripts/lib/issue-validation.sh"
cp "$REPO_ROOT/skills/orch/scripts/container-close" "$SANDBOX/skills/orch/scripts/container-close"
cp "$REPO_ROOT/skills/orch/scripts/git-context" "$SANDBOX/skills/orch/scripts/git-context"
chmod +x "$SANDBOX/skills/orch/scripts/container-close" "$SANDBOX/skills/orch/scripts/git-context"
git init -q "$SANDBOX"
git -C "$SANDBOX" config gc.auto 0
git -C "$SANDBOX" config maintenance.auto false
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
    [[ "$state" == Canceled ]] && type=canceled
    in_pr_bundle=false; [[ ! -e "$root/parent.in-pr-bundle" ]] || in_pr_bundle=true
    printf '{"id":"PARENT-1","title":"Container","state":"%s","state_type":"%s","in_pr_bundle":%s}\n' "$state" "$type" "$in_pr_bundle"
    ;;
  issues:update)
    [[ "$#" == 3 && "$2" == --state ]] || exit 2
    printf '%s\n' "$3" > "$root/parent.state"
    printf 'update %s\n' "$3" >> "$root/complete.calls"
    printf '{"success":true}\n'
    ;;
  issues:children) jq 'map(.depth //= 0)' "$root/children.json" ;;
  issues:validate-completion)
    jq -e 'length > 0' "$root/children.json" >/dev/null || exit 1
    mode="$(cat "$root/validation.mode")"; has_summary=false
    [[ ! -e "$root/summary.posted" ]] || has_summary=true
    case "$mode" in
      exit) echo 'validator unavailable' >&2; exit 7 ;;
      # Each result comes from the shared validation rule: the parent's with
      # its description's checklist facts, each child's with the summary
      # marker read from the comments posted on it.
      children)
        source "${0%/*}/lib/issue-validation.sh"
        state="$(cat "$root/parent.state")"; type=started
        [[ "$state" != Done ]] || type=completed
        [[ "$state" != Canceled ]] || type=canceled
        rows="$(build_completion_validation_result PARENT-1 "$state" '' "$has_summary" container "$type" "$(cat "$root/parent.description" 2>/dev/null)")"
        while IFS=$'\t' read -r id state type; do
          child_summary=false
          [[ ! -e "$root/comments.$id" ]] || child_summary="$(jq -Rs 'test("Completion Summary|Bundle Complete"; "i")' "$root/comments.$id")"
          rows+=$'\n'"$(build_completion_validation_result "$id" "$state" PARENT-1 "$child_summary" container-child "$type")"
        done < <(jq -r '.[] | select(.state_type != "canceled") | [.id, .state, .state_type] | @tsv' "$root/children.json")
        jq -cs '{all_ok: all(.[]; .ok), results: .}' <<<"$rows"
        ;;
      # Each malformed result below breaks one field the close reads.
      missing_parent) printf '{"all_ok":true,"results":[{"id":"CHILD-1","ok":true}]}\n' ;;
      duplicate_parent) printf '{"all_ok":true,"results":[{"id":"PARENT-1","has_summary":false,"ok":true,"errors":[],"container_open_boxes":[]},{"id":"PARENT-1","has_summary":false,"ok":true,"errors":[],"container_open_boxes":[]}]}\n' ;;
      missing_open_boxes) printf '{"all_ok":true,"results":[{"id":"PARENT-1","has_summary":false,"ok":true,"errors":[]}]}\n' ;;
      missing_errors) printf '{"all_ok":true,"results":[{"id":"PARENT-1","has_summary":false,"ok":true,"container_open_boxes":[]}]}\n' ;;
      wrong_summary_type) printf '{"all_ok":true,"results":[{"id":"PARENT-1","has_summary":"false","ok":true,"errors":[],"container_open_boxes":[]}]}\n' ;;
      wrong_child_box) printf '{"all_ok":true,"results":[{"id":"PARENT-1","has_summary":false,"ok":true,"errors":[],"container_open_boxes":[],"child_box":"1"}]}\n' ;;
      wrong_child_ok) printf '{"all_ok":true,"results":[{"id":"PARENT-1","has_summary":false,"ok":true,"errors":[],"container_open_boxes":[]},{"id":"CHILD-1","ok":"true"}]}\n' ;;
      *) printf '{"all_ok":true,"results":[{"id":"PARENT-1","state_type":"started","has_summary":%s,"ok":true,"errors":[],"container_open_boxes":[]}]}\n' "$has_summary" ;;
    esac
    ;;
  issues:complete)
    if [[ "$1" != PARENT-1 ]]; then
      printf '{"success":true,"identifier":"%s"}\n' "$1"
      exit 0
    fi
    summary=""; met='[]'; evidence='{}'
    while [[ $# -gt 0 ]]; do case "$1" in
      --summary-file) summary="$2"; shift 2 ;;
      --done-when-met) met="[$2]"; shift 2 ;;
      --evidence-file) cp "$2" "$root/complete.evidence"
        evidence="$(jq -Rn '[inputs | capture("^(?<box>[0-9]+): (?<text>.*)$")] | map({(.box): .text}) | add // {}' "$2")"; shift 2 ;;
      *) shift ;;
    esac; done
    # Completion refuses an open box as issues complete does, through the same parser.
    if [[ -e "$root/parent.description" ]]; then
      source "${0%/*}/lib/issue-validation.sh"
      tick="$(done_when_parse "$(cat "$root/parent.description")" "$met" '' "$evidence")"
      [[ "$(jq -r '.completion_state // ""' <<<"$tick")" == Done ]] \
        || { jq -c '{error: "post-merge-checklist", unmet_branch_boxes, missing_evidence_boxes}' <<<"$tick" >&2; exit 1; }
      jq -r '.description' <<<"$tick" > "$root/parent.description"
    fi
    ratelimit="$(cat "$root/ratelimit.complete.once" 2>/dev/null || true)"
    rm -f "$root/ratelimit.complete.once"
    # The transport keeps raw requests_reset distinct from its selected reset.
    reset="$(cat "$root/ratelimit.reset" 2>/dev/null || printf '2026-10-05T16:00:00Z')"
    hold_reset="$(cat "$root/ratelimit.hold-reset" 2>/dev/null || printf '%s' "$reset")"
    rate_line="$(jq -cn --arg reset "$reset" --arg hold "$hold_reset" '{error:"Rate limited",code:"RATELIMITED",requests_reset:$reset,
      quota:{reset:$hold,status:(if $hold == "unavailable" then "missing" else "future" end),limit:"unknown",
        reset_epoch:(if $hold == "unavailable" then null else ($hold | fromdateiso8601) end)}}')"
    printf 'invoke\n' >> "$root/complete.invocations"
    already_done=false
    [[ "$(cat "$root/parent.state")" != Done ]] || already_done=true
    if [[ "$ratelimit" == comment ]]; then
      printf 'ratelimit\n' >> "$root/complete.calls"
      printf '%s\n' "$rate_line" '{"error": "Completion summary comment failed for PARENT-1. Issue state unchanged."}' >&2
      exit 1
    fi
    if [[ -n "$summary" ]]; then
      cp "$summary" "$root/summary.body"; printf 'summary\n' >> "$root/summary.calls"; touch "$root/summary.posted"; printf 'summary\n' >> "$root/complete.args"
    else printf 'state-only\n' >> "$root/complete.args"; fi
    $already_done || printf 'close\n' >> "$root/complete.calls"
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
    # Native issues complete can fail required effects after the Done update.
    printf 'effect\n' >> "$root/supersession.calls"
    post_done="$(cat "$root/post-done.mode" 2>/dev/null || true)"
    if [[ "$post_done" == quota ]]; then printf '%s\n' "$rate_line" >&2; fi
    if [[ -n "$post_done" ]]; then
      printf '{"success":true,"identifier":"PARENT-1"}\n'
      printf '{"error":"supersession-incomplete","issue":"PARENT-1","already_done":true,"state":"Done","retry":{"resource":"issues","action":"complete","issue":"PARENT-1","options":[]}}\n' >&2
      exit 1
    fi
    printf '{"success":true,"identifier":"PARENT-1"}\n'
    ;;
  comments:create)
    [[ "$#" == 3 && "$2" == --body-file ]] || exit 2
    cat "$3" >> "$root/comments.$1"
    printf '{"success":true}\n'
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
    "$FAKE_LINEAR_ROOT/complete.invocations" "$FAKE_LINEAR_ROOT/supersession.calls" "$FAKE_LINEAR_ROOT/post-done.mode" \
    "$FAKE_LINEAR_ROOT/ratelimit.complete.once" "$FAKE_LINEAR_ROOT/ratelimit.reset" "$FAKE_LINEAR_ROOT/ratelimit.hold-reset" "$HELD_DIR/summary.md" "$HELD_DIR/children.tsv" \
    "$FAKE_LINEAR_ROOT/parent.description" "$FAKE_LINEAR_ROOT/complete.evidence" "$FAKE_LINEAR_ROOT/parent.in-pr-bundle"
  [[ ! -d "$HELD_DIR" ]] || rmdir "$HELD_DIR"
  rm -f -- "${FAKE_LINEAR_ROOT:?}"/comments.*
  rm -rf "$FAKE_LINEAR_ROOT/complete.entries"; mkdir "$FAKE_LINEAR_ROOT/complete.entries"
}
run_close() { (cd "$CALLER_ONE" && "$SCRIPT" "$SANDBOX" PARENT-1); }
run_linked_close() { (cd "$CALLER_TWO" && "$SCRIPT" "$CALLER_TWO" PARENT-1); }

# One table drives the close decision through every row. A row's result is
# the exit status, stdout, the parent's state after, the keyed stderr lines
# and the Linear calls made. Each Done child carries its Completion Summary
# unless the row names it bare. refused_rows reads the rows a refusal prints
# on stderr as ID=TYPE, TYPE being the type of the row's remedy.
close_row() { # STATE IN_PR DESCRIPTION CHILDREN BARE [SCRIPT]
  reset_state
  printf '%s\n' "$1" >"$FAKE_LINEAR_ROOT/parent.state"
  [[ "$2" != yes ]] || touch "$FAKE_LINEAR_ROOT/parent.in-pr-bundle"
  printf 'children\n' >"$FAKE_LINEAR_ROOT/validation.mode"
  [[ -z "$3" ]] || printf '%b\n' "$3" >"$FAKE_LINEAR_ROOT/parent.description"
  printf '%s\n' "$4" >"$FAKE_LINEAR_ROOT/children.json"
  local rc=0 out id
  for id in $(jq -r '.[] | select(.state_type == "completed") | .id' <<<"$4"); do
    [[ "$id" == "$5" ]] || printf '## Completion Summary\n' >"$FAKE_LINEAR_ROOT/comments.$id"
  done
  out="$(cd "$CALLER_ONE" && "${6:-$SCRIPT}" "$SANDBOX" PARENT-1 2>"$TMP_ROOT/close-row.err")" || rc=$?
  printf '%s:%s:%s:%s:%s' "$rc" "$out" "$(cat "$FAKE_LINEAR_ROOT/parent.state")" \
    "$(sed -n 's/^container-close: \([a-z-]*\) parent-id=PARENT-1/\1/p' "$TMP_ROOT/close-row.err" | paste -sd, -)" \
    "$(sed 's/^issues://' "$FAKE_LINEAR_ROOT/linear.calls" | paste -sd, -)"
}
refused_rows() { jq -Rr 'fromjson? | objects | "\(.id)=\(.remedy | type)"' "$TMP_ROOT/close-row.err" | paste -sd, -; }
CHILD_BOX_DONE='## Done when\n- [ ] Every child Done or cancelled'
OUTCOME_BESIDE="$CHILD_BOX_DONE\n- [ ] Shared outcome at source"
MALFORMED_POST_MERGE="$CHILD_BOX_DONE\n- [x] Post-merge: Read health; Where: service; Why after merge: deployment; Deadline: bogus\n  Evidence: holder read passed"
NO_CHILDREN='[]'
ALL_DONE='[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"},{"id":"CHILD-2","title":"two","state":"Done","state_type":"completed"}]'
DONE_AND_CANCELED='[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"},{"id":"CHILD-2","title":"two","state":"Canceled","state_type":"canceled"}]'
ONE_OPEN='[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"},{"id":"CHILD-2","title":"two","state":"Todo","state_type":"unstarted"},{"id":"CHILD-3","title":"three","state":"Canceled","state_type":"canceled"}]'
ALL_CANCELED='[{"id":"CHILD-1","title":"one","state":"Canceled","state_type":"canceled"},{"id":"CHILD-2","title":"two","state":"Canceled","state_type":"canceled"}]'
# Linear lets a team add completed states besides Done.
COMPLETED_NOT_DONE='[{"id":"CHILD-1","title":"one","state":"Released","state_type":"completed"},{"id":"CHILD-2","title":"two","state":"Done","state_type":"completed"}]'
READ=get,children,validate-completion
while IFS='|' read -r row state in_pr description children bare want refused evidence summary; do
  assert_eq "$(close_row "$state" "$in_pr" "$description" "${!children}" "$bare")" "$want" "$row decides the container's close" "$TMP_ROOT/close-row.err"
  assert_eq "$(refused_rows)" "$refused" "$row prints each refused row with its remedy" "$TMP_ROOT/close-row.err"
  if [[ -n "$evidence" ]]; then
    assert_file_contains "$FAKE_LINEAR_ROOT/parent.description" '- [x] Every child Done or cancelled' "$row ticks the child box"
    assert_file_contains "$FAKE_LINEAR_ROOT/parent.description" "  Evidence: container-close read every child Done or Canceled: $evidence" "$row records each child's state as Evidence"
  else
    [[ ! -e "$FAKE_LINEAR_ROOT/complete.evidence" ]] && pass "$row writes no Evidence" || fail "$row writes no Evidence"
  fi
  assert_eq "$(sed -n 's/^- //p' "$FAKE_LINEAR_ROOT/summary.body" 2>/dev/null | paste -sd ';' -)" "$summary" "$row posts its bundle summary"
done <<ROWS
in-PR bundle root, every child canceled|In Review|yes|$CHILD_BOX_DONE|ALL_CANCELED||1::In Review:in-pr-bundle:get|||
no children|In Progress|no|$CHILD_BOX_DONE|NO_CHILDREN||1::In Progress:no-children:get,children|||
child box, a child open|In Progress|no|$CHILD_BOX_DONE|ONE_OPEN||0:deferred CHILD-2:In Progress::get,children|||
outcome box beside the child box|In Progress|no|$OUTCOME_BESIDE|ALL_DONE||1::In Progress:completion-refused cause=open-box:$READ|PARENT-1=string||
outcome box beside the child box, every child canceled|In Progress|no|$OUTCOME_BESIDE|ALL_CANCELED||1::In Progress:completion-refused cause=open-box:$READ|PARENT-1=string||
outcome box beside the child box on a Done parent, every child canceled|Done|no|$OUTCOME_BESIDE|ALL_CANCELED||1::Done:completion-refused cause=open-box:$READ|PARENT-1=string||
a ticked post-merge box with malformed fields|In Progress|no|$MALFORMED_POST_MERGE|ALL_DONE||1::In Progress:completion-refused cause=checklist-invalid:$READ|PARENT-1=string||
a Done child with no summary|In Progress|no|$CHILD_BOX_DONE|ALL_DONE|CHILD-2|1::In Progress:completion-refused cause=child-not-ok:$READ|CHILD-2=string||
a completed child in a state other than Done|In Progress|no|$CHILD_BOX_DONE|COMPLETED_NOT_DONE||1::In Progress:completion-refused cause=child-not-ok:$READ|CHILD-1=string||
child box, every child canceled|In Progress|no|$CHILD_BOX_DONE|ALL_CANCELED||0:closed PARENT-1:Canceled:canceled:$READ,update|||
parent already Canceled, every child canceled|Canceled|no|$CHILD_BOX_DONE|ALL_CANCELED||0:closed PARENT-1:Canceled:canceled:$READ|||
parent already Done, every child Canceled|Done|no|$CHILD_BOX_DONE|ALL_CANCELED||0:closed PARENT-1:Done::$READ|||
child box, every child Done|In Progress|no|$CHILD_BOX_DONE|ALL_DONE||0:closed PARENT-1:Done::$READ,complete||CHILD-1 Done, CHILD-2 Done|CHILD-1 ✓ one — PR #101;CHILD-2 ✓ two — PR #102
child box, Done and Canceled|In Progress|no|$CHILD_BOX_DONE|DONE_AND_CANCELED||0:closed PARENT-1:Done::$READ,complete||CHILD-1 Done, CHILD-2 Canceled|CHILD-1 ✓ one — PR #101
child box on a parent another route set Done|Done|no|$CHILD_BOX_DONE|ALL_DONE||0:closed PARENT-1:Done::$READ,complete||CHILD-1 Done, CHILD-2 Done|
no checklist, every child Done|In Progress|no||ALL_DONE||0:closed PARENT-1:Done::$READ,complete|||CHILD-1 ✓ one — PR #101;CHILD-2 ✓ two — PR #102
a Canceled parent with a Done child|Canceled|no|$CHILD_BOX_DONE|DONE_AND_CANCELED||1::Canceled:completion-refused cause=parent-canceled:$READ|PARENT-1=string||
ROWS

# Controls, each in a disposable copy: a pending filter that keeps canceled
# children defers forever; an all-canceled close that skips the open-box read
# cancels an open outcome unread; a close that skips the tick leaves the
# child box open and refuses every-Done children; a refusal that prints no
# refused row, or a row without its remedy, leaves the caller nothing to
# follow.
CANCELED_MUTANT="$SANDBOX/skills/orch/scripts/container-close-canceled-mutant"
cp "$SCRIPT" "$CANCELED_MUTANT"
mutate_file "$CANCELED_MUTANT" 'def pending: .state_type != "completed" and .state_type != "canceled";' 'def pending: .state_type != "completed";'
assert_eq "$(close_row 'In Progress' no "$CHILD_BOX_DONE" "$DONE_AND_CANCELED" '' "$CANCELED_MUTANT")" '0:deferred CHILD-2:In Progress::get,children' "canceled control exposes the endless deferral"
CANCEL_MUTANT="$SANDBOX/skills/orch/scripts/container-close-cancel-mutant"
cp "$SCRIPT" "$CANCEL_MUTANT"
mutate_file "$CANCEL_MUTANT" 'def open_box: .container_open_boxes != [];' 'def open_box: false;'
control_rc=0
( FAIL=0; assert_eq "$(close_row 'In Progress' no "$OUTCOME_BESIDE" "$ALL_CANCELED" '' "$CANCEL_MUTANT")" "1::In Progress:completion-refused cause=open-box:$READ" 'open outcome refuses'; [[ "$FAIL" == 0 ]] ) >"$TMP_ROOT/cancel-control.log" || control_rc=$?
assert_eq "$control_rc" 1 "cancel control: an open outcome box on an all-canceled parent is canceled unread"
TICK_MUTANT="$SANDBOX/skills/orch/scripts/container-close-tick-mutant"
cp "$SCRIPT" "$TICK_MUTANT"
mutate_file "$TICK_MUTANT" 'if [[ -n "$CHILD_BOX" ]]; then' 'if false; then'
control_rc=0
( FAIL=0; assert_eq "$(close_row 'In Progress' no "$CHILD_BOX_DONE" "$ALL_DONE" '' "$TICK_MUTANT")" "0:closed PARENT-1:Done::$READ,complete" 'child box closes'; [[ "$FAIL" == 0 ]] ) >"$TMP_ROOT/tick-control.log" || control_rc=$?
assert_eq "$control_rc" 1 "tick control: an unticked child box keeps every-Done children from closing the parent"
for control in unprinted unremedied; do
  mutant="$SANDBOX/skills/orch/scripts/container-close-$control-mutant"
  cp "$SCRIPT" "$mutant"
  if [[ "$control" == unprinted ]]; then
    mutate_file "$mutant" '| select(if $cause == "child-not-ok" then refused_child($id) else .id == $id end)' '| select(false)'
  else
    mutate_file "$mutant" '| . + {remedy: remedy($cause; $id)}' '| .'
  fi
  close_row 'In Progress' no "$OUTCOME_BESIDE" "$ALL_DONE" '' "$mutant" >/dev/null
  control_rc=0
  ( FAIL=0; assert_eq "$(refused_rows)" 'PARENT-1=string' 'refused row with its remedy'; [[ "$FAIL" == 0 ]] ) >"$TMP_ROOT/$control-control.log" || control_rc=$?
  assert_eq "$control_rc" 1 "$control control: the refused rows column reddens"
done

# The owner must distinguish completed state from successful required effects.
while IFS='|' read -r initial effect first_result; do
  reset_state
  printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
  printf '%s\n' "$initial" > "$FAKE_LINEAR_ROOT/parent.state"
  if [[ "$initial" == Done ]]; then
    touch "$FAKE_LINEAR_ROOT/summary.posted"
    printf 'summary\n' > "$FAKE_LINEAR_ROOT/summary.calls"
  fi
  printf '%s\n' "$effect" > "$FAKE_LINEAR_ROOT/post-done.mode"
  rc=0; out="$(run_close 2>"$TMP_ROOT/post-done.err")" || rc=$?
  assert_eq "$rc:$out" "$first_result" "$initial $effect never reports a completed required effect as closed" "$TMP_ROOT/post-done.err"
  assert_eq "$(cat "$FAKE_LINEAR_ROOT/parent.state")" Done "$initial $effect preserves the completed transition"
  if [[ "$effect" == error ]]; then
    rc=0; out="$(run_close 2>"$TMP_ROOT/post-done-retry.err")" || rc=$?
    assert_eq "$rc:$out" '1:' "$initial error retry preserves the required failure" "$TMP_ROOT/post-done-retry.err"
  fi
  rm "$FAKE_LINEAR_ROOT/post-done.mode"
  out="$(run_close)"
  assert_eq "$out" 'closed PARENT-1' "$initial $effect resumes and closes after effects succeed"
  assert_eq "$(cat "$FAKE_LINEAR_ROOT/summary.calls")" summary "$initial $effect retries without duplicating its summary"
  [[ ! -e "$HELD_DIR" ]] && pass "$initial $effect releases held inputs only after success" || fail "$initial $effect releases held inputs only after success"
done <<'ROWS'
In Progress|error|1:
Done|error|1:
In Progress|quota|0:held PARENT-1 2026-10-05T16:00:00Z
Done|quota|0:held PARENT-1 2026-10-05T16:00:00Z
ROWS

for defect in swallow short-circuit; do
  mutant="$SANDBOX/skills/orch/scripts/container-close-$defect"
  cp "$SCRIPT" "$mutant"
  if [[ "$defect" == swallow ]]; then
    mutate_file "$mutant" '  container_close_message completion-failed "$@" >&2' '  print_closed "$@"; exit 0'
    initial='In Progress'
  else
    mutate_file "$mutant" 'else "close-done:resume" end' 'else "noop:completed" end'
    initial=Done
  fi
  reset_state
  printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
  printf '%s\n' "$initial" > "$FAKE_LINEAR_ROOT/parent.state"
  printf 'error\n' > "$FAKE_LINEAR_ROOT/post-done.mode"
  rc=0; out="$("$mutant" "$SANDBOX" PARENT-1 2>"$TMP_ROOT/control.err")" || rc=$?
  control_rc=0
  ( FAIL=0; assert_eq "$rc:$out" '1:' 'required completion failure'; [[ "$FAIL" == 0 ]] ) >"$TMP_ROOT/control.log" || control_rc=$?
  assert_eq "$control_rc" 1 "$defect control fails the required-completion assertion"
done

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
printf '2026-10-05T15:00:00Z\n' > "$FAKE_LINEAR_ROOT/ratelimit.reset"
printf '2026-10-05T16:00:00Z\n' > "$FAKE_LINEAR_ROOT/ratelimit.hold-reset"
rc=0; out="$(run_close 2>"$TMP_ROOT/held.err")" || rc=$?
assert_eq "$rc:$out" "0:held PARENT-1 2026-10-05T16:00:00Z" "a rate-limited completion holds with its reset" "$TMP_ROOT/held.err"
assert_eq "$(cat "$FAKE_LINEAR_ROOT/parent.state")" "In Progress" "a held completion leaves the parent open"
assert_eq "$(tail -n 1 "$FAKE_LINEAR_ROOT/linear.calls")" "issues:complete" "a held completion reads nothing after the rate limit"
assert_file_contains "$TMP_ROOT/held.err" '"code":"RATELIMITED"' "a held completion forwards the rate-limit line"
assert_file_contains "$TMP_ROOT/held.err" "container-close: completion-held parent-id=PARENT-1 requests-reset=2026-10-05T15:00:00Z hold-reset=2026-10-05T16:00:00Z summary=$HELD_DIR/summary.md" "a held completion names its kept summary"
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
assert_file_contains "$TMP_ROOT/held-unavailable.err" "container-close: completion-held parent-id=PARENT-1 requests-reset=unavailable hold-reset=unavailable summary=$HELD_DIR/summary.md" "a hold with no reset time keys its reset as unavailable"
assert_eq "$(cat "$FAKE_LINEAR_ROOT/parent.state")" "In Progress" "a hold with no reset time leaves the parent open"

# Controls: the hold branch and the kept-summary reuse, each disabled in a copy.
HOLD_MUTANT="$SANDBOX/skills/orch/scripts/container-close-hold-mutant"
REUSE_MUTANT="$SANDBOX/skills/orch/scripts/container-close-reuse-mutant"
assert_eq "$(grep -Fc 'if [[ -n "$HOLD_RESET" ]]; then' "$SCRIPT")" "1" "hold control finds the hold branch"
assert_eq "$(grep -Fc 'if [[ -f "$HELD_SUMMARY" ]] && cmp' "$SCRIPT")" "1" "reuse control finds the kept-summary reuse"
awk 'index($0, "if [[ -n \"$HOLD_RESET\" ]]; then") { sub(/if /, "if false \\&\\& ") } { print }' "$SCRIPT" > "$HOLD_MUTANT"
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

RESET_MUTANT="$SANDBOX/skills/orch/scripts/container-close-reset-mutant"
cp "$SCRIPT" "$RESET_MUTANT"
mutate_file "$RESET_MUTANT" '(.quota.reset // "unavailable")' '(.requests_reset // "unavailable")'
reset_state
printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
printf 'comment\n' > "$FAKE_LINEAR_ROOT/ratelimit.complete.once"
printf '2026-10-05T15:00:00Z\n' > "$FAKE_LINEAR_ROOT/ratelimit.reset"
printf '2026-10-05T16:00:00Z\n' > "$FAKE_LINEAR_ROOT/ratelimit.hold-reset"
rc=0; out="$(cd "$CALLER_ONE" && "$RESET_MUTANT" "$SANDBOX" PARENT-1 2>/dev/null)" || rc=$?
control_rc=0
( FAIL=0; assert_eq "$rc:$out" '0:held PARENT-1 2026-10-05T16:00:00Z' 'selected hold reset'; [[ "$FAIL" == 0 ]] ) >"$TMP_ROOT/reset-control.log" || control_rc=$?
assert_eq "$control_rc" 1 'control rejects the earlier raw request reset'

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
assert_file_contains "$TMP_ROOT/held-update.err" "container-close: completion-held parent-id=PARENT-1 requests-reset=2026-10-05T16:00:00Z hold-reset=2026-10-05T16:00:00Z summary=$HELD_DIR/summary.md" "a held state transition names the summary it kept"
assert_eq "$(cd "$HELD_DIR" && ls -A)" $'children.tsv\nsummary.md' "a held state transition keeps the summary and its child rows"
assert_eq "$(run_close 2>/dev/null)" "closed PARENT-1" "a held state transition resumes"
assert_eq "$(cat "$FAKE_LINEAR_ROOT/complete.args")" $'summary\nstate-only' "a held state transition resumes without the summary"
assert_eq "$(wc -l < "$FAKE_LINEAR_ROOT/summary.calls" | tr -d ' ')" "1" "a held state transition posts one summary"
[[ ! -e "$HELD_DIR" ]] && pass "a resumed state transition releases its held inputs" || fail "a resumed state transition releases its held inputs"

# A micro child's Completion Summary is the comment ../workflows/micro.md
# § 2 step 6 posts; its later completion is the plain command in
# ../workflows/merge-pr.md § 5 step 2 every entry runs. The plain row posts
# nothing, as micro did before that step: its child holds the container open.
post_command="$(awk '/^   \.agents\/skills\/linear\/scripts\/linear\.sh comments create / { sub(/^   /, ""); print }' "$REPO_ROOT/skills/orch/workflows/micro.md")"
complete_command="$(awk '/^   \[MAIN_REPO_ROOT\]\/\.agents\/skills\/linear\/scripts\/linear.sh issues complete / { sub(/^   /, ""); print }' "$REPO_ROOT/skills/orch/workflows/merge-pr.md")"
assert_eq "$(grep -c . <<<"$complete_command" || true)" "1" "merge-pr gives one completion command"
micro_child_close() { # POST_COMMAND
  local command wt="$TMP_ROOT/micro-child"
  mkdir -p "$wt/tmp"
  printf '## Completion Summary\n\nfeat(CHILD-1): one\n' > "$wt/tmp/completion-summary-CHILD-1.md"
  printf '1: fixture evidence\n' > "$wt/tmp/evidence"
  for command in "$1" "$complete_command"; do
    [[ -n "$command" ]] || continue
    command="${command//\[MAIN_REPO_ROOT\]\/.agents\//$SANDBOX/}"
    command="${command/#.agents\//$SANDBOX/}"
    command="${command//\[WT_PATH\]/$wt}"
    command="${command//\[ISSUE_ID\]/CHILD-1}"
    command="${command//\[ISSUE\]/CHILD-1}"
    command="${command//\[MERGED_AT\]/2026-10-16T12:00:00Z}"
    command="${command//\[MET_BOXES\]/all}"
    command="${command//\[EVIDENCE_FILE\]/$wt/tmp/evidence}"
    [[ "$command" != *'['* ]] || { printf 'micro-command: placeholder-left command=%s\n' "$command" >&2; return 1; }
    bash -c "$command" >/dev/null || return 1
  done
  run_close
}
while IFS='|' read -r row command want; do
  reset_state
  printf 'children\n' > "$FAKE_LINEAR_ROOT/validation.mode"
  printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
  rc=0; out="$(micro_child_close "$command" 2>"$TMP_ROOT/micro-$row.err")" || rc=$?
  refusal="$(grep -o 'completion-refused parent-id=PARENT-1' "$TMP_ROOT/micro-$row.err" || true)"
  assert_eq "$rc:$out:$refusal:$(cat "$FAKE_LINEAR_ROOT/parent.state")" "$want" "$row completion of a micro child decides its container's close" "$TMP_ROOT/micro-$row.err"
done <<ROWS
micro|$post_command|0:closed PARENT-1::Done
plain||1::completion-refused parent-id=PARENT-1:In Progress
ROWS

while IFS='|' read -r validation_mode key; do
  reset_state
  printf '%s\n' "$validation_mode" > "$FAKE_LINEAR_ROOT/validation.mode"
  printf '%s\n' '[{"id":"CHILD-1","title":"one","state":"Done","state_type":"completed"}]' > "$FAKE_LINEAR_ROOT/children.json"
  rc=0; run_close >/dev/null 2>"$TMP_ROOT/validation-$validation_mode.err" || rc=$?
  assert_eq "$rc:$(sed -n 's/^container-close: \([a-z-]*\) parent-id=PARENT-1$/\1/p' "$TMP_ROOT/validation-$validation_mode.err")" "1:$key" "$validation_mode validation refuses closure" "$TMP_ROOT/validation-$validation_mode.err"
  [[ ! -e "$FAKE_LINEAR_ROOT/complete.calls" ]] && pass "$validation_mode validation prevents parent mutation" || fail "$validation_mode validation prevents parent mutation"
done <<'ROWS'
exit|validation-failed
missing_parent|validation-result
duplicate_parent|validation-result
missing_open_boxes|validation-result
missing_errors|validation-result
wrong_summary_type|validation-result
wrong_child_box|validation-result
wrong_child_ok|validation-result
ROWS

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

rc=0
"$SCRIPT" >/dev/null 2>"$TMP_ROOT/arguments.err" || rc=$?
assert_eq "$rc:$(sed -n '1p' "$TMP_ROOT/arguments.err")" "2:container-close: invalid-arguments count=0" "missing operands identify the argument count"

printf 'container-close: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
