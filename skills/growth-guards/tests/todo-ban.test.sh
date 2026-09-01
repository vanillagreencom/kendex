#!/usr/bin/env bash
# Pins for scripts/todo-ban: both marker shapes fire, prose that quotes or
# names a marker word does not, excludes need reasons, --staged judges the
# lines the commit ADDS while the default scope judges the whole index, and
# the staged lane's change-set collection and hunk parse are collection
# errors — never a pass. Every green assertion is paired with a control that
# proves it can fail. The index readers this family of checks shares — the
# staged lane's carriers pre-filter and content sniff among them — are
# pinned once, in index-reads.test.sh, which drives them through this check.
#
# Marker words are assembled from split tokens throughout so this test
# file never contains a marker shape itself — the kendex repo runs
# todo-ban over its own tree, tests included.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TB="$SKILL_DIR/scripts/todo-ban"
. "$TEST_DIR/lib/harness.bash"

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

# A row is a shell glob against the whole path, so every `*` in it crosses
# `/`. A reader who writes `**/name/**` meaning "that vendored tree wherever
# it is rendered" gets "any directory called name, at any depth" — and the
# first-party one goes quiet with it, which is the one thing this file's own
# header forbids.
echo "=== excludes: a row anchored at a root does not exempt that name elsewhere ==="
new_repo cross
mkdir -p "$R/vendor/thing" "$R/crates/thing/src" "$R/tools"
printf '// %s: vendored upstream marker\n' "$TD" >"$R/vendor/thing/lib.rs"
printf '// %s: our own marker\n' "$TD" >"$R/crates/thing/src/lib.rs"
printf 'vendor/thing/**\tvendored third-party code\n' >"$R/tools/todo-ban-excludes"
git -C "$R" add -A
run_tb
[ "$RC" -eq 1 ] && case "$OUT" in
  *"crates/thing/src/lib.rs"*) ok "the first-party tree of the same name still fails" ;;
  *) bad "the anchored row exempted the wrong tree" "rc=$RC out=$OUT" ;;
esac || bad "the first-party marker was silenced" "rc=$RC out=$OUT"
case "$OUT" in
  *"vendor/thing/lib.rs"*) bad "the anchored row did not silence its own tree" "out=$OUT" ;;
  *) ok "and the vendored tree it names is silent" ;;
esac

# The control: the crossing shorthand does silence both, which is why a row
# is written out per root rather than spelled `**/thing/**`.
printf '**/thing/**\tthe shorthand that crosses\n' >"$R/tools/todo-ban-excludes"
git -C "$R" add -A
run_tb
[ "$RC" -eq 0 ] \
  && ok "must-fail control: the crossing shorthand silences the first-party tree too" \
  || bad "the crossing shorthand did not cross" "rc=$RC out=$OUT"

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
mkdir -p "$R/tools"
printf 'v.rs\tvendored fixture\n' >"$R/tools/growth-guards-todo-excludes"
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

echo "=== --staged judges the lines the commit adds, not the whole index ==="
new_repo stagedscope
printf 'fn main() {}\n' >"$R/ok.rs"
git -C "$R" add -A
git -C "$R" commit -qm seed
# Someone else's marker, committed and untouched by the commit under judgement.
printf '// %s: left in a fixture\n' "$TD" >"$R/fixture.rs"
git -C "$R" add -A
git -C "$R" commit -qm fixture
printf 'fn other() {}\n' >>"$R/ok.rs"
git -C "$R" add ok.rs
run_tb --staged
[ "$RC" -eq 0 ] && case "$OUT" in *"the staged diff adds no work markers"*) true ;; *) false ;; esac \
  && ok "a commit that adds no marker passes on a repo whose index holds one" \
  || bad "a commit adding no marker passes" "rc=$RC out=$OUT"
run_tb
[ "$RC" -eq 1 ] && case "$OUT" in *"work marker: fixture.rs:1:"*) true ;; *) false ;; esac \
  && ok "control: the index scan (CI) still refuses that same marker" \
  || bad "control: the index scan refuses the marker" "rc=$RC out=$OUT"

# The same commit, now adding a marker of its own.
printf '// %s: added by this commit\n' "$FX" >>"$R/ok.rs"
git -C "$R" add ok.rs
run_tb --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"work marker: ok.rs:3:"*) true ;; *) false ;; esac \
  && ok "a marker the staged diff adds is refused, at the line it lands on" \
  || bad "a staged marker is refused" "rc=$RC out=$OUT"
