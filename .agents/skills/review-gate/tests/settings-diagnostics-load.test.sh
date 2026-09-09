#!/usr/bin/env bash
# settings.sh must report its stable load error before Bash 3.2 can exit on a
# missing file passed to the source builtin.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf -- "${TMP:?}"' EXIT
mkdir -p "$TMP/lib"
cp "$SKILL_DIR/scripts/lib/settings.sh" "$TMP/lib/"

rc=0
output="$(bash -c '. "$1"' bash "$TMP/lib/settings.sh" 2>&1)" || rc=$?
first="${output%%$'\n'*}"
printf -v expected_path '%q' "$TMP/lib/diagnostics.sh"
expected="review-gate-error=diagnostics-load value=$expected_path"
if [ "$rc" = 1 ] && [ "$first" = "$expected" ]; then
  printf 'test-pass=settings-diagnostics-load value=missing\n'
else
  printf 'test-failure=settings-diagnostics-load value=missing\nrc=%s expected=%q actual=%q\n' "$rc" "$expected" "$first" >&2
  exit 1
fi
