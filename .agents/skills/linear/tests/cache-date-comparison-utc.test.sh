#!/usr/bin/env bash
# Cache date comparisons are UTC, and cycle selection anchors on a date (KEN-1175).
#
# sync stores `startsAt` and `updatedAt` as Linear returns them — UTC, a `Z`
# suffix — and every filter over the cache compares those strings lexically. The
# comparison timestamp was built with `date -Iseconds`, which emits the host's
# local time with an offset suffix, so the two were only comparable on a UTC
# host. Off UTC the cut moved by the whole offset, so within that window either
# side of a cycle boundary `current` named a cycle that had not started (east of
# UTC) or the previous one, or nothing at all where no earlier cycle was
# incomplete (west of it).
#
# So TZ is PINNED here, not read from the host. The assertions state the UTC
# answer, which is the only right one at any TZ.
#
# The same helpers carry the second defect: with no cycle running, prev/next and
# past/upcoming fell back to a POSITION in the date-sorted list rather than to a
# date, which inverted both answers — a cycle that has not started was reported
# as the previous one, to the read cycle planning consumes. The second fixture
# carries two cycles on each side of now, because a helper returning them in the
# wrong order reads as green off a one-element list.
#
# Fully offline — pure cache reads, no curl needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

# GIT_DIR outranks -C, so where it is inherited `git -C "$TMP_ROOT" init` below
# re-inits the ambient repository and leaves no fixture repo at all. All four go,
# which is the house rule in .claude/CLAUDE.md.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/.cache/linear"
# common.sh resolves PROJECT_ROOT through git rev-parse, so the fixture needs a
# repository of its own for that to land inside this scratch root.
git -C "$TMP_ROOT" init -q -b main
if [[ ! -d "$TMP_ROOT/.git" ]]; then
  assert_stop "the fixture repository is the one git init created" \
    "no repository at $TMP_ROOT/.git: a git environment variable redirected git init"
fi

# This root's own cache is the subject, so it replaces the assert lib's default
# sandbox — still scratch, so the exit verdict's containment check holds.
export LINEAR_CACHE_ROOT="$TMP_ROOT"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
LINEAR="$TMP_ROOT/.agents/skills/linear/scripts/linear.sh"
CACHE="$TMP_ROOT/.cache/linear"

# UTC+14, no DST, so the pin is the same offset in every month of the year.
TZ_PIN="Pacific/Kiritimati"

# jq's `now`, not `date -d '+6 hours'`: the suite already depends on jq, and
# `date -d` is GNU-only with no precedent in this directory. The `.000Z` shape
# is what sync writes.
at() { jq -rn --argjson off "$1" '(now + $off) | todate | sub("Z$"; ".000Z")'; }

cycles() { printf '%s\n' "$1" >"$CACHE/cycles.json"; }

# endsAt rides along because the formatter prints it.
cycle_record() { # name team starts-offset ends-offset progress
  jq -cn --arg n "$1" --arg t "$2" --arg s "$(at "$3")" --arg e "$(at "$4")" --argjson p "$5" \
    '{id: ("uuid-" + $n), number: 1, name: $n, startsAt: $s,
      endsAt: $e, progress: $p, team: {name: $t}}'
}

# `research` is the fourth argument: session-status reads completed research
# issues through the same day-count cutoff the `--updated-since` filter uses.
issue_record() { # identifier cycle-name updated-offset [research]
  jq -cn --arg id "$1" --arg c "$2" --arg u "$(at "$3")" --arg r "${4:-}" \
    '{id: ("issue-" + $id), identifier: $id, title: $id, description: "",
      state: (if $r == "" then {name: "Todo", type: "unstarted"}
              else {name: "Done", type: "completed"} end),
      assignee: null, project: null,
      projectMilestone: null, parent: null, team: {name: "KEN"},
      cycle: (if $c == "" then null else {id: ("uuid-" + $c), number: 1, name: $c} end),
      labels: {nodes: (if $r == "" then [] else [{name: "research"}] end)},
      priority: 0, estimate: null, sortOrder: 0, url: "",
      createdAt: $u, updatedAt: $u, archivedAt: null, trashed: false,
      children: {nodes: []}, relations: {nodes: []}, inverseRelations: {nodes: []}}'
}

printf '%s\n' '[]' >"$CACHE/projects.json"
# STALE and OUTSIDE straddle the one-day cutoff; the two research issues straddle
# session-status's seven-day one. Both pairs pin an edge on each side, so a
# window that widened is as visible as one that narrowed.
jq -cn '[$ARGS.positional[] | fromjson]' --args \
  "$(issue_record IN-OLD old -7200)" \
  "$(issue_record IN-LINGERING lingering -7200)" \
  "$(issue_record IN-RUNNING running -7200)" \
  "$(issue_record IN-SOON soon 21600)" \
  "$(issue_record STALE "" -54000)" \
  "$(issue_record OUTSIDE "" -108000)" \
  "$(issue_record RESEARCH-FRESH "" -172800 research)" \
  "$(issue_record RESEARCH-OLD "" -864000 research)" >"$CACHE/issues.json"
