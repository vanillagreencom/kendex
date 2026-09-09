#!/usr/bin/env bash
# rg_message's first record is the public diagnostic key/value protocol.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../scripts/lib/diagnostics.sh"
count=0
while IFS='|' read -r name kind code value want; do
  [ -n "$name" ] || continue
  count=$((count + 1))
  output="$(rg_message "$kind" "$code" "$value" explanation)"
  got="${output%%$'\n'*}"
  if [ "$got" != "$want" ]; then
    printf 'test-failure=%s value=%q\nexpected=%q actual=%q\n' "$name" "$code" "$want" "$got" >&2
    exit 1
  fi
done <<'ROWS'
error-path|error|settings-unreadable|settings.toml|review-gate-error=settings-unreadable value=settings.toml
notice-code|notice|predicate-config|valid|review-gate-notice=predicate-config value=valid
space-path|error|settings-type|my settings.toml|review-gate-error=settings-type value=my\ settings.toml
empty-value|error|arguments||review-gate-error=arguments value=''
shell-metacharacters|error|settings-key|$(false)|review-gate-error=settings-key value=\$\(false\)
ROWS
[ "$count" -gt 0 ] || { printf 'test-failure=message-rows value=0\n' >&2; exit 1; }
printf 'test-pass=diagnostics-message value=%s\n' "$count"
