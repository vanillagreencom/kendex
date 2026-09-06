#!/usr/bin/env bash
# Tests for what oversee-watch reads off a spent-account banner: whether a
# limit banner on a lane's screen is the account speaking now, and what the
# reset clause on that line resolves to. The rest of the pane side is
# oversee_watch_lanes.sh and the GitHub side oversee_watch.sh; all build their
# sandbox from lib/oversee-watch-harness.sh.
#
# One table. A row names a screen (a byte-exact pane fixture, kept whole in
# `screen`), the lane it sits in, the clock and zone the pane is read under,
# and the facts the run must show; `watch` reads exactly those facts, so a row
# fails on the fact it names. A `cont` row is the next pass of the row above
# it, with the same state and a fresh capture.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

# Every fixture banner below states a clock, and the event carries the UTC
# instant it resolves to. Rows asserting the whole event line pin both ends of
# that resolution: RESET_NOW as the moment the pane is read (`now.epoch`, the
# harness's clock stub) and TZ=UTC as the zone a banner naming none is read in,
# so they hold on a runner in any zone. Their banner is the measured
# `9:50am (America/Los_Angeles)` shape: no mechanism here rests on the one
# grammar arm nothing is measured to draw, and `resets 21:00` appears only
# where that arm is the subject.
RESET_NOW=1788364800
AT_0950='EVENT+usage-limit+gh-2+resets=2026-09-02T16:50:00Z'   # what that banner resolves to
HEARTBEAT='EVENT+heartbeat+loops=1+interval=0s+since=none'

BANNER="You've hit your usage limit \xc2\xb7 resets 9:50am (America/Los_Angeles)"
CODEX_BANNER='Usage limit reached. Increase your limits to continue.'
COMPOSER='\xe2\x9d\xaf\xc2\xa0'          # Claude's composer: `❯` + U+00A0
CODEX_COMPOSER='\xe2\x80\xba Ask Codex to do anything'
DIALOG='  Select Model and Effort\n\xe2\x80\xba 1. gpt-6-astra (current)  Our most capable model for complex, demanding work.\n  2. gpt-5.6-terra          Balanced agentic coding model for everyday work.'
QUESTION='Do you want to proceed?\n   ❯ 1. Yes\n     2. No'

