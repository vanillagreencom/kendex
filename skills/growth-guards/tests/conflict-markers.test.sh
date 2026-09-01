#!/usr/bin/env bash
# Pins for scripts/conflict-markers: each of the open/base/close trio at
# column 0 fires, indented/quoted/glued occurrences and the seven-equals
# separator do not, excludes need reasons, and the check's own source never
# trips it. Every green assertion is paired with a control that proves it can
# fail. The index readers this family of checks shares are pinned once, in
# index-reads.test.sh.
#
# Marker runs are assembled with printf throughout so this test file never
# contains a marker shape itself — the kendex repo runs conflict-markers
# over its own tree, tests included.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CM="$SKILL_DIR/scripts/conflict-markers"
. "$TEST_DIR/lib/harness.bash"

# Hermetic: a leaked setting would mask every case below.
unset GROWTH_GUARDS_CONFLICT_EXCLUDES GROWTH_GUARDS_SETTINGS_FILE 2>/dev/null || true

mk7() { printf '%s%s%s%s%s%s%s' "$1" "$1" "$1" "$1" "$1" "$1" "$1"; }
OPEN="$(mk7 '<')"
BASE="$(mk7 '|')"
CLOSE="$(mk7 '>')"
SEP="$(mk7 '=')"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

new_repo() { # NAME — fresh fixture repo in $R
  R="$TMP/$1"
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}

run_cm() { # [args...] — run in $R; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$CM" "$@" 2>&1)" || RC=$?
}

echo "=== control: a clean repo passes ==="
new_repo clean
printf 'fn main() {}\n' >"$R/ok.rs"
git -C "$R" add -A
run_cm
[ "$RC" -eq 0 ] && case "$OUT" in *"conflict-markers: OK"*) true ;; *) false ;; esac \
  && ok "clean repo passes" || bad "clean repo passes" "rc=$RC out=$OUT"

echo "=== each marker of the trio at column 0 fails, naming the file ==="
new_repo trio
printf '%s HEAD\n' "$OPEN" >"$R/a.rs"
git -C "$R" add -A
run_cm
[ "$RC" -eq 1 ] && case "$OUT" in *"conflict marker: a.rs:1:"*) true ;; *) false ;; esac \
  && ok "the open marker with its label fails, naming file:line" \
  || bad "open marker fails" "rc=$RC out=$OUT"
case "$OUT" in *"finish the merge and delete the marker lines"*) ok "diagnostic carries the remediation" ;; *) bad "diagnostic carries the remediation" "$OUT" ;; esac

printf '%s\n' "$BASE" >"$R/a.rs"
git -C "$R" add -A
run_cm
[ "$RC" -eq 1 ] && case "$OUT" in *"conflict marker: a.rs:1:"*) true ;; *) false ;; esac \
  && ok "the bare base marker (end of line, no label) fails" \
  || bad "base marker fails" "rc=$RC out=$OUT"

printf '%s theirs\n' "$CLOSE" >"$R/a.rs"
git -C "$R" add -A
run_cm
[ "$RC" -eq 1 ] && case "$OUT" in *"conflict marker: a.rs:1:"*) true ;; *) false ;; esac \
  && ok "the close marker with its label fails, naming file:line" \
  || bad "close marker fails" "rc=$RC out=$OUT"

echo "=== indented, quoted, and glued occurrences never fire ==="
{
  printf ' %s HEAD\n' "$OPEN"
  printf '\t%s theirs\n' "$CLOSE"
  printf 'the %s run mid-prose\n' "$BASE"
  printf 'quoted: "%s ours"\n' "$OPEN"
  printf '%sx glued to text\n' "$OPEN"
} >"$R/a.rs"
git -C "$R" add -A
run_cm
[ "$RC" -eq 0 ] && ok "space/tab-indented, quoted, mid-prose and glued runs all pass" \
  || bad "non-column-0 and glued runs pass" "rc=$RC out=$OUT"

printf '%s%s eight then a space\n' "$OPEN" '<' >"$R/a.rs"
git -C "$R" add -A
run_cm
[ "$RC" -eq 0 ] && ok "an eight-character run is not the seven-character marker" \
  || bad "eight-character run passes" "rc=$RC out=$OUT"

echo "=== the seven-equals separator alone never fires ==="
printf 'Title\n%s\n' "$SEP" >"$R/a.md"
printf 'fn main() {}\n' >"$R/a.rs"
git -C "$R" add -A
run_cm
[ "$RC" -eq 0 ] && ok "a setext H2 underline at column 0 passes (separator is deliberately unmatched)" \
  || bad "seven-equals separator passes" "rc=$RC out=$OUT"

echo "=== excludes: a declared path is exempt WITH a reason ==="
new_repo exc
mkdir -p "$R/fixtures" "$R/tools"
printf '%s HEAD\nours\n%s theirs\n' "$OPEN" "$CLOSE" >"$R/fixtures/merge.txt"
git -C "$R" add -A
run_cm
[ "$RC" -eq 1 ] && ok "control: the fixture marker fails without an excludes row" \
  || bad "control: fixture marker fails without excludes" "rc=$RC out=$OUT"

