#!/usr/bin/env bash
# `cache projects list-dependencies` returns ONE project's relations.
#
# It selected with `.[] | select(.id == $id or .name == $id)` and emitted one
# top-level object PER match, so a name the cache holds twice printed the
# canceled project's relations beside the live one's at rc 0, in cache-file
# order, with nothing in the output saying a second object followed. A caller's
# `| jq -r '.project.id'` read two ids and a caller reading the first object got
# either project depending on sync order. Team KEN carries such a twin today:
# "Review Gate & CI" is live in one project and canceled in another.
#
# This locks in the cache spelling of the rule ../SKILL.md § Option Behavior
# states for a name that selects one project, for the `list-dependencies`
# command:
#   A. A name matching a live project and its canceled twin returns exactly one
#      object, the live one's relations — so `| jq -r '.project.id'` reads one id.
#   B. A UUID reaches the canceled project directly, whatever its state.
#   C. A name whose every match is canceled is refused, naming each UUID and
#      state, rather than answering with a canceled project's relations.
#   D. A reference matching nothing is refused rather than printing nothing at
#      rc 0, which told a caller asking whether a project is blocked that it
#      has no dependencies.
#
# Fully offline — pure cache read, no curl needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

# GIT_DIR outranks -C, so where it is inherited the `git init` below re-inits
# the ambient repository and leaves no fixture repo at all — which is what the
# assert_stop below checks. All four go together, which is the house rule in
# the repository's AGENTS.md.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/.cache/linear"
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

cat >"$TMP_ROOT/.cache/linear/meta.json" <<'JSON'
{"synced_at":"2026-09-02T00:00:00+00:00"}
JSON

# The canceled twin is listed FIRST, so a selection that merely narrows to one
# object without preferring the live one still fails section A, and the
# control's emit-every-match stream leads with the canceled id. Each project
# carries relations naming itself, so an assertion can tell which project's
# relations came back rather than only which id did.
# "Solo Canceled" has no live counterpart at all.
cat >"$TMP_ROOT/.cache/linear/projects.json" <<'JSON'
[
  {"id":"dead-uuid","name":"Review Gate & CI","state":"canceled",
   "relations":{"nodes":[{"id":"rel-dead","type":"blocks"}]},
   "inverseRelations":{"nodes":[]}},
  {"id":"live-uuid","name":"Review Gate & CI","state":"backlog",
   "relations":{"nodes":[{"id":"rel-live","type":"blocks"}]},
   "inverseRelations":{"nodes":[{"id":"inv-live","type":"blocks"}]}},
  {"id":"lonely-uuid","name":"Solo Canceled","state":"canceled",
   "relations":{"nodes":[]},"inverseRelations":{"nodes":[]}},
  {"id":"plain-uuid","name":"Trading Panels","state":"started",
   "relations":{"nodes":[{"id":"rel-plain","type":"blocks"}]},
   "inverseRelations":{"nodes":[]}}
]
JSON

run_deps() { cd "$TMP_ROOT" && bash "$LINEAR" cache projects list-dependencies "$@"; }

# --- A: a duplicated name returns exactly one project ------------------------
# The status is captured, not discarded: a caller's `| jq -r '.project.id'`
# cannot see it, so every assertion below would hold on a command that printed
# the live project and then exited 1.
dup_rc=0
dup="$(run_deps "Review Gate & CI" 2>/dev/null)" || dup_rc=$?
assert_eq "A: a resolved name exits 0" "$dup_rc" 0
assert_eq "A: a name matching a live and a canceled project returns ONE object" \
  "$(jq -s 'length' <<<"$dup")" "1"
assert_eq "A: that one object is the live project, so \`| jq -r .project.id\` reads one id" \
  "$(jq -s -r '[.[].project.id] | join(",")' <<<"$dup")" "live-uuid"
assert_eq "A: the relations returned are the live project's, not the canceled twin's" \
  "$(jq -s -r '[.[].project.relations.nodes[].id] | join(",")' <<<"$dup")" "rel-live"
assert_eq "A: the inverse relations come from that same project" \
  "$(jq -s -r '[.[].project.inverseRelations.nodes[].id] | join(",")' <<<"$dup")" "inv-live"

# An unambiguous name is unaffected. Guarded like the reads above: an
# unguarded command substitution aborts the whole suite under errexit, so a
# failure here would report as a missing verdict rather than a failure.
solo_rc=0
solo="$(run_deps "Trading Panels" 2>/dev/null)" || solo_rc=$?
assert_eq "A: an unduplicated name exits 0" "$solo_rc" 0
assert_eq "A: an unduplicated name still returns its project" \
  "$(jq -s -r '[.[].project.id] | join(",")' <<<"$solo")" "plain-uuid"

# --- B: a UUID reaches the canceled project ---------------------------------
by_uuid_rc=0
by_uuid="$(run_deps "dead-uuid" 2>/dev/null)" || by_uuid_rc=$?
assert_eq "B: a UUID for a canceled project succeeds" "$by_uuid_rc" 0
assert_eq "B: a UUID reaches that canceled project's relations, not its live twin's" \
  "$(jq -s -r '[.[].project.relations.nodes[].id] | join(",")' <<<"$by_uuid")" "rel-dead"

# --- C: an all-canceled name set is refused, naming the matches --------------
only_rc=0
only_out="$(run_deps "Solo Canceled" 2>/dev/null)" || only_rc=$?
only_err="$(run_deps "Solo Canceled" 2>&1 >/dev/null)" || true
assert_ne "C: a name whose only match is canceled does not exit 0" "$only_rc" 0
assert_eq "C: it prints no project on stdout" "$only_out" ""
assert_jq "C: the refusal names the matching UUID and its state" \
  "$only_err" '.error | test("lonely-uuid \\(canceled\\)")'

# --- D: an unmatched reference is refused, not answered with silence ---------
missing_rc=0
missing_out="$(run_deps "No Such Project" 2>/dev/null)" || missing_rc=$?
missing_err="$(run_deps "No Such Project" 2>&1 >/dev/null)" || true
assert_ne "D: an unmatched reference does not exit 0" "$missing_rc" 0
assert_eq "D: it prints no relations payload on stdout" "$missing_out" ""
assert_jq "D: an unmatched reference reports plain not-found, not an empty match list" \
  "$missing_err" '.error | test("Project not found in cache: No Such Project$")'
