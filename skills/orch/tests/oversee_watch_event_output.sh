#!/usr/bin/env bash
# Surface: oversee-watch event output and heartbeat output. The overseer's
# numbered log follow consumes these EVENT blocks and machine-read rows.
# Inputs: skills/orch/* skills/linear/scripts/lib/* skills/github/scripts/lib/*
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/oversee-watch-harness.sh"

DISARMED=$'owner/repo\t12\taaaa0000\tdisarmed\tauto-merge off'
THREADS=$'owner/repo\t34\tbbbb0000\tthreads-open\t1 unresolved'

# Linear's Verifying inventory and the reducer are the real row producers.
output_world() {
  new_case "$1"
  printf '{"lanes":[],"launch_queue":[]}\n' > "$STUB_DIR/fleet.json"
  jq -nr '"2026-10-02T00:00:01Z" | fromdateiso8601' > "$STUB_DIR/now.epoch"
  jq -nc --arg trigger "${2:-merge}" '[{id:"KEN-1",state:"Verifying",priority:2,
    description:("## Done when\n- [ ] Post-merge: Read health; Where: service; Why after merge: live release; Trigger: " + $trigger + "; Deadline: 2026-10-03T00:00:00Z")}]' \
    > "$STUB_DIR/tracker.out"
  printf '12\taaaa0000\tdisarmed\tauto-merge off\n' > "$STUB_DIR/prwatch.out"
  printf '1\n' > "$STUB_DIR/prwatch.rc"
  # An existing clear reducer read lets its first new key rise immediately.
  mkdir -p "$STATE_DIR"
  : > "$STATE_DIR/owner_repo__none"
}

output_pass() {
  RC=0
  run_watch -- --state "$STUB_DIR/fleet.json" --max-loops "${1:-1}" gh-1 \
    > "$STUB_DIR/out" 2> "$STUB_DIR/err" || RC=$?
  OUT="$(cat "$STUB_DIR/out")"
}

# Three event passes: a due box and disarmed key, a lane question, then a
# second PR's threads-open key. The baseline persists across watch processes.
event_sequence() {
  output_world "$1"
  output_pass
  cp "$STUB_DIR/out" "$STUB_DIR/log"
  printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-1.txt"
  output_pass
  cat "$STUB_DIR/out" >> "$STUB_DIR/log"
  printf '34\tbbbb0000\tthreads-open\t1 unresolved\n' >> "$STUB_DIR/prwatch.out"
  output_pass
  cat "$STUB_DIR/out" >> "$STUB_DIR/log"
}

event_contract() {
  assert_eq "$RC" 0 'event output completes' "$STUB_DIR/err"
  assert_eq "$(grep -c '^verifying KEN-1 ' "$STUB_DIR/log" || true)" 1 'a standing due row prints once'
  assert_eq "$(grep -cxF "$DISARMED" "$STUB_DIR/log" || true)" 1 'a standing reducer key prints once'
  assert_eq "$(awk -F'\t' '$1 == "owner/repo"' <<<"$OUT")" "$THREADS" 'the third event carries only the second PR new key'
}

event_sequence events
event_contract
assert_contains "$(cat "$STUB_DIR/log")" 'EVENT lane-asking gh-1' 'the second pass is an event block'