# screen NAME — writes the pane fixture NAME, whole, as lane gh-2's screen.
# `banner:TEXT` is a one-line pane holding TEXT (`\x` escapes expanded). The
# composer is the last marker line on the screen and never a turn: Claude Code
# draws it as `❯` + U+00A0, spelled in bytes here, and a fixture that degraded
# into an ASCII space would slice the whole pane away, so `composed` checks
# the byte is there once before the fixture is used.
composed() {
  printf '%b\n' "$@" > "$STUB_DIR/pane-gh-2.txt"
  [[ "$(grep -c "$(printf '\xc2\xa0')" "$STUB_DIR/pane-gh-2.txt")" == 1 ]] \
    || { echo "screen: a composer fixture lost its U+00A0" >&2; exit 1; }
}
screen() {
  case "$1" in
    banner:*) printf '%b\n' "${1#banner:}" > "$STUB_DIR/pane-gh-2.txt" ;;
    # the harness alive, the account spent, the realistic idle screen
    banner_idle) composed '⏺ Working through the queue.' "$BANNER" 'Run /usage-credits to raise it' "$COMPOSER" ;;
    banner_draft) composed '⏺ Working through the queue.' "$BANNER" "${COMPOSER}take the next round" ;;
    banner_over_question) printf '%b\n' "You've hit your session limit \xc2\xb7 resets 9:50am (America/Los_Angeles)" "$QUESTION" > "$STUB_DIR/pane-gh-2.txt" ;;
    # a user turn below the banner: the harness took another turn since
    stale_banner) composed '⏺ Working through the queue.' "$BANNER" '❯ pick the round back up' '⏺ Teammate @dev-ken832-r3 finished' "$COMPOSER" ;;
    # the permission line a real screen draws under the composer, so the
    # composer is not the last line and the Claude signature decides the
    # boundary rather than the last-line fallback
    banner_after_turn) composed '❯ pick the round back up' '⏺ Working through the queue.' "$BANNER" "$COMPOSER" '  bypass permissions on' ;;
    # an input line the composer rule does not recognize
    unrecognized_composer) printf '%b\n' '❯ pick the round back up' '⏺ Working through the queue.' "$BANNER" '❯ ' > "$STUB_DIR/pane-gh-2.txt" ;;
    # the E2-lead lines a real screen carries between the banner and the
    # composer, and no streaming token counter: the turn that hit the wall is
    # over
    realistic) composed '❯ pick the round back up' '⏺ Ran 3 shell commands' "$BANNER" '⏺ Teammate @dev-ken832-r3 finished' '⎿  Wrote 6 lines to tmp/roundD.json' '─────────────────────────────' "$COMPOSER" ;;
    # a dialog screen draws no composer: the selection rows replace it
    stale_over_question) printf '%b\n' "$BANNER" '❯ pick the round back up' '⏺ Teammate @dev-ken832-r3 finished' "$QUESTION" > "$STUB_DIR/pane-gh-2.txt" ;;
    live_over_question) printf '%b\n' '❯ pick the round back up' '⏺ Teammate @dev-ken832-r3 finished' "$BANNER" "$QUESTION" > "$STUB_DIR/pane-gh-2.txt" ;;
    healthy) composed '⏺ All green, nothing blocking.' "$COMPOSER" ;;
    # the measured AskUserQuestion screen (its selected row at column 0, the
    # question above the row) with the banner drawn under the user's turn
    banner_over_column0_dialog)
      grep -q '^❯ 1\. Yes' "$CODEX_PANES/claude-dialog-askuserquestion.txt" \
        || { echo "screen: the AskUserQuestion fixture no longer draws its row at column 0, so the row would pin nothing" >&2; exit 1; }
      { head -n 7 "$CODEX_PANES/claude-dialog-askuserquestion.txt"; printf '%s\n' "$BANNER"; tail -n +8 "$CODEX_PANES/claude-dialog-askuserquestion.txt"; } > "$STUB_DIR/pane-gh-2.txt"
      grep -q '^❯ Use the AskUserQuestion' <(head -n 7 "$STUB_DIR/pane-gh-2.txt") \
        || { echo "screen: the banner did not land under the user turn" >&2; exit 1; } ;;
    # this suite's own source among the text a lane prints mid-turn
    working) printf '%b\n' '⏺ Reading the suite.' "  printf \"You've hit your usage limit \xc2\xb7 resets 17:00\"" 'esc to interrupt' > "$STUB_DIR/pane-gh-2.txt" ;;
    banner_1700) composed "You've hit your usage limit \xc2\xb7 resets 17:00" "$COMPOSER" ;;
    # Codex draws the composer with the SAME `› ` and text a submitted turn
    # uses, so only its position separates them
    codex_banner) printf '%b\n' "$CODEX_BANNER" > "$STUB_DIR/pane-gh-2.txt" ;;
    codex_live) printf '%b\n' '\xe2\x80\xba pick the round back up' '\xe2\x80\xa2 Ran 3 commands' "$CODEX_BANNER" "$CODEX_COMPOSER" > "$STUB_DIR/pane-gh-2.txt" ;;
    codex_stale) printf '%b\n' "$CODEX_BANNER" '\xe2\x80\xba pick the round back up' '\xe2\x80\xa2 Ran 3 commands' "$CODEX_COMPOSER" > "$STUB_DIR/pane-gh-2.txt" ;;
    # a Codex dialog draws no composer and does NOT indent the selected row:
    # that row keeps the marker at column 0, measured on a live model picker
    codex_dialog_stale) printf '%b\n' "$CODEX_BANNER" '\xe2\x80\xba pick the round back up' '\xe2\x80\xa2 Ran 3 commands' "$DIALOG" '  Press enter to confirm or esc to go back' > "$STUB_DIR/pane-gh-2.txt" ;;
    codex_dialog_live) printf '%b\n' '\xe2\x80\xba pick the round back up' '\xe2\x80\xa2 Ran 3 commands' "$CODEX_BANNER" "$DIALOG" > "$STUB_DIR/pane-gh-2.txt" ;;
    # the byte-exact startup screen of a fresh Codex, carrying its reset OFFER
    codex_idle)
      grep -qF 'You have 1 usage limit reset available' "$CODEX_PANES/codex-composer-idle.txt" \
        || { echo "screen: the codex idle fixture no longer carries the reset offer, so the near-miss row would pin nothing" >&2; exit 1; }
      cat "$CODEX_PANES/codex-composer-idle.txt" > "$STUB_DIR/pane-gh-2.txt" ;;
    *) echo "screen: unknown fixture $1" >&2; exit 1 ;;
  esac
}

