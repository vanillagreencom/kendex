#!/usr/bin/env bash
# The lanes end to end over the readers lib/common.sh and
# lib/configured-paths.sh share: an unmerged index is refused rather than
# scanned around, content decides what gg_grep_lane scans and an attributes
# rule never does, a blob whose leading bytes carry a NUL is counted unmeasured
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
  printf '[]\n' >"$R/.kendex-generated.json"
  git -C "$R" add .kendex-generated.json
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
  out="$(printf '%s\n' "$out" | LC_ALL=C awk '
    /^[a-z-]+: [a-z-]+=/ { print; next }
    /^[[:space:]]*dependency-order-control:/ { sub(/^[[:space:]]*/, ""); print }
  ')"
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | sed 's/[[:space:]]*$//' | paste -sd ';' -)}"
}

# Spelled in halves so this suite does not itself carry a conflict marker.
OPEN="<<<<""<<<"

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
fx_merged_big() { new_repo "$1"; printf 'seed\n' >"$R/seed.txt"; commit_all base; head -c 400000 /dev/zero >"$R/big.bin"; git -C "$R" add -A; }
fx_merged_small() { new_repo "$1"; printf 'seed\n' >"$R/seed.txt"; commit_all base; printf 'small\n' >"$R/small.txt"; git -C "$R" add -A; }

fx_addadd addadd-fixture
assert_eq "the add/add fixture really hides the addition from --diff-filter=A" 0 "$(git -C "$R" diff --cached --raw --diff-filter=A | wc -l | tr -d ' ')"

