#!/usr/bin/env bash
# Cross-run state controls for oversee-watch lane-asking events, and the note
# a Copilot lane's session record puts on its lane-asking and idle lines.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"
# mutant_scripts and mutate_file, the two halves of the Copilot control below.
# shellcheck source=lib/growth-state.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/growth-state.sh"

echo "=== oversee-watch lane-asking state ==="

new_case lane_asking_once
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/asking-a"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" \
  "a new prompt emits lane-asking" "$err"

err="$TMP_ROOT/asking-b"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=none" \
  "the same prompt is emitted only once" "$err"
assert_not_contains "$out" "EVENT lane-asking" "an unchanged prompt never repeats" "$err"

printf 'Do you want to pick the other path?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/asking-c"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" \
  "a changed prompt emits a new lane-asking event" "$err"

# Prompt A clears when a later observation sees no prompt, then A is unseen again.
new_case lane_asking_disappears
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
run_watch -- --max-loops 1 gh-1 gh-2 >/dev/null 2>"$TMP_ROOT/asking-reset-a"
printf '⏺ working on it\n' > "$STUB_DIR/pane-gh-2.txt"
run_watch -- --max-loops 1 gh-1 gh-2 >/dev/null 2>"$TMP_ROOT/asking-reset-b"
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/asking-reset-c"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" \
  "prompt A emits again after a no-prompt observation" "$err"

# a prior merged event must not strand the old prompt baseline when the
# pane has already moved through a no-prompt screen.
new_case lane_asking_disappears_before_merge
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
run_watch -- --max-loops 1 gh-1 gh-2 >/dev/null 2>"$TMP_ROOT/asking-merge-a"
printf '⏺ working on it\n' > "$STUB_DIR/pane-gh-2.txt"
printf '[{"number":5,"headRefName":"issue-5","mergedAt":"2026-08-15T10:00:00Z"}]\n' > "$STUB_DIR/merged.json"
out="$(run_watch -- --max-loops 1 --item issue-5 gh-1 gh-2 2>"$TMP_ROOT/asking-merge-b")"
assert_eq "$(head -1 <<<"$out")" "EVENT merged 5 issue-5 owner/repo" \
  "the earlier merge event preempts the ordinary lane event pass"
printf '[]\n' > "$STUB_DIR/merged.json"
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/asking-merge-c"
out="$(run_watch -- --max-loops 1 --item issue-5 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" \
  "prompt A emits after disappearing behind an earlier event" "$err"

# The same text in a replacement pane is an unseen prompt occurrence.
new_case lane_asking_relaunch
printf '7000 %%2\n' > "$STUB_DIR/pane-key-gh-2.txt"
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
run_watch -- --max-loops 1 gh-1 gh-2 >/dev/null 2>"$TMP_ROOT/asking-relaunch-a"
printf '7000 %%9\n' > "$STUB_DIR/pane-key-gh-2.txt"
err="$TMP_ROOT/asking-relaunch-b"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" \
  "the same prompt emits in a replacement pane" "$err"

