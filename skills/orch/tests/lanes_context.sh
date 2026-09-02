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
# Where the status line SITS is pinned too, and the two harnesses put it in
# different places. Codex draws it LAST, so the codex reading comes from the
# final non-empty line and from no other. Claude draws a row per running
# agent BELOW its status line, so its footer has no bound and its reading is
# the bottom-most whole-line match. WHICH rule a pane gets comes from the
# pane's own foreground process, never from what is on the screen: this fleet
# pastes both harnesses' screens into both harnesses' terminals all day, and
# the panes here carry a process per case for that reason. Case 1's screen is
# a real `tmux capture-pane`; the other claude screens are built from real
# status lines. Cases hold each half shut, one per mutation:
#   case 1  an orchestrating lane's real footer, whose final line is an agent
#           row — dies the moment the claude reading is taken by position
#           too, or any bottom window narrower than the footer is taken off
#   case 14 a session with no percentage yet, under prose that names a model
#           and one — dies if the claude shape is loosened back to accepting
#           words between the model name and the percentage
#   case 18 prose naming a model and a percentage BELOW a real status line —
#           dies if a reading is a FRAGMENT of the status line rather than
#           the whole line, because bottom-most then hands the sentence the
#           verdict over the real line above it
#   case 22 a codex screen whose final line is not a status line, with a real
#           one above it — dies the moment the codex reading goes back to
#           searching the screen instead of reading the line it ends on
#   case 24 a configured status item that is not a working directory — dies
#           the moment the codex shape judges what follows the separator,
#           because no shape separates a configured item from a sentence
#   case 26 a codex pane on a dialog with a claude status line in its
#           transcript — dies the moment a codex pane can reach the claude
#           shape, which is the one way the fail-closed rule was bypassed
#   case 27 a claude pane quoting a codex status line on its final row —
#           dies the moment the harness is inferred from the screen instead
#           of taken from the pane
#   case 28 a codex lane whose pane command is the agent-confine wrapper —
#           dies the moment that wrapper is read as a harness spelling
#           instead of as the launcher both harnesses exec through
#   case 13 a pane that exited to its shell — dies if the liveness evidence
#           is dropped, which is the only thing a window ever stood in for
#
# Covered:
#   1. the claude shape reports its number as used, wherever the footer puts
#      the status line
#   2. the codex shape is converted, not reported raw, and is read off the
#      line the screen ends on, blank rows below it and all
#   3. the bottom-most claude reading wins over one repainted past
#   4. a screen with neither shape is no_status_line, never 0
#   5. a pane that cannot be captured is unreadable, never 0
#   6. a percentage over 100 is not a context figure, in either shape, and on
#      a pane offered both shapes a codex line carrying one settles the
#      reading rather than falling through to a claude match higher up
#   7. the table names the direction it reports, in its header and its rows
#   8. an empty fleet says so; an unreadable claim store refuses
#   9. the account column names the lane the pane runs under
#  10. a claim on ANOTHER tmux server is unreadable, never a local pane's
#      number under its name
#  11. codex's other status item, `Context 40% used`, is taken as it stands
#  12. whatever follows the codex separator is taken as it comes, a claude
#      status item included; the shape reads no further than the separator
#  13. a pane that has exited to its shell is not measured from what it left
#  14. a model and a percentage in prose is not a status line
#  15. an unenumerable tmux server refuses every claim, not just foreign ones
#  16. a login shell (`-bash`) and a second shell name are refused too, not
#      only the one name case 13 supplies
#  17. the model's dotted version and its `(1M context)` parenthetical both
#      sit between the model name and the percentage, and both parse
#  18. prose naming a model and a percentage below a real status line does
#      not outrank the line above it
#  19. a screen whose only model and percentage sit in prose is no reading
#  20. a pane running a command that is neither a shell nor a harness is
#      refused, and the refusal names the process it found
#  21. the per-account wrapper spellings the fleet launches through are
#      harnesses, and their panes are measured
#  22. a codex screen whose final line is not a status line carries no
#      reading, and the real status line above it is not searched out
#  23. the table still carries every row where `column` is not installed
#  24. the configured status items `[tui].status_line` draws are accepted,
#      one item or several, none of them a working directory
#  25. every committed codex capture parses to the figure on its screen
#  26. a codex pane that does not end in a codex status line carries no
#      reading, whatever its transcript holds, and says what it could not read
#  27. a claude pane is read by the claude shape however its screen ends
#  28. the agent-confine wrapper names no harness, so a pane running it is
#      offered both shapes and a wrapped codex lane is measured like any
#      other
#
# errexit is on: every case here either succeeds or is guarded, so an
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
  # reachable — the only place it still is.
  printf '%s %%27 pi\n' "$LIVE_PID"
  # 28. agent-confine is the launcher BOTH harnesses exec through, so its
  # pane command names neither and both shapes are offered. %28 is a wrapped
  # codex lane, %29 a wrapped claude one, %30 a wrapped pane showing neither.
  for n in 28 29 30; do printf '%s %%%s agent-confine\n' "$LIVE_PID" "$n"; done
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
# The foreign lane's pane NUMBER exists here too, on a screen that parses
# cleanly: %1 is ken-101's, reading 35.
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
# version in the version slot; both spellings run on this fleet right now.
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
# verdict. There is no codex sibling any more: a codex screen is read at the
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
screen 22 '  Context 100% left · gpt-5.6-sol default'
screen 23 '  Context 78% left · gpt-5.6-sol default · ken-885 · kendex · 0.151.0'
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

