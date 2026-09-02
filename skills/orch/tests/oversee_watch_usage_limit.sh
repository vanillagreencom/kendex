#!/usr/bin/env bash
# Regression tests for what oversee-watch reads off a spent-account banner:
# whether a limit banner on a lane's screen is the account speaking now, and
# what the reset clause on that line resolves to. The rest of the pane side —
# window absence, shell exits, prompts, idle returns — is oversee_watch_lanes.sh;
# the GitHub side is oversee_watch.sh. All build their sandbox from
# lib/oversee-watch-harness.sh.
set -euo pipefail

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"


# Every fixture banner below states a clock, and the event now carries the UTC
# instant that clock resolves to. Cases that assert the whole event line pin
# both ends of that resolution: RESET_NOW as the moment the pane is read
# (`now.epoch`, the harness's clock stub) and TZ=UTC as the zone a banner
# naming none is read in, so the assertion holds on a runner in any zone.
RESET_NOW=1788364800                            # 2026-09-02T16:00:00Z
RESET_2100=' resets=2026-09-02T21:00:00Z'       # what `resets 21:00` resolves to
pin_now() { printf '%s' "$RESET_NOW" > "$STUB_DIR/now.epoch"; }

echo "=== oversee-watch usage limits ==="

# --- 1. usage-limit: the harness is alive, the account is spent -------------
new_case usage_limit
pin_now
{
  printf '⏺ Working through the queue.\n'
  printf "You've hit your usage limit \xc2\xb7 resets 21:00\n"
  printf 'Run /usage-credits to raise it\n'
  printf '\xe2\x9d\xaf\xc2\xa0\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3f"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "usage-limit exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2$RESET_2100" \
  "a limit banner under a live harness is the event on ONE pass" "$err"
assert_contains "$out" "usage limit" "the pane tail follows the usage-limit event" "$err"

# Codex words it its own way; one regex covers both harnesses
new_case usage_limit_codex
printf 'codex\n' > "$STUB_DIR/cmd-gh-2.txt"
printf 'Usage limit reached. Increase your limits to continue.\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3f2"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2" "the codex limit banner fires too" "$err"

# A spent account outranks a prompt left on the same screen
new_case usage_limit_before_question
pin_now
{
  printf "You've hit your session limit \xc2\xb7 resets 21:00\n"
  printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3g"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2$RESET_2100" \
  "a limit banner above a stale prompt is usage-limit, not question" "$err"
assert_not_contains "$out" "EVENT lane-asking" "lane-asking never preempts a spent account" "$err"

# The banner and the prompt are read on the same liveness answer, so a lane
# wrapped in a shell still gets its banner seen
new_case usage_limit_wrapped_shell
printf 'fish\n' > "$STUB_DIR/cmd-gh-2.txt"
printf '2747883\n' > "$STUB_DIR/kids-9002.txt"
printf "You've hit your weekly limit \xc2\xb7 resets Sunday\n" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3f3"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2" \
  "a wrapped lane's limit banner is still the event" "$err"

# An account that has since reset leaves its old banner on the visible screen.
# A user turn below it says the harness took another turn, so the banner is
# scrollback and the lane needs nothing.
new_case usage_limit_stale_banner
{
  printf '⏺ Working through the queue.\n'
  printf "You've hit your usage limit \xc2\xb7 resets 21:00\n"
  printf '❯ pick the round back up\n'
  printf '⏺ Teammate @dev-ken832-r3 finished\n'
  printf '\xe2\x9d\xaf\xc2\xa0\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3f4"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=none" \
  "a banner the lane has since worked past is not the event" "$err"
assert_not_contains "$out" "EVENT usage-limit" \
  "a stale banner above a later user turn never fires" "$err"

# The composer is the last marker line on the screen, and it is never a turn:
# if it counted as one the whole pane would be sliced away and usage-limit
# would go silent for every lane. Claude Code draws it as `❯` + U+00A0, which
# these fixtures spell in bytes and then verify, so a fixture that degrades
# into an ASCII space fails here instead of passing quietly.
new_case usage_limit_above_empty_composer
pin_now
{
  printf '⏺ Working through the queue.\n'
  printf "You've hit your usage limit \xc2\xb7 resets 21:00\n"
  printf '\xe2\x9d\xaf\xc2\xa0\n'
} > "$STUB_DIR/pane-gh-2.txt"
assert_eq "$(grep -c "$(printf '\xc2\xa0')" "$STUB_DIR/pane-gh-2.txt")" "1" \
  "the composer fixture carries U+00A0, not an ASCII space"
err="$TMP_ROOT/e3f6"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2$RESET_2100" \
  "the empty composer is not a turn, so a banner above it is still reported" "$err"

# ...and neither is a composer holding an unsent draft
new_case usage_limit_above_composer_draft
pin_now
{
  printf '⏺ Working through the queue.\n'
  printf "You've hit your usage limit \xc2\xb7 resets 21:00\n"
  printf '\xe2\x9d\xaf\xc2\xa0take the next round\n'
} > "$STUB_DIR/pane-gh-2.txt"
assert_eq "$(grep -c "$(printf '\xc2\xa0')" "$STUB_DIR/pane-gh-2.txt")" "1" \
  "the draft-composer fixture carries U+00A0, not an ASCII space"
err="$TMP_ROOT/e3f7"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2$RESET_2100" \
  "an unsent draft in the composer is not a turn either" "$err"

# Codex draws the composer with the SAME `› ` and text a submitted turn uses,
# so only its position separates them. Its placeholder must not read as a turn.
new_case usage_limit_above_codex_composer
printf 'codex\n' > "$STUB_DIR/cmd-gh-2.txt"
{
  printf '\xe2\x80\xba pick the round back up\n'
  printf '\xe2\x80\xa2 Ran 3 commands\n'
  printf 'Usage limit reached. Increase your limits to continue.\n'
  printf '\xe2\x80\xba Ask Codex to do anything\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3f8"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2" \
  "a codex banner below the last turn is reported, the composer notwithstanding" "$err"

# A Codex dialog screen draws no composer, and Codex does NOT indent the row
# it has selected: that row keeps the marker at column 0, measured on a live
# model picker, so the screen still ends in a live-input marker line and the
# turn above it is the boundary. Only the unselected rows indent.
new_case usage_limit_codex_dialog_stale_banner
printf 'codex\n' > "$STUB_DIR/cmd-gh-2.txt"
{
  printf 'Usage limit reached. Increase your limits to continue.\n'
  printf '\xe2\x80\xba pick the round back up\n'
  printf '\xe2\x80\xa2 Ran 3 commands\n'
  printf '  Select Model and Effort\n'
  printf '\xe2\x80\xba 1. gpt-5.6-sol (current)  Latest frontier agentic coding model.\n'
  printf '  2. gpt-5.6-terra          Balanced agentic coding model for everyday work.\n'
  printf '  Press enter to confirm or esc to go back\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3fd"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" \
  "a codex dialog row is live input, so the banner above the turn stays scrollback" "$err"
assert_not_contains "$out" "EVENT usage-limit" \
  "the codex dialog row never resurrects a stale banner" "$err"

# The near-miss control. Every fresh Codex prints a benign reset OFFER, and
# loosening USAGE_LIMIT_RE toward a bare `usage limit` would turn the startup
# screen of every Codex lane into a spent-account event.
new_case usage_limit_codex_reset_offer
printf 'codex\n' > "$STUB_DIR/cmd-gh-2.txt"
cat "$CODEX_PANES/codex-composer-idle.txt" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3fg"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_contains "$(cat "$STUB_DIR/pane-gh-2.txt")" "You have 1 usage limit reset available" \
  "the fixture really carries the reset offer, so the control is not vacuous" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=none" \
  "a codex startup screen is no event at all" "$err"
assert_not_contains "$out" "EVENT usage-limit" \
  "an offered reset is credit to spend, never a spent account" "$err"

# ...and its control: the banner below the turn on the same dialog screen
new_case usage_limit_codex_dialog_live_banner
printf 'codex\n' > "$STUB_DIR/cmd-gh-2.txt"
{
  printf '\xe2\x80\xba pick the round back up\n'
  printf '\xe2\x80\xa2 Ran 3 commands\n'
  printf 'Usage limit reached. Increase your limits to continue.\n'
  printf '  Select Model and Effort\n'
  printf '\xe2\x80\xba 1. gpt-5.6-sol (current)  Latest frontier agentic coding model.\n'
  printf '  2. gpt-5.6-terra          Balanced agentic coding model for everyday work.\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3fe"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2" \
  "a banner below the turn on a codex dialog screen is still the event" "$err"

# ...and the must-fail control: the same codex screen with the banner ABOVE
# the turn is scrollback, which the composer must not resurrect
new_case usage_limit_codex_stale_banner
printf 'codex\n' > "$STUB_DIR/cmd-gh-2.txt"
{
  printf 'Usage limit reached. Increase your limits to continue.\n'
  printf '\xe2\x80\xba pick the round back up\n'
  printf '\xe2\x80\xa2 Ran 3 commands\n'
  printf '\xe2\x80\xba Ask Codex to do anything\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3f9"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=none" \
  "a codex banner the lane has worked past is not the event" "$err"
assert_not_contains "$out" "EVENT usage-limit" \
  "the codex composer never resurrects a stale banner" "$err"

# The must-fail control for the case above: the same screen with the banner
# BELOW the turn — the account is spent right now. It carries the permission
# line a real screen draws under the composer, so the composer is not the last
# line of the capture: this is where the Claude signature decides the boundary
# rather than the last-line fallback, and a signature that stops matching
# drops the banner out of the slice here.
new_case usage_limit_after_turn
pin_now
{
  printf '❯ pick the round back up\n'
  printf '⏺ Working through the queue.\n'
  printf "You've hit your usage limit \xc2\xb7 resets 21:00\n"
  printf '\xe2\x9d\xaf\xc2\xa0\n'
  printf '  bypass permissions on\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3f5"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2$RESET_2100" \
  "a banner below the last user turn is the event" "$err"

# An input line the composer rule does not recognize must not become the
# boundary itself: that empties the slice and makes usage-limit a silent
# no-op. A marker line that is the last line of the capture falls back to the
# previous marker, so the unrecognized case fails toward a stale banner.
new_case usage_limit_unrecognized_composer
pin_now
{
  printf '❯ pick the round back up\n'
  printf '⏺ Working through the queue.\n'
  printf "You've hit your usage limit \xc2\xb7 resets 21:00\n"
  printf '❯ \n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3f6"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2$RESET_2100" \
  "an unrecognized last input line never swallows the screen" "$err"

# A realistic transcript, with the E2-lead lines a real screen carries
# between the banner and the composer. The marker must be an alternation of
# literals: as a bracket expression it degrades to a set of BYTES on any awk
# without multibyte support, every one of these lines then reads as a marker,
# the boundary lands below the banner and usage-limit goes silent. A short
# fixture cannot see that; this one can.
new_case usage_limit_realistic_transcript
pin_now
{
  printf '❯ pick the round back up\n'
  printf '⏺ Ran 3 shell commands\n'
  printf "You've hit your usage limit \xc2\xb7 resets 21:00\n"
  printf '⏺ Teammate @dev-ken832-r3 finished\n'
  printf '⎿  Wrote 6 lines to tmp/roundD.json\n'
  printf '↓ 58.7k tokens\n'
  printf '─────────────────────────────\n'
  printf '\xe2\x9d\xaf\xc2\xa0\n'
} > "$STUB_DIR/pane-gh-2.txt"
# Run it in BOTH locales. The byte-set degradation only happens on an awk
# without multibyte support, so under the runner's own UTF-8 locale gawk
# behaves identically either way and the case cannot fail on the defect it
# names. Under LC_ALL=C it can, and does. The UTF-8 invocation stays as the
# control that the case passes for the right reason rather than by locale.
err="$TMP_ROOT/e3fc"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2$RESET_2100" \
  "transcript lines between the banner and the composer are not markers" "$err"
err="$TMP_ROOT/e3fc2"
out="$(run_watch TZ=UTC LC_ALL=C LANG=C -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2$RESET_2100" \
  "...and under a byte-oriented locale, where a marker class would degrade" "$err"

# A dialog screen draws no composer at all: Claude replaces it with the
# selection rows, which it indents, so the last marker line there is the user
# turn itself. Read as a composer, the boundary would slip back to the turn
# before it and reopen the window over the very scrollback this slice exists
# to exclude — a stale banner would mask a live question.
new_case usage_limit_stale_banner_over_question
{
  printf "You've hit your usage limit \xc2\xb7 resets 21:00\n"
  printf '❯ pick the round back up\n'
  printf '⏺ Teammate @dev-ken832-r3 finished\n'
  printf 'Do you want to proceed?\n'
  printf '   ❯ 1. Yes\n     2. No\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3fa"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" \
  "a stale banner never masks the live question on a dialog screen" "$err"
assert_not_contains "$out" "EVENT usage-limit" \
  "the banner above the turn stays scrollback when no composer is drawn" "$err"

# ...and its control: on the same dialog screen, a banner BELOW the turn is
# the account spent right now, and it still outranks the question
new_case usage_limit_live_banner_over_question
pin_now
{
  printf '❯ pick the round back up\n'
  printf '⏺ Teammate @dev-ken832-r3 finished\n'
  printf "You've hit your usage limit \xc2\xb7 resets 21:00\n"
  printf 'Do you want to proceed?\n'
  printf '   ❯ 1. Yes\n     2. No\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3fb"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2$RESET_2100" \
  "a banner below the turn on a dialog screen is still the event" "$err"

# The must-fail control: a lane with no banner at all
new_case usage_limit_healthy
printf '⏺ All green, nothing blocking.\n\xe2\x9d\xaf\xc2\xa0\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3h"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=none" \
  "a lane with no limit banner reaches the heartbeat" "$err"
assert_not_contains "$out" "EVENT usage-limit" "a healthy lane never fires usage-limit" "$err"

# The account is the actionable part: a live claim maps the window to it
new_case usage_limit_claim
printf '900 %%3\n' > "$STUB_DIR/panes.txt"
printf '900 %%3\n' > "$STUB_DIR/pane-key-gh-2.txt"
mkdir -p "$STATE_DIR/claims"
# Read first by glob order, so anything matching on the window NAME alone
# would answer with one of these instead of the pane actually captured: one
# claim from another live server, one from THIS server on another pane —
# window names repeat across sessions as well as across servers.
printf '%s\t%%3\t/home/me/.otherclaude\tgh-2\t2026-08-16T00:00:00Z\n' "$$" > "$STATE_DIR/claims/a.claim"
printf '900\t%%9\t/home/me/.thirdclaude\tgh-2\t2026-08-16T00:00:00Z\n' > "$STATE_DIR/claims/b.claim"
printf '900\t%%3\t/home/me/.eclaude\tgh-2\t2026-08-16T00:00:00Z\n' > "$STATE_DIR/claims/c.claim"
printf "You've hit your weekly limit\n" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3i"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2 /home/me/.eclaude" \
  "the event names the config dir the lane was claimed on" "$err"
assert_not_contains "$out" "otherclaude" \
  "a same-named window on another tmux server never answers for this lane" "$err"
assert_not_contains "$out" "thirdclaude" \
  "a same-named window on another pane of this server never answers either" "$err"

# ... and a claim whose pane is gone is pruned rather than reported
new_case usage_limit_claim_stale
printf '900 %%9\n' > "$STUB_DIR/panes.txt"
printf '900 %%3\n' > "$STUB_DIR/pane-key-gh-2.txt"
mkdir -p "$STATE_DIR/claims"
printf '900\t%%3\t/home/me/.eclaude\tgh-2\t2026-08-16T00:00:00Z\n' > "$STATE_DIR/claims/a.claim"
printf "You've hit your weekly limit\n" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3j"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2" \
  "a claim whose pane is gone names no account" "$err"
assert_eq "$(ls -1 "$STATE_DIR/claims" | wc -l | tr -d '[:space:]')" "0" \
  "a dead claim is pruned on read, not left to accumulate" "$err"

# --- 2. the reset time the banner states ------------------------------------
# Claude Code formats its reset through `Intl` in en-US, lowercases the
# meridiem and drops the space before it, so a bare clock inside a day reads
# `9:50am` and the IANA zone follows in parentheses. Every case here pins
# `now.epoch` and the runner's zone, per the note beside RESET_NOW above.
new_case usage_limit_reset_live
printf '%s' "$RESET_NOW" > "$STUB_DIR/now.epoch"   # 2026-09-02T16:00:00Z, 50m early
{
  printf '⏺ Working through the queue.\n'
  printf "You've hit your usage limit \xc2\xb7 resets 9:50am (America/Los_Angeles)\n"
  printf '\xe2\x9d\xaf\xc2\xa0\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3k"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2 resets=2026-09-02T16:50:00Z" \
  "the event carries the reset the banner states, resolved to UTC" "$err"

# ...and the case the issue was filed on: the same screen read after the wall
# lifted. The banner is the pane remembering a window that has since reopened,
# so the lane wants a nudge, not another wait — a distinct event, because the
# supervisor cannot tell the two apart from the banner text alone.
new_case usage_limit_reset_passed
printf '1788369300' > "$STUB_DIR/now.epoch"   # 2026-09-02T17:15:00Z, 25m late
{
  printf '⏺ Working through the queue.\n'
  printf "You've hit your usage limit \xc2\xb7 resets 9:50am (America/Los_Angeles)\n"
  printf '\xe2\x9d\xaf\xc2\xa0\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3l"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit-passed gh-2 resets=2026-09-02T16:50:00Z" \
  "a reset already behind us is its own event" "$err"
assert_not_contains "$out" "EVENT usage-limit " \
  "a spent wall never reports as a standing one" "$err"

# A bare clock names no day, and the two directions are separated by one
# session window (USAGE_RESET_PAST_TOLERANCE, 5h). Inside it, the clock is the
# reset that just passed: `resets 11pm` read at 01:00 is two hours gone.
new_case usage_limit_reset_within_window
printf '1788397200' > "$STUB_DIR/now.epoch"   # 2026-09-03T01:00:00Z
printf "You've hit your usage limit \xc2\xb7 resets 11pm\n" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3m"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit-passed gh-2 resets=2026-09-02T23:00:00Z" \
  "a clock inside the window behind us is the reset that just passed" "$err"

# ...and beyond it the SAME clock reads forward, as the occurrence still to
# come. Reading it backwards there is the fail-open this rule exists to close:
# it would report a wall still standing as a lifted one, and oversee.md then
# has the overseer nudge a lane whose account is still spent.
new_case usage_limit_reset_beyond_window
printf '1788343200' > "$STUB_DIR/now.epoch"   # 2026-09-02T10:00:00Z, 11h past 11pm
printf "You've hit your usage limit \xc2\xb7 resets 11pm\n" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3n"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2 resets=2026-09-02T23:00:00Z" \
  "a clock further back than one window reads forward, not backwards" "$err"

# ...and when today's occurrence is itself behind the floor, the winner is
# TOMORROW's: the walk runs forward, it does not stop at the current day
new_case usage_limit_reset_forward_day
printf '%s' "$RESET_NOW" > "$STUB_DIR/now.epoch"   # 2026-09-02T16:00:00Z, 10h past 6am
printf "You've hit your usage limit \xc2\xb7 resets 6am\n" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3u"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2 resets=2026-09-03T06:00:00Z" \
  "the next day's occurrence wins when today's is behind the floor" "$err"

# The candidate days are enumerated off local NOON, so a DST boundary between
# now and the reset cannot skip a day. Read at Mar 13 23:30 PST, the night the
# US springs forward, `resets 3am` is Mar 14 03:00 PDT — 2.5 hours ahead.
# Walking by 86400 from `now` lands on Mar 15 and never offers Mar 14, which
# reported a reset 20 hours BEHIND and a lifted wall.
new_case usage_limit_reset_dst
printf '1805009400' > "$STUB_DIR/now.epoch"   # 2027-03-14T07:30:00Z
printf "You've hit your usage limit \xc2\xb7 resets 3am (America/Los_Angeles)\n" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3v"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2 resets=2027-03-14T10:00:00Z" \
  "the day after a spring-forward night is still a candidate" "$err"

# The two hours the 12-hour clock spells backwards. Claude Code renders
# midnight and noon through Intl en-US h12 as `12 AM` and `12 PM`, so both
# reach the pane, and each is a 12-hour error on the branch that picks the
# event name.
new_case usage_limit_reset_midnight
printf '%s' "$RESET_NOW" > "$STUB_DIR/now.epoch"   # 2026-09-02T16:00:00Z
printf "You've hit your usage limit \xc2\xb7 resets 12am\n" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3w"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2 resets=2026-09-03T00:00:00Z" \
  "12am is midnight, not noon" "$err"

new_case usage_limit_reset_noon
printf '%s' "$RESET_NOW" > "$STUB_DIR/now.epoch"   # 2026-09-02T16:00:00Z, 4h past noon
printf "You've hit your usage limit \xc2\xb7 resets 12pm\n" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3x"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit-passed gh-2 resets=2026-09-02T12:00:00Z" \
  "12pm is noon, not midnight and not hour 24" "$err"

# A zone the host cannot resolve is dropped whole. TZ falls back to UTC for a
# name it does not know, silently and with a zero status, and the same banner
# would then resolve seven hours out — enough to report a standing wall as a
# lifted one, with nothing in the event saying which answer it gave.
new_case usage_limit_reset_zone_unresolvable
printf '%s' "$RESET_NOW" > "$STUB_DIR/now.epoch"
printf "You've hit your usage limit \xc2\xb7 resets 9:50am (Bogus/Zone)\n" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3y"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2" \
  "a zone the host cannot resolve leaves the event without a time" "$err"
assert_not_contains "$out" "resets=" \
  "a reset is never computed in a zone silently replaced by UTC" "$err"

# Past 24 hours out — a weekly window — Claude switches to a dated form and
# prints the year only when it is not the current one
new_case usage_limit_reset_dated
printf '%s' "$RESET_NOW" > "$STUB_DIR/now.epoch"   # 2026-09-02T16:00:00Z
printf "You've hit your weekly limit \xc2\xb7 resets Sep 6, 4pm\n" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3o"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2 resets=2026-09-06T16:00:00Z" \
  "a dated banner is read as a date, not as a clock today" "$err"

new_case usage_limit_reset_dated_year
printf '%s' "$RESET_NOW" > "$STUB_DIR/now.epoch"   # 2026-09-02T16:00:00Z
printf "You've hit your weekly limit \xc2\xb7 resets Oct 7, 2027, 11:32am\n" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3p"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2 resets=2027-10-07T11:32:00Z" \
  "the year the dated form carries wins over the current one" "$err"

# The weekly copy this repository records as the CLI's own, at
# pi-extensions/pi-claude-bridge/tests/unit-usage-limit.mjs. It names a weekday
# and a clock but no date, so the walk runs to the next matching weekday. Read
# on a Friday, `Thursday 4am` is six days out — far enough that a walk ignoring
# the weekday would answer tomorrow instead.
new_case usage_limit_reset_weekday
printf '1788537600' > "$STUB_DIR/now.epoch"   # 2026-09-04T16:00:00Z, a Friday
printf "You've hit your weekly limit \xc2\xb7 resets Thursday 4am\n" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3z"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2 resets=2026-09-10T04:00:00Z" \
  "a weekday and a clock resolve to that weekday's next occurrence" "$err"

# The `at` wording and the 24-hour clock the sibling parser accepts
# (pi-extensions/pi-agents-tmux/extensions/subagent/rate-limit-reset.ts); the
# 24-hour form alone is what every `resets 21:00` fixture above now exercises.
new_case usage_limit_reset_at_wording
printf '%s' "$RESET_NOW" > "$STUB_DIR/now.epoch"   # 2026-09-02T16:00:00Z, 4h past noon
printf "You've hit your usage limit \xc2\xb7 reset at 12:00\n" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3aa"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit-passed gh-2 resets=2026-09-02T12:00:00Z" \
  "the optional at and the singular reset read the same" "$err"

# Codex. Both halves are literals recovered from the 0.152.1 binary — the
# banner `You've hit your usage limit.` and the trigger ` Try again at `, which
# formats through chrono's `%-I:%M %p` — but no byte-exact pane under
# fixtures/oversee-watch/ holds a spent Codex account, so their composition on
# one line is not measured the way the composer shapes there are. The assertion
# is therefore on the trigger and the clock, which are.
new_case usage_limit_reset_codex
printf 'codex\n' > "$STUB_DIR/cmd-gh-2.txt"
printf '%s' "$RESET_NOW" > "$STUB_DIR/now.epoch"   # 2026-09-02T16:00:00Z
printf "You've hit your usage limit. Try again at 4:30 PM\n" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3q"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2 resets=2026-09-02T16:30:00Z" \
  "codex's own trigger and upper-case meridiem read the same" "$err"

# Every label this parser writes and reads back is numeric, and the month and
# weekday names on the banner are matched in the shell rather than handed to
# `date`. On a host whose LC_TIME is not English a `%b` label written by `date`
# and read back by `date` resolves to nothing, and the event would silently
# lose its time on every shape at once. All three tails answer the same under
# that host.
new_case usage_limit_reset_non_english_host
printf '%s' "$RESET_NOW" > "$STUB_DIR/now.epoch"   # 2026-09-02T16:00:00Z
: > "$STUB_DIR/date-non-english"
printf "You've hit your weekly limit \xc2\xb7 resets Sep 6, 4pm\n" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3ab"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2 resets=2026-09-06T16:00:00Z" \
  "a dated banner resolves on a host with a non-English LC_TIME" "$err"
printf "You've hit your usage limit \xc2\xb7 resets 9:50am (America/Los_Angeles)\n" > "$STUB_DIR/pane-gh-2.txt"
rm -f "$STUB_DIR/pane-gh-2.calls"
err="$TMP_ROOT/e3ac"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2 resets=2026-09-02T16:50:00Z" \
  "...and so does a bare clock, whose candidate days are numeric labels" "$err"

# The must-fail control. Claude's fast-mode cooldown states its reset as a
# duration, which names no instant: the event keeps its old shape rather than
# carrying a guessed one, and stays `usage-limit` — a time nobody could read
# is never evidence the wall has lifted.
new_case usage_limit_reset_unreadable
printf '%s' "$RESET_NOW" > "$STUB_DIR/now.epoch"
{
  printf '⏺ Working through the queue.\n'
  printf "You've hit your fast limit \xc2\xb7 resets in 5m\n"
  printf '\xe2\x9d\xaf\xc2\xa0\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3r"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2" \
  "a reset stated as a duration leaves the event without a time" "$err"
assert_not_contains "$out" "resets=" "no time is invented for a banner that states none" "$err"
assert_not_contains "$out" "usage-limit-passed" \
  "an unreadable reset is never read as a spent one" "$err"

# A `resets` clause the account is not speaking is not the account's reset:
# only the banner line is read, so a transcript line below it cannot supply
# the time the event carries
new_case usage_limit_reset_off_banner
printf '%s' "$RESET_NOW" > "$STUB_DIR/now.epoch"
{
  printf "You've hit your usage limit \xc2\xb7 resets in 5m\n"
  printf '⏺ Wrote a note saying the deploy resets 9:50am (America/Los_Angeles)\n'
  printf '\xe2\x9d\xaf\xc2\xa0\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3s"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2" \
  "a reset clause on a transcript line is not the account speaking" "$err"

# The config dir and the reset ride the same line, and `resets=` is keyed so
# the optional field before it cannot shift what the time is read as
new_case usage_limit_reset_with_claim
printf '%s' "$RESET_NOW" > "$STUB_DIR/now.epoch"
printf '900 %%3\n' > "$STUB_DIR/panes.txt"
printf '900 %%3\n' > "$STUB_DIR/pane-key-gh-2.txt"
mkdir -p "$STATE_DIR/claims"
printf '900\t%%3\t/home/me/.eclaude\tgh-2\t2026-08-16T00:00:00Z\n' > "$STATE_DIR/claims/c.claim"
printf "You've hit your usage limit \xc2\xb7 resets 9:50am (America/Los_Angeles)\n" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3t"
out="$(run_watch TZ=UTC -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2 /home/me/.eclaude resets=2026-09-02T16:50:00Z" \
  "the account and the reset ride one event, the reset keyed" "$err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
