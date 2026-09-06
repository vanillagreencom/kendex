#!/usr/bin/env bash
# The lanes end to end over the readers lib/common.sh and
# lib/configured-paths.sh share: an unmerged index is refused rather than
# scanned around, content decides what gg_grep_lane scans and an attributes
# rule never does, a blob whose leading bytes carry a NUL is named unmeasured
# rather than scanned or dropped, and a reader git or a tool could not run is
# a collection error, never a clean verdict. One table per family: a row
# builds its own fixture repository, runs one lane under an optional PATH
# shim, and reads back the exit status and every line printed.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPTS="$SKILL_DIR/scripts"
ROOT="$TMP"
REAL_GIT="$(command -v git)"

unset COMMIT_GUARDS_SETTINGS_FILE COMMIT_GUARDS_CONFLICT_EXCLUDES 2>/dev/null || true

PASS=0
FAIL=0
assert_eq() { # LABEL EXPECT ACTUAL
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
  fi
}

new_repo() { # NAME — fresh fixture repo in $R, cwd unchanged
  R="$ROOT/$1"
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}
commit_all() { # MESSAGE
  git -C "$R" add -A
  git -C "$R" commit -qm "$1"
}

# One line for a lane run inside $R, SHIM-DIR first on PATH when given: the
# exit status, then every printed line in order joined by ';', so a refusal
# reads with git's own line above it and a verdict with its qualifier.
lane() { # SHIM-DIR SCRIPT [ARG...]
  local dir="$1" script="$2" rc=0 out
  shift 2
  out="$(cd "$R" && PATH="${dir:+$dir:}$PATH" "$SCRIPTS/$script" "$@" 2>&1)" || rc=$?
  out="${out//"$R"/<repo>}"
  out="${out//"$ROOT"/<root>}"
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | sed 's/[[:space:]]*$//' | paste -sd ';' -)}"
}

# Spelled in halves so this suite is not itself a work marker.
MARKER="TO""DO"

# --- an unmerged index -------------------------------------------------------

conflicted_repo() { # NAME — fixture left mid-merge, f.txt unmerged
  new_repo "$1"
  printf 'line1\nbase\nline3\n' >"$R/f.txt"
  commit_all base
  git -C "$R" checkout -q -b other
  printf 'line1\ntheirs\nline3\n' >"$R/f.txt"
  git -C "$R" commit -qam other
  git -C "$R" checkout -q main
  printf 'line1\nours\nline3\n' >"$R/f.txt"
  git -C "$R" commit -qam ours
  git -C "$R" merge other >/dev/null 2>&1 || true
}
fx_conflict_staged() { conflicted_repo "$1"; git -C "$R" add f.txt; }
fx_conflict_resolved() { conflicted_repo "$1"; printf 'line1\nmerged\nline3\n' >"$R/f.txt"; git -C "$R" add f.txt; }
# An add/add conflict is status U, which --diff-filter=A drops entirely: the
# addition vanishes from the record set and a ceiling measures nothing.
fx_addadd() {
  new_repo "$1"
  printf 'seed\n' >"$R/seed.txt"
  commit_all base
  git -C "$R" checkout -q -b other
  head -c 400000 /dev/zero | tr '\0' 'b' >"$R/big.txt"
  commit_all other
  git -C "$R" checkout -q main
  head -c 400000 /dev/zero | tr '\0' 'a' >"$R/big.txt"
  commit_all ours
  git -C "$R" merge other >/dev/null 2>&1 || true
}
fx_merged_big() { new_repo "$1"; printf 'seed\n' >"$R/seed.txt"; commit_all base; head -c 400000 /dev/zero | tr '\0' 'a' >"$R/big.txt"; git -C "$R" add -A; }
fx_merged_small() { new_repo "$1"; printf 'seed\n' >"$R/seed.txt"; commit_all base; printf 'small\n' >"$R/small.txt"; git -C "$R" add -A; }

fx_addadd addadd-fixture
assert_eq "the add/add fixture really hides the addition from --diff-filter=A" 0 "$(git -C "$R" diff --cached --raw --diff-filter=A | wc -l | tr -d ' ')"

