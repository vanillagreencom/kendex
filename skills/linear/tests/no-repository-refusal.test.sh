#!/usr/bin/env bash
# lib/common.sh resolves the project root from the current directory, and
# every subcommand sources it. Outside a repository `git rev-parse` exits 128,
# and a bare assignment carried that status out under `set -e` before the
# guard below it could speak: the run died at 128 with nothing on stdout or
# stderr (KEN-1193). The refusal now names the directory it could not resolve
# a repository from. Help is answered before the lib is sourced and is held
# here from the other side, so the refusal cannot creep in front of it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LINEAR="$SKILL_DIR/scripts/linear.sh"
assert_tmpdir TMP_ROOT

# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below back at the real repository and make the fixture read as one.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
NOREPO="$TMP_ROOT/norepo"
mkdir -p "$NOREPO"
# The scratch root is under TMPDIR, which on a developer box can sit inside a
# checkout; the ceiling stops rev-parse's upward search at the fixture's own
# parent so "outside a repository" is what the fixture actually is.
export GIT_CEILING_DIRECTORIES="$TMP_ROOT"

probe_status=0
probe=$(LC_ALL=C git -C "$NOREPO" rev-parse --show-toplevel 2>&1) || probe_status=$?
if [[ "$probe_status" -ne 128 || "$probe" != *"not a git repository"* ]]; then
	assert_stop "the no-repository fixture is outside a git repository" "$probe"
fi
assert_eq "the no-repository fixture is outside a git repository" "$probe_status" 128

status=0
out=$(cd "$NOREPO" && "$LINEAR" issues list 2>"$TMP_ROOT/norepo.err") || status=$?
err=$(cat "$TMP_ROOT/norepo.err")
assert_eq "a subcommand run outside a git repository exits 1, not git's bare 128" "$status" 1
assert_eq "it prints nothing on stdout" "$out" ""
assert_contains "the refusal names the directory it could not resolve a repository from" \
	"$err" "Could not resolve a git repository from: $NOREPO"
assert_jq "the refusal is the JSON error shape every other linear diagnostic uses" \
	"$err" '.error | type == "string"'

# Help is answered before lib/common.sh is sourced, so the repository lookup
# must not reach it.
status=0
out=$(cd "$NOREPO" && "$LINEAR" --help) || status=$?
assert_eq "--help still exits 0 outside a git repository" "$status" 0
assert_contains "--help still prints its usage there" "$out" "Usage: ./linear.sh"
