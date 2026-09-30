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

# run [ENV=VAL ...] -- ARGS...: one watch run; OUT, RC and ERR (a file)
# are what the checks read. RUN_LOOPS overrides the single-loop default.
RUN_SEQ=0
run() {
  ERR="$TMP_ROOT/run-$((++RUN_SEQ)).err"
  OUT="$(run_watch "$@" --max-loops "${RUN_LOOPS:-1}" 2>"$ERR")" && RC=0 || RC=$?
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
# vulnerabilityAlerts nodes: an alert in STATE linking pull request PR in
# PR_STATE.
node() { # ALERT STATE PR PR_STATE
  printf '{"number":%s,"state":"%s","dependabotUpdate":{"pullRequest":{"number":%s,"state":"%s"}}}' "$@"
}
PR_12="$(node 7 OPEN 12 OPEN)"
LINE_DEPENDABOT="EVENT security-alert owner/repo kind=dependabot number=7 severity=high package=fast-uri manifest=ui/package-lock.json scope=runtime advisory=GHSA-aaaa-bbbb-cccc url=$URL/dependabot/7"
LINE_DEPENDABOT_DEV="EVENT security-alert owner/repo kind=dependabot number=8 severity=low package=undici manifest=ui/package-lock.json scope=development advisory=GHSA-dddd-eeee-ffff url=$URL/dependabot/8"
LINE_CODE="EVENT security-alert owner/repo kind=code-scanning number=9 severity=medium rule=js/xss url=$URL/code-scanning/9"
LINE_SECRET="EVENT security-alert owner/repo kind=secret-scanning number=3 rule=github_personal_access_token validity=active url=$URL/secret-scanning/3"
RECORDS='{"triaged":[],"alerts_triaged":[
  {"repo":"Owner/Repo","kind":"dependabot","number":7,"verdict":"filed","item":"KEN-1","reason":"runtime advisory"},
  {"repo":"owner/repo","kind":"code-scanning","number":9,"verdict":"dismissed","item":null,"reason":"test code"},
  {"repo":"owner/repo","kind":"secret-scanning","number":3,"verdict":"filed","item":"KEN-2","reason":"live token"}]}'
HTTP_403='gh: Resource not accessible by integration (HTTP 403)'
# DEPENDABOT_OPEN — an open Dependabot pull request as the open-list fixture
# spells it, author last.
DEPENDABOT_OPEN=$'12\tdependabot/npm_and_yarn/ui/security-1a2b\tBump the security group\tapp/dependabot'

# one_of_each — one open alert of every kind, the Dependabot one with its
# open pull request.
one_of_each() {
  printf '[%s]\n' "$DEPENDABOT" > "$STUB_DIR/dependabot.json"
  printf '[%s]\n' "$CODE_SCANNING" > "$STUB_DIR/code-scanning.json"
  printf '[%s]\n' "$SECRET" > "$STUB_DIR/secret-scanning.json"
  printf '[%s]\n' "$PR_12" > "$STUB_DIR/dependabot-prs.json"
}

echo "=== oversee-watch security alerts ==="

# GitHub CLI gives GH_TOKEN precedence over GITHUB_TOKEN and the keyring.
# Only the four alert reads use the supplied installation token. Each control
# restores the watch's ambient credential at one API call site.
for kind in rest graphql; do
  scripts="$(mutant_scripts "security-auth-$kind/orch" lib/security-alerts.sh)" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/security-auth-$kind/github"
  case "$kind" in
    rest) call='gh api --paginate' ;;
    graphql) call='gh api graphql' ;;
  esac
  mutate_file "$scripts/lib/security-alerts.sh" "GH_TOKEN=\"\$token\" $call" "GH_TOKEN=\"\${GH_TOKEN:-}\" $call"
done
for row in \
  'gh|GH_TOKEN=ghs_fixture_lane|0' \
  'github|GITHUB_TOKEN=ghs_fixture_lane|0' \
  'keyring|GH_TOKEN=|0' \
  'rest|GH_TOKEN=ghs_fixture_lane|3' \
  'graphql|GH_TOKEN=ghs_fixture_lane|1'; do
  IFS='|' read -r name ambient wrong <<<"$row"
  new_case "security_auth_$name"
  one_of_each
  watch="$REPO_ROOT/skills/orch/scripts/oversee-watch"
  case "$name" in rest|graphql) watch="$TMP_ROOT/security-auth-$name/orch/scripts/oversee-watch" ;; esac
  WATCH_BIN="$watch" run "$ambient" --
  current=ghs_fixture_lane
  [[ "$name" != keyring ]] || current=keyring
  got="$(awk -F'\t' -v current="$current" '
    $2 == "api" && ($3 == "graphql" || ($3 == "--paginate" && $4 ~ /\/alerts\?/)) {
      alerts++; if ($1 != "ghs_fixture_overseer") wrong++; next
    }
    { other++; if ($1 != current) leaked++ }
    END { printf "%d|%d|%d|%d", alerts, wrong, (other > 0), leaked }
  ' "$STUB_DIR/gh.auth")" || exit 1
  assert_eq "$RC|$got" "0|4|$wrong|1|0" "alert credential isolation: $name" "$ERR"
