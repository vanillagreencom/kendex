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
TMP="$(mktemp -d "$ROOT/tmp/rust-reads.XXXXXX")" || exit 2
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

run_reads() { # [READER] — sets OUT and RC; the rows as KIND:PATH, joined by ;
  local out
  OUT=""
  RC=0
  out="$(cd "$W" && "${1:-$READS}" 2>&1)" || RC=$?
  OUT="$(printf '%s' "$out" | tr '\t\n' ':;')"
}

# LABEL|FILE|SOURCE|ROWS — ROWS is every row the reader prints, in its order.
SHAPES='an include_str! literal resolves against the including file|crates/demo/src/lib.rs|const A: &str = include_str!("../../../docs/a.md");|include:docs/a.md
an include_bytes! literal resolves the same way|crates/demo/src/lib.rs|const A: &[u8] = include_bytes!("assets/logo.png");|include:crates/demo/src/assets/logo.png
a literal on the line after the parenthesis counts|crates/demo/src/lib.rs|const A: &str = include_str!(\n    "../../../docs/split.md"\n);|include:docs/split.md
an include climbing out of the checkout names nothing|crates/demo/src/lib.rs|const A: &str = include_str!("../../../../outside.md");|
a concat! literal joins the manifest directory|crates/demo/src/lib.rs|const S: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../ui/src/bindings.ts");|manifest:ui/src/bindings.ts
a .join literal joins the manifest directory|crates/demo/src/lib.rs|let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../README.md");|manifest:README.md
a chain across lines that goes on with a non-literal prints its directory and the root|crates/demo/src/lib.rs|let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))\n    .join("../../docs/legal")\n    .join(name);|manifest:.;manifest:docs/legal
a format! argument leaves the read unfollowed|crates/demo/tests/t.rs|let p = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("../../{SCRIPT}"));|manifest:.;manifest:crates/demo
a non-literal concat! argument leaves the read unfollowed|crates/demo/src/lib.rs|const S: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../docs", SUFFIX);|manifest:.;manifest:docs
consecutive literal joins resolve together|crates/demo/tests/t.rs|let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").join("docs/b.md");|manifest:docs/b.md
a chain stopping at the checkout root prints the root|crates/demo/tests/t.rs|let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");|manifest:.
the manifest directory alone is the crate|crates/demo/tests/t.rs|let dir = Path::new(env!("CARGO_MANIFEST_DIR"));|manifest:crates/demo
a file deeper in the crate still joins its manifest directory|crates/demo/src/deep/mod.rs|let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/x.tsv");|manifest:crates/demo/tests/fixtures/x.tsv
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
for member in include:docs/authoring/README.md manifest:docs/legal manifest:README.md; do
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
s/chain = chain unquote(substr(rest, RSTART, RLENGTH))/chain = chain/|a concat! literal joins the manifest directory
s/if (seg\[i\] == "..") { if (k == 0) return ""; k--; continue }/if (seg[i] == "..") { if (k > 0) k--; continue }/|an include climbing out of the checkout names nothing
s/if (match(rest, \/^\[ \\t\\n\]\*\\)+\/)) rest = substr(rest, RLENGTH + 1)//|a chain across lines that goes on with a non-literal prints its directory and the root
/emit("manifest", ".")$/d|a format! argument leaves the read unfollowed
ROWS
[ "$((PASS + FAIL))" -gt "$before" ] || { echo "no row was asserted: the controls" >&2; exit 2; }

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
