#!/usr/bin/env bash
# Pins for scripts/comments: every shape fails in comment text and passes in
# a string literal or in code, each extraction limit CHECKS.md states holds
# exactly as stated, the path list and excludes resolve like the sibling
# lanes', and --staged judges the lines the commit adds against comment
# state read from the whole file. Every green assertion is paired with a
# control that proves it can fail. The index readers this family shares are
# pinned once, in index-reads.test.sh.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CM="$SKILL_DIR/scripts/comments"
GG="$SKILL_DIR/scripts/growth-guards"
. "$TEST_DIR/lib/harness.bash"

# Hermetic: a leaked setting would mask every case below.
unset GROWTH_GUARDS_COMMENT_PATHS GROWTH_GUARDS_COMMENT_EXCLUDES GH_ISSUE_PATTERN \
  GROWTH_GUARDS_CHECKS GROWTH_GUARDS_SETTINGS_FILE 2>/dev/null || true

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

run_cm() { # [args...] — run in $R; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$CM" "$@" 2>&1)" || RC=$?
}

put() { # PATH LINE... — a tracked file holding those lines, staged
  local f="$1"
  shift
  mkdir -p "$R/$(dirname "$f")"
  printf '%s\n' "$@" >"$R/$f"
  git -C "$R" add -A
}

solo() { # PATH LINE... — the same, as the only tracked file
  (cd "$R" && git ls-files -z | xargs -0 rm -f --)
  put "$@"
}

# The word planted in every case: one whole-word member of the list. The
# test's own comments never carry it, so this file passes the lane it pins.
W="previously"

fails_at() { # DESC PATH LINE — the last run failed naming PATH:LINE
  [ "$RC" -eq 1 ] && case "$OUT" in *"history reference"*": $2:$3: "*) true ;; *) false ;; esac \
    && ok "$1" || bad "$1" "rc=$RC out=$OUT"
}
passes() { # DESC — the last run was clean and read at least one file
  [ "$RC" -eq 0 ] && case "$OUT" in *"comments: OK — no history references in the comments of"*) true ;; *) false ;; esac \
    && ok "$1" || bad "$1" "rc=$RC out=$OUT"
}

echo "=== control: source with a clean comment passes, counting what it read ==="
new_repo clean
put a.rs '// the lock is held across the read on purpose' 'fn main() {}'
run_cm
[ "$RC" -eq 0 ] && case "$OUT" in *"comments: OK — no history references in the comments of 1 scanned file(s)"*) true ;; *) false ;; esac \
  && ok "a clean comment passes, and the verdict says how many files it read" \
  || bad "clean comment passes" "rc=$RC out=$OUT"

echo "=== each shape fails in a comment and names its shape ==="
new_repo shapes
put a.rs '// tracked as ABC-123 at the time it landed'
run_cm
fails_at "an issue id in a comment fails, naming file:line" a.rs 1
case "$OUT" in *"(issue id)"*) ok "the diagnostic names the shape" ;; *) bad "diagnostic names the shape" "$OUT" ;; esac
case "$OUT" in *"state the constraint that holds now and delete the story"*) ok "the diagnostic carries the remedy" ;; *) bad "diagnostic carries the remedy" "$OUT" ;; esac
case "$OUT" in *"comments: 2 history reference(s) in the comments of 1 scanned file(s)"*) ok "the summary counts every (line, shape) hit and the files read" ;; *) bad "summary counts hits and files" "$OUT" ;; esac
put a.rs '// abc-123 in lowercase is the same id'
run_cm
fails_at "the issue id is matched case-insensitively" a.rs 1
put a.rs '// closed by #228 upstream'
run_cm
fails_at "a three-digit issue number fails" a.rs 1
case "$OUT" in *"(issue number)"*) ok "named as an issue number" ;; *) bad "named as an issue number" "$OUT" ;; esac
put a.rs '// the shorthand #900 is also how issue 900 is written'
run_cm
fails_at "all-digit shorthand fails: the shape cannot tell a colour from an issue" a.rs 1
put a.rs '// the token #12345 and the colour #1234ab and the port #12'
run_cm
passes "a five-digit run, a hex colour and a two-digit run all pass"
put a.rs '// seeded 2026-08-12'
run_cm
fails_at "a calendar date fails" a.rs 1
case "$OUT" in *"(calendar date)"*) ok "named as a calendar date" ;; *) bad "named as a calendar date" "$OUT" ;; esac
put a.rs '// 2026-8-1 is not the shape'
run_cm
passes "an unpadded date is not the shape"
for w in previously "used to" "no longer" reverted "an earlier" "earlier round" incident historically originally "at the time" added new "existing code" "phase 1" "phase 12"; do
  put a.rs "// the flag $w applied to the batch"
  run_cm
  fails_at "the word '$w' fails" a.rs 1
