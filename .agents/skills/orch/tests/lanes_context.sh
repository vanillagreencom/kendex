#!/usr/bin/env bash
# Regression tests for `lanes context` (KEN-837) and lib/lane-context.sh.
#
# The overseer compacts a lane before it runs out of context, so it needs one
# number per live lane. That number comes from the lane's own pane status
# line and nothing else — and the two harnesses print it in OPPOSITE
# directions: Claude's `Opus 5 41%` is the share USED, Codex's
# `Context 86% left` the share REMAINING. Reporting either number raw sends
# the overseer to compact the emptiest lane in the fleet, so the direction is
# what these cases pin.
#
# Covered:
#   1. the claude shape reports its number as used
#   2. the codex shape is converted, not reported raw
#   3. the bottom-most reading wins over one scrolled past
#   4. a screen with neither shape is no_status_line, never 0
#   5. a pane that cannot be captured is unreadable, never 0
#   6. a percentage over 100 is not a context figure
#   7. the table names the direction it reports
#   8. an empty fleet says so; an unreadable claim store refuses
#   9. the account column names the lane the pane runs under
#
# errexit is on: every case here either succeeds or is guarded, so an
# unexpected non-zero is a broken fixture, not a finding to print past.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
LANES="$SCRIPTS_DIR/lanes"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then pass "$name"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"; fi
}

assert_contains() {
  local hay="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$hay"; then pass "$name"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        wanted: %s\n        in: %s\n' "$name" "$needle" "$hay"; fi
}

BIN="$TMP_ROOT/bin"; mkdir -p "$BIN"
PANE_DIR="$TMP_ROOT/panes"; mkdir -p "$PANE_DIR"
PANES="$TMP_ROOT/panes.txt"
STATE="$TMP_ROOT/state"
H="$TMP_ROOT/home"; mkdir -p "$H/.claude" "$H/.eclaude" "$H/.codex"