OUT="$(run_ctx --json)"

# 1. The claude shape carries the share USED, and is reported as it stands —
# from under a footer no line count would have cleared.
assert_eq "$(jq -r '.[] | select(.lane=="ken-101") | .context_used_pct' <<<"$OUT")" "35" \
  "the claude status line reports its number as used, under an agent-row footer"
assert_eq "$(jq -r '.[] | select(.lane=="ken-101") | .harness' <<<"$OUT")" "claude" \
  "the matched shape names the harness, with nothing recorded in advance"
assert_eq "$(jq -r '.[] | select(.lane=="ken-101") | .status' <<<"$OUT")" "ok" \
  "a measured lane is ok"

# 2. THE conversion. `Context 86% left` is a nearly EMPTY context; reported
# raw it is the fullest lane in the fleet and the overseer compacts the wrong
# one. The screen ends in blank rows, as a real capture does, so this also
# holds the codex reading to the last NON-EMPTY line.
assert_eq "$(jq -r '.[] | select(.lane=="ken-102") | .context_used_pct' <<<"$OUT")" "14" \
  "the codex status line is converted from remaining to used"
assert_eq "$(jq -r '.[] | select(.lane=="ken-102") | .status' <<<"$OUT")" "ok" \
  "blank rows below the status line do not cost the lane its reading"
assert_eq "$(jq -r '.[] | select(.lane=="ken-102") | .harness' <<<"$OUT")" "codex" \
  "the codex shape names the codex harness"

# 3. A pane keeps the render it repainted over: the status line is the
# bottom-most reading, and an earlier one is the same lane before it
# compacted.
assert_eq "$(jq -r '.[] | select(.lane=="ken-103") | .context_used_pct' <<<"$OUT")" "18" \
  "the bottom-most reading wins over one repainted past"

# 11. Codex's status item is user-configured and the binary ships both
# spellings; a lane running the `used` one was measured by neither branch.
assert_eq "$(jq -r '.[] | select(.lane=="ken-106") | .context_used_pct' <<<"$OUT")" "40" \
  "the codex used shape is taken as it stands, not converted"
assert_eq "$(jq -r '.[] | select(.lane=="ken-106") | .harness' <<<"$OUT")" "codex" \
  "the codex used shape names the codex harness"

# 12. The shape reads no further than the separator, so what sits past it is
# taken as it comes — here a claude status item, which no codex config draws
# and which the reader therefore has no business judging. The line still opens
# with the codex context item, and that is what the reading is taken from.
assert_eq "$(jq -r '.[] | select(.lane=="ken-107") | .context_used_pct' <<<"$OUT")" "14" \
  "whatever follows the codex separator is taken as it comes"