done
case "$OUT" in *"(revision narration)"*) ok "named as revision narration" ;; *) bad "named as revision narration" "$OUT" ;; esac
put a.rs '// Previously the batch took the flag'
run_cm
fails_at "a sentence-initial capital is the same word" a.rs 1
put a.rs '// NO LONGER is shouted the same way'
run_cm
fails_at "an all-caps history word fails too" a.rs 1
put a.rs '// an incidental unreverted renewed originality is unadded and existing'
run_cm
passes "a word glued inside a longer word never fires, and 'existing' alone is not the phrase"
put a.rs '// phase without a number, and a phrase with existing code'
run_cm
fails_at "control: the phrase 'existing code' fires while a bare 'phase' does not" a.rs 1
[ "$(printf '%s\n' "$OUT" | grep -c 'FAIL history reference')" -eq 1 ] && ok "and it is the one hit" || bad "one hit" "$OUT"
put a.rs '// encoded as UTF-8'
run_cm
fails_at "the default key shape is any letter run, a hyphen and a digit run, so UTF-8 matches it (set GH_ISSUE_PATTERN to narrow)" a.rs 1

echo "=== a word the pattern matches inside a quoted example still counts ==="
put a.rs '// the string "previously" is banned, and so is `no longer`'
run_cm
fails_at "quotes and backticks inside a comment exempt nothing (the prose lane makes the same choice)" a.rs 1

echo "=== GH_ISSUE_PATTERN replaces the issue-id shape ==="
new_repo pattern
put a.rs '// see KEN-12 and ABC-123'
run_cm
[ "$RC" -eq 1 ] && [ "$(printf '%s\n' "$OUT" | grep -c 'history reference (issue id)')" -eq 1 ] \
  && ok "control: under the default pattern one issue-id record covers the line" \
  || bad "control: default pattern" "rc=$RC out=$OUT"
put a.rs '// see ABC-123 only'
OUT="$(cd "$R" && GH_ISSUE_PATTERN='ken-[0-9]+' "$CM" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && ok "a narrower pattern leaves ABC-123 alone" || bad "narrower pattern leaves ABC-123 alone" "rc=$RC out=$OUT"
put a.rs '// see KEN-12 only'
OUT="$(cd "$R" && GH_ISSUE_PATTERN='ken-[0-9]+' "$CM" 2>&1)" && RC=0 || RC=$?
fails_at "the same pattern catches KEN-12 whatever its case" a.rs 1
printf '[env]\nGH_ISSUE_PATTERN = "ken-[0-9]+"\n' >"$R/kendex.settings.toml"
git -C "$R" add -A
run_cm
fails_at "the pattern resolves from kendex.settings.toml [env]" a.rs 1
rm "$R/kendex.settings.toml"
put a.rs '// see ABC-123 again'
OUT="$(cd "$R" && GH_ISSUE_PATTERN= "$CM" 2>&1)" && RC=0 || RC=$?
fails_at "an empty pattern is unconfigured and keeps the default shape" a.rs 1
OUT="$(cd "$R" && GH_ISSUE_PATTERN='(' "$CM" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"GH_ISSUE_PATTERN is not a POSIX ERE"*) true ;; *) false ;; esac \
  && ok "a pattern no engine can compile is exit 2, never a silent no-match" \
  || bad "uncompilable pattern is exit 2" "rc=$RC out=$OUT"

echo "=== only comment text is judged: strings and code never fire ==="
new_repo extract
solo a.rs "let s = \"http://x/#228 $W ABC-123 2026-08-12\";"
run_cm
passes "every shape inside a string literal passes"
solo a.rs "let s = \"// $W\";"
run_cm
passes "a // inside a string literal is not a comment"
solo a.rs "let x = 1; // $W"
run_cm
fails_at "control: a comment after code on the same line is judged" a.rs 1
solo a.rs "let s = \"//\"; // $W"
run_cm
fails_at "control: a comment after a string that holds a leader is still judged" a.rs 1
solo a.rs "/* $W */ fn main() {}"
run_cm
fails_at "a block comment is judged" a.rs 1
solo a.rs '/* first line' " second line $W" ' third */'
run_cm
fails_at "a block comment spanning lines reports the line the reference sits on" a.rs 2
solo a.rs "/// $W" "//! $W" 'fn main() {}'
run_cm
[ "$RC" -eq 1 ] && case "$OUT" in *": a.rs:1: "*": a.rs:2: "*) true ;; *) false ;; esac \
  && ok "doc-comment forms are judged like any other comment" || bad "doc comments judged" "rc=$RC out=$OUT"
