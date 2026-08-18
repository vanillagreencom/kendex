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

echo "=== an EXISTING non-regular settings path never falls back to defaults ==="
# A directory (FIFO/socket/device are the same shape) fails -f exactly like
# an absent file, so the reader would resolve every key to its caller
# default with nothing said — fail-open on permissive defaults.
mkdir -p "$TMP/nonregular.dir"
OUT=""; RC=0
OUT="$(unset REVIEW_GATE_TN 2>/dev/null; REVIEW_GATE_SETTINGS_FILE="$TMP/nonregular.dir" rg_setting REVIEW_GATE_TN "dflt" 2>"$TMP/err")" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q "not a regular file" "$TMP/err" && ok "a DIRECTORY settings path is a config error, not a silent default" || bad "a DIRECTORY settings path is a config error, not a silent default" "rc=$RC out=$OUT"

if mkfifo "$TMP/nonregular.fifo" 2>/dev/null; then
  OUT=""; RC=0
  OUT="$(unset REVIEW_GATE_TN 2>/dev/null; REVIEW_GATE_SETTINGS_FILE="$TMP/nonregular.fifo" rg_setting REVIEW_GATE_TN "dflt" 2>"$TMP/err")" || RC=$?
  [[ "$RC" -ne 0 ]] && grep -q "not a regular file" "$TMP/err" && ok "a FIFO settings path is a config error, not a silent default" || bad "a FIFO settings path is a config error, not a silent default" "rc=$RC out=$OUT"
else
  echo "  skip  mkfifo unavailable — FIFO shape not exercised"
fi

# A symlink that does not resolve fails -e as well as -f, so an existence
# test alone never sees it — the same silent-defaults trap one shape over.
ln -s missing.toml "$TMP/dangling.settings.toml"
OUT=""; RC=0
OUT="$(unset REVIEW_GATE_TN 2>/dev/null; REVIEW_GATE_SETTINGS_FILE="$TMP/dangling.settings.toml" rg_setting REVIEW_GATE_TN "dflt" 2>"$TMP/err")" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q "does not resolve" "$TMP/err" && ok "a DANGLING symlink settings path is a config error, not a silent default" || bad "a DANGLING symlink settings path is a config error, not a silent default" "rc=$RC out=$OUT"

ln -s cycle-b.settings.toml "$TMP/cycle-a.settings.toml"
ln -s cycle-a.settings.toml "$TMP/cycle-b.settings.toml"
OUT=""; RC=0
OUT="$(unset REVIEW_GATE_TN 2>/dev/null; REVIEW_GATE_SETTINGS_FILE="$TMP/cycle-a.settings.toml" rg_setting REVIEW_GATE_TN "dflt" 2>"$TMP/err")" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q "does not resolve" "$TMP/err" && ok "a CYCLIC symlink settings path is a config error, not a silent default" || bad "a CYCLIC symlink settings path is a config error, not a silent default" "rc=$RC out=$OUT"

# A RESOLVING symlink is an ordinary install shape and must still read.
printf 'REVIEW_GATE_TL = "linked"\n' >"$TMP/link-target.settings.toml"
ln -s link-target.settings.toml "$TMP/link.settings.toml"
OUT=""; RC=0
OUT="$(unset REVIEW_GATE_TL 2>/dev/null; REVIEW_GATE_SETTINGS_FILE="$TMP/link.settings.toml" rg_setting REVIEW_GATE_TL "dflt" 2>"$TMP/err")" || RC=$?
[[ "$RC" -eq 0 && "$OUT" == "linked" ]] && ok "a RESOLVING symlink reads its target (control)" || bad "a RESOLVING symlink reads its target (control)" "rc=$RC out=$OUT"

echo "=== an UNREADABLE settings source fails loud, never falls back ==="
# grep exits 0/1 are measurements; anything else means the source could not
# be read. -f and -e both pass on a mode-000 file, so only the read itself
# sees it: falling back would resolve every key to its caller default, and
# an empty default widens the gate (empty trusted-logins = any non-author).
if [ "$(id -u)" -eq 0 ]; then
  echo "  skip  unreadable-source pins need a non-root reader (chmod 000 cannot deny root)"