case "$OUT" in
  *"fixture.rs"*) bad "the untouched fixture must stay out of the commit-scope verdict" "$OUT" ;;
  *) ok "and the untouched fixture is not in that verdict" ;;
esac

echo "=== --staged reads the index, not the work tree ==="
new_repo stagedbytes
printf 'fn main() {}\n' >"$R/ok.rs"
git -C "$R" add -A
git -C "$R" commit -qm seed
printf '// %s: staged\n' "$TD" >>"$R/ok.rs"
git -C "$R" add ok.rs
printf 'fn main() {}\n' >"$R/ok.rs" # the work tree walks it back; the index still carries it
run_tb --staged
[ "$RC" -eq 1 ] && ok "staged bytes decide, whatever the work tree says now" \
  || bad "staged bytes decide" "rc=$RC out=$OUT"
# Control: staging the walked-back file clears the verdict.
git -C "$R" add ok.rs
run_tb --staged
[ "$RC" -eq 0 ] && ok "control: staging the walked-back file clears it" \
  || bad "control: staging the walked-back file clears it" "rc=$RC out=$OUT"

echo "=== --staged on a repository's first commit diffs against the empty tree ==="
new_repo firstcommit
printf '// %s: in the very first commit\n' "$TD" >"$R/a.rs"
git -C "$R" add -A
run_tb --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"work marker: a.rs:1:"*) true ;; *) false ;; esac \
  && ok "with no HEAD to diff against, the whole staged tree reads as added" \
  || bad "the first commit is judged" "rc=$RC out=$OUT"
# Control: the same repository with no marker staged passes rather than
# erroring on the missing HEAD.
printf 'fn main() {}\n' >"$R/a.rs"
git -C "$R" add -A
run_tb --staged
[ "$RC" -eq 0 ] && case "$OUT" in *"the staged diff adds no work markers"*) true ;; *) false ;; esac \
  && ok "control: a clean first commit passes, not exit 2 for want of a HEAD" \
  || bad "control: a clean first commit passes" "rc=$RC out=$OUT"

echo "=== --staged honours the exclusion list ==="
new_repo stagedexc
printf 'fn main() {}\n' >"$R/ok.rs"
mkdir -p "$R/vendor" "$R/tools"
git -C "$R" add -A
git -C "$R" commit -qm seed
printf '// %s: vendored upstream marker\n' "$TD" >"$R/vendor/lib.rs"
git -C "$R" add -A
run_tb --staged
[ "$RC" -eq 1 ] && ok "control: the staged vendored marker fails without an excludes row" \
  || bad "control: staged vendored marker fails" "rc=$RC out=$OUT"
printf 'vendor/*\tvendored third-party code\n' >"$R/tools/todo-ban-excludes"
git -C "$R" add -A
run_tb --staged
[ "$RC" -eq 0 ] && ok "the excludes row silences the staged vendored tree too" \
  || bad "excludes row silences the staged tree" "rc=$RC out=$OUT"

echo "=== a .gitattributes rule cannot hide staged content from the lane ==="
new_repo stagedattr
printf 'fn main() {}\n' >"$R/ok.rs"
git -C "$R" add -A
git -C "$R" commit -qm seed
# A committed '-diff' rule makes git call every .rs file binary: the plain
# staged diff then carries no hunks at all, and the index scan skips the blob
# unless both are forced to text. That is the shape a whole extension could
# be hidden behind by committing one attributes line.
printf '*.rs -diff\n' >"$R/.gitattributes"
git -C "$R" add -A
git -C "$R" commit -qm attrs
printf '// %s: behind an attributes rule\n' "$TD" >>"$R/ok.rs"
git -C "$R" add ok.rs
case "$(git -C "$R" diff --cached -- ok.rs)" in
  *"Binary files"*) ok "fixture: the rule does suppress the unforced staged diff" ;;
  *) bad "fixture: the rule suppresses the unforced staged diff" "the attributes rule did not take" ;;
esac
run_tb --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"work marker: ok.rs:2:"*) true ;; *) false ;; esac \
  && ok "a marker added under a non-diffable path is refused, at its own line" \
  || bad "a marker under a non-diffable path is refused" "rc=$RC out=$OUT"