solo a.rs "let p = previously_seen(); let n = new_value; // clean"
run_cm
passes "a word in code, even one the list holds, is never judged"

echo "=== Rust: lifetimes, char literals, raw and multi-line strings ==="
solo a.rs "fn f<'a>(x: &'a str) -> &'a str { x } // $W"
run_cm
fails_at "a lifetime quote opens no string, so the comment after it is still seen" a.rs 1
solo a.rs "let q = '\"'; let n = '\\n'; // $W"
run_cm
fails_at "a char literal holding a double quote opens no string" a.rs 1
solo a.rs "let r = r#\"say \"hi\" // $W\"#;"
run_cm
passes "a raw string with inner quotes and a leader is one string"
solo a.rs "let r = r#\"say \"hi\"\"#; // $W"
run_cm
fails_at "control: the comment after that raw string is judged" a.rs 1
solo a.rs 'let s = "line one \' "  // $W \\" '  line three";'
run_cm
passes "a string continued across lines by a trailing backslash is one string"
solo a.rs 'let s = "line one' "  // $W" '  line three";'
run_cm
passes "a Rust string spanning lines without a backslash is one string too"
solo a.rs 'let s = "line one' '  line two";' "// $W"
run_cm
fails_at "control: the comment after a multi-line string is judged" a.rs 3

echo "=== JavaScript: template literals and single quotes ==="
solo a.ts 'const t = `line one' "  // $W" '  line three`;'
run_cm
passes "a template literal spanning lines is one string"
solo a.ts 'const t = `x`;' "// $W"
run_cm
fails_at "control: the comment after a template literal is judged" a.ts 2
solo a.ts "const s = '// $W';"
run_cm
passes "a single-quoted string holding a leader is a string"
solo a.ts "const s = \"a\"; // $W"
run_cm
fails_at "control: a JavaScript trailing comment is judged" a.ts 1

echo "=== hash family: word-start hashes, strings, shebang, heredocs ==="
solo a.sh "printf '%s' \"# $W\""
run_cm
passes "a hash inside a string is not a comment"
solo a.sh "echo \$# \${x#$W} url#$W"
run_cm
passes "a hash glued to a word is not a comment"
solo a.sh "foo # $W"
run_cm
fails_at "control: a hash after whitespace opens a comment" a.sh 1
solo a.sh "#!/bin/bash $W" "# $W"
run_cm
fails_at "a shebang is not a comment; the line after it is" a.sh 2
case "$OUT" in *"a.sh:1:"*) bad "the shebang must not be judged" "$OUT" ;; *) ok "the shebang line itself is not in the verdict" ;; esac
solo a.sh "echo 'a\\' # $W"
run_cm
fails_at "a backslash in a single-quoted shell string escapes nothing" a.sh 1
solo a.sh "echo \$'a\\'b' # $W"
run_cm
fails_at "a backslash in \$'...' does escape, so the comment after the string is judged" a.sh 1
solo a.sh 'cat <<EOF' "# $W" 'EOF' "# $W"
run_cm
[ "$RC" -eq 1 ] && case "$OUT" in *": a.sh:2: "*) false ;; *": a.sh:4: "*) true ;; *) false ;; esac \
  && ok "a heredoc body is not judged; the line after its terminator is" \
  || bad "heredoc body skipped" "rc=$RC out=$OUT"
solo a.sh "cat <<-'EOF'" "	# $W" '	EOF' "# $W"
run_cm
[ "$RC" -eq 1 ] && case "$OUT" in *": a.sh:2: "*) false ;; *": a.sh:4: "*) true ;; *) false ;; esac \
  && ok "a quoted <<- heredoc ends at its tab-indented terminator" \
  || bad "<<- heredoc" "rc=$RC out=$OUT"