done

# The control VM renews short-lived tokens while the same watch is running.
# Replacement during the GraphQL read affects only the next long pass.
new_case security_auth_rotation
printf 'ghs_fixture_renewed\n' > "$STUB_DIR/next-alert-token"
RUN_LOOPS=2 run GH_TOKEN=ghs_fixture_lane --
got="$(awk -F'\t' '
  $2 == "api" && ($3 == "graphql" || ($3 == "--paginate" && $4 ~ /\/alerts\?/)) { print $1 }
' "$STUB_DIR/gh.auth")" || exit 1
assert_eq "$RC|$got" '0|ghs_fixture_overseer
ghs_fixture_overseer
ghs_fixture_overseer
ghs_fixture_overseer
ghs_fixture_renewed
ghs_fixture_renewed
ghs_fixture_renewed
ghs_fixture_renewed' "one token snapshot per pass, renewed without restarting the watch" "$ERR"

# No usable token means no fallback API read. Alert rows and the heartbeat's
# security-update mapping survive the outage, before recovery can repair them.
# The table includes the control VM's missing file and interrupted/invalid writes.
for shape in unset missing empty whitespace multiline; do
  new_case "security_auth_$shape"
  one_of_each
  printf '%s\n' "$DEPENDABOT_OPEN" > "$STUB_DIR/open.txt"
  run --
  supplied="$STUB_DIR/alert-token"
  case "$shape" in
    unset) supplied="" ;;
    missing) rm -- "$supplied" ;;
    empty) : > "$supplied" ;;
    whitespace) printf ' \t\n' > "$supplied" ;;
    multiline) printf 'ghs_fixture_overseer\nghs_fixture_renewed\n' > "$supplied" ;;
  esac
  : > "$STUB_DIR/gh.auth"
  run GH_TOKEN=ghs_fixture_lane "ORCH_SECURITY_ALERT_TOKEN_FILE=$supplied" --
  refused="$RC|$(unread)|$(events)"
  run GH_TOKEN=ghs_fixture_lane "ORCH_SECURITY_ALERT_TOKEN_FILE=$supplied" --
  retained="$RC|$(unread)|$(events)|$(heartbeats)|$(grep -F $'owner/repo\t' <<<"$OUT" || true)"
  calls="$(awk -F'\t' '$2 == "api" && ($3 == "graphql" || ($3 == "--paginate" && $4 ~ /\/alerts\?/)) { n++ } END { print n+0 }' "$STUB_DIR/gh.auth")" || exit 1
  printf 'ghs_fixture_renewed\n' > "$STUB_DIR/alert-token"
  run --
  assert_eq "$refused|$retained|$calls|$RC|$(unread)|$(events)" "0|EVENT security-alerts-unread reads=installation-token:credential|none|0|EVENT security-alerts-unread reads=installation-token:credential|none|1|owner/repo	bot-fix pr=12 alert=7|0|0|none|none" \
    "unusable token refuses fallback, retains the mapping during the outage and recovers without repeating alerts: $shape" "$ERR"
done

# Must-fail control: keep the file read and token checks but disable their
# refusal. The credential row must fail rather than accept gh's fallback.
scripts="$(mutant_scripts security-token-control/orch lib/security-alerts.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/security-token-control/github"
mutate_file "$scripts/lib/security-alerts.sh" \
  '    || [[ -z "$token" || "$token" == *[[:space:]]* ]]; then' \
  '    || [[ -z "$token" || "$token" == *[[:space:]]* ]] && false; then'
for shape in missing empty; do
  new_case "security_token_control_$shape"
  case "$shape" in missing) rm -- "$STUB_DIR/alert-token" ;; empty) : > "$STUB_DIR/alert-token" ;; esac
  WATCH_BIN="$scripts/oversee-watch" run GH_TOKEN=ghs_fixture_lane --
  assert_eq "$RC|$(unread)" "0|none" "control: token refusal removed makes the credential row fail: $shape" "$ERR"
done