assert_eq "$(jq -r '.[] | select(.lane=="ken-107") | .harness' <<<"$OUT")" "codex" \
  "the context item at the line's opening is what names the harness"

# 6 (codex arm). Over 100 is not a context figure in either shape: unguarded,
# the conversion turns 140 left into -40 used. %27 is the same line on a pane
# whose harness has no shape rule, where both shapes ARE offered: the claude
# status line above it is what a fall-through would report instead, 35, from a
# line the screen does not end on.
assert_eq "$(jq -r '.[] | select(.lane=="ken-108") | .status' <<<"$OUT")" "no_status_line" \
  "a codex percentage over 100 is not read as a context figure"
assert_eq "$(jq -r '.[] | select(.lane=="ken-108") | .context_used_pct' <<<"$OUT")" "null" \
  "an out-of-range codex reading carries no number"
assert_contains "$(jq -r '.[] | select(.lane=="ken-108") | .detail' <<<"$OUT")" "does not end in a valid codex context figure" \
  "the refusal states what it checked, on the pane whose figure nothing is covering"
assert_eq "$(jq -r '.[] | select(.lane=="ken-128") | .context_used_pct' <<<"$OUT")" "null" \
  "an out-of-range codex line refuses rather than falling through to a match above it"

# 13. The pane exited to its shell. Its last render is still on the screen and
# is not a measurement of anything: what refuses it is the foreground process
# tmux reports, not how far up the screen the reading sits.
assert_eq "$(jq -r '.[] | select(.lane=="ken-109") | .status' <<<"$OUT")" "no_status_line" \
  "a pane that exited to its shell is not measured from what it left"
assert_eq "$(jq -r '.[] | select(.lane=="ken-109") | .context_used_pct' <<<"$OUT")" "null" \
  "an exited pane carries no number"
assert_contains "$(jq -r '.[] | select(.lane=="ken-109") | .detail' <<<"$OUT")" "exited to its shell" \
  "the refusal names the evidence it acted on"

# 16. The dash a login shell carries is stripped before the name is matched,
# and the list holds more than the one name case 13 drives. Each of these
# panes left a readable status line behind, so a lapse in either reports 44
# or 55 for a lane that is running nothing.
assert_eq "$(jq -r '.[] | select(.lane=="ken-112") | .status' <<<"$OUT")" "no_status_line" \
  "a pane at a login shell is refused, dash and all"
assert_eq "$(jq -r '.[] | select(.lane=="ken-112") | .context_used_pct' <<<"$OUT")" "null" \
  "a login-shell pane carries no number, not the one left on its screen"
assert_eq "$(jq -r '.[] | select(.lane=="ken-113") | .status' <<<"$OUT")" "no_status_line" \
  "a second shell name from the list is refused too"
assert_eq "$(jq -r '.[] | select(.lane=="ken-113") | .context_used_pct' <<<"$OUT")" "null" \
  "that pane carries no number either"

# 17. The version slot and the parenthetical. A lane on a 1M-context session,
# or on a point-release model, is measured like any other; unmatched, it
# leaves the report entirely and never gets compacted.
assert_eq "$(jq -r '.[] | select(.lane=="ken-114") | .context_used_pct' <<<"$OUT")" "22" \
  "a parenthetical between the model name and the percentage is read through"
assert_eq "$(jq -r '.[] | select(.lane=="ken-114") | .harness' <<<"$OUT")" "claude" \
  "that line still names the claude harness"
assert_eq "$(jq -r '.[] | select(.lane=="ken-115") | .context_used_pct' <<<"$OUT")" "12" \
  "a dotted model version is read through, parenthetical and all"
assert_eq "$(jq -r '.[] | select(.lane=="ken-115") | .harness' <<<"$OUT")" "claude" \
  "that line names the claude harness too"

# 14. Prose names a model and a percentage with words between them; the
# status line below it names a model and no percentage at all. Neither is a
# reading, and the pane is live, so no distance rule separates them.
assert_eq "$(jq -r '.[] | select(.lane=="ken-111") | .status' <<<"$OUT")" "no_status_line" \
  "a model and a percentage in prose is not a status line"
