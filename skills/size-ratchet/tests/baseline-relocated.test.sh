#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SR="$TEST_DIR/../scripts/size-ratchet"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_CLASSES SIZE_RATCHET_DEFAULT_CLASSES SIZE_RATCHET_FROZEN_CLASSES SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE RATCHET_RAISE 2>/dev/null || true
export SIZE_RATCHET_THRESHOLD=10 SIZE_RATCHET_DEFAULT_CLASSES=""

new_repo() {
  R="$TMP/$1"
  mkdir -p "$R/tools"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}

mkfile() {
  awk -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) print "line " i }' >"$R/$1"
}

run_check() {
  local mode="$1" declaration="$2" frozen="$3"
  RC=0
  if [ -n "$mode" ]; then
    OUT="$(cd "$R" && RATCHET_RAISE="$declaration" SIZE_RATCHET_FROZEN_CLASSES="$frozen" SIZE_RATCHET_SETTINGS_FILE="$SETTINGS_FILE" "$SR" "$mode" 2>&1)" || RC=$?
  else
    OUT="$(cd "$R" && RATCHET_RAISE="$declaration" SIZE_RATCHET_FROZEN_CLASSES="$frozen" SIZE_RATCHET_SETTINGS_FILE="$SETTINGS_FILE" "$SR" 2>&1)" || RC=$?
  fi
}

FAIL=0
while IFS='|' read -r label mode declaration frozen dormant source expect_rc expect_text; do
  [ -n "$label" ] || continue
  new_repo "$label"
  if [ -n "$frozen" ]; then path=big.test.txt; else path=big.txt; fi
  mkfile "$path" 15
  printf '%s\t15\n' "$path" >"$R/tools/active.tsv"
  if [ "$dormant" = yes ]; then printf '%s\t20\n' "$path" >"$R/tools/target.tsv"; fi
  case "$source" in
    nested) SETTINGS_FILE=.kendex/settings.toml ;;
    explicit) SETTINGS_FILE=policy/settings.toml ;;
    *) SETTINGS_FILE=kendex.settings.toml ;;
  esac
  case "$SETTINGS_FILE" in */*) mkdir -p "$R/${SETTINGS_FILE%/*}" ;; esac
  printf '[env]\nSIZE_RATCHET_BASELINE = "tools/active.tsv"\n' >"$R/$SETTINGS_FILE"
  git -C "$R" add -A
  git -C "$R" commit -q -m active
  mkfile "$path" 20
  if [ "$dormant" = no ]; then printf '%s\t20\n' "$path" >"$R/tools/target.tsv"; fi
  printf '[env]\nSIZE_RATCHET_BASELINE = "tools/target.tsv"\n' >"$R/$SETTINGS_FILE"
  git -C "$R" add -A
  run_check "$mode" "$declaration" "$frozen"
  if [ "$RC" -ne "$expect_rc" ] || { [ -n "$expect_text" ] && ! printf '%s\n' "$OUT" | grep -Fq "$expect_text"; }; then
    printf 'FAIL: %s\nrc=%s expected=%s\n%s\n' "$label" "$RC" "$expect_rc" "$OUT" >&2
    FAIL=$((FAIL + 1))
  fi
done <<'CASES'
default-open-undeclared||0||no|root|1|baseline row raised: big.txt — row 15 -> 20 lines
staged-open-undeclared|--staged|0||no|root|1|baseline row raised: big.txt — row 15 -> 20 lines
default-open-declared||1||no|root|0|
staged-open-declared|--staged|1||no|root|0|
default-frozen-declared||1|*.test.*|no|root|1|frozen baseline row raised: big.test.txt — row 15 -> 20 lines
staged-frozen-declared|--staged|1|*.test.*|no|root|1|frozen baseline row raised: big.test.txt — row 15 -> 20 lines
default-dormant-target||0||yes|root|1|baseline row raised: big.txt — row 15 -> 20 lines
staged-dormant-target|--staged|0||yes|root|1|baseline row raised: big.txt — row 15 -> 20 lines
nested-head-settings||0||no|nested|1|baseline row raised: big.txt — row 15 -> 20 lines
explicit-head-settings||0||no|explicit|1|baseline row raised: big.txt — row 15 -> 20 lines
CASES

while IFS='|' read -r label declaration frozen expect_rc expect_text; do
  [ -n "$label" ] || continue
  new_repo "$label"
  if [ -n "$frozen" ]; then path=big.test.txt; else path=big.txt; fi
  mkfile "$path" 15
  printf '%s\t15\n' "$path" >"$R/tools/active.tsv"
  SETTINGS_FILE=kendex.settings.toml
  printf '[env]\nSIZE_RATCHET_BASELINE = "tools/active.tsv"\n' >"$R/$SETTINGS_FILE"
  git -C "$R" add -A
  git -C "$R" commit -q -m active
  mkfile "$path" 20
  : >"$R/tools/target.tsv"
  printf '[env]\nSIZE_RATCHET_BASELINE = "tools/target.tsv"\n' >"$R/$SETTINGS_FILE"
  git -C "$R" add -A
  run_check --seed "$declaration" "$frozen"
  if [ "$RC" -ne "$expect_rc" ] || { [ -n "$expect_text" ] && ! printf '%s\n' "$OUT" | grep -Fq "$expect_text"; }; then
    printf 'FAIL: %s\nrc=%s expected=%s\n%s\n' "$label" "$RC" "$expect_rc" "$OUT" >&2
    FAIL=$((FAIL + 1))
  fi
done <<'SEED_CASES'
seed-repoint-open-undeclared|0||1|baseline row raised: big.txt — row 15 -> 20 lines
seed-repoint-open-declared|1||0|
seed-repoint-frozen-declared|1|*.test.*|1|frozen baseline row raised: big.test.txt — row 15 -> 20 lines
SEED_CASES

[ "$FAIL" -eq 0 ] || exit 1
printf 'baseline-relocated.test.sh: PASS\n'
