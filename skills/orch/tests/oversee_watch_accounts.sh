#!/usr/bin/env bash
# oversee-watch account events and the heartbeat's account roster: one
# `lanes list --json` reading per pass, an `account` event only when an
# account's compared status, its verdict against ORCH_LANE_MAX_PCT or its
# binding bucket's reset changed, and the same reading printed
# under a heartbeat. Every run is one pass (--max-loops 1), so the Nth run
# reads the stub's lanes.<N>.json.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# The grant cases run the real `lanes`, which no caller's account settings
# or account home may reach: a Codex or Copilot launch exports its home, and
# lane_dirs lists that account whatever LANES_HOME names.
unset ORCH_LANE_DIRS ORCH_LANE_ALIASES ORCH_LANE_EXCLUDE ORCH_LANE_RETIRE ORCH_LANE_MAX_PCT \
  ORCH_LANE_CLOUD_CREDIT_FLOOR ORCH_LANES_USAGE_TTL ORCH_LANE_COPILOT_POOL CODEX_HOME COPILOT_HOME

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

HEARTBEAT='EVENT heartbeat loops=1 interval=0s since=none'

# account ALIAS STATUS VERDICT HEADROOM RESETS — one `lanes list --json`
# record; `-` for HEADROOM or RESETS is the null an unmeasured account carries.
account() {
  jq -nc --arg a "$1" --arg s "$2" --arg v "$3" --arg h "$4" --arg r "$5" '{
    alias: $a, harness: "claude", config_dir: ("/home/u/." + $a), measured_through: "local",
    status: $s, verdict: $v,
    headroom_pct: (if $h == "-" then null else ($h | tonumber) end),
    binding_bucket: (if $r == "-" then null else "weekly" end),
    binding_resets_at: (if $r == "-" then null else $r end)}'
}

# accounts N RECORD... — the listing the Nth read answers.
accounts() {
  local n="$1"
  shift
  jq -sc . <<<"$(printf '%s\n' "$@")" > "$STUB_DIR/lanes.$n.json"
}

# watch_pass — one watch run; OUT, RC and ERR (a file) are what the assertions read.
RUN_SEQ=0
watch_pass() {
  ERR="$TMP_ROOT/run-$((++RUN_SEQ)).err"
  OUT="$(run_watch "$@" -- --max-loops 1 2>"$ERR")" && RC=0 || RC=$?
}

account_events() { grep -c '^EVENT account ' <<<"$OUT" || true; }

echo "=== oversee-watch accounts ==="

# The renewal the overseer never heard about: an account read `expired` on
# one pass and `ok` on the next. The unchanged account beside it says nothing.
new_case renewal
EXPIRED="$(account claude expired unmeasured - -)"
RENEWED="$(account claude ok room 80 2026-10-01T00:00:00Z)"
STEADY="$(account eclaude ok room 40 2026-10-02T00:00:00Z)"
accounts 1 "$EXPIRED" "$STEADY"
accounts 2 "$RENEWED" "$STEADY"
accounts 3 "$RENEWED" "$STEADY"
watch_pass
assert_eq "rc=$RC first=$(head -1 <<<"$OUT") events=$(account_events)" "rc=0 first=$HEARTBEAT events=0" \
  "the first reading of every account is its baseline and emits nothing" "$ERR"
assert_eq "$(grep '^account' <<<"$OUT")" "account-roster accounts=2
account claude config_dir=/home/u/.claude harness=claude through=local status=expired verdict=unmeasured headroom_pct=- binding_bucket=- binding_resets_at=-
account eclaude config_dir=/home/u/.eclaude harness=claude through=local status=ok verdict=room headroom_pct=40 binding_bucket=weekly binding_resets_at=2026-10-02T00:00:00Z" \
  "the heartbeat carries one roster line per account from the pass's own reading" "$ERR"
assert_eq "$(cat "$STUB_DIR/lanes.args")" "list --json" "the pass reads the accounts through lanes list --json" "$ERR"
watch_pass
assert_eq "rc=$RC events=$(account_events)" "rc=0 events=1" "the renewal pass emits exactly one account event" "$ERR"
assert_eq "$(grep '^EVENT account ' <<<"$OUT")" \
  "EVENT account claude config_dir=/home/u/.claude harness=claude through=local status=ok verdict=room headroom_pct=80 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z change=status,headroom was=expired/unmeasured" \
  "the event names the account, its headroom and reset, and what changed from what" "$ERR"