echo "=== an unmerged index is refused, never scanned around ==="
UNMERGED="f.txt;::error::CHECK: the index carries 1 unmerged path(s) (listed above) and a --cached scan skips them silently — finish or abort the merge, then re-run"
BIG_UNMERGED="big.txt;::error::byte-ceiling: the index carries 1 unmerged path(s) (listed above) and a --cached scan skips them silently — finish or abort the merge, then re-run"
# label | fixture | lane args | expect
rows=(
  "conflict-markers refuses the unmerged index|conflicted_repo cm-unmerged|conflict-markers|rc=2 ${UNMERGED//CHECK/conflict-markers}"
  "prose refuses it before its walk, though no default path matches|conflicted_repo prose-unmerged|prose|rc=2 ${UNMERGED//CHECK/prose}"
  "control: once staged, the same markers fail as violations|fx_conflict_staged cm-staged|conflict-markers|rc=1 conflict-markers FAIL conflict marker: f.txt:2:<<<<<<< HEAD;  remedies: finish the merge and delete the marker lines; a file that legitimately carries the trio at column 0 belongs in tools/conflict-markers-excludes with a reason;conflict-markers FAIL conflict marker: f.txt:6:>>>>>>> other;  remedies: finish the merge and delete the marker lines; a file that legitimately carries the trio at column 0 belongs in tools/conflict-markers-excludes with a reason;conflict-markers: 2 conflict marker(s) — excludes tools/conflict-markers-excludes"
  "control: a resolved, marker-free tree passes|fx_conflict_resolved cm-resolved|conflict-markers|rc=0 conflict-markers: OK — no conflict markers in tracked files"
  "byte-ceiling refuses an add/add conflict instead of measuring around it|fx_addadd bc-addadd|byte-ceiling|rc=2 $BIG_UNMERGED"
  "--all refuses it too, where ls-files emits one record per stage|fx_addadd bc-addadd-all|byte-ceiling --all|rc=2 $BIG_UNMERGED"
  "control: a merged index still fails an oversized addition|fx_merged_big bc-merged-big|byte-ceiling|rc=1 byte-ceiling FAIL oversized file: big.txt — 400000 bytes (~391 KB) > ceiling 200 KB;  remedies: keep big artifacts out of the repo (asset store, Git LFS, build-time generation); a file that genuinely belongs gets a row in tools/byte-ceiling-excludes with its reason;byte-ceiling: 1 violation(s) — ceiling 200 KB, 1 staged file(s) checked"
  "control: a merged index with nothing oversized passes|fx_merged_small bc-merged-small|byte-ceiling|rc=0 byte-ceiling: OK — 1 staged file(s) checked, ceiling 200 KB"
)
for row in "${rows[@]}"; do
  IFS='|' read -r label fixture args expect <<<"$row"
  $fixture
  # shellcheck disable=SC2086
  assert_eq "$label" "$expect" "$(lane "" $args)"
done

# --- content decides what is scanned ----------------------------------------

# `git grep -I` takes its binary verdict from the path's userdiff driver, so
# ONE committed attributes row would put a whole extension outside the scan
# with no status and no stderr. Each lane is read with and without the row.
fx_attrs() { # NAME FILE CONTENT [ATTR-ROW]
  new_repo "$1"
  printf '%b' "$3" >"$R/$2"
  [ -z "${4:-}" ] || printf '%s\n' "$4" >"$R/.gitattributes"
  git -C "$R" add -A
}
fx_ratchet() { # NAME [ATTR-ROW]
  new_repo "$1"
  mkdir -p "$R/tools"
  printf '#[allow(dead_code)]\nfn a() {}\n' >"$R/a.rs"
  printf '#[allow(dead_code)]\nfn b() {}\n' >"$R/b.rs"
  printf 'b.rs\t1\n' >"$R/tools/suppression-baseline.tsv"
  [ -z "${2:-}" ] || printf '%s\n' "$2" >"$R/.gitattributes"
  git -C "$R" add -A
}

fx_attrs attrs-probe code.py "x = 1  # $MARKER: real\n" '*.py -diff'
assert_eq "fixture: with '*.py -diff' a bare -I grep drops the file silently" "rc=1" \
  "$(rc=0; out="$(cd "$R" && git grep --cached -nIE "$MARKER" -- code.py 2>&1)" || rc=$?; printf 'rc=%s%s' "$rc" "${out:+ $out}")"

