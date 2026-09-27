#!/usr/bin/env bash
# `cache comments bulk-list` reads the comments of several issues in one
# process, and keeps apart the three answers a per-issue loop could not: an
# issue with no comments ([] at exit 0), an identifier the cache holds no issue
# for (refused with `missing`), and a comment file that cannot be read (refused
# with `path`). A cache that cannot be found stays an error.
#
# Fully offline — pure cache read, no curl needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

# The fixture repository below must be this root's own, not whatever an
# inherited git environment points at.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

CACHE="$TMP_ROOT/.cache/linear"
mkdir -p "$TMP_ROOT/.agents/skills" "$CACHE/comments"
git -C "$TMP_ROOT" init -q -b main
git -C "$TMP_ROOT" config gc.auto 0
git -C "$TMP_ROOT" config maintenance.auto false

# This root's own cache is the subject, so it replaces the assert lib's default
# sandbox — still scratch, so the exit verdict's containment check holds.
export LINEAR_CACHE_ROOT="$TMP_ROOT"
# The rows that pass no --format measure the command's default, not the
# format a caller's shell exports.
export LINEAR_FORMAT=safe
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
LINEAR="$TMP_ROOT/.agents/skills/linear/scripts/linear.sh"

echo '{"synced_at":"2026-09-27T00:00:00+00:00"}' >"$CACHE/meta.json"
cat >"$CACHE/issues.json" <<'JSON'
[
  {"id": "uuid-CB-1", "identifier": "CB-1", "title": "two comments", "state": {"name": "Todo", "type": "unstarted"}, "labels": {"nodes": []}},
  {"id": "uuid-CB-2", "identifier": "CB-2", "title": "one comment", "state": {"name": "Done", "type": "completed"}, "labels": {"nodes": []}},
  {"id": "uuid-CB-3", "identifier": "CB-3", "title": "no comments", "state": {"name": "Canceled", "type": "canceled"}, "labels": {"nodes": []}}
]
JSON
cat >"$CACHE/comments/CB-1.json" <<'JSON'
[
  {"id": "c-1a", "body": "first", "user": {"name": "Ada"}, "createdAt": "2026-09-01T00:00:00Z", "updatedAt": "2026-09-01T00:00:00Z"},
  {"id": "c-1b", "body": "second", "user": {"name": "Bo"}, "createdAt": "2026-09-02T00:00:00Z", "updatedAt": "2026-09-02T00:00:00Z"}
]
JSON
GOOD_CB2='[{"id": "c-2a", "body": "superseded by CB-1", "user": {"name": "Cy"}, "createdAt": "2026-09-03T00:00:00Z", "updatedAt": "2026-09-03T00:00:00Z"}]'
printf '%s\n' "$GOOD_CB2" >"$CACHE/comments/CB-2.json"

# run_cache OUT_VAR ERR_VAR RC_VAR [ARGS...] — stdout, stderr and status kept
# apart, since a refusal must put nothing on stdout.
# The locals carry a prefix so none shadows a caller's variable name, which
# `printf -v` would then write instead.
run_cache() {
  local rc__out="$1" rc__err="$2" rc__rc="$3" rc__status=0 rc__file="$TMP_ROOT/stderr" rc__stdout
  shift 3
  rc__stdout="$(cd "$TMP_ROOT" && bash "$LINEAR" cache "$@" 2>"$rc__file")" || rc__status=$?
  printf -v "$rc__out" '%s' "$rc__stdout"
  printf -v "$rc__err" '%s' "$(cat "$rc__file")"
  printf -v "$rc__rc" '%s' "$rc__status"
}

# --- several identifiers, one of them with no comments -----------------------
run_cache out err rc comments bulk-list CB-2 CB-1 CB-3
assert_eq "several identifiers exit zero" "$rc" 0
assert_jq "several identifiers key the result by identifier in request order" "$out" \
  'keys_unsorted == ["CB-2", "CB-1", "CB-3"]'
assert_jq "each identifier carries its own comments" "$out" \
  '(.["CB-1"] | map(.id)) == ["c-1a", "c-1b"] and (.["CB-2"] | map(.id)) == ["c-2a"]'
assert_jq "the default format is the safe comment shape" "$out" \
  '.["CB-1"][0] == {id: "c-1a", body: "first", user: "Ada", created_at: "2026-09-01T00:00:00Z", updated_at: "2026-09-01T00:00:00Z"}'
assert_jq "an issue with no comments reads as an empty list" "$out" '.["CB-3"] == []'

# The only row that reads no comment file at all, where jq would read stdin
# for input if the command let it, so it is handed a stdin that is not a
# comment list.
run_cache out err rc comments bulk-list CB-3 <<<'{"a": 1}'
assert_eq "an issue with no comments alone exits zero" "$rc" 0
assert_jq "an issue with no comments alone reads as an empty list" "$out" '. == {"CB-3": []}'

