#!/usr/bin/env bash
# oversee-watch security-alert events: that each open alert of every kind is
# reported once, and not at all once the fleet state records its verdict; that
# a failed read is one unread line per pass; that a Dependabot pull request is
# named on its alert's line and in the heartbeat; and what turns the check off.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

HEARTBEAT="EVENT heartbeat loops=1 interval=0s since=none"

# run [ENV=VAL ...] -- ARGS... — one single-loop watch run; OUT, RC and ERR (a
# file) are what the checks read.
RUN_SEQ=0
run() {
  ERR="$TMP_ROOT/run-$((++RUN_SEQ)).err"
  OUT="$(run_watch "$@" --max-loops 1 2>"$ERR")" && RC=0 || RC=$?
}

# events — the run's security-alert lines, one per line, or `none`.
events() {
  local got
  got="$(grep '^EVENT security-alert ' <<<"$OUT" || true)"
  printf '%s' "${got:-none}"
}
# unread — the run's security-alerts-unread lines, or `none`.
unread() {
  local got
  got="$(grep '^EVENT security-alerts-unread ' <<<"$OUT" || true)"
  printf '%s' "${got:-none}"
}
heartbeats() { grep -c '^EVENT heartbeat ' <<<"$OUT" || true; }

URL=https://github.com/owner/repo/security
DEPENDABOT="{\"number\":7,\"html_url\":\"$URL/dependabot/7\",\"dependency\":{\"package\":{\"ecosystem\":\"npm\",\"name\":\"fast-uri\"},\"manifest_path\":\"ui/package-lock.json\",\"scope\":\"runtime\"},\"security_advisory\":{\"ghsa_id\":\"GHSA-aaaa-bbbb-cccc\",\"severity\":\"high\"}}"
DEPENDABOT_DEV="{\"number\":8,\"html_url\":\"$URL/dependabot/8\",\"dependency\":{\"package\":{\"ecosystem\":\"npm\",\"name\":\"undici\"},\"manifest_path\":\"ui/package-lock.json\",\"scope\":\"development\"},\"security_advisory\":{\"ghsa_id\":\"GHSA-dddd-eeee-ffff\",\"severity\":\"low\"}}"
CODE_SCANNING="{\"number\":9,\"html_url\":\"$URL/code-scanning/9\",\"rule\":{\"id\":\"js/xss\",\"severity\":\"error\",\"security_severity_level\":\"medium\"}}"
SECRET="{\"number\":3,\"html_url\":\"$URL/secret-scanning/3\",\"secret_type\":\"github_personal_access_token\",\"validity\":\"active\"}"
PR_12='{"number":7,"dependabotUpdate":{"pullRequest":{"number":12,"state":"OPEN"}}}'
LINE_DEPENDABOT="EVENT security-alert owner/repo kind=dependabot number=7 severity=high package=fast-uri manifest=ui/package-lock.json scope=runtime advisory=GHSA-aaaa-bbbb-cccc url=$URL/dependabot/7"
LINE_CODE="EVENT security-alert owner/repo kind=code-scanning number=9 severity=medium rule=js/xss url=$URL/code-scanning/9"
LINE_SECRET="EVENT security-alert owner/repo kind=secret-scanning number=3 rule=github_personal_access_token validity=active url=$URL/secret-scanning/3"
RECORDS='{"triaged":[],"alerts_triaged":[
  {"repo":"Owner/Repo","kind":"dependabot","number":7,"verdict":"filed","item":"KEN-1","reason":"runtime advisory"},
  {"repo":"owner/repo","kind":"code-scanning","number":9,"verdict":"dismissed","item":null,"reason":"test code"},
  {"repo":"owner/repo","kind":"secret-scanning","number":3,"verdict":"filed","item":"KEN-2","reason":"live token"}]}'
HTTP_403='gh: Resource not accessible by integration (HTTP 403)'

# one_of_each — one open alert of every kind, the Dependabot one with its
# open pull request.
one_of_each() {
  printf '[%s]\n' "$DEPENDABOT" > "$STUB_DIR/dependabot.json"
  printf '[%s]\n' "$CODE_SCANNING" > "$STUB_DIR/code-scanning.json"
  printf '[%s]\n' "$SECRET" > "$STUB_DIR/secret-scanning.json"
  printf '[%s]\n' "$PR_12" > "$STUB_DIR/dependabot-prs.json"
}

