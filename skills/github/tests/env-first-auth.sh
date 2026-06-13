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
  [[ "${GH_TOKEN:-}" == "ghs_ROUTERBOT123" ]]
}

case "${1:-}" in
  auth)
    if [[ "${2:-}" == "status" ]]; then
      _token_ok || { echo "auth failed" >&2; exit 1; }
      echo "Logged in"
      exit 0
    fi
    ;;
  pr)
    if [[ "${2:-}" == "view" ]]; then
      _token_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo '{"number":42,"state":"OPEN"}'
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

cat > "$TMP_ROOT/repo/.env.local" <<'ENVEOF'
GH_TOKEN=op://vault/github/user
GH_BOT_TOKEN=op://vault/github/bot
ENVEOF
rm -f "$TMP_ROOT/op.calls"
output=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" GH_BOT_TOKEN=ghs_ROUTERBOT123 "$REPO_ROOT/skills/github/scripts/github.sh" -C "$TMP_ROOT/repo" pr-view --json number,state)
assert_eq "$(jq -r .number <<<"$output")" "42" "github.sh router uses inherited GH_BOT_TOKEN over local GH_TOKEN"
assert_file_missing "$TMP_ROOT/op.calls" "github.sh router avoids op when inherited GH_BOT_TOKEN is resolved"

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
