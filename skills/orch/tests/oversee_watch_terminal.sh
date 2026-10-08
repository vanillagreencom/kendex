#!/usr/bin/env bash
# Surface: terminal close of parked/stopped records on each fleet interval.
# Inputs: oversee-watch, lane-close, their scripts/lib dependencies, and the
# watcher harness. Controls disable the offer and the refusal dedup separately.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/oversee-watch-harness.sh"

CLOSE_SCRIPTS="$(mutant_scripts terminal-close/orch lane-mail)" || exit 1
mkdir -p "$TMP_ROOT/terminal-close/linear/scripts"
cat > "$TMP_ROOT/terminal-close/linear/scripts/linear.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2" == 'issues get' ]] || exit 2
printf '%s\n' "$*" >> "$STUB_DIR/terminal-reads"
[[ ! -f "$STUB_DIR/tracker-failed" ]] || exit 9
state="$(cat "$STUB_DIR/terminal-state")"
jq -cn --arg state "$state" '{state_type:$state}'
EOF
chmod +x "$TMP_ROOT/terminal-close/linear/scripts/linear.sh"
cat > "$CLOSE_SCRIPTS/lane-mail" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$STUB_DIR/terminal-mail"
exit 2
EOF
rm -- "$CLOSE_SCRIPTS/lane-host"
cat > "$CLOSE_SCRIPTS/lane-host" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == close && -f "$STUB_DIR/refusal" ]]; then
  printf '%s\n' "$*" >> "$STUB_DIR/host.log"
  reason="$(cat "$STUB_DIR/refusal")"
  printf 'lane-host: %s item=%s\nlane-host: close-refused path=/srv/clone\n' "$reason" "$3" >&2
  exit 3
fi
exec "$REAL_LANE_HOST" "$@"
EOF
chmod +x "$CLOSE_SCRIPTS/lane-host"
FIXTURE_HOST="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"

terminal_case() { # NAME RECORD_STATUS TRACKER_STATE
  new_case "$1"
  mkdir -p "$STUB_DIR/fleet" "$STUB_DIR/remote"
  : > "$STUB_DIR/host.log"
  : > "$STUB_DIR/terminal-mail"
  printf '%s\n' "$3" > "$STUB_DIR/terminal-state"
  jq -cn --arg status "$2" --arg host "$FIXTURE_HOST" \
    '{triaged:[],lanes:[{item:"KEN-1",tracker:"linear",repo:"owner/repo",harness:"codex",window:null,
      host:$host,mail_root:"/srv/lane/ken-1",status:$status,
      parked:(if $status == "parked" then {pr:1,repo:"owner/repo"} else null end)}]}' \
    > "$STUB_DIR/fleet/workflow-state-oversee.json"
}
terminal_run() { # [WATCH_BIN]
  rc=0
  WATCH_BIN="${1:-$REPO_ROOT/skills/orch/scripts/oversee-watch}" run_watch \
    OVERSEE_WATCH_LANE_CLOSE="$CLOSE_SCRIPTS/lane-close" \
    OVERSEE_WATCH_WORKFLOW_STATE="$REPO_ROOT/skills/orch/scripts/workflow-state" \
    ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_DIR="$STUB_DIR/remote" \
    LANE_HOST_STUB_LOG="$STUB_DIR/host.log" -- --max-loops 1 \
    --state "$STUB_DIR/fleet/workflow-state-oversee.json" > "$STUB_DIR/out" 2> "$STUB_DIR/err" || rc=$?
}
terminal_result() {
  printf 'rc=%s status=%s close=%s mail=%s closed=%s refused=%s' "$rc" \
    "$(jq -r '.lanes[0].status' "$STUB_DIR/fleet/workflow-state-oversee.json")" \
    "$(awk '/^close --item KEN-1/ { n++ } END {print n+0}' "$STUB_DIR/host.log" 2>/dev/null || printf 0)" \
    "$(awk 'END {print NR+0}' "$STUB_DIR/terminal-mail" 2>/dev/null || printf 0)" \
    "$(awk '/^EVENT lane-closed KEN-1$/ {n++} END {print n+0}' "$STUB_DIR/out")" \
    "$(awk '/^EVENT lane-close-refused KEN-1$/ {n++} END {print n+0}' "$STUB_DIR/out")"
}

for status in parked stopped; do
  for state in completed canceled started; do
    terminal_case "${status}_${state}" "$status" "$state"
    # PR traffic makes this pass busy. Terminal cleanup must run before a
    # quiet heartbeat, with no dependency on a merged pull request.
    printf 'EVENT attention 9\n' > "$STUB_DIR/prwatch.out"
    terminal_run
    expected='rc=0 status=done close=1 mail=0 closed=1 refused=0'
    [[ "$state" != started ]] || expected="rc=0 status=$status close=0 mail=0 closed=0 refused=0"
    assert_eq "$(terminal_result)" "$expected" "$status/$state: the normal busy fleet pass closes only terminal items" "$STUB_DIR/err"
  done
