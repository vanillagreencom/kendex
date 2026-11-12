#!/usr/bin/env bash
# bash-runtime: 4
# Tests for comments --body-file parsing without invoking the real API.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"

cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
printf '%s\n' "$config" > "${CURL_CONFIG_CAPTURE:?}"
printf '{"data":{"commentCreate":{"success":true,"comment":{"id":"comment-1","body":"ok","createdAt":"2026-06-13T00:00:00Z","updatedAt":"2026-06-13T00:00:00Z","user":{"name":"Test"},"issue":{"identifier":"PROJ-1","updatedAt":"2026-06-13T00:00:00Z"}}}}}___HTTP_CODE___200'
SH
chmod +x "$TMP_ROOT/bin/curl"

body_file="$TMP_ROOT/comment.md"
cat >"$body_file" <<'MD'
## Completion Summary

`code` and multi-line markdown.
MD

export CURL_CONFIG_CAPTURE="$TMP_ROOT/curl-config.txt"
rc=0
out="$(PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" comments create PROJ-1 --body-file "$body_file" 2>&1)" || rc=$?

assert_eq "comments create --body-file exits zero" "$rc" 0
assert_jq "comments create --body-file reports the created comment" \
  "$out" '.success == true and .data.comment.id == "comment-1"'

payload="null"
if [[ -f "$CURL_CONFIG_CAPTURE" ]]; then
  payload="$(sed -n 's/^data = //p' "$CURL_CONFIG_CAPTURE" | jq -r)"
fi
body="$(jq -r '.variables.input.body // ""' <<<"$payload")"

assert_contains "the --body-file payload carries the file's heading" "$body" "Completion Summary"
assert_contains "the --body-file payload carries the file's markdown verbatim" \
  "$body" '`code` and multi-line markdown.'

for ending in '' $'\n' $'\n\n' nul; do
    if [[ "$ending" == nul ]]; then
        # The JSON text action can carry U+0000; a Bash variable cannot.
        printf '%s\000%s' 'Owner action' '<!-- jarvis-owner-action:unique -->' >"$body_file"
    else
        printf '%s%s' '-n owner action\n<!-- jarvis-owner-action:unique -->' "$ending" >"$body_file"
    fi
    rc=0
    PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam \
        "$BASH" "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" comments create PROJ-1 \
        --body-file "$body_file" >"$TMP_ROOT/exact.out" 2>"$TMP_ROOT/exact.err" || rc=$?
    assert_eq "the exact-byte comment write succeeds" "$rc" 0
    payload="$(sed -n 's/^data = //p' "$CURL_CONFIG_CAPTURE" | jq -r)"
    assert_jq "the posted body preserves every file byte for recovery" \
        "$(jq --rawfile expected "$body_file" '. + {expected: $expected}' <<<"$payload")" \
        '.variables.input.body == .expected'
done

conflict_rc=0
PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" comments create PROJ-1 --body inline --body-file "$body_file" >"$TMP_ROOT/conflict.out" 2>&1 || conflict_rc=$?

assert_ne "comments create refuses both --body and --body-file" "$conflict_rc" 0

