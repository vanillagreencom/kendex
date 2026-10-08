#!/usr/bin/env bash
# First-watch recovery of login failures. Inputs: scripts/oversee-watch,
# scripts/lib/lane-state.sh, scripts/lib/session-rows.sh and the shared harness.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$TEST_DIR/lib/oversee-watch-harness.sh"
source "$TEST_DIR/lib/overseer-watch-case.sh"
CLAUDE_AUTH='  ⎿  Login expired · Please run /login'
COMPOSER=$'❯\xc2\xa0'
auth_case() { # NAME [ROW_ERROR]
  overseer_case "$1" idle
  touch "$STUB_DIR/repeat-child"
  state_with "$LINE"
  if [[ -n "${2:-}" ]]; then
    local rows="$CASE_REPO_ROOT/tmp/lane-mail/overseer/session-7000-9.jsonl"
    mkdir -p "${rows%/*}"
    jq -nc --arg error "$2" '{harness:"claude",event:"StopFailure",error:$error}' > "$rows"
    jq --arg rows "$rows" '.overseer.session_rows=$rows' "$STUB_DIR/oversee-state.json" > "$STUB_DIR/state.tmp"
    mv -- "$STUB_DIR/state.tmp" "$STUB_DIR/oversee-state.json"
  else
    printf '%s\n' '❯ watch the fleet' "$CLAUDE_AUTH" "$COMPOSER" > "$STUB_DIR/pane-$PANE.txt"
  fi
}
for shape in pane authentication_failed; do
  error="$shape"; [[ "$shape" != pane ]] || error=""
  auth_case "auth_$shape" "$error"
  run TMUX_PANE="$PANE" -- --max-loops 1
  assert_eq "rc=$RC launched=$(succeed_calls --walled-pane)" 'rc=3 launched=1' "$shape login failure starts succession on the first watch pass" "$ERR"
  assert_contains "$OUT" "EVENT overseer-walled $PANE window=$WINDOW passes=1" "first-pass wall event" "$ERR"
done
# A last successful row must not hide a login banner on the next turn.
auth_case stale_rows
rows="$CASE_REPO_ROOT/tmp/lane-mail/overseer/session-7000-9.jsonl"
mkdir -p "${rows%/*}"
printf '%s\n' '{"harness":"claude","event":"Stop"}' > "$rows"
jq --arg rows "$rows" '.overseer.session_rows=$rows' "$STUB_DIR/oversee-state.json" > "$STUB_DIR/state.tmp"
mv -- "$STUB_DIR/state.tmp" "$STUB_DIR/oversee-state.json"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC launched=$(succeed_calls --walled-pane)" 'rc=3 launched=1' "stale success cannot suppress the login wall" "$ERR"
WATCH_CONTROL="$(mutant_scripts auth-watch/orch oversee-watch)"
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/auth-watch/github"
mutate_file "$WATCH_CONTROL/oversee-watch" 'OV_STATE=walled OV_SOURCE=auth OV_SCREEN="$OL_DETAIL"' 'OV_STATE=walled OV_SOURCE=pane OV_SCREEN="$OL_DETAIL"'
auth_case watch_control
WATCH_BIN="$WATCH_CONTROL/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC launched=$(succeed_calls --walled-pane)" 'rc=0 launched=0' "must-fail: requiring usage room confirmation suppresses first-pass auth recovery" "$ERR"
ROWS_CONTROL="$(mutant_scripts auth-rows/orch lib/session-rows.sh)"
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/auth-rows/github"
mutate_file "$ROWS_CONTROL/lib/session-rows.sh" '&& lane_auth_failure "" "${auth_fields#claude:StopFailure:}"' '&& false && lane_auth_failure "" "${auth_fields#claude:StopFailure:}"'
auth_case rows_control authentication_failed
WATCH_BIN="$ROWS_CONTROL/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC launched=$(succeed_calls --walled-pane)" 'rc=0 launched=0' "must-fail: ignoring authentication_failed leaves the overseer unrecovered" "$ERR"
new_case auth_lane
printf '%s\n' '❯ continue the issue' "$CLAUDE_AUTH" "$COMPOSER" > "$STUB_DIR/pane-gh-2.txt"
OUT="$(run_watch -- --max-loops 1 gh-2 2>"$STUB_DIR/err")"
assert_contains "$OUT" 'EVENT usage-limit gh-2' "lane login failure reaches the existing walled-lane handler on the first pass" "$STUB_DIR/err"
printf 'pass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
