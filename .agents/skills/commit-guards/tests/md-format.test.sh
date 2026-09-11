#!/usr/bin/env bash
# Pins for scripts/md-format, the judge of a markdown file's shape: one
# paragraph per line and one list item per line, blank lines between
# paragraphs, list blocks, headings and fences, no trailing-double-space
# break; fenced code, tables, HTML blocks, indented code and front matter
# left alone; the three scopes select the files the docs say; what cannot be
# judged is named rather than passed. Two tables: the first holds one shape
# as doc.md judged with --all, the second the scopes, the path list and the
# unmeasured paths. A row runs the judge once and pins the exit status with
# every line printed, so each violation's file, line and rule, the remedy,
# the count and the scope are one pin. The index readers this family shares
# are index-reads.test.sh and lane-readers.test.sh.
set -euo pipefail
# No globbing: a row's ARGS column is word-split into the judge's arguments.
set -f
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
MDF="$SKILL_DIR/scripts/md-format"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# Hermetic: a leaked setting would mask every row below.
unset COMMIT_GUARDS_MD_PATHS COMMIT_GUARDS_MD_EXCLUDES COMMIT_GUARDS_MD_SCOPE COMMIT_GUARDS_SETTINGS_FILE 2>/dev/null || true

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

# One line for a run in the row's repository: the exit status, then every
# stable record printed, in order, joined by ';'. ENVS is a comma-separated list of
# assignments; ARGS are passed through.
R=""
run() { # ENVS ARGS
  local envs=() rc=0 out=""
  [ -z "$1" ] || IFS=',' read -ra envs <<<"$1"
  # shellcheck disable=SC2086
  out="$(cd "$R" && env ${envs[@]+"${envs[@]}"} "$MDF" $2 2>&1)" || rc=$?
  out="$(printf '%s\n' "$out" | LC_ALL=C awk '/^[a-z][a-z-]*: [a-z-]+=/ { print }')"
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}

# Fixture vocabulary. Every fixture builds its own repository and stages
# what it wrote; a name used twice is refused.
repo() { # NAME
  R="$TMP/$1"
  [ ! -e "$R" ] || { echo "harness: fixture $1 already exists" >&2; exit 2; }
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}
put() { mkdir -p "$R/$(dirname "$1")"; printf '%b' "$2" >"$R/$1"; git -C "$R" add -A; } # PATH CONTENT (printf %b), staged
write() { mkdir -p "$R/$(dirname "$1")"; printf '%b' "$2" >"$R/$1"; } # PATH CONTENT — the work tree only
commit() { git -C "$R" commit -qm "$1"; }
WRAPPED='Wrapped\ntext.\n'

# Expected stable records keep file, line, rule, count and scope.
ERR="md-format: "
NOTHING_STAGED="md-format: staged-count=0"
WRAP="paragraph-wrap"
ITEM="item-wrap"
H_BEFORE="heading-before"
H_AFTER="heading-after"
F_AFTER="fence-after"
viol() { printf 'md-format: %s=%s:%s' "$3" "$1" "$2"; } # PATH LINE RULE
skip() { printf 'md-format: unmeasured=%s:%s' "$1" "$2"; } # PATH CODE
unmeasured() { printf '%s' "$1"; } # N
clean() { printf 'md-format: summary=violations=0 files=%s scope=%s skipped=%s' "$1" "${2:-all}" "${3:-0}"; } # N [SCOPE] [SKIPPED]
failed() { printf 'md-format: summary=violations=%s files=%s scope=%s skipped=%s' "$1" "$2" "${3:-all}" "${4:-0}"; } # VIOLATIONS N [SCOPE] [SKIPPED]
nomatch() { printf 'md-format: no-match=%s:%s' "$1" "$2"; } # SCOPE GLOBS
refused() { local rule="$2"; printf 'md-format: %s=doc.md:%s' "${rule%%:*}" "$1"; case "$rule" in *:*) printf ':%s' "${rule#*:}" ;; esac; } # LINE RULE
NONE="md-format: unmeasured-count="

