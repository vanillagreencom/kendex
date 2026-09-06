#!/usr/bin/env bash
# Pins for scripts/md-format: each rule of the format fires on the shape it
# names and stays quiet on the shapes it skips, the three scopes select the
# files the docs say, the remedy names md-reflow, and what cannot be judged
# is named rather than passed. Every green assertion is paired with a
# control that proves it can fail. The index readers this family shares are
# pinned once, in index-reads.test.sh.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
MDF="$SKILL_DIR/scripts/md-format"
. "$TEST_DIR/lib/harness.bash"

unset COMMIT_GUARDS_MD_PATHS COMMIT_GUARDS_MD_EXCLUDES COMMIT_GUARDS_MD_SCOPE COMMIT_GUARDS_SETTINGS_FILE 2>/dev/null || true

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

run_mdf() { # [args...] — run in $R; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$MDF" "$@" 2>&1)" || RC=$?
}

put() { # PATH CONTENT — a tracked file, staged
  mkdir -p "$R/$(dirname "$1")"
  printf '%s' "$2" >"$R/$1"
  git -C "$R" add -A
}

# The shape under test, staged as doc.md and judged with --all; asserts the
# verdict and, on a violation, the line and rule named.
shape() { # LABEL EXPECT-RC CONTENT [LINE RULE-FRAGMENT]
  local label="$1" want="$2" content="$3" line="${4-}" rule="${5-}"
  put doc.md "$content"
  run_mdf --all
  if [ "$RC" -ne "$want" ]; then
    bad "$label" "rc=$RC want=$want out=$OUT"
    return
  fi
  if [ "$want" -eq 1 ]; then
    case "$OUT" in
      *"format: doc.md:$line: $rule"*) ok "$label" ;;
      *) bad "$label" "expected doc.md:$line: $rule in: $OUT" ;;
    esac
  else
    ok "$label"
  fi
}

new_repo shapes

echo "=== a clean file passes, and the verdict counts it ==="
shape "one paragraph per line, blank-separated, passes" 0 $'# Title\n\nOne paragraph on one line.\n\n- item one\n- item two\n\nAnother.\n'
case "$OUT" in *"md-format: OK — 1 tracked markdown file(s) clean"*) ok "the verdict counts the file it read" ;; *) bad "verdict counts files" "$OUT" ;; esac

