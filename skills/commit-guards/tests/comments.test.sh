#!/usr/bin/env bash
# Pins for scripts/lib/comment-text.sh, the comment extractor md-refs reads:
# the grammar a path takes, and the comment text it yields under that
# grammar. Only comment text is a record, never a string literal or code;
# each extraction limit CHECKS.md states for the extractor holds exactly as
# stated;
# a construct the reader cannot follow is a refusal naming it, never a
# record set read to the end of the file. One table: a row writes one file
# from its own content and reads back the records that carry the planted
# word, as line:text, or the extractor's refusal.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# shellcheck source=../scripts/lib/common.sh
. "$SKILL_DIR/scripts/lib/common.sh"
# shellcheck source=../scripts/lib/comment-text.sh
. "$SKILL_DIR/scripts/lib/comment-text.sh"
GG_TMP="$TMP/gg"
mkdir -p "$GG_TMP"
# The planted word each row looks for, and a second token for the rows that
# put several reference shapes in one string.
W="ABC-123"
D="2026-08-12"

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

# The extraction of one file at PATH: `hits=` and the records carrying the
# planted word, as line:text joined by ';', or `error=` and the reason the
# extractor refused. The file lives under the scratch root; PATH is the name
# the grammar is chosen by.
extract_file() { # PATH FILE
  local fam
  fam="$(gg_comment_family "$1" "$2")"
  [ -n "$fam" ] || { printf 'family=none'; return 0; }
  if gg_comment_text "$fam" "$2" "$1" >"$TMP/text"; then
    printf 'hits=%s' "$(W="$W" LC_ALL=C awk -F '\t' 'index($2, ENVIRON["W"]) { printf "%s%s:%s", (n++ ? ";" : ""), $1, $2 }' "$TMP/text")"
  else
    printf 'error=%s' "$GG_COMMENT_ERROR"
  fi
}

# The table: label | path | content | expect. CONTENT goes through printf %b.
run_files() {
  local row label path content expect
  for row in "$@"; do
    IFS='|' read -r label path content expect <<<"$row"
    [ -n "$expect" ] || { echo "harness: row has fewer than four fields: $row" >&2; exit 2; }
    printf '%b' "$content" >"$TMP/blob"
    assert_eq "$label" "$expect" "$(extract_file "$path" "$TMP/blob")"
  done
}

echo "=== only comment text is judged: strings and code never fire ==="
run_files \
  "every shape inside a string literal passes|a.rs|let s = \"http://x/#228 $W $D\";\n|hits=" \
  "a // inside a string literal is not a comment|a.rs|let s = \"// $W\";\n|hits=" \
  "control: a comment after code on the same line is judged|a.rs|let x = 1; // $W\n|hits=1: $W" \
  "control: a comment after a string that holds a leader is still judged|a.rs|let s = \"//\"; // $W\n|hits=1: $W" \
  "a block comment is judged, its text the span between the markers|a.rs|/* $W */ fn main() {}\n|hits=1: $W " \
  "a block comment spanning lines reports the line the reference sits on, whole|a.rs|/* first line\n second line $W\n third */\n|hits=2: second line $W" \
  "doc-comment forms are judged like any other comment, their third marker stripped|a.rs|/// $W\n//! $W\nfn main() {}\n|hits=1: $W;2: $W" \
  "code with a name that contains an ordinary word passes|a.rs|let p = previously_seen(); let n = new_value; // clean\n|hits="

echo "=== Rust: lifetimes, char literals, raw and multi-line strings ==="
run_files \
  "a lifetime quote opens no string, so the comment after it is still seen|a.rs|fn f<'a>(x: &'a str) -> &'a str { x } // $W\n|hits=1: $W" \
  "a char literal holding a double quote opens no string|a.rs|let q = '\"'; let n = '\\\\n'; // $W\n|hits=1: $W" \
  "a raw string with an inner quote and a leader is one string, closed only by its hash|a.rs|let r = r#\"say \"hi // $W\"#;\n|hits=" \
  "control: the comment after that raw string is judged|a.rs|let r = r#\"say \"hi\"#; // $W\n|hits=1: $W" \
  "a string continued across lines by a trailing backslash is one string|a.rs|let s = \"line one \\\\\n  // $W \\\\\n  line three\";\n|hits=" \
  "a Rust string spanning lines without a backslash is one string too|a.rs|let s = \"line one\n  // $W\n  line three\";\n|hits=" \
  "control: the comment after a multi-line string is judged|a.rs|let s = \"line one\n  line two\";\n// $W\n|hits=3: $W"

