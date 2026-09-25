#!/usr/bin/env bash
# oversee-watch's report-due event: relayed from `oversee-report due` on every
# pass while a report is due, so it stops once the overseer writes one, and
# never where the report settings turn the cadence off. The judgement's own
# rows are oversee_report.sh; these hold the watch to relaying it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

NOW=1790000000
iso() { "$OVERSEE_TEST_REAL_DATE" -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || "$OVERSEE_TEST_REAL_DATE" -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
# write_state — one running lane with no window, launched a day before NOW,
# so the pass reads no pane for it.
write_state() {
  jq -n --arg at "$(iso $((NOW - 86400)))" \
    '{issue_id: "oversee", triaged: [], lanes: [{item: "issue-1", window: null, host: null, mail_root: "/w/issue-1",
      account: null, surface: "tmux", model: null, session_id: null, launched_at: $at, status: "running"}]}' \
    > "$STUB_DIR/state.json"
}
# report AGE — a report file beside the state, AGE seconds before NOW.
report() {
  local file="$STUB_DIR/progress-reports/$1.md" when
  mkdir -p "$STUB_DIR/progress-reports"
  echo "a report" > "$file"
  when="$("$OVERSEE_TEST_REAL_DATE" -u -d "@$((NOW - $1))" +%Y%m%d%H%M.%S 2>/dev/null \
    || "$OVERSEE_TEST_REAL_DATE" -u -r "$((NOW - $1))" +%Y%m%d%H%M.%S)"
  TZ=UTC touch -t "$when" "$file"
}
# watch [ENV=VAL...] — one pass at NOW; EVENTS holds its report-due lines
# joined by `|`, RC its exit status.
watch() {
  printf '%s\n' "$NOW" > "$STUB_DIR/now.epoch"
  RC=0
  EVENTS="$(run_watch ORCH_REPORT=on "$@" -- --max-loops 1 --state "$STUB_DIR/state.json" 2>"$STUB_DIR/err" </dev/null)" || RC=$?
  EVENTS="$(grep '^EVENT report-due' <<<"$EVENTS" | paste -sd '|' - || true)"
}

echo "=== report-due on every pass while the last report is older than the interval ==="
new_case report_due
write_state
report 7300
DUE="EVENT report-due reason=minutes since=$(iso $((NOW - 7300)))"
watch
assert_eq "$RC|$EVENTS" "0|$DUE" "a report older than the default 120 minutes makes the pass report it due" "$STUB_DIR/err"
watch
assert_eq "$RC|$EVENTS" "0|$DUE" "the next pass reports it again while no newer report exists" "$STUB_DIR/err"
report 60
watch
assert_eq "events=$EVENTS" "events=" "a report written since stops it" "$STUB_DIR/err"

echo "=== settings that turn the cadence off ==="
for setting in ORCH_REPORT_EVERY_MINUTES= ORCH_REPORT=off; do
  new_case "report_off_${setting%%=*}"
  write_state
  report 999999
  watch "$setting"
  assert_eq "events=$EVENTS" "events=" "$setting reports no report-due at any age" "$STUB_DIR/err"
done

echo "=== the completion count ==="
new_case report_issues
write_state
report 600
jq -n --arg at "$(iso $((NOW - 60)))" \
  '[{number: 7, headRefName: "issue-1", mergedAt: $at, mergeCommit: {oid: "abcdef1234"}}]' > "$STUB_DIR/merged.json"
watch ORCH_REPORT_EVERY_ISSUES=1
assert_eq "events=$EVENTS" "events=EVENT report-due reason=issues since=$(iso $((NOW - 600))) landed=1" \
  "a fleet item merged since the last report reaches ORCH_REPORT_EVERY_ISSUES=1" "$STUB_DIR/err"

echo "=== a judgement that fails fails the pass ==="
new_case report_unjudged
write_state
watch ORCH_REPORT=maybe
assert_eq "$RC|$(grep -c '^oversee-watch: report-unjudged exit=2 ' "$STUB_DIR/err" || true)|$(grep -c '^oversee-report: setting=ORCH_REPORT:maybe$' "$STUB_DIR/err" || true)" \
  "2|1|1" "a refused judgement exits the pass 2 with the report's own keyed line under the watch's" "$STUB_DIR/err"

echo "=== must-fail control ==="
# The watch without its report check: no report-due at any age.
MUTANT_DIR="$TMP_ROOT/report-mutant"
mkdir -p "$MUTANT_DIR/orch"
cp -R "$REPO_ROOT/skills/orch/scripts" "$MUTANT_DIR/orch/scripts"
ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
call='    check_report'
assert_eq "$(grep -cxF -- "$call" "$REPO_ROOT/skills/orch/scripts/oversee-watch")" "1" "control: the report check is one call to strip"
awk -v line="$call" '$0 == line { print "    :"; next } { print }' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MUTANT_DIR/orch/scripts/oversee-watch"
new_case report_due_mutant
write_state
report 999999
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" watch
assert_eq "events=$EVENTS" "events=" "control: without the check a report long overdue is never reported" "$STUB_DIR/err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