echo "=== the rules fire on the shapes they name ==="
shape "a hard-wrapped paragraph fails on the continuation line" 1 $'First line\nsecond line.\n' 2 "a paragraph hard-wrapped over lines"
shape "a list item continued on the next line fails" 1 $'- item\n  continued\n' 2 "a list item continued on the next line"
shape "an ordered item continued on the next line fails" 1 $'1. item\n   continued\n' 2 "a list item continued on the next line"
shape "a heading directly under a paragraph fails" 1 $'Para\n# Heading\n' 2 "a heading not preceded by a blank line"
shape "a heading not followed by a blank line fails" 1 $'# Heading\nPara\n' 2 "a heading not followed by a blank line"
shape "a fence directly under a paragraph fails" 1 $'Para\n```\ncode\n```\n' 2 "a fence directly under a paragraph or list line"
shape "a fence closer not followed by a blank line fails" 1 $'```\ncode\n```\nPara\n' 4 "a fence not followed by a blank line"
shape "a list directly under a paragraph fails" 1 $'Para\n- item\n' 2 "a list item directly under a paragraph line"
shape "a table directly under a heading fails" 1 $'# H\n| a |\n|---|\n' 2 "a heading not followed by a blank line"
shape "a thematic break directly under a heading fails" 1 $'# H\n---\n' 2 "a heading not followed by a blank line"
shape "an HTML comment directly under a heading fails" 1 $'# H\n<!-- x -->\n' 2 "a heading not followed by a blank line"
shape "a definition directly under a heading fails" 1 $'# H\n[a]: x\n' 2 "a heading not followed by a blank line"
shape "a blockquote directly under a heading fails" 1 $'# H\n> q\n' 2 "a heading not followed by a blank line"
shape "a paragraph leaving the quote a heading sits in fails" 1 $'> # H\nafter\n' 2 "a heading not followed by a blank line"
shape "a heading directly under a quoted paragraph fails" 1 $'> p\n# H\n' 2 "a heading not preceded by a blank line"
shape "a table directly under a fence closer fails" 1 $'```\nx\n```\n| a |\n|---|\n' 4 "a fence not followed by a blank line"
shape "a definition whose destination sits on the next line is a wrap" 1 $'[ref]:\n  http://x\n' 2 "a paragraph hard-wrapped over lines"
shape "a prompt-section opener sharing its line with prose is a paragraph line" 1 $'<delegation_format> Do it.\nwrapped\n' 2 "a paragraph hard-wrapped over lines"
shape "control: an HTML element's block still ends at the blank line" 1 $'<details>\nx\n\nwrapped\nlines\n</details>\n' 5 "a paragraph hard-wrapped over lines"
shape "control: a pipe line over prose is a wrap, not a table" 1 $'a | b\nc | d\n' 2 "a paragraph hard-wrapped over lines"
shape "control: a delimiter row under a line with no pipe is a wrap" 1 $'a\n--|--\n' 2 "a paragraph hard-wrapped over lines"
shape "a trailing double space fails" 1 $'Line one  \n\nLine two\n' 1 "a trailing-double-space line break"
shape "a hard wrap inside a blockquote fails" 1 $'> quoted\n> continued\n' 2 "a paragraph hard-wrapped over lines"
shape "a lazy continuation of a quoted paragraph fails" 1 $'> quoted\ncontinued\n' 2 "a paragraph hard-wrapped over lines"
shape "a CRLF line is the file's one violation" 1 $'Line one\r\nLine two\r\n' 1 "a CRLF line ending"
case "$OUT" in *"doc.md:2:"*) bad "a CRLF file is not judged past its first line" "$OUT" ;; *) ok "a CRLF file is not judged past its first line" ;; esac
case "$OUT" in *"remedies: reflow the file with md-reflow"*) ok "the remedy names md-reflow" ;; *) bad "remedy names md-reflow" "$OUT" ;; esac

echo "=== the shapes the rule skips stay quiet ==="
shape "a nested list item is an item, not a continuation" 0 $'- parent\n  - child\n    - grandchild\n- sibling\n'
shape "a multi-paragraph item after a blank line is a paragraph" 0 $'- item\n\n  second paragraph of the item\n'
shape "fenced code keeps its lines, tilde and backtick alike" 0 $'```\nwrapped\ntext\n# not a heading\n```\n\n~~~\nmore\nlines\n~~~\n'
shape "a longer fence closes only on a run at least as long" 0 $'````\n```\ninner\n```\n````\n'
shape "a table is not judged" 0 $'| a | b |\n|---|---|\n| c | d |\n'
shape "a table directly under a paragraph is a boundary, not a wrap" 0 $'Para\n| a | b |\n|---|---|\n'
shape "a table without outer pipes is a table" 0 $'a | b\n:--|--:\n1 | 2\n'
shape "a table runs to the next blank line, so a row without a pipe is a row" 0 $'| a |\n|---|\nrow\n\nPara\n'
shape "a prompt-section block is not judged, blank lines included, to its closing tag" 0 $'<output_format>\nwrapped\nlines\n\nSource: [S]\nIssue: [I]\n</output_format>\n'
shape "a prompt-section block indented under a list item is not judged" 0 $'1. step\n\n   <delegation_format>\n   Follow: x\n\n   Source: [S]\n   Issue: [I]\n   </delegation_format>\n'
shape "a quote directly under a paragraph is a boundary" 0 $'Para\n> q\n'
shape "an HTML block is not judged" 0 $'<details>\n<summary>x</summary>\nwrapped\nlines\n</details>\n'
shape "an HTML comment block is not judged" 0 $'<!--\nwrapped\nlines\n-->\n'
shape "a heading directly under a one-line HTML comment passes (the render marker shape)" 0 $'<!-- kendex:project-instructions:start -->\n## Project Instructions\n\n<!-- kendex:shared-instructions:start -->\nOne line.\n<!-- kendex:shared-instructions:end -->\n<!-- kendex:project-instructions:end -->\n'
shape "indented code after a blank line is not judged" 0 $'Para\n\n    code\n    more code\n'
shape "front matter is skipped" 0 $'---\ntitle: x\nwrapped: y\n---\n\nPara\n'
shape "a setext heading is a heading, not a wrap" 0 $'Heading\n=======\n\nPara\n\nSecond\n-------\n'
shape "reference definitions stack without blank lines" 0 $'Para\n\n[a]: https://x\n[b]: https://y\n'
shape "a thematic break is a boundary" 0 $'Para\n\n---\n\nPara\n'
shape "a blockquote paragraph on one line passes" 0 $'> one line\n\n> another\n'
shape "a `#hashtag` line is a paragraph, not a heading" 0 $'#tag one\n'
shape "a file without a trailing newline passes" 0 $'Para'

