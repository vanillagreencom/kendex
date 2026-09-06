#!/usr/bin/env bash
# Tests for `lanes context` and lib/lane-context.sh. The overseer hands a
# lane off before it runs out of context, so it needs one number per live
# lane, read from the lane's own pane status line and nothing else. The two
# harnesses print it in OPPOSITE directions (Claude's `Opus 5 41%` is the share
# used, Codex's `Context 86% left` the share remaining) and in different
# places (Codex draws it last, so its reading is the final non-empty line and
# no other; Claude draws agent rows below it, so its reading is the
# bottom-most whole-line match). Which rule a pane gets comes from the pane's
# own foreground process, never from what is on the screen, because this
# fleet pastes both harnesses' screens into both harnesses' terminals. Pane
# %1's screen is a real `tmux capture-pane`; the other claude screens are built
# from real status lines; the committed codex captures are parsed as they are.
#
# One neutral world of panes, claims and screens; one `lanes context` JSON;
# one row per lane with the fields it pins, so a row fails on the field it
# names. errexit is on: every case either succeeds or is guarded, so an
# unexpected non-zero is a broken fixture, not a finding to print past.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
LANES="$SCRIPTS_DIR/lanes"

TMP_ROOT="$(mktemp -d)"
# FOREIGN_PID is assigned well below this trap, and `kill 0` signals the whole
# process group — the runner included. Guard on the variable, never on a
# default that expands to a signal every process here would receive.
cleanup() {
  if [[ -n "${FOREIGN_PID:-}" ]]; then kill "$FOREIGN_PID" 2>/dev/null || true; fi
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT

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

# Whole-line match. The legend repeats CONTEXT_USED_PCT, so a substring
# assertion on the header's number column is satisfied by the footer alone.
assert_line() {
  local hay="$1" re="$2" name="$3"
  if grep -qE -- "$re" <<<"$hay"; then pass "$name"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        wanted line matching: %s\n        in: %s\n' "$name" "$re" "$hay"; fi
}

BIN="$TMP_ROOT/bin"; mkdir -p "$BIN"
PANE_DIR="$TMP_ROOT/panes"; mkdir -p "$PANE_DIR"
PANES="$TMP_ROOT/panes.txt"
NO_SERVER="$TMP_ROOT/panes-none.txt"
: > "$NO_SERVER"
STATE="$TMP_ROOT/state"
H="$TMP_ROOT/home"; mkdir -p "$H/.claude" "$H/.eclaude" "$H/.codex"

# tmux stub: `list-panes` replays $TMUX_PANES_FILE, whose rows are
# `<server pid> <pane id> <foreground process>`, PROJECTED onto the -F format
# the caller asked for — lane-claims asks for two fields and matches the line
# whole, lane-context asks for three. A stub that answered both with the same
# row would prune every claim in the store before the collector saw it.
# `capture-pane -t %N` replays $PANE_DIR/N.screen; a pane with no screen file
# fails the capture, the way a pane on another tmux server does.
cat > "$BIN/tmux" <<'STUBEOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-panes)
    [[ -f "${TMUX_PANES_FILE:-}" ]] || exit 0
    fmt=""
    args=("$@")
    for i in "${!args[@]}"; do
      [[ "${args[$i]}" == "-F" ]] && { fmt="${args[$((i + 1))]:-}"; break; }
    done
    if [[ "$fmt" == *pane_current_command* ]]; then
      awk '{ print $1, $2, $3 }' "$TMUX_PANES_FILE"
    else
      awk '{ print $1, $2 }' "$TMUX_PANES_FILE"
    fi
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

# A live process that is NOT the enumerated tmux server. lane_claims_read
# keeps a claim on an unenumerable server while that server's process runs,
# so a foreign claim needs a live pid to survive the prune and reach the
# collector at all.
sleep 300 &
FOREIGN_PID=$!

write_claim_on() { # <server pid> <name> <pane id> <config dir> <window>
  mkdir -p "$STATE/claims"
  printf '%s\t%s\t%s\t%s\t2026-08-16T00:00:00Z\n' \
    "$1" "$3" "$4" "$5" > "$STATE/claims/$2.claim"
}

write_claim() { # <name> <pane id> <config dir> <window>
  write_claim_on "$LIVE_PID" "$@"
}

screen() { # <pane number> <body>
  printf '%s\n' "$2" > "$PANE_DIR/$1.screen"
}

run_ctx_on() { # <panes file> [args...]
  local panes="$1"; shift
  LANES_HOME="$H" OVERSEE_WATCH_STATE_DIR="$STATE" \
    TMUX_PANES_FILE="$panes" PANE_DIR="$PANE_DIR" \
    PATH="$BIN:$PATH" "$LANES" context "$@"
}

run_ctx() { run_ctx_on "$PANES" "$@"; }

echo "=== lanes context ==="

# Foreground process per pane. %9 is the one that exited to its shell.
{
  for n in 1 3 4 5 10 13 14 15 16 21 26; do printf '%s %%%s claude\n' "$LIVE_PID" "$n"; done
  for n in 2 6 7 8 19 20 22 23 24 25; do printf '%s %%%s codex\n' "$LIVE_PID" "$n"; done
  # 6, both-shapes arm. `pi` is a harness this reader measures and has no
  # shape rule for, so both are offered and the fall-through guard is
  # reachable — the only place it is.
  printf '%s %%27 pi\n' "$LIVE_PID"
  # 28. agent-confine is the launcher BOTH harnesses exec through, so its
  # pane command names neither and both shapes are offered. %28 is a wrapped
  # codex lane, %29 a wrapped claude one, %30 a wrapped pane showing neither.
  for n in 28 29 30; do printf '%s %%%s agent-confine\n' "$LIVE_PID" "$n"; done
  # 31: a claude pane whose transcript ends in prose carrying a COMPLETE
  # status-shaped tail, account parenthetical and hint included. 32: a
  # per-account wrapper pane showing no status line at all.
  printf '%s %%31 claude\n' "$LIVE_PID"
  printf '%s %%32 nclaude\n' "$LIVE_PID"
  # 33: a 1M-window lane past the overseer's handoff mark.
  printf '%s %%33 claude\n' "$LIVE_PID"
  printf '%s %%9 fish\n' "$LIVE_PID"
  # tmux reports a login shell with the leading dash it was started with.
  printf '%s %%11 -bash\n' "$LIVE_PID"
  printf '%s %%12 zsh\n' "$LIVE_PID"
  # 20. A harness gone, an ordinary command left running in its pane. It is
  # not a shell, so any not-a-shell test admits it and measures the footer
  # the harness left behind.
  printf '%s %%17 less\n' "$LIVE_PID"
  # 21. The per-account wrapper this fleet launches Claude through.
  printf '%s %%18 nclaude\n' "$LIVE_PID"
} > "$PANES"

write_claim one    "%1"  "$H/.claude"  "ken-101"
write_claim two    "%2"  "$H/.codex"   "ken-102"
write_claim three  "%3"  "$H/.eclaude" "ken-103"
write_claim four   "%4"  "$H/.claude"  "ken-104"
write_claim six    "%6"  "$H/.codex"   "ken-106"
write_claim seven  "%7"  "$H/.codex"   "ken-107"
write_claim eight  "%8"  "$H/.codex"   "ken-108"
write_claim nine   "%9"  "$H/.claude"  "ken-109"
write_claim eleven "%10" "$H/.claude"  "ken-111"
write_claim twelve   "%11" "$H/.claude" "ken-112"
write_claim thirteen "%12" "$H/.claude" "ken-113"
write_claim fourteen "%13" "$H/.claude" "ken-114"
write_claim fifteen  "%14" "$H/.claude" "ken-115"
write_claim sixteen   "%15" "$H/.claude" "ken-116"
write_claim seventeen "%16" "$H/.claude" "ken-117"
write_claim eighteen  "%17" "$H/.claude" "ken-118"
write_claim nineteen  "%18" "$H/.claude" "ken-119"
write_claim twenty    "%19" "$H/.codex"  "ken-120"
write_claim twentyone "%20" "$H/.codex"  "ken-121"
write_claim twentytwo   "%21" "$H/.claude" "ken-122"
write_claim twentythree "%22" "$H/.codex"  "ken-123"
write_claim twentyfour  "%23" "$H/.codex"  "ken-124"
write_claim twentyfive  "%24" "$H/.codex"  "ken-125"
write_claim twentysix   "%25" "$H/.codex"  "ken-126"
write_claim twentyseven "%26" "$H/.claude" "ken-127"
write_claim twentyeight "%27" "$H/.codex"  "ken-128"
write_claim twentynine  "%28" "$H/.codex"  "ken-129"
write_claim thirty      "%29" "$H/.claude" "ken-130"
write_claim thirtyone   "%30" "$H/.codex"  "ken-131"
write_claim thirtytwo   "%31" "$H/.claude" "ken-132"
write_claim thirtythree "%32" "$H/.claude" "ken-133"
write_claim thirtyfour  "%33" "$H/.claude" "ken-134"
# The foreign lane's pane NUMBER exists here too, on a screen that parses
# cleanly: %1 is the first lane's, reading 35.
write_claim_on "$FOREIGN_PID" foreign "%1" "$H/.claude" "ken-110"

# 1. An ORCHESTRATING lane, captured live rather than written from memory.
# The footer below its status line grows by a row per running agent, so it
# is unbounded: a lane running more agents draws more rows, and any window
# narrower than the footer loses exactly the lanes the overseer compaction
# rule exists for. Only the box rules are trimmed, to keep this file narrow;
# nothing else is altered.
screen 1 '  ⎿  Tip: Use /clear to start fresh when switching topics and free up context

──────────────────────────────
❯
──────────────────────────────
  kendex (🌳 ken-835*) Opus 5 35% (brad@drovr.dev)     /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · PR #1841 · ← 1 agent

  ● main
  ◯ dev-ken835  Follow workflow: .agents/skills/dev/workflows/dev-...   7m 45s · ↓ 937.0k tokens
  ◯ dev-ken-845  Follow workflow: .agents/skills/dev/workflo… 8m 45s · ↓ 364.8k tokens
  ◯ dev-ken-844-c  Follow workflow: .agents/skills/dev/workflo… 4m 2s · ↓ 75.8k tokens'
# 2. The codex status line is the last NON-EMPTY row: a real capture carries
# blank rows under it, and a rule that read the last row outright would find
# one of those and report nothing.
screen 2 '  Codex is working
  Context 86% left

'
# A repaint after a compaction leaves the previous render on the screen.
screen 3 '  kendex (🌳 ken-103) Opus 5 92% (brad@drovr.dev)     /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
● Compacted 113,518 tokens · ctrl+o to expand
  kendex (🌳 ken-103) Opus 5 18% (brad@drovr.dev)     /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents'
screen 4 'plain shell output with no harness status line'
# %5 is claimed by nothing here; pane 5 has no screen file at all.
screen 6 '  Codex is working
  Context 40% used'
screen 7 '  Context 86% left · Opus 5 41%'
screen 8 '  Context 140% left'
screen 9 '  kendex (🌳 ken-109) Opus 5 41% (brad@drovr.dev)     /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
$ git status
On branch ken-109
working tree clean, nothing staged
$ ls tmp
dev-round-ken-109.json
$ '
# A session that has not rendered a percentage yet — the status line of tmux
# pane %21, captured from the same server — under a transcript line naming a
# model and a percentage in prose.
screen 10 '● Opus 5 has used 35% of its window on this lane so far
  scribd-brain Opus 5 (1M context) (S)
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents'
# 16. Two more panes back at their shell, each carrying a status line that
# parses cleanly: whichever one gets measured is a lane reporting the number
# it stopped at. %11 is a LOGIN shell, which tmux names with the dash it was
# started with; %12 is a second name from the list, so the list is driven by
# more than the one entry case 13 supplies.
screen 11 '  kendex (🌳 ken-112) Opus 5 44% (brad@drovr.dev)     /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
$ '
screen 12 '  kendex (🌳 ken-113) Opus 5 55% (brad@drovr.dev)     /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
$ '
# 17. What Claude puts between the model name and the percentage. The window
# size rides in a parenthetical, and a point-release model puts a dotted
# version in the version slot; both spellings run on this fleet.
# Without either allowance the line matches nothing and the lane drops out of
# the report unmeasured, which is the failure the whole `context` verb exists
# to prevent.
screen 13 '  scribd-brain Opus 5 (1M context) 22% (brad@drovr.dev)     /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents'
screen 14 '  scribd-brain Sonnet 4.5 (1M context) 12% (brad@drovr.dev)     /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents'
# 18 and 19. The transcript ends in a sentence carrying a model, a version
# and a percentage — every piece of the status line except the line itself.
# %15 puts it BELOW a real status line, which is where bottom-most hands it
# the verdict; %16 gives it a screen of its own.
screen 15 '  kendex (🌳 ken-116) Opus 5 35% (brad@drovr.dev)     /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
● Documentation example: Opus 5 92% is already heavily used.'
screen 16 '● Documentation example: Opus 5 92% is already heavily used.'
# 20 and 21. Both screens parse cleanly; what separates them is the process
# tmux reports for the pane.
screen 17 '  kendex (🌳 ken-118) Opus 5 66% (brad@drovr.dev)     /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents'
screen 18 '  kendex (🌳 ken-119) Opus 5 27% (brad@drovr.dev)     /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents'
# 22. THE fail-closed case. A codex screen whose final line is not a status
# line carries no reading, and the real status line above it is not searched
# out: a screen that does not end in its status line is a screen the reader
# cannot vouch for — caught mid-redraw, or with a dialog over the footer —
# and reporting the last figure it can find there is reporting a number from
# before whatever moved the line. %19 puts a real status line above a line
# that is not one; %20 gives that line a screen of its own.
screen 19 '  Codex is working
  Context 86% left
● Documentation: Context 60% used means compact now'
screen 20 '● Documentation: Context 60% used means compact now'
# 18, trailing half. The other end of the same fragment. Prose can put the
# sentence AFTER the status shape as easily as before it, and then the
# status-shaped PREFIX matches while the sentence it sits in never has to.
# The claude reading is the bottom-most match, so this screen puts that line
# below a real status line, which is where bottom-most would hand it the
# verdict. There is no codex sibling: a codex screen is read at the
# line it ends on, so what a sentence there is shaped like never comes up.
screen 21 '  kendex (🌳 ken-122) Opus 5 41% (brad@drovr.dev)     /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
/fake Opus 5 99% (work) is an example'
# 24. `[tui].status_line` is a real config key, and the items it draws behind
# the separator are not all working directories. %22 carries the one the
# committed captures do not: a model with its reasoning effort, two bare
# words. %23 carries four items at once — model, git branch, project name,
# codex version — because the key takes a list. A shape that judges what
# follows the separator refuses one or both of these, and a refused lane is
# an unmeasured lane, which the overseer never compacts.
screen 22 '  Context 100% left · gpt-6-astra default'
screen 23 '  Context 78% left · gpt-6-astra default · ken-885 · kendex · 0.151.0'
# 26. A codex pane with a dialog over its footer, and a claude status line in
# the transcript above — this fleet pastes both harnesses' screens into both
# harnesses' terminals, so that line is ordinary here. %24 has a real codex
# status line above the dialog and %25 has none, and the two must agree: the
# dialog is covering whatever the lane is showing now, so neither is a
# reading. Falling through to the claude shape answers with the wrong harness
# AND the wrong number, and finding the covered status line by searching past
# the dialog answers with a figure the lane has moved on from.
screen 24 '  Codex is working
  kendex (🌳 ken-125) Opus 5 35% (brad@drovr.dev)     /rc
  Context 86% left
  Press enter to continue'
screen 25 '  Codex is working
  kendex (🌳 ken-126) Opus 5 35% (brad@drovr.dev)     /rc
  Press enter to continue'
# 27. The same confusion the other way round. A claude pane whose final row
# quotes a codex status line is still a claude lane, and reading it as codex
# reports 14 used for a lane that is 41 used. Which harness a pane runs is the
# caller's to say; the screen cannot be asked.
screen 26 '  kendex (🌳 ken-127) Opus 5 41% (brad@drovr.dev)     /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
● A codex lane prints:
  Context 86% left'
# 6, both-shapes arm. A pane running a harness with no shape rule is offered
# both, and there the codex line on the final row still settles the reading:
# out of range, it is a refusal, not a reason to take the claude status line
# above it. That fall-through is unreachable on a codex pane, where the claude
# shape is never offered at all.
screen 27 '  kendex (🌳 ken-128) Opus 5 35% (brad@drovr.dev)     /rc
  Context 140% left'
# 28. A wrapped lane. Its pane command is `agent-confine`, which is what both
# harnesses exec through, so it names neither and both shapes are offered.
# %28 is a codex lane whose screen ends on its own status line: read for the
# claude shape alone it is a refusal, and an unmeasured lane is one the
# overseer never compacts. %29 holds the other half shut — a wrapped claude
# lane under an agent-row footer, which the codex shape cannot reach because
# that footer is what the screen ends on. %30 shows neither shape, and its
# refusal names both.
screen 28 '  Codex is working
  Context 86% left'
screen 29 '  kendex (🌳 ken-130) Opus 5 27% (brad@drovr.dev)     /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent
  ◯ dev-ken-885  Follow workflow: .agents/skills/dev/workflo… 4m 2s'
screen 30 'plain shell output with no harness status line'
screen 31 '  kendex (🌳 ken-132) Opus 5 35% (brad@drovr.dev)     /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
● Documentation: a status line reads kendex (🌳 ken-132) Opus 5 92% (brad@drovr.dev)     /rc'
screen 32 'plain shell output with no harness status line'
# 33. The handoff mark is an absolute token count, so the reading carries the
# percentage times the window the line names: 52% of `(1M context)` is
# 520000 tokens. A line naming no window (%1) carries no token figure, and
# the codex line never names one.
screen 33 '  kendex (🌳 ken-134) Fable 5.1 (1M context) 52% (brad@drovr.dev)     /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents'

OUT="$(run_ctx --json)"

# field JSON LANE EXPR — one field of the lane's record in JSON, or ABSENT.
field() { jq -r --arg l "$2" ".[] | select(.lane==\$l) | $3" <<<"$1" 2>/dev/null || echo UNPARSEABLE; }

# observe JSON LANE EXPECT — prints the lane's value of every `name=` field
# EXPECT names, in EXPECT's order: the record's fields (a missing key reads
# ABSENT, a JSON null reads null), and `detail~<text>` for whether the detail
# names <text> (`+` reads as a space): the detail is what the overseer acts
# on and which evidence refused the lane lives nowhere else.
observe() {
  local json="$1" lane="$2" got="" token name value needle
  for token in $3; do
    name="${token%%=*}"
    case "$name" in
      detail~*) needle="${name#detail~}"; value="$(field "$json" "$lane" '.detail // ""' | grep -qF -- "${needle//+/ }" && echo true || echo false)" ;;
      *) value="$(field "$json" "$lane" "if has(\"$name\") then .$name else \"ABSENT\" end")" ;;
    esac
    got="$got $name=$value"
  done
  printf '%s' "${got# }"
}