# lane NAME — stages what surrounds the pane: its foreground command, and for
# the claim lanes the pane identity and the claim files the watch reads.
lane() {
  case "$1" in
    claude) ;;
    codex) printf 'codex\n' > "$STUB_DIR/cmd-gh-2.txt" ;;
    # the harness under a shell: liveness is answered from the shell's children
    fish) printf 'fish\n' > "$STUB_DIR/cmd-gh-2.txt"; printf '2747883\n' > "$STUB_DIR/kids-9002.txt" ;;
    # three claims, read in glob order: one from another live server, one from
    # THIS server on another pane, and the pane actually captured. Window
    # names repeat across sessions as well as across servers.
    claim_live)
      printf '900 %%3\n' > "$STUB_DIR/panes.txt"
      printf '900 %%3\n' > "$STUB_DIR/pane-key-gh-2.txt"
      mkdir -p "$STATE_DIR/claims"
      printf '%s\t%%3\t/home/me/.otherclaude\tgh-2\t2026-08-16T00:00:00Z\n' "$$" > "$STATE_DIR/claims/a.claim"
      printf '900\t%%9\t/home/me/.thirdclaude\tgh-2\t2026-08-16T00:00:00Z\n' > "$STATE_DIR/claims/b.claim"
      printf '900\t%%3\t/home/me/.eclaude\tgh-2\t2026-08-16T00:00:00Z\n' > "$STATE_DIR/claims/c.claim" ;;
    # one claim whose pane is gone
    claim_dead)
      printf '900 %%9\n' > "$STUB_DIR/panes.txt"
      printf '900 %%3\n' > "$STUB_DIR/pane-key-gh-2.txt"
      mkdir -p "$STATE_DIR/claims"
      printf '900\t%%3\t/home/me/.eclaude\tgh-2\t2026-08-16T00:00:00Z\n' > "$STATE_DIR/claims/a.claim" ;;
    *) echo "lane: unknown lane $1" >&2; exit 1 ;;
  esac
}

# run [ENV=VAL ...] — one single-pass watch over gh-1 and gh-2; OUT, RC and
# ERR (a file) are what `watch` reads.
RUN_SEQ=0
run() {
  ERR="$TMP_ROOT/run-$((++RUN_SEQ)).err"
  OUT="$(run_watch "$@" -- --max-loops 1 gh-1 gh-2 2>"$ERR")" && RC=0 || RC=$?
}

# watch EXPECT — prints the run's value of every `name=` field EXPECT names,
# in EXPECT's order (in a needle `+` reads as a space and %e as `=`):
#   rc            exit status
#   first         the first stdout line, or `none`
#   out~<text>    whether stdout carries <text>
#   claims        how many claim files the state directory holds
watch() {
  local got="" token name value needle
  set -f
  for token in $1; do
    name="${token%%=*}"
    needle="${name#*~}"; needle="${needle//+/ }"; needle="${needle//%e/=}"
    case "$name" in
      rc) value="$RC" ;;
      first) value="$(head -n 1 <<<"$OUT")"; value="${value:-none}"; value="${value// /+}" ;;
      out~*) value="$(grep -qF -- "$needle" <<<"$OUT" && echo true || echo false)" ;;
      claims) value="$(find "$STATE_DIR/claims" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d '[:space:]')" ;;
      *) echo "watch: unknown field $name" >&2; exit 1 ;;
    esac
    got="$got $name=$value"
  done
  set +f
  printf '%s' "${got# }"
}

