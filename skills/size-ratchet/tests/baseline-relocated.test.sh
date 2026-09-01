#!/usr/bin/env bash
# One fail-closed control for a baseline path that HEAD did not judge.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SR="$TEST_DIR/../scripts/size-ratchet"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_CLASSES SIZE_RATCHET_DEFAULT_CLASSES SIZE_RATCHET_FROZEN_CLASSES SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE RATCHET_RAISE 2>/dev/null || true
export SIZE_RATCHET_THRESHOLD=10 SIZE_RATCHET_DEFAULT_CLASSES="" SIZE_RATCHET_FROZEN_CLASSES="*.test.*"

R="$TMP/repo"
mkdir -p "$R/tools"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
awk 'BEGIN { for (i = 1; i <= 15; i++) print "line " i }' >"$R/big.test.txt"
printf 'big.test.txt\t15\n' >"$R/tools/a.tsv"
printf '[env]\nSIZE_RATCHET_BASELINE = "tools/a.tsv"\n' >"$R/kendex.settings.toml"
git -C "$R" add -A
git -C "$R" commit -q -m seed

awk 'BEGIN { for (i = 1; i <= 20; i++) print "line " i }' >"$R/big.test.txt"
printf 'big.test.txt\t20\n' >"$R/tools/size-ratchet-baseline.tsv"
rm "$R/kendex.settings.toml"
git -C "$R" add -A

run_relocation() {
  local mode="$1" declaration="$2"
  RC=0
  if [ "$declaration" = "yes" ]; then
    if [ -n "$mode" ]; then
      OUT="$(cd "$R" && RATCHET_RAISE=1 "$SR" "$mode" 2>&1)" || RC=$?
    else
      OUT="$(cd "$R" && RATCHET_RAISE=1 "$SR" 2>&1)" || RC=$?
    fi
  else
    if [ -n "$mode" ]; then
      OUT="$(cd "$R" && "$SR" "$mode" 2>&1)" || RC=$?
    else
      OUT="$(cd "$R" && "$SR" 2>&1)" || RC=$?
    fi
  fi
}

FAIL=0
for mode in "" --staged; do
  run_relocation "$mode" no
  [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -Fq 'baseline has rows but HEAD has none at tools/size-ratchet-baseline.tsv' \
    || { printf 'FAIL: %s relocation passed without RATCHET_RAISE=1\nrc=%s\n%s\n' "${mode:-default}" "$RC" "$OUT" >&2; FAIL=1; }

  run_relocation "$mode" yes
  [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -Fq 'frozen row cannot cross an unverified baseline relocation: big.test.txt' \
    || { printf 'FAIL: %s relocation admitted a changed frozen row\nrc=%s\n%s\n' "${mode:-default}" "$RC" "$OUT" >&2; FAIL=1; }
done

SIZE_RATCHET_FROZEN_CLASSES="" run_relocation --staged yes
[ "$RC" -eq 0 ] || { printf 'FAIL: declared open-row relocation rc=%s\n%s\n' "$RC" "$OUT" >&2; exit 1; }
[ "$FAIL" -eq 0 ] || exit 1

printf 'baseline-relocated.test.sh: PASS\n'