# lanes_table JSON ROW... — one assertion per lane row: `label|lane|expect`.
lanes_table() {
  local json="$1" row label lane expect
  shift
  for row in "$@"; do
    IFS='|' read -r label lane expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'lanes_table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    assert_eq "$(observe "$json" "$lane" "$expect")" "$expect" "$label"
  done
}

echo "=== the claude shape reports the share used, wherever the footer puts the line ==="
# Claude draws a row per running agent below its status line, so the reading
# is the bottom-most whole-line match: a repaint above it loses, a dotted
# version or a `(1M context)` parenthetical between the model and the
# percentage is read through, prose naming a model and a percentage is not a
# line, a status-shaped prefix with prose after it is not a line, a codex
# line quoted in a claude pane is not this lane's reading, and a per-account
# wrapper or the agent-confine launcher is still a measured claude pane.
lanes_table "$OUT" \
  "an orchestrating lane's real footer: the status line under agent rows reports used|ken-101|status=ok harness=claude context_used_pct=35" \
  "a line naming no window yields no token figure|ken-101|context_tokens=null" \
  "a 1M lane at 52% reads 520000 tokens: the percentage times the window the line names|ken-134|harness=claude context_used_pct=52 context_tokens=520000" \
  "a (1M context) parenthetical yields the token figure beside the percentage|ken-114|context_tokens=220000" \
  "the bottom-most reading wins over one repainted past|ken-103|context_used_pct=18" \
  "a (1M context) parenthetical between the model and the percentage is read through|ken-114|harness=claude context_used_pct=22" \
  "a dotted model version is read through, parenthetical and all|ken-115|harness=claude context_used_pct=12" \
  "a model and a percentage in prose above a line with no percentage is no reading|ken-111|status=no_status_line context_used_pct=null" \
  "prose carrying model, version and percentage below a real status line does not outrank it|ken-116|context_used_pct=35" \
  "a screen whose only model and percentage sit in prose carries no reading|ken-117|status=no_status_line context_used_pct=null" \
  "claude prose after a status-shaped prefix does not outrank the line above|ken-122|context_used_pct=41" \
  "prose ending in a complete status-shaped tail is not a line: the line starts with the project|ken-132|context_used_pct=35" \
  "a codex status line quoted on a claude pane's last row does not take the reading|ken-127|harness=claude context_used_pct=41" \
  "a per-account claude wrapper is a harness and its pane is measured|ken-119|status=ok context_used_pct=27" \
  "a wrapper pane with no status line is refused for the claude shape alone|ken-133|status=no_status_line detail~no+claude+status+line=true" \
  "a wrapped claude lane under an agent-row footer keeps its reading|ken-130|harness=claude context_used_pct=27" \
  "a screen with neither shape is no_status_line, never 0, refused for the shape it was read for|ken-104|status=no_status_line context_used_pct=null detail~no+claude+status+line=true"