assert_not_contains "$OUT" "account-roster" "a pass that emits an event prints no roster with it" "$ERR"
watch_pass
assert_eq "rc=$RC first=$(head -1 <<<"$OUT") events=$(account_events)" "rc=0 first=$HEARTBEAT events=0" \
  "the pass after the renewal reads the same state and emits nothing" "$ERR"
assert_contains "$OUT" "account claude config_dir=/home/u/.claude harness=claude through=local status=ok verdict=room headroom_pct=80" \
  "the next heartbeat's roster carries the renewed reading" "$ERR"

# Headroom crossing the launch bound, as lanes judges it, in both directions.
new_case crossing
accounts 1 "$(account claude ok room 10 2026-10-01T00:00:00Z)"
accounts 2 "$(account claude ok walled 3 2026-10-01T00:00:00Z)"
accounts 3 "$(account claude ok room 30 2026-10-01T00:00:00Z)"
accounts 4 "$(account claude ok room 50 2026-10-01T00:00:00Z)"
watch_pass
watch_pass
assert_eq "$(grep '^EVENT account ' <<<"$OUT")" \
  "EVENT account claude config_dir=/home/u/.claude harness=claude through=local status=ok verdict=walled headroom_pct=3 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z change=headroom was=ok/room" \
  "headroom falling across the bound is an account event" "$ERR"
watch_pass
assert_eq "$(grep '^EVENT account ' <<<"$OUT")" \
  "EVENT account claude config_dir=/home/u/.claude harness=claude through=local status=ok verdict=room headroom_pct=30 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z change=headroom was=ok/walled" \
  "headroom climbing back across the bound is an account event" "$ERR"
watch_pass
assert_eq "rc=$RC first=$(head -1 <<<"$OUT") events=$(account_events)" "rc=0 first=$HEARTBEAT events=0" \
  "headroom moving within the same side of the bound emits nothing" "$ERR"

# A binding bucket reset: news once the reset has passed and the reading has
# moved off it, never while a cached figure still names it, and never when a
# reset time moves while it is still ahead.
new_case reset
# Fixed UTC epoch seconds, so no `date -d` (GNU only) runs on a BSD host:
# BEFORE is one hour before the first reading's reset below, AFTER one hour
# after it.
BEFORE=1790247600
AFTER=1790254800
accounts 1 "$(account claude ok walled 2 2026-09-24T12:00:00Z)"
accounts 2 "$(account claude ok walled 2 2026-09-24T12:30:00Z)"
accounts 3 "$(account claude ok walled 2 2026-09-24T12:30:00Z)"
accounts 4 "$(account claude ok room 20 2026-09-24T12:30:00Z)"
accounts 5 "$(account claude ok room 20 2026-10-01T12:00:00Z)"
printf '%s\n' "$BEFORE" > "$STUB_DIR/now.epoch"
watch_pass
watch_pass
assert_eq "rc=$RC first=$(head -1 <<<"$OUT") events=$(account_events)" "rc=0 first=$HEARTBEAT events=0" \
  "a reset time that moves while still ahead is no reset" "$ERR"
printf '%s\n' "$AFTER" > "$STUB_DIR/now.epoch"
watch_pass
assert_eq "rc=$RC first=$(head -1 <<<"$OUT") events=$(account_events)" "rc=0 first=$HEARTBEAT events=0" \
  "a passed reset still named by the reading waits for a fresh one" "$ERR"
watch_pass
assert_eq "$(grep '^EVENT account ' <<<"$OUT")" \
  "EVENT account claude config_dir=/home/u/.claude harness=claude through=local status=ok verdict=room headroom_pct=20 binding_bucket=weekly binding_resets_at=2026-09-24T12:30:00Z change=headroom was=ok/walled" \
  "a verdict change beside a passed reset the reading still names reports the headroom and no reset" "$ERR"
watch_pass
assert_eq "$(grep '^EVENT account ' <<<"$OUT")" \
  "EVENT account claude config_dir=/home/u/.claude harness=claude through=local status=ok verdict=room headroom_pct=20 binding_bucket=weekly binding_resets_at=2026-10-01T12:00:00Z change=reset was=ok/room" \
  "the reading moving off a passed reset is an account event naming the reset" "$ERR"

