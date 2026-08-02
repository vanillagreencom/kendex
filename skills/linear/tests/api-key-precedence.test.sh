#!/usr/bin/env bash
# Regression test (#1002): the project's own key must win over an inherited one.
#
# Per-repo Linear workspaces make a box-global LINEAR_API_KEY export actively
# wrong for every other repo, so the precedence is: LINEAR_API_KEY_OVERRIDE
# (explicit inline/test channel), then project files (.env → settings [env] →
# .env.local), then plain inherited env only when no file provides a key. When
# an inherited key is silently shadowed by a differing file key, auth-check
# must warn — with key fingerprints, never key material.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/.agents/skills" "$PROJECT/bin"
git -C "$PROJECT" init -q -b main
cp -R "$SKILL_DIR" "$PROJECT/.agents/skills/linear"

LINEAR="$PROJECT/.agents/skills/linear/scripts/linear.sh"
AUTH_LOG="$TMP_ROOT/auth-headers.log"
ERR_FILE="$TMP_ROOT/stderr.txt"

FILE_KEY="file-key-111"
ENV_KEY="env-key-222"
OVERRIDE_KEY="override-key-333"

# The stub records the Authorization header each request carries, so the
# assertions below see which key actually reached the wire.
cat >"$PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
sed -n 's/^header = "Authorization: \(.*\)"$/\1/p' <<<"$config" >>"${AUTH_LOG:?}"
printf '%s' '{"data":{"viewer":{"id":"viewer-uuid"}}}___HTTP_CODE___200'
SH
chmod +x "$PROJECT/bin/curl"

OUT=""
RC=0

fail() {
  echo "FAIL $*"
  exit 1
}

fingerprint() {
  if command -v sha256sum &>/dev/null; then
    printf '%s' "$1" | sha256sum | cut -c1-12
  else
    printf '%s' "$1" | shasum -a 256 | cut -c1-12
  fi
}

# Run auth-check with a controlled environment: the three key channels start
# absent, per-case assignments come in as arguments.
run_auth() {
  : >"$AUTH_LOG"
  set +e
  OUT="$(cd "$PROJECT" && env -u LINEAR_TEAM -u LINEAR_API_KEY -u LINEAR_API_KEY_OVERRIDE \
    PATH="$PROJECT/bin:$PATH" \
    AUTH_LOG="$AUTH_LOG" \
    "$@" \
    bash "$LINEAR" auth-check 2>"$ERR_FILE")"
  RC=$?
  set -e
}

sent_key() {
  tail -n 1 "$AUTH_LOG" 2>/dev/null || true
}

assert_source() {
  local expected="$1"
  jq -e --arg s "$expected" '.api_key_source == $s' <<<"$OUT" >/dev/null ||
    fail "expected api_key_source \"$expected\": $OUT"
}

assert_no_shadow_warning() {
  jq -e '[.warnings[] | select(contains("inherited LINEAR_API_KEY"))] | length == 0' <<<"$OUT" >/dev/null ||
    fail "unexpected shadowing warning: $OUT"
}

echo "=== a project-file key beats a plain inherited env key ==="

printf 'LINEAR_API_KEY=%s\n' "$FILE_KEY" >"$PROJECT/.env.local"

run_auth LINEAR_API_KEY="$ENV_KEY"
[[ "$RC" -eq 0 ]] || fail "auth-check exited $RC with a file key: $(cat "$ERR_FILE")"
assert_source "project-config"
[[ "$(sent_key)" == "$FILE_KEY" ]] || fail "the inherited env key shadowed the project key on the wire: $(sent_key)"

echo "=== the shadowing warning fires exactly when env and file keys differ ==="

env_fp="$(fingerprint "$ENV_KEY")"
file_fp="$(fingerprint "$FILE_KEY")"
jq -e --arg env "sha256:$env_fp" --arg file "sha256:$file_fp" \
  '[.warnings[] | select(contains("inherited LINEAR_API_KEY") and contains($env) and contains($file) and contains("using project-config"))] | length == 1' <<<"$OUT" >/dev/null ||
  fail "shadowing warning missing or missing fingerprints: $OUT"
grep -qF "$ENV_KEY" <<<"$OUT" && fail "warning leaked the inherited key material: $OUT"
grep -qF "$FILE_KEY" <<<"$OUT" && fail "warning leaked the project key material: $OUT"

# Identical env and file keys: nothing is being shadowed.
run_auth LINEAR_API_KEY="$FILE_KEY"
[[ "$RC" -eq 0 ]] || fail "auth-check exited $RC with identical keys: $(cat "$ERR_FILE")"
assert_source "project-config"
assert_no_shadow_warning

# Only the file key: nothing inherited, nothing to warn about.
run_auth
[[ "$RC" -eq 0 ]] || fail "auth-check exited $RC with only a file key: $(cat "$ERR_FILE")"
assert_source "project-config"
assert_no_shadow_warning
[[ "$(sent_key)" == "$FILE_KEY" ]] || fail "file key not used on the wire: $(sent_key)"

echo "=== LINEAR_API_KEY_OVERRIDE beats the project files ==="

run_auth LINEAR_API_KEY="$ENV_KEY" LINEAR_API_KEY_OVERRIDE="$OVERRIDE_KEY"
[[ "$RC" -eq 0 ]] || fail "auth-check exited $RC with an override: $(cat "$ERR_FILE")"
assert_source "override"
assert_no_shadow_warning
[[ "$(sent_key)" == "$OVERRIDE_KEY" ]] || fail "override key not used on the wire: $(sent_key)"

echo "=== .env.local still beats .env among the project files ==="

printf 'LINEAR_API_KEY=%s\n' "dot-env-key" >"$PROJECT/.env"
run_auth
assert_source "project-config"
[[ "$(sent_key)" == "$FILE_KEY" ]] || fail ".env.local did not win over .env: $(sent_key)"
rm -f "$PROJECT/.env"

echo "=== inherited env is used only when no file provides a key ==="

rm -f "$PROJECT/.env.local"

run_auth LINEAR_API_KEY="$ENV_KEY"
[[ "$RC" -eq 0 ]] || fail "auth-check exited $RC with only an env key: $(cat "$ERR_FILE")"
assert_source "environment"
assert_no_shadow_warning
[[ "$(sent_key)" == "$ENV_KEY" ]] || fail "inherited env key not used on the wire: $(sent_key)"

echo "=== no key anywhere reports unset and fails ==="

run_auth
[[ "$RC" -ne 0 ]] || fail "auth-check exited 0 with no key: $OUT"
jq -e '.ok == false and .api_key_source == "unset"' <<<"$OUT" >/dev/null ||
  fail "auth-check did not report an unset key: $OUT"
[[ ! -s "$AUTH_LOG" ]] || fail "a request was sent with no key: $(cat "$AUTH_LOG")"

echo "all pass"
