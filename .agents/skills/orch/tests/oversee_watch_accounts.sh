#!/usr/bin/env bash
# oversee-watch account events and the heartbeat's account roster: one
# `lanes list --json` reading per pass, an `account` event only when an
# account's status, its verdict against ORCH_LANE_MAX_PCT or its binding
# bucket's reset changed against the baseline, and the same reading printed
# under a heartbeat. Every run is one pass (--max-loops 1), so the Nth run
# reads the stub's lanes.<N>.json.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

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

# pass — one watch run; OUT, RC and ERR (a file) are what the assertions read.
RUN_SEQ=0
pass() {
  ERR="$TMP_ROOT/run-$((++RUN_SEQ)).err"
  OUT="$(run_watch "$@" -- --max-loops 1 2>"$ERR")" && RC=0 || RC=$?
}

account_events() { grep -c '^EVENT account ' <<<"$OUT" || true; }

epoch() { "$OVERSEE_TEST_REAL_DATE" -u -d "$1" +%s; }

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
pass
assert_eq "rc=$RC first=$(head -1 <<<"$OUT") events=$(account_events)" "rc=0 first=$HEARTBEAT events=0" \
  "the first reading of every account is its baseline and emits nothing" "$ERR"
assert_eq "$(grep '^account' <<<"$OUT")" "account-roster accounts=2
account claude harness=claude through=local status=expired verdict=unmeasured headroom_pct=- binding_bucket=- binding_resets_at=-
account eclaude harness=claude through=local status=ok verdict=room headroom_pct=40 binding_bucket=weekly binding_resets_at=2026-10-02T00:00:00Z" \
  "the heartbeat carries one roster line per account from the pass's own reading" "$ERR"
assert_eq "$(cat "$STUB_DIR/lanes.args")" "list --json" "the pass reads the accounts through lanes list --json" "$ERR"
pass
assert_eq "rc=$RC events=$(account_events)" "rc=0 events=1" "the renewal pass emits exactly one account event" "$ERR"
assert_eq "$(grep '^EVENT account ' <<<"$OUT")" \
  "EVENT account claude harness=claude through=local status=ok verdict=room headroom_pct=80 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z change=status,headroom was=expired/unmeasured" \
  "the event names the account, its headroom and reset, and what changed from what" "$ERR"
assert_not_contains "$OUT" "account-roster" "a pass that emits an event prints no roster with it" "$ERR"
pass
assert_eq "rc=$RC first=$(head -1 <<<"$OUT") events=$(account_events)" "rc=0 first=$HEARTBEAT events=0" \
  "the pass after the renewal reads the same state and emits nothing" "$ERR"
assert_contains "$OUT" "account claude harness=claude through=local status=ok verdict=room headroom_pct=80" \
  "the next heartbeat's roster carries the renewed reading" "$ERR"

# Headroom crossing the launch bound, as lanes judges it, in both directions.
new_case crossing
accounts 1 "$(account claude ok room 10 2026-10-01T00:00:00Z)"
accounts 2 "$(account claude ok walled 3 2026-10-01T00:00:00Z)"
accounts 3 "$(account claude ok room 30 2026-10-01T00:00:00Z)"
accounts 4 "$(account claude ok room 50 2026-10-01T00:00:00Z)"
pass
pass
assert_eq "$(grep '^EVENT account ' <<<"$OUT")" \
  "EVENT account claude harness=claude through=local status=ok verdict=walled headroom_pct=3 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z change=headroom was=ok/room" \
  "headroom falling across the bound is an account event" "$ERR"
pass
assert_eq "$(grep '^EVENT account ' <<<"$OUT")" \
  "EVENT account claude harness=claude through=local status=ok verdict=room headroom_pct=30 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z change=headroom was=ok/walled" \
  "headroom climbing back across the bound is an account event" "$ERR"
pass
assert_eq "rc=$RC first=$(head -1 <<<"$OUT") events=$(account_events)" "rc=0 first=$HEARTBEAT events=0" \
  "headroom moving within the same side of the bound emits nothing" "$ERR"

# A binding bucket reset: news once the reset has passed and the reading has
# moved off it, never while a cached figure still names it, and never when a
# reset time moves while it is still ahead.
new_case reset
BEFORE="$(epoch 2026-09-24T11:00:00Z)"
AFTER="$(epoch 2026-09-24T13:00:00Z)"
accounts 1 "$(account claude ok walled 2 2026-09-24T12:00:00Z)"
accounts 2 "$(account claude ok walled 2 2026-09-24T12:30:00Z)"
accounts 3 "$(account claude ok walled 2 2026-09-24T12:30:00Z)"
accounts 4 "$(account claude ok room 20 2026-09-24T12:30:00Z)"
accounts 5 "$(account claude ok room 20 2026-10-01T12:00:00Z)"
printf '%s\n' "$BEFORE" > "$STUB_DIR/now.epoch"
pass
pass
assert_eq "rc=$RC first=$(head -1 <<<"$OUT") events=$(account_events)" "rc=0 first=$HEARTBEAT events=0" \
  "a reset time that moves while still ahead is no reset" "$ERR"
printf '%s\n' "$AFTER" > "$STUB_DIR/now.epoch"
pass
assert_eq "rc=$RC first=$(head -1 <<<"$OUT") events=$(account_events)" "rc=0 first=$HEARTBEAT events=0" \
  "a passed reset still named by the reading waits for a fresh one" "$ERR"
pass
assert_eq "$(grep '^EVENT account ' <<<"$OUT")" \
  "EVENT account claude harness=claude through=local status=ok verdict=room headroom_pct=20 binding_bucket=weekly binding_resets_at=2026-09-24T12:30:00Z change=headroom was=ok/walled" \
  "a verdict change beside a passed reset the reading still names reports the headroom and no reset" "$ERR"