# An account the listing drops for a pass keeps its baseline row, so its
# return is judged against the reading before it went missing.
new_case dropped
accounts 1 "$(account claude ok walled 2 2026-10-01T00:00:00Z)"
accounts 2 "$(account eclaude ok room 40 2026-10-02T00:00:00Z)"
accounts 3 "$(account claude ok room 30 2026-10-01T00:00:00Z)"
watch_pass
watch_pass
assert_eq "rc=$RC first=$(head -1 <<<"$OUT") events=$(account_events)" "rc=0 first=$HEARTBEAT events=0" \
  "a pass that does not name the account emits nothing about it" "$ERR"
watch_pass
assert_eq "$(grep '^EVENT account ' <<<"$OUT")" \
  "EVENT account claude config_dir=/home/u/.claude harness=claude through=local status=ok verdict=room headroom_pct=30 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z change=headroom was=ok/walled" \
  "the account's return is judged against its reading before the gap" "$ERR"

# Each row names a sequence, the provider reading, its event tail, and the
# saved account row. Unmeasured gaps preserve that row, including when their
# status changes. Expired and retired readings remain operator news.
ACCOUNT_SEQUENCES=(
  "quiet;ok room 80 2099-01-01T00:00:00Z;-;ok|room|2099-01-01T00:00:00Z|-"
  "quiet;unreachable unmeasured - -;-;ok|room|2099-01-01T00:00:00Z|-"
  "quiet;held unmeasured - -;-;ok|room|2099-01-01T00:00:00Z|-"
  "quiet;ok room 80 2099-01-01T00:00:00Z;-;ok|room|2099-01-01T00:00:00Z|-"
  "crossing;ok walled 2 2099-01-01T00:00:00Z;-;ok|walled|2099-01-01T00:00:00Z|-"
  "crossing;unreachable unmeasured - -;-;ok|walled|2099-01-01T00:00:00Z|-"
  "crossing;ok room 80 2099-01-01T00:00:00Z;change=headroom was=ok/walled;ok|room|2099-01-01T00:00:00Z|-"
  "expired;ok room 80 2099-01-01T00:00:00Z;-;ok|room|2099-01-01T00:00:00Z|-"
  "expired;unreachable unmeasured - -;-;ok|room|2099-01-01T00:00:00Z|-"
  "expired;expired unmeasured - -;change=status,headroom was=ok/room;expired|unmeasured|-|expired"
  "expired;held unmeasured - -;-;expired|unmeasured|-|expired"
  "expired;ok room 80 2099-01-01T00:00:00Z;change=status,headroom was=expired/unmeasured;ok|room|2099-01-01T00:00:00Z|expired"
  "expired;expired unmeasured - -;change=status,headroom was=ok/room;expired|unmeasured|-|expired"
  "expired;expired unmeasured - -;-;expired|unmeasured|-|expired"
  "retired;ok room 80 2099-01-01T00:00:00Z;-;ok|room|2099-01-01T00:00:00Z|-"
  "retired;unreachable unmeasured - -;-;ok|room|2099-01-01T00:00:00Z|-"
  "retired;retired unmeasured - -;change=status,headroom was=ok/room;retired|unmeasured|-|retired"
  "retired;held unmeasured - -;-;retired|unmeasured|-|retired"
  "retired;ok room 80 2099-01-01T00:00:00Z;change=status,headroom was=retired/unmeasured;ok|room|2099-01-01T00:00:00Z|retired"
  "retired;retired unmeasured - -;change=status,headroom was=ok/room;retired|unmeasured|-|retired"
  "retired;retired unmeasured - -;-;retired|unmeasured|-|retired"
  "no_baseline;unreachable unmeasured - -;-;-"
  "no_baseline;held unmeasured - -;-;-"
  "no_baseline;ok room 80 2099-01-01T00:00:00Z;-;ok|room|2099-01-01T00:00:00Z|-"
  "retired_baseline;retired unmeasured - -;-;retired|unmeasured|-|retired"
  "retired_baseline;ok room 80 2099-01-01T00:00:00Z;change=status,headroom was=retired/unmeasured;ok|room|2099-01-01T00:00:00Z|retired"
)