echo "=== oversee-watch security alerts ==="

# One open alert of each kind prints one line each, the Dependabot line naming
# its pull request, and ends the run as news. The next pass reports none.
new_case security_once
one_of_each
run --
assert_eq "$RC|$(events)|$(heartbeats)" "0|$LINE_DEPENDABOT pr=12
$LINE_CODE
$LINE_SECRET|0" "an open alert of each kind is one line each, and the run ends on them" "$ERR"
run --
assert_eq "$RC|$(events)|$(head -n 1 <<<"$OUT")" "0|none|$HEARTBEAT" \
  "an alert already reported is not a second line" "$ERR"

# The verdict record, not the baseline, is what silences an alert for good: a
# fresh baseline reports nothing the fleet state records, whatever the case of
# its repository.
new_case security_recorded
one_of_each
printf '%s\n' "$RECORDS" > "$STUB_DIR/oversee-state.json"
run --
assert_eq "$RC|$(events)|$(head -n 1 <<<"$OUT")" "0|none|$HEARTBEAT" \
  "an alert the fleet state records a verdict for is not reported" "$ERR"

# An alert that closes takes its row with it, so the same alert reopened is
# news again.
new_case security_reopened
printf '[%s]\n' "$CODE_SCANNING" > "$STUB_DIR/code-scanning.json"
run --
printf '[]\n' > "$STUB_DIR/code-scanning.json"
run --
printf '[%s]\n' "$CODE_SCANNING" > "$STUB_DIR/code-scanning.json"
run --
assert_eq "$RC|$(events)" "0|$LINE_CODE" "an alert closed and reopened is reported again" "$ERR"

# A failed read is one unread line per pass naming the source and GitHub's
# status, and the other lists are still read. The first pass with the failure
# ends the run; a pass on which it stands still prints it, and the heartbeat
# follows.
new_case security_unread
one_of_each
printf '%s\n' "$HTTP_403" > "$STUB_DIR/dependabot-fail"
run --
assert_eq "$RC|$(unread)|$(events)|$(heartbeats)" \
  "0|EVENT security-alerts-unread reads=owner/repo/dependabot:http-403|$LINE_CODE
$LINE_SECRET|0" "a 403 on one list is the unread line, and the other lists are reported" "$ERR"
assert_eq "$(grep -c '^oversee-watch: security-alerts-read-failed source=owner/repo/dependabot cause=http-403$' "$ERR" || true)" "1" \
  "the failed read is named on stderr with its cause" "$ERR"
run --
assert_eq "$RC|$(unread)|$(heartbeats)" "0|EVENT security-alerts-unread reads=owner/repo/dependabot:http-403|1" \
  "a standing failure prints the unread line again and the heartbeat still comes" "$ERR"

# A read that fails keeps the rows of its source: the alert reported before it
# is not news once the read comes back.
new_case security_rows_stand
one_of_each
run --
touch "$STUB_DIR/dependabot-fail"
run --
rm -f "$STUB_DIR/dependabot-fail"
run --
assert_eq "$RC|$(events)|$(unread)" "0|none|none" \
  "an alert reported before a failed read is not reported again after it" "$ERR"

# Refusals of a list's content: a line with no whole number, and a value with
# white space in it, are an unread list, never an empty one.
for row in \
  "a list line with no whole number is unread|[{\"number\":\"x\",\"html_url\":\"$URL/code-scanning/1\",\"rule\":{\"id\":\"r\",\"severity\":\"error\"}}]" \
  "a list value with white space is unread|[{\"number\":1,\"html_url\":\"$URL/code-scanning/1\",\"rule\":{\"id\":\"r x\",\"severity\":\"error\"}}]"; do
  IFS='|' read -r label body <<<"$row"
  new_case security_invalid
  printf '%s\n' "$body" > "$STUB_DIR/code-scanning.json"
  run --
  assert_eq "$RC|$(events)|$(unread)" "0|none|EVENT security-alerts-unread reads=owner/repo/code-scanning:invalid" "$label" "$ERR"
done

# A verdict record the check cannot read reports nothing and names the record.
new_case security_record_invalid
one_of_each
printf '{"triaged":[],"alerts_triaged":[{"repo":"owner/repo","kind":"npm","number":7}]}\n' > "$STUB_DIR/oversee-state.json"
run --
assert_eq "$RC|$(events)|$(unread)" "0|none|EVENT security-alerts-unread reads=alerts_triaged:invalid" \
  "a verdict record naming no alert kind is unread, and no alert is reported past it" "$ERR"