echo "=== a construct with no end is a collection error, not a pass ==="
shape "an unterminated fence is exit 2" 2 $'Para\n\n```\nnever closed\n'
case "$OUT" in *"doc.md:3: an unterminated fence"*) ok "the refusal names the file and line" ;; *) bad "refusal names file and line" "$OUT" ;; esac
shape "unterminated front matter is exit 2" 2 $'---\ntitle: x\n'
shape "a prompt-section block with no closing tag is exit 2" 2 $'Para\n\n<output_format>\nprose\n\nmore\n'
case "$OUT" in *"doc.md:3: a block with no closing </output_format>"*) ok "the refusal names the opener's line and tag" ;; *) bad "refusal names the opener" "$OUT" ;; esac

echo "=== scopes: --staged judges the files a commit touches, in full ==="
new_repo scopes
put clean.md $'Clean.\n'
put wrapped.md $'Wrapped\ntext.\n'
git -C "$R" commit -qm seed
run_mdf --staged
[ "$RC" -eq 0 ] && case "$OUT" in *"no staged markdown file(s) to judge"*) true ;; *) false ;; esac \
  && ok "with nothing staged, --staged judges nothing and says so" || bad "--staged with nothing staged" "rc=$RC out=$OUT"
printf 'Wrapped\ntext.\nMore.\n' >"$R/wrapped.md"
git -C "$R" add wrapped.md
run_mdf --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"wrapped.md:2:"*"wrapped.md:3:"*) true ;; *) false ;; esac \
  && ok "a touched file is judged in full: the committed wrap on line 2 fails beside the new line 3" \
  || bad "touched file judged in full" "rc=$RC out=$OUT"
printf 'Wrapped text. More.\n' >"$R/wrapped.md"
printf 'Wrapped\ntext.\n' >"$R/clean.md"
git -C "$R" add wrapped.md
run_mdf --staged
[ "$RC" -eq 0 ] && case "$OUT" in *"1 staged markdown file(s) clean"*) true ;; *) false ;; esac \
  && ok "control: the unstaged edit to clean.md is not judged, and the staged fix passes" \
  || bad "control: unstaged edit not judged" "rc=$RC out=$OUT"
git -C "$R" add clean.md
run_mdf --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"clean.md:2:"*) true ;; *) false ;; esac \
  && ok "once staged, the same edit fails" || bad "staged edit fails" "rc=$RC out=$OUT"
git -C "$R" commit -qm fix

echo "=== scopes: --all judges every tracked matching file ==="
run_mdf --all
[ "$RC" -eq 1 ] && case "$OUT" in *"clean.md:2:"*) true ;; *) false ;; esac \
  && ok "--all reaches the committed file no commit is touching" || bad "--all reaches committed files" "rc=$RC out=$OUT"
printf 'Clean.\n' >"$R/clean.md"
git -C "$R" add clean.md && git -C "$R" commit -qm clean
run_mdf --all
[ "$RC" -eq 0 ] && case "$OUT" in *"2 tracked markdown file(s) clean"*) true ;; *) false ;; esac \
  && ok "control: --all passes once every tracked file is clean, counting both" || bad "control: --all clean" "rc=$RC out=$OUT"

echo "=== scopes: with neither flag, COMMIT_GUARDS_MD_SCOPE decides ==="
run_mdf
[ "$RC" -eq 0 ] && case "$OUT" in *"nothing staged to judge"*"COMMIT_GUARDS_MD_SCOPE=all"*) true ;; *) false ;; esac \
  && ok "under the default touched scope with nothing staged, one line says so and how to widen" \
  || bad "touched scope with nothing staged" "rc=$RC out=$OUT"