# A per-item read failure must retain saved deadlines until recovery. The
# overseer consumes the stderr cause and EVENT keys across long passes.
RELEASE_KEY=$'verifying-deadline\tKEN-3\tbox=1 trigger="release owner/releases v*" status=due deadline=2026-10-04T12:00:00Z'
unread_merge_sequence() {
  output_world "$1"
  jq '. + [{id:"KEN-2",state:"Verifying",priority:2,
    description:"## Done when\n- [ ] Post-merge: Read health; Where: service; Why after merge: live release; Trigger: release owner/repo v*; Deadline: +72h"},
    {id:"KEN-3",state:"Verifying",priority:2,
    description:"## Done when\n- [ ] Post-merge: Read release; Where: feed; Why after merge: live release; Trigger: release owner/releases v*; Deadline: +72h"}]' \
    "$STUB_DIR/tracker.out" > "$STUB_DIR/items.json"
  mv -- "$STUB_DIR/items.json" "$STUB_DIR/tracker.out"
  printf '%s\n' '[{"number":3,"headRefName":"ken-3","mergedAt":"2026-10-01T00:00:00Z"}]' > "$STUB_DIR/merged.json"
  printf '%s\n' '[{"tagName":"v1","publishedAt":"2026-10-01T12:00:00Z","isDraft":false}]' > "$STUB_DIR/releases.owner_releases.json"
  local phase
  for phase in first second recovered; do
    case "$phase" in
      second) touch "$STUB_DIR/release-fail" ;;
      recovered) rm -- "$STUB_DIR/release-fail" ;;
    esac
    output_pass
    printf '%s\n' "$RC" > "$STUB_DIR/$phase.rc"
    cp "$STUB_DIR/out" "$STUB_DIR/$phase.out"
    cp "$STUB_DIR/err" "$STUB_DIR/$phase.err"
    cp "$STATE_DIR/owner_repo__none" "$STUB_DIR/$phase.state"
  done
}
unread_merge_contract() {
  local phase events unread
  while IFS='|' read -r phase events unread; do
    assert_eq "$(cat "$STUB_DIR/$phase.rc")" 0 "$phase unread merge pass completes" "$STUB_DIR/$phase.err"
    assert_eq "$(grep -cx 'verifying-merge-unread issue=KEN-2' "$STUB_DIR/$phase.err" || true)" 1 \
      "$phase reports the unread item's cause once"
    assert_not_contains "$(cat "$STUB_DIR/$phase.out")" 'verifying-deadline KEN-2' "$phase never emits an unread deadline"
    assert_contains "$(cat "$STUB_DIR/$phase.state")" $'verifying-deadline\tKEN-1\tbox=1' "$phase commits the other due row"
    assert_eq "$(awk -F'\t' '$1 == "verifying-deadline" && $2 == "KEN-3"' "$STUB_DIR/$phase.state")" "$RELEASE_KEY" \
      "$phase retains the release item's saved deadline"
    assert_eq "$(grep -Ec '^verifying-release-unread .*issue=KEN-3 repo=owner/releases$' "$STUB_DIR/$phase.err" || true)" "$unread" \
      "$phase reports the release read cause only while unread"
    assert_eq "$(grep -c '^EVENT verifying-deadline KEN-3 ' "$STUB_DIR/$phase.out" || true)" "$events" \
      "$phase emits the release deadline only on the first readable pass"
    if [[ "$unread" == 1 ]]; then
      assert_eq "$(awk '/^verifying KEN-3 /' "$STUB_DIR/$phase.out")" '' 'an unread release item prints no judged row'
    fi
  done <<'ROWS'
first|1|0
second|0|1
recovered|0|0
ROWS
  assert_eq "$(grep -c '^EVENT verifying-deadline KEN-1 ' "$STUB_DIR/first.out" || true)" 1 'the other due item wakes on its first pass'
  assert_eq "$(grep -c '^EVENT verifying-deadline KEN-1 ' "$STUB_DIR/second.out" || true)" 0 'the second pass does not repeat the committed due event'
  assert_eq "$(grep -c '^EVENT verifying-deadline KEN-1 ' "$STUB_DIR/recovered.out" || true)" 0 'recovery does not repeat the other due event'
}
# A cleared key must rise again even though its row was printed earlier.
printf '0\n' > "$STUB_DIR/prwatch.rc"
output_pass
assert_contains "$OUT" 'EVENT heartbeat' 'a cleared reducer key permits a quiet heartbeat'
printf '1\n' > "$STUB_DIR/prwatch.rc"
output_pass
assert_eq "$(awk -F'\t' '$1 == "owner/repo"' <<<"$OUT")" "$DISARMED"$'\n'"$THREADS" 'recurring cleared keys print again'

unread_merge_sequence unread_merge
unread_merge_contract