solo a.sh "x=\$((1<<2)) # $W"
run_cm
fails_at "a shift is not a heredoc" a.sh 1
solo a.sh 'x=$(( 1 << n ))' "# $W"
run_cm
fails_at "a shift by a name inside ((...)) opens no heredoc, so the next line is judged" a.sh 2
solo a.sh 'cat <<END-OF' "# $W" 'END-OF' "# $W"
run_cm
[ "$RC" -eq 1 ] && case "$OUT" in *": a.sh:2: "*) false ;; *": a.sh:4: "*) true ;; *) false ;; esac \
  && ok "a heredoc word is taken whole, so END-OF terminates the body and the line after it is judged" \
  || bad "heredoc word taken whole" "rc=$RC out=$OUT"
solo a.sh 'cat <<"END-OF" | sort' "# $W" 'END-OF' "# $W"
run_cm
[ "$RC" -eq 1 ] && case "$OUT" in *": a.sh:2: "*) false ;; *": a.sh:4: "*) true ;; *) false ;; esac \
  && ok "a quoted heredoc word is stripped of its quotes and stops before the pipe" \
  || bad "quoted heredoc word" "rc=$RC out=$OUT"
solo a.sh "read -r x <<<\"y\" # $W"
run_cm
fails_at "a here-string is not a heredoc" a.sh 1
solo a.py '"""' "# $W" '"""' "# $W"
run_cm
[ "$RC" -eq 1 ] && case "$OUT" in *": a.py:2: "*) false ;; *": a.py:4: "*) true ;; *) false ;; esac \
  && ok "a triple-quoted Python string is one string" || bad "triple-quoted string" "rc=$RC out=$OUT"
solo a.toml "key = \"a # $W\"" "other = 1 # $W"
run_cm
[ "$RC" -eq 1 ] && case "$OUT" in *": a.toml:1: "*) false ;; *": a.toml:2: "*) true ;; *) false ;; esac \
  && ok "TOML: a hash in a string is not a comment, one after a value is" || bad "TOML" "rc=$RC out=$OUT"
solo a.yml "key: 'don''t' # $W"
run_cm
fails_at "YAML: a doubled quote ends nothing, and the trailing comment is judged" a.yml 1
solo Makefile "all: # $W"
run_cm
fails_at "a Makefile is judged by its basename" Makefile 1
solo sub/Dockerfile "# $W"
run_cm
fails_at "a nested Dockerfile is judged by its basename" sub/Dockerfile 1

echo "=== SQL, Lua, markup, CSS ==="
solo a.sql "SELECT '-- $W'; -- $W"
run_cm
fails_at "SQL: a leader inside a string is a string, the trailing comment is judged" a.sql 1
[ "$(printf '%s\n' "$OUT" | grep -c 'FAIL history reference')" -eq 1 ] && ok "and it is one hit, not two" || bad "one hit" "$OUT"
solo a.sql "/* $W */ SELECT 1;"
run_cm
fails_at "SQL: a block comment is judged" a.sql 1
solo a.lua "--[[ $W" "]] x = 1"
run_cm
fails_at "Lua: a block comment is judged" a.lua 1
solo a.html "<p>$W</p>" "<!-- $W -->"
run_cm
[ "$RC" -eq 1 ] && case "$OUT" in *": a.html:1: "*) false ;; *": a.html:2: "*) true ;; *) false ;; esac \
  && ok "markup: text is not judged, a comment is" || bad "markup" "rc=$RC out=$OUT"
solo a.svelte '<!-- first' " $W -->"
run_cm
fails_at "a markup comment spanning lines reports the line the reference sits on" a.svelte 2
solo a.css "a { background: url(http://x/$W) } /* clean */"
run_cm
passes "CSS: a URL's slashes open no comment"
solo a.css "a { color: red } /* $W */"
run_cm
fails_at "control: a CSS block comment is judged" a.css 1

