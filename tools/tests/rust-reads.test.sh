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
a concat! literal joins the manifest directory|crates/demo/src/lib.rs|const S: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../ui/src/bindings.ts");|manifest:ui/src/bindings.ts:demo
a .join literal joins the manifest directory|crates/demo/src/lib.rs|read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../README.md"));|manifest:README.md:demo
a chain across lines that goes on with a non-literal prints its directory and the root|crates/demo/src/lib.rs|let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))\n    .join("../../docs/legal")\n    .join(name);|manifest:.:demo;manifest:docs/legal:demo
a format! argument leaves the read unfollowed|crates/demo/tests/t.rs|let p = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("../../{SCRIPT}"));|manifest:.:demo;manifest:crates/demo:demo
a non-literal concat! argument leaves the read unfollowed|crates/demo/src/lib.rs|const S: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../docs", SUFFIX);|manifest:.:demo;manifest:docs:demo
a parent() leaves the read unfollowed|crates/demo/tests/t.rs|read(Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap());|manifest:.:demo;manifest:crates/demo:demo
a comma after a join chain separates arguments and continues nothing|crates/demo/tests/t.rs|read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../README.md"),\n);|manifest:README.md:demo
consecutive literal joins resolve together|crates/demo/tests/t.rs|read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").join("docs/b.md"));|manifest:docs/b.md:demo
a chain used at the checkout root prints the root|crates/demo/tests/t.rs|open(&Path::new(env!("CARGO_MANIFEST_DIR")).join("../.."));|manifest:.:demo
the manifest directory alone is the crate|crates/demo/tests/t.rs|scan(Path::new(env!("CARGO_MANIFEST_DIR")));|manifest:crates/demo:demo
a file deeper in the crate still joins its manifest directory|crates/demo/src/deep/mod.rs|read(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/x.tsv"));|manifest:crates/demo/tests/fixtures/x.tsv:demo
a let binding is read where it is used|crates/demo/tests/t.rs|let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");\nlet text = read(root.join("docs/b.md"));|manifest:docs/b.md:demo
a binding through canonicalize and unwrap used whole reads the root|crates/demo/tests/t.rs|let catalog = Path::new(env!("CARGO_MANIFEST_DIR"))\n    .join("../..")\n    .canonicalize()\n    .unwrap();\ninstall(&catalog);|manifest:.:demo
a binding used nowhere reads nothing|crates/demo/tests/t.rs|let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");|
a binding ends with the block it was made in|crates/demo/tests/t.rs|fn a() {\n    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");\n    read(root.join("docs/a.md"));\n}\nfn b() {\n    read(root.join("docs/b.md"));\n}|manifest:docs/a.md:demo
a later let of the name ends its binding|crates/demo/tests/t.rs|let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docs");\nread(p.join("a.md"));\nlet p = scratch();\nread(p.join("b.md"));|manifest:docs/a.md:demo
a root helper is followed through each call, and its body is no read|crates/demo/tests/t.rs|fn root() -> PathBuf {\n    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")\n}\nfn t() {\n    read(root().join("hooks/README.md"));\n}|manifest:hooks/README.md:demo
a private helper serves its own module alone|crates/demo/tests/a.rs+crates/demo/tests/b.rs|fn root() -> PathBuf {\n    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")\n}\nfn t() {\n    read(root().join("docs/a.md"));\n}~~fn u() {\n    read(root().join("docs/b.md"));\n}|manifest:docs/a.md:demo
a helper whose chain climbs out of the checkout reads anything|crates/demo/tests/t.rs|fn out() -> PathBuf {\n    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")\n}\nfn t() {\n    read(out());\n}|manifest:.:demo
a file outside every crate belongs to the crates reaching it through a path attribute|crates/test_util.rs+crates/demo/src/lib.rs+crates/demo/tests/t.rs|pub fn checkout_root() -> PathBuf {\n    let guess = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");\n    canonical(&guess)\n}~~#[path = "../../test_util.rs"]\nmod test_util;~~fn t() {\n    read(test_util::checkout_root().join("hooks"));\n}|manifest:hooks:demo
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

echo "=== this repository's own reads carry the files its crates are known to read ==="
# Required members, one per shape the tree holds: a floor on the extractor,
# which a reader that lost a shape falls through. What is read beyond them
# is not held here.
OUT="$(cd "$ROOT" && "$READS" | tr '\t' ':')" || { bad "the repository's own reads are readable" "rc=$?"; OUT=""; }
for member in include:docs/authoring/README.md:kendex-app manifest:docs/legal:kendex-core \
  manifest:README.md:kendex-core manifest:hooks/README.md:kendex-core \
  manifest:skills/bot-instructions:kendex-core manifest:.:kendex-core manifest:.:kendex-cli; do
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
s/chain = chain unquote(substr(text, RSTART, RLENGTH))/chain = chain/|a concat! literal joins the manifest directory
s/if (seg\[i\] == "..") { if (k == 0) return ""; k--; continue }/if (seg[i] == "..") { if (k > 0) k--; continue }/|an include climbing out of the checkout names nothing
s/if (match(after, \/^\[ \\t\\n\]\*\\)+\/)) after = substr(after, RLENGTH + 1)//|a chain across lines that goes on with a non-literal prints its directory and the root
/if (entry\[2\] + 0) row("manifest", ".", dir)/d|a format! argument leaves the read unfollowed
s/\(push\).parent/\1/|a parent() leaves the read unfollowed
s/(in_concat \&\& match(text, \/^\[ \\t\\n\]\*,\/))/match(text, \/^[ \\t\\n]*,\/)/|a comma after a join chain separates arguments and continues nothing
s/        bound\[name\] = FOUND/        delete bound[name]/|a let binding is read where it is used
/for (name in bound) if (bound_level\[name\] > LEVEL) delete bound\[name\]/d|a binding ends with the block it was made in
/^        delete bound\[name\]$/d|a later let of the name ends its binding
s/if ((tok in SEEN_VALUE) \&\& match/if (0 \&\& match/|a root helper is followed through each call, and its body is no read
s/if (!helper\[k\]) continue/continue/|a root helper is followed through each call, and its body is no read
s/if (cand_scope\[k\] != "" \&\& file/if (0 \&\& file/|a private helper serves its own module alone
/if (ACC == "") ACC = "." FS_ 1/d|a helper whose chain climbs out of the checkout reads anything
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
