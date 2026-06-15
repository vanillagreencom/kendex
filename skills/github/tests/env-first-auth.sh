#!/usr/bin/env bash
# Regression tests for env-first GitHub token loading.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_file_missing() {
  local path="$1" name="$2"
  if [[ ! -e "$path" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unexpected file: %s\n' "$name" "$path"
  fi
}

mkdir -p "$TMP_ROOT/repo" "$TMP_ROOT/bin"
git -C "$TMP_ROOT/repo" init -q

cat > "$TMP_ROOT/bin/op" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'op called: %s\n' "\$*" >>"$TMP_ROOT/op.calls"
if [[ "\${1:-}" == "read" && "\${2:-}" == "op://vault/github/bot" ]]; then
  printf '%s\n' 'ghs_RESOLVED123'
  exit 0
fi
exit 1
EOF
chmod +x "$TMP_ROOT/bin/op"

cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

_token_ok() {
  local tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -n "$tok" ]]; then
    [[ "$tok" == "ghs_ROUTERBOT123" || "$tok" == "gho_DIRECT456" ]]
    return
  fi
  [[ "${STUB_KEYRING_OK:-0}" == "1" ]]
}

case "${1:-}" in
  auth)
    if [[ "${2:-}" == "status" ]]; then
      _token_ok || { echo "auth failed" >&2; exit 1; }
      echo "Logged in"
      exit 0
    fi
    ;;
  api)
    if [[ "${2:-}" == "user" ]]; then
      _token_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "test-user"
      exit 0
    fi
    ;;
  pr)
    if [[ "${2:-}" == "view" ]]; then
      _token_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo '{"number":42,"state":"OPEN"}'
      exit 0
    fi
    if [[ "${2:-}" == "edit" ]]; then
      _token_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "updated"
      exit 0
    fi
    ;;
  issue)
    if [[ "${2:-}" == "edit" ]]; then
      _token_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "updated"
      exit 0
    fi
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"