# Table one: doc.md holds CONTENT in a fresh repository, judged with --all.
# The columns split on the pipe, so a pipe in the content is written as its
# octal escape, \174, which printf %b renders.
ROW=0
shape_rows() { # label | content | expect
  local row label content expect
  for row in "$@"; do
    IFS='|' read -r label content expect <<<"$row"
    ROW=$((ROW + 1))
    R=""
    repo "shape-$ROW"
    put doc.md "$content"
    assert_eq "$label" "$expect" "$(run '' --all)"
  done
}

echo "=== the rules fire on the shapes they name, once per line ==="
shape_rows \
  "one paragraph per line, blank-separated, passes, and the verdict counts the file|# Title\n\nOne paragraph on one line.\n\n- item one\n- item two\n\nAnother.\n|rc=0 $(clean 1)" \
  "a hard-wrapped paragraph fails on the continuation line, with the remedy|First line\nsecond line.\n|rc=1 $(viol doc.md 2 "$WRAP");$(failed 1 1)" \
  "a list item continued on the next line fails|- item\n  continued\n|rc=1 $(viol doc.md 2 "$ITEM");$(failed 1 1)" \
  "an ordered item continued on the next line fails|1. item\n   continued\n|rc=1 $(viol doc.md 2 "$ITEM");$(failed 1 1)" \
  "a heading directly under a paragraph fails|Para\n# Heading\n|rc=1 $(viol doc.md 2 "$H_BEFORE");$(failed 1 1)" \
  "a heading not followed by a blank line fails|# Heading\nPara\n|rc=1 $(viol doc.md 2 "$H_AFTER");$(failed 1 1)" \
  "a fence directly under a paragraph fails|Para\n\`\`\`\ncode\n\`\`\`\n|rc=1 $(viol doc.md 2 'fence-before');$(failed 1 1)" \
  "a fence closer not followed by a blank line fails|\`\`\`\ncode\n\`\`\`\nPara\n|rc=1 $(viol doc.md 4 "$F_AFTER");$(failed 1 1)" \
  "a list directly under a paragraph fails|Para\n- item\n|rc=1 $(viol doc.md 2 'list-before');$(failed 1 1)" \
  "a table directly under a heading fails|# H\n\174 a \174\n\174---\174\n|rc=1 $(viol doc.md 2 "$H_AFTER");$(failed 1 1)" \
  "a thematic break directly under a heading fails|# H\n---\n|rc=1 $(viol doc.md 2 "$H_AFTER");$(failed 1 1)" \
  "an HTML comment directly under a heading fails|# H\n<!-- x -->\n|rc=1 $(viol doc.md 2 "$H_AFTER");$(failed 1 1)" \
  "a definition directly under a heading fails|# H\n[a]: x\n|rc=1 $(viol doc.md 2 "$H_AFTER");$(failed 1 1)" \
  "a blockquote directly under a heading fails|# H\n> q\n|rc=1 $(viol doc.md 2 "$H_AFTER");$(failed 1 1)" \
  "a paragraph leaving the quote a heading sits in fails|> # H\nafter\n|rc=1 $(viol doc.md 2 "$H_AFTER");$(failed 1 1)" \
  "a heading directly under a quoted paragraph fails|> p\n# H\n|rc=1 $(viol doc.md 2 "$H_BEFORE");$(failed 1 1)" \
  "a table directly under a fence closer fails|\`\`\`\nx\n\`\`\`\n\174 a \174\n\174---\174\n|rc=1 $(viol doc.md 4 "$F_AFTER");$(failed 1 1)" \
  "a definition whose destination sits on the next line is a wrap|[ref]:\n  http://x\n|rc=1 $(viol doc.md 2 "$WRAP");$(failed 1 1)" \
  "a prompt-section opener sharing its line with prose is a paragraph line|<delegation_format> Do it.\nwrapped\n|rc=1 $(viol doc.md 2 "$WRAP");$(failed 1 1)" \
  "control: an HTML element's block still ends at the blank line|<details>\nx\n\nwrapped\nlines\n</details>\n|rc=1 $(viol doc.md 5 "$WRAP");$(failed 1 1)" \
  "control: a pipe line over prose is a wrap, not a table|a \174 b\nc \174 d\n|rc=1 $(viol doc.md 2 "$WRAP");$(failed 1 1)" \
  "control: a delimiter row under a line with no pipe is a wrap|a\n--\174--\n|rc=1 $(viol doc.md 2 "$WRAP");$(failed 1 1)" \
  "a trailing double space fails|Line one  \n\nLine two\n|rc=1 $(viol doc.md 1 'trailing-space');$(failed 1 1)" \
  "a trailing double space on a list item fails|- item  \n- next\n|rc=1 $(viol doc.md 1 'trailing-space');$(failed 1 1)" \
  "a hard wrap inside a blockquote fails|> quoted\n> continued\n|rc=1 $(viol doc.md 2 "$WRAP");$(failed 1 1)" \
  "a #hashtag line is a paragraph, not a heading: the line under it is its wrap|#tag one\nwrapped\n|rc=1 $(viol doc.md 2 "$WRAP");$(failed 1 1)" \
  "a lazy continuation of a quoted paragraph fails|> quoted\ncontinued\n|rc=1 $(viol doc.md 2 "$WRAP");$(failed 1 1)" \
  "a CRLF line is the file's one violation: nothing past its first line is judged|Line one\r\nLine two\r\n|rc=1 $(viol doc.md 1 'crlf');$(failed 1 1)" \
  "two wraps are two violations, each on its own line|One\ntwo\n\nThree\nfour\n|rc=1 $(viol doc.md 2 "$WRAP");$(viol doc.md 5 "$WRAP");$(failed 2 1)"

