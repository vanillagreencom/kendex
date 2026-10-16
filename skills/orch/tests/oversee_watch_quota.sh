#!/usr/bin/env bash
# Surface: watch scheduling receipts from Linear quota refusals. Inputs:
# oversee-watch, its libraries, and the existing watch harness. The tracker
# fixture returns the transport's typed receipt; it does not select a reset.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/oversee-watch-harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

cat >"$TMP_ROOT/bin/quota-tracker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --args '$ARGS.positional' -- "$@" >>"$STUB_DIR/quota.calls"
target=''
case "$1 $2" in
  'statuses list') target=statuses ;;
  'issues bulk-get') target=children ;;
  'issues update') target=repair ;;
  'comments bulk-list') target=comments ;;
  'issues list')
    case " $* " in *' --assignee '*) target=owner ;; *' --created-since '*) target=triage ;; *) target=list ;; esac ;;
esac
if [[ "$target" == "$(cat "$STUB_DIR/fail-target")" ]]; then
    cat "$STUB_DIR/refusal" >&2
    exit 1
fi
case "$target" in
  owner) cat "$STUB_DIR/tracker.out" ;;
  repair) printf '{}\n' ;;
  comments) printf '{}\n' ;;
  *) exec "${BASH_SOURCE[0]%/*}/linear-stub.sh" "$@" ;;
esac
SH
cat >"$TMP_ROOT/bin/quota-mail" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$STUB_DIR/mail.calls"
if [[ "$1" == pending ]]; then
    printf '%s\n' '{"id":"quota-ask","issue":"KEN-1","tracker_posted":true,"tracker_label":"owner-gated","do":"Approve the work."}'
elif [[ "$1" == resolve ]]; then
    printf 'resolved\n' >>"$STUB_DIR/resolved"
else
    exec "$QUOTA_REAL_MAIL" "$@"
fi
SH
cat >"$TMP_ROOT/bin/quota-report" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>"$STUB_DIR/report.calls"
SH
chmod +x "$TMP_ROOT/bin/quota-tracker" "$TMP_ROOT/bin/quota-mail" "$TMP_ROOT/bin/quota-report"

world() { # NAME TARGET STATUS
    new_case "$1"
    printf '10000\n' >"$STUB_DIR/now.epoch"
    printf '%s\n' "$2" >"$STUB_DIR/fail-target"
    : >"$STUB_DIR/quota.calls"
    : >"$STUB_DIR/resolved"
    printf '%s\n' '{"issue_id":"oversee","triaged":[],"launch_queue":[],"lanes":[]}' >"$STUB_DIR/fleet.json"
    printf '%s\n' '[{"id":"KEN-1","title":"Work","state":"In Progress","state_type":"started","priority":1,"created_at":"1970-01-01T00:00:01Z","description":"Build the work.","assignee":"Maya Owner"}]' >"$STUB_DIR/tracker.out"
    jq -nc --arg status "$3" '{code:"RATELIMITED",requests_reset:"1970-01-01T04:10:00Z",source:"response",
      quota:{status:$status,limit:"unknown",reset:(if $status == "future" then "1970-01-01T05:33:20Z"
        elif $status == "elapsed" then "1970-01-01T01:23:20Z" else "unavailable" end),
        reset_epoch:(if $status == "future" then 20000 elif $status == "elapsed" then 5000 else null end)}}' >"$STUB_DIR/refusal"
}
watch() {
    RC=0
    OUT="$(run_watch ORCH_OWNER_EMAIL=owner@example.com ORCH_OWNER_ASK_LABEL=owner-gated \
        QUOTA_REAL_MAIL="$REPO_ROOT/skills/orch/scripts/lane-mail" \
        OVERSEE_WATCH_TRACKER="$TMP_ROOT/bin/quota-tracker" OVERSEE_WATCH_LANE_MAIL="$TMP_ROOT/bin/quota-mail" \
        OVERSEE_WATCH_REPORT="$TMP_ROOT/bin/quota-report" "$@" \
        -- --max-loops 1 --since 1970-01-01T00:00:00Z --state "$STUB_DIR/fleet.json" 2>"$STUB_DIR/err")" || RC=$?
}
calls() { wc -l <"$STUB_DIR/quota.calls" | tr -d ' '; }

for target in owner repair comments triage statuses list children; do
    world "$target" "$target" future
    watch
    assert_eq "$RC" 0 "$target quota leaves available watch work running" "$STUB_DIR/err"
    assert_contains "$OUT" 'EVENT tracker-quota status=future reset=1970-01-01T05:33:20Z limit=unknown' "$target exposes the selected hold" "$STUB_DIR/err"
    # The failing operation must be the final tracker call in this pass.
    case "$target" in
      owner) last='issues list --assignee' ;;
      repair) last='issues update' ;;
      comments) last='comments bulk-list' ;;
      triage) last='issues list --team kendex --created-since' ;;
      statuses) last='statuses list' ;;
      list) last='issues list --team kendex --state' ;;
      children) last='issues bulk-get' ;;
    esac
    assert_contains "$(tail -1 "$STUB_DIR/quota.calls" | jq -r 'join(" ")')" "$last" "$target stops subsequent tracker operations" "$STUB_DIR/err"
    assert_eq "$(cat "$STUB_DIR/report.calls")" due "$target still checks report due" "$STUB_DIR/err"
    case "$target" in owner|repair|comments)
      assert_eq "$(wc -l <"$STUB_DIR/resolved" | tr -d ' ')" 0 "$target refusal cannot prove an unanswered owner ask" "$STUB_DIR/err" ;;
    esac
done