# The prompt text can repeat in one pane after the operator answered it. The
# submitted turn is the occurrence boundary even when the new dialog is equal.
new_case lane_asking_identical_reprompt
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
run_watch -- --max-loops 1 gh-1 gh-2 >/dev/null 2>"$TMP_ROOT/asking-reprompt-a"
{
  printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n'
  printf '❯ 1\n'
  printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/asking-reprompt-b"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" \
  "an identical prompt emits after a submitted answer" "$err"

# A failed fresh capture is a probe error once tmux confirmed the window.
# The failed redirect must not leave a reusable marker or lose stderr.
new_case lane_asking_capture_failure
: > "$STUB_DIR/capture-fail-gh-2"
err="$TMP_ROOT/asking-capture-fail"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "capture failure exits 2 after the window probe" "$err"
assert_eq "$out" "" "capture failure emits no window-gone event" "$err"
assert_contains "$(cat "$err")" "oversee-watch: pane-capture-failed lane=gh-2" \
  "capture failure names the probe" "$err"
assert_contains "$(cat "$err")" "E_CAPTURE lane=gh-2" \
  "capture failure preserves tmux stderr" "$err"

new_case lane_asking_identity_failure
printf 'E_IDENTITY\n' > "$STUB_DIR/pane-key-fail-gh-2"
err="$TMP_ROOT/asking-identity-fail"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "identity probe failure exits 2" "$err"
assert_eq "$out" "" "identity probe failure emits no window-gone event" "$err"
assert_eq "$(grep '^oversee-watch: pane-identity-failed ' "$err"; tail -n 1 "$err")" \
  "$(printf '%s\n' 'oversee-watch: pane-identity-failed lane=gh-2' 'E_IDENTITY')" "identity probe failure preserves tmux stderr" "$err"

new_case lane_asking_identity_malformed
printf 'not-a-pane-key\n' > "$STUB_DIR/pane-key-gh-2.txt"
err="$TMP_ROOT/asking-identity-malformed"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "malformed identity exits 2" "$err"
assert_eq "$out" "" "malformed identity emits no window-gone event" "$err"
assert_contains "$(cat "$err")" "oversee-watch: pane-identity-invalid lane=gh-2 value=not-a-pane-key" \
  "the malformed identity value is preserved" "$err"

# Control: a pane without a prompt emits no lane-asking event.
new_case lane_asking_no_prompt
err="$TMP_ROOT/asking-d"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=none" \
  "a pane with no prompt reaches the heartbeat" "$err"
assert_not_contains "$out" "EVENT lane-asking" "no prompt emits no lane-asking event" "$err"

# The fingerprint is a row in the one per-repo baseline, never a file of its
# own, and it coexists with the reducer's keys in that file.
new_case lane_asking_shares_repo_baseline
printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out"
printf '1\n' > "$STUB_DIR/prwatch.rc"
run_watch -- --max-loops 1 gh-1 gh-2 >/dev/null 2>"$TMP_ROOT/asking-share-a"
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/asking-share-b"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" \
  "the prompt emits once the reducer edge is baselined" "$err"
state_file="$STATE_DIR/owner_repo__none"
assert_contains "$(cat "$state_file")" "$(printf 'lane-asking\tgh-2\t')" \
  "the fingerprint is a row in the repo baseline" "$err"
assert_contains "$(cat "$state_file")" "$(printf '12\tthreads-open')" \
  "the reducer key survives beside it" "$err"
assert_eq "$(find "$STATE_DIR" -maxdepth 1 -type f ! -name '*.mail' | wc -l | tr -d '[:space:]')" "1" \
  "lane-asking creates no second state-file class" "$err"
err="$TMP_ROOT/asking-share-c"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=none" \
  "a reducer pass carries the fingerprint rather than replacing it" "$err"

new_case lane_asking_state_unwritable
mkdir -p "$STATE_DIR/owner_repo__none"
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/asking-f"
out="$(run_watch OVERSEE_WATCH_PR_WATCH="$TMP_ROOT/bin/absent-pr-watch" -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "a lane-asking baseline write failure exits 2" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" \
  "the event is delivered before its baseline write" "$err"
assert_contains "$(cat "$err")" "oversee-watch: state-target-invalid path=$STATE_DIR/owner_repo__none" \
  "the baseline write failure names its target" "$err"

echo "=== a Copilot lane's session record rides its lane-asking and idle lines ==="
# copilot_lane ALLOW SCREEN [GRANT] — gh-2 is a running Copilot fleet lane,
# launched with allow_all GRANT (true unless named), on an account whose one
# session ran in the lane's worktree, its record saying allow_all_enabled
# ALLOW, the watch's clock at the record's stamp, and its pane showing SCREEN:
# a permission prompt, or an idle composer.
copilot_lane() {
  local account="$STUB_DIR/.1copilot" wt="$STUB_DIR/wt"
  mkdir -p "$wt" "$account/session-state/cop-1"
  printf 'id: cop-1\ncwd: %s\n' "$(cd "$wt" && pwd -P)" > "$account/session-state/cop-1/workspace.yaml"
  printf '{"type":"session.start"}\n' > "$account/session-state/cop-1/events.jsonl"
  jq -cn --arg a "$account" --arg root "$wt" --argjson g "${3:-true}" \
    '{issue_id: "oversee", triaged: [], lanes: [{item: "gh-2", window: "gh-2", harness: "copilot",
      account: $a, mail_root: $root, status: "running", allow_all: $g}]}' > "$STUB_DIR/state.json"
  jq -cn --argjson a "$1" '{session_id: "cop-1", allow_all_enabled: $a}' \
    | COPILOT_HOME="$account" "$REPO_ROOT/skills/orch/scripts/copilot-statusline" >/dev/null
  jq -r '.written_at' "$account/lane-status/cop-1.json" > "$STUB_DIR/now.epoch"
  case "$2" in
    prompt) printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt" ;;
    idle) printf '%b\n' '⏺ Done: the PR is merged.' '\xe2\x9d\xaf\xc2\xa0' > "$STUB_DIR/pane-gh-2.txt" ;;
  esac
}
# copilot_events — the lane events one two-pass run prints, `|`-joined.
copilot_events() {
  WATCH_BIN="${COPILOT_WATCH:-}" run_watch -- --state "$STUB_DIR/state.json" 2>"$STUB_DIR/err" </dev/null \
    | grep '^EVENT lane-asking\|^EVENT idle-after-return' | paste -sd '|' - || true
}
# GRANT|PRIOR|ALLOW|SCREEN|WANT: PRIOR, where not `-`, is the allow_all_enabled
# an earlier run reported the same screen under, and WANT the events of the run
# after the record says ALLOW.
while IFS='|' read -r grant prior allow screen want; do
  [[ -n "$grant" ]] || continue
  new_case "copilot_${grant}_${prior}_${allow}_$screen"
  if [[ "$prior" != - ]]; then copilot_lane "$prior" "$screen" "$grant"; copilot_events >/dev/null; fi
  copilot_lane "$allow" "$screen" "$grant"
  assert_eq "$(copilot_events)" "$want" \
    "a Copilot lane launched with allow_all $grant whose record says allow_all_enabled $prior then $allow, at a $screen pane" "$STUB_DIR/err"
