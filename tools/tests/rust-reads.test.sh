#!/usr/bin/env bash
# The proof for tools/rust-reads: one row per source shape the reader
# resolves or declines, each a checkout holding one crate and its source
# files; the build rows; the required members of this repository's own read
# set; the reads that cannot happen; and one control per derivation rule,
# each a copy of the reader with that rule removed, turning its row red.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

ROOT="$(git rev-parse --show-toplevel)"
READS="$ROOT/tools/rust-reads"
mkdir -p "$ROOT/tmp"
TMP="$(mktemp -d "$ROOT/tmp/rust-reads.XXXXXX")" || exit 2
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

W="$TMP/repo"

# A checkout with one crate, crates/demo, and each of FILES, joined by +,
# holding the SOURCES part in the same place, joined by ~~, whose `\n` is a
# newline.
seed_world() { # FILES SOURCES
  local files sources i
  rm -rf -- "${W:?}"
  mkdir -p "$W/crates/demo/src"
  printf '[package]\nname = "demo"\n' >"$W/crates/demo/Cargo.toml"
  IFS=+ read -r -a files <<<"$1"
  sources=()
  local rest="$2"
  while :; do
    sources+=("${rest%%~~*}")
    [ "$rest" != "${rest#*~~}" ] || break
    rest="${rest#*~~}"
  done
  [ "${#files[@]}" -eq "${#sources[@]}" ] ||
    { echo "seed_world: ${#files[@]} files for ${#sources[@]} sources" >&2; exit 2; }
  for i in "${!files[@]}"; do
    mkdir -p "$(dirname "$W/${files[$i]}")"
    printf '%b\n' "${sources[$i]}" >"$W/${files[$i]}"
  done
}

run_reads() { # [READER] — sets OUT and RC; the rows other than build as KIND:PATH:CRATE, joined by ;
  local out
  OUT=""
  RC=0
  out="$(cd "$W" && "${1:-$READS}" 2>&1)" || RC=$?
  OUT="$(printf '%s\n' "$out" | grep -v '^build	' | tr '\t' ':' | paste -sd ';' -)" || OUT=""
}