echo "=== the codex shape is converted and read off the line the screen ends on ==="
# `Context N% left` is the share remaining and is converted; `used` is taken
# as it stands; the reading is the last non-empty row and nothing above it,
# so a dialog over the footer or a sentence on the last row is a refusal
# whatever sits higher, a claude-shaped line in a codex transcript included;
# whatever follows the separator is taken as it comes; a percentage over 100
# is not a context figure, on a pane offered both shapes too; the wrapper
# names no harness so a wrapped codex lane is measured.
lanes_table "$OUT" \
  "Context 86% left is 14 used, and names no window|ken-102|status=ok harness=codex context_used_pct=14 context_tokens=null" \
  "Context 40% used is taken as it stands|ken-106|harness=codex context_used_pct=40" \
  "whatever follows the separator is taken as it comes, a claude item included|ken-107|harness=codex context_used_pct=14" \
  "a percentage over 100 is not a context figure, and says what it checked|ken-108|status=no_status_line context_used_pct=null detail~does+not+end+in+a+valid+codex+context+figure=true" \
  "on a pane offered both shapes an out-of-range codex line refuses for both rather than falling through|ken-128|context_used_pct=null detail~neither+harness's+context+figure=true" \
  "a codex screen not ending in a status line carries no reading; the line above is not searched out|ken-120|status=no_status_line context_used_pct=null" \
  "a screen whose only context percentage sits in codex prose carries no reading|ken-121|status=no_status_line context_used_pct=null" \
  "a model with its reasoning effort behind the separator is a status item|ken-123|harness=codex context_used_pct=0" \
  "four configured items behind the separator are read like any other|ken-124|status=ok context_used_pct=22" \
  "a dialog over a codex footer with a claude line in the transcript is refused for codex, no harness named|ken-125|status=no_status_line context_used_pct=null harness=null detail~does+not+end+in+a+valid+codex+context+figure=true" \
  "the same pane with no covered codex line answers the same way|ken-126|status=no_status_line context_used_pct=null" \
  "a wrapped codex lane is read at the line its screen ends on|ken-129|harness=codex context_used_pct=14" \
  "a wrapped pane showing neither shape is refused for both|ken-131|detail~neither+harness's+context+figure=true"

