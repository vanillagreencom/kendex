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
# The rows a vsys overseer on an account whose organization disabled
# subscription access wrote: three failed turns, each a StopFailure the
# stop-failure-row hook recorded with Claude Code's error kind and message.
OAUTH_MESSAGE='Your organization has disabled Claude subscription access for Claude Code · Use an Anthropic API key instead, or ask your admin to enable access'
auth_rows() { # ERROR
  local at
  if [[ "$1" != oauth_org_not_allowed ]]; then
    jq -nc --arg error "$1" '{harness:"claude",event:"StopFailure",error:$error}'
    return
  fi
  for at in 1792383331 1792383354 1792384489; do
    jq -nc --argjson at "$at" --arg message "$OAUTH_MESSAGE" \
      '{at:$at,event:"StopFailure",harness:"claude",session_id:"5f0c1d2e-vsys",error:"oauth_org_not_allowed",message:$message,account:"/home/method/.1claude"}'
  done
}
# The owner notices the overseer mailbox holds whose text opens with KEY.
owner_notices() { # KEY
  local file="$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-overseer.jsonl"
  [[ -f "$file" ]] || { echo 0; return; }
  jq -r --arg key "$1:" 'select(.to == "owner" and (.text | startswith($key))) | .text' "$file" | awk 'END { print NR }'
}
auth_case() { # NAME [ROW_ERROR]
  overseer_case "$1" idle
  touch "$STUB_DIR/repeat-child"
  state_with "$LINE"
  if [[ -n "${2:-}" ]]; then
    local rows="$CASE_REPO_ROOT/tmp/lane-mail/overseer/session-7000-9.jsonl"
    mkdir -p "${rows%/*}"
    auth_rows "$2" > "$rows"
    # The account read that sighting met: a refused usage query, so the
    # account judgement measured nothing.
    [[ "$2" != oauth_org_not_allowed ]] \
      || printf 'oversee-succeed: mark-unmeasured kind=headroom reason=headroom-none succession=on\n' > "$STUB_DIR/succeed.check"
    jq --arg rows "$rows" '.overseer.session_rows=$rows' "$STUB_DIR/oversee-state.json" > "$STUB_DIR/state.tmp"
    mv -- "$STUB_DIR/state.tmp" "$STUB_DIR/oversee-state.json"
  else
    printf '%s\n' '❯ watch the fleet' "$CLAUDE_AUTH" "$COMPOSER" > "$STUB_DIR/pane-$PANE.txt"
  fi
}
for shape in pane authentication_failed oauth_org_not_allowed; do
  error="$shape"; [[ "$shape" != pane ]] || error=""
  auth_case "auth_$shape" "$error"
  run TMUX_PANE="$PANE" -- --max-loops 1
  assert_eq "rc=$RC launched=$(succeed_calls --walled-pane) owner=$(owner_notices overseer-walled)" 'rc=3 launched=1 owner=1' \
    "$shape login failure starts succession on the first watch pass with one owner notice" "$ERR"
  assert_contains "$OUT" "EVENT overseer-walled $PANE window=$WINDOW passes=1" "first-pass wall event" "$ERR"
done
OWNER_CONTROL="$(mutant_scripts auth-owner/orch oversee-watch)"
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/auth-owner/github"
mutate_file "$OWNER_CONTROL/oversee-watch" '! overseer_auth_wall || overseer_owner_notice "$notice" "$errf" || true' '! overseer_auth_wall || true'
auth_case owner_control oauth_org_not_allowed
WATCH_BIN="$OWNER_CONTROL/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "launched=$(succeed_calls --walled-pane) owner=$(owner_notices overseer-walled)" 'launched=1 owner=0' \
  "must-fail: a wall notice kept off the owner channel leaves the owner untold" "$ERR"
