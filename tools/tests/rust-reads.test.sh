#!/usr/bin/env bash
# The proof for tools/rust-reads: one row per source shape the reader
# resolves or declines, each a checkout holding one crate and one source
# file; the required members of this repository's own read set; the reads
# that cannot happen; and one control per derivation rule, each a copy of
# the reader with that rule removed, turning its row red.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

ROOT="$(git rev-parse --show-toplevel)"
READS="$ROOT/tools/rust-reads"
mkdir -p "$ROOT/tmp"
TMP="$(mktemp -d)" || exit 2
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

W="$TMP/repo"

# A checkout with one crate, crates/demo, and FILE holding SOURCE, whose `\n`
# is a newline.
seed_world() { # FILE SOURCE
  rm -rf -- "${W:?}"
  mkdir -p "$W/crates/demo/src" "$(dirname "$W/$1")"
  printf '[package]\nname = "demo"\n' >"$W/crates/demo/Cargo.toml"
  printf '%b\n' "$2" >"$W/$1"
}

run_reads() { # [READER] — sets OUT and RC; the rows but build as KIND:PATH, joined by ;
  local out
  OUT=""
  RC=0
  out="$(cd "$W" && "${1:-$READS}" 2>&1)" || RC=$?
  OUT="$(printf '%s\n' "$out" | grep -v '^build	' | tr '\t' ':' | paste -sd ';' -)" || OUT=""
}

# LABEL|FILE|SOURCE|ROWS — ROWS is every row the reader prints, in its order.
SHAPES='an include_str! literal resolves against the including file|crates/demo/src/lib.rs|const A: &str = include_str!("../../../docs/a.md");|include:docs/a.md
an include_bytes! literal resolves the same way|crates/demo/src/lib.rs|const A: &[u8] = include_bytes!("assets/logo.png");|include:crates/demo/src/assets/logo.png
a literal on the line after the parenthesis counts|crates/demo/src/lib.rs|const A: &str = include_str!(\n    "../../../docs/split.md"\n);|include:docs/split.md
an include climbing out of the checkout names nothing|crates/demo/src/lib.rs|const A: &str = include_str!("../../../../outside.md");|
a concat! literal joins the manifest directory|crates/demo/src/lib.rs|const S: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../ui/src/bindings.ts");|manifest:ui/src/bindings.ts:crates/demo/Cargo.toml
a .join literal joins the manifest directory|crates/demo/src/lib.rs|let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../README.md");|manifest:README.md:crates/demo/Cargo.toml
a chain across lines that goes on with a non-literal prints its directory and the root|crates/demo/src/lib.rs|let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))\n    .join("../../docs/legal")\n    .join(name);|manifest:.:crates/demo/Cargo.toml;manifest:docs/legal:crates/demo/Cargo.toml
a format! argument leaves the read unfollowed|crates/demo/tests/t.rs|let p = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("../../{SCRIPT}"));|manifest:.:crates/demo/Cargo.toml;manifest:crates/demo:crates/demo/Cargo.toml
a non-literal concat! argument leaves the read unfollowed|crates/demo/src/lib.rs|const S: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../docs", SUFFIX);|manifest:.:crates/demo/Cargo.toml;manifest:docs:crates/demo/Cargo.toml
consecutive literal joins resolve together|crates/demo/tests/t.rs|let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").join("docs/b.md");|manifest:docs/b.md:crates/demo/Cargo.toml
a chain stopping at the checkout root prints the root|crates/demo/tests/t.rs|let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");|manifest:.:crates/demo/Cargo.toml
the manifest directory alone is the crate|crates/demo/tests/t.rs|let dir = Path::new(env!("CARGO_MANIFEST_DIR"));|manifest:crates/demo:crates/demo/Cargo.toml
a file deeper in the crate still joins its manifest directory|crates/demo/src/deep/mod.rs|let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/x.tsv");|manifest:crates/demo/tests/fixtures/x.tsv:crates/demo/Cargo.toml
a file outside every crate reads no manifest directory|crates/loose.rs|let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("x"); const A: &str = include_str!("../docs/c.md");|include:docs/c.md
two reads of one path print one row|crates/demo/src/lib.rs|const A: &str = include_str!("../../../docs/a.md");\nconst B: &str = include_str!("../../../docs/a.md");|include:docs/a.md
source reading nothing prints nothing|crates/demo/src/lib.rs|fn main() {}|'

echo "=== each source shape resolves to its rows ==="
before=$((PASS + FAIL))
while IFS='|' read -r label file source rows; do
  [ -n "$label" ] || continue
  seed_world "$file" "$source"
  run_reads
  [ "$RC" -eq 0 ] && [ "$OUT" = "$rows" ] && ok "$label" || bad "$label" "rc=$RC want=$rows out=$OUT"
done <<<"$SHAPES"
[ "$((PASS + FAIL))" -gt "$before" ] || { echo "no row was asserted: the source shapes" >&2; exit 2; }

