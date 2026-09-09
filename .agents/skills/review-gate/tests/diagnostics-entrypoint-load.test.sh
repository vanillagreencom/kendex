#!/usr/bin/env bash
# Every shipped entry point must fail with the stable diagnostic when its
# diagnostics dependency is absent. The writer uses its documented read-error
# status; command-line readers use their documented could-not-run status.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf -- "${TMP:?}"' EXIT
mkdir -p "$TMP/scripts/lib"
cp "$SKILL_DIR/scripts/review-writer.sh" \
  "$SKILL_DIR/scripts/pr-watch.sh" \
  "$SKILL_DIR/scripts/review-predicate.sh" "$TMP/scripts/"
cp "$SKILL_DIR/scripts/lib/settings.sh" "$TMP/scripts/lib/"

pass=0
fail=0
while IFS='|' read -r script expected_rc; do
  rc=0
  output="$(bash "$TMP/scripts/$script" 2>&1)" || rc=$?
  first="${output%%$'\n'*}"
  printf -v expected_path '%q' "$TMP/scripts/lib/diagnostics.sh"
  expected="review-gate-error=diagnostics-load value=$expected_path"
  if [ "$rc" = "$expected_rc" ] && [ "$first" = "$expected" ]; then
    pass=$((pass + 1))
    printf '  ok    %s missing diagnostics\n' "$script"
  else
    fail=$((fail + 1))
    printf '  FAIL  %s missing diagnostics (exit %s, expected %s, diagnostic %q)\n' \
      "$script" "$rc" "$expected_rc" "$first"
  fi
done <<'CASES'
review-writer.sh|1
pr-watch.sh|2
review-predicate.sh|2
CASES

printf '\nDiagnostics entrypoint load: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
