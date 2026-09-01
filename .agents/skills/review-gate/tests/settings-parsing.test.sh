#!/usr/bin/env bash
# Unit pins for lib/settings.sh's rg_setting contract (kendex#1059):
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
run_setting $'[env]\nREVIEW_GATE_T1 = "col1"' REVIEW_GATE_T1 "dflt"
[[ "$RC" -eq 0 && "$OUT" == "col1" ]] && ok "column-one assignment reads" || bad "column-one assignment reads" "rc=$RC out=$OUT"

run_setting $'[env]\n  REVIEW_GATE_T2 = "indented"' REVIEW_GATE_T2 "dflt"
[[ "$RC" -eq 0 && "$OUT" == "indented" ]] && ok "indented sole assignment reads (not the silent default)" || bad "indented sole assignment reads (not the silent default)" "rc=$RC out=$OUT"

run_setting $'[env]\nREVIEW_GATE_T3 = ""' REVIEW_GATE_T3 "dflt"
[[ "$RC" -eq 0 && "$OUT" == "" ]] && ok "explicit empty assignment overrides the default (empty-disables contract)" || bad "explicit empty assignment overrides the default" "rc=$RC out=$OUT"

run_setting $'[env]\nREVIEW_GATE_T4 = "file"' REVIEW_GATE_T4 "dflt"
env_out="$(REVIEW_GATE_T4="env" REVIEW_GATE_SETTINGS_FILE="$TMP/settings.toml" rg_setting REVIEW_GATE_T4 "dflt")"
[[ "$env_out" == "env" ]] && ok "explicit environment still wins over the file" || bad "explicit environment still wins over the file" "$env_out"

echo "=== ambiguity fails loud regardless of indentation ==="
run_setting $'[env]\nREVIEW_GATE_T5 = "a"\nREVIEW_GATE_T5 = "b"' REVIEW_GATE_T5 "dflt"
[[ "$RC" -ne 0 ]] && grep -q "assigned more than once" "$TMP/err" && ok "column-one duplicate is a config error (control)" || bad "column-one duplicate is a config error (control)" "rc=$RC"

run_setting $'[env]\nREVIEW_GATE_T6 = "a"\n  REVIEW_GATE_T6 = "b"' REVIEW_GATE_T6 "dflt"
[[ "$RC" -ne 0 ]] && grep -q "assigned more than once" "$TMP/err" && ok "INDENTED duplicate is a config error (was invisible to the guard)" || bad "INDENTED duplicate is a config error (was invisible to the guard)" "rc=$RC out=$OUT"

run_setting $'[env]\n  REVIEW_GATE_T7 = "a"\n  REVIEW_GATE_T7 = "b"' REVIEW_GATE_T7 "dflt"
[[ "$RC" -ne 0 ]] && ok "two indented duplicates are a config error" || bad "two indented duplicates are a config error" "rc=$RC out=$OUT"

echo "=== unparseable stays loud ==="
run_setting $'[env]\nREVIEW_GATE_T8 = ["array"]' REVIEW_GATE_T8 "dflt"
[[ "$RC" -ne 0 ]] && grep -q "unsupported syntax" "$TMP/err" && ok "array syntax is a config error (control)" || bad "array syntax is a config error (control)" "rc=$RC"

run_setting $'[env]\n  REVIEW_GATE_T9 = ["array"]' REVIEW_GATE_T9 "dflt"
[[ "$RC" -ne 0 ]] && grep -q "unsupported syntax" "$TMP/err" && ok "indented array syntax is a config error, not a silent default" || bad "indented array syntax is a config error, not a silent default" "rc=$RC out=$OUT"

echo "=== invalid key names are refused before any interpolation ==="
# The name reaches indirect expansion and is interpolated into ERE and sed
# patterns; the identifier-shape rejection is the only thing standing between
# a metacharacter name and pattern injection. Red-first: both refusal cases
# fail against a build with the `case` guard deleted.
run_setting $'[env]\nREVIEW_GATE_OK = "x"' 9BADNAME "dflt"
[[ "$RC" -ne 0 ]] && grep -q "invalid key name" "$TMP/err" && ok "leading-digit name is refused" || bad "leading-digit name is refused" "rc=$RC out=$OUT"

run_setting $'[env]\nREVIEW_GATE_OK = "x"' 'REVIEW_GATE.DOT' "dflt"
[[ "$RC" -ne 0 ]] && grep -q "invalid key name" "$TMP/err" && ok "regex-metacharacter name is refused (never reaches ERE interpolation)" || bad "regex-metacharacter name is refused (never reaches ERE interpolation)" "rc=$RC out=$OUT"