# One open alert of each kind prints one line each, the Dependabot line naming
# its pull request, and ends the run as news. The next pass reports none.
# An alert whose Dependabot pull request is closed names none, and the secret
# list is read without the secret's value.
new_case security_once
one_of_each
printf '[%s,%s]\n' "$DEPENDABOT" "$DEPENDABOT_DEV" > "$STUB_DIR/dependabot.json"
printf '[%s,%s]\n' "$PR_12" "$(node 8 OPEN 11 CLOSED)" > "$STUB_DIR/dependabot-prs.json"
run --
assert_eq "$RC|$(events)|$(heartbeats)" "0|$LINE_DEPENDABOT pr=12
$LINE_DEPENDABOT_DEV
$LINE_CODE
$LINE_SECRET|0" "an open alert of each kind is one line each, and the run ends on them" "$ERR"
assert_eq "$(grep -c '^api --paginate repos/owner/repo/secret-scanning/alerts?state=open&per_page=100&hide_secret=true ' "$STUB_DIR/gh.calls" || true)" "1" \
  "the secret scanning list asks GitHub to leave each secret's value out" "$ERR"
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
  "0|EVENT security-alerts-unread reads=owner/repo/dependabot:permission|$LINE_CODE
$LINE_SECRET|0" "a failed read of one list is the unread line, and the other lists are reported" "$ERR"
assert_eq "$(grep -c '^oversee-watch: security-alerts-read-failed source=owner/repo/dependabot cause=permission$' "$ERR" || true)" "1" \
  "the failed read is named on stderr with its cause" "$ERR"
run --
assert_eq "$RC|$(unread)|$(heartbeats)" "0|EVENT security-alerts-unread reads=owner/repo/dependabot:permission|1" \
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

# The cause a failed list read is named by, from what gh printed: a missing
# permission and an alert feature turned off are told apart by GitHub's own
# words, and any other failure keeps its HTTP status.
for row in \
  "dependabot|$HTTP_403|permission" \
  "code-scanning|gh: Resource not accessible by personal access token (HTTP 403)|permission" \
  "dependabot|gh: Dependabot alerts are disabled for this repository. (HTTP 403)|feature-off" \
  "secret-scanning|gh: Secret scanning is disabled on this repository. (HTTP 404)|feature-off" \
  "code-scanning|gh: GitHub Code Security or GitHub Advanced Security is not enabled (HTTP 403)|feature-off" \
  "code-scanning|gh: Advanced Security must be enabled for this repository to use code scanning. (HTTP 403)|feature-off" \
  "code-scanning|gh: no analysis found (HTTP 404)|feature-off" \
  "code-scanning|gh: You have exceeded a secondary rate limit. (HTTP 403)|http-403" \
  "secret-scanning|gh: Bad Gateway (HTTP 502)|http-502"; do
  IFS='|' read -r kind text cause <<<"$row"
  new_case security_cause
  printf '%s\n' "$text" > "$STUB_DIR/$kind-fail"
  run --
  assert_eq "$RC|$(unread)" "0|EVENT security-alerts-unread reads=owner/repo/$kind:$cause" "$text is cause $cause" "$ERR"
done

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

# A manifest path is the one column that may hold white space: it is
# percent-encoded, `%` first, so its alert and the rest of the list are read.
new_case security_manifest_encoded
printf '[%s,%s]\n' "$DEPENDABOT" "${DEPENDABOT_DEV/ui\/package-lock.json/packages/my app/100%/package.json}" \
  > "$STUB_DIR/dependabot.json"
run --
assert_eq "$RC|$(events)|$(unread)" "0|$LINE_DEPENDABOT
${LINE_DEPENDABOT_DEV/ui\/package-lock.json/packages/my%20app/100%25/package.json}|none" \
  "a manifest path with a space or a percent sign is encoded, and the list is read" "$ERR"

# A verdict record the check cannot read reports nothing and names the record.
new_case security_record_invalid
one_of_each
printf '{"triaged":[],"alerts_triaged":[{"repo":"owner/repo","kind":"npm","number":7}]}\n' > "$STUB_DIR/oversee-state.json"
run --
assert_eq "$RC|$(events)|$(unread)" "0|none|EVENT security-alerts-unread reads=alerts_triaged:invalid" \
  "a verdict record naming no alert kind is unread, and no alert is reported past it" "$ERR"