# A last successful row must not hide a login banner on the next turn.
auth_case stale_rows
rows="$CASE_REPO_ROOT/tmp/lane-mail/overseer/session-7000-9.jsonl"
mkdir -p "${rows%/*}"
printf '%s\n' '{"harness":"claude","event":"Stop"}' > "$rows"
jq --arg rows "$rows" '.overseer.session_rows=$rows' "$STUB_DIR/oversee-state.json" > "$STUB_DIR/state.tmp"
mv -- "$STUB_DIR/state.tmp" "$STUB_DIR/oversee-state.json"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC launched=$(succeed_calls --walled-pane)" 'rc=3 launched=1' "stale success cannot suppress the login wall" "$ERR"
INSPECT_CONTROL="$(mutant_scripts auth-inspect/orch overseer-host-tmux)"
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/auth-inspect/github"
mutate_file "$INSPECT_CONTROL/overseer-host-tmux" '${LANE_WALL_KIND:+ wall_kind=$LANE_WALL_KIND}' ''
auth_case inspect_control
WATCH_BIN="$INSPECT_CONTROL/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC launched=$(succeed_calls --walled-pane)" 'rc=0 launched=0' "must-fail: inspect losing the wall kind suppresses first-pass recovery" "$ERR"
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
# No account with room: one keyed owner alert, which a later pass on the same
# wall does not send again.
for shape in pane authentication_failed oauth_org_not_allowed; do
  error="$shape"; [[ "$shape" != pane ]] || error=""
  auth_case "blocked_$shape" "$error"
  printf '3\n' > "$STUB_DIR/succeed.rc"
  run TMUX_PANE="$PANE" -- --max-loops 1
  assert_contains "$(cat -- "$ERR")" 'overseer-recovery-blocked pane=%9 account=unknown resets=none' "blocked $shape login recovery has no measured usage reset" "$ERR"
  assert_eq "$(succeed_calls --check-marks)" 0 "blocked $shape recovery does not wait for an account probe" "$ERR"
  run TMUX_PANE="$PANE" -- --max-loops 1
  assert_eq "launched=$(succeed_calls --walled-pane) owner=$(owner_notices overseer-recovery-blocked)" 'launched=1 owner=1' \
    "blocked $shape recovery alerts the owner once across passes" "$ERR"
done
BLOCKED_CONTROL="$(mutant_scripts auth-blocked/orch oversee-watch)"
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/auth-blocked/github"
mutate_file "$BLOCKED_CONTROL/oversee-watch" '  overseer_owner_notice "$notice" "$errf" || true
  ow_message overseer-recovery-blocked' '  ow_message overseer-recovery-blocked'
auth_case blocked_control oauth_org_not_allowed
printf '3\n' > "$STUB_DIR/succeed.rc"
WATCH_BIN="$BLOCKED_CONTROL/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "owner=$(owner_notices overseer-recovery-blocked)" 'owner=0' \
  "must-fail: a blocked recovery kept off the owner channel leaves the owner untold" "$ERR"
new_case auth_lane
printf '%s\n' '❯ continue the issue' "$CLAUDE_AUTH" "$COMPOSER" > "$STUB_DIR/pane-gh-2.txt"
OUT="$(run_watch -- --max-loops 1 gh-2 2>"$STUB_DIR/err")"
assert_contains "$OUT" 'EVENT usage-limit gh-2 wall_kind=auth' "lane login failure reaches recovery with the shared wall kind on the first pass" "$STUB_DIR/err"

