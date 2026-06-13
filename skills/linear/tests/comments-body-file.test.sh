#!/usr/bin/env bash
# Regression test for comments --body-file parsing without invoking the real API.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

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
out="$(PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY=test-token bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" comments create PROJ-1 --body-file "$body_file")"

if ! jq -e '.success == true and .data.comment.id == "comment-1"' >/dev/null <<<"$out"; then
  echo "FAIL comments create --body-file returned unexpected output: $out"
  exit 1
fi

payload="$(sed -n 's/^data = //p' "$CURL_CONFIG_CAPTURE" | jq -r)"
body="$(jq -r '.variables.input.body' <<<"$payload")"
if [[ "$body" != *"Completion Summary"* || "$body" != *'`code` and multi-line markdown.'* ]]; then
  echo "FAIL --body-file payload did not include markdown body: $body"
  exit 1
fi

set +e
PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY=test-token bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" comments create PROJ-1 --body inline --body-file "$body_file" >"$TMP_ROOT/conflict.out" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL comments create accepted both --body and --body-file"
  exit 1
fi

echo "all pass"
