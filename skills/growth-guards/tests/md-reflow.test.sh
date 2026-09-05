#!/usr/bin/env bash
# Pins for scripts/md-reflow: over a corpus of shapes, a reflowed file passes
# md-format, a second reflow changes nothing, and the constructs the format
# leaves alone come out byte-identical; a clean file is untouched; CRLF is
# refused; --check writes nothing; the file selection is md-format's. Every
# green assertion is paired with a control that proves it can fail.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
MDR="$SKILL_DIR/scripts/md-reflow"
MDF="$SKILL_DIR/scripts/md-format"
. "$TEST_DIR/lib/harness.bash"

unset GROWTH_GUARDS_MD_PATHS GROWTH_GUARDS_MD_EXCLUDES GROWTH_GUARDS_MD_SCOPE GROWTH_GUARDS_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

new_repo() { # NAME
  R="$TMP/$1"
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}

run_in() { # DIR CMD [args...] — sets OUT and RC
  local dir="$1"
  shift
  OUT=""
  RC=0
  OUT="$(cd "$dir" && "$@" 2>&1)" || RC=$?
}

# Reflow CONTENT as doc.md; assert the result equals WANT, that md-format
# then passes, and that a second reflow is a no-op.
corpus() { # LABEL CONTENT WANT
  local label="$1" content="$2" want="$3" got
  printf '%s' "$content" >"$R/doc.md"
  run_in "$R" "$MDR" doc.md
  if [ "$RC" -ne 0 ]; then
    bad "$label" "reflow rc=$RC out=$OUT"
    return
  fi
  got="$(cat "$R/doc.md"; printf x)"
  got="${got%x}"
  if [ "$got" != "$want" ]; then
    bad "$label" "got: $(printf '%q' "$got") want: $(printf '%q' "$want")"
    return
  fi
  git -C "$R" add doc.md
  run_in "$R" "$MDF" --all
  if [ "$RC" -ne 0 ]; then
    bad "$label: md-format passes after reflow" "rc=$RC out=$OUT"
    return
  fi
  run_in "$R" "$MDR" --check doc.md
  if [ "$RC" -ne 0 ]; then
    bad "$label: a second reflow is a no-op" "rc=$RC out=$OUT"
    return
  fi
  ok "$label"
}

new_repo corpus

echo "=== joining: paragraphs, list items, blockquotes, trailing breaks ==="
corpus "a hard-wrapped paragraph joins with single spaces, trailing space dropped" \
  $'First line  \nsecond line   \n  third.\n' $'First line second line third.\n'
corpus "a continued list item joins, and its nested item stays an item" \
  $'- item one\n  continued\n  - nested\n    continued too\n- item two\n' \
  $'- item one continued\n  - nested continued too\n- item two\n'
corpus "an ordered item joins" $'1. first\n   continued\n2. second\n' $'1. first continued\n2. second\n'
corpus "a blockquote paragraph joins, lazy continuation included" \
  $'> quoted\n> continued\nlazy\n\n> next\n' $'> quoted continued lazy\n\n> next\n'
corpus "a multi-paragraph item joins each paragraph on its own" \
  $'- item\n\n  second\n  paragraph\n' $'- item\n\n  second paragraph\n'

echo "=== separating: the blank line before a heading, fence or list ==="
corpus "a heading under a paragraph gets its blank line, before and after" \
  $'Para\n# Heading\nMore\n' $'Para\n\n# Heading\n\nMore\n'
corpus "a fence under a paragraph gets its blank line, and one after the closer" \
  $'Para\n```sh\nwrapped\ncode\n```\nAfter\n' $'Para\n\n```sh\nwrapped\ncode\n```\n\nAfter\n'
corpus "a list under a paragraph gets its blank line" $'Para\n- item\n' $'Para\n\n- item\n'
corpus "a fence directly under a list item gets its blank line, inside the item" \
  $'- item\n  ```\n  code\n  ```\n' $'- item\n\n  ```\n  code\n  ```\n'
corpus "a heading inside a blockquote gets a quoted blank line" \
  $'> para\n> # heading\n' $'> para\n>\n> # heading\n'
corpus "a heading gets its blank line before a table, a break, an HTML comment and a definition" \
  $'# H\n| a |\n|---|\n\n# I\n---\n\n# J\n<!-- x -->\n\n# K\n[a]: x\n' \
  $'# H\n\n| a |\n|---|\n\n# I\n\n---\n\n# J\n\n<!-- x -->\n\n# K\n\n[a]: x\n'