# LABEL|FILES|SOURCES|ROWS — ROWS is every row but the build rows the reader
# prints, in its order.
SHAPES='an include_str! literal resolves against the including file|crates/demo/src/lib.rs|const A: &str = include_str!("../../../docs/a.md");|include:docs/a.md:demo
an include_bytes! literal resolves the same way|crates/demo/src/lib.rs|const A: &[u8] = include_bytes!("assets/logo.png");|include:crates/demo/src/assets/logo.png:demo
a literal on the line after the parenthesis counts|crates/demo/src/lib.rs|const A: &str = include_str!(\n    "../../../docs/split.md"\n);|include:docs/split.md:demo
an include climbing out of the checkout names nothing|crates/demo/src/lib.rs|const A: &str = include_str!("../../../../outside.md");|
a concat! of the manifest directory and literals is a finished path|crates/demo/src/lib.rs|const S: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../ui/src/bindings.ts");|manifest:ui/src/bindings.ts:demo
a concat! inside Path::new handed to a call is placed|crates/demo/tests/t.rs|read(Path::new(concat!(\n    env!("CARGO_MANIFEST_DIR"),\n    "/../../ui/x.ts"\n)));|manifest:ui/x.ts:demo
a .join literal handed to a call is placed|crates/demo/src/lib.rs|read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../README.md"));|manifest:README.md:demo
consecutive literal joins resolve together|crates/demo/tests/t.rs|read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").join("docs/b.md"));|manifest:docs/b.md:demo
a comma after a join chain ends the argument|crates/demo/tests/t.rs|read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../README.md"),\n);|manifest:README.md:demo
canonicalize and unwrap after the joins keep the chain placed|crates/demo/tests/t.rs|copy(&PathBuf::from(env!("CARGO_MANIFEST_DIR"))\n    .join("../../skills/x")\n    .canonicalize()\n    .unwrap(), &dest);|manifest:skills/x:demo
a chain handed to a call at the checkout root reads the root|crates/demo/tests/t.rs|open(&Path::new(env!("CARGO_MANIFEST_DIR")).join("../.."));|manifest:.:demo
the manifest directory alone is the crate|crates/demo/tests/t.rs|scan(Path::new(env!("CARGO_MANIFEST_DIR")));|manifest:crates/demo:demo
a file deeper in the crate still joins its manifest directory|crates/demo/src/deep/mod.rs|read(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/x.tsv"));|manifest:crates/demo/tests/fixtures/x.tsv:demo
a chain that goes on with a non-literal join prints what it reached and the root|crates/demo/src/lib.rs|read(PathBuf::from(env!("CARGO_MANIFEST_DIR"))\n    .join("../../docs/legal")\n    .join(name));|manifest:.:demo;manifest:docs/legal:demo
a format! join argument is not followed|crates/demo/tests/t.rs|read(Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("../../{SCRIPT}")));|manifest:.:demo;manifest:crates/demo:demo
a non-literal concat! argument is not followed|crates/demo/src/lib.rs|const S: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../docs", SUFFIX);|manifest:.:demo;manifest:docs:demo
a parent() is not followed|crates/demo/tests/t.rs|read(Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap());|manifest:.:demo;manifest:crates/demo:demo
a chain bound by let is not followed|crates/demo/tests/t.rs|let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docs");\nread(root.join("a.md"));|manifest:.:demo;manifest:docs:demo
a concat! in Path::new bound by let is not followed|crates/demo/tests/t.rs|let p = Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/../../ui/x.ts"));|manifest:.:demo;manifest:ui/x.ts:demo
the manifest directory in a format! is not followed|crates/demo/tests/t.rs|read(format!("{}/../../hooks/x", env!("CARGO_MANIFEST_DIR")));|manifest:.:demo;manifest:crates/demo:demo
the manifest directory in string concatenation is not followed|crates/demo/tests/t.rs|let p = env!("CARGO_MANIFEST_DIR").to_owned() + "/../../hooks/x";|manifest:.:demo;manifest:crates/demo:demo
a helper returning String is not followed|crates/demo/tests/t.rs|fn root() -> String {\n    format!("{}/../..", env!("CARGO_MANIFEST_DIR"))\n}\nfn t() {\n    read(Path::new(&root()).join("hooks/x"));\n}|manifest:.:demo;manifest:crates/demo:demo
current_dir() is not followed|crates/demo/tests/t.rs|read(std::env::current_dir().unwrap().join("../../hooks/x"));|manifest:.:demo
a call of a Path helper is not followed|crates/demo/tests/t.rs|fn root() -> PathBuf {\n    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")\n}\nfn t() {\n    read(root().join("hooks/README.md"));\n}|manifest:.:demo
a Path helper nothing calls reads nothing|crates/demo/tests/t.rs|fn root() -> PathBuf {\n    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")\n}|
a commented-out chain is no read|crates/demo/tests/t.rs|// read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docs/a.md"));\nfn t() {}|
a file outside every crate belongs to the crates reaching it through a path attribute|crates/test_util.rs+crates/demo/src/lib.rs|pub fn fixture() {\n    read(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/x"));\n}~~#[path = "../../test_util.rs"]\nmod test_util;|manifest:crates/demo/tests/fixtures/x:demo
a file no crate reaches is read by none|crates/loose.rs|read(Path::new(env!("CARGO_MANIFEST_DIR")).join("x")); const A: &str = include_str!("../docs/c.md");|
each crate reading a path prints its own row|crates/other/Cargo.toml+crates/other/src/lib.rs+crates/demo/src/lib.rs|[package]\nname = "other"~~const A: &str = include_str!("../../../docs/a.md");~~const A: &str = include_str!("../../../docs/a.md");|include:docs/a.md:demo;include:docs/a.md:other
two reads of one path print one row|crates/demo/src/lib.rs|const A: &str = include_str!("../../../docs/a.md");\nconst B: &str = include_str!("../../../docs/a.md");|include:docs/a.md:demo
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

echo "=== every crate carries the build inputs cargo reads ==="
# Required members: the crates/ tree and the workspace files a change to
# which rebuilds every crate. What the reader prints beyond them is not held
# here.
build_rows() { # [READER] — the build rows as PATH:CRATE, one per line
  (cd "$W" && "${1:-$READS}") | awk -F '\t' '$1 == "build" { print $2 ":" $3 }'
}
BUILD_MEMBERS="crates Cargo.toml Cargo.lock rust-toolchain.toml .cargo clippy.toml"
seed_world crates/demo/src/lib.rs 'fn main() {}'
BUILD="$(build_rows)" || { bad "the build rows are readable" "rc=$?"; BUILD=""; }
for member in $BUILD_MEMBERS; do
  grep -qFx -- "$member:demo" <<<"$BUILD" &&
    ok "the build rows carry $member for the crate" ||
    bad "the build rows carry $member for the crate" "the build rows are broken: $BUILD"
done

echo "=== a crate is named by its package, and a manifest naming none is refused ==="
# MANIFEST|RC|OUTPUT — OUTPUT is the non-build rows, or the refusal line.
before=$((PASS + FAIL))
while IFS='|' read -r manifest rc want; do
  [ -n "$manifest" ] || continue
  seed_world crates/demo/Cargo.toml+crates/demo/src/lib.rs "$manifest~~const A: &str = include_str!(\"../../../docs/a.md\");"
  run_reads
  [ "$RC" -eq "$rc" ] && [ "$OUT" = "$want" ] && ok "manifest $manifest: rc=$rc" ||
    bad "manifest $manifest: rc=$rc" "rc=$RC want=$want out=$OUT"
done <<'ROWS'
[package] # the core library\nname = "demo"|0|include:docs/a.md:demo
[package]\nname = 'demo'|0|include:docs/a.md:demo
[package]\nversion = "1"|2|rust-reads: unreadable=crates/demo/Cargo.toml
[workspace]|2|rust-reads: unreadable=crates/demo/Cargo.toml
ROWS
[ "$((PASS + FAIL))" -gt "$before" ] || { echo "no row was asserted: the manifests" >&2; exit 2; }
# The refusal's control: with a missing name read as the directory, the crate
# prints under a name no cargo matrix leg carries.
sed 's/^    if (name == "") {$/    if (0) {/' "$READS" >"$TMP/rust-reads-unnamed"
chmod +x "$TMP/rust-reads-unnamed"
if cmp -s "$READS" "$TMP/rust-reads-unnamed"; then
  bad "control: a manifest naming no package is refused" "the edit changed nothing in a reader copy"
else
  seed_world crates/demo/Cargo.toml+crates/demo/src/lib.rs '[workspace]~~fn main() {}'
  run_reads "$TMP/rust-reads-unnamed"
  [ "$RC" -eq 0 ] && ok "control: a manifest naming no package is refused, with the refusal removed" ||
    bad "control: a manifest naming no package is refused, with the refusal removed" "rc=$RC out=$OUT"
fi

echo "=== this repository's own reads carry the files its crates are known to read ==="
# Required members, one per shape the tree holds: a floor on the extractor,
# which a reader that lost a shape falls through. What is read beyond them
# is not held here.
OUT="$(cd "$ROOT" && "$READS" | tr '\t' ':')" || { bad "the repository's own reads are readable" "rc=$?"; OUT=""; }
for member in include:docs/authoring/README.md:kendex-app manifest:ui/src/bindings.ts:kendex-app \
  manifest:docs/legal:kendex-core manifest:README.md:kendex-core \
  manifest:.:kendex-core manifest:.:kendex-cli; do
  grep -qFx -- "$member" <<<"$OUT" &&
    ok "the repository's reads carry $member" ||
    bad "the repository's reads carry $member" "the extractor is broken for that shape: $OUT"
done
# kendex-app reads nothing this reader cannot place, so its cargo legs stand
# down on a diff that reaches none of its reads. On a red, every kendex-app
# source is emptied in a copy of crates/ and each is put back alone, and the
# files that bring the row back by themselves are named.
if grep -qFx -- "manifest:.:kendex-app" <<<"$OUT"; then
  mkdir -p "$TMP/app-dot/kept"
  cp -R "$ROOT/crates" "$TMP/app-dot/crates"
  app_files="$(cd "$ROOT" && git ls-files -- 'crates/app/*.rs')"
  while IFS= read -r f; do
    mkdir -p "$TMP/app-dot/kept/$(dirname "$f")"
    mv "$TMP/app-dot/$f" "$TMP/app-dot/kept/$f"
    : >"$TMP/app-dot/$f"
  done <<<"$app_files"
  culprits=""
  while IFS= read -r f; do
    cp "$TMP/app-dot/kept/$f" "$TMP/app-dot/$f"
    rows_now="$(cd "$TMP/app-dot" && "$READS")" || rows_now=""
    ! grep -qFx -- "$(printf 'manifest\t.\tkendex-app')" <<<"$rows_now" || culprits="$culprits $f"
    : >"$TMP/app-dot/$f"
  done <<<"$app_files"
  bad "kendex-app prints no . row" "a read of kendex-app this reader cannot place, in:${culprits:- no single file}"
else
  ok "kendex-app prints no . row"
fi

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
# crates/ holding source and no manifest places no crate: a run that read
# nothing, never an empty set. The control removes that rule.
rm -f -- "$W/crates/demo/Cargo.toml"
run_reads
[ "$RC" -eq 2 ] && [ "$OUT" = "rust-reads: unreadable=crates" ] && ok "a crates/ that places no crate exits 2 naming crates" || bad "a crates/ that places no crate exits 2 naming crates" "rc=$RC out=$OUT"
sed '/^# Every crate placed prints build rows/,/^esac$/d' "$READS" >"$TMP/rust-reads-placeless"
chmod +x "$TMP/rust-reads-placeless"
if cmp -s "$READS" "$TMP/rust-reads-placeless"; then
  bad "control: a crates/ that places no crate exits 2" "the edit changed nothing in a reader copy"
else
  run_reads "$TMP/rust-reads-placeless"
  [ "$RC" -eq 0 ] && ok "control: a crates/ that places no crate exits 2, with that rule removed" ||
    bad "control: a crates/ that places no crate exits 2, with that rule removed" "rc=$RC out=$OUT"
fi
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
s/if (seg\[i\] == "..") { if (k == 0) return ""; k--; continue }/if (seg[i] == "..") { if (k > 0) k--; continue }/|an include climbing out of the checkout names nothing
s/joined = joined "\/" unquote(lit)/joined = joined/|a .join literal handed to a call is placed
s/joined = joined unquote(substr(after, RSTART, RLENGTH))/joined = joined/|a concat! of the manifest directory and literals is a finished path
s/after !~ \/^\[ \\t\\n\]\*\[),\]\//after !~ \/^[ \\t\\n]*[)]\//|a comma after a join chain ends the argument
s/(canonicalize.unwrap)/(nothing)/|canonicalize and unwrap after the joins keep the chain placed
/Handed whole to a call as one argument/{n;d;}|a chain bound by let is not followed
/^    row("manifest", ".", dir)$/d|the manifest directory in a format! is not followed
s/\]current_dir\[/]nothing_here[/|current_dir() is not followed
s/(calls == "" ? "" : /("" == "" ? "" : /|a call of a Path helper is not followed
s/kept = kept substr(rest, 1, RSTART) "}"/kept = kept substr(rest, 1, RSTART + length_ - 1)/|a Path helper nothing calls reads nothing
s/if (line ~ .*) line = ""/if (0) line = ""/|a commented-out chain is no read
s/if (target != "") includers\[target\]/if (0) includers[target]/|a file outside every crate belongs to the crates reaching it through a path attribute
ROWS
[ "$((PASS + FAIL))" -gt "$before" ] || { echo "no row was asserted: the controls" >&2; exit 2; }

# The build rows' control: with clippy.toml gone from the reader's list, the
# member floor above goes red for it.
sed 's/ \.cargo clippy\.toml / .cargo /' "$READS" >"$MUTANT"
chmod +x "$MUTANT"
if cmp -s "$READS" "$MUTANT"; then
  bad "control: the build rows carry clippy.toml" "the edit changed nothing in a reader copy"
else
  seed_world crates/demo/src/lib.rs 'fn main() {}'
  grep -qFx -- "clippy.toml:demo" <<<"$(build_rows "$MUTANT")" &&
    bad "control: the build rows carry clippy.toml" "a reader without it still printed it" ||
    ok "control: the build rows carry clippy.toml, with it removed"
fi

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