echo "=== this repository's own reads carry the files its crates are known to read ==="
# Required members, one per shape the tree holds: a floor on the extractor,
# which a reader that lost a shape falls through. What is read beyond them
# is not held here.
OUT="$(cd "$ROOT" && "$READS" | tr '\t' ':')" || { bad "the repository's own reads are readable" "rc=$?"; OUT=""; }
for member in include:docs/authoring/README.md manifest:docs/legal:crates/core/Cargo.toml manifest:README.md:crates/core/Cargo.toml manifest:skills:crates/core/Cargo.toml; do
  grep -qFx -- "$member" <<<"$OUT" &&
    ok "the repository's reads carry $member" ||
    bad "the repository's reads carry $member" "the extractor is broken for that shape: $OUT"
done

echo "=== a read that cannot run is never an empty set ==="
seed_world crates/demo/src/lib.rs 'fn main() {}'
REAL_FIND="$(command -v find)"
mkdir -p "$TMP/fake-bin"
cat >"$TMP/fake-bin/find" <<SH
#!/usr/bin/env bash
case "\$*" in *'*.rs'*) exit 1 ;; esac
exec "$REAL_FIND" "\$@"
SH
chmod +x "$TMP/fake-bin/find"
OUT=""
RC=0
OUT="$(cd "$W" && PATH="$TMP/fake-bin:$PATH" "$READS" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && [ "$OUT" = "rust-reads: unreadable=crates" ] && ok "a failed source walk exits 2 naming crates" || bad "a failed source walk exits 2 naming crates" "rc=$RC out=$OUT"
# crates/ with source and no manifest is refused; the control drops the rule.
rm -f -- "$W/crates/demo/Cargo.toml"
run_reads
[ "$RC" -eq 2 ] && [ "$OUT" = "rust-reads: unreadable=crates" ] && ok "a crates/ holding no crate exits 2 naming crates" || bad "a crates/ holding no crate exits 2 naming crates" "rc=$RC out=$OUT"
sed 's/ || \[ -z "\$manifests" \]; then$/; then/' "$READS" >"$TMP/rust-reads-crateless"
chmod +x "$TMP/rust-reads-crateless"
run_reads "$TMP/rust-reads-crateless"
! cmp -s "$READS" "$TMP/rust-reads-crateless" && [ "$RC" -eq 0 ] &&
  ok "control: a crates/ holding no crate exits 2, with that rule removed" ||
  bad "control: a crates/ holding no crate exits 2, with that rule removed" "rc=$RC out=$OUT"
rm -rf -- "${W:?}/crates"
run_reads
[ "$RC" -eq 2 ] && [ "$OUT" = "rust-reads: unreadable=crates" ] && ok "a checkout with no crates/ exits 2 naming it" || bad "a checkout with no crates/ exits 2 naming it" "rc=$RC out=$OUT"
OUT=""
RC=0
OUT="$("$READS" "$TMP/absent" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && [ "$OUT" = "rust-reads: unreadable=$TMP/absent" ] && ok "an absent root exits 2 naming it" || bad "an absent root exits 2 naming it" "rc=$RC out=$OUT"
OUT=""
RC=0
OUT="$("$READS" one two 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && [[ "$OUT" == "rust-reads: usage="* ]] && ok "a second argument is refused with the usage line" || bad "a second argument is refused with the usage line" "rc=$RC out=$OUT"


echo "=== each derivation rule has a control ==="
# EDIT|SHAPE LABEL — a reader copy with EDIT applied prints something other
# than that shape's rows. An edit carries no |, the column separator.
MUTANT="$TMP/rust-reads"
before=$((PASS + FAIL))
while IFS='|' read -r edit shape; do
  [ -n "$edit" ] || continue
  sed "$edit" "$READS" >"$MUTANT"
  chmod +x "$MUTANT"
  if cmp -s "$READS" "$MUTANT"; then
    bad "control: $shape" "the edit changed nothing in a reader copy: $edit"
    continue
  fi
  row="$(printf '%s\n' "$SHAPES" | grep -F -- "$shape|")"
  IFS='|' read -r _label file source rows <<<"$row"
  seed_world "$file" "$source"
  run_reads "$MUTANT"
  [ "$RC" -eq 0 ] && [ "$OUT" != "$rows" ] && ok "control: $shape, with that rule removed" ||
    bad "control: $shape, with that rule removed" "rc=$RC out=$OUT"