echo "=== JavaScript: template literals and single quotes ==="
run_files \
  "a template literal spanning lines is one string|a.ts|const t = \`line one\n  // $W\n  line three\`;\n|hits=" \
  "control: the comment after a template literal is judged|a.ts|const t = \`x\`;\n// $W\n|hits=2: $W" \
  "a single-quoted string holding a leader is a string|a.ts|const s = '// $W';\n|hits=" \
  "control: a JavaScript trailing comment is judged|a.ts|const s = \"a\"; // $W\n|hits=1: $W" \
  "a leading if regex keeps backticks and quotes out of later comment state|a.js|  if (/^[\`\`\`\"']/.test(s)) {}\n// \`value\` doesn't change $W\n|hits=2: \`value\` doesn't change $W" \
  "class slashes and comment leaders stay regex data until the real closer|a.ts|if(/[\"'\`//*]/.test(s)) {} // $W\n|hits=1: $W" \
  "escaped slash and closing bracket cannot end the regex or its class|a.ts|if (/\\\\/\\\\\`[\\\\]/\"']/.test(s)) {} // $W\n|hits=1: $W" \
  "a regex closes before a genuine string and its following comment|a.js|if (/x/.test(s)) { const t = \`// $W\`; const q = '// $W'; } // $W\n|hits=1: $W" \
  "division in an if condition keeps the trailing comment|a.ts|if (total / count > 1) {} // $W\n|hits=1: $W" \
  "pure line-comment apostrophes and backticks never open strings|a.js|// \`value\` doesn't change $W\n|hits=1: \`value\` doesn't change $W" \
  "Go raw strings and division keep their existing boundaries|a.go|var s = \`if (/\n// $W\n\`\nif (total / count > 1) {} // $W\n|hits=4: $W" \
  "an identifier ending in if does not admit a regex|a.js|diff(/\`/);\n// $W\n|error=unclosed-string:1" \
  "a method named if does not admit a regex|a.js|obj.if(/\`/);\n// $W\n|error=unclosed-string:1" \
  "a regex with no same-line closer stays unjudged even if a later slash exists|a.ts|if (/x\n/); // $W\n|error=unclosed-regex:1" \
  "an escaped final slash is not a regex closer|a.ts|if (/x\\\\/\n// $W\n|error=unclosed-regex:1" \
  "a slash inside an unclosed class is not a regex closer|a.ts|if (/[x/\n// $W\n|error=unclosed-regex:1"