assert_eq "$(jq -r '.[] | select(.lane=="ken-111") | .context_used_pct' <<<"$OUT")" "null" \
  "a session with no percentage yet carries no number, not the prose's"

# 18 and 19. Prose carries the model, the version and the percentage in the
# order the status line does — the fragment, not the line. ken-116 puts that
# sentence under a real status line, where the bottom-most rule hands it the
# verdict and the lane reports 92 for a lane that is at 35; ken-117 has
# nothing else on its screen at all.
assert_eq "$(jq -r '.[] | select(.lane=="ken-116") | .context_used_pct' <<<"$OUT")" "35" \
  "prose below a status line does not outrank the status line above it"
assert_eq "$(jq -r '.[] | select(.lane=="ken-117") | .status' <<<"$OUT")" "no_status_line" \
  "a screen whose only model and percentage sit in prose carries no reading"
assert_eq "$(jq -r '.[] | select(.lane=="ken-117") | .context_used_pct' <<<"$OUT")" "null" \
  "that lane carries no number, not the sentence's"

# 20. The harness is gone and something that is not a shell is running in its
# pane. A not-a-shell test admits less, vim and git log alike, and reports the
# 66 still painted on this screen as the lane's current context use.
assert_eq "$(jq -r '.[] | select(.lane=="ken-118") | .status' <<<"$OUT")" "no_status_line" \
  "a pane running a command that is not a harness is not measured"
assert_eq "$(jq -r '.[] | select(.lane=="ken-118") | .context_used_pct' <<<"$OUT")" "null" \
  "that pane carries no number, not the one left on its screen"
assert_contains "$(jq -r '.[] | select(.lane=="ken-118") | .detail' <<<"$OUT")" "running less" \
  "the refusal names the process it found"

# 21. The fleet launches Claude through a per-account wrapper, and tmux may
# name the pane after it. A list holding only the bare binary names drops
# every lane on this machine out of the report.
assert_eq "$(jq -r '.[] | select(.lane=="ken-119") | .context_used_pct' <<<"$OUT")" "27" \
  "a pane running a per-account claude wrapper is measured like any other"
assert_eq "$(jq -r '.[] | select(.lane=="ken-119") | .status' <<<"$OUT")" "ok" \
  "that lane is ok, not a refusal"

# 22. THE fail-closed case. %19 ends in a line that is not a status line and
# carries a real one above it: the reading is refused rather than searched
# out, because a screen that does not end in its status line is one the reader
# cannot vouch for. %20 is the same line with nothing above it. Both are
# no_status_line, and the moment the codex reading goes back to searching the
# screen, %19 reports 14 from a line the screen has moved past.
assert_eq "$(jq -r '.[] | select(.lane=="ken-120") | .status' <<<"$OUT")" "no_status_line" \
  "a codex screen not ending in a status line carries no reading"
assert_eq "$(jq -r '.[] | select(.lane=="ken-120") | .context_used_pct' <<<"$OUT")" "null" \
  "the status line above it is not searched out"
assert_eq "$(jq -r '.[] | select(.lane=="ken-121") | .status' <<<"$OUT")" "no_status_line" \
  "a screen whose only context percentage sits in codex prose carries no reading"
assert_eq "$(jq -r '.[] | select(.lane=="ken-121") | .context_used_pct' <<<"$OUT")" "null" \
  "that lane carries no number, not the sentence's"

# 18, trailing half. A status-shaped PREFIX with prose after it. The claude
# line ends in its account and claude's own right-hand hint, and admits no
# sentence past either, so the real status line above keeps the verdict.
assert_eq "$(jq -r '.[] | select(.lane=="ken-122") | .context_used_pct' <<<"$OUT")" "41" \
  "claude prose after a status-shaped prefix does not outrank the status line above it"

# 24. The configured status items. `gpt-5.6-sol default` is two bare words
# and so is `compact now`, so no shape tells them apart — and a shape that
# refuses the one it has not seen leaves that lane unmeasured, which is the
# lane the overseer then never compacts. Position is what refuses prose, so
# these are accepted: one item, and the four a list config draws.
assert_eq "$(jq -r '.[] | select(.lane=="ken-123") | .context_used_pct' <<<"$OUT")" "0" \
  "a model with its reasoning effort is a status item, not a sentence"