run_setting $'[env]\n_REVIEW_GATE_U = "u1"' _REVIEW_GATE_U "dflt"
[[ "$RC" -eq 0 && "$OUT" == "u1" ]] && ok "underscore-prefixed name stays valid (control)" || bad "underscore-prefixed name stays valid (control)" "rc=$RC out=$OUT"

echo "=== dash-prefixed settings path is a filename, never grep options ==="
# Without `--` before "$file", a relative path like "-e" parses as a grep
# OPTION: the presence probe errors, and the reader silently falls back to the
# caller default — fail-open on permissive defaults (hyprtrade#515 review,
# qodo). Red-first: fails against a build without the -- terminators.
printf '[env]\nREVIEW_GATE_TD = "dashfile"\n' > "$TMP/-e"
OUT=""; RC=0
OUT="$(cd "$TMP" && { unset REVIEW_GATE_TD 2>/dev/null; REVIEW_GATE_SETTINGS_FILE="-e" rg_setting REVIEW_GATE_TD "dflt" 2>"$TMP/err"; })" || RC=$?
[[ "$RC" -eq 0 && "$OUT" == "dashfile" ]] && ok "dash-prefixed settings path reads its value (no option-injection fallback)" || bad "dash-prefixed settings path reads its value (no option-injection fallback)" "rc=$RC out=$OUT"

echo "=== an EXISTING non-regular settings path never falls back to defaults ==="
# A directory fails -f exactly like an absent file, so the reader would resolve
# every key to its caller default with nothing said.
mkdir -p "$TMP/nonregular.dir"
OUT=""; RC=0
OUT="$(unset REVIEW_GATE_TN 2>/dev/null; REVIEW_GATE_SETTINGS_FILE="$TMP/nonregular.dir" rg_setting REVIEW_GATE_TN "dflt" 2>"$TMP/err")" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q "not a regular file" "$TMP/err" && ok "a DIRECTORY settings path is a config error, not a silent default" || bad "a DIRECTORY settings path is a config error, not a silent default" "rc=$RC out=$OUT"

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
printf '[env]\nREVIEW_GATE_TL = "linked"\n' >"$TMP/link-target.settings.toml"
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
  printf '[env]\nREVIEW_GATE_TU = "configured"\n' >"$TMP/unreadable.settings.toml"
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
printf '[env]\nREVIEW_GATE_TS = "fromfile"\n' >"$TMP/sentinel/kendex.settings.toml"
OUT=""; RC=0
OUT="$(cd "$TMP/sentinel" && { unset REVIEW_GATE_TS REVIEW_GATE_SETTINGS_FILE 2>/dev/null; rg_setting REVIEW_GATE_TS "dflt" 2>"$TMP/err"; })" || RC=$?
[[ "$RC" -eq 0 && "$OUT" == "fromfile" ]] && ok "control: without the sentinel the settings file at the default path supplies the value" || bad "sentinel control" "rc=$RC out=$OUT"

OUT=""; RC=0
OUT="$(cd "$TMP/sentinel" && { unset REVIEW_GATE_TS 2>/dev/null; REVIEW_GATE_SETTINGS_FILE=/dev/null rg_setting REVIEW_GATE_TS "dflt" 2>"$TMP/err"; })" || RC=$?
[[ "$RC" -eq 0 && "$OUT" == "dflt" ]] && ok "the sentinel skips a populated settings file and the built-in default decides" || bad "sentinel skips the settings file" "rc=$RC out=$OUT"

OUT=""; RC=0
OUT="$(cd "$TMP/sentinel" && REVIEW_GATE_TS="fromenv" REVIEW_GATE_SETTINGS_FILE=/dev/null rg_setting REVIEW_GATE_TS "dflt" 2>"$TMP/err")" || RC=$?
[[ "$RC" -eq 0 && "$OUT" == "fromenv" ]] && ok "an explicit environment variable still wins over the sentinel" || bad "sentinel vs environment" "rc=$RC out=$OUT"

echo "=== only the [env] table is read ==="
# The loader is table-aware: a bare assignment above the first header or
# under an unrelated table belongs to another tool and resolves nothing.
# Both cases fail against a file-wide matcher, which would read the value.
run_setting $'REVIEW_GATE_TT = "top"\n[env]\nREVIEW_GATE_OTHER = "x"' REVIEW_GATE_TT "dflt"
[[ "$RC" -eq 0 && "$OUT" == "dflt" ]] && ok "an assignment ABOVE the [env] header is ignored" || bad "an assignment ABOVE the [env] header is ignored" "rc=$RC out=$OUT"

