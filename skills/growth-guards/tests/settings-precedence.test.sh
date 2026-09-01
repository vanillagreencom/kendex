#!/usr/bin/env bash
# Precedence pins for lib/settings.sh's gg_setting contract: explicit env >
# .env.local > .kendex/settings.toml > kendex.settings.toml > built-in
# default, with `.env` read by nothing, only the [env] table consulted, and
# the contract value grammar (single-line double-quoted, no `"`, no `\`)
# enforced loudly.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"

# shellcheck source=../scripts/lib/settings.sh
source "$SKILL_DIR/scripts/lib/settings.sh"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

R="$TMP/repo"
mkdir -p "$R/.kendex"

resolve() { # NAME DEFAULT [ENV_ASSIGN] — sets OUT and RC from inside the repo
  OUT=""; RC=0
  OUT="$(cd "$R" && { unset "$1" GROWTH_GUARDS_SETTINGS_FILE 2>/dev/null; env ${3:+"$3"} bash -c '
    set -euo pipefail
    source "$0"
    gg_setting "$1" "$2"
  ' "$SKILL_DIR/scripts/lib/settings.sh" "$1" "$2" 2>"$TMP/err"; })" || RC=$?
}

echo "=== the resolution ladder, one layer at a time ==="
resolve GROWTH_GUARDS_TP "dflt"
[ "$RC" -eq 0 ] && [ "$OUT" = "dflt" ] && ok "no source configured: the built-in default answers" || bad "built-in default answers" "rc=$RC out=$OUT"

printf '[env]\nGROWTH_GUARDS_TP = "root"\n' >"$R/kendex.settings.toml"
resolve GROWTH_GUARDS_TP "dflt"
[ "$RC" -eq 0 ] && [ "$OUT" = "root" ] && ok "kendex.settings.toml supplies the value" || bad "kendex.settings.toml supplies the value" "rc=$RC out=$OUT"

printf '[env]\nGROWTH_GUARDS_TP = "nested"\n' >"$R/.kendex/settings.toml"
resolve GROWTH_GUARDS_TP "dflt"
[ "$RC" -eq 0 ] && [ "$OUT" = "nested" ] && ok ".kendex/settings.toml beats kendex.settings.toml" || bad ".kendex/settings.toml beats kendex.settings.toml" "rc=$RC out=$OUT"

printf 'GROWTH_GUARDS_TP=dotenv\n' >"$R/.env.local"
resolve GROWTH_GUARDS_TP "dflt"
[ "$RC" -eq 0 ] && [ "$OUT" = "dotenv" ] && ok ".env.local beats both settings files" || bad ".env.local beats both settings files" "rc=$RC out=$OUT"

resolve GROWTH_GUARDS_TP "dflt" "GROWTH_GUARDS_TP=explicit"
[ "$RC" -eq 0 ] && [ "$OUT" = "explicit" ] && ok "explicit environment beats every project file" || bad "explicit environment beats every project file" "rc=$RC out=$OUT"

resolve GROWTH_GUARDS_TP "dflt" "GROWTH_GUARDS_TP="
[ "$RC" -eq 0 ] && [ "$OUT" = "" ] && ok "a SET-but-empty environment value still wins (explicitly empty)" || bad "set-but-empty environment wins" "rc=$RC out=$OUT"
rm -f "$R/.env.local" "$R/.kendex/settings.toml" "$R/kendex.settings.toml"

echo "=== a .env value is read by nothing ==="
# Fails against a resolver that still reads the dropped layer: the value
# would resolve instead of the default.
printf 'GROWTH_GUARDS_TP=from-dotenv\n' >"$R/.env"
resolve GROWTH_GUARDS_TP "dflt"
[ "$RC" -eq 0 ] && [ "$OUT" = "dflt" ] && ok "a .env assignment is ignored and the default answers" || bad "a .env assignment is ignored" "rc=$RC out=$OUT"
rm -f "$R/.env"

echo "=== only the [env] table is read ==="
printf 'GROWTH_GUARDS_TT = "top"\n[env]\nGROWTH_GUARDS_OTHER = "x"\n' >"$R/kendex.settings.toml"
resolve GROWTH_GUARDS_TT "dflt"
[ "$RC" -eq 0 ] && [ "$OUT" = "dflt" ] && ok "an assignment ABOVE the [env] header is ignored" || bad "assignment above [env] ignored" "rc=$RC out=$OUT"

printf '[notes]\nGROWTH_GUARDS_TT = "elsewhere"\n' >"$R/kendex.settings.toml"
resolve GROWTH_GUARDS_TT "dflt"
[ "$RC" -eq 0 ] && [ "$OUT" = "dflt" ] && ok "an assignment under an UNRELATED table is ignored" || bad "assignment under another table ignored" "rc=$RC out=$OUT"

printf '[env]\nGROWTH_GUARDS_TT = "in-env"\n' >"$R/kendex.settings.toml"
resolve GROWTH_GUARDS_TT "dflt"
[ "$RC" -eq 0 ] && [ "$OUT" = "in-env" ] && ok "control: the same assignment inside [env] resolves" || bad "control: [env] assignment resolves" "rc=$RC out=$OUT"

