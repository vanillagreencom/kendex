#!/usr/bin/env bash
# Cache date comparisons are UTC, and cycle selection anchors on a date (KEN-1175).
#
# sync stores `startsAt` and `updatedAt` as Linear returns them — UTC, a `Z`
# suffix — and every filter over the cache compares those strings lexically. The
# comparison timestamp was built with `date -Iseconds`, which emits the host's
# local time with an offset suffix, so the two were only comparable on a UTC
# host. Off UTC the cut moved by the whole offset: at -07:00 no `--cycle`
# keyword resolved at all, at +09:00 `current` answered with a cycle that had
# not started. Nothing caught it, because every fixture cycle in this suite's
# neighbours sits months out and CI runs UTC.
#
# So TZ is PINNED here, not read from the host, and the fixture's cycles sit
# hours from now — inside the offset. The assertions state the UTC answer, which
# is the only right one at any TZ.
#
# The same helpers carry the second defect: with no cycle running, prev/next and
# past/upcoming fell back to a POSITION in the date-sorted list rather than to a
# date, which inverted both answers — a cycle that has not started was reported
# as the previous one, to the read cycle planning consumes.
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

# UTC+14, no DST, so the pin is the same offset in every month of the year. At
# this offset the local-time form reads as fourteen hours into tomorrow, which
# is what puts a cycle starting in six hours on the wrong side of every cut.
TZ_PIN="Pacific/Kiritimati"

# jq's `now`, not `date -d '+6 hours'`: the suite already depends on jq, and
# `date -d` is GNU-only with no precedent in this directory. The `.000Z` shape
# is what sync writes.
at() { jq -rn --argjson off "$1" '(now + $off) | todate | sub("Z$"; ".000Z")'; }

cycles() { printf '%s\n' "$1" >"$CACHE/cycles.json"; }

# Only startsAt and progress decide any selection under test; endsAt rides along
# because the formatter prints it.
cycle_record() { # name team starts-offset ends-offset progress
  jq -cn --arg n "$1" --arg t "$2" --arg s "$(at "$3")" --arg e "$(at "$4")" --argjson p "$5" \
    '{id: ("uuid-" + $n), number: 1, name: $n, startsAt: $s,
      endsAt: $e, progress: $p, team: {name: $t}}'
}

issue_record() { # identifier cycle-name updated-offset
  jq -cn --arg id "$1" --arg c "$2" --arg u "$(at "$3")" \
    '{id: ("issue-" + $id), identifier: $id, title: $id, description: "",
      state: {name: "Todo", type: "unstarted"}, assignee: null, project: null,
      projectMilestone: null, parent: null, team: {name: "KEN"},
      cycle: (if $c == "" then null else {id: ("uuid-" + $c), number: 1, name: $c} end),
      labels: {nodes: []}, priority: 0, estimate: null, sortOrder: 0, url: "",
      createdAt: $u, updatedAt: $u, archivedAt: null, trashed: false,
      children: {nodes: []}, relations: {nodes: []}, inverseRelations: {nodes: []}}'
}

printf '%s\n' '[]' >"$CACHE/projects.json"
jq -cn '[$ARGS.positional[] | fromjson]' --args \
  "$(issue_record IN-RUNNING running -7200)" \
  "$(issue_record IN-SOON soon 21600)" \
  "$(issue_record STALE "" -54000)" >"$CACHE/issues.json"
# session-status syncs a stale cache before reading it, which would reach the
# network; a fresh stamp keeps this suite offline.
printf '{"synced_at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$CACHE/meta.json"

run() { (cd "$TMP_ROOT" && TZ="$TZ_PIN" bash "$LINEAR" "$@"); }
names() { jq -r '[.[].name] | join(",")' <<<"$1"; }
ids() { jq -r '[.[].id] | sort | join(",")' <<<"$1"; }

# --- A cycle is running: every site must agree on WHICH one ------------------
#
# `running` started two hours ago and is incomplete; `soon` starts in six. Under
# the local-time form at +14 both read as already started, and `soon`, being the
# later start, wins every "most recently started" selection.
cycles "$(jq -cn --argjson a "$(cycle_record running KEN -7200 1123200 0.5)" \
  --argjson b "$(cycle_record soon KEN 21600 1231200 0)" '[$a, $b]')"

assert_eq "cache issues list --cycle current resolves the running cycle, not the one starting later today" \
  "$(ids "$(run cache issues list --cycle current --all-projects 2>/dev/null)")" "IN-RUNNING"

assert_eq "cache cycles list --type current is the running cycle, not the one starting later today" \
  "$(names "$(run cache cycles list --type current 2>/dev/null)")" "running"

assert_eq "session-status reports the running cycle as the working one" \
  "$(run session-status 2>/dev/null | jq -r '.cycle.name // "none"')" "running"

# The `Nd` cutoff is the same encoding with a smaller blast radius: it lands the
# offset away from where it should. STALE was updated fifteen hours ago, inside
# a one-day window and outside the ten-hour window the local-time form leaves.
assert_eq "cache issues list --updated-since keeps an issue inside the UTC window" \
  "$(ids "$(run cache issues list --updated-since 1d --all-projects 2>/dev/null)")" \
  "IN-RUNNING,IN-SOON,STALE"

# --- No cycle is running: the fallback must anchor on a date, not a position -
#
# `old` ran forty days ago and is complete, `soon` has not started. Falling back
# to the ends of the date-sorted list answers both questions with the other
# one's cycle.
cycles "$(jq -cn --argjson a "$(cycle_record old KEN -3456000 -2246400 1)" \
  --argjson b "$(cycle_record soon KEN 21600 1231200 0)" '[$a, $b]')"

assert_eq "with no cycle running, --type upcoming is the next cycle to start" \
  "$(names "$(run cache cycles list --type upcoming 2>/dev/null)")" "soon"

assert_eq "with no cycle running, --type past excludes a cycle that has not started" \
  "$(names "$(run cache cycles list --type past 2>/dev/null)")" "old"

status="$(run session-status 2>/dev/null)"
assert_eq "with no cycle running, session-status prev_cycle is the cycle that already ran" \
  "$(jq -r '.prev_cycle.name // "none"' <<<"$status")" "old"
assert_eq "with no cycle running, session-status next_cycle is the cycle that has not started" \
  "$(jq -r '.next_cycle.name // "none"' <<<"$status")" "soon"