echo "=== every limit CHECKS.md states holds exactly as stated ==="
new_repo limits
solo a.js "const re = /https?:\\/\\// ; // $W"
run_cm
fails_at "a regex literal is code: its escaped slashes open no comment, the trailing comment is judged" a.js 1
solo a.js "const re = /x\\/\\/y/; const t = /a// $W"
run_cm
fails_at "a // inside a regex literal opens a comment (stated limit)" a.js 1
solo a.py "x = 1#$W"
run_cm
passes "a hash glued to a Python value is read as code (stated limit)"
solo a.lua "s = [[ --$W ]]"
run_cm
fails_at "a -- inside a Lua long string is read as a comment (stated limit)" a.lua 1
solo a.rs "/* outer /* inner */ $W */"
run_cm
passes "a nested Rust block comment closes at the first */, so the tail is read as code (stated limit)"
solo a.lua "--[==[ $W" "]==] x = 1"
run_cm
[ "$RC" -eq 1 ] && case "$OUT" in *": a.lua:1: "*) true ;; *) false ;; esac \
  && ok "a levelled Lua block opener is read as a -- line comment, judged on its own line" \
  || bad "levelled Lua block" "rc=$RC out=$OUT"
solo a.sh "cat <<A <<B" "# $W" "A" "# $W" "B" "# $W"
run_cm
[ "$RC" -eq 1 ] && case "$OUT" in *": a.sh:2: "*) false ;; *": a.sh:4: "*) true ;; *) false ;; esac \
  && ok "a line opening two heredocs honours the first: the body after its terminator is judged (stated limit)" \
  || bad "two heredocs" "rc=$RC out=$OUT"
solo a.rb "s = <<~EOS" "# $W" "EOS"
run_cm
fails_at "a Ruby heredoc body is read as code, so its hash is a comment (stated limit)" a.rb 2
solo a.yml "key: |" "  # $W"
run_cm
fails_at "a YAML block scalar is read as code (stated limit)" a.yml 2
solo Makefile "all:" "	echo '# $W'"
run_cm
passes "a Makefile recipe's shell is read under the hash grammar with its strings tracked (stated limit)"
solo Makefile "all:" "	echo \$# $W"
run_cm
passes "and a hash glued to a dollar is not a comment there either"
solo a.vue "<script>// $W</script>"
run_cm
passes "a Vue script block's // is not read (stated limit)"
solo a.vue "<template><!-- $W --></template>"
run_cm
fails_at "control: the markup comment in the same file is judged" a.vue 1
solo a.c 'char *s = "one \' "  // $W" '  three";'
run_cm
fails_at "a C string ends at its line, so the continued line's // is a comment (stated limit)" a.c 2

echo "=== a file that ends inside a string, a block comment or a heredoc is not extractable ==="
new_repo unclosed
not_extractable() { # DESC PATH FRAGMENT — the last run was exit 2 naming PATH and the opener
  [ "$RC" -eq 2 ] && case "$OUT" in *"could not extract the comment text of $2: $3"*) true ;; *) false ;; esac \
    && ok "$1" || bad "$1" "rc=$RC out=$OUT"
  case "$OUT" in *"scanned file(s)"*) bad "no clean count covers a file that was not extracted" "$OUT" ;; *) ok "no clean count covers a file that was not extracted" ;; esac
}
solo a.ts 'const re = /`/g;' "// $W"
run_cm
not_extractable "a regex literal holding a backtick opens a template literal that never closes (stated limit)" a.ts "a string literal opened at line 1 is never closed"
solo a.c 'int x;' '/* open' "int y; // $W"
run_cm
not_extractable "a block comment never closed is reported, not read to the end as one comment" a.c "a block comment opened at line 2 is never closed"
solo a.sh 'cat <<EOF' 'body' "# $W"
run_cm
not_extractable "a heredoc never terminated is reported, naming its word" a.sh "a heredoc (terminator EOF) opened at line 1 is never closed"
solo a.rs 'let s = "spans' 'lines";' "// $W"
run_cm
fails_at "control: a string that does close is a string, and the comment after it is judged" a.rs 3

echo "=== a path with no grammar is named as unmeasured, never counted clean ==="
new_repo grammar
put run "#!/usr/bin/env bash" "# $W"
OUT="$(cd "$R" && GROWTH_GUARDS_COMMENT_PATHS='run' "$CM" 2>&1)" && RC=0 || RC=$?
fails_at "an extensionless file the list names is judged under the grammar its shebang picks" run 2
put run "# $W" "echo hi"
OUT="$(cd "$R" && GROWTH_GUARDS_COMMENT_PATHS='run' "$CM" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"not measured: run — no comment grammar"*"1 matched path(s) not measured"*) true ;; *) false ;; esac \
  && ok "the same file with no shebang is named as unmeasured and counted" \
  || bad "no-shebang file named" "rc=$RC out=$OUT"