# account_sequence_run CASE NAME: the same observations run against the
# production script or a disposable control. The expected rows come from
# the table, never from the script's own comparison.
account_sequence_run() {
  local selected="$1" n=0 row name reading expected saved event count
  new_case "$2"
  SEQUENCE_WANT=""
  for row in "${ACCOUNT_SEQUENCES[@]}"; do
    IFS=';' read -r name reading expected saved <<<"$row"
    [[ "$name" == "$selected" ]] || continue
    # shellcheck disable=SC2086 # four fixture words, one per account field
    accounts "$((++n))" "$(jq -c '.measured_through = "host"' <<<"$(account claude $reading)")"
    count=1; [[ "$expected" != - ]] || count=0
    SEQUENCE_WANT+="$n: rc=0 events=$count $expected row=$saved"$'\n'
  done
  SEQUENCE_GOT=""
  SEQUENCE_EVENTS=0
  n=0
  for row in "${ACCOUNT_SEQUENCES[@]}"; do
    IFS=';' read -r name reading expected saved <<<"$row"
    [[ "$name" == "$selected" ]] || continue
    n=$((n + 1))
    watch_pass
    count="$(account_events)"
    SEQUENCE_EVENTS=$((SEQUENCE_EVENTS + count))
    event="$(grep '^EVENT account ' <<<"$OUT" | sed 's/.* change=/change=/' || true)"
    if [[ -z "$event" ]]; then
      [[ "$(head -1 <<<"$OUT")" == "$HEARTBEAT" ]] && event=- || event=no-heartbeat
    fi
    saved="$(awk -F'\t' '$1 == "account" { print $3 }' "$STATE_DIR/owner_repo__none")"
    SEQUENCE_GOT+="$n: rc=$RC events=$count $event row=${saved:--}"$'\n'
  done
}

for sequence in quiet crossing expired retired no_baseline retired_baseline; do
  account_sequence_run "$sequence" "$sequence"
  assert_eq "$SEQUENCE_GOT" "$SEQUENCE_WANT" \
    "$sequence: account events and saved comparisons follow measured readings and terminal statuses" "$ERR"
done

# Control: restore the old comparison. The unreachable, held and recovered
# readings all become news, so the quiet sequence rejects that behavior.
FLAP_MUTANT="$(mutant_scripts flap-mutant/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/flap-mutant/github"
mutate_file "$FLAP_MUTANT" '[[ "$status" == expired || "$status" == retired ]] || continue' \
  '[[ "$status" == expired || "$status" != "$unmeasured" ]] || continue'
WATCH_BIN="$FLAP_MUTANT" account_sequence_run quiet quiet_control
assert_eq "$SEQUENCE_EVENTS" "3" "control: the old rule emits three events across the unmeasured gap" "$ERR"
assert_not_contains "$SEQUENCE_GOT" "$SEQUENCE_WANT" "control: the quiet sequence rejects the old rule" "$ERR"

# Control: also suppress a measured room reading. The crossing sequence
# must reject the missing measured change, not just suppress all events.
MEASURED_MUTANT="$(mutant_scripts measured-mutant/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/measured-mutant/github"
mutate_file "$MEASURED_MUTANT" 'if [[ "$verdict" == unmeasured ]]; then' \
  'if [[ "$verdict" == unmeasured || "$verdict" == room ]]; then'
WATCH_BIN="$MEASURED_MUTANT" account_sequence_run crossing crossing_control
assert_eq "$SEQUENCE_EVENTS" "0" "control: dropping measured room suppresses the crossing event" "$ERR"
assert_not_contains "$SEQUENCE_GOT" "$SEQUENCE_WANT" "control: the crossing sequence rejects the missing change" "$ERR"

# Controls: suppress each operator-action status. Its sequence must reject
# the lost event and unchanged row, including a later recurrence.
for terminal in expired retired; do
  TERMINAL_MUTANT="$(mutant_scripts "$terminal-mutant/orch" oversee-watch)/oversee-watch" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/$terminal-mutant/github"
  mutate_file "$TERMINAL_MUTANT" "\"\$status\" == $terminal" "\"\$status\" == never-$terminal"
  WATCH_BIN="$TERMINAL_MUTANT" account_sequence_run "$terminal" "${terminal}_control"
  assert_eq "$SEQUENCE_EVENTS" "0" "control: suppressing $terminal loses the terminal events" "$ERR"
  assert_not_contains "$SEQUENCE_GOT" "$SEQUENCE_WANT" "control: the $terminal sequence rejects the lost events" "$ERR"
done

