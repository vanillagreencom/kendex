#!/usr/bin/env bash
# The proof for tools/test-roster: a checkout holding one harness crate, a
# pass row spelling every way a name is declared, one refusal row per way a
# file or directory goes undeclared, the crate with no [[test]] root at all,
# the crate that keeps autodiscovery, the pass world under BSD sed's argv
# rules, and the reads that cannot happen. Every row runs the real script
# over a fixture tree under tmp/ and reads its exit status and its keyed
# first line; no result is read out of an empty string.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

ROOT="$(git rev-parse --show-toplevel)"
ROSTER="$ROOT/tools/test-roster"
mkdir -p "$ROOT/tmp"
TMP="$(mktemp -d "$ROOT/tmp/test-roster.XXXXXX")" || exit 2
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

W="$TMP/repo"
CRATE="$W/crates/demo"
T="$CRATE/tests"

# The passing world: autodiscovery off, the harness root and a second
# [[test]] target of its own, a third [[test]] whose root is a directory's
# main.rs, and under tests/ one entry of every shape a root can declare.
seed_world() {
  rm -rf -- "${W:?}"
  mkdir -p "$T/nested" "$T/support" "$T/by_path" "$T/fixtures/deep"
  cat >"$CRATE/Cargo.toml" <<'TOML'
[package]
name = "demo"
autotests = false

[[test]]
name = "integration"
path = "tests/main.rs"

[[test]]
name = "own_target"
path = "tests/own_target.rs"

[[test]]
name = "by_path"
path = "tests/by_path/main.rs"
TOML
  printf '%s\n' \
    '#[path = "../../test_util.rs"]' \
    'mod test_util;' \
    '#[path = "support/helper.rs"]' \
    'mod helper;' \
    'mod declared;' \
    'pub mod exported;' \
    'mod nested;' >"$T/main.rs"
  printf 'fn declared() {}\n' >"$T/declared.rs"
  printf 'pub fn exported() {}\n' >"$T/exported.rs"
  printf 'fn nested() {}\n' >"$T/nested/mod.rs"
  printf 'fn helper() {}\n' >"$T/support/helper.rs"
  printf 'fn own_target() {}\n' >"$T/own_target.rs"
  printf 'fn by_path() {}\n' >"$T/by_path/main.rs"
  printf 'not rust\n' >"$T/fixtures/deep/data.txt"
}

run_roster() { # [ROOT-ARG...] — sets OUT and RC; OUT drops the final newline as $(...) does
  OUT=""
  RC=0
  OUT="$(cd "$W" && "$ROSTER" "$@" 2>&1)" || RC=$?
}

echo "=== every declared shape passes ==="
seed_world
run_roster
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "a mod line, a pub mod line, a #[path] attribute, a [[test]] path and a directory root all declare; a fixture directory is not judged" || bad "a mod line, a pub mod line, a #[path] attribute, a [[test]] path and a directory root all declare; a fixture directory is not judged" "rc=$RC out=$OUT"
run_roster .
[ "$RC" -eq 0 ] && ok "an explicit root argument judges the same tree" || bad "an explicit root argument judges the same tree" "rc=$RC out=$OUT"
# The BSD argv shape: a `--` after sed's script is a file operand there,
# which the shim from skills/commit-guards/tests/bsd-argv-install.test.sh
# fails the way BSD sed does after handing the rest to the real one.
SHIM="$TMP/shim"
mkdir -p "$SHIM"
REAL_SED="$(command -v sed)"
cat >"$SHIM/sed" <<SHIM
#!/bin/sh
n=\$#; i=0; seen=0; bad=0
while [ "\$i" -lt "\$n" ]; do
  arg=\$1; shift; i=\$((i + 1))
  if [ "\$seen" -eq 0 ]; then
    case "\$arg" in -*) ;; *) seen=1 ;; esac
    set -- "\$@" "\$arg"; continue
  fi
  if [ "\$arg" = "--" ]; then bad=1; echo "sed: --: No such file or directory" >&2; continue; fi
  set -- "\$@" "\$arg"
done
$REAL_SED "\$@"; rc=\$?
[ "\$bad" -eq 0 ] || exit 1
exit "\$rc"
SHIM
chmod 0755 "$SHIM/sed"
printf 'a\nb\n' >"$TMP/sed-probe"
probe_rc=0
PATH="$SHIM:$PATH" sed -n '2p' -- "$TMP/sed-probe" >/dev/null 2>&1 || probe_rc=$?
[ "$probe_rc" -eq 1 ] && ok "premise: the shim fails a -- operand after sed's script" || bad "premise: the shim fails a -- operand after sed's script" "rc=$probe_rc"
OUT=""
RC=0
OUT="$(cd "$W" && PATH="$SHIM:$PATH" "$ROSTER" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "the passing world passes under BSD sed's argv rules" || bad "the passing world passes under BSD sed's argv rules" "rc=$RC out=$OUT"

