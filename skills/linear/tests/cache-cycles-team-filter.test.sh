#!/usr/bin/env bash
# cache cycles list --team (KEN-1150).
#
# `--team` was consumed and discarded here — `--team) shift 2 ;;` — so the flag
# was accepted at rc 0 and did nothing. Every cycle in the cache came back, and
# `--type current|upcoming|past` picked its one cycle off that unfiltered set:
# on a cache holding more than one team, `--team X --type current` could answer
# with another team's cycle while naming X in the request.
#
# `cache labels list` already carries the same one-line `.team.name` filter;
# this locks the cycles side to it, and locks the ordering the type selection
# depends on:
#   A. --team returns only that team's cycles.
#   B. The filter runs BEFORE the type selection, so current/upcoming/past pick
#      within the team rather than across every team.
#   C. No --team still returns every team's cycles.
#
# Fully offline — pure cache read, no curl needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/.cache/linear"
git -C "$TMP_ROOT" init -q -b main

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

# Interleaved so no team owns the extremes of the whole set: OTHER's incomplete
# cycle starts latest, so an unfiltered "current" answers OTHER, and OTHER's
# future cycle is the earliest future one, so an unfiltered "upcoming" does too.
{
  cycle_record ken-past    KEN   2026-05-01T00:00:00.000Z 2026-05-15T00:00:00.000Z 1
  cycle_record ken-now     KEN   2026-06-01T00:00:00.000Z 2026-06-15T00:00:00.000Z 0.4
  cycle_record ken-next    KEN   2036-08-01T00:00:00.000Z 2036-08-15T00:00:00.000Z 0
  cycle_record other-past  OTHER 2026-05-20T00:00:00.000Z 2026-06-03T00:00:00.000Z 1
  cycle_record other-now   OTHER 2026-06-10T00:00:00.000Z 2026-06-24T00:00:00.000Z 0.2
  cycle_record other-next  OTHER 2036-07-01T00:00:00.000Z 2036-07-15T00:00:00.000Z 0
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
  "$(names "$outC")" "ken-next,ken-now,ken-past,other-next,other-now,other-past"