# A running lane's grant reaching ORCH_LANE_CLOUD_CREDIT_FLOOR: the real
# `lanes list` reads a provider harness=pi grant row, and the watch reports
# the pass it walls. GRANT_FLOOR names a set floor, empty for the default.
GRANT_LANES="$REPO_ROOT/skills/orch/scripts/lanes"
GRANT_HOST="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
GRANT_EXPIRES="$(jq -nr 'now + 5 * 86400 | todateiso8601')" || exit 1
grant_pass() { # REMAINING
  local floor=()
  [[ -z "$GRANT_FLOOR" ]] || floor=("ORCH_LANE_CLOUD_CREDIT_FLOOR=$GRANT_FLOOR")
  printf 'account=%s\tharness=pi\tcredit-limit=200\tcredit-spent=0\tcredit-remaining=%s\tcredit-expires=%s\n' \
    "$GRANT_HOME/.eclaude" "$1" "$GRANT_EXPIRES" > "$STUB_DIR/accounts.tsv"
  watch_pass OVERSEE_WATCH_LANES="$GRANT_LANES" LANES_HOME="$GRANT_HOME" ORCH_LANE_HOST="$GRANT_HOST" \
    LANE_HOST_STUB_ACCOUNTS="$STUB_DIR/accounts.tsv" LANE_HOST_STUB_LOG="$STUB_DIR/provider.log" \
    ORCH_LANES_USAGE_TTL=0 ${floor[@]+"${floor[@]}"}
}
grant_event() { # HEADROOM
  printf 'EVENT account eclaude config_dir=%s harness=pi through=host status=ok verdict=walled headroom_pct=%s binding_bucket=credits binding_resets_at=- change=headroom was=ok/room' \
    "$GRANT_HOME/.eclaude" "$1"
}

new_case grant_floor
GRANT_HOME="$STUB_DIR/home"; mkdir -p "$GRANT_HOME"
GRANT_FLOOR=""
grant_pass 150
assert_eq "rc=$RC events=$(account_events)" "rc=0 events=0" "a grant's first reading is its baseline" "$ERR"
grant_pass 9
assert_eq "rc=$RC $(grep '^EVENT account ' <<<"$OUT")" \
  "rc=0 $(grant_event 4)" \
  "a grant falling to the default floor is one account event" "$ERR"
grant_pass 8
assert_eq "rc=$RC events=$(account_events)" "rc=0 events=0" "a grant still under the floor emits nothing" "$ERR"

new_case grant_set_floor
GRANT_HOME="$STUB_DIR/home"; mkdir -p "$GRANT_HOME"
GRANT_FLOOR=160
grant_pass 170
grant_pass 150
assert_eq "rc=$RC $(grep '^EVENT account ' <<<"$OUT")" \
  "rc=0 $(grant_event 75)" \
  "the set floor, not zero, decides the pass the grant walls" "$ERR"

# A baseline reset no date can read settles no reset, is noted once, and the
# status and headroom changes beside it are still reported.
new_case reset_unparsed
accounts 1 "$(account claude ok walled 2 not-a-time)"
accounts 2 "$(account claude ok room 30 2026-10-01T00:00:00Z)"
watch_pass
watch_pass
assert_eq "$(grep '^EVENT account ' <<<"$OUT")" \
  "EVENT account claude config_dir=/home/u/.claude harness=claude through=local status=ok verdict=room headroom_pct=30 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z change=headroom was=ok/walled" \
  "an unparseable baseline reset still reports the headroom change and no reset" "$ERR"
assert_eq "$(grep -c "^oversee-watch: account-reset-unparsed account=claude|local|/home/u/.claude binding_resets_at=not-a-time$" "$ERR" || true)" "1" \
  "the unparseable baseline reset is noted once, naming the account and the stamp" "$ERR"

# Two accounts can share an alias: config dirs in different parents with one
# basename, or an alias setting naming two dirs. Only config_dir tells their
# lines apart.
new_case shared_alias
FIRST="$(account claude ok room 80 2026-10-01T00:00:00Z)"
SECOND="$(jq -c '.config_dir = "/srv/u/.claude"' <<<"$(account claude ok room 70 2026-10-01T00:00:00Z)")"
SECOND_WALLED="$(jq -c '.config_dir = "/srv/u/.claude"' <<<"$(account claude ok walled 2 2026-10-01T00:00:00Z)")"
accounts 1 "$FIRST" "$SECOND"
accounts 2 "$FIRST" "$SECOND_WALLED"
watch_pass
assert_eq "$(grep '^account ' <<<"$OUT")" "account claude config_dir=/home/u/.claude harness=claude through=local status=ok verdict=room headroom_pct=80 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z
account claude config_dir=/srv/u/.claude harness=claude through=local status=ok verdict=room headroom_pct=70 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z" \
  "two accounts sharing an alias are two roster lines told apart by config_dir" "$ERR"