corpus "a fence closer gets its blank line before a table" \
  $'```\nx\n```\n| a |\n|---|\n' $'```\nx\n```\n\n| a |\n|---|\n'
corpus "a heading beside a change of quote depth gets a blank line at the shallower depth" \
  $'# H\n> q\n\n> p\n# I\n\n> # J\n>> deeper\n\n> # K\nafter\n' \
  $'# H\n\n> q\n\n> p\n\n# I\n\n> # J\n>\n>> deeper\n\n> # K\n\nafter\n'
corpus "a definition split over two lines joins into the one-line form" $'[ref]:\n  http://x\n' $'[ref]: http://x\n'

echo "=== byte-identical: fences, tables, HTML, indented code, front matter ==="
corpus "a fence keeps every line, backtick and tilde alike" \
  $'```\nwrapped\n  lines\n\n# not heading\n```\n\n~~~\nmore\nlines\n~~~\n' \
  $'```\nwrapped\n  lines\n\n# not heading\n```\n\n~~~\nmore\nlines\n~~~\n'
corpus "a table keeps its rows, and a table under a paragraph is a boundary" \
  $'Para\n| a | b |\n|---|---|\n| c | d |\n' $'Para\n| a | b |\n|---|---|\n| c | d |\n'
corpus "a details block keeps its lines" \
  $'<details>\n<summary>x</summary>\nwrapped\nlines\n\ninside\n</details>\n' \
  $'<details>\n<summary>x</summary>\nwrapped\nlines\n\ninside\n</details>\n'
corpus "a prompt-section block keeps its lines, blank lines included, to its closing tag" \
  $'Para\n\n<output_format>\nwrapped\nlines\n\nSource: [S]\nIssue: [I]\n</output_format>\n\nAfter\nwrapped\n' \
  $'Para\n\n<output_format>\nwrapped\nlines\n\nSource: [S]\nIssue: [I]\n</output_format>\n\nAfter wrapped\n'
corpus "a prompt-section block indented under a list item keeps its lines" \
  $'1. step\n\n   <delegation_format>\n   Follow: x\n\n   Source: [S]\n   Issue: [I]\n   </delegation_format>\n' \
  $'1. step\n\n   <delegation_format>\n   Follow: x\n\n   Source: [S]\n   Issue: [I]\n   </delegation_format>\n'
corpus "control: a prompt-section opener sharing its line with prose is a paragraph line" \
  $'<delegation_format> Do it.\nwrapped\n\nWorktree: [W]\n\n</delegation_format>\n' \
  $'<delegation_format> Do it. wrapped\n\nWorktree: [W]\n\n</delegation_format>\n'
corpus "a table without outer pipes keeps its rows, and a row after it without a pipe is a row" \
  $'Para\n\na | b\n--|--\n1 | 2\nrow\n\nAfter\n' $'Para\n\na | b\n--|--\n1 | 2\nrow\n\nAfter\n'
corpus "control: a pipe line over a plain dash line is a setext heading, and one over prose a wrap" \
  $'a | b\n---\n\na | b\nc | d\n' $'a | b\n---\n\na | b c | d\n'
corpus "indented code keeps its lines" $'Para\n\n    code\n    more\n' $'Para\n\n    code\n    more\n'
corpus "front matter keeps its lines" $'---\ntitle: x\nwrapped:\n  y\n---\n\nPara\n' $'---\ntitle: x\nwrapped:\n  y\n---\n\nPara\n'
corpus "reference definitions keep their lines" $'[a]: https://x\n[b]: y.md\n' $'[a]: https://x\n[b]: y.md\n'
corpus "a setext heading keeps its underline, and a wrapped one joins above it" \
  $'Heading\n=======\n\nPara\n\nTwo line\nheading\n---\n' $'Heading\n=======\n\nPara\n\nTwo line heading\n---\n'
corpus "a file without a trailing newline stays without one" $'Para' $'Para'

echo "=== a clean file is untouched, and --check says so without writing ==="
printf 'Clean.\n\n- item\n' >"$R/clean.md"
touch -t 200001010000 "$R/clean.md"
before="$(cat "$R/clean.md")"
mtime() { stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1"; }
m_before="$(mtime "$R/clean.md")"
run_in "$R" "$MDR" clean.md
[ "$RC" -eq 0 ] && case "$OUT" in *"0 of 1 file(s) rewritten"*) true ;; *) false ;; esac && [ "$(cat "$R/clean.md")" = "$before" ] \
  && ok "a clean file is reported unchanged and its bytes stand" || bad "clean file untouched" "rc=$RC out=$OUT"
