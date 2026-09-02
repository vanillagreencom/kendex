#!/usr/bin/env bash
# `cache projects get` returns ONE project (KEN-1153).
#
# Linear keeps a canceled project under the name a live one reuses (KEN-1022).
# cache_get_project selected with `.[] | select(.id == $ref or .name == $ref)`
# and printed every match, so a duplicated name emitted two concatenated
# top-level JSON objects at rc 0 — in --format=safe and --format=raw alike —
# and `cache projects get "<name>" | jq -r '.id'` read two ids. KEN-1022 fixed
# the live path in resolve_project_id and never touched this one.
#
# This locks in the cache spelling of the rule SKILL.md § Option Behavior
# states for a name that selects one project:
#   A. A name matching a live project and its canceled twin returns exactly one
#      object, the live one, in both formats — so `| jq -r '.id'` reads one id.
#   B. A UUID reaches the canceled project directly, whatever its state.
#   C. A name whose every match is canceled is refused, naming each UUID and
#      state, rather than answering with a canceled project.
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
# .claude/CLAUDE.md.
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
# control's emit-every-match stream leads with the canceled id.
# "Solo Canceled" has no live counterpart at all.
cat >"$TMP_ROOT/.cache/linear/projects.json" <<'JSON'
[
  {"id":"dead-uuid","name":"Review Gate & CI","state":"canceled"},
  {"id":"live-uuid","name":"Review Gate & CI","state":"backlog"},
  {"id":"lonely-uuid","name":"Solo Canceled","state":"canceled"},
  {"id":"plain-uuid","name":"Trading Panels","state":"started"}
]
JSON

run_get() { cd "$TMP_ROOT" && bash "$LINEAR" cache projects get "$@"; }

# --- A: a duplicated name returns exactly one project, the live one ----------
# The status is captured, not discarded: a caller's `| jq -r '.id'` cannot see
# it, so every assertion below would hold on a command that printed the live
# project and then exited 1.
safe_rc=0
safe="$(run_get "Review Gate & CI" 2>/dev/null)" || safe_rc=$?
assert_eq "A: a resolved name exits 0 (--format=safe)" "$safe_rc" 0
assert_eq "A: a name matching a live and a canceled project returns ONE object (--format=safe)" \
  "$(jq -s 'length' <<<"$safe")" "1"
assert_eq "A: that one object is the live project, so \`| jq -r .id\` reads one id" \
  "$(jq -s -r '[.[].id] | join(",")' <<<"$safe")" "live-uuid"

raw_rc=0
raw="$(run_get "Review Gate & CI" --format=raw 2>/dev/null)" || raw_rc=$?
assert_eq "A: a resolved name exits 0 (--format=raw)" "$raw_rc" 0
assert_eq "A: --format=raw returns ONE object too" \
  "$(jq -s 'length' <<<"$raw")" "1"
assert_eq "A: the raw object carries the live project" \
  "$(jq -s -r '[.[].project.id] | join(",")' <<<"$raw")" "live-uuid"

# An unambiguous name is unaffected. Guarded like the reads above: an
# unguarded command substitution aborts the whole suite under errexit, so a
# regression here would report as a missing verdict rather than a failure.
solo_rc=0
solo="$(run_get "Trading Panels" 2>/dev/null)" || solo_rc=$?
assert_eq "A: an unduplicated name exits 0" "$solo_rc" 0
assert_eq "A: an unduplicated name still resolves to its project" \
  "$(jq -s -r '[.[].id] | join(",")' <<<"$solo")" "plain-uuid"

# --- B: a UUID reaches the canceled project ---------------------------------
by_uuid_rc=0
by_uuid="$(run_get "dead-uuid" 2>/dev/null)" || by_uuid_rc=$?
assert_eq "B: a UUID for a canceled project succeeds" "$by_uuid_rc" 0
assert_eq "B: a UUID reaches that canceled project, not its live twin" \
  "$(jq -s -r '[.[].id] | join(",")' <<<"$by_uuid")" "dead-uuid"

# --- C: an all-canceled name set is refused, naming the matches --------------
only_rc=0
only_err="$(run_get "Solo Canceled" 2>&1 >/dev/null)" || only_rc=$?
assert_ne "C: a name whose only match is canceled does not exit 0" "$only_rc" 0
assert_jq "C: the refusal names the matching UUID and its state" \
  "$only_err" '.error | test("lonely-uuid \\(canceled\\)")'

missing_rc=0
missing_err="$(run_get "No Such Project" 2>&1 >/dev/null)" || missing_rc=$?
assert_ne "C: an unmatched name still fails" "$missing_rc" 0
assert_jq "C: an unmatched name reports plain not-found, not an empty match list" \
  "$missing_err" '.error | test("Project not found in cache: No Such Project$")'
