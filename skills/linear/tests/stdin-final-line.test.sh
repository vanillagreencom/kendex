#!/usr/bin/env bash
# Every `--stdin` identifier reader keeps a last line that has no newline.
# `read` returns false on that line while still filling the variable, so a
# plain `while read` loop drops it with no error: a list written with
# printf '%s' or an editor's Write loses its last issue. `cache comments
# bulk-list` is covered in its own suite; these rows are the other three.
#
# Fully offline: the live readers run with their API call stubbed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT
ISSUES_SH="$TMP_ROOT/.agents/skills/linear/scripts/commands/issues.sh"

# The fixture repository below must be this root's own, not whatever an
# inherited git environment points at.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/.cache/linear"
git -C "$TMP_ROOT" init -q -b main
git -C "$TMP_ROOT" config gc.auto 0
git -C "$TMP_ROOT" config maintenance.auto false
export LINEAR_CACHE_ROOT="$TMP_ROOT"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
echo '{"synced_at":"2026-09-27T00:00:00+00:00"}' >"$TMP_ROOT/.cache/linear/meta.json"
cat >"$TMP_ROOT/.cache/linear/issues.json" <<'JSON'
[
  {"id": "uuid-SF-1", "identifier": "SF-1", "title": "first", "state": {"name": "Todo", "type": "unstarted"}, "labels": {"nodes": []}},
  {"id": "uuid-SF-2", "identifier": "SF-2", "title": "last", "state": {"name": "Todo", "type": "unstarted"}, "labels": {"nodes": []}}
]
JSON

cache_rc=0
cache_out="$(cd "$TMP_ROOT" && printf 'SF-1\nSF-2' |
  bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" cache issues bulk-get --stdin --format=ids)" || cache_rc=$?
assert_eq "cache issues bulk-get --stdin exits zero" "$cache_rc" 0
assert_eq "cache issues bulk-get --stdin keeps the last identifier" "$cache_out" $'SF-1\nSF-2'

# run_live SCRIPT — run SCRIPT with the fixture's issues.sh as $1, from the
# fixture root and with the child's whole environment named here, so the
# developer checkout's settings and env file are never read.
run_live() {
  (cd "$TMP_ROOT" && env -i HOME="$TMP_ROOT" PATH="$PATH" \
    LINEAR_API_KEY_OVERRIDE=test-token LINEAR_CACHE_ROOT="$TMP_ROOT" \
    "$BASH" -euo pipefail -c "$1" _ "$ISSUES_SH")
}

# The live reader sends the identifiers it read as the query's id filter; the
# stub prints that filter back instead of calling the API.
live_rc=0
live_out="$(printf 'SF-1\nSF-2' | run_live '
    # shellcheck disable=SC1090
    source "$1"
    resolve_issue_id() { printf "uuid-%s\n" "$1"; }
    graphql_query() { printf "%s\n" "$2"; }
    bulk_get_issues --stdin --format=raw
')" || live_rc=$?
assert_eq "issues bulk-get --stdin exits zero" "$live_rc" 0
assert_jq "issues bulk-get --stdin keeps the last identifier" "$live_out" \
  '.filter.id.in == ["uuid-SF-1", "uuid-SF-2"]'

update_rc=0
update_out="$(printf 'SF-1\nSF-2' | run_live '
    # shellcheck disable=SC1090
    source "$1"
    update_issue() { printf "{\"success\":true,\"identifier\":\"%s\"}\n" "$1"; }
    bulk_update_issues --stdin --state Todo
')" || update_rc=$?
assert_eq "issues bulk-update --stdin exits zero" "$update_rc" 0
assert_jq "issues bulk-update --stdin keeps the last identifier" "$update_out" \
  '(.results | map(.identifier)) == ["SF-1", "SF-2"]'
