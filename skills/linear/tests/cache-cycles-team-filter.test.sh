#!/usr/bin/env bash
# cache cycles list --team (KEN-1150).
#
# `--team` was consumed and discarded here — `--team) shift 2 ;;` — so the flag
# was accepted at rc 0 and did nothing. Every cycle in the cache came back, and
# the type selection then worked off that unfiltered set: on a cache holding
# more than one team, `--team X --type current` could answer with another
# team's cycle while naming X.
#
# `cache labels list` already carries the same one-line `.team.name` filter;
# this locks the cycles side to it, and locks what filtering first requires of
# the type selection:
#   A. --team returns only that team's cycles.
#   B. The filter runs BEFORE the type selection. current and upcoming pick one
#      cycle out of whatever set they are handed and past cuts at the working
#      cycle's start, so filtering after the selection answers for the wrong
#      team either way.
#   C. No --team still returns every team's cycles.
#   D. Both no-working-cycle fallbacks answer by date. Filtering first makes
#      them reachable per team — a team between cycles, or whose running cycle
#      already hit progress 1, has none started-and-incomplete while another
#      team does — and positionally they returned the OLDEST cycle for upcoming
#      and the whole set for past, reporting a future cycle as past.
#   E. The inline `--team=X` spelling filters too, the spelling this same
#      function already accepts for --format.
#
# Fully offline — pure cache read, no curl needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

# GIT_DIR outranks -C, so where it is inherited `git -C "$TMP_ROOT" init` below
# re-inits the ambient repository and leaves no fixture repo at all. Git sets it
# for a hook run in a linked worktree; a hook in the main checkout gets
# GIT_INDEX_FILE instead. Reaching the developer's real cache needs GIT_WORK_TREE
# or core.worktree inherited as well, so all four go, which is the house rule in
# .claude/CLAUDE.md. Unsetting at suite scope covers git and the CLI alike.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/.cache/linear"
# common.sh resolves PROJECT_ROOT through git rev-parse, so the fixture needs a
# repository of its own for that to land inside this scratch root.
git -C "$TMP_ROOT" init -q -b main
# Proof the isolation held. Without the unset the line above re-inits the
# ambient repository and leaves no fixture repo behind, and a run that goes on
# from there is reading somewhere nobody sandboxed, so this stops the suite
# rather than recording a failure and continuing.
if [[ ! -d "$TMP_ROOT/.git" ]]; then
  assert_stop "the fixture repository is the one git init created" \
    "no repository at $TMP_ROOT/.git: a git environment variable redirected git init"
fi

# This root's own cache is the subject, so it replaces the assert lib's default
# sandbox — still scratch, so the exit verdict's containment check holds.
export LINEAR_CACHE_ROOT="$TMP_ROOT"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
LINEAR="$TMP_ROOT/.agents/skills/linear/scripts/linear.sh"

cat >"$TMP_ROOT/.cache/linear/meta.json" <<'JSON'
{"synced_at":"2026-07-17T00:00:00+00:00"}
JSON

# Args: name team starts_at ends_at progress.
cycle_record() {
  printf '{"id":"uuid-%s","number":1,"name":"%s","startsAt":"%s","endsAt":"%s","progress":%s,"issueCountHistory":[],"completedIssueCountHistory":[],"team":{"name":"%s"}}\n' \
    "$1" "$1" "$3" "$4" "$5" "$2"
}