echo "=== content decides what is scanned, an attributes rule never does ==="
TODO_HIT="todo-ban FAIL work marker: code.py:1:x = 1  # $MARKER: real;  remedies: do the work now, or move it to the tracker and delete the marker; vendored/generated trees belong in tools/todo-ban-excludes with a reason;todo-ban: 1 work marker(s) — excludes tools/todo-ban-excludes"
SUPP_HIT="suppression-ban FAIL module-wide rust allow: lib.rs:1:#![allow(dead_code)];  remedies: delete the module-wide attribute and fix the findings, or annotate the surviving sites per line with a stated reason; vendored trees belong in tools/suppression-ban-excludes with a reason;suppression-ban: 1 violation(s) — 1 blanket, 0 ratchet (baseline tools/suppression-baseline.tsv)"
RATCHET_HIT="suppression-ban FAIL new bare allow: a.rs — 1 reasonless allow(dead_code)/allow(unused) attribute(s), no baseline row;  remedies: state a reason on each attribute or fix the code; freezing a legacy count is a hand-added baseline row in this diff with justification;suppression-ban: 1 violation(s) — 0 blanket, 1 ratchet (baseline tools/suppression-baseline.tsv)"
CM_HITS="conflict-markers FAIL conflict marker: merge.txt:1:<<<<<<< HEAD;  remedies: finish the merge and delete the marker lines; a file that legitimately carries the trio at column 0 belongs in tools/conflict-markers-excludes with a reason;conflict-markers FAIL conflict marker: merge.txt:5:>>>>>>> other;  remedies: finish the merge and delete the marker lines; a file that legitimately carries the trio at column 0 belongs in tools/conflict-markers-excludes with a reason;conflict-markers: 2 conflict marker(s) — excludes tools/conflict-markers-excludes"
CONFLICT='<<<<<<< HEAD\na\n=======\nb\n>>>>>>> other\n'
# label | file | content (%b) | attributes row | lane args | expect
rows=(
  "control: the marker fails with no attributes row|code.py|x = 1  # $MARKER: real\\n||todo-ban|rc=1 $TODO_HIT"
  "the index-wide todo-ban lane still reads a '-diff' path|code.py|x = 1  # $MARKER: real\\n|*.py -diff|todo-ban|rc=1 $TODO_HIT"
  "the 'binary' attribute macro cannot hide it either|code.py|x = 1  # $MARKER: real\\n|*.py binary|todo-ban|rc=1 $TODO_HIT"
  "control: conflict markers fail with no attributes row|merge.txt|$CONFLICT||conflict-markers|rc=1 $CM_HITS"
  "a '-diff' row cannot hide a conflict marker|merge.txt|$CONFLICT|*.txt -diff|conflict-markers|rc=1 $CM_HITS"
  "control: the blanket allow fails with no attributes row|lib.rs|#![allow(dead_code)]\\n||suppression-ban|rc=1 $SUPP_HIT"
  "a '-diff' row cannot hide a blanket suppression|lib.rs|#![allow(dead_code)]\\n|*.rs -diff|suppression-ban|rc=1 $SUPP_HIT"
  "control: the unbaselined bare allow fails with no attributes row, the live row not called stale|ratchet|||suppression-ban|rc=1 $RATCHET_HIT"
  "a '-diff' row cannot hide a bare allow from the ratchet count|ratchet||*.rs -diff|suppression-ban|rc=1 $RATCHET_HIT"
  "--update cannot be led into erasing the ratchet: the re-check still fails|ratchet||*.rs -diff|suppression-ban --update|rc=1 suppression-ban --update: baseline tightened at tools/suppression-baseline.tsv (1 row(s));$RATCHET_HIT"
)
i=0
for row in "${rows[@]}"; do
  IFS='|' read -r label file content attr args expect <<<"$row"
  i=$((i + 1))
  if [ "$file" = ratchet ]; then fx_ratchet "attrs-$i" "$attr"; else fx_attrs "attrs-$i" "$file" "$content" "$attr"; fi
  # shellcheck disable=SC2086
  assert_eq "$label" "$expect" "$(lane "" $args)"
done
assert_eq "--update left the baseline as it was" "b.rs	1" "$(cat "$R/tools/suppression-baseline.tsv")"

echo "=== a blob whose leading bytes carry a NUL is named unmeasured, not scanned ==="
fx_attrs attrs-binary logo.png "PNG\0 $MARKER: not a marker\n"
assert_eq "the unread match is named, counted apart, and the verdict carries the qualifier" \
  "rc=0 todo-ban: not measured: logo.png — binary content, not text;todo-ban: OK — no work markers in tracked files; 1 matched path(s) not measured" "$(lane "" todo-ban)"