echo "=== the shapes the rule skips stay quiet ==="
shape_rows \
  "a nested list item is an item, not a continuation|- parent\n  - child\n    - grandchild\n- sibling\n|rc=0 $(clean 1)" \
  "a multi-paragraph item after a blank line is a paragraph|- item\n\n  second paragraph of the item\n|rc=0 $(clean 1)" \
  "fenced code keeps its lines, tilde and backtick alike|\`\`\`\nwrapped\ntext\n# not a heading\n\`\`\`\n\n~~~\nmore\nlines\n~~~\n|rc=0 $(clean 1)" \
  "a longer fence closes only on a run at least as long|\`\`\`\`\n\`\`\`\ninner\n\`\`\`\n\`\`\`\`\n|rc=0 $(clean 1)" \
  "a table is not judged|\174 a \174 b \174\n\174---\174---\174\n\174 c \174 d \174\n|rc=0 $(clean 1)" \
  "a table directly under a paragraph is a boundary, not a wrap|Para\n\174 a \174 b \174\n\174---\174---\174\n|rc=0 $(clean 1)" \
  "a table without outer pipes is a table|a \174 b\n:--\174--:\n1 \174 2\n|rc=0 $(clean 1)" \
  "a table runs to the next blank line, so a row without a pipe is a row|\174 a \174\n\174---\174\nrow\n\nPara\n|rc=0 $(clean 1)" \
  "a prompt-section block is not judged, blank lines included, to its closing tag|<output_format>\nwrapped\nlines\n\nSource: [S]\nIssue: [I]\n</output_format>\n|rc=0 $(clean 1)" \
  "a prompt-section block indented under a list item is not judged|1. step\n\n   <delegation_format>\n   Follow: x\n\n   Source: [S]\n   Issue: [I]\n   </delegation_format>\n|rc=0 $(clean 1)" \
  "a quote directly under a paragraph is a boundary|Para\n> q\n|rc=0 $(clean 1)" \
  "an HTML block is not judged|<details>\n<summary>x</summary>\nwrapped\nlines\n</details>\n|rc=0 $(clean 1)" \
  "an HTML comment block is not judged|<!--\nwrapped\nlines\n-->\n|rc=0 $(clean 1)" \
  "a heading directly under a one-line HTML comment passes (the render marker shape)|<!-- kendex:project-instructions:start -->\n## Project Instructions\n\n<!-- kendex:shared-instructions:start -->\nOne line.\n<!-- kendex:shared-instructions:end -->\n<!-- kendex:project-instructions:end -->\n|rc=0 $(clean 1)" \
  "indented code after a blank line is not judged|Para\n\n    code\n    more code\n|rc=0 $(clean 1)" \
  "front matter is skipped|---\ntitle: x\nwrapped: y\n---\n\nPara\n|rc=0 $(clean 1)" \
  "a setext heading is a heading, not a wrap|Heading\n=======\n\nPara\n\nSecond\n-------\n|rc=0 $(clean 1)" \
  "reference definitions stack without blank lines|Para\n\n[a]: https://x\n[b]: https://y\n|rc=0 $(clean 1)" \
  "a thematic break is a boundary|Para\n\n---\n\nPara\n|rc=0 $(clean 1)" \
  "a blockquote paragraph on one line passes|> one line\n\n> another\n|rc=0 $(clean 1)" \
  "a file without a trailing newline passes|Para|rc=0 $(clean 1)"

