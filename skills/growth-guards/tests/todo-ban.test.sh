#!/usr/bin/env bash
# Pins for scripts/todo-ban: both marker shapes fire, prose that quotes or
# names a marker word does not, excludes need reasons, and a broken scan is
# a collection error — never a pass. Every green assertion is paired with a
# control that proves it can fail.
#
# Marker words are assembled from split tokens throughout so this test
# file never contains a marker shape itself — the vstack repo runs
# todo-ban over its own tree, tests included.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TB="$SKILL_DIR/scripts/todo-ban"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Hermetic: a leaked setting would mask every case below.
unset GROWTH_GUARDS_TODO_EXCLUDES GROWTH_GUARDS_SETTINGS_FILE 2>/dev/null || true

TD="TO""DO"
FX="FIX""ME"
HK="HA""CK"
XX="XX""X"

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

run_tb() { # [args...] — run in $R; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$TB" "$@" 2>&1)" || RC=$?
}

echo "=== control: a clean repo passes ==="
new_repo clean
printf 'fn main() {}\n' >"$R/ok.rs"
git -C "$R" add -A
run_tb
[ "$RC" -eq 0 ] && case "$OUT" in *"todo-ban: OK"*) true ;; *) false ;; esac \
  && ok "clean repo passes" || bad "clean repo passes" "rc=$RC out=$OUT"

echo "=== shape (a): annotated markers fire ==="
new_repo shapes
printf '// %s: wire this up\n' "$TD" >"$R/a.rs"
git -C "$R" add -A
run_tb
[ "$RC" -eq 1 ] && case "$OUT" in *"work marker: a.rs:1:"*) true ;; *) false ;; esac \
  && ok "colon-annotated marker in a comment fails, naming file:line" \
  || bad "colon-annotated marker fails" "rc=$RC out=$OUT"
case "$OUT" in *"move it to the tracker and delete the marker"*) ok "diagnostic carries the remediation" ;; *) bad "diagnostic carries the remediation" "$OUT" ;; esac

printf '%s(alice): assigned marker\n' "$FX" >"$R/a.rs"
git -C "$R" add -A
run_tb
[ "$RC" -eq 1 ] && ok "attributed marker at line start fails" || bad "attributed marker at line start fails" "rc=$RC out=$OUT"

printf 'code(); /* %s: inline block */\n' "$HK" >"$R/a.rs"
git -C "$R" add -A
run_tb
[ "$RC" -eq 1 ] && ok "block-comment annotated marker fails" || bad "block-comment annotated marker fails" "rc=$RC out=$OUT"

echo "=== shape (b): bare marker directly after a comment leader fires ==="
printf '# %s implement the frobnicator\n' "$TD" >"$R/a.rs"
git -C "$R" add -A
run_tb
[ "$RC" -eq 1 ] && ok "bare marker after hash leader fails" || bad "bare marker after hash leader fails" "rc=$RC out=$OUT"

printf '//%s no space before the word\n' "$XX" >"$R/a.rs"
git -C "$R" add -A
run_tb
[ "$RC" -eq 1 ] && ok "bare marker glued to a slash leader fails" || bad "bare marker glued to a slash leader fails" "rc=$RC out=$OUT"

echo "=== prose that names or quotes a marker does not fire ==="
printf 'The %s marker is banned in this repo.\n' "$TD" >"$R/a.rs"
git -C "$R" add -A
run_tb
[ "$RC" -eq 0 ] && ok "bare word mid-prose (no colon, no adjacent leader) passes" \
  || bad "bare word mid-prose passes" "rc=$RC out=$OUT"

printf 'the `%s:` shape and `%s(` shape are banned\n' "$TD" "$FX" >"$R/a.md"
git -C "$R" add -A
run_tb
[ "$RC" -eq 0 ] && ok "backtick-quoted marker shapes in docs pass" \
  || bad "backtick-quoted marker shapes pass" "rc=$RC out=$OUT"

printf 'emit "%s:/%s( marker without an issue reference"\n' "$TD" "$FX" >"$R/a.sh"
git -C "$R" add -A
run_tb
[ "$RC" -eq 0 ] && ok "quote- and slash-joined marker names in a string pass" \
  || bad "joined marker names in a string pass" "rc=$RC out=$OUT"

printf 'printf "then\\n%s: inside a literal"\n' "$TD" >"$R/a.sh"
git -C "$R" add -A
run_tb
[ "$RC" -eq 0 ] && ok "marker joined to an escape sequence in a literal passes" \
  || bad "escape-joined marker passes" "rc=$RC out=$OUT"

printf '// %s: lowercase is prose, not a marker\n' "todo" >"$R/a.rs"
git -C "$R" add -A
run_tb
[ "$RC" -eq 0 ] && ok "lowercase word is never a marker (case-sensitive match)" \
  || bad "lowercase word passes" "rc=$RC out=$OUT"

echo "=== excludes: vendored trees are excluded WITH a reason ==="
new_repo exc
mkdir -p "$R/vendor" "$R/tools"
printf '// %s: vendored upstream marker\n' "$TD" >"$R/vendor/lib.rs"
git -C "$R" add -A
run_tb
[ "$RC" -eq 1 ] && ok "control: the vendored marker fails without an excludes row" \
  || bad "control: vendored marker fails without excludes" "rc=$RC out=$OUT"

printf 'vendor/*\tvendored third-party code\n' >"$R/tools/todo-ban-excludes"
git -C "$R" add -A
run_tb
[ "$RC" -eq 0 ] && ok "the excludes row silences exactly the vendored tree" \
  || bad "excludes row silences the vendored tree" "rc=$RC out=$OUT"