# Waiting and completed rows use the existing deadline row. Completion wakes
# once, then another event carries none of its standing boxes=0 context.
completion_sequence() {
  output_world "$1"
  jq -nc '[{id:"KEN-1",state:"Verifying",priority:2,description:"## Done when\n- [x] branch proof"}]' > "$STUB_DIR/tracker.out"
  output_pass
  FIRST_RC=$RC
  cp "$STUB_DIR/out" "$STUB_DIR/first"
  printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-1.txt"
  output_pass
}
completion_contract() {
  assert_eq "$FIRST_RC:$RC" 0:0 'both completion reads finish' "$STUB_DIR/err"
  assert_eq "$(grep -cx 'verifying KEN-1 boxes=0' "$STUB_DIR/first" || true)" 1 'the first empty checklist read prints completion'
  assert_contains "$(cat "$STUB_DIR/first")" 'EVENT verifying-deadline KEN-1 boxes=0' 'completion wakes through the existing event kind'
  assert_not_contains "$OUT" 'verifying KEN-1' 'another event does not repeat empty completion'
  assert_contains "$(cat "$STATE_DIR/owner_repo__none")" $'verifying-deadline\tKEN-1\tboxes=0' 'completion reuses the deadline row'
}
completion_sequence no_boxes
completion_contract

output_world waiting 2026-10-02T12:00:00Z
output_pass
assert_not_contains "$OUT" 'verifying KEN-1' 'a waiting box has no due key for an event block'
assert_contains "$(cat "$STATE_DIR/owner_repo__none")" $'verifying-deadline\tKEN-1\t-' 'a valid no-due read reuses the deadline row'
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-1.txt"
output_pass
assert_not_contains "$OUT" 'verifying KEN-1' 'a standing no-due row stays out of other event blocks'

# oversee-report due reads owner reports through lane-mail events. An
# unreachable mailbox is a shipped failure after verification rows advance.
DELIVERY_ROWS=$'due|merge|due\ncompletion|merge|boxes=0'
delivery_sequence() {
  DELIVERY_PREFIX="$1"
  local kind trigger status failed_rc
  while IFS='|' read -r kind trigger status; do
    output_world "$DELIVERY_PREFIX-$kind" "$trigger"
    if [[ "$kind" == completion ]]; then
      jq -nc '[{id:"KEN-1",state:"Verifying",priority:2,description:"## Done when\n- [x] branch proof"}]' > "$STUB_DIR/tracker.out"
    fi
    printf '0\n' > "$STUB_DIR/prwatch.rc"
    cat > "$STUB_DIR/report-mail" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_DIR/report-mail.args"
printf 'lane-mail: host-unreachable=overseer\n' >&2
exit 2
EOF
    chmod +x "$STUB_DIR/report-mail"
    failed_rc=0
    run_watch ORCH_REPORT=on OVERSEE_REPORT_LANE_MAIL="$STUB_DIR/report-mail" \
      -- --state "$STUB_DIR/fleet.json" --max-loops 1 gh-1 \
      > "$STUB_DIR/failed.out" 2> "$STUB_DIR/failed.err" || failed_rc=$?
    cp "$STATE_DIR/owner_repo__none" "$STUB_DIR/failed.state"
    printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-1.txt"
    output_pass
    printf '%s:%s\n' "$failed_rc" "$RC" > "$STUB_DIR/delivery.rc"
  done <<<"$DELIVERY_ROWS"
}
delivery_contract() {
  local kind trigger status dir rows
  while IFS='|' read -r kind trigger status; do
    dir="$TMP_ROOT/cases/$DELIVERY_PREFIX-$kind"
    assert_eq "$(cat "$dir/report-mail.args")" 'events --item overseer' "$kind reaches the owner report mailbox read"
    assert_eq "$(cat "$dir/delivery.rc")" 2:0 "$kind preserves the failed pass and healthy retry statuses" "$dir/failed.err"
    rows="$(grep '^verifying KEN-1 ' "$dir/failed.out" || true)"
    assert_eq "$(grep -c '^verifying KEN-1 ' "$dir/failed.out" || true)" 1 "$kind delivers its selected row on the failed pass"
    if [[ "$status" == boxes=0 ]]; then
      assert_eq "$rows" 'verifying KEN-1 boxes=0' 'failed completion delivers the completion row'
    else
      assert_contains "$rows" " status=$status " "failed $kind delivers its judged verification row"
    fi
    assert_contains "$(cat "$dir/failed.state")" $'verifying-deadline\tKEN-1\t' "$kind retains its existing deadline row"
    assert_contains "$(cat "$dir/out")" 'EVENT lane-asking gh-1' "$kind retries under a healthy event block"
    assert_not_contains "$(cat "$dir/out")" 'verifying KEN-1' "$kind does not repeat the delivered row on retry"
  done <<<"$DELIVERY_ROWS"
}
delivery_sequence failed_delivery
delivery_contract

