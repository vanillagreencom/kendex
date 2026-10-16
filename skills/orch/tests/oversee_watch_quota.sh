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

# lane-close relays tracker stderr through its own diagnostics. The watch owns
# the result handling; the earlier terminal-suite measurement uses the real
# close verb to establish this response boundary.
cat >"$TMP_ROOT/bin/quota-close" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --args '$ARGS.positional' -- "$@" >>"$STUB_DIR/close.calls"
mode=$(cat "$STUB_DIR/close-mode")
if [[ " $* " == *' --terminal-state '* ]]; then
    count=$(wc -l <"$STUB_DIR/close.calls")
    if [[ "$mode" == open || "$mode" == bare || ( "$mode" == heartbeat && "$count" -lt 2 ) ]]; then printf 'open\n'; exit 0; fi
    if [[ "$mode" == conditional ]]; then printf 'completed\n'; exit 0; fi
fi
if [[ "$mode" != open ]]; then
    cat "$STUB_DIR/refusal" >&2
    printf 'lane-close: tracker-read-failed\n' >&2
    exit 2
fi
SH
chmod +x "$TMP_ROOT/bin/quota-close"
lane_world() { # NAME STATUS
    world "$1" none future
    : >"$STUB_DIR/close.calls"
    jq -nc --arg status "$2" '{lanes:[{item:"KEN-1",tracker:null,status:$status,window:null,
      parked:(if $status == "parked" then {pr:1,repo:"owner/repo"} else null end)}]}' >"$STUB_DIR/fleet.json"
}
lane_watch() {
    watch ORCH_OWNER_EMAIL= LINEAR_TEAM= OVERSEE_WATCH_LANE_CLOSE="$TMP_ROOT/bin/quota-close" "$@"
}
close_calls() { wc -l <"$STUB_DIR/close.calls" | tr -d ' '; }
lane_merged() {
    printf '[{"number":1,"headRefName":"ken-1","mergedAt":"1970-01-01T00:00:01Z"}]\n' >"$STUB_DIR/merged.json"
}
for entry in stopped parked conditional dependency; do
    status=stopped
    case "$entry" in parked|dependency) status=parked ;; esac
    lane_world "indirect_$entry" "$status"
    mode=terminal
    [[ "$entry" != conditional ]] || mode=conditional
    printf '%s\n' "$mode" >"$STUB_DIR/close-mode"
    [[ "$status" != parked ]] || lane_merged
    if [[ "$entry" == dependency ]]; then
        jq '.lanes[0].parked.until_pr=2' "$STUB_DIR/fleet.json" >"$STUB_DIR/next"
        mv -- "$STUB_DIR/next" "$STUB_DIR/fleet.json"
        printf '{"state":"MERGED"}\n' >"$STUB_DIR/dependency-2.json"
        printf '{"number":1,"headRefName":"ken-1","mergedAt":null,"headRepositoryOwner":{"login":"owner"}}\n' >"$STUB_DIR/dependency-1.json"
    fi
    lane_watch
    assert_eq "$RC" 0 "$entry indirect quota keeps the pass available" "$STUB_DIR/err"
    assert_contains "$OUT" 'EVENT tracker-quota status=future' "$entry classifies the close refusal" "$STUB_DIR/err"
    assert_not_contains "$OUT" 'EVENT lane-closed' "$entry quota cannot establish terminality" "$STUB_DIR/err"
    assert_eq "$(cat "$STUB_DIR/report.calls")" due "$entry indirect quota still checks report due" "$STUB_DIR/err"
    before="$(close_calls)"
    lane_watch
    assert_eq "$RC:$(close_calls)" "0:$before" "$entry saves the hold across row commits and processes" "$STUB_DIR/err"
    assert_contains "$OUT" 'EVENT heartbeat' "$entry held pass reaches heartbeat" "$STUB_DIR/err"
    if [[ "$status" == parked ]]; then
        printf '20000\n' >"$STUB_DIR/now.epoch"
        printf 'open\n' >"$STUB_DIR/close-mode"
        lane_watch
        assert_eq "$RC" 0 "$entry reset permits the parked probe" "$STUB_DIR/err"
        assert_contains "$OUT" 'EVENT parked-merged KEN-1' "$entry deferred notification replays after reset" "$STUB_DIR/err"
    fi