echo "=== hash family: word-start hashes, strings, shebang, heredocs ==="
run_files \
  "a hash inside a string is not a comment|a.sh|printf '%s' \"# $W\"\n|hits=" \
  "a hash glued to a word is not a comment|a.sh|echo \$# \${x#$W} url#$W\n|hits=" \
  "control: a hash after whitespace opens a comment|a.sh|foo # $W\n|hits=1: $W" \
  "a shebang is not a comment; the line after it is|a.sh|#!/bin/bash $W\n# $W\n|hits=2: $W" \
  "only line 1 is a shebang: a second #! line is a comment|a.sh|#!/bin/bash\n#!second $W\n|hits=2:!second $W" \
  "a backslash in a single-quoted shell string escapes nothing|a.sh|echo 'a\\\\' # $W\n|hits=1: $W" \
  "a backslash in \$'...' does escape, so the comment after the string is judged|a.sh|echo \$'a\\\\'b' # $W\n|hits=1: $W" \
  "a backslash in a double-quoted shell string escapes its quote, so the comment after the string is judged|a.sh|echo \"a\\\\\"b\" # $W\n|hits=1: $W" \
  "a backslash outside a string quotes the next character, so the escaped quote between two closed strings opens nothing|a.sh|echo 'it'\\\\''s' # $W\n|hits=1: $W" \
  "a heredoc body is not judged; the line after its terminator is|a.sh|cat <<EOF\n# $W\nEOF\n# $W\n|hits=4: $W" \
  "a quoted <<- heredoc ends at its tab-indented terminator|a.sh|cat <<-'EOF'\n\t# $W\n\tEOF\n# $W\n|hits=4: $W" \
  "a plain << heredoc is not ended by a tab-indented terminator: it never closes|a.sh|cat <<EOF\n# $W\n\tEOF\n# $W\n|error=unclosed-heredoc:1:EOF" \
  "an unquoted heredoc word stops at an operator|a.sh|cat <<EOF;echo\n# $W\nEOF\n# $W\n|hits=4: $W" \
  "a backslash-quoted heredoc word loses its backslash|a.sh|cat <<\\\\EOF\n# $W\nEOF\n# $W\n|hits=4: $W" \
  "a shift is not a heredoc|a.sh|x=\$((1<<2)) # $W\n|hits=1: $W" \
  "a shift by a name inside ((...)) opens no heredoc, so the next line is judged|a.sh|x=\$(( 1 << n ))\n# $W\n|hits=2: $W" \
  "a heredoc word is taken whole, so END-OF terminates the body|a.sh|cat <<END-OF\n# $W\nEND-OF\n# $W\n|hits=4: $W" \
  "a here-string is not a heredoc|a.sh|read -r x <<<\"y\" # $W\n|hits=1: $W" \
  "a quote inside a quoted command substitution does not hide the following comment|a.sh|out=\"\$(printf '\"')\"\n# $W\n|hits=2: $W" \
  "a comment inside a quoted command substitution is judged as shell code|a.sh|out=\"\$(\n# $W\nprintf ok\n)\"\n|hits=2: $W" \
  "a quoted command substitution stays extractable when its comments are clean|a.sh|out=\"\$(printf '\"$W\"')\"\n|hits=" \
  "a quoted command substitution never closed is reported at its opener|a.sh|out=\"\$(\n# $W\n|error=unclosed-substitution:1" \
  "a heredoc token inside an embedded heredoc does not hide the following comment|a.sh|out=\"\$(python3 - <<'PY'\nprint(\"<<'MANIFEST_EOF'\")\nPY\n)\"\n# $W\n|hits=5: $W" \
  "a heredoc in a quoted command substitution stays extractable when its comments are clean|a.sh|out=\"\$(python3 - <<'PY'\nprint(\"<<'MANIFEST_EOF' $W\")\nPY\n)\"\n|hits=" \
  "a triple-quoted Python string is one string|a.py|\"\"\"\n# $W\n\"\"\"\n# $W\n|hits=4: $W" \
  "TOML: a hash in a string is not a comment, one after a value is|a.toml|key = \"a # $W\"\nother = 1 # $W\n|hits=2: $W" \
  "TOML: a triple-quoted string spans lines|a.toml|key = \"\"\"\n# $W\n\"\"\"\n# $W\n|hits=4: $W" \
  "Ruby: a backslash escapes inside single quotes, so the comment after the string is judged|a.rb|s = 'don\\\\'t' # $W\n|hits=1: $W" \
  "YAML: a doubled quote ends nothing, and the trailing comment is judged|a.yml|key: 'don''t' # $W\n|hits=1: $W" \
  "a Makefile is judged by its basename|Makefile|all: # $W\n|hits=1: $W" \
  "a nested Dockerfile is judged by its basename|sub/Dockerfile|# $W\n|hits=1: $W"
