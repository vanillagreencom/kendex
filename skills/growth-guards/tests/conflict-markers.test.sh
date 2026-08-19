#!/usr/bin/env bash
# Pins for scripts/conflict-markers: each of the open/base/close trio at
# column 0 fires, indented/quoted/glued occurrences and the seven-equals
# separator do not, excludes need reasons, the check's own source never
# trips it, and a broken scan is a collection error — never a pass. Every
# green assertion is paired with a control that proves it can fail.
#
# Marker runs are assembled with printf throughout so this test file never
# contains a marker shape itself — the vstack repo runs conflict-markers
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

echo "=== fail-closed: a broken scan terminates, never passes ==="
new_repo grepfail
printf 'clean file\n' >"$R/ok.txt"
git -C "$R" add -A
run_cm
[ "$RC" -eq 0 ] && ok "shim-free control: the fixture passes with the real git" \
  || bad "shim-free control passes" "rc=$RC out=$OUT"

REAL_GIT="$(command -v git)"
GIT_SHIM="$TMP/git-shim"
mkdir -p "$GIT_SHIM"
cat >"$GIT_SHIM/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "grep" ]; then
    echo "git grep: simulated execution failure" >&2
    exit 128
  fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GIT_SHIM/git"
OUT="$(cd "$R" && PATH="$GIT_SHIM:$PATH" "$CM" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"git grep failed scanning tracked files"*) true ;; *) false ;; esac \
  && ok "a git grep execution failure is a collection error: exit 2, never OK" \
  || bad "a git grep execution failure is a collection error" "rc=$RC out=$OUT"
case "$OUT" in *"conflict-markers: OK"*) bad "no OK verdict may accompany a broken scan" "$OUT" ;; *) ok "no OK verdict accompanies the broken scan" ;; esac

echo "=== fail-closed: an unreadable staged blob is a collection error ==="
new_repo unreadable
printf '%s HEAD\n' "$OPEN" >"$R/marker.txt"
git -C "$R" add -A
run_cm
[ "$RC" -eq 1 ] && ok "control: the staged marker trips while its blob is readable" \
  || bad "control: readable blob trips" "rc=$RC out=$OUT"
OID="$(git -C "$R" rev-parse :marker.txt)"
[ -f "$R/.git/objects/${OID:0:2}/${OID:2}" ] || bad "fixture: the staged blob is not a loose object at the expected path" "$OID"
rm -f -- "$R/.git/objects/${OID:0:2}/${OID:2}"
run_cm
[ "$RC" -eq 2 ] && case "$OUT" in *"error: "*"unable to read"*) true ;; *) false ;; esac \
  && ok "a vanished staged blob is exit 2 carrying git's own error line" \
  || bad "vanished blob is exit 2 with git's error line" "rc=$RC out=$OUT"
case "$OUT" in *"conflict-markers: OK"*) bad "no OK verdict may accompany an unread blob" "$OUT" ;; *) ok "no OK verdict accompanies the unread blob" ;; esac

# Status 0 + stderr error: a second, readable file matches while the first
# stays unread — a partial scan must not fold as an ordinary violation.
printf '%s theirs\n' "$CLOSE" >"$R/readable.txt"
git -C "$R" add readable.txt
run_cm
[ "$RC" -eq 2 ] && case "$OUT" in *"unable to read"*) true ;; *) false ;; esac \
  && ok "a scan that matches one file but cannot read another is exit 2, never a violation verdict" \
  || bad "match + unreadable blob is exit 2, not 1" "rc=$RC out=$OUT"
case "$OUT" in *"conflict marker(s) — excludes"*) bad "no violation summary may accompany a partial scan" "$OUT" ;; *) ok "no violation summary accompanies the partial scan" ;; esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