echo "=== an unmerged index is refused, never scanned around ==="
UNMERGED="CHECK: unmerged-path=f.txt;CHECK: unmerged-count=1"
BIG_UNMERGED="byte-ceiling: unmerged-path=big.txt;byte-ceiling: unmerged-count=1"
# label | fixture | lane args | expect
rows=(
  "conflict-markers refuses the unmerged index|conflicted_repo cm-unmerged|conflict-markers|rc=2 ${UNMERGED//CHECK/conflict-markers}"
  "control: once staged, the same markers fail as violations|fx_conflict_staged cm-staged|conflict-markers|rc=1 conflict-markers: match=conflict marker:f.txt:2:<<<<<<< HEAD;conflict-markers: match=conflict marker:f.txt:6:>>>>>>> other;conflict-markers: result=2:0:tools/conflict-markers-excludes"
  "control: a resolved, marker-free tree passes|fx_conflict_resolved cm-resolved|conflict-markers|rc=0 conflict-markers: result=0:0:tools/conflict-markers-excludes"
  "byte-ceiling refuses an add/add conflict instead of measuring around it|fx_addadd bc-addadd|byte-ceiling|rc=2 $BIG_UNMERGED"
  "--all refuses it too, where ls-files emits one record per stage|fx_addadd bc-addadd-all|byte-ceiling --all|rc=2 $BIG_UNMERGED"
  "control: a merged index still fails an oversized addition|fx_merged_big bc-merged-big|byte-ceiling|rc=1 byte-ceiling: oversized=big.bin:400000:391:200;byte-ceiling: result=1:1:200:staged:"
  "control: a merged index with nothing oversized passes|fx_merged_small bc-merged-small|byte-ceiling|rc=0 byte-ceiling: result=0:1:200:staged:"
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

fx_attrs attrs-probe merge.txt "$OPEN HEAD\n" '*.txt -diff'
assert_eq "fixture: with '*.txt -diff' a bare -I grep drops the file silently" "rc=1" \
  "$(rc=0; out="$(cd "$R" && git grep --cached -nIE "HEAD" -- merge.txt 2>&1)" || rc=$?; printf 'rc=%s%s' "$rc" "${out:+ $out}")"

echo "=== content decides what is scanned, an attributes rule never does ==="
SUPP_HIT="suppression-ban: match=module-wide rust allow:lib.rs:1:#![allow(dead_code)];suppression-ban: result=1:1:0:tools/suppression-baseline.tsv:0:tools/suppression-ban-excludes"
RATCHET_HIT="suppression-ban: allow-new=a.rs:1;suppression-ban: result=1:0:1:tools/suppression-baseline.tsv:0:tools/suppression-ban-excludes"
CM_HITS="conflict-markers: match=conflict marker:merge.txt:1:<<<<<<< HEAD;conflict-markers: match=conflict marker:merge.txt:5:>>>>>>> other;conflict-markers: result=2:0:tools/conflict-markers-excludes"
CONFLICT='<<<<<<< HEAD\na\n=======\nb\n>>>>>>> other\n'
# label | file | content (%b) | attributes row | lane args | expect
rows=(
  "control: conflict markers fail with no attributes row|merge.txt|$CONFLICT||conflict-markers|rc=1 $CM_HITS"
  "a '-diff' row cannot hide a conflict marker|merge.txt|$CONFLICT|*.txt -diff|conflict-markers|rc=1 $CM_HITS"
  "the 'binary' attribute macro cannot hide it either|merge.txt|$CONFLICT|*.txt binary|conflict-markers|rc=1 $CM_HITS"
  "control: the blanket allow fails with no attributes row|lib.rs|#![allow(dead_code)]\\n||suppression-ban|rc=1 $SUPP_HIT"
  "a '-diff' row cannot hide a blanket suppression|lib.rs|#![allow(dead_code)]\\n|*.rs -diff|suppression-ban|rc=1 $SUPP_HIT"
  "control: the unbaselined bare allow fails with no attributes row, the live row not called stale|ratchet|||suppression-ban|rc=1 $RATCHET_HIT"
  "a '-diff' row cannot hide a bare allow from the ratchet count|ratchet||*.rs -diff|suppression-ban|rc=1 $RATCHET_HIT"
  "--update cannot be led into erasing the ratchet: the re-check still fails|ratchet||*.rs -diff|suppression-ban --update|rc=1 suppression-ban: baseline-updated=tools/suppression-baseline.tsv:1;$RATCHET_HIT"
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

echo "=== a blob whose leading bytes carry a NUL is counted unmeasured, not scanned ==="
fx_attrs attrs-binary logo.png "PNG\0\n$OPEN not a marker\n"
assert_eq "the unread match is counted apart and the verdict carries the qualifier, with no path named" \
  "rc=0 conflict-markers: result=0:1:tools/conflict-markers-excludes" "$(lane "" conflict-markers)"
fx_attrs attrs-text logo.png "PNG \n$OPEN not a marker\n"
assert_eq "control: the same bytes without the NUL are scanned as text" \
  "rc=1 conflict-markers: match=conflict marker:logo.png:2:$OPEN not a marker;conflict-markers: result=1:0:tools/conflict-markers-excludes" "$(lane "" conflict-markers)"

# --- the shared readers fail closed -----------------------------------------

# gg_grep_guard, gg_read_blob and gg_blob_is_binary are the family's index
# readers: every lane collects through them, so an incomplete scan is refused
# HERE, once, including the call sites no default-lane run reaches.
git_shim() { # ARG — a git that exits 128 for any call carrying ARG
  local dir="$ROOT/git-shim-$1" message="git $1: simulated failure"
  mkdir -p "$dir"
  [ "$1" != grep ] || message="dependency-order-control: grep-exit"
  printf '#!/usr/bin/env bash\ncase " $* " in *" %s "*) echo "%s" >&2; exit 128 ;; esac\nexec "%s" "$@"\n' "$1" "$message" "$REAL_GIT" >"$dir/git"
  chmod +x "$dir/git"
}
git_shim grep
mkdir -p "$ROOT/git-shim-cat-file-order"
printf '#!/usr/bin/env bash\ncase " $* " in *" cat-file "*) echo "dependency-order-control: blob-read" >&2; exit 128 ;; esac\nexec "%s" "$@"\n' \
  "$REAL_GIT" >"$ROOT/git-shim-cat-file-order/git"
chmod +x "$ROOT/git-shim-cat-file-order/git"
# A wc that fails once, so the first count fails while the second succeeds;
# a tr that fails every time, breaking only the strip inside the second count.
mkdir -p "$ROOT/wc-shim" "$ROOT/tr-shim" "$ROOT/count-shim"
printf '#!/usr/bin/env bash\nif [ ! -e "%s" ]; then : >"%s"; echo "wc: simulated execution failure" >&2; exit 1; fi\nexec "%s" "$@"\n' \
  "$ROOT/wc-fired" "$ROOT/wc-fired" "$(command -v wc)" >"$ROOT/wc-shim/wc"
printf '#!/usr/bin/env bash\necho "tr: simulated execution failure" >&2\nexit 1\n' >"$ROOT/tr-shim/tr"
# suppression-ban's per-carrier count is its own call, made after the shared
# listing has named the carrier; the shim errors that call alone and exits 0,
# so the `error:` line on stderr is the only thing left that can refuse it.
printf '#!/usr/bin/env bash\ncase " $* " in *" -acE "*) : >%q; echo "error: %s: unable to read %s" >&2; exit 0 ;; esac\nexec "%s" "$@"\n' \
  "$ROOT/head-arm" "'phantom.rs'" "0000000000000000000000000000000000000000" "$REAL_GIT" >"$ROOT/count-shim/git"
printf '#!/usr/bin/env bash\nif [ -e %q ]; then echo "dependency-order-control: early-reader" >&2; rm -f -- %q; fi\nexec %q "$@"\n' "$ROOT/head-arm" "$ROOT/head-arm" "$(command -v head)" >"$ROOT/count-shim/head"
chmod +x "$ROOT/wc-shim/wc" "$ROOT/tr-shim/tr" "$ROOT/count-shim/git" "$ROOT/count-shim/head"

fx_readers() { new_repo "$1"; printf '%s stranded work\n' "$OPEN" >"$R/a.rs"; git -C "$R" add -A; }
fx_vanished() { # NAME [SECOND] — the staged blob's loose object removed; a readable second file when asked
  fx_readers "$1"
  local oid
  oid="$(git -C "$R" rev-parse :a.rs)"
  [ -f "$R/.git/objects/${oid:0:2}/${oid:2}" ] || echo "fixture: the staged blob is not a loose object" >&2
  rm -f -- "$R/.git/objects/${oid:0:2}/${oid:2}"
  [ -z "${2:-}" ] || { printf '%s readable\n' "$OPEN" >"$R/b.rs"; git -C "$R" add b.rs; }
}
# A staged text file near the size ceiling, which byte-ceiling samples for a
# NUL before it calls the file text.
fx_sampled() { new_repo "$1"; printf 'seed\n' >"$R/seed.txt"; commit_all seed; head -c 300000 /dev/zero | tr '\0' x >"$R/big.txt"; git -C "$R" add big.txt; rm -f "$ROOT/wc-fired"; }
fx_count() { new_repo "$1"; mkdir -p "$R/tools"; printf 'fn main() {}\n' >"$R/ok.rs"; printf '#[allow(dead_code)]\nfn b() {}\n' >"$R/bare.rs"; printf 'bare.rs\t1\n' >"$R/tools/suppression-baseline.tsv"; git -C "$R" add -A; }

echo "=== the shared readers fail closed, once, for every lane that uses them ==="
A_HIT="conflict-markers: match=conflict marker:a.rs:1:$OPEN stranded work;conflict-markers: result=1:0:tools/conflict-markers-excludes"
# label | fixture | shim | lane args | expect
rows=(
  "control: the staged marker trips with the real git|fx_readers readers-0||conflict-markers|rc=1 $A_HIT"
  "a git grep execution failure puts the stable record before git's cause|fx_readers readers-1|$ROOT/git-shim-grep|conflict-markers|rc=2 conflict-markers: grep-exit=128;dependency-order-control: grep-exit"
  "a blob read failure puts the stable record before git's cause|fx_readers readers-2|$ROOT/git-shim-cat-file-order|conflict-markers|rc=2 conflict-markers: blob-read=a.rs::0:a.rs;dependency-order-control: blob-read"
  "a vanished staged blob is exit 2 carrying git's own error line|fx_vanished readers-3||conflict-markers|rc=2 conflict-markers: grep-content=1"
  "a scan matching one file it read and one it could not is exit 2, never a violation|fx_vanished readers-4 second||conflict-markers|rc=2 conflict-markers: grep-content=0"
  "control: the staged text file passes the sample with the real tools|fx_sampled sampled-0||byte-ceiling --staged|rc=0 byte-ceiling: result=0:1:200:staged:"
  "a first block that cannot be sized is exit 2, never OK|fx_sampled sampled-1|$ROOT/wc-shim|byte-ceiling --staged|rc=2 byte-ceiling: content-sample=big.txt:1"
  "a NUL-free count that cannot run is exit 2, never OK|fx_sampled sampled-2|$ROOT/tr-shim|byte-ceiling --staged|rc=2 byte-ceiling: content-sample=big.txt:1"
  "control: the baselined bare allow passes with the real git|fx_count count-0||suppression-ban|rc=0 suppression-ban: result=0:0:0:tools/suppression-baseline.tsv:0:tools/suppression-ban-excludes"
  "a count whose stderr carries an error line refuses without an early-reader diagnostic|fx_count count-1|$ROOT/count-shim|suppression-ban|rc=2 suppression-ban: grep-content=0"
)
for row in "${rows[@]}"; do
  IFS='|' read -r label fixture shim args expect <<<"$row"
  $fixture
  # shellcheck disable=SC2086
  assert_eq "$label" "$expect" "$(lane "$shim" $args)"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
