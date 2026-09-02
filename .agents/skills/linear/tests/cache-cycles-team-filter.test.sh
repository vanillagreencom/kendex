#!/usr/bin/env bash
# cache cycles list --team (KEN-1150).
#
# `--team` was consumed and discarded here — `--team) shift 2 ;;` — so the flag
# was accepted at rc 0 and did nothing: on a cache holding more than one team,
# every team's cycles came back from a request that named one. `cache labels
# list` already carries the one-line `.team.name` filter this adds.
#
# Both spellings filter, the space form and the inline `--team=X` the same
# function already accepts for --format.
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

# Two teams, which is what makes a filter that does nothing detectable.
cat >"$TMP_ROOT/.cache/linear/cycles.json" <<'JSON'
[
  {"id":"uuid-ken","number":1,"name":"ken-cycle","startsAt":"2026-06-01T00:00:00.000Z",
   "endsAt":"2026-06-15T00:00:00.000Z","progress":0.4,"team":{"name":"KEN"}},
  {"id":"uuid-other","number":1,"name":"other-cycle","startsAt":"2026-06-10T00:00:00.000Z",
   "endsAt":"2026-06-24T00:00:00.000Z","progress":0.2,"team":{"name":"OTHER"}}
]
JSON

run_cycles() { cd "$TMP_ROOT" && bash "$LINEAR" cache cycles list "$@"; }

names() { jq -r '[.[].name] | sort | join(",")' <<<"$1"; }

assert_eq "--team KEN returns exactly KEN's cycles" \
  "$(names "$(run_cycles --team KEN 2>/dev/null)")" "ken-cycle"

assert_eq "--team=KEN, the inline spelling, filters the same" \
  "$(names "$(run_cycles --team=KEN 2>/dev/null)")" "ken-cycle"