# The heartbeat names each open Dependabot pull request by the alerts its
# row maps to it, and none where no open alert does; other pull requests keep
# their line.
new_case security_heartbeat
printf '[%s,%s]\n' "$DEPENDABOT" "$DEPENDABOT_DEV" > "$STUB_DIR/dependabot.json"
printf '[%s,{"number":8,"dependabotUpdate":{"pullRequest":{"number":12,"state":"OPEN"}}},{"number":4,"dependabotUpdate":{"pullRequest":{"number":11,"state":"CLOSED"}}}]\n' \
  "$PR_12" > "$STUB_DIR/dependabot-prs.json"
printf '5\tken-5\tFix the thing\n12\tdependabot/npm_and_yarn/ui/security-1a2b\tBump the security group\tapp/dependabot\n13\tdependabot/cargo/time-0.3.47\tBump time\tapp/dependabot\n' \
  > "$STUB_DIR/open.txt"
run --
run --
assert_eq "$RC|$(grep -F $'owner/repo\t' <<<"$OUT" || true)" "0|owner/repo	5	ken-5	Fix the thing
owner/repo	bot-fix pr=12 alert=7,8
owner/repo	bot-fix pr=13 alert=none" \
  "a Dependabot pull request is bot-fix with its alerts, none where no open alert names it" "$ERR"

# A Dependabot pull request the last long pass could not map, its alert list
# unread, is unread rather than stale; with the check off it keeps its line.
DEPENDABOT_OPEN=$'12\tdependabot/npm_and_yarn/ui/security-1a2b\tBump the security group\tapp/dependabot'
new_case security_heartbeat_unread
printf '%s\n' "$HTTP_403" > "$STUB_DIR/dependabot-fail"
printf '%s\n' "$DEPENDABOT_OPEN" > "$STUB_DIR/open.txt"
run --
run --
assert_eq "$RC|$(grep -F $'owner/repo\t' <<<"$OUT" || true)" "0|owner/repo	bot-fix pr=12 alert=unread" \
  "a Dependabot pull request whose alert list is unread is bot-fix alert=unread" "$ERR"
new_case security_heartbeat_off
printf '%s\n' "$DEPENDABOT_OPEN" > "$STUB_DIR/open.txt"
run ORCH_SECURITY_ALERTS=off --
assert_eq "$RC|$(grep -F $'owner/repo\t' <<<"$OUT" || true)" "0|owner/repo	${DEPENDABOT_OPEN%$'\t'app/dependabot}" \
  "with the check off a Dependabot pull request keeps its plain line" "$ERR"

# The setting: off lists nothing and makes no call; any other value is refused.
new_case security_off
one_of_each
run ORCH_SECURITY_ALERTS=off --
assert_eq "$RC|$(events)|$(grep -cE '/alerts\?|api graphql' "$STUB_DIR/gh.calls" || true)" "0|none|0" \
  "ORCH_SECURITY_ALERTS=off lists nothing" "$ERR"
new_case security_setting_invalid
run ORCH_SECURITY_ALERTS=yes --
assert_eq "$RC|${OUT:-empty}|$(grep -c 'oversee-watch: security-alerts-invalid setting=ORCH_SECURITY_ALERTS value=yes' "$ERR" || true)" \
  "2|empty|1" "an ORCH_SECURITY_ALERTS value other than on or off is refused" "$ERR"

# Must-fail control: with the baseline row read dropped, a second pass without
# a record reports the same alert again.
MUTANT_DIR="$TMP_ROOT/security-mutant"
MUTANT_LIB="$(mutant_scripts security-mutant/orch lib/security-alerts.sh)/lib/security-alerts.sh" || exit 1
ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
mutate_file "$MUTANT_LIB" "[[ \"\$reported\" != *\$'\\n'\"\$key\"\$'\\n'* ]] || continue" ':'
new_case security_mutant
printf '[%s]\n' "$CODE_SCANNING" > "$STUB_DIR/code-scanning.json"
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run --
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run --
assert_eq "$(events)" "$LINE_CODE" \
  "control: without the baseline read a second pass without a record reports the same alert again" "$ERR"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
