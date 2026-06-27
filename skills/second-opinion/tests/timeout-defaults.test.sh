#!/usr/bin/env bash
# Regression test: shipped project settings must keep the documented
# second-opinion default timeout at 300s, while caller env overrides still win.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SECOND_OPINION="$REPO_ROOT/skills/second-opinion/scripts/second-opinion"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/work"

cat > "$TMP_ROOT/bin/codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"agent":"external-codex","verdict":"pass","summary":"ok","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}'
SH
chmod +x "$TMP_ROOT/bin/codex"

assert_contains() {
  local file="$1" expected="$2" label="$3"
  if grep -Fq "$expected" "$file"; then
    printf 'PASS: %s\n' "$label"
  else
    printf 'FAIL: %s\n  expected to find: %s\n  in: %s\n' "$label" "$expected" "$file" >&2
    sed -n '1,80p' "$file" >&2 || true
    exit 1
  fi
}

default_stderr="$TMP_ROOT/default.stderr"
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=codex \
  SECOND_OPINION_CODEX_CMD=codex \
  "$SECOND_OPINION" review --cwd "$TMP_ROOT/work" >/dev/null 2>"$default_stderr"

assert_contains "$default_stderr" "timeout=300s" "default timeout resolves to documented 300s"
assert_contains "$default_stderr" "cmd: timeout 300s codex" "launch log includes explicit default timeout"

override_stderr="$TMP_ROOT/override.stderr"
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=codex \
  SECOND_OPINION_CODEX_CMD=codex \
  SECOND_OPINION_TIMEOUT=7 \
  "$SECOND_OPINION" review --cwd "$TMP_ROOT/work" >/dev/null 2>"$override_stderr"

assert_contains "$override_stderr" "timeout=7s" "caller timeout override wins"
assert_contains "$override_stderr" "cmd: timeout 7s codex" "launch log includes explicit override timeout"