done

# A real refused close leaves the record parked/stopped. Restarts keep the
# refusal, and a new tracker terminal state or lane record permits a new offer.
for status in parked stopped; do
  for reason in close-dirty close-unpushed; do
    terminal_case "${status}_${reason}" "$status" completed
    printf '%s\n' "$reason" > "$STUB_DIR/refusal"
    terminal_run
    assert_eq "$(terminal_result)" "rc=0 status=$status close=1 mail=0 closed=0 refused=1" \
      "$status/$reason: one refusal names the item and keeps its record" "$STUB_DIR/err"
    assert_contains "$(cat "$STUB_DIR/err")" "lane-host: $reason item=KEN-1" 'the provider refusal keeps its machine reason'
    terminal_run
    assert_eq "$(terminal_result)" "rc=0 status=$status close=1 mail=0 closed=0 refused=0" \
      "$status/$reason: a restarted pass makes no provider call for the unchanged refusal" "$STUB_DIR/err"
    printf 'canceled\n' > "$STUB_DIR/terminal-state"
    terminal_run
    assert_eq "$(terminal_result)" "rc=0 status=$status close=2 mail=0 closed=0 refused=1" \
      "$status/$reason: a changed terminal state permits one new close" "$STUB_DIR/err"
    jq '.lanes[0].launched_at="2026-10-08T00:00:00Z"' "$STUB_DIR/fleet/workflow-state-oversee.json" > "$STUB_DIR/fleet/next"
    mv -- "$STUB_DIR/fleet/next" "$STUB_DIR/fleet/workflow-state-oversee.json"
    terminal_run
    assert_eq "$(terminal_result)" "rc=0 status=$status close=3 mail=0 closed=0 refused=1" \
      "$status/$reason: a replaced lane record permits one new close" "$STUB_DIR/err"
  done
done

MUTANT="$(mutant_scripts no-terminal/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/no-terminal/github"
mutate_file "$MUTANT" '    check_terminal_lanes' '    false && check_terminal_lanes'
terminal_case no_terminal stopped completed
terminal_run "$MUTANT"
assert_eq "$(terminal_result)" 'rc=0 status=stopped close=0 mail=0 closed=0 refused=0' \
  'control: disabling the terminal offer leaves the terminal stopped record open' "$STUB_DIR/err"

MUTANT="$(mutant_scripts no-refusal-dedup/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/no-refusal-dedup/github"
mutate_file "$MUTANT" '    [[ "$prior" != "$key" ]] || continue' '    [[ "$prior" != "$key" ]] || :'
terminal_case no_refusal_dedup stopped canceled
printf 'close-unpushed\n' > "$STUB_DIR/refusal"
terminal_run "$MUTANT"
terminal_run "$MUTANT"
assert_eq "$(terminal_result)" 'rc=0 status=stopped close=2 mail=0 closed=0 refused=1' \
  'control: disabling refusal dedup retries and reports the same provider refusal' "$STUB_DIR/err"

terminal_case tracker_failed stopped completed
touch "$STUB_DIR/tracker-failed"
terminal_run
assert_eq "$(terminal_result)" 'rc=2 status=stopped close=0 mail=0 closed=0 refused=0' \
  'a tracker read failure keeps the record and closes no sandbox' "$STUB_DIR/err"
assert_contains "$(cat "$STUB_DIR/err")" 'oversee-watch: lane-close-failed item=KEN-1 exit=2' 'the existing failure line names the failed item'

for provider_exit in 4 9; do
  terminal_case "provider_failed_$provider_exit" stopped canceled
  LANE_HOST_STUB_CLOSE_STATUS="$provider_exit" terminal_run
  assert_eq "$(terminal_result)" 'rc=2 status=stopped close=1 mail=0 closed=0 refused=0' \
    'a provider failure stays a failure, including the status used for a reopened item' "$STUB_DIR/err"
  assert_contains "$(cat "$STUB_DIR/err")" "oversee-watch: lane-close-failed item=KEN-1 exit=$provider_exit" 'the failure line keeps the provider status'
done
MUTANT="$(mutant_scripts provider-four/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/provider-four/github"
mutate_file "$MUTANT" '&& grep -qxF "lane-close: item-open item=$1" <<<"$out"' '&& { true || grep -qxF "lane-close: item-open item=$1" <<<"$out"; }'
terminal_case provider_four_control stopped canceled
LANE_HOST_STUB_CLOSE_STATUS=4 terminal_run "$MUTANT"
assert_eq "$(terminal_result)" 'rc=0 status=stopped close=1 mail=0 closed=0 refused=0' \
  'control: without the item-open discriminator a provider failure becomes a quiet open-item result' "$STUB_DIR/err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