# A verdict record that cannot be read at all, its presence check or its read
# failing, is unread under the reader's exit status with the reader's words on
# stderr, and no alert is reported past it. A `get` exits 5 on a state file
# holding invalid JSON; `exists` answers 1 for no file, which is no verdict.
for row in "get|.alerts_triaged |5" "exists| exists oversee |2"; do
  IFS='|' read -r verb match status <<<"$row"
  new_case security_record_unread
  one_of_each
  {
    printf '#!/usr/bin/env bash\n'
    printf '[[ " $* " != *"%s"* ]] || { echo "workflow-state: %s refused" >&2; exit %s; }\n' "$match" "$verb" "$status"
    printf 'exec "$STUB_DIR/../../bin/workflow-state-stub.sh" "$@"\n'
  } > "$STUB_DIR/record-fail.sh"
  chmod +x "$STUB_DIR/record-fail.sh"
  run OVERSEE_WATCH_WORKFLOW_STATE="$STUB_DIR/record-fail.sh" --
  assert_eq "$RC|$(events)|$(unread)|$(grep -c "^workflow-state: $verb refused$" "$ERR" || true)" \
    "0|none|EVENT security-alerts-unread reads=alerts_triaged:exit-$status|1" \
    "a verdict record whose $verb read fails is unread, and no alert is reported past it" "$ERR"
done

# The heartbeat names each open Dependabot pull request an alert links by its
# open alerts, and none where every alert that links it has left the open
# list. One no alert links, a version update, keeps its plain line, as does a
# pull request of any other author.
new_case security_heartbeat
printf '[%s,%s]\n' "$DEPENDABOT" "$DEPENDABOT_DEV" > "$STUB_DIR/dependabot.json"
printf '[%s,%s,%s,%s]\n' "$PR_12" "$(node 8 OPEN 12 OPEN)" "$(node 6 DISMISSED 12 OPEN)" "$(node 4 FIXED 14 OPEN)" \
  > "$STUB_DIR/dependabot-prs.json"
printf '5\tken-5\tFix the thing\toctocat\n%s\n13\tdependabot/cargo/time-0.3.47\tBump time\tapp/dependabot\n14\tdependabot/pip/requests-2.32.4\tBump requests\tapp/dependabot\n' \
  "$DEPENDABOT_OPEN" > "$STUB_DIR/open.txt"
run --
run --
assert_eq "$RC|$(grep -F $'owner/repo\t' <<<"$OUT" || true)" "0|owner/repo	5	ken-5	Fix the thing
owner/repo	bot-fix pr=12 alert=7,8
owner/repo	13	dependabot/cargo/time-0.3.47	Bump time
owner/repo	bot-fix pr=14 alert=none" \
  "a Dependabot pull request an alert links is bot-fix with its open alerts, and one none links keeps its line" "$ERR"

# A failed read of the alert-to-pull-request link names its own source, and
# the mapping of the last good read stands; a Dependabot pull request that
# read never saw keeps its plain line.
new_case security_heartbeat_unread
printf '[%s]\n' "$DEPENDABOT" > "$STUB_DIR/dependabot.json"
printf '[%s]\n' "$PR_12" > "$STUB_DIR/dependabot-prs.json"
printf '%s\n' "$DEPENDABOT_OPEN" > "$STUB_DIR/open.txt"
run --
touch "$STUB_DIR/graphql-fail"
printf '%s\n15\tdependabot/npm_and_yarn/ui/security-3c4d\tBump the ui group\tapp/dependabot\n' "$DEPENDABOT_OPEN" > "$STUB_DIR/open.txt"
run --
assert_eq "$RC|$(unread)|$(heartbeats)" "0|EVENT security-alerts-unread reads=owner/repo/dependabot-prs:permission|0" \
  "a failed pull request link read is unread under its own source" "$ERR"
run --
assert_eq "$RC|$(grep -F $'owner/repo\t' <<<"$OUT" || true)" "0|owner/repo	bot-fix pr=12 alert=7
owner/repo	15	dependabot/npm_and_yarn/ui/security-3c4d	Bump the ui group" \
  "a failed pull request link read keeps the last mapping, and a pull request it never saw keeps its line" "$ERR"
new_case security_heartbeat_off
printf '%s\n' "$DEPENDABOT_OPEN" > "$STUB_DIR/open.txt"
run ORCH_SECURITY_ALERTS=off --
assert_eq "$RC|$(grep -F $'owner/repo\t' <<<"$OUT" || true)" "0|owner/repo	${DEPENDABOT_OPEN%$'\t'app/dependabot}" \
  "with the check off a Dependabot pull request keeps its plain line" "$ERR"

# The setting: off lists nothing and makes no call; any other value is refused.
new_case security_off
one_of_each
run ORCH_SECURITY_ALERTS=off "ORCH_SECURITY_ALERT_TOKEN_FILE=$STUB_DIR/missing-token" --
assert_eq "$RC|$(events)|$(unread)|$(grep -cE '/alerts\?|api graphql' "$STUB_DIR/gh.calls" || true)" "0|none|none|0" \
  "ORCH_SECURITY_ALERTS=off reads neither the token nor alerts" "$ERR"
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