# usage_table ROW... — `label|pass|screen|lane|now|zone|expect`. `pass` is
# `new` (a fresh sandbox) or `cont` (the next pass over the row above: same
# state, fresh capture); `now` the epoch the pane is read at, or `-` for the
# host clock on a new row and the row above's clock on a cont row; `zone`
# the runner's zone, UTC, LA (America/Los_Angeles), C (UTC
# under a byte-oriented locale) or `-` for the host's.
CASE_SEQ=0
usage_table() {
  local row label pass name which now zone expect env
  for row in "$@"; do
    IFS='|' read -r label pass name which now zone expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'usage_table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    case "$pass" in
      new) new_case "usage_$((++CASE_SEQ))" ;;
      cont) rm -f "$STUB_DIR/pane-gh-2.calls" "$STUB_DIR/cmd-gh-2.calls" ;;
      *) echo "usage_table: unknown pass $pass in $row" >&2; exit 1 ;;
    esac
    lane "$which"
    screen "$name"
    [[ "$now" == - ]] || printf '%s' "$now" > "$STUB_DIR/now.epoch"
    env=()
    case "$zone" in
      UTC) env=(TZ=UTC) ;;
      LA) env=(TZ=America/Los_Angeles) ;;
      C) env=(TZ=UTC LC_ALL=C LANG=C) ;;
      -) ;;
      *) echo "usage_table: unknown zone $zone in $row" >&2; exit 1 ;;
    esac
    run ${env[@]+"${env[@]}"}
    assert_eq "$(watch "$expect")" "$expect" "$label" "$ERR"
  done
}

echo "=== oversee-watch usage limits: is the account speaking now ==="
# A banner is the event only when nothing below it says the harness took
# another turn: the last user-turn marker is the boundary, the composer is
# never a turn, and a dialog screen draws no composer at all, so its last
# marker line is the user turn itself. The realistic transcript runs under
# both locales: the marker must be an alternation of literals, since as a
# bracket expression it degrades to a set of BYTES on an awk without multibyte
# support and every transcript line reads as a marker; gawk under the runner's
# UTF-8 locale cannot see that, LC_ALL=C can. A spent account outranks a
# prompt on the same screen, and the near-miss is every fresh Codex's benign
# reset OFFER, which a looser USAGE_LIMIT_RE would turn into an event.
usage_table \
  "a limit banner under a live harness is the event on ONE pass, the pane tail following|new|banner_idle|claude|$RESET_NOW|UTC|rc=0 first=$AT_0950 out~usage+limit=true" \
  "the codex banner fires too: one regex covers both harnesses|new|codex_banner|codex|-|-|rc=0 first=EVENT+usage-limit+gh-2" \
  "a limit banner above a stale prompt is usage-limit, never lane-asking|new|banner_over_question|claude|$RESET_NOW|UTC|rc=0 first=$AT_0950 out~EVENT+lane-asking=false" \
  "a lane wrapped in a shell still gets its banner seen|new|banner:You've hit your weekly limit \\xc2\\xb7 resets Sunday|fish|-|-|rc=0 first=EVENT+usage-limit+gh-2" \
  "a banner the lane has since worked past is scrollback|new|stale_banner|claude|-|-|rc=0 first=$HEARTBEAT out~EVENT+usage-limit=false" \
  "an unsent draft in the composer is not a turn either|new|banner_draft|claude|$RESET_NOW|UTC|rc=0 first=$AT_0950" \
  "a banner below the last user turn is the event, the Claude signature deciding the boundary|new|banner_after_turn|claude|$RESET_NOW|UTC|rc=0 first=$AT_0950" \
  "an unrecognized last input line never swallows the screen|new|unrecognized_composer|claude|$RESET_NOW|UTC|rc=0 first=$AT_0950" \
  "transcript lines between the banner and the composer are not markers|new|realistic|claude|$RESET_NOW|UTC|rc=0 first=$AT_0950" \
  "...and under a byte-oriented locale, where a marker class would degrade|new|realistic|claude|$RESET_NOW|C|rc=0 first=$AT_0950" \
  "a stale banner never masks the live question on a dialog screen|new|stale_over_question|claude|-|-|rc=0 first=EVENT+lane-asking+gh-2 out~EVENT+usage-limit=false" \
  "a banner below the turn on a dialog screen is still the event, and outranks the question|new|live_over_question|claude|$RESET_NOW|UTC|rc=0 first=$AT_0950" \
  "a dialog's column-0 selected row is live input, not the turn: the banner above it is still the event|new|banner_over_column0_dialog|claude|$RESET_NOW|UTC|rc=0 first=$AT_0950 out~EVENT+lane-asking=false" \
  "a codex banner below the last turn is reported, the composer notwithstanding|new|codex_live|codex|-|-|rc=0 first=EVENT+usage-limit+gh-2" \
  "a codex banner the lane has worked past is not the event: the composer never resurrects it|new|codex_stale|codex|-|-|rc=0 first=$HEARTBEAT out~EVENT+usage-limit=false" \
  "a codex dialog row is live input, so the banner above the turn stays scrollback|new|codex_dialog_stale|codex|-|-|rc=0 first=EVENT+lane-asking+gh-2 out~EVENT+usage-limit=false" \
  "a banner below the turn on a codex dialog screen is still the event|new|codex_dialog_live|codex|-|-|rc=0 first=EVENT+usage-limit+gh-2" \
  "a codex startup screen is no event: an offered reset is credit to spend|new|codex_idle|codex|-|-|rc=0 first=$HEARTBEAT out~EVENT+usage-limit=false" \
  "control: a lane with no banner reaches the heartbeat|new|healthy|claude|-|-|rc=0 first=$HEARTBEAT out~EVENT+usage-limit=false"

