#!/usr/bin/env bash
# `attachments list` reads, live, every uploads.linear.app file an issue
# references: its attachment records first, then links in its description and
# comments that no record already names. `attachments fetch` refuses a URL on
# any other host before it sends a credential. The download itself, its
# credential and its renewal are oauth-auth.test.sh's.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)" || exit 1
assert_tmpdir TMP_ROOT
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || exit 1

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
git -C "$TMP_ROOT" init -q -b main
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
# One issue: a record for plan.md and one for a GitHub pull request, a
# description linking plan.md again and an image, a comment linking a log.
# Linear answers KEN-404 with no issue.
cat >"$TMP_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
config=$(cat)
printf '%s\n' "$config" >>"$CALLS"
if [[ "$(sed -n 's/^data = //p' <<<"$config" | jq -r 'fromjson | .variables.id // ""')" == KEN-404 ]]; then
    printf '{"data":{"issue":null}}___HTTP_CODE___200'
    exit 0
fi
conn() { printf '{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":%s}' "$1"; }
records=$(conn '[{"id":"a1","url":"https://uploads.linear.app/o/p/plan.md","title":"docs/plans/plan.md"},{"id":"a2","url":"https://github.com/o/r/pull/1","title":"PR"}]')
comments=$(conn '[{"id":"c1","body":"log at https://uploads.linear.app/o/q/run.log?x=1","createdAt":"2026-10-01T00:00:00.000Z","updatedAt":"2026-10-01T00:00:00.000Z","user":{"name":"Fixture Person"}}]')
description='see https://uploads.linear.app/o/p/plan.md and ![s](<https://uploads.linear.app/o/i/shot.png>)'
jq -cjn --argjson records "$records" --argjson comments "$comments" --arg d "$description" \
    '{data: {issue: {id: "uuid-1", identifier: "KEN-1", description: $d, attachments: $records, comments: $comments}}}'
printf '___HTTP_CODE___200'
STUB
chmod +x "$TMP_ROOT/bin/curl"

run_attachments() {
    : >"$TMP_ROOT/calls"
    RC=0
    OUT=$(cd -- "$TMP_ROOT" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" CALLS="$TMP_ROOT/calls" \
        LINEAR_API_KEY_OVERRIDE=test-key bash .agents/skills/linear/scripts/linear.sh attachments "$@" \
        2>"$TMP_ROOT/err") || RC=$?
}

run_attachments list KEN-1
assert_eq "list: succeeds" "$RC" 0
assert_jq "list: the record comes first with its repository path" "$OUT" \
    '.[0] == {url: "https://uploads.linear.app/o/p/plan.md", source: "KEN-1", context: "attachment", filename: "plan.md", repo_path: "docs/plans/plan.md"}'
assert_jq "list: a record and a link with one url list once" "$OUT" \
    '[.[] | select(.url == "https://uploads.linear.app/o/p/plan.md")] | length == 1'
assert_jq "list: links name their context and file" "$OUT" \
    '[.[1:][] | [.context, .filename, .repo_path]] == [["description", "shot.png", null], ["comment", "run.log", null]]'
assert_jq "list: a record off the upload host is left out" "$OUT" 'all(.[]; .url | startswith("https://uploads.linear.app/"))'

run_attachments list KEN-404
assert_eq "list of a missing issue: refuses" "$RC" 1
assert_eq "list of a missing issue: prints nothing" "$OUT" ''
assert_file_contains "list of a missing issue: names the issue" "$TMP_ROOT/err" 'Issue not found: KEN-404'

run_attachments fetch https://example.invalid/file.txt --output "$TMP_ROOT/out.txt"
assert_eq "foreign host: refuses" "$RC" 1
assert_not "foreign host: sends no request" test -s "$TMP_ROOT/calls"
assert_not "foreign host: writes no file" test -e "$TMP_ROOT/out.txt"

run_attachments fetch https://uploads.linear.app/o/p/plan.md
assert_eq "fetch without --output: refuses" "$RC" 1
assert_not "fetch without --output: sends no request" test -s "$TMP_ROOT/calls"
