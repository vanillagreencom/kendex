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
# Where the status line SITS is pinned too, and by property rather than by
# count. Case 1's screen is a real `tmux capture-pane`; the other claude
# screens are built from real status lines. The footer under a status line
# grows by a row per running agent, so no line count reaches an
# orchestrating lane's. Four cases hold that shut, each against a different
# mutation:
#   case 1  an orchestrating lane's real footer — dies the moment any bottom
#           window narrower than it is taken off the screen
#   case 14 a session with no percentage yet, under prose that names a model
#           and one — dies if the claude shape is loosened back to accepting
#           words between the model name and the percentage
#   case 18 prose naming a model and a percentage BELOW a real status line —
#           dies if a reading is a FRAGMENT of the status line rather than
#           the whole line, because bottom-most then hands the sentence the
#           verdict over the real line above it
#   case 22 the same sentence in the CODEX shape, which carries its fragment
#           in ordinary prose about compaction — dies the moment the codex
#           branch is loosened back to matching anywhere in a line
#   case 24 the same sentence two words long — dies the moment the codex
#           trailing item is admitted by token COUNT rather than by shape,
#           which is how `compact now` passed for a status item
#   case 13 a pane that exited to its shell — dies if the liveness evidence
#           is dropped, which is the only thing a window ever stood in for
#
# Covered:
#   1. the claude shape reports its number as used, wherever the footer puts
#      the status line
#   2. the codex shape is converted, not reported raw
#   3. the bottom-most reading wins over one repainted past
#   4. a screen with neither shape is no_status_line, never 0
#   5. a pane that cannot be captured is unreadable, never 0
#   6. a percentage over 100 is not a context figure, in either shape
#   7. the table names the direction it reports, in its header and its rows
#   8. an empty fleet says so; an unreadable claim store refuses
#   9. the account column names the lane the pane runs under
#  10. a claim on ANOTHER tmux server is unreadable, never a local pane's
#      number under its name
#  11. codex's other status item, `Context 40% used`, is taken as it stands
#  12. a claude status item behind the codex separator is not a codex
#      status line; the codex status item carries a path and nothing else
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
#  22. a codex context fragment in prose is not a status line, alone or
#      below a real one
#  23. the table still carries every row where `column` is not installed
#  24. two words behind the codex separator are prose, not a status item
#  25. every committed codex capture parses to the figure on its screen
#
# errexit is on: every case here either succeeds or is guarded, so an
# unexpected non-zero is a broken fixture, not a finding to print past.
set -euo pipefail

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
  for n in 1 2 3 4 5 10 13 14 15 16 21; do printf '%s %%%s claude\n' "$LIVE_PID" "$n"; done
  for n in 6 7 8 19 20 22 23; do printf '%s %%%s codex\n' "$LIVE_PID" "$n"; done
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
screen 2 '  Codex is working
  Context 86% left'
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
# 22. The codex sibling of 18 and 19. The compaction rule is written about
# in the terminal it governs, so `Context <N>% used` turns up in ordinary
# transcript prose — and a fragment match hands that sentence the verdict
# over the real status line above it, exactly as the claude fragment did.
# %19 puts the sentence BELOW a real codex status line; %20 gives it a
# screen of its own.
screen 19 '  Codex is working
  Context 86% left
● Documentation: Context 60% used means compact now'
screen 20 '● Documentation: Context 60% used means compact now'
# 22, trailing half. The other end of the same fragment. Prose can put the
# sentence AFTER the status shape as easily as before it, and then the
# status-shaped PREFIX matches while the sentence it sits in never has to. Both
# screens put that line BELOW a real status line, which is where bottom-most
# hands it the verdict.
screen 21 '  kendex (🌳 ken-122) Opus 5 41% (brad@drovr.dev)     /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
/fake Opus 5 99% (work) is an example'
screen 22 '  Context 86% left
● Context 77% used means compact now
● Context 77% used · and that is an example'
# 24. The reproduction from KEN-885, and the shortest sentence of the class:
# two words behind the separator. A trailing item admitted by token COUNT
# takes `compact now` for a status item, and bottom-most then reports 60 used
# for a lane that is 14 used — the overseer compacts the emptiest lane in the
# fleet and skips the full one. Codex puts its working directory behind that
# separator, so the item is matched by that shape and a sentence of any
# length fails it.
screen 23 'Context 86% left
Context 60% used · compact now'

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
# one.
assert_eq "$(jq -r '.[] | select(.lane=="ken-102") | .context_used_pct' <<<"$OUT")" "14" \
  "the codex status line is converted from remaining to used"
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