echo "=== a construct with no end is a collection error naming the opener, not a pass ==="
shape_rows \
  "fence-unclosed is exit 2, naming the file and line|Para\n\n\`\`\`\nnever closed\n|rc=2 $(refused 3 'fence-unclosed')" \
  "front-unclosed is exit 2|---\ntitle: x\n|rc=2 $(refused 1 'front-unclosed')" \
  "a prompt-section block with no closing tag is exit 2, naming the opener's line and tag|Para\n\n<output_format>\nprose\n\nmore\n|rc=2 $(refused 3 'block-unclosed:</output_format>')"

# Table two: FIXTURE (a function and its words) builds the repository; the
# judge runs with ARGS under ENVS.
run_rows() { # label | fixture | envs | args | expect
  local row label fx envs args expect words
  for row in "$@"; do
    IFS='|' read -r label fx envs args expect <<<"$row"
    R=""
    read -ra words <<<"$fx"
    "${words[@]}"
    assert_eq "$label" "$expect" "$(run "$envs" "$args")"
  done
}

echo "=== scopes: --staged judges the files a commit touches, in full ==="
seeded() { repo "$1"; put clean.md 'Clean.\n'; put wrapped.md "$WRAPPED"; commit seed; } # NAME — a committed wrap, nothing staged
# Two commits, so HEAD~1 names one and a row can spell two different refs
# under one flag name. Its own fixture: the counts every --all row asserts are
# the shared one's, and a file added there would move them.
two_commits() { repo "$1"; put first.md 'First.\n'; commit first; put second.md 'Second.\n'; commit second; } # NAME
fx_touched_full() { seeded touched-full; put wrapped.md 'Wrapped\ntext.\nMore.\n'; }
fx_unstaged_edit() { seeded unstaged-edit; put wrapped.md 'Wrapped text. More.\n'; write clean.md "$WRAPPED"; }
fx_staged_edit() { seeded staged-edit; put wrapped.md 'Wrapped text. More.\n'; put clean.md "$WRAPPED"; }
fx_committed_wrap() { seeded committed-wrap; put wrapped.md 'Wrapped text. More.\n'; put clean.md "$WRAPPED"; commit fix; } # both committed, clean.md wrapped
fx_all_clean() { seeded all-clean; put wrapped.md 'Wrapped text. More.\n'; commit fix; }
fx_touched_staged() { seeded touched-staged; put clean.md 'Wrapped\nagain.\n'; }
# The deletion row's verdict is the no-match line: a deletion that never
# happened reads the same. What the row guards is the staged walk's
# --diff-filter=AMT, which a D would turn into a read of a null sha.
fx_deletion() { seeded deletion; git -C "$R" rm -q clean.md; }
fx_settings_all() { seeded settings-all; put kendex.settings.toml '[env]\nCOMMIT_GUARDS_MD_SCOPE = "all"\n'; }
run_rows \
  "with nothing staged, --staged judges nothing and says so, naming the path list|seeded staged-nothing||--staged|rc=0 $(nomatch staged '*.md')" \
  "a touched file is judged in full: the committed wrap on line 2 fails beside the new line 3|fx_touched_full||--staged|rc=1 $(viol wrapped.md 2 "$WRAP");$(viol wrapped.md 3 "$WRAP");$(failed 2 1 staged)" \
  "control: the unstaged edit to clean.md is not judged, and the staged fix passes|fx_unstaged_edit||--staged|rc=0 $(clean 1 staged)" \
  "once staged, the same edit fails, with both staged files counted|fx_staged_edit||--staged|rc=1 $(viol clean.md 2 "$WRAP");$(failed 1 2 staged)" \
  "a staged deletion is no file to judge|fx_deletion||--staged|rc=0 $(nomatch staged '*.md')" \
  "--all reaches the committed file no commit is touching|fx_committed_wrap||--all|rc=1 $(viol clean.md 2 "$WRAP");$(failed 1 2)" \
  "control: --all passes once every tracked file is clean, counting both|fx_all_clean||--all|rc=0 $(clean 2)" \
  "under the default touched scope with nothing staged, one line says so and how to widen|seeded touched-nothing|||rc=0 $NOTHING_STAGED" \
  "under touched, a staged file is judged|fx_touched_staged|||rc=1 $(viol clean.md 2 "$WRAP");$(failed 1 1 staged)" \
  "control: under touched, the committed wrap is out of scope|seeded touched-committed|||rc=0 $NOTHING_STAGED" \
  "COMMIT_GUARDS_MD_SCOPE=all is --all|seeded env-all|COMMIT_GUARDS_MD_SCOPE=all||rc=1 $(viol wrapped.md 2 "$WRAP");$(failed 1 2)" \
  "the scope resolves from kendex.settings.toml [env]|fx_settings_all|||rc=1 $(viol wrapped.md 2 "$WRAP");$(failed 1 2)" \
  "an unknown scope is exit 2, quoting it|seeded scope-unknown|COMMIT_GUARDS_MD_SCOPE=sometimes||rc=2 ${ERR}scope=sometimes" \
  "--staged with --all is exit 2|seeded both-flags||--staged --all|rc=2 ${ERR}scope-flags=--staged,--all" \
  "two range flags name two scopes, so the contradiction is refused rather than resolved to the last one|seeded two-ranges||--base HEAD --against HEAD|rc=2 ${ERR}scope-flags=--base HEAD,--against HEAD" \
  "one flag naming two refs is the same contradiction|two_commits two-refs||--base HEAD --base HEAD~1|rc=2 ${ERR}scope-flags=--base HEAD,--base HEAD~1" \
  "a range beside --all is refused too, whichever came first|seeded range-and-all||--all --base HEAD|rc=2 ${ERR}scope-flags=--all,--base HEAD" \
  "control: a flag repeated verbatim names one scope and runs|seeded repeat-range||--base HEAD --base HEAD|rc=0 $(nomatch range '*.md')" \
  "control: one range flag alone reaches the range scope|seeded one-range||--base HEAD|rc=0 $(nomatch range '*.md')"