printf 'Wrapped\nagain.\n' >"$R/clean.md"
git -C "$R" add clean.md
run_mdf
[ "$RC" -eq 1 ] && case "$OUT" in *"1 staged markdown file(s)"*) true ;; *) false ;; esac \
  && ok "under touched, a staged file is judged" || bad "touched judges the staged file" "rc=$RC out=$OUT"
git -C "$R" checkout -q -- clean.md 2>/dev/null || true
git -C "$R" reset -q --hard
printf 'Wrapped\ntext.\n' >"$R/committed.md"
git -C "$R" add committed.md && git -C "$R" commit -qm wrapped
run_mdf
[ "$RC" -eq 0 ] && ok "control: under touched, the committed wrap is out of scope" || bad "control: touched ignores committed files" "rc=$RC out=$OUT"
OUT="$(cd "$R" && COMMIT_GUARDS_MD_SCOPE=all "$MDF" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 1 ] && case "$OUT" in *"committed.md:2:"*) true ;; *) false ;; esac \
  && ok "COMMIT_GUARDS_MD_SCOPE=all is --all" || bad "scope=all is --all" "rc=$RC out=$OUT"
printf '[env]\nCOMMIT_GUARDS_MD_SCOPE = "all"\n' >"$R/kendex.settings.toml"
git -C "$R" add -A
run_mdf
[ "$RC" -eq 1 ] && case "$OUT" in *"committed.md:2:"*) true ;; *) false ;; esac \
  && ok "the scope resolves from kendex.settings.toml [env]" || bad "scope from settings" "rc=$RC out=$OUT"
rm "$R/kendex.settings.toml"
git -C "$R" add -A
OUT="$(cd "$R" && COMMIT_GUARDS_MD_SCOPE=sometimes "$MDF" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"must be 'touched' or 'all'"*) true ;; *) false ;; esac \
  && ok "an unknown scope is exit 2" || bad "unknown scope is exit 2" "rc=$RC out=$OUT"
run_mdf --staged --all
[ "$RC" -eq 2 ] && ok "--staged with --all is exit 2" || bad "--staged with --all is exit 2" "rc=$RC out=$OUT"

echo "=== the path list and the excludes list bound both scopes ==="
new_repo paths
put docs/wrapped.md $'Wrapped\ntext.\n'
put vendor/wrapped.md $'Wrapped\ntext.\n'
put notes.txt $'Wrapped\ntext.\n'
run_mdf --all
[ "$RC" -eq 1 ] && case "$OUT" in *"docs/wrapped.md:2:"*"vendor/wrapped.md:2:"*) true ;; *) false ;; esac \
  && ok "control: the default *.md reaches both markdown files and not the .txt" || bad "control: default path list" "rc=$RC out=$OUT"
case "$OUT" in *"notes.txt"*) bad "a non-markdown path is never judged" "$OUT" ;; *) ok "a non-markdown path is never judged" ;; esac
OUT="$(cd "$R" && COMMIT_GUARDS_MD_PATHS='docs/*.md' "$MDF" --all 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 1 ] && case "$OUT" in *"vendor/wrapped.md"*) false ;; *"docs/wrapped.md:2:"*) true ;; *) false ;; esac \
  && ok "COMMIT_GUARDS_MD_PATHS replaces the list" || bad "path list replaces" "rc=$RC out=$OUT"
mkdir -p "$R/tools"
printf 'vendor/*\tupstream docs, not ours\n' >"$R/tools/md-excludes"
git -C "$R" add -A
run_mdf --all
[ "$RC" -eq 1 ] && case "$OUT" in *"vendor/wrapped.md"*) false ;; *"docs/wrapped.md:2:"*) true ;; *) false ;; esac \
  && ok "tools/md-excludes drops the vendored tree from --all" || bad "excludes drop vendored tree" "rc=$RC out=$OUT"
run_mdf --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"vendor/wrapped.md"*) false ;; *"docs/wrapped.md:2:"*) true ;; *) false ;; esac \
  && ok "and from --staged" || bad "excludes drop vendored tree at commit" "rc=$RC out=$OUT"