run_setting $'[notes]\nREVIEW_GATE_TT = "elsewhere"' REVIEW_GATE_TT "dflt"
[[ "$RC" -eq 0 && "$OUT" == "dflt" ]] && ok "an assignment under an UNRELATED table is ignored" || bad "an assignment under an UNRELATED table is ignored" "rc=$RC out=$OUT"

# A duplicate split across re-entered [env] sections is the same ambiguity
# as two lines in one section.
run_setting $'[env]\nREVIEW_GATE_TT = "a"\n[notes]\nx = "y"\n[env]\nREVIEW_GATE_TT = "b"' REVIEW_GATE_TT "dflt"
[[ "$RC" -ne 0 ]] && grep -q "assigned more than once in \[env\]" "$TMP/err" && ok "a duplicate across re-entered [env] sections is a config error" || bad "a duplicate across re-entered [env] sections is a config error" "rc=$RC out=$OUT"

echo "=== the contract value grammar ==="
# Values are single-line basic strings with no double quote and no
# backslash; a trailing TOML comment is accepted. Both families decode the
# contract shape identically, so a backslash cannot mean an escape in one
# reader and a literal in another — it is refused everywhere.
run_setting $'[env]\nREVIEW_GATE_TC = "spaced value" # trailing comment' REVIEW_GATE_TC "dflt"
[[ "$RC" -eq 0 && "$OUT" == "spaced value" ]] && ok "a trailing comment is dropped from the decoded value" || bad "a trailing comment is dropped from the decoded value" "rc=$RC out=$OUT"

run_setting $'[env]\nREVIEW_GATE_TB = "a\\b"' REVIEW_GATE_TB "dflt"
[[ "$RC" -ne 0 ]] && grep -q "unsupported syntax" "$TMP/err" && ok "a backslash in the value is a config error, never decoded" || bad "a backslash in the value is a config error, never decoded" "rc=$RC out=$OUT"

echo "=== default-path layering and the REVIEW_GATE_MODE exception ==="
# With no REVIEW_GATE_SETTINGS_FILE the default sources apply: .env.local >
# .kendex/settings.toml > kendex.settings.toml > default — except
# REVIEW_GATE_MODE, which reads only env and the COMMITTED kendex.settings.toml
# so the local waiter and the CI gate (whose checkout has neither .env.local
# nor .kendex/) resolve the switch identically.
mkdir -p "$TMP/layers/.kendex"
printf '[env]\nREVIEW_GATE_TP = "root"\nREVIEW_GATE_MODE = "off"\n' >"$TMP/layers/kendex.settings.toml"
layer() { # NAME DEFAULT — resolve from inside the layered fixture
  OUT=""; RC=0
  OUT="$(cd "$TMP/layers" && { unset "$1" REVIEW_GATE_SETTINGS_FILE 2>/dev/null; rg_setting "$1" "$2" 2>"$TMP/err"; })" || RC=$?
}
layer REVIEW_GATE_TP "dflt"
[[ "$RC" -eq 0 && "$OUT" == "root" ]] && ok "control: the root settings file supplies the value" || bad "control: the root settings file supplies the value" "rc=$RC out=$OUT"

printf '[env]\nREVIEW_GATE_TP = "nested"\n' >"$TMP/layers/.kendex/settings.toml"
layer REVIEW_GATE_TP "dflt"
[[ "$RC" -eq 0 && "$OUT" == "nested" ]] && ok ".kendex/settings.toml beats kendex.settings.toml" || bad ".kendex/settings.toml beats kendex.settings.toml" "rc=$RC out=$OUT"

printf 'REVIEW_GATE_TP=dotenv\nREVIEW_GATE_MODE=enforce\n' >"$TMP/layers/.env.local"
layer REVIEW_GATE_TP "dflt"
[[ "$RC" -eq 0 && "$OUT" == "dotenv" ]] && ok ".env.local beats both settings files" || bad ".env.local beats both settings files" "rc=$RC out=$OUT"