printf 'vendor/*\n' >"$R/tools/todo-ban-excludes"
git -C "$R" add -A
run_tb
[ "$RC" -eq 2 ] && case "$OUT" in *"pattern<TAB>reason"*) true ;; *) false ;; esac \
  && ok "a pattern without a tab-separated reason is exit 2" \
  || bad "a pattern without a reason is exit 2" "rc=$RC out=$OUT"

echo "=== configuration: GROWTH_GUARDS_TODO_EXCLUDES and --excludes ==="
printf 'vendor/*\tvendored third-party code\n' >"$R/alt-excludes"
rm "$R/tools/todo-ban-excludes"
git -C "$R" add -A
OUT="$(cd "$R" && GROWTH_GUARDS_TODO_EXCLUDES=alt-excludes "$TB" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && ok "excludes path resolves through the environment key" \
  || bad "excludes path resolves through the environment key" "rc=$RC out=$OUT"
run_tb --excludes alt-excludes
[ "$RC" -eq 0 ] && ok "--excludes flag points at the same list" || bad "--excludes flag" "rc=$RC out=$OUT"
run_tb
[ "$RC" -eq 1 ] && ok "control: without either, the vendored marker still fails" \
  || bad "control: default excludes path has no file, marker fails" "rc=$RC out=$OUT"

run_tb --no-such-flag
[ "$RC" -eq 2 ] && ok "unknown flag is exit 2" || bad "unknown flag is exit 2" "rc=$RC out=$OUT"

echo "=== fail-closed: a broken scan terminates, never passes ==="
new_repo grepfail
printf 'clean file\n' >"$R/ok.txt"
git -C "$R" add -A
run_tb
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
OUT="$(cd "$R" && PATH="$GIT_SHIM:$PATH" "$TB" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"git grep failed scanning tracked files"*) true ;; *) false ;; esac \
  && ok "a git grep execution failure is a collection error: exit 2, never OK" \
  || bad "a git grep execution failure is a collection error" "rc=$RC out=$OUT"
case "$OUT" in *"todo-ban: OK"*) bad "no OK verdict may accompany a broken scan" "$OUT" ;; *) ok "no OK verdict accompanies the broken scan" ;; esac

echo "=== fail-closed: an unreadable staged blob is a collection error ==="
new_repo unreadable
printf '// %s: stranded work\n' "$TD" >"$R/a.rs"
git -C "$R" add -A
run_tb
[ "$RC" -eq 1 ] && ok "control: the staged marker trips while its blob is readable" \
  || bad "control: readable blob trips" "rc=$RC out=$OUT"
OID="$(git -C "$R" rev-parse :a.rs)"
[ -f "$R/.git/objects/${OID:0:2}/${OID:2}" ] || bad "fixture: the staged blob is not a loose object at the expected path" "$OID"
rm -f -- "$R/.git/objects/${OID:0:2}/${OID:2}"
run_tb
[ "$RC" -eq 2 ] && case "$OUT" in *"error: "*"unable to read"*) true ;; *) false ;; esac \
  && ok "a vanished staged blob is exit 2 carrying git's own error line" \
  || bad "vanished blob is exit 2 with git's error line" "rc=$RC out=$OUT"
case "$OUT" in *"todo-ban: OK"*) bad "no OK verdict may accompany an unread blob" "$OUT" ;; *) ok "no OK verdict accompanies the unread blob" ;; esac

echo "=== a URL is not a comment leader ==="
new_repo url
printf 'see http://%s:8080/path for the mock\n' "$TD" >"$R/u.md"
git -C "$R" add -A
run_tb
[ "$RC" -eq 0 ] && ok "a marker word inside a URL authority does not fire" \
  || bad "a marker word inside a URL authority does not fire" "rc=$RC out=$OUT"
# Control: the same word after real whitespace still fires.
printf 'left in: %s: cleanup\n' "$TD" >>"$R/u.md"
git -C "$R" add -A
run_tb
[ "$RC" -eq 1 ] && ok "control: the same marker after whitespace fires" \
  || bad "control: the same marker after whitespace fires" "rc=$RC out=$OUT"

echo "=== the exclusion list is read from the index ==="
new_repo stagedx
printf '// %s: vendored\n' "$TD" >"$R/v.rs"
printf 'v.rs\tvendored fixture\n' >"$R/tools/growth-guards-todo-excludes" 2>/dev/null || { mkdir -p "$R/tools"; printf 'v.rs\tvendored fixture\n' >"$R/tools/growth-guards-todo-excludes"; }
git -C "$R" add -A
# Worktree copy now DROPS the exclusion; the staged copy must still govern.
: >"$R/tools/growth-guards-todo-excludes"
OUT="$(cd "$R" && GROWTH_GUARDS_TODO_EXCLUDES=tools/growth-guards-todo-excludes "$TB" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && ok "staged exclusion list governs a staged scan" \
  || bad "staged exclusion list governs a staged scan" "rc=$RC out=$OUT"
# Control: staging the emptied list re-exposes the marker.
git -C "$R" add tools/growth-guards-todo-excludes
OUT="$(cd "$R" && GROWTH_GUARDS_TODO_EXCLUDES=tools/growth-guards-todo-excludes "$TB" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 1 ] && ok "control: staging the emptied list re-exposes the marker" \
  || bad "control: staging the emptied list re-exposes the marker" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