echo "=== the path list and the excludes list bound both scopes ==="
paths() { repo "$1"; put docs/wrapped.md "$WRAPPED"; put vendor/wrapped.md "$WRAPPED"; put notes.txt "$WRAPPED"; } # NAME — two wrapped markdown files and a .txt
fx_excluded() { paths "$1"; put tools/md-excludes 'vendor/*\tupstream docs, not ours\n'; }
fx_carved() { paths carved; put tools/md-excludes 'vendor/*\tupstream docs, not ours\n!vendor/wrapped.md\tours after all\n'; }
fx_reasonless() { paths reasonless; put tools/md-excludes 'vendor/*\n'; }
run_rows \
  "control: the default *.md reaches both markdown files and never the .txt|paths default||--all|rc=1 $(viol docs/wrapped.md 2 "$WRAP");$(viol vendor/wrapped.md 2 "$WRAP");$(failed 2 2)" \
  "COMMIT_GUARDS_MD_PATHS replaces the list|paths replaced|COMMIT_GUARDS_MD_PATHS=docs/*.md|--all|rc=1 $(viol docs/wrapped.md 2 "$WRAP");$(failed 1 1)" \
  "tools/md-excludes drops the vendored tree from --all|fx_excluded excluded-all||--all|rc=1 $(viol docs/wrapped.md 2 "$WRAP");$(failed 1 1)" \
  "and from --staged|fx_excluded excluded-staged||--staged|rc=1 $(viol docs/wrapped.md 2 "$WRAP");$(failed 1 1 staged)" \
  "a ! row carves a path back in|fx_carved||--all|rc=1 $(viol docs/wrapped.md 2 "$WRAP");$(viol vendor/wrapped.md 2 "$WRAP");$(failed 2 2)" \
  "an exclusion without a reason is exit 2, naming the row|fx_reasonless||--all|rc=2 ${ERR}exclusion-reason=tools/md-excludes:1" \
  "an empty path list is exit 2|paths empty-list|COMMIT_GUARDS_MD_PATHS= |--all|rc=2 ${ERR}glob-empty=COMMIT_GUARDS_MD_PATHS" \
  "an unknown flag is exit 2, quoting it|paths unknown-flag||--no-such-flag|rc=2 ${ERR}argument=--no-such-flag"
