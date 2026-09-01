#!/usr/bin/env bash
# One fail-closed control for a baseline path that HEAD did not judge.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SR="$TEST_DIR/../scripts/size-ratchet"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_CLASSES SIZE_RATCHET_DEFAULT_CLASSES SIZE_RATCHET_FROZEN_CLASSES SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE RATCHET_RAISE 2>/dev/null || true
export SIZE_RATCHET_THRESHOLD=10 SIZE_RATCHET_DEFAULT_CLASSES="" SIZE_RATCHET_FROZEN_CLASSES=""

R="$TMP/repo"
mkdir -p "$R/tools"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
awk 'BEGIN { for (i = 1; i <= 15; i++) print "line " i }' >"$R/big.txt"
printf 'big.txt\t15\n' >"$R/tools/a.tsv"
printf '[env]\nSIZE_RATCHET_BASELINE = "tools/a.tsv"\n' >"$R/kendex.settings.toml"
git -C "$R" add -A
git -C "$R" commit -q -m seed

awk 'BEGIN { for (i = 1; i <= 20; i++) print "line " i }' >"$R/big.txt"
printf 'big.txt\t20\n' >"$R/tools/b.tsv"
printf '[env]\nSIZE_RATCHET_BASELINE = "tools/b.tsv"\n' >"$R/kendex.settings.toml"
git -C "$R" add -A

RC=0
OUT="$(cd "$R" && "$SR" --staged 2>&1)" || RC=$?
if [ "$RC" -ne 1 ] || ! printf '%s\n' "$OUT" | grep -Fq 'baseline has rows but HEAD has none at tools/b.tsv'; then
  printf 'FAIL: a relocated baseline with changed rows must refuse without RATCHET_RAISE=1\nrc=%s\n%s\n' "$RC" "$OUT" >&2
  exit 1
fi

RC=0
OUT="$(cd "$R" && RATCHET_RAISE=1 "$SR" --staged 2>&1)" || RC=$?
if [ "$RC" -ne 0 ]; then
  printf 'FAIL: RATCHET_RAISE=1 must admit the reviewed relocation\nrc=%s\n%s\n' "$RC" "$OUT" >&2
  exit 1
fi

printf 'baseline-relocated.test.sh: PASS\n'