case "$OUT" in *"scanned file(s)"*) bad "an unmeasured path must not produce a clean scanned-file verdict" "$OUT" ;; *) ok "no clean scanned-file verdict covers the unread path" ;; esac
put notes.txt "# $W"
OUT="$(cd "$R" && GROWTH_GUARDS_COMMENT_PATHS='*.txt' "$CM" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"not measured: notes.txt"*) true ;; *) false ;; esac \
  && ok "an extension the table does not carry is named, not guessed at" \
  || bad "unknown extension named" "rc=$RC out=$OUT"
# A `head` that fails on the shebang read alone: the binary sniff's `head -c`
# still runs, so the error can only come from the grammar lookup.
mkdir -p "$R/shim"
printf '#!/bin/sh\ncase "$1" in -n) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v head)" >"$R/shim/head"
chmod +x "$R/shim/head"
put run "#!/usr/bin/env bash" "# $W"
OUT="$(cd "$R" && PATH="$R/shim:$PATH" GROWTH_GUARDS_COMMENT_PATHS='run' "$CM" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"could not read the first line of run"*) true ;; *) false ;; esac \
  && ok "a shebang read that fails is a collection error, not a path with no grammar" \
  || bad "failed shebang read is loud" "rc=$RC out=$OUT"
case "$OUT" in *"no comment grammar"*) bad "the failed read must not be named as a grammar skip" "$OUT" ;; *) ok "and it is not named as a grammar skip" ;; esac

echo "=== scope: each default extension is scanned, markdown is not ==="
new_repo scope
put ok.rs '// clean'
for f in a.rs a.go a.c a.h a.cc a.cpp a.hpp a.java a.kt a.kts a.swift a.wgsl a.js a.mjs a.cjs a.jsx a.ts a.tsx a.scss a.less a.sh a.bash a.zsh a.py a.rb a.toml a.yml a.yaml deep/a.mk; do
  put "$f" "// $W" "# $W" "-- $W"
  run_cm
  [ "$RC" -eq 1 ] && case "$OUT" in *"history reference"*": $f:"*) true ;; *) false ;; esac \
    && ok "$f is in the default scope" || bad "$f is in the default scope" "rc=$RC out=$OUT"
  rm "$R/$f"
  git -C "$R" add -A
done
for f in a.css a.sql a.lua a.html a.htm a.xml a.svg a.vue a.svelte; do
  put "$f" "/* $W */ -- $W <!-- $W -->"
  run_cm
  [ "$RC" -eq 1 ] && case "$OUT" in *"history reference"*": $f:"*) true ;; *) false ;; esac \
    && ok "$f is in the default scope" || bad "$f is in the default scope" "rc=$RC out=$OUT"
  rm "$R/$f"
  git -C "$R" add -A
done
put README.md "# $W" "<!-- $W -->"
put AGENTS.md "<!-- $W -->"
put a.json "{\"k\": \"// $W\"}"
run_cm
passes "markdown and JSON are not this lane's (the prose lane owns markdown)"

echo "=== GROWTH_GUARDS_COMMENT_PATHS REPLACES the list, and is validated ==="
new_repo override
put a.rs "// $W"
put notes.txt "# $W"
OUT="$(cd "$R" && GROWTH_GUARDS_COMMENT_PATHS='*.txt' "$CM" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"a.rs"*) false ;; *"not measured: notes.txt"*) true ;; *) false ;; esac \
  && ok "the override replaces the list: a.rs is no longer scanned" || bad "override replaces the list" "rc=$RC out=$OUT"
OUT="$(cd "$R" && GROWTH_GUARDS_COMMENT_PATHS='no/such/*.rs' "$CM" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"no tracked file matches GROWTH_GUARDS_COMMENT_PATHS"*) true ;; *) false ;; esac \
  && ok "a list matching no tracked file passes, naming the list" || bad "unmatched list" "rc=$RC out=$OUT"
OUT="$(cd "$R" && GROWTH_GUARDS_COMMENT_PATHS=' ' "$CM" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"names no path"*) true ;; *) false ;; esac \
  && ok "an empty path list is exit 2" || bad "empty path list is exit 2" "rc=$RC out=$OUT"
run_cm --no-such-flag
[ "$RC" -eq 2 ] && ok "unknown flag is exit 2" || bad "unknown flag is exit 2" "rc=$RC out=$OUT"
run_cm --help
[ "$RC" -eq 0 ] && case "$OUT" in *"usage: comments"*) true ;; *) false ;; esac \
  && ok "--help prints usage at exit 0" || bad "--help prints usage" "rc=$RC out=$OUT"