echo "=== the pane's process, not its screen, decides whether it is measured ==="
lanes_table "$OUT" \
  "a pane that exited to its shell is not measured from what it left, and names the evidence|ken-109|status=no_status_line context_used_pct=null detail~exited+to+its+shell=true" \
  "a login shell is refused, dash and all, on the shell arm|ken-112|status=no_status_line context_used_pct=null detail~exited+to+its+shell=true" \
  "a second shell name is refused too|ken-113|status=no_status_line context_used_pct=null" \
  "a command that is neither shell nor harness is refused, naming the process|ken-118|status=no_status_line context_used_pct=null detail~running+less=true" \
  "a claim on another tmux server is unreadable, never the local pane's number|ken-110|status=unreadable context_used_pct=null detail~another+tmux+server=true" \
  "the account column names the lane the pane runs under|ken-103|account=eclaude"

echo "=== a pane that cannot be captured, a server that cannot be enumerated, a percentage near a model name ==="
write_claim five "%5" "$H/.claude" "ken-105"
UNREAD="$(run_ctx --json)"
rm -f "$STATE/claims/five.claim"
lanes_table "$UNREAD" \
  "a pane that cannot be captured is unreadable with no number|ken-105|status=unreadable context_used_pct=null"
NOSRV="$(run_ctx_on "$NO_SERVER" --json)"
lanes_table "$NOSRV" \
  "an unenumerable tmux server refuses a claim it would otherwise have measured, naming the enumeration|ken-101|status=unreadable detail~no+tmux+server+could+be+enumerated=true"
