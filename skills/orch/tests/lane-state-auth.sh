#!/usr/bin/env bash
# Login failures produced by Claude Code, Codex and Copilot are terminal
# walls. Inputs: scripts/lib/lane-state.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TMP_ROOT="$(mktemp -d)" || { echo "lane-state-auth: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lane-state-auth: scratch=not-a-directory" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lane-state-auth: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
JUDGE="$TEST_DIR/../scripts/lib/lane-state.sh"
source "$JUDGE"
CLAUDE_AUTH=$'  ⎿ \xc2\xa0Login expired · Please run /login'
CODEX_AUTH='■ Your access token could not be refreshed because your refresh token has expired.'
COPILOT_AUTH=' ✗ You must be logged in to send messages. Please run /login'
COMPOSER=$'❯\xc2\xa0'
for row in "claude|$CLAUDE_AUTH" "codex|$CODEX_AUTH" "copilot|$COPILOT_AUTH"; do
  IFS='|' read -r harness message <<<"$row"
  screen="❯ watch the fleet"$'\n'"$message"$'\n'"$COMPOSER"
  lane_state actual listed "$harness" "" "$screen" "" room idle
  assert_eq "$actual" walled "$harness login failure overrides usage room and a stale idle row"
  lane_state actual listed "$harness" "" "$screen"$'\n''esc to interrupt'
  assert_eq "$actual" working "$harness login words printed during a live turn do not stop it"
  lane_state actual listed "$harness" "" "$message"$'\n''❯ continue'$'\n'"$COMPOSER"
  assert_eq "$actual" idle "$harness login failure above a later turn is stale"
done
lane_state actual listed claude "" "❯ read lane news"$'\n''⏺ The lane answered "Login expired · Please run /login".'$'\n'"$COMPOSER"
assert_eq "$actual" idle "an inline quote in an overseer report is not its login failure"
CONTROL="$(mutant_scripts auth-classifier lib/lane-state.sh)"
mutate_file "$CONTROL/lib/lane-state.sh" 'AUTH_FAILURE_RE=' 'AUTH_FAILURE_RE_DISABLED='
# Retain the table's text but disable its use, as one failed classification
# must turn the auth contract red rather than merely stop the test running.
AUTH_FAILURE_RE='a^'
source "$CONTROL/lib/lane-state.sh"
lane_state actual listed claude "" "$CLAUDE_AUTH"$'\n'"$COMPOSER" "" room idle
if [[ "$actual" == walled ]]; then
  assert_eq control survived "must-fail: authentication classification removed"
else
  assert_eq control control "must-fail: removing authentication classification rejects the walled assertion"
fi
printf 'pass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