echo "=== excludes: generated trees are excluded WITH a reason, carves win ==="
new_repo exc
put vendor/lib.rs "// $W"
put gen/out.ts "// $W"
run_cm
[ "$RC" -eq 1 ] && case "$OUT" in *"vendor/lib.rs:1:"*"gen/out.ts:1:"*|*"gen/out.ts:1:"*"vendor/lib.rs:1:"*) true ;; *) false ;; esac \
  && ok "control: both planted files fail without an excludes row" || bad "control: no excludes" "rc=$RC out=$OUT"
put tools/comments-excludes "$(printf 'vendor/*\tvendored third-party code')"
run_cm
[ "$RC" -eq 1 ] && case "$OUT" in *"vendor/lib.rs"*) false ;; *"gen/out.ts:1:"*) true ;; *) false ;; esac \
  && ok "the excludes row silences exactly the vendored tree" || bad "excludes row" "rc=$RC out=$OUT"
put tools/comments-excludes "$(printf 'vendor/*\tvendored third-party code\ngen/*\tgenerated\n!gen/out.ts\thand-written after all')"
run_cm
[ "$RC" -eq 1 ] && case "$OUT" in *"gen/out.ts:1:"*) true ;; *) false ;; esac \
  && ok "a ! row carves its path back into the scanned set" || bad "carve" "rc=$RC out=$OUT"
put tools/comments-excludes 'vendor/*'
run_cm
[ "$RC" -eq 2 ] && case "$OUT" in *"pattern<TAB>reason"*) true ;; *) false ;; esac \
  && ok "a pattern without a reason is exit 2" || bad "reasonless row is exit 2" "rc=$RC out=$OUT"
put alt "$(printf 'vendor/*\tvendored\ngen/*\tgenerated')"
rm "$R/tools/comments-excludes"
git -C "$R" add -A
OUT="$(cd "$R" && GROWTH_GUARDS_COMMENT_EXCLUDES=alt "$CM" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && ok "the excludes path resolves through the environment key" || bad "env excludes key" "rc=$RC out=$OUT"
run_cm --excludes alt
[ "$RC" -eq 0 ] && ok "--excludes flag points at the same list" || bad "--excludes flag" "rc=$RC out=$OUT"

echo "=== a symlink and a binary blob at a configured path are named ==="
new_repo unmeasurable
put target.txt "// $W"
ln -s target.txt "$R/link.rs"
git -C "$R" add -A
run_cm
[ "$RC" -eq 0 ] && case "$OUT" in *"not measured: link.rs"*"tracked as a symlink"*) true ;; *) false ;; esac \
  && ok "a symlink at a source path is named as unmeasured" || bad "symlink named" "rc=$RC out=$OUT"
printf 'lead\000// %s\n' "$W" >"$R/blob.rs"
git -C "$R" add -A
run_cm
[ "$RC" -eq 0 ] && case "$OUT" in *"not measured: blob.rs"*"binary content"*) true ;; *) false ;; esac \
  && ok "a binary blob at a source path is named as unmeasured" || bad "binary named" "rc=$RC out=$OUT"
case "$OUT" in *"no history references in"*) bad "no clean verdict may cover unread blobs" "$OUT" ;; *) ok "no clean file-count verdict covers the unread paths" ;; esac

echo "=== --staged judges the lines the commit adds, with comment state from the whole file ==="
new_repo staged
put ok.rs '/* a block comment that' '   spans lines */' 'fn main() {}'
git -C "$R" commit -qm seed
put fixture.rs "// committed $W"
git -C "$R" commit -qm fixture
printf '/* a block comment that\n   %s\n   spans lines */\nfn main() {}\n' "$W" >"$R/ok.rs"
git -C "$R" add ok.rs
run_cm --staged
fails_at "a line added inside a block comment the commit did not open is judged, at its line" ok.rs 2
case "$OUT" in *"fixture.rs"*) bad "the untouched fixture must stay out of the commit-scope verdict" "$OUT" ;; *) ok "the committed reference is not in that verdict" ;; esac
case "$OUT" in *"in comments added by the staged diff"*) ok "the staged summary names its scope" ;; *) bad "staged summary" "$OUT" ;; esac
git -C "$R" checkout -q HEAD -- ok.rs
printf 'fn other() {}\n' >>"$R/ok.rs"
git -C "$R" add ok.rs
run_cm --staged
[ "$RC" -eq 0 ] && case "$OUT" in *"the staged diff adds no history references in comments (1 file(s) read)"*) true ;; *) false ;; esac \
  && ok "a commit adding no reference passes on a repo whose index holds one" || bad "clean staged commit" "rc=$RC out=$OUT"