watch_pass
assert_eq "$(grep '^EVENT account ' <<<"$OUT")" \
  "EVENT account claude config_dir=/srv/u/.claude harness=claude through=local status=ok verdict=walled headroom_pct=2 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z change=headroom was=ok/room" \
  "the event names the config dir whose account changed" "$ERR"

# Any other event opens the block, and the roster stays with the heartbeat.
new_case other_event
accounts 1 "$(account claude ok room 80 2026-10-01T00:00:00Z)"
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
ERR="$TMP_ROOT/other-event.err"
OUT="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$ERR")" && RC=0 || RC=$?
assert_eq "rc=$RC first=$(head -1 <<<"$OUT")" "rc=0 first=EVENT lane-asking gh-2" \
  "a lane-asking pass reports its event" "$ERR"
assert_not_contains "$OUT" "account-roster" "a pass with another event prints no roster with it" "$ERR"

# A reading that failed is said, never printed as a fleet with no accounts.
new_case unread
printf '1\n' > "$STUB_DIR/lanes.rc"
watch_pass
assert_eq "rc=$RC first=$(head -1 <<<"$OUT") roster=$(grep '^account' <<<"$OUT" || true)" \
  "rc=0 first=$HEARTBEAT roster=account-roster unread" \
  "a failed read puts account-roster unread in the heartbeat" "$ERR"
assert_eq "$(grep -c "^oversee-watch: account-unread path=$TMP_ROOT/bin/lanes-stub.sh exit=1$" "$ERR" || true)" "1" \
  "the failed read is noted with the reader and its exit" "$ERR"

# A listing that exits 0 with nothing on stdout failed to render; it is not a
# fleet with no accounts.
new_case empty_listing
: > "$STUB_DIR/lanes.1.json"
watch_pass
assert_eq "rc=$RC first=$(head -1 <<<"$OUT") roster=$(grep '^account' <<<"$OUT" || true)" \
  "rc=0 first=$HEARTBEAT roster=account-roster unread" \
  "an empty listing at exit 0 puts account-roster unread in the heartbeat" "$ERR"
assert_eq "$(grep -c "^oversee-watch: account-unread path=$TMP_ROOT/bin/lanes-stub.sh parse=failed$" "$ERR" || true)" "1" \
  "the empty listing is noted as a parse failure" "$ERR"

# A record missing the status or the verdict is not an account the watch can
# compare, and the read is refused rather than reading it as unchanged.
for field in status verdict; do
  new_case "missing_$field"
  jq -c --arg f "$field" '[del(.[$f])]' <<<"$(account claude ok room 80 2026-10-01T00:00:00Z)" > "$STUB_DIR/lanes.1.json"
  watch_pass
  assert_eq "rc=$RC first=$(head -1 <<<"$OUT") roster=$(grep '^account' <<<"$OUT" || true)" \
    "rc=0 first=$HEARTBEAT roster=account-roster unread" \
    "a record with no $field puts account-roster unread in the heartbeat" "$ERR"
  assert_eq "$(grep -c "^oversee-watch: account-unread path=$TMP_ROOT/bin/lanes-stub.sh parse=failed$" "$ERR" || true)" "1" \
    "a record with no $field is noted once as a parse failure" "$ERR"
done

# A reader that overruns its ceiling is noted with the seconds it was given.
# The copy shortens the ceiling so the row need not wait out the real one.
if command -v timeout >/dev/null 2>&1; then
  shortened_ceiling_watch
  new_case ceiling
  printf '3\n' > "$STUB_DIR/lanes.sleep"
  WATCH_BIN="$CEILING_WATCH" watch_pass
  assert_eq "rc=$RC first=$(head -1 <<<"$OUT") roster=$(grep '^account' <<<"$OUT" || true)" \
    "rc=0 first=$HEARTBEAT roster=account-roster unread" \
    "a read past its ceiling puts account-roster unread in the heartbeat" "$ERR"
  assert_eq "$(grep -c "^oversee-watch: account-unread path=$TMP_ROOT/bin/lanes-stub.sh seconds=1$" "$ERR" || true)" "1" \
    "the overrun is noted with the seconds the ceiling allowed" "$ERR"
else
  printf '  skip  a read past its ceiling: this host has no timeout to bound one with\n'
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