fx_attrs attrs-text logo.png "PNG  $MARKER: not a marker\n"
assert_eq "control: the same bytes without the NUL are scanned as text" \
  "rc=1 todo-ban FAIL work marker: logo.png:1:PNG  $MARKER: not a marker;  remedies: do the work now, or move it to the tracker and delete the marker; vendored/generated trees belong in tools/todo-ban-excludes with a reason;todo-ban: 1 work marker(s) — excludes tools/todo-ban-excludes" "$(lane "" todo-ban)"

# --- the shared readers fail closed -----------------------------------------

# gg_grep_guard, gg_read_blob and gg_blob_is_binary are the family's index
# readers: every lane collects through them, so an incomplete scan is refused
# HERE, once, including the call sites no default-lane run reaches.
git_shim() { # ARG — a git that exits 128 for any call carrying ARG
  local dir="$ROOT/git-shim-$1"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\ncase " $* " in *" %s "*) echo "git %s: simulated failure" >&2; exit 128 ;; esac\nexec "%s" "$@"\n' "$1" "$1" "$REAL_GIT" >"$dir/git"
  chmod +x "$dir/git"
}
git_shim grep
git_shim cat-file
# A wc that fails once, so the first count fails while the second succeeds;
# a tr that fails every time, breaking only the strip inside the second count.
mkdir -p "$ROOT/wc-shim" "$ROOT/tr-shim" "$ROOT/count-shim"
printf '#!/usr/bin/env bash\nif [ ! -e "%s" ]; then : >"%s"; echo "wc: simulated execution failure" >&2; exit 1; fi\nexec "%s" "$@"\n' \
  "$ROOT/wc-fired" "$ROOT/wc-fired" "$(command -v wc)" >"$ROOT/wc-shim/wc"
printf '#!/usr/bin/env bash\necho "tr: simulated execution failure" >&2\nexit 1\n' >"$ROOT/tr-shim/tr"
# suppression-ban's per-carrier count is its own call, made after the shared
# listing has named the carrier; the shim errors that call alone and exits 0,
# so the `error:` line on stderr is the only thing left that can refuse it.
printf '#!/usr/bin/env bash\ncase " $* " in *" -acE "*) echo "error: %s: unable to read %s" >&2; exit 0 ;; esac\nexec "%s" "$@"\n' \
  "'phantom.rs'" "0000000000000000000000000000000000000000" "$REAL_GIT" >"$ROOT/count-shim/git"
chmod +x "$ROOT/wc-shim/wc" "$ROOT/tr-shim/tr" "$ROOT/count-shim/git"

# A sed script aliasing every staged blob's sha to OID(path): a reader that
# names the blob it could not read is read back by the path it stands for.
oid_aliases() {
  git -C "$R" ls-files -s | awk '{ printf "s|%s|OID(%s)|g\n", $2, $4 }' >"$ROOT/oids.sed"
  printf '%s' "$ROOT/oids.sed"
}
fx_readers() { new_repo "$1"; printf '// %s: stranded work\n' "$MARKER" >"$R/a.rs"; git -C "$R" add -A; }
fx_vanished() { # NAME [SECOND] — the staged blob's loose object removed; a readable second file when asked
  fx_readers "$1"
  local oid
  oid="$(git -C "$R" rev-parse :a.rs)"
  [ -f "$R/.git/objects/${oid:0:2}/${oid:2}" ] || echo "fixture: the staged blob is not a loose object" >&2
  rm -f -- "$R/.git/objects/${oid:0:2}/${oid:2}"
  [ -z "${2:-}" ] || { printf '// %s: readable\n' "$MARKER" >"$R/b.rs"; git -C "$R" add b.rs; }
}
fx_staged() { new_repo "$1"; printf 'fn main() {}\n' >"$R/ok.rs"; commit_all seed; printf '// %s: staged for the pre-filter to find\n' "$MARKER" >>"$R/ok.rs"; git -C "$R" add ok.rs; rm -f "$ROOT/wc-fired"; }
fx_count() { new_repo "$1"; mkdir -p "$R/tools"; printf 'fn main() {}\n' >"$R/ok.rs"; printf '#[allow(dead_code)]\nfn b() {}\n' >"$R/bare.rs"; printf 'bare.rs\t1\n' >"$R/tools/suppression-baseline.tsv"; git -C "$R" add -A; }