echo "=== one undeclared entry per shape is refused by name ==="
# Each row plants one entry over the passing world and expects exactly that
# entry back: label, the file to write, the path the refusal names, and an
# edit to a declared module file that must not count as a declaration.
while IFS='|' read -r label plant expect module_edit; do
  [ -n "$label" ] || continue
  seed_world
  mkdir -p "$(dirname "$T/$plant")"
  printf 'fn planted() {}\n' >"$T/$plant"
  [ -z "$module_edit" ] || printf '%s\n' "$module_edit" >>"$T/declared.rs"
  run_roster
  if [ "$RC" -eq 1 ] && [ "$OUT" = "test-roster: orphans=1"$'\n'"crates/demo/tests/$expect" ]; then
    ok "$label"
  else
    bad "$label" "rc=$RC out=$OUT"
  fi
done <<'ROWS'
an undeclared file|orphan.rs|orphan.rs|
an undeclared directory holding a mod.rs|stray/mod.rs|stray|
an undeclared directory holding a main.rs, cargo's multi-file layout|stray/main.rs|stray|
an undeclared directory holding a .rs file below its top level|stray/inner/leaf.rs|stray|
a mod line inside a declared module file declares nothing|orphan.rs|orphan.rs|mod orphan;
ROWS

echo "=== with no [[test]] root every entry is an orphan, the harness root included ==="
seed_world
printf '[package]\nname = "demo"\nautotests = false\n' >"$CRATE/Cargo.toml"
run_roster
expected="test-roster: orphans=7"$'\n'
for e in by_path declared.rs exported.rs main.rs nested own_target.rs support; do
  expected="$expected""crates/demo/tests/$e"$'\n'
done
[ "$RC" -eq 1 ] && [ "$OUT" = "${expected%$'\n'}" ] && ok "with no [[test]] root every .rs file and every directory holding one is named, main.rs among them" || bad "with no [[test]] root every .rs file and every directory holding one is named, main.rs among them" "rc=$RC out=$OUT"

echo "=== a crate that keeps autodiscovery is cargo's to judge ==="
seed_world
printf '[package]\nname = "demo"\n' >"$CRATE/Cargo.toml"
printf 'fn orphan() {}\n' >"$T/orphan.rs"
run_roster
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "an undeclared file in a crate with autodiscovery on is not an orphan" || bad "an undeclared file in a crate with autodiscovery on is not an orphan" "rc=$RC out=$OUT"

echo "=== a tree that cannot be read is never a pass ==="
seed_world
chmod 0000 "$CRATE/Cargo.toml"
run_roster
chmod 0644 "$CRATE/Cargo.toml"
if [ "$(id -u)" -eq 0 ]; then
  printf '  skip  an unreadable manifest exits 2 naming it: root reads every file\n'
else
  [ "$RC" -eq 2 ] && [ "$OUT" = "test-roster: unreadable=crates/demo/Cargo.toml" ] && ok "an unreadable manifest exits 2 naming it" || bad "an unreadable manifest exits 2 naming it" "rc=$RC out=$OUT"
fi
seed_world
chmod 0000 "$T/main.rs"
run_roster
chmod 0644 "$T/main.rs"
if [ "$(id -u)" -eq 0 ]; then
  printf '  skip  an unreadable harness root exits 2 naming it: root reads every file\n'
else
  [ "$RC" -eq 2 ] && [ "$OUT" = "test-roster: unreadable=crates/demo/tests/main.rs" ] && ok "an unreadable harness root exits 2 naming it" || bad "an unreadable harness root exits 2 naming it" "rc=$RC out=$OUT"
fi
run_roster "$TMP/absent"
[ "$RC" -eq 2 ] && [[ "$OUT" == "test-roster: unreadable=$TMP/absent"* ]] && ok "an absent root exits 2 naming it" || bad "an absent root exits 2 naming it" "rc=$RC out=$OUT"
run_roster one two
[ "$RC" -eq 2 ] && [[ "$OUT" == "test-roster: usage="* ]] && ok "a second argument is refused with the usage line" || bad "a second argument is refused with the usage line" "rc=$RC out=$OUT"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