screen 4 '  kendex (🌳 ken-104) Opus 5 140% (brad@drovr.dev)     /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents'
OVER="$(run_ctx --json)"
screen 4 'plain shell output with no harness status line'
lanes_table "$OVER" \
  "a claude status line carrying a percentage over 100 is not a context figure|ken-104|status=no_status_line context_used_pct=null"

echo "=== the token figure is the multiplication, not the window ==="
# The must-fail control for the rows above: a copy of the library with the
# multiplication dropped reports the window itself, so a 52% lane reads as a
# full one. The mutant must differ from the source or the control proves
# nothing; the source parses the same screen to the multiplied figure.
MUTANT="$TMP_ROOT/mutant-lane-context.sh"
sed 's/int(used \* window \/ 100)/window/' "$SCRIPTS_DIR/lib/lane-context.sh" > "$MUTANT"
assert_eq "$(cmp -s "$MUTANT" "$SCRIPTS_DIR/lib/lane-context.sh" && echo same || echo differs)" "differs" "control: the mutant really drops the multiplication"
parse_screen() { # <lib> <pane number>
  "$BASH" -c 'source "$1"; lane_context_parse claude <"$2"' _ "$1" "$PANE_DIR/$2.screen" | cut -f3
}
assert_eq "$(parse_screen "$SCRIPTS_DIR/lib/lane-context.sh" 33)" "520000" "the source multiplies the percentage by the window"
assert_eq "$(parse_screen "$MUTANT" 33)" "1000000" "control: without the multiplication the same screen reads as the whole window"

