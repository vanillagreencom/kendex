#!/usr/bin/env bash
# bash-runtime: 4
# Tests for comments create --id: the caller's comment identity reaches Linear's create input.

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
printf '{"data":{"commentCreate":{"success":true,"comment":{"id":"5b0c8c52-4f43-4d4e-9d8e-2a1f6c3e7b10","body":"ok","createdAt":"2026-11-24T00:00:00Z","updatedAt":"2026-11-24T00:00:00Z","user":{"name":"Test"},"issue":{"identifier":"PROJ-1","updatedAt":"2026-11-24T00:00:00Z"}}}}}___HTTP_CODE___200'
SH
chmod +x "$TMP_ROOT/bin/curl"

export CURL_CONFIG_CAPTURE="$TMP_ROOT/curl-config.txt"
id=5b0c8c52-4f43-4d4e-9d8e-2a1f6c3e7b10
for given in with-id without-id; do
  rm -f -- "${CURL_CONFIG_CAPTURE:?}"
  args=(comments create PROJ-1 --body reply --parent parent-1)
  [[ "$given" == without-id ]] || args+=(--id "$id")
  rc=0
  out="$(PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam \
    bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" "${args[@]}" 2>&1)" || rc=$?
  assert_eq "comments create $given exits zero" "$rc" 0
  payload="$(sed -n 's/^data = //p' "$CURL_CONFIG_CAPTURE" | jq -r)"
  if [[ "$given" == with-id ]]; then
    assert_jq "comments create --id sends the comment's own id beside its parent" "$payload" \
      ".variables.input.id == \"$id\" and .variables.input.parentId == \"parent-1\""
  else
    assert_jq "comments create without --id lets Linear mint the id" "$payload" \
      '.variables.input | has("id") | not'
  fi
done