echo "=== the account is the actionable part ==="
# A live claim maps the window to its config dir; anything matching on the
# window NAME alone would answer with another server's or another pane's
# claim. A claim whose pane is gone is pruned on read, not reported.
usage_table \
  "the event names the config dir the lane was claimed on, never a same-named window elsewhere|new|banner:You've hit your weekly limit|claim_live|-|-|rc=0 first=EVENT+usage-limit+gh-2+/home/me/.eclaude out~otherclaude=false out~thirdclaude=false" \
  "a claim whose pane is gone names no account and is pruned|new|banner:You've hit your weekly limit|claim_dead|-|-|rc=0 first=EVENT+usage-limit+gh-2 claims=0"

# The note is about the event line it qualifies: a re-run that suppresses the
# standing wall prints neither. Red with the claim read above the suppression.
new_case claim_note_only_with_event
# one live claim on this server, on a pane other than the one captured
printf '900 %%3\n900 %%9\n' > "$STUB_DIR/panes.txt"
printf '900 %%3\n' > "$STUB_DIR/pane-key-gh-2.txt"
mkdir -p "$STATE_DIR/claims"
printf '900\t%%9\t/home/me/.eclaude\tgh-9\t2026-08-16T00:00:00Z\n' > "$STATE_DIR/claims/a.claim"
screen "banner:You've hit your weekly limit"
run
expect="rc=0 first=EVENT+usage-limit+gh-2"
assert_eq "$(watch "$expect")" "$expect" "the run that reports the wall notes the missing claim" "$ERR"
assert_eq "$(grep -c 'no live lane claim' "$ERR")" "1" "and prints the note once"
rm -f "$STUB_DIR/pane-gh-2.calls" "$STUB_DIR/cmd-gh-2.calls"
run
expect="rc=0 first=$HEARTBEAT out~EVENT+usage-limit=false"
assert_eq "$(watch "$expect")" "$expect" "a re-run over the same wall reports nothing" "$ERR"
assert_eq "$(grep -c 'no live lane claim' "$ERR" || true)" "0" "and the note about an event it did not print stays silent"