# tmux stub: `list-panes` replays $TMUX_PANES_FILE, `capture-pane -t %N`
# replays $PANE_DIR/N.screen. A pane with no screen file fails the capture,
# the way a pane on another tmux server does.
cat > "$BIN/tmux" <<'STUBEOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-panes)
    [[ -f "${TMUX_PANES_FILE:-}" ]] || exit 0
    cat "$TMUX_PANES_FILE"
    ;;
  capture-pane)
    pane=""
    while [[ $# -gt 0 ]]; do
      [[ "$1" == "-t" ]] && { pane="${2:-}"; break; }
      shift
    done
    f="$PANE_DIR/${pane#%}.screen"
    [[ -f "$f" ]] || exit 1
    cat "$f"
    ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$BIN/tmux"

LIVE_PID="$$"

write_claim() { # <name> <pane id> <config dir> <window>
  mkdir -p "$STATE/claims"
  printf '%s\t%s\t%s\t%s\t2026-08-16T00:00:00Z\n' \
    "$LIVE_PID" "$2" "$3" "$4" > "$STATE/claims/$1.claim"
}

screen() { # <pane number> <body>
  printf '%s\n' "$2" > "$PANE_DIR/$1.screen"
}

run_ctx() {
  LANES_HOME="$H" OVERSEE_WATCH_STATE_DIR="$STATE" \
    TMUX_PANES_FILE="$PANES" PANE_DIR="$PANE_DIR" \
    PATH="$BIN:$PATH" "$LANES" context "$@"
}

echo "=== lanes context ==="

printf '%s %%1\n%s %%2\n%s %%3\n%s %%4\n%s %%5\n' \
  "$LIVE_PID" "$LIVE_PID" "$LIVE_PID" "$LIVE_PID" "$LIVE_PID" > "$PANES"

write_claim one   "%1" "$H/.claude"  "ken-101"
write_claim two   "%2" "$H/.codex"   "ken-102"
write_claim three "%3" "$H/.eclaude" "ken-103"
write_claim four  "%4" "$H/.claude"  "ken-104"

screen 1 '> implement the thing
  ⏵⏵ accept edits on                          Opus 5 41%'
screen 2 '  Codex is working
  Context 86% left'
screen 3 'Opus 5 92%
some later output
  ⏵⏵ accept edits on                          Opus 5 18%'
screen 4 'plain shell output with no harness status line'
# %5 is claimed by nothing here; pane 5 has no screen file at all.

OUT="$(run_ctx --json)"

# 1. The claude shape carries the share USED, and is reported as it stands.
assert_eq "$(jq -r '.[] | select(.lane=="ken-101") | .context_used_pct' <<<"$OUT")" "41" \
  "the claude status line reports its number as used"
assert_eq "$(jq -r '.[] | select(.lane=="ken-101") | .harness' <<<"$OUT")" "claude" \
  "the matched shape names the harness, with nothing recorded in advance"
assert_eq "$(jq -r '.[] | select(.lane=="ken-101") | .status' <<<"$OUT")" "ok" \
  "a measured lane is ok"

# 2. THE conversion. `Context 86% left` is a nearly EMPTY context; reported
# raw it is the fullest lane in the fleet and the overseer compacts the wrong
# one.
assert_eq "$(jq -r '.[] | select(.lane=="ken-102") | .context_used_pct' <<<"$OUT")" "14" \
  "the codex status line is converted from remaining to used"
assert_eq "$(jq -r '.[] | select(.lane=="ken-102") | .harness' <<<"$OUT")" "codex" \
  "the codex shape names the codex harness"

# 3. A pane keeps its scrollback: the status line is the bottom-most reading,
# and an earlier one is the same lane before it compacted.
assert_eq "$(jq -r '.[] | select(.lane=="ken-103") | .context_used_pct' <<<"$OUT")" "18" \
  "the bottom-most reading wins over one scrolled past"

# 4 and 5. Neither absence is a measurement: an unmeasured lane reported as 0
# reads as a lane with the whole window free.
assert_eq "$(jq -r '.[] | select(.lane=="ken-104") | .status' <<<"$OUT")" "no_status_line" \
  "a screen with neither shape is no_status_line"
assert_eq "$(jq -r '.[] | select(.lane=="ken-104") | .context_used_pct' <<<"$OUT")" "null" \
  "a lane with no status line carries no number"

write_claim five "%5" "$H/.claude" "ken-105"
UNREAD="$(run_ctx --json)"
assert_eq "$(jq -r '.[] | select(.lane=="ken-105") | .status' <<<"$UNREAD")" "unreadable" \
  "a pane that cannot be captured is unreadable"
assert_eq "$(jq -r '.[] | select(.lane=="ken-105") | .context_used_pct' <<<"$UNREAD")" "null" \
  "an uncapturable pane carries no number"
rm -f "$STATE/claims/five.claim"

# 6. A percent sign near a model name is not automatically a context figure.
screen 4 'Opus 5 finished 140% of the plan'
OVER="$(run_ctx --json)"
assert_eq "$(jq -r '.[] | select(.lane=="ken-104") | .context_used_pct' <<<"$OVER")" "null" \
  "a percentage over 100 is not read as a context figure"
screen 4 'plain shell output with no harness status line'

# 7. The direction is part of the output. A bare percentage column is read in
# whichever direction the reader last saw one.
TABLE="$(run_ctx)"
assert_contains "$TABLE" "CONTEXT_USED_PCT" "the table column names the direction"
assert_contains "$TABLE" "CONSUMED" "the table legend states which direction it reports"
assert_contains "$TABLE" "ken-101" "the table lists the lanes by window"

# 9. The account a lane runs under, resolved from the claim's config dir.
assert_eq "$(jq -r '.[] | select(.lane=="ken-103") | .account' <<<"$OUT")" "eclaude" \
  "the account column names the lane the pane runs under"

# 8. An empty fleet and an unreadable store are different answers.
rm -f "$STATE"/claims/*.claim
EMPTY="$(run_ctx)"
assert_contains "$EMPTY" "No live lane claims" "an empty fleet says so"
assert_eq "$(run_ctx --json | jq -r 'length')" "0" "an empty fleet is an empty array"

BROKEN_STATE="$TMP_ROOT/broken"
mkdir -p "$BROKEN_STATE"
: > "$BROKEN_STATE/claims"
err="$TMP_ROOT/broken.err"
LANES_HOME="$H" OVERSEE_WATCH_STATE_DIR="$BROKEN_STATE" \
  TMUX_PANES_FILE="$PANES" PANE_DIR="$PANE_DIR" \
  PATH="$BIN:$PATH" "$LANES" context >/dev/null 2>"$err" && rc=0 || rc=$?
assert_eq "$rc" "1" "an unreadable claim store refuses rather than reporting an empty fleet"
assert_contains "$(cat "$err")" "refusing to report context" "the refusal names what it refused"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