done <<'ROWS'
true|-|false|prompt|EVENT lane-asking gh-2 stop-cause=allow-all-blocked-by-policy
true|-|true|prompt|EVENT lane-asking gh-2
true|-|false|idle|EVENT idle-after-return gh-2 stop-cause=allow-all-blocked-by-policy
false|-|false|prompt|EVENT lane-asking gh-2
true|true|false|prompt|EVENT lane-asking gh-2 stop-cause=allow-all-blocked-by-policy
true|true|false|idle|EVENT idle-after-return gh-2 stop-cause=allow-all-blocked-by-policy
true|true|true|prompt|
ROWS
# The control: a watch whose lane-asking line drops the note reports a
# policy-blocked lane as a plain dialog to answer.
COPILOT_WATCH="$(mutant_scripts copilot-mutant/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/copilot-mutant/github"
mutate_file "$COPILOT_WATCH" 'echo "EVENT lane-asking $lane${COPILOT_SESSION_NOTE:+ $COPILOT_SESSION_NOTE}"' 'echo "EVENT lane-asking $lane"'
new_case copilot_mutant
copilot_lane false prompt
assert_eq "$(copilot_events)" "EVENT lane-asking gh-2" \
  "control: without the note a policy-blocked Copilot lane reads as a plain dialog" "$STUB_DIR/err"
# One control per dedupe key: a watch that leaves the note out of it stays
# silent on the unchanged screen whose record turned to a stop cause.
# SCREEN KEY: the mutant drops the note from the key line that starts KEY.
while read -r screen key; do
  COPILOT_WATCH="$(mutant_scripts "copilot-key-$screen/orch" oversee-watch)/oversee-watch" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/copilot-key-$screen/github"
  mutate_file "$COPILOT_WATCH" "$key\${COPILOT_SESSION_NOTE}|" "$key"
  new_case "copilot_key_mutant_$screen"
  copilot_lane true "$screen"
  copilot_events >/dev/null
  copilot_lane false "$screen"
  assert_eq "$(copilot_events)" "" \
    "control: a $screen key without the note hides a stop cause that follows an earlier report" "$STUB_DIR/err"
done <<'ROWS'
prompt fingerprint="${pane_key}|${turn_identity}|
idle screen_key="${pane_key}|
ROWS
COPILOT_WATCH=""

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
