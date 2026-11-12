#!/usr/bin/env bash
# The proof for tools/rust-reads --modules and the tools/guard --range route
# that runs its rows: one crate whose library and integration target each
# hold readers of the shapes the module map tells apart, a table of the rows
# each read maps to, a table of the cargo test calls a range touching those
# reads makes, and a control for each: a reader copy with the reach closure
# removed, and a guard copy that runs the whole crate for every reader, as
# the guard did before the module map.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/guard-world.sh
. "$TEST_DIR/lib/guard-world.sh"
READS="$REPO/tools/rust-reads"

# Cargo metadata reads the real fixture workspace; every other cargo call is
# logged, never run.
REAL_CARGO="$(command -v cargo)"
FAKE_BIN="$TMP/fake-bin"
CALLS="$TMP/calls"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/cargo" <<SH
#!/usr/bin/env bash
[ "\${1:-}" != metadata ] || exec "$REAL_CARGO" "\$@"
echo "cargo \$*" >>"\$CALL_LOG"
SH
printf '#!/usr/bin/env bash\necho "npm $*" >>"$CALL_LOG"\n' >"$FAKE_BIN/npm"
chmod +x "$FAKE_BIN/cargo" "$FAKE_BIN/npm"

# The crate: a library with a pub module, a private one and a #[path] one,
# and an integration target with a leaf, a nested module, a pub helper and
# the module naming it, a trait impl, and a build script.
rm -- "$R/crates/core/tests/existing_temp.rs"
mkdir -p "$R/crates/core/src/elsewhere" "$R/crates/core/tests/nested"
cp "$REPO/rust-toolchain.toml" "$R/rust-toolchain.toml"
printf '%s\n' '[workspace]' 'resolver = "3"' 'members = ["crates/core"]' >"$R/Cargo.toml"
printf '%s\n' '[package]' 'name = "kendex-core"' 'version = "0.1.0"' 'edition = "2024"' 'autotests = false' \
  '' '[[test]]' 'name = "integration"' 'path = "tests/main.rs"' >"$R/crates/core/Cargo.toml"
reader() { # FILE FN-HEAD PATH — FILE holds one function joining PATH onto the checkout
  printf '%s\n' "$2 {" "    let _ = crate::checkout_root().join(\"$3\");" '}' >>"$R/crates/core/$1"
}
printf '%s\n' 'pub mod open;' 'mod sealed;' '#[cfg(test)]' '#[path = "elsewhere/moved.rs"]' 'mod moved;' \
  >"$R/crates/core/src/lib.rs"
printf '%s\n' 'pub fn shipped() -> std::path::PathBuf {' \
  '    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../skills/lib-open")' '}' \
  >"$R/crates/core/src/open.rs"
reader src/sealed.rs '#[test]
fn reads()' skills/lib-sealed
reader src/elsewhere/moved.rs '#[test]
fn reads()' skills/moved
printf '%s\n' 'mod helper;' 'mod leaf;' 'mod nested;' 'mod traited;' 'mod user;' >"$R/crates/core/tests/main.rs"
printf '%s\n' '#[test]' 'fn reads() {' \
  '    let _ = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../skills/leaf");' '}' \
  >"$R/crates/core/tests/leaf.rs"
printf 'mod inner;\n' >"$R/crates/core/tests/nested/mod.rs"
reader tests/nested/inner.rs '#[test]
fn reads()' skills/inner
reader tests/helper.rs 'pub fn copy()' skills/helper
printf '%s\n' '#[test]' 'fn copies() {' '    crate::helper::copy();' '}' >"$R/crates/core/tests/user.rs"
printf '%s\n' 'struct World;' 'impl Drop for World {' >"$R/crates/core/tests/traited.rs"
reader tests/traited.rs '    fn drop(&mut self)' skills/traited
printf '}\n' >>"$R/crates/core/tests/traited.rs"
printf '%s\n' 'fn main() {' \
  '    let _ = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../skills/orphan");' '}' \
  >"$R/crates/core/build.rs"
for skill in lib-open lib-sealed moved leaf inner helper traited orphan unread; do
  mkdir -p "$R/skills/$skill"
  printf '# %s\n' "$skill" >"$R/skills/$skill/SKILL.md"
done
git -C "$R" add -A
git -C "$R" commit -q -m "chore: a crate whose modules read skills"
BASE="$(git -C "$R" rev-parse HEAD)"

module_rows() { # READS PATH — the `selector:module` rows for PATH, joined by ;
  (cd "$R" && "$1" --modules .) | awk -F '\t' -v path="$2" '$1 == "module" && $2 == path { print $4 ":" $5 }' |
    paste -sd ';' -
}