# The exception: the same .env.local assigns REVIEW_GATE_MODE=enforce, and
# the settings file says off — the settings file must win, because the
# dotenv layer is not a source for this key. Fails against a resolver that
# reads the mode from .env.local.
layer REVIEW_GATE_MODE "enforce"
[[ "$RC" -eq 0 && "$OUT" == "off" ]] && ok "REVIEW_GATE_MODE ignores .env.local and reads the settings file" || bad "REVIEW_GATE_MODE ignores .env.local and reads the settings file" "rc=$RC out=$OUT"

# The machine-local .kendex/settings.toml is not a source for this key
# either: CI's checkout does not carry it, so a local uncommitted "off"
# would recreate the waiter/gate split the exception exists to prevent.
printf '[env]\nREVIEW_GATE_MODE = "off"\n' >"$TMP/layers/.kendex/settings.toml"
printf '[env]\nREVIEW_GATE_TP = "root"\n' >"$TMP/layers/kendex.settings.toml"
layer REVIEW_GATE_MODE "enforce"
[[ "$RC" -eq 0 && "$OUT" == "enforce" ]] && ok "REVIEW_GATE_MODE ignores the machine-local .kendex/settings.toml" || bad "REVIEW_GATE_MODE ignores the machine-local .kendex/settings.toml" "rc=$RC out=$OUT"

# And with the settings assignment gone, the exception resolves the built-in
# default while the dotenv value still sits there unread.
rm -f "$TMP/layers/.kendex/settings.toml"
layer REVIEW_GATE_MODE "enforce"
[[ "$RC" -eq 0 && "$OUT" == "enforce" ]] && ok "REVIEW_GATE_MODE falls to the default over a dotenv-only value" || bad "REVIEW_GATE_MODE falls to the default over a dotenv-only value" "rc=$RC out=$OUT"

echo "=== the dotenv layer reads every supported shape and refuses the rest ==="
# Quoted values end at the FIRST closing delimiter, a trailing # comment is
# dropped, and a shape the parser cannot read fails NONZERO — truncating an
# adjacent segment would silently load an unintended value.
dot() { # NAME DEFAULT — resolve inside the layered fixture
  OUT=""; RC=0
  OUT="$(cd "$TMP/layers" && { unset "$1" REVIEW_GATE_SETTINGS_FILE 2>/dev/null; rg_setting "$1" "$2" 2>"$TMP/err"; })" || RC=$?
}
printf 'REVIEW_GATE_TD="spaced value" # note\n' >"$TMP/layers/.env.local"
dot REVIEW_GATE_TD "dflt"
[[ "$RC" -eq 0 && "$OUT" == "spaced value" ]] && ok "double-quoted dotenv value with a trailing comment extracts the content" || bad "quoted+comment dotenv" "rc=$RC out=$OUT"

printf 'REVIEW_GATE_TD="900" # say "quiet"\n' >"$TMP/layers/.env.local"
dot REVIEW_GATE_TD "dflt"
[[ "$RC" -eq 0 && "$OUT" == "900" ]] && ok "a quote inside the trailing comment never leaks into the value" || bad "comment-quote dotenv" "rc=$RC out=$OUT"

printf 'export REVIEW_GATE_TD=42\n' >"$TMP/layers/.env.local"
dot REVIEW_GATE_TD "dflt"
[[ "$RC" -eq 0 && "$OUT" == "42" ]] && ok "export-form dotenv assignment is recognized" || bad "export-form dotenv" "rc=$RC out=$OUT"

printf "REVIEW_GATE_TD='19' # note\n" >"$TMP/layers/.env.local"
dot REVIEW_GATE_TD "dflt"
[[ "$RC" -eq 0 && "$OUT" == "19" ]] && ok "single-quoted dotenv value with a trailing comment extracts the content" || bad "single-quoted dotenv" "rc=$RC out=$OUT"

printf "REVIEW_GATE_TD='29' # don't raise\n" >"$TMP/layers/.env.local"
dot REVIEW_GATE_TD "dflt"
[[ "$RC" -eq 0 && "$OUT" == "29" ]] && ok "an apostrophe in the trailing comment never leaks into a single-quoted value" || bad "comment-apostrophe dotenv" "rc=$RC out=$OUT"

printf 'REVIEW_GATE_TD="17".5\n' >"$TMP/layers/.env.local"
dot REVIEW_GATE_TD "dflt"
[[ "$RC" -ne 0 ]] && grep -q "unsupported syntax" "$TMP/err" && ok "an adjacent segment after a quoted value fails loud, never truncates" || bad "adjacent-segment dotenv" "rc=$RC out=$OUT"