[ "$(mtime "$R/clean.md")" = "$m_before" ] \
  && ok "and it was not rewritten in place either (mtime stands)" || bad "clean file not rewritten" "mtime moved"
printf 'Wrapped\ntext.\n' >"$R/wrapped.md"
run_in "$R" "$MDR" --check wrapped.md clean.md
[ "$RC" -eq 1 ] && case "$OUT" in *"would reflow wrapped.md"*"1 of 2 file(s) would change"*) true ;; *) false ;; esac \
  && ok "--check names the file a reflow would change and exits 1" || bad "--check names the file" "rc=$RC out=$OUT"
[ "$(cat "$R/wrapped.md")" = $'Wrapped\ntext.' ] && ok "--check wrote nothing" || bad "--check wrote nothing" "$(cat "$R/wrapped.md")"
run_in "$R" "$MDR" --check clean.md
[ "$RC" -eq 0 ] && ok "control: --check over a clean file exits 0" || bad "control: --check clean" "rc=$RC out=$OUT"

echo "=== refusals: CRLF, an unterminated fence, a symlink, a missing file ==="
printf 'Line one\r\nLine two\r\n' >"$R/crlf.md"
run_in "$R" "$MDR" crlf.md
[ "$RC" -eq 2 ] && case "$OUT" in *"crlf.md:1: a CRLF line ending"*"nothing written"*) true ;; *) false ;; esac \
  && ok "a CRLF file is refused at exit 2, naming the line" || bad "CRLF refused" "rc=$RC out=$OUT"
[ "$(cat "$R/crlf.md")" = $'Line one\r\nLine two\r' ] && ok "and it was not converted" || bad "CRLF not converted" "$(cat "$R/crlf.md" | od -c | head -3)"
printf 'Para\n\n```\nopen\n' >"$R/open.md"
run_in "$R" "$MDR" open.md
[ "$RC" -eq 2 ] && case "$OUT" in *"open.md:3: an unterminated fence"*) true ;; *) false ;; esac \
  && ok "an unterminated fence is refused at exit 2" || bad "unterminated fence refused" "rc=$RC out=$OUT"
printf 'Para\n\n<output_format>\nprose\n\nmore\n' >"$R/section.md"
run_in "$R" "$MDR" section.md
[ "$RC" -eq 2 ] && case "$OUT" in *"section.md:3: a block with no closing </output_format>"*) true ;; *) false ;; esac \
  && ok "a prompt-section block with no closing tag is refused at exit 2, naming the opener" || bad "unclosed section refused" "rc=$RC out=$OUT"
[ "$(cat "$R/section.md")" = $'Para\n\n<output_format>\nprose\n\nmore' ] && ok "and nothing was written" || bad "unclosed section not written" "$(cat "$R/section.md")"
ln -s clean.md "$R/link.md"
run_in "$R" "$MDR" link.md
[ "$RC" -eq 2 ] && case "$OUT" in *"is a symlink"*) true ;; *) false ;; esac \
  && ok "a symlink is refused rather than rewritten through" || bad "symlink refused" "rc=$RC out=$OUT"
run_in "$R" "$MDR" absent.md
[ "$RC" -eq 2 ] && ok "a missing path is exit 2" || bad "missing path is exit 2" "rc=$RC out=$OUT"
run_in "$R" "$MDR"
[ "$RC" -eq 2 ] && ok "no path and no scope is exit 2" || bad "no path is exit 2" "rc=$RC out=$OUT"
run_in "$R" "$MDR" --staged clean.md
[ "$RC" -eq 2 ] && ok "a path beside --staged is exit 2" || bad "path beside --staged" "rc=$RC out=$OUT"

echo "=== a path is taken from the invoking directory, inside the repository ==="
mkdir -p "$R/docs"
printf 'Wrapped\ntext.\n' >"$R/docs/deep.md"
run_in "$R/docs" "$MDR" deep.md
[ "$RC" -eq 0 ] && [ "$(cat "$R/docs/deep.md")" = "Wrapped text." ] \
  && ok "a relative path resolves from where md-reflow was run" || bad "relative path from cwd" "rc=$RC out=$OUT"
printf 'Wrapped\ntext.\n' >"$TMP/outside.md"
run_in "$R" "$MDR" "$TMP/outside.md"
[ "$RC" -eq 2 ] && case "$OUT" in *"outside this repository"*) true ;; *) false ;; esac \
  && ok "a path outside the repository is refused" || bad "outside path refused" "rc=$RC out=$OUT"