echo "=== each reader maps to the modules that can run its read ==="
# LABEL|PATH|ROWS
MODULES='a pub library item runs from other crates: the whole crate|skills/lib-open|.:.
a private library module is its own filter|skills/lib-sealed|--lib:sealed
a #[path] module takes its declared name|skills/moved|--lib:moved
a private test module is its own filter|skills/leaf|--test=integration:leaf
a nested module keeps its parents|skills/inner|--test=integration:nested::inner
a pub helper adds each module naming it|skills/helper|--test=integration:helper;--test=integration:user
a trait impl runs anywhere in the target: the whole target|skills/traited|--test=integration:.
a file in no library or test module is the whole crate|skills/orphan|.:.'
before=$((PASS + FAIL))
while IFS='|' read -r label path rows; do
  got="$(module_rows "$READS" "$path")" || got="rc=$?"
  [ "$got" = "$rows" ] && ok "$label" || bad "$label" "want=$rows got=$got"
done <<<"$MODULES"
[ "$((PASS + FAIL))" -gt "$before" ] || { echo "no row was asserted: the module rows" >&2; exit 2; }
sed 's/reach\[w_path\[i\]\] = grew = 1/grew = 0/' "$READS" >"$TMP/rust-reads-unreached"
chmod +x "$TMP/rust-reads-unreached"
got="$(module_rows "$TMP/rust-reads-unreached" skills/helper)" || got="rc=$?"
! cmp -s "$READS" "$TMP/rust-reads-unreached" && [ "$got" = '--test=integration:helper' ] &&
  ok "control: a pub helper misses the module naming it, with the reach closure removed" ||
  bad "control: a pub helper misses the module naming it, with the reach closure removed" "got=$got"

OUT=""
RC=0
printf '#!/bin/sh\nexit 1\n' >"$TMP/cargo-fails"
mkdir -p "$TMP/failing-bin"
cp "$TMP/cargo-fails" "$TMP/failing-bin/cargo"
chmod +x "$TMP/failing-bin/cargo"
OUT="$(cd "$R" && PATH="$TMP/failing-bin:$PATH" "$READS" --modules . 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && [ "$OUT" = 'rust-reads: unreadable=modules' ] &&
  ok "failed Cargo metadata refuses the module map" || bad "failed Cargo metadata refuses the module map" "rc=$RC out=$OUT"

echo "=== a range runs only the tests that can run its changed reads ==="
run_range() { # GUARD — sets OUT, RC and LOG over the working tree against BASE
  OUT=""
  RC=0
  : >"$CALLS"
  OUT="$(cd "$R" && env "${GUARD_TEST_BOUNDS[@]}" PATH="$FAKE_BIN:$PATH" CALL_LOG="$CALLS" "$1" --range "$BASE" 2>&1 </dev/null)" || RC=$?
  LOG="$(cat "$CALLS")"
}
TEST='cargo test --manifest-path crates/core/Cargo.toml --quiet'
# LABEL|CHANGED SKILLS|CALLS, one per line joined by ;
RUNS="one reading module runs by its filter|leaf|$TEST --test=integration -- leaf::
a library and a test module run in their own targets|leaf lib-sealed|$TEST --lib -- sealed::;$TEST --test=integration -- leaf::
a helper runs with the module naming it|helper|$TEST --test=integration -- helper:: user::
a whole-target reader runs its target unfiltered|traited leaf|$TEST --test=integration --
a whole-crate reader runs the crate|lib-open leaf|$TEST
an unread skill runs no crate test|unread|"
before=$((PASS + FAIL))
while IFS='|' read -r label skills want; do
  for skill in $skills unread; do printf 'edit\n' >>"$R/skills/$skill/SKILL.md"; done
  run_range "$GUARD"
  want="${want//;/$'\n'}"
  [ "$RC" -eq 0 ] && [ "$LOG" = "$want" ] && ok "$label" || bad "$label" "rc=$RC log=$LOG out=$OUT"
  git -C "$R" checkout -q -- skills
done <<<"$RUNS"
[ "$((PASS + FAIL))" -gt "$before" ] || { echo "no row was asserted: the range runs" >&2; exit 2; }
printf 'edit\n' >>"$R/skills/leaf/SKILL.md"
if mutant_guard 's/if (\$4 == ".") whole\[/if (1) whole[/'; then
  run_range "$MUTANT_TOOLS/guard"
  [ "$RC" -eq 0 ] && [ "$LOG" = "$TEST" ] &&
    ok "control: a change one module reads runs the whole crate, with the module map removed" ||
    bad "control: a change one module reads runs the whole crate, with the module map removed" "rc=$RC log=$LOG out=$OUT"
else
  bad "control: the module map edit applies to tools/guard"
fi
git -C "$R" checkout -q -- skills

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