assert_eq "$(jq -r '.[] | select(.lane=="ken-123") | .harness' <<<"$OUT")" "codex" \
  "that lane is measured rather than left out of the report"
assert_eq "$(jq -r '.[] | select(.lane=="ken-124") | .context_used_pct' <<<"$OUT")" "22" \
  "a status line carrying four configured items is read like any other"
assert_eq "$(jq -r '.[] | select(.lane=="ken-124") | .status' <<<"$OUT")" "ok" \
  "several items behind the separator are not a reason to refuse the lane"

# 26. THE fail-closed rule, held shut against the one thing that bypassed it:
# a claude-shaped line in a codex pane's transcript. The claude shape is not
# offered on a codex pane at all, so both screens refuse — the one whose
# status line the dialog covers and the one that has none. Bottom-most
# recovered the covered line and answered 14; the claude fallback answered
# claude 35. Neither is what the lane is showing.
assert_eq "$(jq -r '.[] | select(.lane=="ken-125") | .status' <<<"$OUT")" "no_status_line" \
  "a dialog over a codex footer is could-not-tell, not the status line it covers"
assert_eq "$(jq -r '.[] | select(.lane=="ken-125") | .context_used_pct' <<<"$OUT")" "null" \
  "a claude-shaped line in a codex pane's transcript is not a reading"
assert_eq "$(jq -r '.[] | select(.lane=="ken-125") | .harness' <<<"$OUT")" "null" \
  "and it does not put the wrong harness in the report either"
assert_eq "$(jq -r '.[] | select(.lane=="ken-126") | .status' <<<"$OUT")" "no_status_line" \
  "the same pane with no codex status line at all answers the same way"
assert_eq "$(jq -r '.[] | select(.lane=="ken-126") | .context_used_pct' <<<"$OUT")" "null" \
  "the two halves agree rather than differing by what sits above the dialog"
assert_contains "$(jq -r '.[] | select(.lane=="ken-125") | .detail' <<<"$OUT")" "does not end in a valid codex context figure" \
  "the refusal names what it could not read, not a missing figure of either shape"

# 27. And the same confusion in the other direction. A codex status line
# quoted in a claude pane's transcript is not this lane's reading, whatever
# row it lands on.
assert_eq "$(jq -r '.[] | select(.lane=="ken-127") | .context_used_pct' <<<"$OUT")" "41" \
  "a codex status line quoted on a claude pane does not take the lane's reading"
assert_eq "$(jq -r '.[] | select(.lane=="ken-127") | .harness' <<<"$OUT")" "claude" \
  "the pane's own harness is what names the reading"

# 28. The wrapper is not a harness spelling. Dispatched to the claude shape
# alone, %28's perfectly good final row is a refusal and the lane goes
# unmeasured — the outcome this reader exists to prevent, on the one pane
# command a codex lane is as likely to present as a claude one. %29 is what
# offering both shapes must not cost: the codex shape only ever sees the last
# row, and a claude footer sits below the status line, so the wrapped claude
# lane keeps its reading.
assert_eq "$(jq -r '.[] | select(.lane=="ken-129") | .context_used_pct' <<<"$OUT")" "14" \
  "a wrapped codex lane is read at the line its screen ends on"
assert_eq "$(jq -r '.[] | select(.lane=="ken-129") | .harness' <<<"$OUT")" "codex" \
  "the wrapper names no harness; the shape that matched does"
assert_eq "$(jq -r '.[] | select(.lane=="ken-130") | .context_used_pct' <<<"$OUT")" "27" \
  "a wrapped claude lane keeps its reading from under the agent-row footer"
assert_eq "$(jq -r '.[] | select(.lane=="ken-130") | .harness' <<<"$OUT")" "claude" \
  "and is still named claude"
assert_contains "$(jq -r '.[] | select(.lane=="ken-131") | .detail' <<<"$OUT")" "neither harness's context figure" \
  "a wrapped pane showing neither shape is refused for both, not for claude alone"

