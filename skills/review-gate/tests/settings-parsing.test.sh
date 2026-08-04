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
  # Hermetic: rg_setting resolves a SET env var before the file, so a leaked
  # variable from the invoking shell would mask every file-parsing case.
  unset "$2" 2>/dev/null || true
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

echo "=== invalid key names are refused before any interpolation ==="
# The name reaches indirect expansion and is interpolated into ERE and sed
# patterns; the identifier-shape rejection is the only thing standing between
# a metacharacter name and pattern injection. Red-first: both refusal cases
# fail against a build with the `case` guard deleted.
run_setting 'REVIEW_GATE_OK = "x"' 9BADNAME "dflt"
[[ "$RC" -ne 0 ]] && grep -q "invalid key name" "$TMP/err" && ok "leading-digit name is refused" || bad "leading-digit name is refused" "rc=$RC out=$OUT"

run_setting 'REVIEW_GATE_OK = "x"' 'REVIEW_GATE.DOT' "dflt"
[[ "$RC" -ne 0 ]] && grep -q "invalid key name" "$TMP/err" && ok "regex-metacharacter name is refused (never reaches ERE interpolation)" || bad "regex-metacharacter name is refused (never reaches ERE interpolation)" "rc=$RC out=$OUT"

run_setting '_REVIEW_GATE_U = "u1"' _REVIEW_GATE_U "dflt"
[[ "$RC" -eq 0 && "$OUT" == "u1" ]] && ok "underscore-prefixed name stays valid (control)" || bad "underscore-prefixed name stays valid (control)" "rc=$RC out=$OUT"

echo "=== dash-prefixed settings path is a filename, never grep options ==="
# Without `--` before "$file", a relative path like "-e" parses as a grep
# OPTION: the presence probe errors, and the reader silently falls back to the
# caller default — fail-open on permissive defaults (hyprtrade#515 review,
# qodo). Red-first: fails against a build without the -- terminators.
printf 'REVIEW_GATE_TD = "dashfile"\n' > "$TMP/-e"
OUT=""; RC=0
OUT="$(cd "$TMP" && unset REVIEW_GATE_TD 2>/dev/null; REVIEW_GATE_SETTINGS_FILE="-e" rg_setting REVIEW_GATE_TD "dflt" 2>"$TMP/err")" || RC=$?
[[ "$RC" -eq 0 && "$OUT" == "dashfile" ]] && ok "dash-prefixed settings path reads its value (no option-injection fallback)" || bad "dash-prefixed settings path reads its value (no option-injection fallback)" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