echo "=== every committed codex capture parses to the figure on its screen ==="
# Real `tmux capture-pane` output from Codex 0.151.0, read by file so the
# blank rows a capture ends in reach the parser: in the four that carry a
# status line it is the last non-empty row; the two ending in a dialog over
# the footer carry no reading, never a zero.
FIXTURES="$TEST_DIR/fixtures/oversee-watch"
parse_fixture() { # <capture file name>
  "$BASH" -c 'source "$1"; lane_context_parse codex <"$2"' _ "$SCRIPTS_DIR/lib/lane-context.sh" "$FIXTURES/$1" || printf 'none\n'
}
for row in "codex-working.txt|codex,0," "codex-composer-draft.txt|codex,0," "codex-composer-idle.txt|codex,0," "codex-idle-after-turn.txt|codex,1," "codex-dialog-model.txt|none" "codex-dialog-trust.txt|none"; do
  IFS='|' read -r capture want <<<"$row"
  assert_eq "$(parse_fixture "$capture" | tr '\t' ',')" "$want" "$capture parses to its screen's figure"
done

echo "=== the table names the direction it reports, with and without column ==="
# A bare percentage column is read in whichever direction the reader last
# saw one, so the header and legend carry it; `column` is not one of orch's
# declared dependencies, so the render is driven with a PATH holding only
# what it needs and every row survives.
TABLE="$(run_ctx)"
NOCOL="$TMP_ROOT/nocol"; mkdir -p "$NOCOL"
for b in jq awk cat; do ln -s "$(command -v "$b")" "$NOCOL/$b"; done
RECS='[{"lane":"ken-101","pane":"%1","account":"drovr","config_dir":"/h/.claude","harness":"claude","context_used_pct":35,"context_tokens":null,"status":"ok","detail":null},{"lane":"ken-104","pane":"%4","account":"drovr","config_dir":"/h/.claude","harness":null,"context_used_pct":null,"context_tokens":null,"status":"no_status_line","detail":"x"}]'
NOCOL_OUT="$(PATH="$NOCOL" "$BASH" -c 'source "$1"; printf "%s" "$2" | lane_context_render' _ "$SCRIPTS_DIR/lib/lane-context.sh" "$RECS" 2>&1)" && nocol_rc=0 || nocol_rc=$?
assert_eq "$nocol_rc" "0" "the table renders without column installed"
HEADER='^LANE[[:space:]]+PANE[[:space:]]+ACCOUNT[[:space:]]+HARNESS[[:space:]]+CONTEXT_USED_PCT[[:space:]]+CONTEXT_TOKENS[[:space:]]+STATUS[[:space:]]*$'
# `label|table|regex` — a whole-line match, since the legend repeats the column name.
for row in \
  "the header carries the number column, in order|TABLE|$HEADER" \
  "a row carries the lane's number between its harness and its status, a dash for tokens where the line names no window|TABLE|^ken-101[[:space:]]+%1[[:space:]]+[^[:space:]]+[[:space:]]+claude[[:space:]]+35%[[:space:]]+-[[:space:]]+ok[[:space:]]*\$" \
  "a lane naming its window carries the token figure in its own column|TABLE|^ken-134[[:space:]]+%33[[:space:]]+[^[:space:]]+[[:space:]]+claude[[:space:]]+52%[[:space:]]+520000[[:space:]]+ok[[:space:]]*\$" \
  "an unmeasured lane's number columns are dashes, never zeros|TABLE|^ken-104[[:space:]]+%4[[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+-[[:space:]]+-[[:space:]]+no_status_line[[:space:]]*\$" \
  "the legend states which direction it reports|TABLE|CONSUMED" \
  "the legend names both codex spellings and which is converted|TABLE|LEFT or what is USED" \
  "the legend says what the token column is and when it is empty|TABLE|CONTEXT_TOKENS: that percent of the window the status line names" \
  "the column-less header is aligned with spaces, not a run of tabs|NOCOL_OUT|^LANE {2,}PANE {2,}ACCOUNT {2,}HARNESS {2,}CONTEXT_USED_PCT {2,}CONTEXT_TOKENS {2,}STATUS *\$" \
  "a measured lane keeps its row where column is missing|NOCOL_OUT|^ken-101[[:space:]]+%1[[:space:]]+drovr[[:space:]]+claude[[:space:]]+35%[[:space:]]+-[[:space:]]+ok[[:space:]]*\$" \
  "an unmeasured lane keeps its row too, dashes and all|NOCOL_OUT|^ken-104[[:space:]]+%4[[:space:]]+drovr[[:space:]]+-[[:space:]]+-[[:space:]]+-[[:space:]]+no_status_line[[:space:]]*\$" \
  "the legend survives the missing column too|NOCOL_OUT|CONSUMED"; do
  IFS='|' read -r label which re <<<"$row"
  assert_line "${!which}" "$re" "$label"
done

echo "=== an empty fleet says so; an unreadable store refuses ==="
rm -f "$STATE"/claims/*.claim
EMPTY="$(run_ctx)"
assert_contains "$EMPTY" "No live lane claims" "an empty fleet says so"
assert_eq "$(run_ctx --json | jq -r 'length')" "0" "an empty fleet is an empty array"
BROKEN_STATE="$TMP_ROOT/broken"
mkdir -p "$BROKEN_STATE"
: > "$BROKEN_STATE/claims"
LANES_HOME="$H" OVERSEE_WATCH_STATE_DIR="$BROKEN_STATE" TMUX_PANES_FILE="$PANES" PANE_DIR="$PANE_DIR" \
  PATH="$BIN:$PATH" "$LANES" context >/dev/null 2>"$TMP_ROOT/broken.err" && rc=0 || rc=$?
assert_eq "rc=$rc named=$(grep -qF 'refusing to report context' "$TMP_ROOT/broken.err" && echo yes || echo no)" "rc=1 named=yes" "an unreadable claim store refuses rather than reporting an empty fleet, and names what it refused"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