# 25. Every committed codex capture, parsed as it stands. These are real
# `tmux capture-pane` output from Codex 0.151.0 (KEN-863), and they are the
# evidence the position rule rests on: in all four that carry a status line
# it is the last non-empty row, blank rows below it and nothing else. The
# other two end in a dialog drawn over the footer, and a reader that searched
# the screen would report the figure that dialog is covering. A capture whose
# screen carries no status line is a refusal, never a zero.
FIXTURES="$TEST_DIR/fixtures/oversee-watch"

parse_fixture() { # <capture file name>
  "$BASH" -c 'source "$1"; lane_context_parse codex <"$2"' _ \
    "$SCRIPTS_DIR/lib/lane-context.sh" "$FIXTURES/$1" || printf 'none\n'
}

assert_eq "$(parse_fixture codex-working.txt)" "$(printf 'codex\t0')" \
  "the working capture reads 100% left as a context with nothing used"
assert_eq "$(parse_fixture codex-composer-draft.txt)" "$(printf 'codex\t0')" \
  "the composer-draft capture parses to the figure on its screen"
assert_eq "$(parse_fixture codex-composer-idle.txt)" "$(printf 'codex\t0')" \
  "the composer-idle capture parses to the figure on its screen"
assert_eq "$(parse_fixture codex-idle-after-turn.txt)" "$(printf 'codex\t1')" \
  "the idle-after-turn capture converts 99% left to 1 used"
assert_eq "$(parse_fixture codex-dialog-model.txt)" "none" \
  "a capture whose dialog covers the status line carries no reading"
assert_eq "$(parse_fixture codex-dialog-trust.txt)" "none" \
  "the trust-dialog capture carries no reading either"

# 10. `capture-pane -t %N` answers from THIS server only, and pane ids restart
# at %0 on each one. ken-110 claims %1 on another server; %1 here is ken-101's
# pane, reading 35. Measured against it, the foreign lane reports 35 as its
# own.
assert_eq "$(jq -r '.[] | select(.lane=="ken-110") | .status' <<<"$OUT")" "unreadable" \
  "a claim on another tmux server is unreadable"
assert_eq "$(jq -r '.[] | select(.lane=="ken-110") | .context_used_pct' <<<"$OUT")" "null" \
  "a foreign-server claim carries no number, not the local pane's"
assert_contains "$(jq -r '.[] | select(.lane=="ken-110") | .detail' <<<"$OUT")" "another tmux server" \
  "the foreign-server refusal names what it could not reach"

# 4 and 5. Neither absence is a measurement: an unmeasured lane reported as 0
# reads as a lane with the whole window free.
assert_eq "$(jq -r '.[] | select(.lane=="ken-104") | .status' <<<"$OUT")" "no_status_line" \
  "a screen with neither shape is no_status_line"
assert_eq "$(jq -r '.[] | select(.lane=="ken-104") | .context_used_pct' <<<"$OUT")" "null" \
  "a lane with no status line carries no number"
assert_contains "$(jq -r '.[] | select(.lane=="ken-104") | .detail' <<<"$OUT")" "no claude status line" \
  "the refusal names the shape that pane was read for, not both shapes"

write_claim five "%5" "$H/.claude" "ken-105"
UNREAD="$(run_ctx --json)"
assert_eq "$(jq -r '.[] | select(.lane=="ken-105") | .status' <<<"$UNREAD")" "unreadable" \
  "a pane that cannot be captured is unreadable"
assert_eq "$(jq -r '.[] | select(.lane=="ken-105") | .context_used_pct' <<<"$UNREAD")" "null" \
  "an uncapturable pane carries no number"
rm -f "$STATE/claims/five.claim"

# 15. Nothing enumerated at all is a different refusal from a pane on a server
# this one can see but does not own: no pane id resolves, so measuring ANY
# claim against a local screen would be the same fabrication. Without its own
# fixture the branch is invisible — the foreign-server case above drives only
# the mismatch arm.
NOSRV="$(run_ctx_on "$NO_SERVER" --json)"
assert_eq "$(jq -r '.[] | select(.lane=="ken-101") | .status' <<<"$NOSRV")" "unreadable" \
  "an unenumerable tmux server refuses a claim it would otherwise have measured"