echo "=== the reset the banner states ==="
# SURFACE 1: the reset parsed out of each banner form the grammar accepts,
# each a fresh sighting because each names a different wall (the
# zone-qualified form is the row that opens the observed-reset sequence
# below); then the forms
# the grammar deliberately excludes and a zone the host cannot resolve, which
# keep the plain event with no time on it and are never evidence the wall
# has lifted.
usage_table \
  "a one-component zone name is still a zone|new|banner:You've hit your usage limit \\xc2\\xb7 resets 9:50pm (UTC)|claude|$RESET_NOW|LA|rc=0 first=EVENT+usage-limit+gh-2+resets=2026-09-02T21:50:00Z" \
  "a clock with no meridiem is a 24-hour one|new|banner:You've hit your session limit \\xc2\\xb7 resets 21:00|claude|$RESET_NOW|UTC|rc=0 first=EVENT+usage-limit+gh-2+resets=2026-09-02T21:00:00Z" \
  "12pm is noon, not midnight and not hour 24|new|banner:You've hit your usage limit \\xc2\\xb7 resets 12pm|claude|$RESET_NOW|UTC|rc=0 first=EVENT+usage-limit+gh-2+resets=2026-09-03T12:00:00Z" \
  "a dated banner is read as a date|new|banner:You've hit your weekly limit \\xc2\\xb7 resets Sep 6, 4pm|claude|$RESET_NOW|UTC|rc=0 first=EVENT+usage-limit+gh-2+resets=2026-09-06T16:00:00Z" \
  "the year the dated form carries wins|new|banner:You've hit your weekly limit \\xc2\\xb7 resets Oct 7, 2027, 11:32am|claude|$RESET_NOW|UTC|rc=0 first=EVENT+usage-limit+gh-2+resets=2027-10-07T11:32:00Z" \
  "a weekday and a clock name that weekday|new|banner:You've hit your weekly limit \\xc2\\xb7 resets Thursday 4am|claude|$RESET_NOW|UTC|rc=0 first=EVENT+usage-limit+gh-2+resets=2026-09-03T04:00:00Z" \
  "codex's trigger and ordinal day read the same|new|banner:You've hit your usage limit. Try again at Sep 6th, 2026 4:30 PM|claude|$RESET_NOW|UTC|rc=0 first=EVENT+usage-limit+gh-2+resets=2026-09-06T16:30:00Z" \
  "a duration names no instant, and no time is invented|new|banner:You've hit your fast limit \\xc2\\xb7 resets in 5m|claude|$RESET_NOW|UTC|rc=0 first=EVENT+usage-limit+gh-2 out~resets%e=false" \
  "a bare number is not a clock|new|banner:You've hit your usage limit \\xc2\\xb7 resets 2026-09-03|claude|$RESET_NOW|UTC|rc=0 first=EVENT+usage-limit+gh-2 out~resets%e=false" \
  "a weekday alone guesses no midnight|new|banner:You've hit your weekly limit \\xc2\\xb7 resets Thursday|claude|$RESET_NOW|UTC|rc=0 first=EVENT+usage-limit+gh-2 out~resets%e=false" \
  "a zone the host cannot resolve drops the time|new|banner:You've hit your usage limit \\xc2\\xb7 resets 9:50am (Bogus/Zone)|claude|$RESET_NOW|UTC|rc=0 first=EVENT+usage-limit+gh-2 out~resets%e=false"

# SURFACE 2: a clause naming no day is usage-limit-passed only once this watch
# has seen that wall standing (the case the issue was filed on); the same
# screen at the same instant with nothing observed before it cannot know which
# 9:50am the banner meant, so it parks. A wall reported once is not reported
# again by a re-run while it stands; the reset going by is what is news.
# SURFACE 3: a dated clause names its own day and needs no sighting. SURFACE
# 4: one predicate answers is-the-account-speaking for both consumers, so a
# turn in flight neither emits nor stamps.
usage_table \
  "the first pass observes the wall and carries the reset it names|new|banner:$BANNER|claude|$RESET_NOW|UTC|rc=0 first=$AT_0950" \
  "a re-run over the same standing wall does not report it again|cont|banner:$BANNER|claude|$RESET_NOW|UTC|rc=0 first=$HEARTBEAT out~EVENT+usage-limit=false" \
  "the reset the first pass observed, now behind us, is its own event|cont|banner:$BANNER|claude|1788369300|UTC|rc=0 first=EVENT+usage-limit-passed+gh-2+resets=2026-09-02T16:50:00Z" \
  "a wall this watch never saw standing is parked, not bumped|new|banner:$BANNER|claude|1788369300|UTC|rc=0 first=EVENT+usage-limit+gh-2+resets=2026-09-03T16:50:00Z" \
  "a dated reset already behind us is passed without an observation|new|banner:You've hit your weekly limit \\xc2\\xb7 resets Aug 30, 4pm|claude|$RESET_NOW|UTC|rc=0 first=EVENT+usage-limit-passed+gh-2+resets=2026-08-30T16:00:00Z" \
  "and a dated reset still ahead is a wall standing|cont|banner:You've hit your weekly limit \\xc2\\xb7 resets Sep 6, 4pm|claude|-|UTC|rc=0 first=EVENT+usage-limit+gh-2+resets=2026-09-06T16:00:00Z" \
  "a lane with a turn in flight is left alone|new|working|claude|$RESET_NOW|UTC|rc=0 first=$HEARTBEAT" \
  "the working pass left no sighting, so this one is the first|cont|banner_1700|claude|1788372000|UTC|rc=0 first=EVENT+usage-limit+gh-2+resets=2026-09-03T17:00:00Z"

