#!/usr/bin/env bash
# The retired doc-drift-check stub: a Stop payload passes at exit 0 with
# nothing on stdout or stderr, so a consumer still declaring the hook is never
# held. The control reruns the same observation on a planted copy that writes
# and refuses, and requires it to differ.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/doc-drift-check.sh}"
# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

observe() { # HOOK -> "rc=N out=<stdout> err=<stderr>"
  local rc=0 out
  out="$(printf '%s' '{"session_id":"s","stop_hook_active":false}' |
    bash "$1" 2>"$TMP_ROOT/err")" || rc=$?
  printf 'rc=%s out=%s err=%s' "$rc" "$out" "$(cat "$TMP_ROOT/err")"
}

echo "=== doc-drift-check: retired stub ==="
assert_eq "$(observe "$HOOK")" "rc=0 out= err=" "a stop passes silently"

PLANTED="$TMP_ROOT/doc-drift-check.sh"
sed 's/^exit 0$/echo held; echo held >\&2; exit 2/' "$HOOK" >"$PLANTED"
assert_eq "$(cmp -s "$HOOK" "$PLANTED" && echo unchanged || echo changed)" changed \
  "control: the planted copy differs from the hook"
assert_eq "$(observe "$PLANTED")" "rc=2 out=held err=held" \
  "control: a copy that writes and refuses is observed doing so"

printf '\n=== %s passed, %s failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