# Control: the same rule still in force, over an addition that carries no
# marker — forcing text reads real content, it does not fail everything it
# forces through. Committing the marker first is what makes this arm reach
# that read: the index blob goes on carrying a marker, so the pre-filter
# lists the path and the --text diff really runs over it, and the verdict
# is decided by the one line THIS commit adds.
git -C "$R" commit -qm "the marker, now committed"
printf 'fn clean() {}\n' >>"$R/ok.rs"
git -C "$R" add ok.rs
case "$(git -C "$R" diff --cached -- ok.rs)" in
  *"Binary files"*) ok "fixture: the rule still suppresses the unforced staged diff" ;;
  *) bad "fixture: the rule still suppresses the unforced staged diff" "the attributes rule lapsed" ;;
esac
run_tb --staged
[ "$RC" -eq 0 ] && case "$OUT" in *"the staged diff adds no work markers"*) true ;; *) false ;; esac \
  && ok "a clean addition to a marker-carrying file under the same rule passes" \
  || bad "a clean addition under the rule passes" "rc=$RC out=$OUT"
case "$OUT" in
  *"ok.rs"*) bad "the committed marker was attributed to the commit that only added a clean line" "$OUT" ;;
  *) ok "and the marker it already carried stays out of this commit's verdict" ;;
esac

echo "=== content decides what is scanned, never an attribute ==="
new_repo binaryblob
printf 'fn main() {}\n' >"$R/ok.rs"
git -C "$R" add -A
git -C "$R" commit -qm seed
# A real asset whose bytes happen to spell a marker. The pre-filter forces
# every blob to text, so this path IS listed; what keeps it out of the
# verdict is the content sniff — a NUL in the first block, git's own test —
# and nothing about how the path is named or attributed. Without the sniff
# the raw bytes reach awk and the commit is blocked by a garbled record.
printf '\211PNG\r\n\032\n\000\000 %s: in the pixels\n' "$TD" >"$R/asset.png"
git -C "$R" add asset.png
run_tb --staged
[ "$RC" -eq 0 ] && case "$OUT" in *"the staged diff adds no work markers"*) true ;; *) false ;; esac \
  && ok "a genuinely binary blob whose bytes spell a marker does not fire" \
  || bad "a binary blob does not fire" "rc=$RC out=$OUT"
# An unread match leaves a trace and qualifies the verdict, rather than
# riding inside a plain OK over content the lane deliberately did not read.
case "$OUT" in
  *"not measured: asset.png — binary content"*"1 matched path(s) not measured"*)
    ok "the skipped carrier is named and carried into the verdict"
    ;;
  *) bad "the skipped carrier is named and carried into the verdict" "out=$OUT" ;;
esac

# The must-fail control: the same bytes with the NULs taken out are a text
# file, and a text file is read whatever it is called.
printf '\211PNG\r\n\032\n %s: in the pixels\n' "$TD" >"$R/asset.png"
git -C "$R" add asset.png
run_tb --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"work marker: asset.png:"*) true ;; *) false ;; esac \
  && ok "control: the same bytes without a NUL are text, and fire" \
  || bad "control: the NUL-free bytes fire" "rc=$RC out=$OUT"

# The window is git's, 8000 bytes, and the arms above only pin it from
# below. A NUL past 8000 leaves git calling the blob text — `git diff
# --numstat` counts its lines rather than printing '-' — so the sniff must
# read it too. A wider read here answers "binary", the file is skipped, and
# a marker that fails the index scan passes the commit.
{
  head -c 8050 /dev/zero | LC_ALL=C tr '\000' 'x'
  printf '\000\n// %s: past the 8000-byte window\n' "$TD"
} >"$R/late-nul.rs"
git -C "$R" reset -q -- asset.png
git -C "$R" add late-nul.rs
[ "$(git -C "$R" diff --cached --numstat -- late-nul.rs | cut -f1)" = 2 ] \
  || bad "fixture: git does not call the late-NUL blob text" "$(git -C "$R" diff --cached --numstat -- late-nul.rs)"
run_tb --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"work marker: late-nul.rs:2:"*) true ;; *) false ;; esac \
  && ok "a NUL past git's 8000-byte window leaves the blob text, and it fires" \
  || bad "a late NUL leaves the blob text" "rc=$RC out=$OUT"