# session-status syncs a stale cache before reading it, which would reach the
# network; a fresh stamp keeps this suite offline.
printf '{"synced_at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$CACHE/meta.json"

run() { (cd "$TMP_ROOT" && TZ="$TZ_PIN" bash "$LINEAR" "$@"); }
names() { jq -r '[.[].name] | join(",")' <<<"$1"; }
ids() { jq -r '[.[].id] | sort | join(",")' <<<"$1"; }

# --- A cycle is running: every site must agree on WHICH one ------------------
#
# `running` started two hours ago and is incomplete; `soon` starts in six, and
# `old` finished long ago. Under the local-time form at +14 all of them read as
# already started, and `soon`, being the later start, wins every "most recently
# started" selection.
#
# `lingering` is the reason the working cycle is MOST RECENTLY started rather
# than merely started: a Linear cycle that ends with unfinished issues keeps
# progress < 1, so two incomplete started cycles at once is the ordinary shape,
# and taking the wrong end of them puts every site on the same wrong cycle.
#
# Newest-first, the order sync leaves in cycles.json. Reordered to read
# oldest-first, the sorts in cache-dates.sh pick what their own absence would
# pick, and stop being provable.
cycles "$(jq -cn --argjson a "$(cycle_record old KEN -3456000 -2246400 1)" \
  --argjson b "$(cycle_record lingering KEN -1728000 -518400 0.9)" \
  --argjson c "$(cycle_record running KEN -7200 1123200 0.5)" \
  --argjson d "$(cycle_record soon KEN 21600 1231200 0)" '[$d, $c, $b, $a]')"

assert_eq "cache issues list --cycle current resolves the running cycle, not the one starting later today" \
  "$(ids "$(run cache issues list --cycle current --all-projects 2>/dev/null)")" "IN-RUNNING"

assert_eq "cache issues list --cycle previous is the cycle before the running one" \
  "$(ids "$(run cache issues list --cycle previous --all-projects 2>/dev/null)")" "IN-LINGERING"

assert_eq "cache issues list --cycle next is the cycle after the running one" \
  "$(ids "$(run cache issues list --cycle next --all-projects 2>/dev/null)")" "IN-SOON"

assert_eq "cache cycles list --type current is the running cycle, not the one starting later today" \
  "$(names "$(run cache cycles list --type current 2>/dev/null)")" "running"

status="$(run session-status 2>/dev/null)"
assert_eq "session-status reports the running cycle as the working one" \
  "$(jq -r '.cycle.name // "none"' <<<"$status")" "running"

# The `Nd` cutoff is the same encoding with a smaller blast radius: it lands the
# offset away from where it should. STALE sits inside the one-day window and
# outside the narrower one the local-time form leaves; OUTSIDE sits beyond both
# and must stay out.
assert_eq "cache issues list --updated-since keeps the UTC window and no more" \
  "$(ids "$(run cache issues list --updated-since 1d --all-projects 2>/dev/null)")" \
  "IN-LINGERING,IN-OLD,IN-RUNNING,IN-SOON,STALE"

# session-status reports research as a count, so the two-issue straddle is what
# makes it discriminating: one inside the seven days, one at ten days out.
assert_eq "session-status research reads the same day-count cutoff" \
  "$(jq -r '.research.count' <<<"$status")" "1"

# --- No cycle is running: the fallback must anchor on a date, not a position -
#
# Two cycles on each side of now, so the ORDER each helper promises is
# observable: `before` newest-first, `after` earliest-first.
#
# Newest-first, the order sync leaves in cycles.json. Reordered to read
# oldest-first, the sorts in cache-dates.sh pick what their own absence would
# pick, and stop being provable.
cycles "$(jq -cn --argjson a "$(cycle_record ancient KEN -10368000 -9158400 1)" \
  --argjson b "$(cycle_record old KEN -3456000 -2246400 1)" \
  --argjson c "$(cycle_record soon KEN 21600 1231200 0)" \
  --argjson d "$(cycle_record soonB KEN 108000 1317600 0)" '[$d, $c, $b, $a]')"

assert_eq "with no cycle running, --type upcoming is the NEXT cycle to start, not the farthest out" \
  "$(names "$(run cache cycles list --type upcoming 2>/dev/null)")" "soon"

assert_eq "with no cycle running, --type past is every started cycle newest-first, and no future one" \
  "$(names "$(run cache cycles list --type past 2>/dev/null)")" "old,ancient"

assert_eq "with no cycle running, --cycle previous answers with the most recent cycle that started" \
  "$(ids "$(run cache issues list --cycle previous --all-projects 2>/dev/null)")" "IN-OLD"

assert_eq "with no cycle running, --cycle next answers with the earliest cycle still to start" \
  "$(ids "$(run cache issues list --cycle next --all-projects 2>/dev/null)")" "IN-SOON"

status="$(run session-status 2>/dev/null)"
assert_eq "with no cycle running, session-status prev_cycle is the most recent cycle that ran" \
  "$(jq -r '.prev_cycle.name // "none"' <<<"$status")" "old"
assert_eq "with no cycle running, session-status next_cycle is the earliest cycle still to start" \
  "$(jq -r '.next_cycle.name // "none"' <<<"$status")" "soon"