# check_refresh's GitHub run listing is a real operation after pr-watch.
# Its acknowledgement holds that operation until the consumer has inspected
# the ready block, rather than treating a sleep as evidence of ordering.
refresh_delivery_sequence() {
  local name="$1" interval="$2" subject="${WATCH_BIN:-$REPO_ROOT/skills/orch/scripts/oversee-watch}" child rc=0 early=no
  new_case "$name"
  printf '{"lanes":[],"launch_queue":[]}\n' > "$STUB_DIR/fleet.json"
  printf '12\taaaa0000\trefresh-ready\tCI passed\n' > "$STUB_DIR/prwatch.out"
  printf '1\n' > "$STUB_DIR/prwatch.rc"
  mkdir -p "$STUB_DIR/bin"
  cat > "$STUB_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == 'run list --repo owner/repo --workflow kendex-refresh.yml --status completed '* ]]; then
  : > "$STUB_DIR/held"
  while [[ ! -f "$STUB_DIR/release" ]]; do sleep 0.05; done
  : > "$STUB_DIR/finished"
fi
exec "$DELIVERY_GH" "$@"
EOF
  cat > "$STUB_DIR/bin/watch" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "$DELIVERY_TIMEOUT" 30 "$DELIVERY_WATCH" "$@"
EOF
  chmod +x "$STUB_DIR/bin/gh" "$STUB_DIR/bin/watch"
  (
    WATCH_BIN="$STUB_DIR/bin/watch" run_watch LINEAR_TEAM= \
      PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" ORCH_WATCH_MAIL_INTERVAL="$interval" \
      DELIVERY_GH="$TMP_ROOT/bin/gh" DELIVERY_WATCH="$subject" \
      DELIVERY_TIMEOUT="$(command -v timeout || command -v gtimeout)" \
      -- --state "$STUB_DIR/fleet.json" --max-loops 1 2> "$STUB_DIR/err" |
      while IFS= read -r line; do
        printf '%s\n' "$line" >> "$STUB_DIR/out"
        [[ "$line" != $'owner/repo\t12\taaaa0000\trefresh-ready\tCI passed' ]] || : > "$STUB_DIR/delivered"
      done
  ) &
  child=$!
  if await_marker "$STUB_DIR/held"; then
    if await_marker "$STUB_DIR/delivered"; then early=yes; fi
    REFRESH_EARLY="$early|$(test -e "$STUB_DIR/finished" && echo finished || echo held)"
  else
    REFRESH_EARLY=operation-unreached
  fi
  : > "$STUB_DIR/release"
  wait "$child" || rc=$?
  REFRESH_DELIVERY_RC="$rc"
}
refresh_delivery_contract() {
  assert_eq "$REFRESH_EARLY" 'yes|held' 'refresh-ready reaches the consumer before the later GitHub read finishes' "$STUB_DIR/err"
  assert_eq "$REFRESH_DELIVERY_RC" 0 'the released long pass completes' "$STUB_DIR/err"
  assert_eq "$(grep -c '^EVENT pr-watch ' "$STUB_DIR/out" || true)" 1 'the early event header is not repeated at completion'
  assert_eq "$(grep -c $'\trefresh-ready\t' "$STUB_DIR/out" || true)" 1 'the early refresh row is not repeated at completion'
  assert_eq "$(test -e "$STUB_DIR/finished" && echo finished || echo missing)" finished 'the later GitHub read completes after release'
}
for delivery_interval in 0 1; do
  refresh_delivery_sequence "refresh_delivery_$delivery_interval" "$delivery_interval"
  refresh_delivery_contract
done