else
  printf 'REVIEW_GATE_TU = "configured"\n' >"$TMP/unreadable.settings.toml"
  chmod 000 "$TMP/unreadable.settings.toml"
  RC=0
  rg_settings_grep "^REVIEW_GATE_TU" "$TMP/unreadable.settings.toml" >/dev/null 2>"$TMP/err" || RC=$?
  [[ "$RC" -eq 2 ]] && grep -q "unreadable while resolving a setting" "$TMP/err" && ok "the read discipline reports 2 for an unreadable source, never 1 (no match)" || bad "the read discipline reports 2 for an unreadable source" "rc=$RC"
  OUT=""; RC=0
  OUT="$(unset REVIEW_GATE_TU 2>/dev/null; REVIEW_GATE_SETTINGS_FILE="$TMP/unreadable.settings.toml" rg_setting REVIEW_GATE_TU "dflt" 2>"$TMP/err")" || RC=$?
  [[ "$RC" -ne 0 && "$OUT" != "dflt" ]] && grep -q "unreadable.settings.toml: unreadable while resolving a setting" "$TMP/err" && ok "an UNREADABLE settings path is a config error naming the file, not a silent default" || bad "an UNREADABLE settings path is a config error naming the file" "rc=$RC out=$OUT"
  chmod 600 "$TMP/unreadable.settings.toml"
  OUT=""; RC=0
  OUT="$(unset REVIEW_GATE_TU 2>/dev/null; REVIEW_GATE_SETTINGS_FILE="$TMP/unreadable.settings.toml" rg_setting REVIEW_GATE_TU "dflt" 2>"$TMP/err")" || RC=$?
  [[ "$RC" -eq 0 && "$OUT" == "configured" ]] && ok "control: the same file, readable, resolves its value" || bad "control: the same file, readable, resolves its value" "rc=$RC out=$OUT"
fi

# Controls: the two shapes that MUST still resolve to the caller default.
OUT=""; RC=0
OUT="$(unset REVIEW_GATE_TN 2>/dev/null; REVIEW_GATE_SETTINGS_FILE=/dev/null rg_setting REVIEW_GATE_TN "dflt" 2>"$TMP/err")" || RC=$?
[[ "$RC" -eq 0 && "$OUT" == "dflt" ]] && ok "/dev/null still forces built-in defaults (control)" || bad "/dev/null still forces built-in defaults (control)" "rc=$RC out=$OUT"

OUT=""; RC=0
OUT="$(unset REVIEW_GATE_TN 2>/dev/null; REVIEW_GATE_SETTINGS_FILE="$TMP/absent.settings.toml" rg_setting REVIEW_GATE_TN "dflt" 2>"$TMP/err")" || RC=$?
[[ "$RC" -eq 0 && "$OUT" == "dflt" ]] && ok "an ABSENT plain file still falls back to the default (control)" || bad "an ABSENT plain file still falls back to the default (control)" "rc=$RC out=$OUT"

echo "=== the /dev/null sentinel selects NO settings source ==="
# The handle means "no source at all", so it must beat a populated settings
# file sitting at the default path, and lose only to an explicit environment
# variable. The copies vendored from this loader layer dotenv sources around
# it and answer the sentinel the same way, so the contract is pinned here
# where the shared logic lives.
mkdir -p "$TMP/sentinel"
printf '[env]\nREVIEW_GATE_TS = "fromfile"\n' >"$TMP/sentinel/vstack.settings.toml"
OUT=""; RC=0
OUT="$(cd "$TMP/sentinel" && unset REVIEW_GATE_TS REVIEW_GATE_SETTINGS_FILE 2>/dev/null; rg_setting REVIEW_GATE_TS "dflt" 2>"$TMP/err")" || RC=$?
[[ "$RC" -eq 0 && "$OUT" == "fromfile" ]] && ok "control: without the sentinel the settings file at the default path supplies the value" || bad "sentinel control" "rc=$RC out=$OUT"

OUT=""; RC=0
OUT="$(cd "$TMP/sentinel" && unset REVIEW_GATE_TS 2>/dev/null; REVIEW_GATE_SETTINGS_FILE=/dev/null rg_setting REVIEW_GATE_TS "dflt" 2>"$TMP/err")" || RC=$?
[[ "$RC" -eq 0 && "$OUT" == "dflt" ]] && ok "the sentinel skips a populated settings file and the built-in default decides" || bad "sentinel skips the settings file" "rc=$RC out=$OUT"

OUT=""; RC=0
OUT="$(cd "$TMP/sentinel" && REVIEW_GATE_TS="fromenv" REVIEW_GATE_SETTINGS_FILE=/dev/null rg_setting REVIEW_GATE_TS "dflt" 2>"$TMP/err")" || RC=$?
[[ "$RC" -eq 0 && "$OUT" == "fromenv" ]] && ok "an explicit environment variable still wins over the sentinel" || bad "sentinel vs environment" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