echo "=== the shared readers fail closed, once, for every lane that uses them ==="
A_HIT="todo-ban FAIL work marker: a.rs:1:// $MARKER: stranded work;  remedies: do the work now, or move it to the tracker and delete the marker; vendored/generated trees belong in tools/todo-ban-excludes with a reason;todo-ban: 1 work marker(s) — excludes tools/todo-ban-excludes"
# label | fixture | shim | lane args | expect
rows=(
  "control: the staged marker trips with the real git|fx_readers readers-0||todo-ban|rc=1 $A_HIT"
  "a git grep execution failure is a collection error, never OK|fx_readers readers-1|$ROOT/git-shim-grep|todo-ban|rc=2 git grep: simulated failure;::error::todo-ban: git grep failed scanning tracked files for work marker (exit 128)"
  "a blob read that cannot run is exit 2, never a path skipped|fx_readers readers-2|$ROOT/git-shim-cat-file|todo-ban|rc=2 git cat-file: simulated failure;::error::todo-ban: cannot read blob :0:a.rs for a.rs — refusing to skip an unread work marker"
  "a vanished staged blob is exit 2 carrying git's own error line|fx_vanished readers-3||todo-ban|rc=2 error: 'a.rs': unable to read OID(a.rs);::error::todo-ban: git grep could not read staged content while scanning tracked files for work marker (error: 'a.rs': unable to read OID(a.rs))"
  "a scan matching one file it read and one it could not is exit 2, never a violation|fx_vanished readers-4 second||todo-ban|rc=2 error: 'a.rs': unable to read OID(a.rs);::error::todo-ban: git grep could not read staged content while scanning tracked files for work marker (error: 'a.rs': unable to read OID(a.rs))"
  "control: the staged marker fires with the real tools|fx_staged staged-0||todo-ban --staged|rc=1 todo-ban FAIL work marker: ok.rs:2:// $MARKER: staged for the pre-filter to find;  remedies: do the work now, or move it to the tracker and delete the marker; vendored/generated trees belong in tools/todo-ban-excludes with a reason;todo-ban: 1 work marker(s) added by the staged diff — excludes tools/todo-ban-excludes"
  "a broken staged pre-filter is a collection error, never OK|fx_staged staged-1|$ROOT/git-shim-grep|todo-ban --staged|rc=2 git grep: simulated failure;::error::todo-ban: git grep failed listing the staged files that carry a work marker (exit 128)"
  "a staged blob the sniff cannot read is exit 2, never a path skipped|fx_staged staged-2|$ROOT/git-shim-cat-file|todo-ban --staged|rc=2 git cat-file: simulated failure;::error::todo-ban: cannot read blob OID(ok.rs) for ok.rs — refusing to skip an unread work marker"
  "a first block that cannot be sized is exit 2, never OK|fx_staged staged-3|$ROOT/wc-shim|todo-ban --staged|rc=2 wc: simulated execution failure;::error::todo-ban: could not sample ok.rs to classify its content"
  "a NUL-free count that cannot run is exit 2, never OK|fx_staged staged-4|$ROOT/tr-shim|todo-ban --staged|rc=2 tr: simulated execution failure;::error::todo-ban: could not sample ok.rs to classify its content"
  "control: the baselined bare allow passes with the real git|fx_count count-0||suppression-ban|rc=0 suppression-ban: OK — no blanket suppressions, bare allows within baseline tools/suppression-baseline.tsv"
  "a count whose stderr carries an error line is exit 2, never a clean zero|fx_count count-1|$ROOT/count-shim|suppression-ban|rc=2 error: 'phantom.rs': unable to read 0000000000000000000000000000000000000000;::error::suppression-ban: git grep could not read staged content while counting the bare allows in 'bare.rs' (error: 'phantom.rs': unable to read 0000000000000000000000000000000000000000)"
)
for row in "${rows[@]}"; do
  IFS='|' read -r label fixture shim args expect <<<"$row"
  $fixture
  # shellcheck disable=SC2086
  assert_eq "$label" "$expect" "$(lane "$shim" $args | sed -f "$(oid_aliases)")"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
