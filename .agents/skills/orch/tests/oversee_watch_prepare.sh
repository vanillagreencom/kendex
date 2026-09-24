#!/usr/bin/env bash
# oversee-watch's report of the lanes open-terminal hands to a background job
# while their host prepares them, read from the `prepare` record the launcher
# and its job write: lane-ready and lane-prepare-failed for the outcome the job
# recorded, lane-prepare-stuck for a record still preparing past
# ORCH_WATCH_PREPARE_SECS, each once per preparation.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

SINCE=2026-08-15T10:00:00Z
SINCE_EPOCH="$(date -u -d "$SINCE" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$SINCE" +%s)"

# prepared ITEM STATUS STATE [SINCE] [REASON] — one lane record carrying the
# preparation a background job writes. No window and a local root, so the
# pass reads no pane and no host for it.
prepared() {
  jq -cn --arg item "$1" --arg status "$2" --arg state "$3" --arg since "${4:-$SINCE}" --arg reason "${5:-}" \
    '{item: $item, window: null, host: null, mail_root: "/w/\($item)", account: null, surface: "tmux", model: null,
      session_id: null, launched_at: "2026-08-15T09:00:00Z", status: $status,
      prepare: ({state: $state, since: $since, log: "/fleet/lane-prepare-\($item).log"} + (if $reason == "" then {} else {reason: $reason} end))}'
}
write_state() { # RECORD...
  printf '%s\n' "$@" | jq -s '{issue_id: "oversee", triaged: [], lanes: .}' > "$STUB_DIR/state.json"
}
# watch NOW [WATCH_BIN] — one pass at epoch NOW; EVENTS holds its EVENT lines
# joined by `|`, the heartbeat left out.
watch() {
  local err="$STUB_DIR/err"
  printf '%s\n' "$1" > "$STUB_DIR/now.epoch"
  EVENTS="$(WATCH_BIN="${2:-}" run_watch -- --max-loops 1 --state "$STUB_DIR/state.json" 2>"$err" </dev/null \
    | grep '^EVENT ' | grep -v '^EVENT heartbeat' | paste -sd '|' - || true)"
}

echo "=== each outcome the job recorded is reported once ==="
new_case prepare_outcomes
write_state "$(prepared issue-1 running ready)" "$(prepared issue-2 stopped failed "$SINCE" wait-failed)"
watch "$((SINCE_EPOCH + 60))"
assert_eq "$EVENTS" \
  "EVENT lane-ready issue-1|EVENT lane-prepare-failed issue-2 reason=wait-failed log=/fleet/lane-prepare-issue-2.log" \
  "a ready lane and a failed preparation are each reported by item, the failure with its reason and the job's log" "$STUB_DIR/err"
watch "$((SINCE_EPOCH + 120))"
assert_eq "events=$EVENTS" "events=" "a second pass over the same records reports neither again" "$STUB_DIR/err"
# A relaunch that prepares again starts a new preparation, which is news.
write_state "$(prepared issue-1 running ready 2026-08-15T11:00:00Z)" "$(prepared issue-2 stopped failed "$SINCE" wait-failed)"
watch "$((SINCE_EPOCH + 3660))"
assert_eq "events=$EVENTS" "events=EVENT lane-ready issue-1" "a preparation begun later is reported afresh" "$STUB_DIR/err"
# A closed lane's preparation is over.
write_state "$(prepared issue-5 "done" failed "$SINCE" launch-failed)"
watch "$((SINCE_EPOCH + 60))"
assert_eq "events=$EVENTS" "events=" "a done record's preparation is not reported" "$STUB_DIR/err"

echo "=== a record still preparing past the bound is reported stuck once ==="
new_case prepare_stuck
write_state "$(prepared issue-3 preparing pending)"
for row in "1800|" "1801|EVENT lane-prepare-stuck issue-3 age=1801s log=/fleet/lane-prepare-issue-3.log" "1900|"; do
  IFS='|' read -r age want <<<"$row"
  watch "$((SINCE_EPOCH + age))"
  assert_eq "events=$EVENTS" "events=$want" "a preparation ${age}s old at the default bound of 1800 reports '${want:-nothing}'" "$STUB_DIR/err"
done
# The job finishing after the stuck report is still news.
write_state "$(prepared issue-3 running ready)"
watch "$((SINCE_EPOCH + 2000))"
assert_eq "events=$EVENTS" "events=EVENT lane-ready issue-3" "a stuck lane that later comes up is reported ready" "$STUB_DIR/err"
new_case prepare_bound
write_state "$(prepared issue-4 preparing pending)"
printf '%s\n' "$((SINCE_EPOCH + 61))" > "$STUB_DIR/now.epoch"
EVENTS="$(run_watch ORCH_WATCH_PREPARE_SECS=60 -- --max-loops 1 --state "$STUB_DIR/state.json" 2>"$STUB_DIR/err" </dev/null | grep -c '^EVENT lane-prepare-stuck issue-4 age=61s ' || true)"
assert_eq "stuck=$EVENTS" "stuck=1" "ORCH_WATCH_PREPARE_SECS sets the bound" "$STUB_DIR/err"
EVENTS="$(run_watch ORCH_WATCH_PREPARE_SECS=060 -- --max-loops 1 --state "$STUB_DIR/state.json" 2>"$STUB_DIR/err" </dev/null || true)"
assert_eq "refused=$(grep -c '^oversee-watch: prepare-secs-invalid value=060$' "$STUB_DIR/err" || true)" "refused=1" \
  "a bound that is not a positive whole number refuses the watch" "$STUB_DIR/err"

echo "=== must-fail control ==="
# The once key compared against nothing: every pass reports the same outcome.
MUTANT_DIR="$TMP_ROOT/prepare-mutant"
mkdir -p "$MUTANT_DIR/orch"
cp -R "$REPO_ROOT/skills/orch/scripts" "$MUTANT_DIR/orch/scripts"
ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
once='    [[ "$key" != "$(lane_row_get lane-prepare "$rows" "$item")" ]] || continue'
assert_eq "$(grep -cxF -- "$once" "$REPO_ROOT/skills/orch/scripts/oversee-watch")" "1" "control: the once key is one line to strip"
awk -v line="$once" '$0 == line { print "    :"; next } { print }' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MUTANT_DIR/orch/scripts/oversee-watch"
new_case prepare_outcomes_mutant
write_state "$(prepared issue-1 running ready)"
watch "$((SINCE_EPOCH + 60))" "$MUTANT_DIR/orch/scripts/oversee-watch"
watch "$((SINCE_EPOCH + 120))" "$MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "events=$EVENTS" "events=EVENT lane-ready issue-1" "control: without the once key the second pass reports the ready lane again" "$STUB_DIR/err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