echo "=== a type change emits two diff sections, neither header an added line ==="
new_repo typechange
printf 'fn main() {}\n' >"$R/ok.rs"
# The path itself carries a marker shape, so a '+++ b/<path>' header read as
# content fires. A symlink-to-file change emits a deletion section and a
# creation section for the one path, and the creation section's header sits
# between them at the deletion hunk's numbering.
ln -s ok.rs "$R/a $TD: x.md"
git -C "$R" add -A
git -C "$R" commit -qm seed
rm -- "$R/a $TD: x.md"
printf 'fn clean() {}\n' >"$R/a $TD: x.md"
git -C "$R" add -A
run_tb --staged
# The pre-filter matches CONTENT, never path names, so a clean file at a
# path shaped like a marker is never listed and the run ends before the
# parser. That is the whole of what this arm pins; the parser is the pair
# below.
[ "$RC" -eq 0 ] \
  && ok "a type change to a clean regular file passes: a marker shape in the PATH is not content" \
  || bad "a clean type change passes" "rc=$RC out=$OUT"

# The same type change, its new regular file carrying a marker on one line
# and clean content on the next. This is the arm that reaches the parser:
# the path is listed, both diff sections are read, and only the line the
# file actually carries may be named — not the creation section's header,
# and not the clean line beside it.
printf '// %s: added with the regular file\nfn clean() {}\n' "$FX" >"$R/a $TD: x.md"
git -C "$R" add -A
run_tb --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"x.md:1:"*) true ;; *) false ;; esac \
  && ok "a marker in the new regular file fires at its own line" \
  || bad "the marker in the new regular file fires" "rc=$RC out=$OUT"
case "$OUT" in *":0:"*) bad "the creation section's header rode along as line 0" "$OUT" ;; *) ok "and the section header is not a record" ;; esac
case "$OUT" in *"x.md:2:"*) bad "the clean line beside the marker was judged a marker" "$OUT" ;; *) ok "and the clean line beside it is judged on its own" ;; esac

echo "=== rename detection is held to EXACT content ==="
new_repo renamed
i=1
: >"$R/old.rs"
while [ "$i" -le 40 ]; do
  printf 'fn f%s() {}\n' "$i" >>"$R/old.rs"
  i=$((i + 1))
done
git -C "$R" add -A
git -C "$R" commit -qm seed
# Moved AND edited: at 100% it does not pair, so it arrives as an addition
# and is read whole. At any lower threshold it pairs as R, is dropped by
# --diff-filter=AMT, and the marker below is never judged.
git -C "$R" mv old.rs new.rs
printf '// %s: added in the move\n' "$TD" >>"$R/new.rs"
git -C "$R" add new.rs
run_tb --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"work marker: new.rs:41:"*) true ;; *) false ;; esac \
  && ok "a file that moved and gained a marker is read whole, at its new path" \
  || bad "a moved-and-edited file is read whole" "rc=$RC out=$OUT"

# The counterpart the same threshold buys: a pure move adds no line, so a
# marker someone else committed does not become this commit's.
new_repo renamepure
printf '// %s: committed long ago\n' "$TD" >"$R/legacy.rs"
git -C "$R" add -A
git -C "$R" commit -qm seed
git -C "$R" mv legacy.rs moved.rs
run_tb --staged
[ "$RC" -eq 0 ] && ok "a pure move of a committed marker adds no line, so it passes" \
  || bad "a pure move passes" "rc=$RC out=$OUT"
run_tb
[ "$RC" -eq 1 ] && case "$OUT" in *"work marker: moved.rs:1:"*) true ;; *) false ;; esac \
  && ok "control: the index scan still refuses that marker at its new path" \
  || bad "control: the index scan refuses the moved marker" "rc=$RC out=$OUT"

echo "=== fail-closed: a broken staged scan terminates, never passes ==="
new_repo stagedfail
printf 'fn main() {}\n' >"$R/ok.rs"
git -C "$R" add -A
git -C "$R" commit -qm seed
printf 'fn other() {}\n' >>"$R/ok.rs"
git -C "$R" add ok.rs
run_tb --staged
[ "$RC" -eq 0 ] && ok "shim-free control: the fixture passes with the real git" \
  || bad "shim-free control passes" "rc=$RC out=$OUT"

# One shim per collection step, so each error path is proven on its own: the
# change-set collection, then the per-file read of the added lines.
REAL_GIT="$(command -v git)"
make_diff_shim() { # DIR MATCH — a git whose `diff` fails when MATCH is in argv
  mkdir -p "$1"
  cat >"$1/git" <<EOF
#!/usr/bin/env bash
saw_diff=0
saw_match=0
for a in "\$@"; do
  [ "\$a" = "diff" ] && saw_diff=1
  [ "\$a" = "$2" ] && saw_match=1
done
if [ "\$saw_diff" = 1 ] && [ "\$saw_match" = 1 ]; then
  echo "git diff: simulated execution failure" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$1/git"
}