# KEN and OTHER are interleaved so neither owns the extremes of the whole set:
# OTHER's incomplete cycle starts latest, so an unfiltered "current" answers
# OTHER, and OTHER's future cycle is the earliest future one, so an unfiltered
# "upcoming" does too.
#
# SETTLED is the D case: every cycle of its own complete, plus one future cycle,
# so it has nothing started-and-incomplete while KEN and OTHER both do. Its
# completed cycle is the oldest in the whole cache and its future cycle the
# latest, which is what the positional fallbacks used to key on.
{
  cycle_record ken-past       KEN     2026-05-01T00:00:00.000Z 2026-05-15T00:00:00.000Z 1
  cycle_record ken-now        KEN     2026-06-01T00:00:00.000Z 2026-06-15T00:00:00.000Z 0.4
  cycle_record ken-next       KEN     2036-08-01T00:00:00.000Z 2036-08-15T00:00:00.000Z 0
  cycle_record other-past     OTHER   2026-05-20T00:00:00.000Z 2026-06-03T00:00:00.000Z 1
  cycle_record other-now      OTHER   2026-06-10T00:00:00.000Z 2026-06-24T00:00:00.000Z 0.2
  cycle_record other-next     OTHER   2036-07-01T00:00:00.000Z 2036-07-15T00:00:00.000Z 0
  cycle_record settled-done   SETTLED 2026-01-05T00:00:00.000Z 2026-01-19T00:00:00.000Z 1
  cycle_record settled-future SETTLED 2036-10-01T00:00:00.000Z 2036-10-15T00:00:00.000Z 0
} | jq -s '.' >"$TMP_ROOT/.cache/linear/cycles.json"

run_cycles() { cd "$TMP_ROOT" && bash "$LINEAR" cache cycles list "$@"; }

names() { jq -r '[.[].name] | sort | join(",")' <<<"$1"; }

# --- A: --team returns only that team's cycles -------------------------------
rc=0
outA="$(run_cycles --team KEN 2>/dev/null)" || rc=$?
assert_eq "A: --team exits zero" "$rc" 0
assert_eq "A: --team KEN returns exactly KEN's cycles" \
  "$(names "$outA")" "ken-next,ken-now,ken-past"
assert_jq "A: no other team's cycle leaks past --team" \
  "$outA" 'all(.[]; .team == "KEN")'

# --- B: the team filter runs before the type selection ------------------------
outB_current="$(run_cycles --team KEN --type current 2>/dev/null)"
assert_eq "B: --team KEN --type current picks KEN's current cycle" \
  "$(names "$outB_current")" "ken-now"
outB_upcoming="$(run_cycles --team KEN --type upcoming 2>/dev/null)"
assert_eq "B: --team KEN --type upcoming picks KEN's next cycle" \
  "$(names "$outB_upcoming")" "ken-next"
outB_past="$(run_cycles --team KEN --type past 2>/dev/null)"
assert_eq "B: --team KEN --type past returns only KEN's past cycles" \
  "$(names "$outB_past")" "ken-past"

# Same request for the other team answers with that team's cycle, so the filter
# is reading the flag rather than happening to match one team.
outB_other="$(run_cycles --team OTHER --type current 2>/dev/null)"
assert_eq "B: --team OTHER --type current picks OTHER's current cycle" \
  "$(names "$outB_other")" "other-now"

# --- C: no --team is unfiltered ----------------------------------------------
outC="$(run_cycles 2>/dev/null)"
assert_eq "C: no --team returns every team's cycles" \
  "$(names "$outC")" \
  "ken-next,ken-now,ken-past,other-next,other-now,other-past,settled-done,settled-future"

# --- D: the no-working-cycle fallbacks answer by date ------------------------
# SETTLED has no started-and-incomplete cycle of its own, which only filtering
# first can produce while the cache as a whole has two.
outD_current="$(run_cycles --team SETTLED --type current 2>/dev/null)"
assert_eq "D: --team SETTLED --type current finds no running cycle" \
  "$(names "$outD_current")" ""
outD_upcoming="$(run_cycles --team SETTLED --type upcoming 2>/dev/null)"
assert_eq "D: --team SETTLED --type upcoming skips the completed cycle" \
  "$(names "$outD_upcoming")" "settled-future"
outD_past="$(run_cycles --team SETTLED --type past 2>/dev/null)"
assert_eq "D: --team SETTLED --type past excludes the future cycle" \
  "$(names "$outD_past")" "settled-done"

# --- E: the inline --team=X spelling filters too ------------------------------
outE="$(run_cycles --team=KEN --type current 2>/dev/null)"
assert_eq "E: --team=KEN --type current picks KEN's current cycle" \
  "$(names "$outE")" "ken-now"
outE_plain="$(run_cycles --team=KEN 2>/dev/null)"
assert_eq "E: --team=KEN returns exactly KEN's cycles" \
  "$(names "$outE_plain")" "ken-next,ken-now,ken-past"