printf 'REVIEW_GATE_TD="17"#note\n' >"$TMP/layers/.env.local"
dot REVIEW_GATE_TD "dflt"
[[ "$RC" -ne 0 ]] && grep -q "unsupported syntax" "$TMP/err" && ok "an adjacent # after a quoted value is a segment, not a comment — fails loud" || bad "adjacent-hash dotenv" "rc=$RC out=$OUT"

echo "=== an UNUSABLE .env.local fails loud, never falls through ==="
# The dotenv layer sits ABOVE the settings files, so silently skipping an
# unusable .env.local would resolve from a lower layer — same silent-value
# swap the settings-file shapes above pin.
rm -f "$TMP/layers/.env.local"
mkdir -p "$TMP/layers/.env.local"
dot REVIEW_GATE_TD "dflt"
[[ "$RC" -ne 0 ]] && grep -q "not a regular file" "$TMP/err" && ok "a DIRECTORY at .env.local is a config error, not a skipped layer" || bad "directory .env.local" "rc=$RC out=$OUT"
rmdir "$TMP/layers/.env.local"

ln -s missing.env "$TMP/layers/.env.local"
dot REVIEW_GATE_TD "dflt"
[[ "$RC" -ne 0 ]] && grep -q "does not resolve" "$TMP/err" && ok "a DANGLING symlink at .env.local is a config error, not a skipped layer" || bad "dangling .env.local" "rc=$RC out=$OUT"
rm -f "$TMP/layers/.env.local"

if [ "$(id -u)" -eq 0 ]; then
  echo "  skip  unreadable-.env.local pin needs a non-root reader (chmod 000 cannot deny root)"
else
  printf 'REVIEW_GATE_TD="secret"\n' >"$TMP/layers/.env.local"
  chmod 000 "$TMP/layers/.env.local"
  dot REVIEW_GATE_TD "dflt"
  [[ "$RC" -ne 0 ]] && grep -q "unreadable while resolving a setting" "$TMP/err" && ok "an UNREADABLE .env.local is a config error, not a skipped layer" || bad "unreadable .env.local" "rc=$RC out=$OUT"
  rm -f "$TMP/layers/.env.local"
fi

echo "=== a SET-but-EMPTY settings-file override is unset, not a source ==="
# "" names no file: consulting only it resolved every key to its built-in
# default with nothing said (an empty trusted-logins default widens the
# gate). Empty must read the default sources; /dev/null stays the one
# force-defaults handle.
printf '[env]\nREVIEW_GATE_TE = "fromrepo"\n' >"$TMP/layers/kendex.settings.toml"
OUT=""; RC=0
OUT="$(cd "$TMP/layers" && { unset REVIEW_GATE_TE 2>/dev/null; REVIEW_GATE_SETTINGS_FILE= rg_setting REVIEW_GATE_TE "dflt" 2>"$TMP/err"; })" || RC=$?
[[ "$RC" -eq 0 && "$OUT" == "fromrepo" ]] && ok "a SET-but-EMPTY REVIEW_GATE_SETTINGS_FILE reads the default sources" || bad "set-but-empty settings-file override" "rc=$RC out=$OUT"

echo "=== a header the parser cannot read fails loud ==="
# Headers decide which assignments load: `[env] # comment` passing as
# content hides the whole table behind silent defaults, and a quoted
# foreign header after [env] leaves foreign keys reading as [env] keys.
run_setting $'[env] # comment\nREVIEW_GATE_TH = "hidden"' REVIEW_GATE_TH "dflt"
[[ "$RC" -ne 0 ]] && grep -q "unsupported table header shape" "$TMP/err" && ok "a commented [env] header is a config error, not an invisible table" || bad "commented [env] header" "rc=$RC out=$OUT"

run_setting $'[env]\nx = "y"\n["notes"]\nREVIEW_GATE_TH = "leak"' REVIEW_GATE_TH "dflt"
[[ "$RC" -ne 0 ]] && grep -q "unsupported table header shape" "$TMP/err" && ok "a quoted foreign header after [env] is a config error, not a leaked key" || bad "quoted foreign header" "rc=$RC out=$OUT"