run_cm
fails_at "control: the index scan (CI) still refuses the committed reference" fixture.rs 1
printf 'fn main() {} // %s\n' "$W" >"$R/ok.rs"
git -C "$R" add ok.rs
printf 'fn main() {}\n' >"$R/ok.rs"
run_cm --staged
fails_at "staged bytes decide, whatever the work tree says now" ok.rs 1
git -C "$R" checkout -q HEAD -- ok.rs
git -C "$R" mv fixture.rs moved.rs
run_cm --staged
[ "$RC" -eq 0 ] && ok "a pure rename adds no line and is not judged" || bad "pure rename" "rc=$RC out=$OUT"
printf '// committed %s\n// and %s again\n' "$W" "$W" >"$R/moved.rs"
git -C "$R" add moved.rs
run_cm --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"moved.rs:1:"*"moved.rs:2:"*) true ;; *) false ;; esac \
  && ok "a file that moved and changed is read whole" || bad "moved and changed" "rc=$RC out=$OUT"
new_repo first
put a.rs "// $W"
run_cm --staged
fails_at "on a repository's first commit the whole staged tree reads as added" a.rs 1
put a.rs '// clean'
run_cm --staged
[ "$RC" -eq 0 ] && ok "control: a clean first commit passes, not exit 2 for want of a HEAD" || bad "clean first commit" "rc=$RC out=$OUT"
put notes.md "# $W"
run_cm --staged
[ "$RC" -eq 0 ] && ok "--staged honours the path list: markdown is not read" || bad "staged path list" "rc=$RC out=$OUT"
put vendor/v.rs "// $W"
put tools/comments-excludes "$(printf 'vendor/*\tvendored')"
run_cm --staged
[ "$RC" -eq 0 ] && ok "--staged honours the exclusion list" || bad "staged excludes" "rc=$RC out=$OUT"
rm "$R/tools/comments-excludes"
git -C "$R" add -A
run_cm --staged
fails_at "control: without the row the staged vendored comment fails" vendor/v.rs 1

echo "=== the dispatcher knows the lane and hands it --staged; the default batch omits it ==="
new_repo dispatch
put ok.rs 'fn main() {}'
git -C "$R" commit -qm seed
put a.rs "// $W"
OUT="$(cd "$R" && "$GG" comments 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 1 ] && ok "'growth-guards comments' reaches the lane" || bad "dispatcher routes by name" "rc=$RC out=$OUT"
OUT="$(cd "$R" && GROWTH_GUARDS_CHECKS=comments "$GG" all --staged 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 1 ] && case "$OUT" in *"growth-guards: comments --staged"*) true ;; *) false ;; esac \
  && ok "the batch hands comments --staged at commit scope" || bad "batch forwards --staged" "rc=$RC out=$OUT"
OUT="$(cd "$R" && "$GG" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"growth-guards: comments"*) false ;; *) true ;; esac \
  && ok "the default batch does not run the lane (it is opt-in through GROWTH_GUARDS_CHECKS)" \
  || bad "default batch omits comments" "rc=$RC out=$OUT"

echo "=== the skill's own shipped shell scans clean under its own lane ==="
new_repo self
mkdir -p "$R/skills/growth-guards/scripts/lib"
cp "$SKILL_DIR/scripts/comments" "$R/skills/growth-guards/scripts/comments"
cp "$SKILL_DIR/scripts/lib/comment-text.sh" "$SKILL_DIR/scripts/lib/staged-lines.sh" "$R/skills/growth-guards/scripts/lib/"
cp "$TEST_DIR/comments.test.sh" "$R/skills/growth-guards/comments.test.sh"
git -C "$R" add -A
OUT="$(cd "$R" && GROWTH_GUARDS_COMMENT_PATHS='*.sh skills/*/scripts/*' "$CM" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"no history references in the comments of 4 scanned file(s)"*) true ;; *) false ;; esac \
  && ok "the lane, its libraries and this suite carry no history in their comments" \
  || bad "shipped shell scans clean" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