done

# A non-quota failure from the same indirect reader remains a failed pass.
lane_world indirect_ordinary stopped
printf 'terminal\n' >"$STUB_DIR/close-mode"
printf '{"code":"HTTP_ERROR"}\n' >"$STUB_DIR/refusal"
lane_watch
assert_eq "$RC" 2 'ordinary terminal probe failures remain failed passes' "$STUB_DIR/err"
assert_not_contains "$OUT" 'EVENT tracker-quota' 'ordinary terminal failures create no quota event' "$STUB_DIR/err"

# A running hosted record reaches the unqualified close after its worktree
# disappears. The existing hosted provider fixture supplies that lifecycle.
hosted_watch() {
    lane_watch ORCH_LANE_HOST="$host" LANE_HOST_STUB_DIR="$remote" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" \
        LANE_HOST_STUB_HARNESS_STATE="$1"
}
hosted_setup() {
    world "$1" none future
    : >"$STUB_DIR/close.calls"
    printf 'bare\n' >"$STUB_DIR/close-mode"
    host="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
    remote="$STUB_DIR/remote"
    mkdir -p "$remote/srv/lane/issue-2" "$remote/srv/clone/tmp/lane-mail/issue-2"
    git -C "$remote/srv/clone" init -q
    git -C "$remote/srv/clone" config gc.auto 0
    git -C "$remote/srv/clone" config maintenance.auto false
    printf 'gitdir: /srv/clone/.git/worktrees/issue-2\n' >"$remote/srv/lane/issue-2/.git"
    printf '{"handoff":{"written_at":"t"}}\n' >"$remote/srv/clone/tmp/workflow-state-issue-2.json"
    jq -nc --arg host "$host" '{lanes:[{item:"issue-2",tracker:"linear",window:"gh-2",host:$host,
      mail_root:"/srv/lane/issue-2",harness:"claude",status:"running"}]}' >"$STUB_DIR/fleet.json"
    printf '[{"number":2,"headRefName":"issue-2","mergedAt":"1970-01-01T00:00:01Z"}]\n' >"$STUB_DIR/merged.json"
    hosted_watch running
    assert_eq "$RC" 0 'hosted quota fixture learns its clone before exit' "$STUB_DIR/err"
    rm -rf -- "$remote/srv/lane/issue-2"
}
hosted_setup indirect_hosted
while IFS='|' read -r phase now mode expected_calls exits event; do
    printf '%s\n' "$now" >"$STUB_DIR/now.epoch"
    printf '%s\n' "$mode" >"$STUB_DIR/close-mode"
    hosted_watch exited
    assert_eq "$RC:$(close_calls)" "0:$expected_calls" "$phase close attempts" "$STUB_DIR/err"
    assert_eq "$(awk '/^EVENT lane-exited gh-2$/ {n++} END {print n+0}' <<<"$OUT")" "$exits" \
        "$phase lane notification count" "$STUB_DIR/err"
    assert_contains "$OUT" "EVENT $event" "$phase available event" "$STUB_DIR/err"
done <<'ROWS'
initial|10000|bare|1|1|tracker-quota status=future
held|10001|bare|1|0|heartbeat
reset|20000|open|2|0|lane-closed issue-2
ROWS