echo "=== a walled lane does not starve the fleet ==="
# One pass reports every lane it found something on, as one block: a fleet
# with one lane parked on its banner and another sitting on an unanswered
# prompt emits usage-limit for the first AND lane-asking for the second, each
# followed by its own pane tail, and exits once. Before, the usage-limit arm
# left the pass on the first walled lane, and with a parked lane the steady
# state (oversee.md § 4), no other lane's question was reported until the
# banner cleared.
new_case walled_and_asking_fleet
printf '%b\n' '⏺ Working through the queue.' "$BANNER" 'Run /usage-credits to raise it' "$COMPOSER" > "$STUB_DIR/pane-gh-1.txt"
printf '%b\n' "$QUESTION" > "$STUB_DIR/pane-gh-2.txt"
printf '%s' "$RESET_NOW" > "$STUB_DIR/now.epoch"
run TZ=UTC
expect="rc=0 first=EVENT+usage-limit+gh-1+resets=2026-09-02T16:50:00Z out~EVENT+lane-asking+gh-2=true out~Do+you+want+to+proceed?=true out~EVENT+heartbeat=false"
assert_eq "$(watch "$expect")" "$expect" \
  "a walled lane and an asking lane are both reported in one pass, the wall first" "$ERR"
assert_eq "$(grep -c '^EVENT ' <<<"$OUT")" "2" "the block carries exactly the two events" "$ERR"
assert_eq "$(grep -n '^EVENT ' <<<"$OUT" | cut -d: -f1 | tr '\n' ' ')" "1 6 " \
  "the walled lane's four-line pane tail sits between its line and the asking line" "$ERR"

# The must-fail control: the usage-limit arm's early exit restored. The
# mutant leaves the pass on the first walled lane, so the fleet above reads
# as usage-limit alone; the copy must differ from the source or the control
# proves nothing. The copy keeps orch's place in a skills tree: its libraries
# resolve the github skill beside it.
MUTANT_DIR="$TMP_ROOT/mutant"
mkdir -p "$MUTANT_DIR/orch"
cp -R "$REPO_ROOT/skills/orch/scripts" "$MUTANT_DIR/orch/scripts"
ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
sed '/^      echo "EVENT \$event \$lane/,/^      PASS_EVENT=1$/ s/^      PASS_EVENT=1$/      pr_watch_context; exit 0/' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$(cmp -s "$MUTANT_DIR/orch/scripts/oversee-watch" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" "differs" \
  "control: the mutant really restores the usage-limit arm's early exit"
new_case walled_and_asking_fleet_mutant
printf '%b\n' '⏺ Working through the queue.' "$BANNER" 'Run /usage-credits to raise it' "$COMPOSER" > "$STUB_DIR/pane-gh-1.txt"
printf '%b\n' "$QUESTION" > "$STUB_DIR/pane-gh-2.txt"
printf '%s' "$RESET_NOW" > "$STUB_DIR/now.epoch"
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run TZ=UTC
expect="rc=0 first=EVENT+usage-limit+gh-1+resets=2026-09-02T16:50:00Z out~EVENT+lane-asking=false"
assert_eq "$(watch "$expect")" "$expect" \
  "control: with the early exit restored the asking lane goes unreported" "$ERR"

# The same mutant with the dialog-row arm removed instead: a column-0 selected
# row reads as the turn, the banner above it falls out of the slice, and the
# screen is reported as the question it cannot answer.
sed 's/ || line\[last\] ~ dialog))$/))/' "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$(cmp -s "$MUTANT_DIR/orch/scripts/oversee-watch" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" "differs" \
  "control: the mutant really removes the dialog-row arm"
new_case column0_dialog_mutant
lane claude
screen banner_over_column0_dialog
printf '%s' "$RESET_NOW" > "$STUB_DIR/now.epoch"
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run TZ=UTC
expect="first=EVENT+lane-asking+gh-2 out~EVENT+usage-limit=false"
assert_eq "$(watch "$expect")" "$expect" \
  "control: without the arm the column-0 row is the turn and the banner above it goes unreported" "$ERR"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