assert_contains "$(jq -r '.[] | select(.lane=="ken-101") | .detail' <<<"$NOSRV")" "no tmux server could be enumerated" \
  "the empty-enumeration refusal names the enumeration, not a foreign server"

# 6. A percent sign near a model name is not automatically a context figure.
screen 4 'Opus 5 finished 140% of the plan'
OVER="$(run_ctx --json)"
assert_eq "$(jq -r '.[] | select(.lane=="ken-104") | .context_used_pct' <<<"$OVER")" "null" \
  "a percentage over 100 is not read as a context figure"
screen 4 'plain shell output with no harness status line'

# 7. The direction is part of the output. A bare percentage column is read in
# whichever direction the reader last saw one.
TABLE="$(run_ctx)"
assert_line "$TABLE" \
  '^LANE[[:space:]]+PANE[[:space:]]+ACCOUNT[[:space:]]+HARNESS[[:space:]]+CONTEXT_USED_PCT[[:space:]]+STATUS[[:space:]]*$' \
  "the table header carries the number column, in order"
assert_line "$TABLE" \
  '^ken-101[[:space:]]+%1[[:space:]]+[^[:space:]]+[[:space:]]+claude[[:space:]]+35%[[:space:]]+ok[[:space:]]*$' \
  "a table row carries the lane's number between its harness and its status"
assert_line "$TABLE" \
  '^ken-104[[:space:]]+%4[[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+-[[:space:]]+no_status_line[[:space:]]*$' \
  "an unmeasured lane's number column is a dash, never a zero"
assert_contains "$TABLE" "CONSUMED" "the table legend states which direction it reports"
assert_contains "$TABLE" "LEFT or what is USED" \
  "the legend names both codex spellings, and which one is converted"

# 23. `column` is util-linux, not one of orch's declared dependencies (jq,
# bash 3.2, flock), and installations that satisfy those ship without it.
# Piping the table into a missing command loses every row under errexit, and
# a fleet report with no lanes reads as a fleet with nothing to compact. The
# render is driven directly here: PATH holds only what the render itself
# needs, so the absence is real rather than stubbed.
NOCOL="$TMP_ROOT/nocol"; mkdir -p "$NOCOL"
for b in jq awk cat; do ln -s "$(command -v "$b")" "$NOCOL/$b"; done
RECS='[{"lane":"ken-101","pane":"%1","account":"drovr","config_dir":"/h/.claude","harness":"claude","context_used_pct":35,"status":"ok","detail":null},{"lane":"ken-104","pane":"%4","account":"drovr","config_dir":"/h/.claude","harness":null,"context_used_pct":null,"status":"no_status_line","detail":"x"}]'
NOCOL_OUT="$(PATH="$NOCOL" "$BASH" -c 'source "$1"; printf "%s" "$2" | lane_context_render' _ \
  "$SCRIPTS_DIR/lib/lane-context.sh" "$RECS" 2>&1)" && nocol_rc=0 || nocol_rc=$?
assert_eq "$nocol_rc" "0" "the table renders without column installed"
assert_line "$NOCOL_OUT" \
  '^LANE[[:space:]]+PANE[[:space:]]+ACCOUNT[[:space:]]+HARNESS[[:space:]]+CONTEXT_USED_PCT[[:space:]]+STATUS[[:space:]]*$' \
  "the column-less header is aligned, not a run of tabs"
assert_line "$NOCOL_OUT" \
  '^ken-101[[:space:]]+%1[[:space:]]+drovr[[:space:]]+claude[[:space:]]+35%[[:space:]]+ok[[:space:]]*$' \
  "a measured lane keeps its row where column is missing"
assert_line "$NOCOL_OUT" \
  '^ken-104[[:space:]]+%4[[:space:]]+drovr[[:space:]]+-[[:space:]]+-[[:space:]]+no_status_line[[:space:]]*$' \
  "an unmeasured lane keeps its row too, dashes and all"
assert_contains "$NOCOL_OUT" "CONSUMED" "the legend survives the missing column too"

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