echo "=== ambiguity and the contract grammar fail loud ==="
printf '[env]\nGROWTH_GUARDS_TT = "a"\nGROWTH_GUARDS_TT = "b"\n' >"$R/kendex.settings.toml"
resolve GROWTH_GUARDS_TT "dflt"
[ "$RC" -ne 0 ] && grep -q "assigned more than once in \[env\]" "$TMP/err" && ok "a duplicate inside [env] is a config error" || bad "duplicate inside [env] errors" "rc=$RC out=$OUT"

printf '[env]\nGROWTH_GUARDS_TT = "a\\b"\n' >"$R/kendex.settings.toml"
resolve GROWTH_GUARDS_TT "dflt"
[ "$RC" -ne 0 ] && grep -q "unsupported syntax" "$TMP/err" && ok "a backslash in the value is a config error, never decoded" || bad "backslash value errors" "rc=$RC out=$OUT"

printf '[env]\nGROWTH_GUARDS_TT = "kept" # comment\n' >"$R/kendex.settings.toml"
resolve GROWTH_GUARDS_TT "dflt"
[ "$RC" -eq 0 ] && [ "$OUT" = "kept" ] && ok "a trailing comment is dropped from the decoded value" || bad "trailing comment decode" "rc=$RC out=$OUT"

echo "=== a header the parser cannot read fails loud ==="
# Headers decide which assignments load: `[env] # comment` passing as
# content hides the whole table behind silent defaults.
printf '[env] # comment\nGROWTH_GUARDS_TT = "hidden"\n' >"$R/kendex.settings.toml"
resolve GROWTH_GUARDS_TT "dflt"
[ "$RC" -ne 0 ] && grep -q "unsupported table header shape" "$TMP/err" && ok "a commented [env] header is a config error, not an invisible table" || bad "commented [env] header errors" "rc=$RC out=$OUT"

echo "=== a SET-but-EMPTY settings-file override is unset, not a source ==="
# "" names no file: consulting only it resolved every key to its built-in
# default with nothing said. /dev/null stays the one force-defaults handle.
printf '[env]\nGROWTH_GUARDS_TT = "fromrepo"\n' >"$R/kendex.settings.toml"
OUT=""; RC=0
OUT="$(cd "$R" && { unset GROWTH_GUARDS_TT 2>/dev/null; env GROWTH_GUARDS_SETTINGS_FILE= bash -c '
    set -euo pipefail
    source "$0"
    gg_setting "$1" "$2"
  ' "$SKILL_DIR/scripts/lib/settings.sh" GROWTH_GUARDS_TT "dflt" 2>"$TMP/err"; })" || RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "fromrepo" ] && ok "a SET-but-EMPTY GROWTH_GUARDS_SETTINGS_FILE reads the default sources" || bad "set-but-empty override reads default sources" "rc=$RC out=$OUT"

echo "=== the WHOLE [env] table is validated, not only the requested key ==="
# kendex-env.sh refuses these same files, so a per-key-only extractor would
# split the family contract.
printf '[env]\nUNRELATED = bare\nGROWTH_GUARDS_TT = "v"\n' >"$R/kendex.settings.toml"
resolve GROWTH_GUARDS_TT "dflt"
[ "$RC" -ne 0 ] && grep -q "unsupported syntax for UNRELATED" "$TMP/err" && ok "an unrelated non-contract assignment fails the read" || bad "unrelated malformed assignment" "rc=$RC out=$OUT"

printf '[env]\nUNRELATED = "a"\nUNRELATED = "b"\nGROWTH_GUARDS_TT = "v"\n' >"$R/kendex.settings.toml"
resolve GROWTH_GUARDS_TT "dflt"
[ "$RC" -ne 0 ] && grep -q "UNRELATED is assigned more than once" "$TMP/err" && ok "an unrelated duplicated key fails the read" || bad "unrelated duplicated key" "rc=$RC out=$OUT"

echo "=== a malformed lower file fails even under a higher-precedence override ==="
# kendex-env validates before its parent-env skip; an exported value must
# never let a broken committed file pass silently.
printf '[env]\nDUP = "a"\nDUP = "b"\n' >"$R/kendex.settings.toml"
resolve GROWTH_GUARDS_TT "dflt" "GROWTH_GUARDS_TT=explicit"
[ "$RC" -ne 0 ] && grep -q "assigned more than once" "$TMP/err" && ok "an exported value does not mask a malformed settings file" || bad "env override over malformed file" "rc=$RC out=$OUT"

# ...and it must not mask a BROKEN .env.local either: the layer's
# usability is part of every resolution, same as the generic loader.
printf '[env]\nGROWTH_GUARDS_TT = "fromrepo"\n' >"$R/kendex.settings.toml"
mkdir -p "$R/.env.local"
resolve GROWTH_GUARDS_TT "dflt" "GROWTH_GUARDS_TT=explicit"
[ "$RC" -ne 0 ] && grep -q "not a regular file" "$TMP/err" && ok "an exported value does not mask a DIRECTORY at .env.local" || bad "env override over broken .env.local" "rc=$RC out=$OUT"
rmdir "$R/.env.local"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