# One saved receipt covers the whole subgroup on the next process.
before="$(calls)"
resolved_before="$(wc -l <"$STUB_DIR/resolved" | tr -d ' ')"
: >"$STUB_DIR/mail.calls"
watch
assert_eq "$RC:$(calls)" "0:$before" 'a saved hold skips every tracker command' "$STUB_DIR/err"
assert_contains "$OUT" 'tracker-quota status=future reset=1970-01-01T05:33:20Z limit=unknown' 'heartbeat retains the hold' "$STUB_DIR/err"
assert_not_contains "$OUT" 'owed KEN-1' 'a hold has no stale owed inventory' "$STUB_DIR/err"
assert_eq "$(wc -l <"$STUB_DIR/resolved" | tr -d ' ')" "$resolved_before" 'a hold cannot prove an unanswered owner ask' "$STUB_DIR/err"
assert_eq "$(wc -l <"$STUB_DIR/report.calls" | tr -d ' ')" 2 'a standing hold still checks report due' "$STUB_DIR/err"
assert_file_contains "$STUB_DIR/mail.calls" 'peek' 'mail still runs during the hold'

for status in elapsed missing invalid; do
    world "$status" statuses "$status"
    watch
    assert_eq "$RC" 0 "$status reset keeps the pass available" "$STUB_DIR/err"
    assert_contains "$OUT" "EVENT tracker-quota status=$status" "$status reset stays distinct" "$STUB_DIR/err"
    before="$(calls)"
    printf 'none\n' >"$STUB_DIR/fail-target"
    watch
    assert_eq "$RC" 0 "$status reset permits the next ordinary pass" "$STUB_DIR/err"
    assert_eq "$(jq -sc '[.[] | select(.[0:2] == ["issues","bulk-get"])] | length' "$STUB_DIR/quota.calls")" 1 "$status reset reads a fresh inventory" "$STUB_DIR/err"
    [[ "$(calls)" -gt "$before" ]] && pass "$status reset retries tracker work" || fail "$status reset retries tracker work" "$OUT"
done

world expired statuses future
watch
printf '20000\n' >"$STUB_DIR/now.epoch"
printf 'none\n' >"$STUB_DIR/fail-target"
watch
assert_eq "$RC" 0 'a passed saved deadline permits an ordinary pass' "$STUB_DIR/err"
assert_eq "$(jq -sc '[.[] | select(.[0:2] == ["issues","bulk-get"])] | length' "$STUB_DIR/quota.calls")" 1 'a passed deadline reads a fresh inventory' "$STUB_DIR/err"

world ordinary statuses future
printf '{"code":"HTTP_ERROR","error":"upstream unavailable"}\n' >"$STUB_DIR/refusal"
watch
assert_eq "$RC" 2 'ordinary tracker failures retain their failure result' "$STUB_DIR/err"
assert_not_contains "$OUT" 'EVENT tracker-quota' 'ordinary failures create no quota event' "$STUB_DIR/err"

# The repeat owner starts real new child processes. Its existing named sleep
# boundary advances the fixture clock, then ends the test after two children.
world repeat statuses future
mkdir -p "$STUB_DIR/bin"
cat >"$STUB_DIR/bin/sleep" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${OVERSEE_WATCH_SLEEP:-}" == repeat ]] || exit 0
printf 'delay\n' >>"$STUB_DIR/delays"
[[ "$(wc -l <"$STUB_DIR/delays")" -lt 2 ]] || exit 1
printf '10001\n' >"$STUB_DIR/now.epoch"
SH
chmod +x "$STUB_DIR/bin/sleep"
RC=0
OUT="$(run_watch PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" ORCH_OWNER_EMAIL=owner@example.com ORCH_OWNER_ASK_LABEL=owner-gated \
    QUOTA_REAL_MAIL="$REPO_ROOT/skills/orch/scripts/lane-mail" \
    OVERSEE_WATCH_TRACKER="$TMP_ROOT/bin/quota-tracker" OVERSEE_WATCH_LANE_MAIL="$TMP_ROOT/bin/quota-mail" \
    OVERSEE_WATCH_REPORT="$TMP_ROOT/bin/quota-report" -- --repeat 0 --max-loops 1 --state "$STUB_DIR/fleet.json" \
    2>"$STUB_DIR/err")" || RC=$?
assert_eq "$RC" 2 'the repeat fixture ends at its named delay boundary' "$STUB_DIR/err"
assert_eq "$(jq -sc '[.[] | select(.[0:2] == ["statuses","list"])] | length' "$STUB_DIR/quota.calls")" 1 'new repeat children retain the selected deadline' "$STUB_DIR/err"
assert_eq "$(wc -l <"$STUB_DIR/report.calls" | tr -d ' ')" 2 'report due runs in both repeat children' "$STUB_DIR/err"
assert_contains "$OUT" 'EVENT heartbeat' 'the held repeat child reaches heartbeat' "$STUB_DIR/err"

MUTANT_SCRIPTS="$(mutant_scripts quota-schedule/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/quota-schedule/github"
ln -s "$REPO_ROOT/skills/linear" "$TMP_ROOT/quota-schedule/linear"
mutate_file "$MUTANT_SCRIPTS/oversee-watch" 'if [[ "$now" -lt "$epoch" ]]; then' 'if [[ "$now" -lt "$epoch" && 1 == 0 ]]; then'
world control statuses future
WATCH_BIN="$MUTANT_SCRIPTS/oversee-watch" watch
before="$(calls)"
WATCH_BIN="$MUTANT_SCRIPTS/oversee-watch" watch
control_rc=0
( FAIL=0; assert_eq "$(calls)" "$before" 'saved receipt suppresses commands'; [[ "$FAIL" == 0 ]] ) >"$STUB_DIR/control.log" || control_rc=$?
assert_eq "$control_rc" 1 'control rejects a watch that ignores the saved deadline' "$STUB_DIR/err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