printf 'vendor/*\tupstream docs, not ours\n!vendor/wrapped.md\tours after all\n' >"$R/tools/md-excludes"
git -C "$R" add -A
run_mdf --all
[ "$RC" -eq 1 ] && case "$OUT" in *"vendor/wrapped.md:2:"*) true ;; *) false ;; esac \
  && ok "a ! row carves a path back in" || bad "carve-in" "rc=$RC out=$OUT"
printf 'vendor/*\n' >"$R/tools/md-excludes"
git -C "$R" add -A
run_mdf --all
[ "$RC" -eq 2 ] && case "$OUT" in *"pattern<TAB>reason"*) true ;; *) false ;; esac \
  && ok "an exclusion without a reason is exit 2" || bad "reasonless exclusion is exit 2" "rc=$RC out=$OUT"
OUT="$(cd "$R" && COMMIT_GUARDS_MD_PATHS=' ' "$MDF" --all 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"names no path"*) true ;; *) false ;; esac \
  && ok "an empty path list is exit 2" || bad "empty path list is exit 2" "rc=$RC out=$OUT"
run_mdf --no-such-flag
[ "$RC" -eq 2 ] && ok "an unknown flag is exit 2" || bad "unknown flag is exit 2" "rc=$RC out=$OUT"
run_mdf --help
[ "$RC" -eq 0 ] && case "$OUT" in *"usage: md-format"*) true ;; *) false ;; esac \
  && ok "--help prints usage at exit 0" || bad "--help prints usage" "rc=$RC out=$OUT"

echo "=== a selected path that is not markdown is named, never counted clean ==="
new_repo unmeasurable
put notes/target.md $'Wrapped\ntext.\n'
put docs/link.md $'Clean.\n'
rm "$R/docs/link.md"
ln -s ../notes/target.md "$R/docs/link.md"
git -C "$R" add -A
OUT="$(cd "$R" && COMMIT_GUARDS_MD_PATHS='docs/*.md' "$MDF" --all 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"not measured: docs/link.md"*"tracked as a symlink"*"1 matched path(s) not measured"*) true ;; *) false ;; esac \
  && ok "a symlink at a selected path is named as unmeasured and counted apart" || bad "symlink named as unmeasured" "rc=$RC out=$OUT"
case "$OUT" in *"markdown file(s) clean"*) bad "no clean count covers the unread link" "$OUT" ;; *) ok "no clean count covers the unread link" ;; esac
OUT="$(cd "$R" && COMMIT_GUARDS_MD_PATHS='docs/*.md' "$MDF" --staged 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"not measured: docs/link.md"*) true ;; *) false ;; esac \
  && ok "the staged scope names the same link" || bad "staged scope names the link" "rc=$RC out=$OUT"
printf 'lead\000Wrapped\ntext.\n' >"$R/docs/bin.md"
git -C "$R" add -A
OUT="$(cd "$R" && COMMIT_GUARDS_MD_PATHS='docs/*.md' "$MDF" --all 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"not measured: docs/bin.md"*"binary content"*) true ;; *) false ;; esac \
  && ok "a binary blob at a selected path is named as unmeasured" || bad "binary blob named" "rc=$RC out=$OUT"

echo "=== the skill's own shipped markdown is in the format ==="
new_repo self
mkdir -p "$R/skills/commit-guards"
for doc in SKILL.md README.md CHECKS.md DEVELOPMENT.md; do
  cp "$SKILL_DIR/$doc" "$R/skills/commit-guards/$doc"
done
git -C "$R" add -A
run_mdf --all
[ "$RC" -eq 0 ] && case "$OUT" in *"4 tracked markdown file(s) clean"*) true ;; *) false ;; esac \
  && ok "SKILL.md, README.md, CHECKS.md and DEVELOPMENT.md pass" || bad "shipped docs pass" "rc=$RC out=$OUT"
put skills/commit-guards/wrapped.md $'Wrapped\ntext.\n'
run_mdf --all
[ "$RC" -eq 1 ] && ok "control: a planted wrap beside them fails" || bad "control: planted wrap fails" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
