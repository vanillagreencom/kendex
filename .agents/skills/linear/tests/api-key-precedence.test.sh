#!/usr/bin/env bash
# the project's own key must win over an inherited one.
#
# Per-repo Linear workspaces make a box-global LINEAR_API_KEY export actively
# wrong for every other repo, so the precedence is: LINEAR_API_KEY_OVERRIDE
# (explicit inline/test channel), then project files (settings [env] →
# .env.local), then plain inherited env only when no file provides a key. When
# an inherited key is silently shadowed by a differing file key, auth-check
# must warn — with key fingerprints, never key material.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

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
  RC=0
  OUT="$(cd "$PROJECT" && env -u LINEAR_TEAM -u LINEAR_API_KEY -u LINEAR_API_KEY_OVERRIDE \
    PATH="$PROJECT/bin:$PATH" \
    AUTH_LOG="$AUTH_LOG" \
    "$@" \
    bash "$LINEAR" auth-check 2>"$ERR_FILE")" || RC=$?
}

sent_key() {
  tail -n 1 "$AUTH_LOG" 2>/dev/null || true
}

assert_source() {
  local label="$1" expected="$2"
  assert_jq "$label: api_key_source is $expected" \
    "$OUT" "$(printf '.api_key_source == "%s"' "$expected")"
}

assert_no_shadow_warning() {
  assert_jq "$1: no shadowing warning" \
    "$OUT" '[.warnings[] | select(contains("inherited LINEAR_API_KEY"))] | length == 0'
}

echo "=== a project-file key beats a plain inherited env key ==="

printf 'LINEAR_API_KEY=%s\n' "$FILE_KEY" >"$PROJECT/.env.local"

run_auth LINEAR_API_KEY="$ENV_KEY"
assert_eq "auth-check exits zero with a file key" "$RC" 0
assert_source "file key beats inherited env" "project-config"
assert_eq "the project key, not the inherited one, reaches the wire" "$(sent_key)" "$FILE_KEY"

echo "=== the shadowing warning fires exactly when env and file keys differ ==="

env_fp="$(fingerprint "$ENV_KEY")"
file_fp="$(fingerprint "$FILE_KEY")"
assert "the shadowing warning carries both key fingerprints" \
  jq -e --arg env "sha256:$env_fp" --arg file "sha256:$file_fp" \
  '[.warnings[] | select(contains("inherited LINEAR_API_KEY") and contains($env) and contains($file) and contains("using project-config"))] | length == 1' <<<"$OUT" 
assert_not_contains "the warning does not leak the inherited key material" "$OUT" "$ENV_KEY"
assert_not_contains "the warning does not leak the project key material" "$OUT" "$FILE_KEY"

# Identical env and file keys: nothing is being shadowed.
run_auth LINEAR_API_KEY="$FILE_KEY"
assert_eq "auth-check exits zero with identical keys" "$RC" 0
assert_source "identical keys" "project-config"
assert_no_shadow_warning "identical keys"

# Only the file key: nothing inherited, nothing to warn about.
run_auth
assert_eq "auth-check exits zero with only a file key" "$RC" 0
assert_source "file key only" "project-config"
assert_no_shadow_warning "file key only"
assert_eq "the file key reaches the wire" "$(sent_key)" "$FILE_KEY"

echo "=== LINEAR_API_KEY_OVERRIDE beats the project files ==="

run_auth LINEAR_API_KEY="$ENV_KEY" LINEAR_API_KEY_OVERRIDE="$OVERRIDE_KEY"
assert_eq "auth-check exits zero with an override" "$RC" 0
assert_source "override beats the project files" "override"
assert_no_shadow_warning "override"
assert_eq "the override key reaches the wire" "$(sent_key)" "$OVERRIDE_KEY"

echo "=== a .env key is read by nothing ==="

# The loader dropped the .env layer, so a key there supplies no project
# config at all: with .env.local removed, the run resolves from the .env
# key's absence — inherited env when set, nothing otherwise. Would fail
# against a loader that still read .env (source would be project-config).
mv "$PROJECT/.env.local" "$PROJECT/.env.local.aside"
printf 'LINEAR_API_KEY=%s\n' "dot-env-key" >"$PROJECT/.env"
run_auth LINEAR_API_KEY="$ENV_KEY"
assert_source "a .env key supplies no project config" "environment"
assert_eq "no .env key reaches the wire" "$(sent_key)" "$ENV_KEY"
rm -f "$PROJECT/.env"
mv "$PROJECT/.env.local.aside" "$PROJECT/.env.local"

echo "=== inherited env is used only when no file provides a key ==="

rm -f "$PROJECT/.env.local"

run_auth LINEAR_API_KEY="$ENV_KEY"
assert_eq "auth-check exits zero with only an env key" "$RC" 0
assert_source "inherited env with no file key" "environment"
assert_no_shadow_warning "env key only"
assert_eq "the inherited env key reaches the wire" "$(sent_key)" "$ENV_KEY"

echo "=== no key anywhere reports unset and fails ==="

run_auth
assert_ne "auth-check fails with no key anywhere" "$RC" 0
assert_jq "auth-check reports the key as unset" "$OUT" '.ok == false and .api_key_source == "unset"'
assert_not "no request is sent with no key" test -s "$AUTH_LOG"