# Codex can retry an out-of-credits turn before the watch captures a clear
# state, then report a permanent refresh failure in the same pane.
lane_wall_sequence() { # NAME
  new_case "$1"
  printf 'codex\n' > "$STUB_DIR/cmd-gh-2.txt"
  local shape message events rc
  while IFS='|' read -r shape message; do
    printf '%s\n' '› continue the issue' "$message" '› Ask Codex to do anything' > "$STUB_DIR/pane-gh-2.txt"
    rc=0
    OUT="$(run_watch -- --max-loops 1 gh-2 2>"$STUB_DIR/err")" || rc=$?
    events="$(awk '/^EVENT usage-limit /' <<<"$OUT")"
    printf '%s|%s|%s\n' "$shape" "$rc" "${events:-quiet}"
  done <<'ROWS'
usage|■ Your workspace is out of credits.
auth|■ Your access token could not be refreshed because your refresh token has expired.
auth_repeat|■ Your access token could not be refreshed because your refresh token has expired.
usage_again|■ Your workspace is out of credits.
usage_repeat|■ Your workspace is out of credits.
ROWS
}
WALL_SEQUENCE=$'usage|0|EVENT usage-limit gh-2\nauth|0|EVENT usage-limit gh-2 wall_kind=auth\nauth_repeat|0|quiet\nusage_again|0|EVENT usage-limit gh-2\nusage_repeat|0|quiet'
assert_eq "$(lane_wall_sequence wall_kind_transition)" "$WALL_SEQUENCE" \
  "a same-pane wall kind change reports once and an unchanged wall stays quiet" "$STUB_DIR/err"
IDENTITY_CONTROL="$(mutant_scripts auth-identity/orch oversee-watch)"
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/auth-identity/github"
mutate_file "$IDENTITY_CONTROL/oversee-watch" '[[ "$wall_kind" != auth ]] || reported_event="$event:auth"' '[[ "$wall_kind" != auth ]] || reported_event="$event"'
assert_eq "$(WATCH_BIN="$IDENTITY_CONTROL/oversee-watch" lane_wall_sequence wall_kind_control)" \
  $'usage|0|EVENT usage-limit gh-2\nauth|0|quiet\nauth_repeat|0|quiet\nusage_again|0|quiet\nusage_repeat|0|quiet' \
  "must-fail: ignoring the judge wall kind suppresses a later login failure" "$STUB_DIR/err"

# A shipped saved row can outlive its dayless reset, including a sighting
# observe_lanes recorded before the lane was judged walled.
saved_reset() { # NAME REPORTED_EVENT
  new_case "$1"
  mkdir -p "$STATE_DIR"
  printf 'usage-limit\tgh-2\t1788364800|7000 %%gh-2|%s|clock||||09:50|America/Los_Angeles\n' "$2" > "$STATE_DIR/owner_repo__none"
  printf '%b\n' "$WALL_BANNER" "$COMPOSER" > "$STUB_DIR/pane-gh-2.txt"
  printf '1788369300\n' > "$STUB_DIR/now.epoch"
  local rc=0
  OUT="$(run_watch TZ=UTC -- --max-loops 1 gh-2 2>"$STUB_DIR/err")" || rc=$?
  printf 'rc=%s\n' "$rc"
  awk '/^EVENT usage-limit/ { print }' <<<"$OUT"
  awk -F'\t' '$1 == "usage-limit" && $2 == "gh-2" { print $3 }' "$STATE_DIR/owner_repo__none"
}
SAVED_RESET=$'rc=0\nEVENT usage-limit-passed gh-2 resets=2026-09-02T16:50:00Z\n1788364800|7000 %gh-2|usage-limit-passed|clock||||09:50|America/Los_Angeles'
for reported in usage-limit ''; do
  assert_eq "$(saved_reset saved_reset "$reported")" "$SAVED_RESET" \
    "a saved $reported wall keeps its first-seen day and reset key after the reset passes" "$STUB_DIR/err"
done
RESET_CONTROL="$(mutant_scripts auth-reset/orch oversee-watch)"
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/auth-reset/github"
mutate_file "$RESET_CONTROL/oversee-watch" 'read -r seen_at seen_pane seen_reported seen_key <<<"$prior"' 'read -r seen_at seen_pane seen_reported shifted_kind seen_key <<<"$prior"'
assert_eq "$(WATCH_BIN="$RESET_CONTROL/oversee-watch" saved_reset saved_reset_control usage-limit)" \
  $'rc=0\nEVENT usage-limit gh-2 resets=2026-09-03T16:50:00Z\n1788369300|7000 %gh-2|usage-limit|clock||||09:50|America/Los_Angeles' \
  "must-fail: shifting a saved reset key discards the observed day" "$STUB_DIR/err"
printf 'pass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
