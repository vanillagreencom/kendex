#!/usr/bin/env bash
# Unit pins for lib/settings.sh's rg_setting contract (vstack#1059):
# leading whitespace before a key is valid TOML, so matching must be
# whitespace-tolerant EVERYWHERE — presence, the duplicate-key ambiguity
# guard, and extraction. Column-one anchoring let an indented duplicate
# bypass the fail-loud guard (the reader silently used the column-one
# value on a security-sensitive key) and made an indented sole assignment
# collapse silently to the built-in default.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../scripts/lib/settings.sh
source "$SKILL_DIR/scripts/lib/settings.sh"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

# run_setting FIXTURE-CONTENT NAME DEFAULT -> sets OUT and RC
run_setting() {
  printf '%s\n' "$1" >"$TMP/settings.toml"
  OUT=""
  RC=0
  OUT="$(REVIEW_GATE_SETTINGS_FILE="$TMP/settings.toml" rg_setting "$2" "$3" 2>"$TMP/err")" || RC=$?
}

echo "=== whitespace-tolerant reads ==="
run_setting 'REVIEW_GATE_T1 = "col1"' REVIEW_GATE_T1 "dflt"
[[ "$RC" -eq 0 && "$OUT" == "col1" ]] && ok "column-one assignment reads" || bad "column-one assignment reads" "rc=$RC out=$OUT"

run_setting '  REVIEW_GATE_T2 = "indented"' REVIEW_GATE_T2 "dflt"
[[ "$RC" -eq 0 && "$OUT" == "indented" ]] && ok "indented sole assignment reads (not the silent default)" || bad "indented sole assignment reads (not the silent default)" "rc=$RC out=$OUT"

run_setting $'[env]\nREVIEW_GATE_T3 = ""' REVIEW_GATE_T3 "dflt"
[[ "$RC" -eq 0 && "$OUT" == "" ]] && ok "explicit empty assignment overrides the default (empty-disables contract)" || bad "explicit empty assignment overrides the default" "rc=$RC out=$OUT"

run_setting 'REVIEW_GATE_T4 = "file"' REVIEW_GATE_T4 "dflt"
env_out="$(REVIEW_GATE_T4="env" REVIEW_GATE_SETTINGS_FILE="$TMP/settings.toml" rg_setting REVIEW_GATE_T4 "dflt")"
[[ "$env_out" == "env" ]] && ok "explicit environment still wins over the file" || bad "explicit environment still wins over the file" "$env_out"

echo "=== ambiguity fails loud regardless of indentation ==="
run_setting $'REVIEW_GATE_T5 = "a"\nREVIEW_GATE_T5 = "b"' REVIEW_GATE_T5 "dflt"
[[ "$RC" -ne 0 ]] && grep -q "assigned more than once" "$TMP/err" && ok "column-one duplicate is a config error (control)" || bad "column-one duplicate is a config error (control)" "rc=$RC"

run_setting $'REVIEW_GATE_T6 = "a"\n  REVIEW_GATE_T6 = "b"' REVIEW_GATE_T6 "dflt"
[[ "$RC" -ne 0 ]] && grep -q "assigned more than once" "$TMP/err" && ok "INDENTED duplicate is a config error (was invisible to the guard)" || bad "INDENTED duplicate is a config error (was invisible to the guard)" "rc=$RC out=$OUT"

run_setting $'  REVIEW_GATE_T7 = "a"\n  REVIEW_GATE_T7 = "b"' REVIEW_GATE_T7 "dflt"
[[ "$RC" -ne 0 ]] && ok "two indented duplicates are a config error" || bad "two indented duplicates are a config error" "rc=$RC out=$OUT"

echo "=== unparseable stays loud ==="
run_setting 'REVIEW_GATE_T8 = ["array"]' REVIEW_GATE_T8 "dflt"
[[ "$RC" -ne 0 ]] && grep -q "unsupported syntax" "$TMP/err" && ok "array syntax is a config error (control)" || bad "array syntax is a config error (control)" "rc=$RC"

run_setting '  REVIEW_GATE_T9 = ["array"]' REVIEW_GATE_T9 "dflt"
[[ "$RC" -ne 0 ]] && grep -q "unsupported syntax" "$TMP/err" && ok "indented array syntax is a config error, not a silent default" || bad "indented array syntax is a config error, not a silent default" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