load_token() {
  (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" env "$@" bash -c '
    set -euo pipefail
    source "'"$REPO_ROOT"'/skills/github/scripts/lib/github-api.sh"
    load_bot_token
  ')
}

echo "=== github env-first auth loading ==="

cat > "$TMP_ROOT/repo/.env.local" <<'ENVEOF'
GH_BOT_TOKEN=op://vault/github/bot
ENVEOF
rm -f "$TMP_ROOT/op.calls"
output=$(load_token GH_TOKEN=ghp_ENV123)
assert_eq "$output" "ghp_ENV123" "resolved GH_TOKEN wins over .env.local"
assert_file_missing "$TMP_ROOT/op.calls" "resolved GH_TOKEN does not trigger op"

rm -f "$TMP_ROOT/op.calls"
output=$(load_token GITHUB_TOKEN=gho_ENV456)
assert_eq "$output" "gho_ENV456" "resolved GITHUB_TOKEN wins over .env.local"
assert_file_missing "$TMP_ROOT/op.calls" "resolved GITHUB_TOKEN does not trigger op"

rm -f "$TMP_ROOT/op.calls"
output=$(load_token GH_BOT_TOKEN=ghs_ENVBOT789)
assert_eq "$output" "ghs_ENVBOT789" "resolved GH_BOT_TOKEN wins before project files"
assert_file_missing "$TMP_ROOT/op.calls" "resolved GH_BOT_TOKEN does not trigger op"

rm -f "$TMP_ROOT/op.calls"
output=$(load_token GH_TOKEN=ghp_USER123 GH_BOT_TOKEN=ghs_BOT123)
assert_eq "$output" "ghs_BOT123" "explicit GH_BOT_TOKEN wins for bot-token loader"
assert_file_missing "$TMP_ROOT/op.calls" "explicit GH_BOT_TOKEN with GH_TOKEN does not trigger op"

rm -f "$TMP_ROOT/op.calls"
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" GH_BOT_TOKEN=ghs_ROUTERBOT123 "$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" bot-token --format=text)
assert_eq "$output" "configured" "github.sh router preserves resolved GH_BOT_TOKEN"
assert_file_missing "$TMP_ROOT/op.calls" "github.sh router does not trigger op for resolved GH_BOT_TOKEN"

rm -f "$TMP_ROOT/op.calls"
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" GH_BOT_TOKEN=ghs_ROUTERBOT123 GITHUB_TOKEN=gho_OTHERUSER "$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" pr-view --json number,state)
assert_eq "$(jq -r .number <<<"$output")" "42" "github.sh router promotes GH_BOT_TOKEN over GITHUB_TOKEN"
assert_file_missing "$TMP_ROOT/op.calls" "github.sh router avoids op when GH_BOT_TOKEN beats GITHUB_TOKEN"

cat > "$TMP_ROOT/repo/.env.local" <<'ENVEOF'
GH_TOKEN=op://vault/github/user
GH_BOT_TOKEN=op://vault/github/bot
ENVEOF
rm -f "$TMP_ROOT/op.calls"
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" GH_BOT_TOKEN=ghs_ROUTERBOT123 "$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" pr-view --json number,state)
assert_eq "$(jq -r .number <<<"$output")" "42" "github.sh router uses inherited GH_BOT_TOKEN over local GH_TOKEN"
assert_file_missing "$TMP_ROOT/op.calls" "github.sh router avoids op when inherited GH_BOT_TOKEN is resolved"

cat > "$TMP_ROOT/repo/.env.local" <<'ENVEOF'
GH_BOT_TOKEN=op://vault/github/bot
ENVEOF
rm -f "$TMP_ROOT/op.calls"
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" GH_TOKEN=op://vault/github/user GITHUB_TOKEN=gho_DIRECT456 "$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" pr-view --json number,state)
assert_eq "$(jq -r .number <<<"$output")" "42" "github.sh router uses direct GITHUB_TOKEN over unresolved GH_TOKEN"
assert_file_missing "$TMP_ROOT/op.calls" "github.sh router does not resolve stale GH_TOKEN when direct GITHUB_TOKEN exists"

cat > "$TMP_ROOT/repo/.env.local" <<'ENVEOF'
GH_TOKEN=op://vault/github/user
ENVEOF
rm -f "$TMP_ROOT/op.calls"
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" STUB_KEYRING_OK=1 "$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" pr-view --json number,state)
assert_eq "$(jq -r .number <<<"$output")" "42" "github.sh router falls back to keyring for unresolved GH_TOKEN"
assert_eq "$(wc -l <"$TMP_ROOT/op.calls")" "1" "unresolved GH_TOKEN attempts op once before keyring fallback"

rm -f "$TMP_ROOT/op.calls"
(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" STUB_KEYRING_OK=1 GH_TOKEN=op://vault/github/user "$REPO_ROOT/skills/github/scripts/commands/label-add.sh" 42 defer-ci >/dev/null)
assert_eq "$(wc -l <"$TMP_ROOT/op.calls")" "1" "label-add falls back to keyring for unresolved GH_TOKEN"

rm -f "$TMP_ROOT/op.calls"
(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" STUB_KEYRING_OK=1 GITHUB_TOKEN=op://vault/github/user "$REPO_ROOT/skills/github/scripts/commands/label-remove.sh" 42 defer-ci >/dev/null)
assert_eq "$(wc -l <"$TMP_ROOT/op.calls")" "1" "label-remove falls back to keyring for unresolved GITHUB_TOKEN"

cat > "$TMP_ROOT/repo/.env.local" <<'ENVEOF'
GH_BOT_TOKEN=ghs_ROUTERBOT123
ENVEOF
rm -f "$TMP_ROOT/op.calls"
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" "$REPO_ROOT/skills/github/scripts/commands/label-add.sh" 42 defer-ci)
assert_eq "$output" "updated" "direct label-add loads project GH_BOT_TOKEN"
assert_file_missing "$TMP_ROOT/op.calls" "direct label-add project direct token avoids op"

rm -f "$TMP_ROOT/op.calls"
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" "$REPO_ROOT/skills/github/scripts/commands/label-remove.sh" 42 defer-ci)
assert_eq "$output" "updated" "direct label-remove loads project GH_BOT_TOKEN"
assert_file_missing "$TMP_ROOT/op.calls" "direct label-remove project direct token avoids op"

rm -f "$TMP_ROOT/op.calls"
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" "$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" label-add 42 defer-ci)
assert_eq "$output" "updated" "github.sh router loads project GH_BOT_TOKEN for label-add"
assert_file_missing "$TMP_ROOT/op.calls" "label-add project direct token avoids op"

rm -f "$TMP_ROOT/op.calls"
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" "$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" label-remove 42 defer-ci)
assert_eq "$output" "updated" "github.sh router loads project GH_BOT_TOKEN for label-remove"
assert_file_missing "$TMP_ROOT/op.calls" "label-remove project direct token avoids op"

cat > "$TMP_ROOT/repo/.env.local" <<'ENVEOF'
# no GitHub token
ENVEOF
rm -f "$TMP_ROOT/op.calls"
set +e
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" STUB_KEYRING_OK=1 GH_BOT_TOKEN=ghs_BADBOT "$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" pr-view --json number,state 2>/dev/null)
rc=$?
set -e
assert_eq "$rc" "3" "github.sh preserves selected GH_BOT_TOKEN instead of keyring fallback"
assert_eq "$(jq -r .status <<<"$output")" "auth_error" "selected bad GH_BOT_TOKEN reports auth error"
assert_file_missing "$TMP_ROOT/op.calls" "selected direct GH_BOT_TOKEN does not trigger op"

printf '%s\n' 'body text' >"$TMP_ROOT/pr-body.md"
rm -f "$TMP_ROOT/op.calls"
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" STUB_KEYRING_OK=1 GH_TOKEN=op://vault/github/user "$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" pr-edit-body 42 --body-file "$TMP_ROOT/pr-body.md")
assert_eq "$output" "updated" "github.sh pr-edit-body falls back to keyring for unresolved GH_TOKEN"
assert_eq "$(wc -l <"$TMP_ROOT/op.calls")" "1" "pr-edit-body unresolved GH_TOKEN attempts op once"

cat > "$TMP_ROOT/repo/.env.local" <<'ENVEOF'
GH_BOT_TOKEN=op://vault/github/bot
ENVEOF
rm -f "$TMP_ROOT/op.calls"
output=$(load_token)
assert_eq "$output" "ghs_RESOLVED123" "project op reference resolves when no env token exists"
assert_eq "$(wc -l <"$TMP_ROOT/op.calls")" "1" "project op reference calls op once"

cat > "$TMP_ROOT/repo/.env.local" <<'ENVEOF'
GH_BOT_TOKEN=ghs_FILEBOT123
ENVEOF
rm -f "$TMP_ROOT/op.calls"
output=$(load_token GH_TOKEN=op://vault/github/main)
assert_eq "$output" "ghs_FILEBOT123" "unresolved env token allows direct project token"
assert_file_missing "$TMP_ROOT/op.calls" "direct project token avoids op for inherited op reference"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