echo "=== --staged and --all select the files md-format would judge ==="
new_repo select
printf 'Wrapped\none.\n' >"$R/one.md"
printf 'Wrapped\ntwo.\n' >"$R/two.md"
mkdir -p "$R/vendor" "$R/tools"
printf 'Wrapped\nthree.\n' >"$R/vendor/three.md"
printf 'vendor/*\tupstream docs\n' >"$R/tools/md-excludes"
git -C "$R" add -A
git -C "$R" commit -qm seed
printf 'Wrapped\none more.\n' >"$R/one.md"
git -C "$R" add one.md
run_in "$R" "$MDR" --staged
[ "$RC" -eq 0 ] && [ "$(cat "$R/one.md")" = "Wrapped one more." ] && [ "$(cat "$R/two.md")" = $'Wrapped\ntwo.' ] \
  && ok "--staged reflows the work-tree copy of the staged file and leaves the rest" || bad "--staged selection" "rc=$RC out=$OUT"
run_in "$R" "$MDR" --all
[ "$RC" -eq 0 ] && [ "$(cat "$R/two.md")" = "Wrapped two." ] && [ "$(cat "$R/vendor/three.md")" = $'Wrapped\nthree.' ] \
  && ok "--all reflows every tracked markdown file minus the excludes" || bad "--all selection" "rc=$RC out=$OUT"
git -C "$R" add -A
run_in "$R" "$MDF" --all
[ "$RC" -eq 0 ] && ok "control: md-format --all passes on what --all reflowed" || bad "control: md-format after --all" "rc=$RC out=$OUT"

echo "=== a failed replacement preserves the file and removes its staging file ==="
new_repo replacement
printf 'Wrapped\ntext.\n' >"$R/doc.md"
cp "$R/doc.md" "$TMP/original.md"
mkdir -p "$TMP/fail-bin"
cat >"$TMP/fail-bin/mv" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'injected rename failure\n' >&2
exit 1
STUB
chmod +x "$TMP/fail-bin/mv"
run_in "$R" env PATH="$TMP/fail-bin:$PATH" "$MDR" doc.md
[ "$RC" -eq 2 ] && cmp -s "$R/doc.md" "$TMP/original.md" \
  && ok "rename failure is an error and preserves the original bytes" || bad "failed replacement" "rc=$RC out=$OUT"
leftovers="$(find "$R" -maxdepth 1 -type f ! -name doc.md -print)"
[ -z "$leftovers" ] && ok "failed replacement removes the staging file" || bad "staging file cleanup" "$leftovers"
run_in "$R" "$MDR" doc.md
[ "$RC" -eq 0 ] && [ "$(cat "$R/doc.md")" = 'Wrapped text.' ] \
  && ok "the same file reflows when rename succeeds" || bad "successful replacement control" "rc=$RC out=$OUT"

echo "=== staged reflow honors exclusions ==="
new_repo staged-exclusion
mkdir -p "$R/tools"
printf 'Wrapped\ntext.\n' >"$R/doc.md"
printf 'doc.md\tvendored document\n' >"$R/tools/md-excludes"
git -C "$R" add -A
run_in "$R" "$MDR" --staged
[ "$RC" -eq 0 ] && [ "$(cat "$R/doc.md")" = $'Wrapped\ntext.' ] \
  && ok "staged reflow leaves the excluded document unchanged" || bad "staged exclusion" "rc=$RC out=$OUT"
git -C "$R" rm -qf tools/md-excludes
run_in "$R" "$MDR" --staged
[ "$RC" -eq 0 ] && [ "$(cat "$R/doc.md")" = 'Wrapped text.' ] \
  && ok "the same staged document reflows without its exclusion" || bad "staged exclusion control" "rc=$RC out=$OUT"

echo "=== the skill's own shipped markdown is a fixed point ==="
new_repo self
mkdir -p "$R/skills/growth-guards"
for doc in SKILL.md README.md CHECKS.md DEVELOPMENT.md; do
  cp "$SKILL_DIR/$doc" "$R/skills/growth-guards/$doc"
done
git -C "$R" add -A
run_in "$R" "$MDR" --check --all
[ "$RC" -eq 0 ] && case "$OUT" in *"4 file(s) already in the format"*) true ;; *) false ;; esac \
  && ok "SKILL.md, README.md, CHECKS.md and DEVELOPMENT.md reflow to themselves" || bad "shipped docs are a fixed point" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