make_diff_shim "$TMP/raw-shim" --raw
OUT="$(cd "$R" && PATH="$TMP/raw-shim:$PATH" "$TB" --staged 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"could not collect the staged changes"*) true ;; *) false ;; esac \
  && ok "a failed change-set collection is exit 2, never OK" \
  || bad "failed change-set collection is exit 2" "rc=$RC out=$OUT"
case "$OUT" in *"todo-ban: OK"*) bad "no OK verdict may accompany a broken collection" "$OUT" ;; *) ok "no OK verdict accompanies the broken collection" ;; esac

# The per-file read is reached only for a path the index scan named, so this
# case stages a marker to give the shim a file to fail on.
printf '// %s: staged for the per-file read\n' "$TD" >>"$R/ok.rs"
git -C "$R" add ok.rs
make_diff_shim "$TMP/hunk-shim" -U0
OUT="$(cd "$R" && PATH="$TMP/hunk-shim:$PATH" "$TB" --staged 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"could not read the staged additions in 'ok.rs'"*) true ;; *) false ;; esac \
  && ok "a file whose added lines cannot be read is exit 2, naming it" \
  || bad "unreadable added lines are exit 2" "rc=$RC out=$OUT"
case "$OUT" in *"todo-ban: OK"*) bad "no OK verdict may accompany an unread file" "$OUT" ;; *) ok "no OK verdict accompanies the unread file" ;; esac

echo "=== fail-closed: a hunk parser that cannot run is a collection error ==="
new_repo hunkparse
printf 'fn main() {}\n' >"$R/ok.rs"
git -C "$R" add -A
git -C "$R" commit -qm seed
printf '// %s: staged for the parser to read\n' "$TD" >>"$R/ok.rs"
git -C "$R" add ok.rs
run_tb --staged
[ "$RC" -eq 1 ] && ok "shim-free control: the staged marker fires with the real awk" \
  || bad "shim-free control fires" "rc=$RC out=$OUT"

# The shim exits 1 on purpose: 1 is this family's "violations", so a parser
# status read as the lane's own would fold a measurement that never ran into
# a violation verdict, with no line saying so.
REAL_AWK="$(command -v awk)"
AWK_SHIM="$TMP/awk-shim"
mkdir -p "$AWK_SHIM"
cat >"$AWK_SHIM/awk" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *hunk*)
      echo "awk: simulated hunk-parser failure" >&2
      exit 1
      ;;
  esac
done
exec "$REAL_AWK" "\$@"
EOF
chmod +x "$AWK_SHIM/awk"
OUT="$(cd "$R" && PATH="$AWK_SHIM:$PATH" "$TB" --staged 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"could not parse the staged additions in 'ok.rs'"*) true ;; *) false ;; esac \
  && ok "a hunk parser that fails is exit 2, naming the file" \
  || bad "a failed hunk parser is exit 2" "rc=$RC out=$OUT"
case "$OUT" in *"work marker:"*) bad "a scan that never ran may not produce a violation" "$OUT" ;; *) ok "and no violation verdict comes with it" ;; esac
case "$OUT" in *"todo-ban: OK"*) bad "no OK verdict may accompany a broken parse" "$OUT" ;; *) ok "no OK verdict accompanies the broken parse" ;; esac

echo "=== the carriers pre-filter is chunked, and every chunk survives ==="
# The chunk size is 256, so a change set larger than that is the only shape
# that runs the loop more than once. A chunk that overwrites its
# predecessors instead of appending drops the carrier named by an earlier
# one, and the lane prints OK: this repository's own render-propagation
# commits stage several hundred files at a time, so the shape is routine.
new_repo chunking
printf 'fn main() {}\n' >"$R/seed.rs"
git -C "$R" add -A
git -C "$R" commit -qm seed
printf '// %s: in the first chunk\n' "$TD" >"$R/a000.rs"
i=1
while [ "$i" -lt 300 ]; do
  printf 'fn f%s() {}\n' "$i" >"$R/$(printf 'a%03d' "$i").rs"
  i=$((i + 1))
done
git -C "$R" add -A
run_tb --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"work marker: a000.rs:1:"*) true ;; *) false ;; esac \
  && ok "a marker in the first of 300 staged paths survives every later chunk" \
  || bad "the first chunk's carrier survives" "rc=$RC out=$OUT"
case "$OUT" in *"todo-ban: OK"*) bad "no OK verdict may accompany a chunked carrier" "$OUT" ;; *) ok "no OK verdict accompanies the chunked scan" ;; esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