scripts="$(mutant_scripts refresh-delivery-buffered/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/refresh-delivery-buffered/github"
ln -s "$REPO_ROOT/skills/linear" "$TMP_ROOT/refresh-delivery-buffered/linear"
mutate_file "$scripts/oversee-watch" '  long_output ready || die event-write-failed "" "path=$LONG_OUT"' '  :'
WATCH_BIN="$scripts/oversee-watch" refresh_delivery_sequence refresh_delivery_buffered_control 1
control_rc=0
( FAIL=0; refresh_delivery_contract; [[ "$FAIL" == 0 ]] ) > "$TMP_ROOT/refresh-delivery-buffered.log" || control_rc=$?
assert_eq "$control_rc" 1 'control: main buffering withholds refresh-ready until the held read finishes'

heartbeat_sequence() {
  output_world "$1"
  output_pass
  output_pass 3
}
heartbeat_contract() {
  assert_eq "$RC" 0 'quiet passes complete' "$STUB_DIR/err"
  assert_eq "$(sed -n '1p' <<<"$OUT")" 'EVENT heartbeat loops=3 interval=0s since=none' 'quiet passes reach heartbeat'
  assert_eq "$(grep -c '^verifying KEN-1 .* status=due ' <<<"$OUT" || true)" 1 'heartbeat retains the full verifying list'
  assert_eq "$(awk -F'\t' '$1 == "owner/repo"' <<<"$OUT")" "$DISARMED" 'heartbeat retains the full reducer output'
}
heartbeat_sequence heartbeat
heartbeat_contract

# Each output contract rejects restored repetition or missing heartbeat
# output in a disposable production copy outside the worktree.
while IFS='@' read -r name file old new contract; do
  scripts="$(mutant_scripts "output-$name/orch" "$file")" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/output-$name/github"
  ln -s "$REPO_ROOT/skills/linear" "$TMP_ROOT/output-$name/linear"
  mutate_file "$scripts/$file" "$old" "$new"
  WATCH_BIN="$scripts/oversee-watch" "${contract}_sequence" "control_$name"
  control_rc=0
  ( FAIL=0; "${contract}_contract"; [[ "$FAIL" == 0 ]] ) > "$TMP_ROOT/output-$name.log" || control_rc=$?
  assert_eq "$control_rc" 1 "control: $name reddens the output contract"
done <<'ROWS'
unread_merge@oversee-watch@[[ "$rc" -eq 1 || "$rc" -eq 2 ]]@[[ "$rc" -eq 1 ]]@unread_merge
unread_deadline_key@oversee-watch@[[ "$rc" -eq 2 && -n "$prior" ]]@[[ "$rc" -eq 2 && -n "$prior" && "$rc" -eq 1 ]]@unread_merge
verifying_repeat@oversee-watch@[[ -z "$VERIFYING_EVENT_LINES" ]] || printf '%s\n' "$VERIFYING_EVENT_LINES"@[[ -z "$VERIFYING_LINES" ]] || printf '%s\n' "$VERIFYING_LINES"@event
pr_repeat@lib/pr-watch-pass.sh@[[ -z "$event_out" ]] || printf '%s' "$event_out"@[[ -z "$PW_OUT" ]] || printf '%s\n' "$PW_OUT"@event
completion_repeat@oversee-watch@[[ "$prior" != "$key" ]] || continue@[[ "$prior" != "$key" || "$key" == boxes=0 ]] || continue@completion
failed_delivery@oversee-watch@if [[ "$PASS_EVENT" -eq 1 || "$PASS_FAILED" -eq 1 ]]; then@if [[ "$PASS_EVENT" -eq 1 && "$PASS_FAILED" -eq 0 ]]; then@delivery
verifying_heartbeat@oversee-watch@[[ -z "$VERIFYING_LINES" ]] || printf '%s\n' "$VERIFYING_LINES"@[[ -z "$VERIFYING_LINES" ]] || printf '%s\n' ""@heartbeat
pr_heartbeat@lib/pr-watch-pass.sh@[[ -z "$PW_OUT" ]] || printf '%s\n' "$PW_OUT"@[[ -z "$PW_OUT" ]] || printf '%s\n' ""@heartbeat
ROWS

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