# A row cannot carry a `|`; the contents that do are files here.
printf '%b' "cat <<\"END-OF\" | sort\n# $W\nEND-OF\n# $W\n" >"$TMP/pipe-heredoc.sh"
printf '%b' "key: |\n  # $W\n" >"$TMP/pipe-yaml.yml"
# An escaped quote in a case pattern and an escaped double quote in a
# `[[ =~ ]]` regex, each followed by a comment that must be judged; the lines
# are taken from a consumer's bin/check-scans.sh.
cat >"$TMP/escaped-case.sh" <<'SH'
case $sm_c in
  \'|\") sm_q=$sm_c; sm_keep+=' '; sm_fresh=0;;
esac
SH
printf '# %s\n' "$W" >>"$TMP/escaped-case.sh"
cat >"$TMP/escaped-regex.sh" <<'SH'
          if [ "$rc" != 0 ]; then
            [ "$want" = REFUSAL ] || out="$out$f:$((i + 1)): $word: the keyed line cannot be read, so whether it carries fix= is unjudged
"
          elif [[ $arg != *fix=* && ! $arg =~ ^\"?\$([A-Za-z_][A-Za-z0-9_]*|[0-9@*]|\{[^}]*\})\"?$ && -n $arg ]]; then
            out="$out$f:$((i + 1)): $word: the refusal carries no fix=
"
          fi
SH
printf '# %s\n' "$W" >>"$TMP/escaped-regex.sh"
assert_eq "a quoted heredoc word is stripped of its quotes and stops before the pipe" \
  "hits=4: $W" "$(extract_file a.sh "$TMP/pipe-heredoc.sh")"
assert_eq "a YAML block scalar is read as code (stated limit)" \
  "hits=2: $W" "$(extract_file a.yml "$TMP/pipe-yaml.yml")"
assert_eq "an escaped quote in a case pattern opens nothing, so the comment after the case is judged" \
  "hits=4: $W" "$(extract_file a.sh "$TMP/escaped-case.sh")"
assert_eq "an escaped double quote in a [[ =~ ]] regex opens nothing, so the comment after the test is judged" \
  "hits=8: $W" "$(extract_file a.sh "$TMP/escaped-regex.sh")"
for fx in escaped-case escaped-regex; do
  assert_eq "fixture: the $fx shape is valid Bash" "0" "$(bash -n "$TMP/$fx.sh" 2>&1; echo $?)"
done
# The three quoted-substitution fixtures above are valid Bash; the extractor
# is held to shapes the shell accepts.
for content in "out=\"\$(printf '\"')\"\n# $W\n" "out=\"\$(\n# $W\nprintf ok\n)\"\n" "out=\"\$(python3 - <<'PY'\nprint(\"<<'MANIFEST_EOF'\")\nPY\n)\"\n# $W\n"; do
  printf '%b' "$content" >"$TMP/valid.sh"
  assert_eq "fixture: the quoted command substitution is valid Bash" "0" "$(bash -n "$TMP/valid.sh" 2>&1; echo $?)"
done

echo "=== SQL, Lua, markup, CSS ==="
run_files \
  "SQL: a leader inside a string is a string, the trailing comment is judged, one hit|a.sql|SELECT '-- $W'; -- $W\n|hits=1: $W" \
  "SQL: a block comment is judged|a.sql|/* $W */ SELECT 1;\n|hits=1: $W " \
  "Lua: a block comment is judged|a.lua|--[[ $W\n]] x = 1\n|hits=1: $W" \
  "markup: text is not judged, a comment is|a.html|<p>$W</p>\n<!-- $W -->\n|hits=2: $W " \
  "a markup comment spanning lines reports the line the reference sits on|a.svelte|<!-- first\n $W -->\n|hits=2: $W " \
  "CSS: a URL's slashes open no comment|a.css|a { background: url(http://x/$W) } /* clean */\n|hits=" \
  "control: a CSS block comment is judged|a.css|a { color: red } /* $W */\n|hits=1: $W "

echo "=== every limit CHECKS.md states holds exactly as stated ==="
run_files \
  "a regex literal's escaped slash before its closer reads as a leader (stated limit): the comment text starts there|a.js|const re = /https?:\\\\/\\\\// ; // $W\n|hits=1: ; // $W" \
  "a // inside a regex literal opens a comment (stated limit)|a.js|const re = /x\\\\/\\\\/y/; const t = /a// $W\n|hits=1: $W" \
  "a hash glued to a Python value is read as code (stated limit)|a.py|x = 1#$W\n|hits=" \
  "a -- inside a Lua long string is read as a comment (stated limit)|a.lua|s = [[ --$W ]]\n|hits=1:$W ]]" \
  "a nested Rust block comment closes at the first */, so the tail is read as code (stated limit)|a.rs|/* outer /* inner */ $W */\n|hits=" \
  "a levelled Lua block opener is read as a -- line comment, judged on its own line|a.lua|--[==[ $W\n]==] x = 1\n|hits=1:[==[ $W" \
  "a comment after an unparenthesised case pattern inside a quoted \$(...) is read as string text (stated limit)|a.sh|x=\"\$(case \$y in\n  a) # $W\n     echo hi;;\nesac)\"\n|hits=" \
  "control: the same comment after a parenthesised pattern is judged|a.sh|x=\"\$(case \$y in\n  (a) # $W\n     echo hi;;\nesac)\"\n|hits=2: $W" \
  "a line opening two heredocs honours the first: the body after its terminator is judged (stated limit)|a.sh|cat <<A <<B\n# $W\nA\n# $W\nB\n# $W\n|hits=4: $W;6: $W" \
  "a Ruby heredoc body is read as code, so its hash is a comment (stated limit)|a.rb|s = <<~EOS\n# $W\nEOS\n|hits=2: $W" \
  "a Makefile recipe's shell is read under the hash grammar with its strings tracked (stated limit)|Makefile|all:\n\techo '# $W'\n|hits=" \
  "and a hash glued to a dollar is not a comment there either|Makefile|all:\n\techo \$# $W\n|hits=" \
  "a Vue script block's // is not read (stated limit)|a.vue|<script>// $W</script>\n|hits=" \
  "control: the markup comment in the same file is judged|a.vue|<template><!-- $W --></template>\n|hits=1: $W " \
  "a C string ends at its line, so the continued line's // is a comment (stated limit)|a.c|char *s = \"one \\\\\n  // $W\n  three\";\n|hits=2: $W"

echo "=== an unextractable file is refused naming its opener; a path with no grammar is not guessed at ==="
run_files \
  "a block comment never closed is reported with its opener, not read to the end as one comment|a.c|int x;\n/* open\nint y; // $W\n|error=unclosed-block:2" \
  "a heredoc never terminated is reported, naming its word|a.sh|cat <<EOF\nbody\n# $W\n|error=unclosed-heredoc:1:EOF" \
  "control: a string that does close is a string, and the comment after it is judged|a.rs|let s = \"spans\nlines\";\n// $W\n|hits=3: $W" \
  "a regex literal holding a backtick opens a template literal that never closes (stated limit)|a.ts|const re = /\`/g;\n// $W\n|error=unclosed-string:1" \
  "an extensionless file is read under the grammar its shebang picks|run|#!/usr/bin/env bash\n# $W\n|hits=2: $W" \
  "a python shebang picks the python grammar, where a backslash escapes inside single quotes|run|#!/usr/bin/env python3\ns = 'don\\\\'t' # $W\n|hits=2: $W" \
  "a node shebang picks the C family with template literals|run|#!/usr/bin/env node\n// $W\n|hits=2: $W" \
  "a first line naming a shell without #! is not a shebang|run|# start with bash\n# $W\n|family=none" \
  "the same file with no shebang has no grammar|run|# $W\necho hi\n|family=none" \
  "an extension the table does not carry has no grammar|notes.txt|# $W\n|family=none"
# The refusal's explanation opens with the reader's cause, which names the
# opener's line; an opener past line 1 proves the number is the opener's.
printf '%b' "true\necho 'open\n# $W\n" >"$TMP/cause.sh"
CAUSE="$(gg_comment_text hash-shell "$TMP/cause.sh" a.sh >/dev/null || printf '%s\n' "$GG_COMMENT_ERROR_DETAIL")"
assert_eq "an unclosed quote's refusal names the reader's cause and the opener's line" \
  "comment-reader:unclosed-string line=2" "${CAUSE%%$'\n'*}"
# A shebang read that fails is a collection error, never a path with no
# grammar.
mkdir -p "$TMP/shim"
printf '#!/bin/sh\ncase "$1" in -n) echo "dependency-order-control: shebang-read" >&2; exit 1 ;; esac\nexec %s "$@"\n' "$(command -v head)" >"$TMP/shim/head"
chmod +x "$TMP/shim/head"
printf '#!/usr/bin/env bash\n# %s\n' "$W" >"$TMP/run"
shebang_read() {
  local rc=0 out
  out="$(PATH="$TMP/shim:$PATH" gg_comment_family run "$TMP/run" 2>&1)" || rc=$?
  printf 'rc=%s %s' "$rc" "$(printf '%s\n' "$out" | LC_ALL=C awk '
    /^[a-z-]+: [a-z-]+=/ { print; next }
    /^[[:space:]]*dependency-order-control:/ { sub(/^[[:space:]]*/, ""); print }
  ' | LC_ALL=C paste -sd ';' -)"
}
assert_eq "a shebang read failure puts the stable record before head's cause" \
  "rc=2 commit-guards: shebang-read=run;dependency-order-control: shebang-read" "$(shebang_read)"

echo "=== each default extension is read under its family, and the default source list carries it; markdown and JSON have no grammar ==="
rows=()
for f in a.rs a.go a.c a.h a.cc a.cpp a.hpp a.java a.kt a.kts a.swift a.wgsl a.js a.mjs a.cjs a.jsx a.ts a.tsx a.scss a.less; do
  rows+=("$f is read under the C family|$f|// $W\n# $W\n-- $W\n|hits=1: $W")
done
for f in a.sh a.bash a.zsh a.py a.rb a.toml a.yml a.yaml deep/a.mk sub/Makefile sub/Dockerfile; do
  rows+=("$f is read under the hash family|$f|// $W\n# $W\n-- $W\n|hits=2: $W")
done
for f in a.sql a.lua; do
  rows+=("$f is read under the dash family|$f|// $W\n# $W\n-- $W\n|hits=3: $W")
done
for f in a.html a.htm a.xml a.svg a.vue a.svelte; do
  rows+=("$f is read under the markup family|$f|// $W\n# $W\n<!-- $W -->\n|hits=3: $W ")
done
rows+=("a.css is read under the block family|a.css|// $W\n# $W\n/* $W */\n|hits=3: $W ")
for f in README.md AGENTS.md a.json; do
  rows+=("$f has no comment grammar|$f|<!-- $W -->\n|family=none")
done
run_files "${rows[@]}"
# md-refs reads GG_COMMENT_PATHS_DEFAULT as its default source list, so every
# path the table gives a grammar is one that list selects.
in_default() ( # PATH — yes when a default glob matches it
  set -f
  for g in $GG_COMMENT_PATHS_DEFAULT; do
    # shellcheck disable=SC2254
    case "$1" in $g) printf yes; exit 0 ;; esac
  done
  printf no
)
for f in a.rs a.go a.c a.h a.cc a.cpp a.hpp a.java a.kt a.kts a.swift a.wgsl a.js a.mjs a.cjs a.jsx a.ts a.tsx a.scss a.less \
  a.sh a.bash a.zsh a.py a.rb a.toml a.yml a.yaml deep/a.mk sub/Makefile sub/Dockerfile a.sql a.lua \
  a.html a.htm a.xml a.svg a.vue a.svelte a.css; do
  assert_eq "$f is in the default source list" yes "$(in_default "$f")"
done
assert_eq "control: a markdown file is not" no "$(in_default README.md)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
