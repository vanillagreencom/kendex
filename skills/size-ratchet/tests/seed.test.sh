#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SR="$TEST_DIR/../scripts/size-ratchet"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_CLASSES SIZE_RATCHET_DEFAULT_CLASSES SIZE_RATCHET_FROZEN_CLASSES SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE RATCHET_RAISE 2>/dev/null || true
export SIZE_RATCHET_THRESHOLD=10 SIZE_RATCHET_DEFAULT_CLASSES="" SIZE_RATCHET_FROZEN_CLASSES=""

new_repo() {
  R="$TMP/$1"
  mkdir -p "$R/tools"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}

run_seed() {
  RC=0
  OUT="$(cd "$R" && RATCHET_RAISE=1 "$SR" --seed 2>&1)" || RC=$?
}

new_repo fresh
awk 'BEGIN { for (i = 1; i <= 15; i++) print "line " i }' >"$R/big.txt"
awk 'BEGIN { for (i = 1; i <= 5; i++) print "line " i }' >"$R/small.txt"
: >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_seed
[ "$RC" -eq 0 ] || { printf 'FAIL: first seed rc=%s\n%s\n' "$RC" "$OUT" >&2; exit 1; }
[ "$(cat "$R/tools/size-ratchet-baseline.tsv")" = "$(printf 'big.txt\t15')" ] \
  || { printf 'FAIL: seed rows\n' >&2; exit 1; }

run_seed
[ "$RC" -eq 2 ] || { printf 'FAIL: populated baseline reseeded rc=%s\n%s\n' "$RC" "$OUT" >&2; exit 1; }

new_repo malformed
printf 'not a row\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_seed
[ "$RC" -eq 2 ] || { printf 'FAIL: malformed baseline accepted rc=%s\n%s\n' "$RC" "$OUT" >&2; exit 1; }

printf 'seed.test.sh: PASS\n'