printf 'fixtures/*\tmerge-conflict fixture data\n' >"$R/tools/conflict-markers-excludes"
git -C "$R" add -A
run_cm
[ "$RC" -eq 0 ] && ok "the excludes row silences exactly the declared path" \
  || bad "excludes row silences the declared path" "rc=$RC out=$OUT"

printf 'fixtures/*\n' >"$R/tools/conflict-markers-excludes"
git -C "$R" add -A
run_cm
[ "$RC" -eq 2 ] && case "$OUT" in *"pattern<TAB>reason"*) true ;; *) false ;; esac \
  && ok "a pattern without a tab-separated reason is exit 2" \
  || bad "a pattern without a reason is exit 2" "rc=$RC out=$OUT"

echo "=== configuration: GROWTH_GUARDS_CONFLICT_EXCLUDES and --excludes ==="
printf 'fixtures/*\tmerge-conflict fixture data\n' >"$R/alt-excludes"
rm "$R/tools/conflict-markers-excludes"
git -C "$R" add -A
OUT="$(cd "$R" && GROWTH_GUARDS_CONFLICT_EXCLUDES=alt-excludes "$CM" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && ok "excludes path resolves through the environment key" \
  || bad "excludes path resolves through the environment key" "rc=$RC out=$OUT"
run_cm --excludes alt-excludes
[ "$RC" -eq 0 ] && ok "--excludes flag points at the same list" || bad "--excludes flag" "rc=$RC out=$OUT"
run_cm --excludes=alt-excludes
[ "$RC" -eq 0 ] && ok "the equals form of --excludes resolves the same list" || bad "--excludes= equals form" "rc=$RC out=$OUT"
run_cm
[ "$RC" -eq 1 ] && ok "control: without either, the fixture marker still fails" \
  || bad "control: default excludes path has no file, marker fails" "rc=$RC out=$OUT"

run_cm --no-such-flag
[ "$RC" -eq 2 ] && ok "unknown flag is exit 2" || bad "unknown flag is exit 2" "rc=$RC out=$OUT"

echo "=== the check's own source does not trip it ==="
new_repo self
mkdir -p "$R/scripts"
cp "$CM" "$R/scripts/conflict-markers"
git -C "$R" add -A
run_cm
[ "$RC" -eq 0 ] && ok "the shipped script, tracked, scans clean (interval-built patterns)" \
  || bad "the shipped script scans clean" "rc=$RC out=$OUT"
# Control: the scan still fires in this repo when a real marker appears.
printf '%s HEAD\n' "$OPEN" >"$R/planted.txt"
git -C "$R" add -A
run_cm
[ "$RC" -eq 1 ] && case "$OUT" in *"planted.txt:1:"*"scripts/conflict-markers"*) false ;; *"planted.txt:1:"*) true ;; *) false ;; esac \
  && ok "control: a planted marker fails while the script stays unnamed" \
  || bad "control: planted marker fails, script unnamed" "rc=$RC out=$OUT"

echo "=== a carrier the sniff skips is named, and qualifies the verdict ==="
new_repo unmeasured
printf 'fn main() {}\n' >"$R/ok.rs"
# An asset whose bytes happen to spell the open marker at column 0. The
# listing forces text, so this path IS matched and reaches the content
# sniff; a NUL in git's leading window is what keeps it out of the count.
# Unread is not clean: the path is named and the verdict carries the count.
printf '\211PNG\r\n\032\n\000\000\n%s HEAD\n' "$OPEN" >"$R/asset.png"
git -C "$R" add -A
run_cm
[ "$RC" -eq 0 ] && case "$OUT" in
  *"not measured: asset.png — binary content, not text"*"conflict-markers: OK"*"1 matched path(s) not measured"*) true ;;
  *) false ;;
esac \
  && ok "a clean verdict names the skipped carrier and says how many went unmeasured" \
  || bad "clean verdict carries the unmeasured qualifier" "rc=$RC out=$OUT"

# The same qualifier on a FAILING verdict: a real marker elsewhere decides
# the exit code, and the unread carrier still has to be declared.
printf '%s theirs\n' "$CLOSE" >"$R/planted.txt"
git -C "$R" add -A
run_cm
[ "$RC" -eq 1 ] && case "$OUT" in
  *"not measured: asset.png — binary content, not text"*"conflict-markers: 1 conflict marker(s)"*"1 matched path(s) not measured"*) true ;;
  *) false ;;
esac \
  && ok "a violation verdict carries the same qualifier" \
  || bad "violation verdict carries the unmeasured qualifier" "rc=$RC out=$OUT"

# The must-fail control: the same bytes with the NULs taken out are text, so
# the carrier is measured, fires, and nothing is declared unmeasured.
printf '\211PNG\r\n\032\n\n%s HEAD\n' "$OPEN" >"$R/asset.png"
git -C "$R" add -A
run_cm
[ "$RC" -eq 1 ] && case "$OUT" in
  *"conflict marker: asset.png:"*) true ;;
  *) false ;;
esac \
  && ok "control: the same bytes without a NUL are read, and fire" \
  || bad "control: the NUL-free carrier fires" "rc=$RC out=$OUT"
case "$OUT" in
  *"not measured"*) bad "nothing goes unmeasured once the carrier is text" "$OUT" ;;
  *) ok "and no unmeasured qualifier accompanies a fully read scan" ;;
esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