pass
assert_eq "$(grep '^EVENT account ' <<<"$OUT")" \
  "EVENT account claude harness=claude through=local status=ok verdict=room headroom_pct=20 binding_bucket=weekly binding_resets_at=2026-10-01T12:00:00Z change=reset was=ok/room" \
  "the reading moving off a passed reset is an account event naming the reset" "$ERR"

# An account the listing drops for a pass keeps its baseline row, so its
# return is judged against the reading before it went missing.
new_case dropped
accounts 1 "$(account claude ok walled 2 2026-10-01T00:00:00Z)"
accounts 2 "$(account eclaude ok room 40 2026-10-02T00:00:00Z)"
accounts 3 "$(account claude ok room 30 2026-10-01T00:00:00Z)"
pass
pass
assert_eq "rc=$RC first=$(head -1 <<<"$OUT") events=$(account_events)" "rc=0 first=$HEARTBEAT events=0" \
  "a pass that does not name the account emits nothing about it" "$ERR"
pass
assert_eq "$(grep '^EVENT account ' <<<"$OUT")" \
  "EVENT account claude harness=claude through=local status=ok verdict=room headroom_pct=30 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z change=headroom was=ok/walled" \
  "the account's return is judged against its reading before the gap" "$ERR"

# A baseline reset no date can read settles no reset, is noted once, and the
# status and headroom changes beside it are still reported.
new_case reset_unparsed
accounts 1 "$(account claude ok walled 2 not-a-time)"
accounts 2 "$(account claude ok room 30 2026-10-01T00:00:00Z)"
pass
pass
assert_eq "$(grep '^EVENT account ' <<<"$OUT")" \
  "EVENT account claude harness=claude through=local status=ok verdict=room headroom_pct=30 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z change=headroom was=ok/walled" \
  "an unparseable baseline reset still reports the headroom change and no reset" "$ERR"
assert_eq "$(grep -c "^oversee-watch: account-reset-unparsed account=claude|local|/home/u/.claude binding_resets_at=not-a-time$" "$ERR" || true)" "1" \
  "the unparseable baseline reset is noted once, naming the account and the stamp" "$ERR"

# Claude's usage endpoint writes a reset with fractional seconds and +00:00,
# which the BSD date arm cannot read: the watch keeps whole-second UTC with a
# Z, so the reset is judged and printed the same way on every host.
new_case reset_fractional
accounts 1 "$(account claude ok walled 2 2026-09-24T12:00:00.123456+00:00)"
accounts 2 "$(account claude ok walled 2 2026-10-01T12:00:00.654321+00:00)"
printf '%s\n' "$BEFORE" > "$STUB_DIR/now.epoch"
pass
printf '%s\n' "$AFTER" > "$STUB_DIR/now.epoch"
pass
assert_eq "$(grep '^EVENT account ' <<<"$OUT")" \
  "EVENT account claude harness=claude through=local status=ok verdict=walled headroom_pct=2 binding_bucket=weekly binding_resets_at=2026-10-01T12:00:00Z change=reset was=ok/walled" \
  "a fractional +00:00 reset is judged and printed as whole-second UTC" "$ERR"
assert_not_contains "$(cat "$ERR")" "account-reset-unparsed" "the fractional reset parses" "$ERR"

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
pass
assert_eq "rc=$RC first=$(head -1 <<<"$OUT") roster=$(grep '^account' <<<"$OUT" || true)" \
  "rc=0 first=$HEARTBEAT roster=account-roster unread" \
  "a failed read puts account-roster unread in the heartbeat" "$ERR"
assert_eq "$(grep -c "^oversee-watch: account-unread path=$TMP_ROOT/bin/lanes-stub.sh exit=1$" "$ERR" || true)" "1" \
  "the failed read is noted with the reader and its exit" "$ERR"

# A listing that exits 0 with nothing on stdout failed to render; it is not a
# fleet with no accounts.
new_case empty_listing
: > "$STUB_DIR/lanes.1.json"
pass
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
  pass
  assert_eq "rc=$RC first=$(head -1 <<<"$OUT") roster=$(grep '^account' <<<"$OUT" || true)" \
    "rc=0 first=$HEARTBEAT roster=account-roster unread" \
    "a record with no $field puts account-roster unread in the heartbeat" "$ERR"
  assert_eq "$(grep -c "^oversee-watch: account-unread path=$TMP_ROOT/bin/lanes-stub.sh parse=failed$" "$ERR" || true)" "1" \
    "a record with no $field is noted once as a parse failure" "$ERR"
done

# A reader that overruns its ceiling is noted with the seconds it was given.
# The copy shortens the ceiling so the row need not wait out the real one.
if command -v timeout >/dev/null 2>&1; then
  CEILING_DIR="$TMP_ROOT/ceiling"
  mkdir -p "$CEILING_DIR/orch"
  cp -R "$REPO_ROOT/skills/orch/scripts" "$CEILING_DIR/orch/scripts"
  ln -s "$REPO_ROOT/skills/github" "$CEILING_DIR/github"
  sed 's/^READ_CEILING=60$/READ_CEILING=1/' \
    "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$CEILING_DIR/orch/scripts/oversee-watch"
  chmod +x "$CEILING_DIR/orch/scripts/oversee-watch"
  assert_eq "$(cmp -s "$CEILING_DIR/orch/scripts/oversee-watch" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
    "differs" "the shortened-ceiling copy really differs from the watch"
  new_case ceiling
  printf '3\n' > "$STUB_DIR/lanes.sleep"
  WATCH_BIN="$CEILING_DIR/orch/scripts/oversee-watch" pass
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