# 12. `Opus 5 41%` is a claude status item, and behind the codex separator it
# is not a status line of either harness: codex draws its working directory
# there and nothing else, and the claude shape needs an account parenthetical
# this line has none of. A trailing item admitted by token count took it for a
# codex reading, which is the same allowance `compact now` walked through.
assert_eq "$(jq -r '.[] | select(.lane=="ken-107") | .status' <<<"$OUT")" "no_status_line" \
  "a claude status item behind the codex separator is not a codex status line"
assert_eq "$(jq -r '.[] | select(.lane=="ken-107") | .context_used_pct' <<<"$OUT")" "null" \
  "that lane carries no number, not the one that shape carried"

# 6 (codex arm). Over 100 is not a context figure in either shape: unguarded,
# the conversion turns 140 left into -40 used.
assert_eq "$(jq -r '.[] | select(.lane=="ken-108") | .status' <<<"$OUT")" "no_status_line" \
  "a codex percentage over 100 is not read as a context figure"
assert_eq "$(jq -r '.[] | select(.lane=="ken-108") | .context_used_pct' <<<"$OUT")" "null" \
  "an out-of-range codex reading carries no number"

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

# 22. A codex reading is the whole line too. Below a real status line the
# sentence wins on bottom-most and the lane reports 60 used for a lane that
# is 14 used; on a screen of its own it is a reading invented out of prose.
assert_eq "$(jq -r '.[] | select(.lane=="ken-120") | .context_used_pct' <<<"$OUT")" "14" \
  "codex prose below a status line does not outrank the status line above it"
assert_eq "$(jq -r '.[] | select(.lane=="ken-121") | .status' <<<"$OUT")" "no_status_line" \
  "a screen whose only context percentage sits in codex prose carries no reading"
assert_eq "$(jq -r '.[] | select(.lane=="ken-121") | .context_used_pct' <<<"$OUT")" "null" \
  "that lane carries no number, not the sentence's"

# 22, trailing half. A status-shaped PREFIX with prose after it. The claude
# line ends in its account and claude's own right-hand hint; the codex line
# ends in its context item or a working directory behind a separator. Neither
# end admits a sentence, so the real status line above keeps the verdict.
assert_eq "$(jq -r '.[] | select(.lane=="ken-122") | .context_used_pct' <<<"$OUT")" "41" \
  "claude prose after a status-shaped prefix does not outrank the status line above it"
assert_eq "$(jq -r '.[] | select(.lane=="ken-123") | .context_used_pct' <<<"$OUT")" "14" \
  "codex prose after a status-shaped prefix does not outrank the status line above it"

# 24. The reproduction from KEN-885. Two words behind the separator is the
# shortest sentence of this class and the one a token count cannot refuse:
# the lane has 14 used and the report called it 60, so the overseer compacted
# the emptiest lane in the fleet and left the full one running.
assert_eq "$(jq -r '.[] | select(.lane=="ken-124") | .context_used_pct' <<<"$OUT")" "14" \
  "two words behind the codex separator are prose, not a status item"
assert_eq "$(jq -r '.[] | select(.lane=="ken-124") | .harness' <<<"$OUT")" "codex" \
  "the real status line above keeps the verdict, and the harness with it"

# 25. Every committed codex capture, parsed as it stands. These are real
# `tmux capture-pane` output from Codex 0.151.0 (KEN-863), so what the reader
# anchors to is what the harness draws: `Context <N>% left`, a separator, and
# the session's working directory, ellipsised where the width ran out. A
# capture whose screen carries no status line is a refusal, never a zero.
FIXTURES="$TEST_DIR/fixtures/oversee-watch"

parse_fixture() { # <capture file name>
  "$BASH" -c 'source "$1"; lane_context_parse <"$2"' _ \
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