REPEAT_SCRIPTS="$(mutant_scripts quota-close-repeat/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/quota-close-repeat/github"
ln -s "$REPO_ROOT/skills/linear" "$TMP_ROOT/quota-close-repeat/linear"
mutate_file "$REPEAT_SCRIPTS/oversee-watch" \
    '        asking_state="$(lane_row_set close-pending "$asking_state" "$1" "$2|$3")" ;;' \
    $'        asking_state="$(lane_row_set close-pending "$asking_state" "$1" "$2|$3")"\n        asking_state="$(lane_row_set "$2" "$asking_state" "$1" "$3")" ;;'
WATCH_BIN="$REPEAT_SCRIPTS/oversee-watch" hosted_setup close_repeat_control
WATCH_BIN="$REPEAT_SCRIPTS/oversee-watch" hosted_watch exited
WATCH_BIN="$REPEAT_SCRIPTS/oversee-watch" hosted_watch exited
control_rc=0
( FAIL=0; assert_not_contains "$OUT" 'EVENT lane-exited gh-2' 'reported lane stays quiet'; [[ "$FAIL" == 0 ]] ) \
    >"$STUB_DIR/control.log" || control_rc=$?
assert_eq "$control_rc" 1 'control rejects a deferred close that resets the notification latch' "$STUB_DIR/err"

# A recorded GitHub identity wins over a Linear-looking key during a hold.
lane_world held_github stopped
printf 'open\n' >"$STUB_DIR/close-mode"
printf 'statuses\n' >"$STUB_DIR/fail-target"
watch
jq '.lanes[0].tracker="github"' "$STUB_DIR/fleet.json" >"$STUB_DIR/next"
mv -- "$STUB_DIR/next" "$STUB_DIR/fleet.json"
lane_watch
assert_eq "$RC:$(close_calls)" '0:1' 'a held tracker does not suppress a recorded GitHub lane probe' "$STUB_DIR/err"

# Heartbeat can learn the hold after the long pass succeeded. Its receipt must
# stay in the parent, so the heartbeat prints it and the next process defers.
heartbeat_quota() {
    lane_world "$1" parked
    lane_merged
    printf 'open\n' >"$STUB_DIR/close-mode"
    lane_watch
    : >"$STUB_DIR/close.calls"
    printf 'heartbeat\n' >"$STUB_DIR/close-mode"
    lane_watch
}
heartbeat_quota heartbeat_indirect
assert_eq "$RC" 0 'heartbeat quota leaves the watch available' "$STUB_DIR/err"
assert_contains "$OUT" 'EVENT heartbeat' 'a heartbeat probe refusal still prints heartbeat' "$STUB_DIR/err"
assert_eq "$(awk '/^tracker-quota /' <<<"$OUT")" 'tracker-quota status=future reset=1970-01-01T05:33:20Z limit=unknown' \
    'heartbeat quota state remains in the parent' "$STUB_DIR/err"
before="$(close_calls)"
lane_watch
assert_eq "$RC:$(close_calls)" "0:$before" 'a heartbeat refusal persists for the next child' "$STUB_DIR/err"

PARENT_SCRIPTS="$(mutant_scripts quota-parent/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/quota-parent/github"
ln -s "$REPO_ROOT/skills/linear" "$TMP_ROOT/quota-parent/linear"
mutate_file "$PARENT_SCRIPTS/oversee-watch" \
    '  parked_merged_owed "${PW_SEEN[0]}" >"$WORK_DIR/parked-hands.out"' \
    '  ( parked_merged_owed "${PW_SEEN[0]}" ) >"$WORK_DIR/parked-hands.out"'
WATCH_BIN="$PARENT_SCRIPTS/oversee-watch" heartbeat_quota heartbeat_parent_control
control_rc=0
( FAIL=0; assert_eq "$(awk '/^tracker-quota /' <<<"$OUT")" 'tracker-quota status=future reset=1970-01-01T05:33:20Z limit=unknown' \
    'parent owns quota state'; [[ "$FAIL" == 0 ]] ) >"$STUB_DIR/control.log" || control_rc=$?
assert_eq "$control_rc" 1 'control rejects quota changes lost in a heartbeat subshell' "$STUB_DIR/err"

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