done <<'ROWS'
s/\\(\[ \\t\\n\]\*"\[^"\]\*"\/)) {/\\([ \\t]*"[^"]*"\/)) {/|a literal on the line after the parenthesis counts
s/chain = chain "\/" unquote(lit)/chain = chain/|a .join literal joins the manifest directory
s/chain = chain unquote(substr(rest, RSTART, RLENGTH))/chain = chain/|a concat! literal joins the manifest directory
s/if (seg\[i\] == "..") { if (k == 0) return ""; k--; continue }/if (seg[i] == "..") { if (k > 0) k--; continue }/|an include climbing out of the checkout names nothing
s/if (match(rest, \/^\[ \\t\\n\]\*\\)+\/)) rest = substr(rest, RLENGTH + 1)//|a chain across lines that goes on with a non-literal prints its directory and the root
/emit("manifest", ".", owner)$/d|a format! argument leaves the read unfollowed
ROWS
[ "$((PASS + FAIL))" -gt "$before" ] || { echo "no row was asserted: the controls" >&2; exit 2; }

echo "=== CLI smoke compiled scope retains its inputs and excludes other targets ==="
# Cargo metadata and the real CLI target produce this scope. The default
# workspace rows remain available to guard and the other compiler lanes.
SCOPE_TMP="$(mktemp -d)" || exit 2
trap 'rm -rf -- "${TMP:?}" "${SCOPE_TMP:?}"' EXIT
scope_rows() { # READER — sets SCOPE_ROWS and SCOPE_RC
  SCOPE_RC=0
  SCOPE_ROWS="$(cd "$ROOT" && "$1" --cli-smoke . 2>"$SCOPE_TMP/err")" || SCOPE_RC=$?
}
scope_matches() { # PATH — whether a scoped row contains this path
  awk -F '\t' -v path="$1" '
    $1 ~ /^cli-(build|include)$/ && (path == $2 || index(path, $2 "/") == 1) { found=1 }
    END { print found ? "true" : "false" }
  ' <<<"$SCOPE_ROWS"
}
scope_table() {
  local path expected
  while IFS='|' read -r path expected; do
    [ "$(scope_matches "$path")" = "$expected" ] && ok "CLI compiled scope: $path" || bad "CLI compiled scope: $path"
  done <<'ROWS'
crates/core/src/lib.rs|true
crates/cli/src/bin/kendex.rs|true
crates/cli/build.rs|true
crates/cli/tests/cli_smoke.rs|true
crates/test_util.rs|true
ui/src/index.css|true
docs/authoring/README.md|false
Cargo.toml|true
Cargo.lock|true
.cargo/config.toml|true
rust-toolchain.toml|true
crates/app/Cargo.toml|true
crates/app/src/editor.rs|false
crates/core/tests/main.rs|false
crates/cli/tests/main.rs|false
README.md|false
ROWS
}
scope_rows "$READS"
[ "$SCOPE_RC" -eq 0 ] || { bad "CLI scope is readable"; cat "$SCOPE_TMP/err"; }
scope_table
grep -qFx $'build\tcrates' <<<"$SCOPE_ROWS" && ok "scoped output retains workspace build rows" || bad "scoped output retains workspace build rows"

# Copies broaden package selection or remove one required input shape.
# Each copy must make the same scope table red, without a compile error.
while IFS='@' read -r needle replacement; do
  [ "$(grep -cxF -- "$needle" "$READS")" -eq 1 ] || exit 2
  NEEDLE="$needle" REPLACEMENT="$replacement" awk '
    $0 == ENVIRON["NEEDLE"] { print ENVIRON["REPLACEMENT"]; next } { print }
  ' "$READS" >"$SCOPE_TMP/reader"
  chmod +x "$SCOPE_TMP/reader"
  scope_rows "$SCOPE_TMP/reader"
  if [ "$SCOPE_RC" -eq 0 ] && ! (PASS=0 FAIL=0; scope_table >"$SCOPE_TMP/control"; [ "$FAIL" -eq 0 ]); then
    ok "control: CLI scope table rejects the changed derivation"
  else
    bad "control: CLI scope table accepts the changed derivation"
  fi
done <<'ROWS'
      | closure([$cli[0].manifest_path]) as $paths@      | [$packages[].manifest_path] as $paths
      | closure([$cli[0].manifest_path]) as $paths@      | [$cli[0].manifest_path] as $paths
        visit(resolve(dir, unquote(substr(rest, RSTART, RLENGTH))))@        # no path-module visit
    else if (kind == "include") printf "cli-include\t%s\n", path@    else if (kind == "include") printf "include\t%s\n", path
  shared=$(awk -F '\t' '$2 != "crates" { print "cli-build\t" $2 }' <<<"$build")@  shared=
ROWS

# A failed metadata invocation cannot become an empty scoped read set.
mkdir -p "$SCOPE_TMP/bin"
printf '#!/bin/sh\nexit 1\n' >"$SCOPE_TMP/bin/cargo"
chmod +x "$SCOPE_TMP/bin/cargo"
PATH="$SCOPE_TMP/bin:$PATH" scope_rows "$READS"
[ "$SCOPE_RC" -eq 2 ] && grep -qFx 'rust-reads: unreadable=cli-smoke' "$SCOPE_TMP/err" &&
  ok "failed Cargo metadata refuses the scoped read" || bad "failed Cargo metadata refuses the scoped read"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