run_cache out err rc comments bulk-list CB-1 --format=raw
assert_jq "raw format keeps the cached comment nodes" "$out" '.["CB-1"][1].user == {name: "Bo"}'

stdin_rc=0
stdin_out="$(cd "$TMP_ROOT" && printf 'CB-1\n\nCB-3\n' | bash "$LINEAR" cache comments bulk-list --stdin)" || stdin_rc=$?
assert_eq "--stdin exits zero" "$stdin_rc" 0
assert_jq "--stdin reads one identifier per line" "$stdin_out" 'keys_unsorted == ["CB-1", "CB-3"]'

# A list written without a final newline (printf '%s', an editor's Write).
run_cache out err rc comments bulk-list --stdin < <(printf 'CB-3\nCB-2')
assert_jq "--stdin keeps a last identifier with no newline" "$out" 'keys_unsorted == ["CB-3", "CB-2"]'

# --- a missing issue ---------------------------------------------------------
run_cache out err rc comments bulk-list CB-1 CB-9 CB-8
assert_ne "an identifier the cache does not hold exits nonzero" "$rc" 0
assert_eq "a missing issue puts nothing on stdout" "$out" ""
assert_jq "a missing issue names every missing identifier" "$err" '.missing == ["CB-9", "CB-8"]'
assert_jq "a missing issue is not reported as an unreadable cache" "$err" 'has("path") | not'

# --- an unreadable comment file ----------------------------------------------
printf '%s' '[{"id": "c-2a", "body": "trunc' >"$CACHE/comments/CB-2.json"
run_cache out err rc comments bulk-list CB-1 CB-2
assert_ne "an unreadable comment file exits nonzero" "$rc" 0
assert_eq "an unreadable comment file puts nothing on stdout" "$out" ""
assert_contains "an unreadable comment file names its path" "$err" "\"path\":\"$CACHE/comments/CB-2.json\""
assert_not_contains "an unreadable comment file is not reported as a missing issue" "$err" '"missing"'

printf '%s\n' '{"id": "c-2a"}' >"$CACHE/comments/CB-2.json"
run_cache out err rc comments bulk-list CB-1 CB-2
assert_ne "a comment file holding no list exits nonzero" "$rc" 0
assert_contains "a comment file holding no list names its path" "$err" "\"path\":\"$CACHE/comments/CB-2.json\""
printf '%s\n' "$GOOD_CB2" >"$CACHE/comments/CB-2.json"

# --- an unreadable issue cache -----------------------------------------------
cp "$CACHE/issues.json" "$TMP_ROOT/issues.json.good"
printf '%s' '[{"id": "uuid-CB-1", "identifier": "CB-1"' >"$CACHE/issues.json"
run_cache out err rc comments bulk-list CB-1
assert_ne "an unreadable issues.json exits nonzero" "$rc" 0
assert_contains "an unreadable issues.json names its path" "$err" "\"path\":\"$CACHE/issues.json\""
cp "$TMP_ROOT/issues.json.good" "$CACHE/issues.json"

# --- refused requests --------------------------------------------------------
run_cache out err rc comments bulk-list
assert_ne "no identifiers exits nonzero" "$rc" 0
assert_contains "no identifiers says none were provided" "$err" "No issue identifiers provided"
run_cache out err rc comments bulk-list CB-1 --since 7d
assert_ne "an unknown flag exits nonzero" "$rc" 0
assert_contains "an unknown flag is named as one" "$err" "Unknown flag for cache comments bulk-list: --since"
run_cache out err rc comments bulk-list CB-1 --format=ids
assert_ne "an unsupported format exits nonzero" "$rc" 0
assert_contains "an unsupported format is named as one" "$err" "Invalid format: ids"
run_cache out err rc comments bulk-list $'CB-1\nCB-2'
assert_ne "an identifier with a line break exits nonzero" "$rc" 0

# --- the per-issue read is unchanged -----------------------------------------
run_cache out err rc comments list CB-1
assert_jq "comments list still prints one issue's safe comments" "$out" \
  'map(.user) == ["Ada", "Bo"]'

# --- failed cache discovery --------------------------------------------------
mv "$CACHE/meta.json" "$TMP_ROOT/meta.json.parked"
run_cache out err rc comments bulk-list CB-1
assert_ne "a cache with no meta.json exits nonzero" "$rc" 0
assert_contains "a cache with no meta.json says no cache was found" "$err" "No cache found"
mv "$TMP_ROOT/meta.json.parked" "$CACHE/meta.json"

missing_root_rc=0
missing_root_err="$(cd "$TMP_ROOT" && LINEAR_CACHE_ROOT="$TMP_ROOT/absent" bash "$LINEAR" cache comments bulk-list CB-1 2>&1 >/dev/null)" ||
  missing_root_rc=$?
assert_ne "a cache root that does not exist exits nonzero" "$missing_root_rc" 0
assert_contains "a cache root that does not exist is named" "$missing_root_err" "LINEAR_CACHE_ROOT is not an existing directory"