echo "=== an =-containing relative settings path stays a file operand ==="
# awk parses an operand containing `=` as a variable assignment: the source
# passes the file checks, awk reads no input, and every key resolves to its
# built-in default with nothing said. Red-first: fails against an awk
# invocation taking the path as an operand instead of stdin.
printf '[env]\nREVIEW_GATE_TQ = "eqfile"\n' > "$TMP/policy=on.toml"
OUT=""; RC=0
OUT="$(cd "$TMP" && { unset REVIEW_GATE_TQ 2>/dev/null; REVIEW_GATE_SETTINGS_FILE="policy=on.toml" rg_setting REVIEW_GATE_TQ "dflt" 2>"$TMP/err"; })" || RC=$?
[[ "$RC" -eq 0 && "$OUT" == "eqfile" ]] && ok "an =-containing relative settings path reads its value (no silent-defaults fallback)" || bad "=-containing settings path" "rc=$RC out=$OUT"

echo "=== the WHOLE [env] table is validated, not only the requested key ==="
# kendex-env.sh refuses these same files, so a per-key-only extractor would
# split the family contract: the resolver would answer while the loader
# rejects the identical file.
run_setting $'[env]\nUNRELATED = bare\nREVIEW_GATE_TW = "v"' REVIEW_GATE_TW "dflt"
[[ "$RC" -ne 0 ]] && grep -q "unsupported syntax for UNRELATED" "$TMP/err" && ok "an unrelated non-contract assignment fails the read" || bad "unrelated malformed assignment" "rc=$RC out=$OUT"

run_setting $'[env]\nUNRELATED = "a"\nUNRELATED = "b"\nREVIEW_GATE_TW = "v"' REVIEW_GATE_TW "dflt"
[[ "$RC" -ne 0 ]] && grep -q "UNRELATED is assigned more than once" "$TMP/err" && ok "an unrelated duplicated key fails the read" || bad "unrelated duplicated key" "rc=$RC out=$OUT"

echo "=== a malformed lower file fails even under a higher-precedence override ==="
# kendex-env validates before its parent-env skip; an exported value or an
# .env.local hit must never let a broken committed file pass silently.
printf '[env]\nDUP = "a"\nDUP = "b"\n' >"$TMP/settings.toml"
OUT=""; RC=0
OUT="$(REVIEW_GATE_TV=envwin REVIEW_GATE_SETTINGS_FILE="$TMP/settings.toml" rg_setting REVIEW_GATE_TV "dflt" 2>"$TMP/err")" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q "assigned more than once" "$TMP/err" && ok "an exported value does not mask a malformed settings file" || bad "env override over malformed file" "rc=$RC out=$OUT"

printf '[env]\nDUP = "a"\nDUP = "b"\n' >"$TMP/layers/kendex.settings.toml"
printf 'REVIEW_GATE_TV="local"\n' >"$TMP/layers/.env.local"
dot REVIEW_GATE_TV "dflt"
[[ "$RC" -ne 0 ]] && grep -q "assigned more than once" "$TMP/err" && ok "a .env.local hit does not mask a malformed settings file" || bad "dotenv override over malformed file" "rc=$RC out=$OUT"
rm -f "$TMP/layers/.env.local"

# ...and it must not mask a BROKEN .env.local either: the layer's
# usability is part of every resolution, same as the generic loader.
printf '[env]\nREVIEW_GATE_TP = "root"\n' >"$TMP/layers/kendex.settings.toml"
mkdir -p "$TMP/layers/.env.local"
OUT=""; RC=0
OUT="$(cd "$TMP/layers" && { unset REVIEW_GATE_SETTINGS_FILE 2>/dev/null; REVIEW_GATE_TV=envwin rg_setting REVIEW_GATE_TV "dflt" 2>"$TMP/err"; })" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q "not a regular file" "$TMP/err" && ok "an exported value does not mask a DIRECTORY at .env.local" || bad "env override over broken .env.local" "rc=$RC out=$OUT"

# ...but REVIEW_GATE_MODE probes only ITS sources: a broken machine-local
# .env.local must not fail the switch that CI, on a clean checkout, would
# resolve normally — that split is what the exception exists to prevent.
printf '[env]\nREVIEW_GATE_MODE = "off"\n' >"$TMP/layers/kendex.settings.toml"
OUT=""; RC=0
OUT="$(cd "$TMP/layers" && { unset REVIEW_GATE_MODE REVIEW_GATE_SETTINGS_FILE 2>/dev/null; rg_setting REVIEW_GATE_MODE "enforce" 2>"$TMP/err"; })" || RC=$?
[[ "$RC" -eq 0 && "$OUT" == "off" ]] && ok "REVIEW_GATE_MODE resolves past a broken .env.local it never reads" || bad "MODE over broken .env.local" "rc=$RC out=$OUT"
rmdir "$TMP/layers/.env.local"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