# The usage text carries a '|', which a row cannot: its first line and the
# exit status, beside the table.
assert_eq "--help prints usage at exit 0" "rc=0 md-format: usage=md-format" "$(run '' --help | sed -n 1p | LC_ALL=C cut -d';' -f1)"

echo "=== a selected path that is not markdown is named, never counted clean ==="
fx_symlink() { repo "$1"; put notes/target.md "$WRAPPED"; mkdir -p "$R/docs"; ln -s ../notes/target.md "$R/docs/link.md"; git -C "$R" add -A; }
fx_symlink_and_binary() { fx_symlink symlink-binary; put docs/bin.md 'lead\0000Wrapped\ntext.\n'; }
run_rows \
  "a symlink at a selected path is named as unmeasured and counted apart, with no clean count|fx_symlink symlink-all|COMMIT_GUARDS_MD_PATHS=docs/*.md|--all|rc=0 $(skip docs/link.md symlink);$NONE$(unmeasured 1)" \
  "the staged scope names the same link|fx_symlink symlink-staged|COMMIT_GUARDS_MD_PATHS=docs/*.md|--staged|rc=0 $(skip docs/link.md symlink);$NONE$(unmeasured 1)" \
  "a binary blob at a selected path is named as unmeasured, in index order beside the link|fx_symlink_and_binary|COMMIT_GUARDS_MD_PATHS=docs/*.md|--all|rc=0 $(skip docs/bin.md binary);$(skip docs/link.md symlink);$NONE$(unmeasured 2)"

echo "=== the skill's own shipped markdown is in the format ==="
fx_shipped() { # NAME — the four shipped documents
  local doc
  repo "$1"
  mkdir -p "$R/skills/commit-guards"
  for doc in SKILL.md README.md CHECKS.md DEVELOPMENT.md; do
    cp "$SKILL_DIR/$doc" "$R/skills/commit-guards/$doc"
  done
  git -C "$R" add -A
}
fx_shipped_planted() { fx_shipped shipped-planted; put skills/commit-guards/wrapped.md "$WRAPPED"; }
run_rows \
  "SKILL.md, README.md, CHECKS.md and DEVELOPMENT.md pass|fx_shipped shipped||--all|rc=0 $(clean 4)" \
  "control: a planted wrap beside them fails, counted with them|fx_shipped_planted||--all|rc=1 $(viol skills/commit-guards/wrapped.md 2 "$WRAP");$(failed 1 5)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
