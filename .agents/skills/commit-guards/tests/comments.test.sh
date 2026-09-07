#!/usr/bin/env bash
# Pins for scripts/comments, the history-reference ban over comment text:
# every shape fails in a comment and names its shape, passes in a string
# literal or in code; each extraction limit CHECKS.md states holds exactly
# as stated; the path list and the excludes resolve like the sibling lanes';
# --staged judges the lines the commit adds against comment state read from
# the whole file. Two tables. The first builds one tracked file per row from
# the row's own content and pins the exit status with every line printed,
# so the shape, the file and line, the extracted text, the remedy and the
# summary are one pin. The second runs a fixture function per row for the
# cases that need more than one file or a commit. The index readers this
# family shares are pinned once, in index-reads.test.sh and
# lane-readers.test.sh.
#
# The reference planted in fixtures stays in row data: this suite itself
# must pass the comments lane, and its last assertion proves it does.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CM="$SKILL_DIR/scripts/comments"
GG="$SKILL_DIR/scripts/commit-guards"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# Hermetic: a leaked setting would mask every row below.
unset COMMIT_GUARDS_COMMENT_PATHS COMMIT_GUARDS_COMMENT_EXCLUDES \
  COMMIT_GUARDS_COMMENT_REFERENCE_TYPES GH_ISSUE_PATTERN \
  COMMIT_GUARDS_CHECKS COMMIT_GUARDS_SETTINGS_FILE 2>/dev/null || true
# Extraction rows use an explicitly declared tracker prefix.
export GH_ISSUE_PATTERN='ABC-[0-9]+'
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

# One line for a run in the row's repository: the exit status, then every
# line printed, in order, joined by ';'. ENVS is a comma-separated list of
# assignments (`-u,NAME` unsets one); ARGS are passed through; BIN is the
# script run, the lane unless a row says otherwise.
R=""
BIN="$CM"
run() { # ENVS ARGS
  local envs=() rc=0 out=""
  [ -z "$1" ] || IFS=',' read -ra envs <<<"$1"
  # shellcheck disable=SC2086
  out="$(cd "$R" && env ${envs[@]+"${envs[@]}"} "$BIN" $2 2>&1)" || rc=$?
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}

# Fixture vocabulary. Every fixture builds its own repository; a name used
# twice is refused. The generated-paths inventory is empty and tracked.
repo() { # NAME
  R="$TMP/$1"
  [ ! -e "$R" ] || { echo "harness: fixture $1 already exists" >&2; exit 2; }
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  printf '[]\n' >"$R/.kendex-generated.json"
  git -C "$R" add .kendex-generated.json
}
put() { mkdir -p "$R/$(dirname "$1")"; printf '%b' "$2" >"$R/$1"; } # PATH CONTENT (printf %b)
stage() { git -C "$R" add -A; }
commit() { git -C "$R" commit -qm "${1:-seed}"; } # [MESSAGE]
file() { repo "$1"; put "$2" "$3"; stage; } # NAME PATH CONTENT — one tracked file

# The lines the lane prints, as functions of what a row put in.
EXCL=tools/comments-excludes
remedy() { printf '  remedies: state the constraint that holds now and delete the story; the issue id, the number and the date belong in the commit that made the change; a generated, vendored, or immutable file belongs in %s with a reason' "${1:-$EXCL}"; } # [EXCLUDES]
hit() { printf 'comments FAIL history reference (%s): %s:%s: %s;%s' "$1" "$2" "$3" "$4" "$(remedy "${5:-}")"; } # SHAPE PATH LINE TEXT [EXCLUDES]
ok_idx() { printf 'comments: OK — no history references in the comments of %s scanned file(s)' "$1"; } # FILES
idx() { printf 'comments: %s history reference(s) in the comments of %s scanned file(s) — excludes %s' "$1" "$2" "${3:-$EXCL}"; } # HITS FILES [EXCLUDES]
ok_stg() { printf 'comments: OK — the staged diff adds no history references in comments (%s file(s) read)' "$1"; } # FILES
stg() { printf 'comments: %s history reference(s) in comments added by the staged diff — excludes %s' "$1" "${2:-$EXCL}"; } # HITS [EXCLUDES]
skip() { printf 'comments: not measured: %s — %s' "$1" "$2"; } # PATH REASON
unread() { printf '; %s matched path(s) not measured' "$1"; } # COUNT
incomplete() { printf 'comments: scan incomplete — %s file(s) could not be scanned; %s history reference(s) found in %s scanned file(s)' "$1" "$2" "$3"; } # UNSCANNED HITS FILES
ERR="::error::comments: "
NO_TYPE="${ERR}COMMIT_GUARDS_COMMENT_REFERENCE_TYPES must name an active type; issue-id needs GH_ISSUE_PATTERN"
ID="issue id"
NUM="issue number"
DATE="calendar date"

# The first table: label | path | content | env | args | expect. One
# tracked file per row, built from CONTENT through printf %b.
run_files() {
  local row label path content env args expect n=0
  for row in "$@"; do
    IFS='|' read -r label path content env args expect <<<"$row"
    [ -n "$expect" ] || { echo "harness: row has fewer than six fields: $row" >&2; exit 2; }
    n=$((n + 1))
    file "f-$SECTION-$n" "$path" "$content"
    assert_eq "$label" "$expect" "$(run "$env" "$args")"
  done
}
# The second: label | fixture | env | args | expect.
run_rows() {
  local row label fx env args expect
  for row in "$@"; do
    IFS='|' read -r label fx env args expect <<<"$row"
    [ -n "$expect" ] || { echo "harness: row has fewer than five fields: $row" >&2; exit 2; }
    R=""
    "$fx"
    assert_eq "$label" "$expect" "$(run "$env" "$args")"
  done
}

SECTION=shapes
echo "=== each shape fails in a comment and names its shape; ordinary wording passes in both scopes ==="
ORDINARY=(
  'The previously saved value stays available.'
  'The lock is no longer held after return.'
  'The incident handler writes a report.'
  'The existing code handles a reverted transaction.'
  'The timestamp records the value at the time of the read.'
)
rows=(
  "a clean comment passes, and the verdict counts the file it read|a.rs|// the lock is held across the read on purpose\nfn main() {}\n|||rc=0 $(ok_idx 1)"
  "an issue id in a comment fails naming shape, file, line and the comment text, with the remedy, and the summary counts hits and files|a.rs|// tracked as $W at the time it landed\n|||rc=1 $(hit "$ID" a.rs 1 " tracked as $W at the time it landed");$(idx 1 1)"
  "the issue id is matched in lower case too|a.rs|// abc-123 in lowercase is the same id\n|||rc=1 $(hit "$ID" a.rs 1 " abc-123 in lowercase is the same id");$(idx 1 1)"
  "a three-digit issue number fails, named as one|a.rs|// closed by #228 upstream\n|||rc=1 $(hit "$NUM" a.rs 1 " closed by #228 upstream");$(idx 1 1)"
  "all-digit shorthand fails: the shape cannot tell a colour from an issue|a.rs|// the shorthand #900 is also how issue 900 is written\n|||rc=1 $(hit "$NUM" a.rs 1 " the shorthand #900 is also how issue 900 is written");$(idx 1 1)"
  "a five-digit run, a hex colour and a two-digit run all pass|a.rs|// the token #12345 and the colour #1234ab and the port #12\n|||rc=0 $(ok_idx 1)"
  "a calendar date fails, named as one|a.rs|// seeded $D\n|||rc=1 $(hit "$DATE" a.rs 1 " seeded $D");$(idx 1 1)"
  "an unpadded date is not the shape|a.rs|// 2026-8-1 is not the shape\n|||rc=0 $(ok_idx 1)"
  "a year outside 20YY is not the shape either|a.rs|// 1999-12-31 is not the shape\n|||rc=0 $(ok_idx 1)"
  "two shapes on one line are two hits, the id before the number|a.rs|// the string \"$W\" is a reference, and so is \`#228\`\n|||rc=1 $(hit "$ID" a.rs 1 " the string \"$W\" is a reference, and so is \`#228\`");$(hit "$NUM" a.rs 1 " the string \"$W\" is a reference, and so is \`#228\`");$(idx 2 1)"
  "the issue-id class alone reports only the id on a line carrying a date too|a.rs|// tracked as $W on $D\n|COMMIT_GUARDS_COMMENT_REFERENCE_TYPES=issue-id||rc=1 $(hit "$ID" a.rs 1 " tracked as $W on $D");$(idx 1 1)"
  "the date class alone reports only the date|a.rs|// tracked as $W on $D\n|COMMIT_GUARDS_COMMENT_REFERENCE_TYPES=date||rc=1 $(hit "$DATE" a.rs 1 " tracked as $W on $D");$(idx 1 1)"
  "the issue-number class alone finds nothing on that line|a.rs|// tracked as $W on $D\n|COMMIT_GUARDS_COMMENT_REFERENCE_TYPES=issue-number||rc=0 $(ok_idx 1)"
  "an unknown reference type is a config error quoting it|a.rs|// clean\n|COMMIT_GUARDS_COMMENT_REFERENCE_TYPES=issue-id bogus||rc=2 ${ERR}COMMIT_GUARDS_COMMENT_REFERENCE_TYPES contains unknown type 'bogus'"
  "technical names pass without a tracker pattern|a.rs|// UTF-8 HTTP-200 RFC-3339 gpt-6-astra exit-2\n|GH_ISSUE_PATTERN=||rc=0 $(ok_idx 1)"
  "an undeclared tracker prefix is not guessed|a.rs|// see $W\n|GH_ISSUE_PATTERN=||rc=0 $(ok_idx 1)"
  "control: the configured tracker prefix catches the same reference|a.rs|// see $W\n|||rc=1 $(hit "$ID" a.rs 1 " see $W");$(idx 1 1)"
  "the number shape stays checked without a tracker pattern|a.rs|// see #1234\n|GH_ISSUE_PATTERN=||rc=1 $(hit "$NUM" a.rs 1 " see #1234");$(idx 1 1)"
  "and so does the date shape|a.rs|// dated $D\n|GH_ISSUE_PATTERN=||rc=1 $(hit "$DATE" a.rs 1 " dated $D");$(idx 1 1)"
  "an id-only scan with no tracker pattern is a config error|a.rs|// see $W\n|GH_ISSUE_PATTERN=,COMMIT_GUARDS_COMMENT_REFERENCE_TYPES=issue-id||rc=2 $NO_TYPE"
  "a whitespace-only type list is the same refusal in index scope|a.rs|// clean\n|COMMIT_GUARDS_COMMENT_REFERENCE_TYPES= ||rc=2 $NO_TYPE"
  "and in staged scope|a.rs|// clean\n|COMMIT_GUARDS_COMMENT_REFERENCE_TYPES= |--staged|rc=2 $NO_TYPE"
  "a pattern naming another tracker leaves this one's id alone|a.rs|// see $W only\n|GH_ISSUE_PATTERN=ken-[0-9]+||rc=0 $(ok_idx 1)"
  "and catches its own whatever the case|a.rs|// see KEN-12 only\n|GH_ISSUE_PATTERN=ken-[0-9]+||rc=1 $(hit "$ID" a.rs 1 " see KEN-12 only");$(idx 1 1)"
  "control: under the fixture pattern the same line is clean|a.rs|// see KEN-12 only\n|||rc=0 $(ok_idx 1)"
  "an empty pattern leaves issue ids unconfigured|a.rs|// see $W again\n|GH_ISSUE_PATTERN=||rc=0 $(ok_idx 1)"
  "a pattern no engine can compile is a config error quoting the bounded pattern, never a silent no-match|a.rs|// see $W\n|GH_ISSUE_PATTERN=(||rc=2 ${ERR}GH_ISSUE_PATTERN is not a POSIX ERE awk can read: '(^|[^A-Za-z0-9_])(()([^A-Za-z0-9_]|\$)'"
)
for line in "${ORDINARY[@]}"; do
  rows+=("ordinary wording passes in index scope: $line|a.rs|// $line\n|||rc=0 $(ok_idx 1)")
  rows+=("ordinary wording passes in staged scope: $line|a.rs|// $line\n||--staged|rc=0 $(ok_stg 1)")
done
run_files "${rows[@]}"

SECTION=settings
echo "=== the tracker pattern resolves from the settings file when the environment has none ==="
fx_toml() { repo toml; put a.rs "// see KEN-12 only\n"; put kendex.settings.toml '[env]\nGH_ISSUE_PATTERN = "ken-[0-9]+"\n'; stage; }
run_rows \
  "the pattern resolves from kendex.settings.toml [env], and the settings file is itself a scanned TOML|fx_toml|-u,GH_ISSUE_PATTERN||rc=1 $(hit "$ID" a.rs 1 " see KEN-12 only");$(idx 1 2)"

SECTION=extract
echo "=== only comment text is judged: strings and code never fire ==="
run_files \
  "every shape inside a string literal passes|a.rs|let s = \"http://x/#228 $W $D\";\n|||rc=0 $(ok_idx 1)" \
  "a // inside a string literal is not a comment|a.rs|let s = \"// $W\";\n|||rc=0 $(ok_idx 1)" \
  "control: a comment after code on the same line is judged|a.rs|let x = 1; // $W\n|||rc=1 $(hit "$ID" a.rs 1 " $W");$(idx 1 1)" \
  "control: a comment after a string that holds a leader is still judged|a.rs|let s = \"//\"; // $W\n|||rc=1 $(hit "$ID" a.rs 1 " $W");$(idx 1 1)" \
  "a block comment is judged, its text the span between the markers|a.rs|/* $W */ fn main() {}\n|||rc=1 $(hit "$ID" a.rs 1 " $W ");$(idx 1 1)" \
  "a block comment spanning lines reports the line the reference sits on, whole|a.rs|/* first line\n second line $W\n third */\n|||rc=1 $(hit "$ID" a.rs 2 " second line $W");$(idx 1 1)" \
  "doc-comment forms are judged like any other comment, their third marker stripped|a.rs|/// $W\n//! $W\nfn main() {}\n|||rc=1 $(hit "$ID" a.rs 1 " $W");$(hit "$ID" a.rs 2 " $W");$(idx 2 1)" \
  "code with a name that contains an ordinary word passes|a.rs|let p = previously_seen(); let n = new_value; // clean\n|||rc=0 $(ok_idx 1)"

SECTION=rust
echo "=== Rust: lifetimes, char literals, raw and multi-line strings ==="
run_files \
  "a lifetime quote opens no string, so the comment after it is still seen|a.rs|fn f<'a>(x: &'a str) -> &'a str { x } // $W\n|||rc=1 $(hit "$ID" a.rs 1 " $W");$(idx 1 1)" \
  "a char literal holding a double quote opens no string|a.rs|let q = '\"'; let n = '\\\\n'; // $W\n|||rc=1 $(hit "$ID" a.rs 1 " $W");$(idx 1 1)" \
  "a raw string with an inner quote and a leader is one string, closed only by its hash|a.rs|let r = r#\"say \"hi // $W\"#;\n|||rc=0 $(ok_idx 1)" \
  "control: the comment after that raw string is judged|a.rs|let r = r#\"say \"hi\"#; // $W\n|||rc=1 $(hit "$ID" a.rs 1 " $W");$(idx 1 1)" \
  "a string continued across lines by a trailing backslash is one string|a.rs|let s = \"line one \\\\\n  // $W \\\\\n  line three\";\n|||rc=0 $(ok_idx 1)" \
  "a Rust string spanning lines without a backslash is one string too|a.rs|let s = \"line one\n  // $W\n  line three\";\n|||rc=0 $(ok_idx 1)" \
  "control: the comment after a multi-line string is judged|a.rs|let s = \"line one\n  line two\";\n// $W\n|||rc=1 $(hit "$ID" a.rs 3 " $W");$(idx 1 1)"

SECTION=js
echo "=== JavaScript: template literals and single quotes ==="
run_files \
  "a template literal spanning lines is one string|a.ts|const t = \`line one\n  // $W\n  line three\`;\n|||rc=0 $(ok_idx 1)" \
  "control: the comment after a template literal is judged|a.ts|const t = \`x\`;\n// $W\n|||rc=1 $(hit "$ID" a.ts 2 " $W");$(idx 1 1)" \
  "a single-quoted string holding a leader is a string|a.ts|const s = '// $W';\n|||rc=0 $(ok_idx 1)" \
  "control: a JavaScript trailing comment is judged|a.ts|const s = \"a\"; // $W\n|||rc=1 $(hit "$ID" a.ts 1 " $W");$(idx 1 1)"

SECTION=hash
echo "=== hash family: word-start hashes, strings, shebang, heredocs ==="
run_files \
  "a hash inside a string is not a comment|a.sh|printf '%s' \"# $W\"\n|||rc=0 $(ok_idx 1)" \
  "a hash glued to a word is not a comment|a.sh|echo \$# \${x#$W} url#$W\n|||rc=0 $(ok_idx 1)" \
  "control: a hash after whitespace opens a comment|a.sh|foo # $W\n|||rc=1 $(hit "$ID" a.sh 1 " $W");$(idx 1 1)" \
  "a shebang is not a comment; the line after it is|a.sh|#!/bin/bash $W\n# $W\n|||rc=1 $(hit "$ID" a.sh 2 " $W");$(idx 1 1)" \
  "only line 1 is a shebang: a second #! line is a comment|a.sh|#!/bin/bash\n#!second $W\n|||rc=1 $(hit "$ID" a.sh 2 "!second $W");$(idx 1 1)" \
  "a backslash in a single-quoted shell string escapes nothing|a.sh|echo 'a\\\\' # $W\n|||rc=1 $(hit "$ID" a.sh 1 " $W");$(idx 1 1)" \
  "a backslash in \$'...' does escape, so the comment after the string is judged|a.sh|echo \$'a\\\\'b' # $W\n|||rc=1 $(hit "$ID" a.sh 1 " $W");$(idx 1 1)" \
  "a heredoc body is not judged; the line after its terminator is|a.sh|cat <<EOF\n# $W\nEOF\n# $W\n|||rc=1 $(hit "$ID" a.sh 4 " $W");$(idx 1 1)" \
  "a quoted <<- heredoc ends at its tab-indented terminator|a.sh|cat <<-'EOF'\n\t# $W\n\tEOF\n# $W\n|||rc=1 $(hit "$ID" a.sh 4 " $W");$(idx 1 1)" \
  "a plain << heredoc is not ended by a tab-indented terminator: it never closes|a.sh|cat <<EOF\n# $W\n\tEOF\n# $W\n|||rc=2 $(skip a.sh 'comment text could not be extracted: a heredoc (terminator EOF) opened at line 1 is never closed ');$(incomplete 1 0 0)$(unread 1)" \
  "an unquoted heredoc word stops at an operator|a.sh|cat <<EOF;echo\n# $W\nEOF\n# $W\n|||rc=1 $(hit "$ID" a.sh 4 " $W");$(idx 1 1)" \
  "a backslash-quoted heredoc word loses its backslash|a.sh|cat <<\\\\EOF\n# $W\nEOF\n# $W\n|||rc=1 $(hit "$ID" a.sh 4 " $W");$(idx 1 1)" \
  "a shift is not a heredoc|a.sh|x=\$((1<<2)) # $W\n|||rc=1 $(hit "$ID" a.sh 1 " $W");$(idx 1 1)" \
  "a shift by a name inside ((...)) opens no heredoc, so the next line is judged|a.sh|x=\$(( 1 << n ))\n# $W\n|||rc=1 $(hit "$ID" a.sh 2 " $W");$(idx 1 1)" \
  "a heredoc word is taken whole, so END-OF terminates the body|a.sh|cat <<END-OF\n# $W\nEND-OF\n# $W\n|||rc=1 $(hit "$ID" a.sh 4 " $W");$(idx 1 1)" \
  "a here-string is not a heredoc|a.sh|read -r x <<<\"y\" # $W\n|||rc=1 $(hit "$ID" a.sh 1 " $W");$(idx 1 1)" \
  "a quote inside a quoted command substitution does not hide the following comment|a.sh|out=\"\$(printf '\"')\"\n# $W\n|||rc=1 $(hit "$ID" a.sh 2 " $W");$(idx 1 1)" \
  "a comment inside a quoted command substitution is judged as shell code|a.sh|out=\"\$(\n# $W\nprintf ok\n)\"\n|||rc=1 $(hit "$ID" a.sh 2 " $W");$(idx 1 1)" \
  "a quoted command substitution stays extractable when its comments are clean|a.sh|out=\"\$(printf '\"$W\"')\"\n|||rc=0 $(ok_idx 1)" \
  "a quoted command substitution never closed is reported at its opener|a.sh|out=\"\$(\n# $W\n|||rc=2 $(skip a.sh 'comment text could not be extracted: a command substitution opened at line 1 is never closed ');$(incomplete 1 0 0)$(unread 1)" \
  "a heredoc token inside an embedded heredoc does not hide the following comment|a.sh|out=\"\$(python3 - <<'PY'\nprint(\"<<'MANIFEST_EOF'\")\nPY\n)\"\n# $W\n|||rc=1 $(hit "$ID" a.sh 5 " $W");$(idx 1 1)" \
  "a heredoc in a quoted command substitution stays extractable when its comments are clean|a.sh|out=\"\$(python3 - <<'PY'\nprint(\"<<'MANIFEST_EOF' $W\")\nPY\n)\"\n|||rc=0 $(ok_idx 1)" \
  "a triple-quoted Python string is one string|a.py|\"\"\"\n# $W\n\"\"\"\n# $W\n|||rc=1 $(hit "$ID" a.py 4 " $W");$(idx 1 1)" \
  "TOML: a hash in a string is not a comment, one after a value is|a.toml|key = \"a # $W\"\nother = 1 # $W\n|||rc=1 $(hit "$ID" a.toml 2 " $W");$(idx 1 1)" \
  "TOML: a triple-quoted string spans lines|a.toml|key = \"\"\"\n# $W\n\"\"\"\n# $W\n|||rc=1 $(hit "$ID" a.toml 4 " $W");$(idx 1 1)" \
  "Ruby: a backslash escapes inside single quotes, so the comment after the string is judged|a.rb|s = 'don\\\\'t' # $W\n|||rc=1 $(hit "$ID" a.rb 1 " $W");$(idx 1 1)" \
  "YAML: a doubled quote ends nothing, and the trailing comment is judged|a.yml|key: 'don''t' # $W\n|||rc=1 $(hit "$ID" a.yml 1 " $W");$(idx 1 1)" \
  "a Makefile is judged by its basename|Makefile|all: # $W\n|||rc=1 $(hit "$ID" Makefile 1 " $W");$(idx 1 1)" \
  "a nested Dockerfile is judged by its basename|sub/Dockerfile|# $W\n|||rc=1 $(hit "$ID" sub/Dockerfile 1 " $W");$(idx 1 1)"
# A row cannot carry a `|`; the two contents that do are fixtures here.
fx_pipe_heredoc() { file pipe-heredoc a.sh "cat <<\"END-OF\" | sort\n# $W\nEND-OF\n# $W\n"; }
fx_pipe_yaml() { file pipe-yaml a.yml "key: |\n  # $W\n"; }
run_rows \
  "a quoted heredoc word is stripped of its quotes and stops before the pipe|fx_pipe_heredoc|||rc=1 $(hit "$ID" a.sh 4 " $W");$(idx 1 1)" \
  "a YAML block scalar is read as code (stated limit)|fx_pipe_yaml|||rc=1 $(hit "$ID" a.yml 2 " $W");$(idx 1 1)"
# The three quoted-substitution fixtures above are valid Bash; the extractor
# is held to shapes the shell accepts.
for content in "out=\"\$(printf '\"')\"\n# $W\n" "out=\"\$(\n# $W\nprintf ok\n)\"\n" "out=\"\$(python3 - <<'PY'\nprint(\"<<'MANIFEST_EOF'\")\nPY\n)\"\n# $W\n"; do
  printf '%b' "$content" >"$TMP/valid.sh"
  assert_eq "fixture: the quoted command substitution is valid Bash" "0" "$(bash -n "$TMP/valid.sh" 2>&1; echo $?)"
done

SECTION=other
echo "=== SQL, Lua, markup, CSS ==="
run_files \
  "SQL: a leader inside a string is a string, the trailing comment is judged, one hit|a.sql|SELECT '-- $W'; -- $W\n|||rc=1 $(hit "$ID" a.sql 1 " $W");$(idx 1 1)" \
  "SQL: a block comment is judged|a.sql|/* $W */ SELECT 1;\n|||rc=1 $(hit "$ID" a.sql 1 " $W ");$(idx 1 1)" \
  "Lua: a block comment is judged|a.lua|--[[ $W\n]] x = 1\n|||rc=1 $(hit "$ID" a.lua 1 " $W");$(idx 1 1)" \
  "markup: text is not judged, a comment is|a.html|<p>$W</p>\n<!-- $W -->\n|||rc=1 $(hit "$ID" a.html 2 " $W ");$(idx 1 1)" \
  "a markup comment spanning lines reports the line the reference sits on|a.svelte|<!-- first\n $W -->\n|||rc=1 $(hit "$ID" a.svelte 2 " $W ");$(idx 1 1)" \
  "CSS: a URL's slashes open no comment|a.css|a { background: url(http://x/$W) } /* clean */\n|||rc=0 $(ok_idx 1)" \
  "control: a CSS block comment is judged|a.css|a { color: red } /* $W */\n|||rc=1 $(hit "$ID" a.css 1 " $W ");$(idx 1 1)"

SECTION=limits
echo "=== every limit CHECKS.md states holds exactly as stated ==="
run_files \
  "a regex literal's escaped slash before its closer reads as a leader (stated limit): the comment text starts there|a.js|const re = /https?:\\\\/\\\\// ; // $W\n|||rc=1 $(hit "$ID" a.js 1 " ; // $W");$(idx 1 1)" \
  "a // inside a regex literal opens a comment (stated limit)|a.js|const re = /x\\\\/\\\\/y/; const t = /a// $W\n|||rc=1 $(hit "$ID" a.js 1 " $W");$(idx 1 1)" \
  "a hash glued to a Python value is read as code (stated limit)|a.py|x = 1#$W\n|||rc=0 $(ok_idx 1)" \
  "a -- inside a Lua long string is read as a comment (stated limit)|a.lua|s = [[ --$W ]]\n|||rc=1 $(hit "$ID" a.lua 1 "$W ]]");$(idx 1 1)" \
  "a nested Rust block comment closes at the first */, so the tail is read as code (stated limit)|a.rs|/* outer /* inner */ $W */\n|||rc=0 $(ok_idx 1)" \
  "a levelled Lua block opener is read as a -- line comment, judged on its own line|a.lua|--[==[ $W\n]==] x = 1\n|||rc=1 $(hit "$ID" a.lua 1 "[==[ $W");$(idx 1 1)" \
  "a line opening two heredocs honours the first: the body after its terminator is judged (stated limit)|a.sh|cat <<A <<B\n# $W\nA\n# $W\nB\n# $W\n|||rc=1 $(hit "$ID" a.sh 4 " $W");$(hit "$ID" a.sh 6 " $W");$(idx 2 1)" \
  "a Ruby heredoc body is read as code, so its hash is a comment (stated limit)|a.rb|s = <<~EOS\n# $W\nEOS\n|||rc=1 $(hit "$ID" a.rb 2 " $W");$(idx 1 1)" \
  "a Makefile recipe's shell is read under the hash grammar with its strings tracked (stated limit)|Makefile|all:\n\techo '# $W'\n|||rc=0 $(ok_idx 1)" \
  "and a hash glued to a dollar is not a comment there either|Makefile|all:\n\techo \$# $W\n|||rc=0 $(ok_idx 1)" \
  "a Vue script block's // is not read (stated limit)|a.vue|<script>// $W</script>\n|||rc=0 $(ok_idx 1)" \
  "control: the markup comment in the same file is judged|a.vue|<template><!-- $W --></template>\n|||rc=1 $(hit "$ID" a.vue 1 " $W ");$(idx 1 1)" \
  "a C string ends at its line, so the continued line's // is a comment (stated limit)|a.c|char *s = \"one \\\\\n  // $W\n  three\";\n|||rc=1 $(hit "$ID" a.c 2 " $W");$(idx 1 1)"

SECTION=unclosed
echo "=== an unextractable file is named, the scan goes on, and the verdict is incomplete ==="
# The extractor's reason is its stderr with newlines turned to spaces, so
# the named line ends in one; the unread count rides on the incomplete
# verdict as on every other.
# A path with no grammar, a symlink and a binary blob are named as unmeasured
# and never counted clean; a shebang read that fails is a collection error.
fx_unclosed_ts() { repo unclosed-ts; put a.ts "const re = /\`/g;\n// $W\n"; put b.rs "// $W\n"; stage; }
fx_shim_head() {
  repo shim-head
  mkdir -p "$R/shim"
  printf '#!/bin/sh\ncase "$1" in -n) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v head)" >"$R/shim/head"
  chmod +x "$R/shim/head"
  put run "#!/usr/bin/env bash\n# $W\n"
  stage
}
fx_link() { repo link; put target.txt "// $W\n"; ln -s target.txt "$R/link.rs"; stage; }
fx_blob() { repo blob; put blob.rs "lead\\0000// $W\n"; stage; }
fx_link_blob() { repo link-blob; put target.txt "// $W\n"; ln -s target.txt "$R/link.rs"; put blob.rs "lead\\0000// $W\n"; stage; }
run_files \
  "a block comment never closed is reported with its opener, not read to the end as one comment|a.c|int x;\n/* open\nint y; // $W\n|||rc=2 $(skip a.c 'comment text could not be extracted: a block comment opened at line 2 is never closed ');$(incomplete 1 0 0)$(unread 1)" \
  "a heredoc never terminated is reported, naming its word|a.sh|cat <<EOF\nbody\n# $W\n|||rc=2 $(skip a.sh 'comment text could not be extracted: a heredoc (terminator EOF) opened at line 1 is never closed ');$(incomplete 1 0 0)$(unread 1)" \
  "control: a string that does close is a string, and the comment after it is judged|a.rs|let s = \"spans\nlines\";\n// $W\n|||rc=1 $(hit "$ID" a.rs 3 " $W");$(idx 1 1)" \
  "an extensionless file the list names is judged under the grammar its shebang picks|run|#!/usr/bin/env bash\n# $W\n|COMMIT_GUARDS_COMMENT_PATHS=run||rc=1 $(hit "$ID" run 2 " $W");$(idx 1 1)" \
  "a python shebang picks the python grammar, where a backslash escapes inside single quotes|run|#!/usr/bin/env python3\ns = 'don\\\\'t' # $W\n|COMMIT_GUARDS_COMMENT_PATHS=run||rc=1 $(hit "$ID" run 2 " $W");$(idx 1 1)" \
  "a node shebang picks the C family with template literals|run|#!/usr/bin/env node\n// $W\n|COMMIT_GUARDS_COMMENT_PATHS=run||rc=1 $(hit "$ID" run 2 " $W");$(idx 1 1)" \
  "a first line naming a shell without #! is not a shebang|run|# start with bash\n# $W\n|COMMIT_GUARDS_COMMENT_PATHS=run||rc=0 $(skip run 'no comment grammar for this path (CHECKS.md § comments)');comments: OK — nothing measurable to scan$(unread 1)" \
  "the same file with no shebang is named as unmeasured, and nothing measurable was scanned|run|# $W\necho hi\n|COMMIT_GUARDS_COMMENT_PATHS=run||rc=0 $(skip run 'no comment grammar for this path (CHECKS.md § comments)');comments: OK — nothing measurable to scan$(unread 1)" \
  "an extension the table does not carry is named, not guessed at|notes.txt|# $W\n|COMMIT_GUARDS_COMMENT_PATHS=*.txt||rc=0 $(skip notes.txt 'no comment grammar for this path (CHECKS.md § comments)');comments: OK — nothing measurable to scan$(unread 1)"
run_rows \
  "a regex literal holding a backtick opens a template literal that never closes (stated limit), and the later file's finding is kept|fx_unclosed_ts|||rc=2 $(skip a.ts 'comment text could not be extracted: a string literal opened at line 1 is never closed ');$(hit "$ID" b.rs 1 " $W");$(incomplete 1 1 1)$(unread 1)" \
  "a shebang read that fails is a collection error, not a path with no grammar|fx_shim_head|PATH=$TMP/shim-head/shim:$PATH,COMMIT_GUARDS_COMMENT_PATHS=run||rc=2 ${ERR}could not read the first line of run" \
  "a symlink at a source path is named as unmeasured|fx_link|||rc=0 $(skip link.rs 'tracked as a symlink, not source');comments: OK — nothing measurable to scan$(unread 1)" \
  "a binary blob at a source path is named as unmeasured|fx_blob|||rc=0 $(skip blob.rs 'binary content, not source');comments: OK — nothing measurable to scan$(unread 1)" \
  "both together are two unmeasured paths and no clean file count|fx_link_blob|||rc=0 $(skip blob.rs 'binary content, not source');$(skip link.rs 'tracked as a symlink, not source');comments: OK — nothing measurable to scan$(unread 2)"

SECTION=scope
echo "=== scope: each default extension is scanned under its family, markdown and JSON are not ==="
rows=()
for f in a.rs a.go a.c a.h a.cc a.cpp a.hpp a.java a.kt a.kts a.swift a.wgsl a.js a.mjs a.cjs a.jsx a.ts a.tsx a.scss a.less; do
  rows+=("$f is in the default scope under the C family|$f|// $W\n# $W\n-- $W\n|||rc=1 $(hit "$ID" "$f" 1 " $W");$(idx 1 1)")
done
for f in a.sh a.bash a.zsh a.py a.rb a.toml a.yml a.yaml deep/a.mk sub/Makefile sub/Dockerfile; do
  rows+=("$f is in the default scope under the hash family|$f|// $W\n# $W\n-- $W\n|||rc=1 $(hit "$ID" "$f" 2 " $W");$(idx 1 1)")
done
for f in a.sql a.lua; do
  rows+=("$f is in the default scope under the dash family|$f|// $W\n# $W\n-- $W\n|||rc=1 $(hit "$ID" "$f" 3 " $W");$(idx 1 1)")
done
for f in a.html a.htm a.xml a.svg a.vue a.svelte; do
  rows+=("$f is in the default scope under the markup family|$f|// $W\n# $W\n<!-- $W -->\n|||rc=1 $(hit "$ID" "$f" 3 " $W ");$(idx 1 1)")
done
rows+=("a.css is in the default scope under the block family|a.css|// $W\n# $W\n/* $W */\n|||rc=1 $(hit "$ID" a.css 3 " $W ");$(idx 1 1)")
run_files "${rows[@]}"
fx_not_ours() { repo not-ours; put README.md "# $W\n<!-- $W -->\n"; put AGENTS.md "<!-- $W -->\n"; put a.json "{\"k\": \"// $W\"}\n"; stage; }
fx_override() { repo override; put a.rs "// $W\n"; put notes.txt "# $W\n"; stage; }
fx_override_none() { repo override-none; put a.rs "// $W\n"; stage; }
fx_override_empty() { repo override-empty; put a.rs "// $W\n"; stage; }
fx_flag_unknown() { repo flag-unknown; put a.rs "// clean\n"; stage; }
fx_flag_bare() { repo flag-bare; put a.rs "// clean\n"; stage; }
run_rows \
  "markdown and JSON are not this lane's: no tracked file matches, and the verdict names the list|fx_not_ours|||rc=0 comments: OK — no tracked file matches COMMIT_GUARDS_COMMENT_PATHS ($(printf '%s' "$(sed -n 's/^GG_COMMENT_PATHS_DEFAULT="\(.*\)"$/\1/p' "$SKILL_DIR/scripts/lib/comment-text.sh")"))" \
  "the override replaces the list: a.rs is no longer scanned, the named file is unmeasured|fx_override|COMMIT_GUARDS_COMMENT_PATHS=*.txt||rc=0 $(skip notes.txt 'no comment grammar for this path (CHECKS.md § comments)');comments: OK — nothing measurable to scan$(unread 1)" \
  "a list matching no tracked file passes, naming the list|fx_override_none|COMMIT_GUARDS_COMMENT_PATHS=no/such/*.rs||rc=0 comments: OK — no tracked file matches COMMIT_GUARDS_COMMENT_PATHS (no/such/*.rs)" \
  "an empty path list is a config error naming how to switch the check off|fx_override_empty|COMMIT_GUARDS_COMMENT_PATHS= ||rc=2 ${ERR}COMMIT_GUARDS_COMMENT_PATHS names no path — name at least one, or drop this check from COMMIT_GUARDS_CHECKS" \
  "an unknown argument is a config error quoting it|fx_flag_unknown||--no-such-flag|rc=2 ${ERR}unknown argument '--no-such-flag' (see --help)" \
  "--excludes with no path is a config error|fx_flag_bare||--excludes|rc=2 ${ERR}--excludes requires a path"

SECTION=excludes
echo "=== excludes: generated trees are excluded with a reason, carves win, the list resolves like the sibling lanes' ==="
planted() { repo "$1"; put vendor/lib.rs "// $W\n"; put gen/out.ts "// $W\n"; stage; } # NAME
fx_exc_none() { planted exc-none; }
fx_exc_row() { planted exc-row; put $EXCL 'vendor/*\tvendored third-party code\n'; stage; }
fx_exc_carve() { planted exc-carve; put $EXCL 'vendor/*\tvendored third-party code\ngen/*\tgenerated\n!gen/out.ts\thand-written after all\n'; stage; }
fx_exc_no_reason() { planted exc-no-reason; put $EXCL 'vendor/*\n'; stage; }
fx_exc_alt() { planted exc-alt; put alt 'vendor/*\tvendored\ngen/*\tgenerated\n'; stage; }
fx_exc_alt_flag() { planted exc-alt-flag; put alt 'vendor/*\tvendored\ngen/*\tgenerated\n'; stage; }
fx_exc_alt_eq() { planted exc-alt-eq; put alt 'vendor/*\tvendored\ngen/*\tgenerated\n'; stage; }
fx_exc_alt_hit() { planted exc-alt-hit; put alt 'vendor/*\tvendored\n'; stage; }
run_rows \
  "control: both planted files fail without a row, in index order|fx_exc_none|||rc=1 $(hit "$ID" gen/out.ts 1 " $W");$(hit "$ID" vendor/lib.rs 1 " $W");$(idx 2 2)" \
  "the row silences exactly the vendored tree|fx_exc_row|||rc=1 $(hit "$ID" gen/out.ts 1 " $W");$(idx 1 1)" \
  "a ! row carves its path back into the scanned set|fx_exc_carve|||rc=1 $(hit "$ID" gen/out.ts 1 " $W");$(idx 1 1)" \
  "a row without a reason is a config error naming the line|fx_exc_no_reason|||rc=2 ${ERR}$EXCL:1: expected 'pattern<TAB>reason' (every exclusion carries its justification)" \
  "the list path resolves through the environment key, and the remedy would name it|fx_exc_alt|COMMIT_GUARDS_COMMENT_EXCLUDES=alt||rc=0 comments: OK — no tracked file matches COMMIT_GUARDS_COMMENT_PATHS ($(sed -n 's/^GG_COMMENT_PATHS_DEFAULT="\(.*\)"$/\1/p' "$SKILL_DIR/scripts/lib/comment-text.sh"))" \
  "--excludes names the same list|fx_exc_alt_flag||--excludes alt|rc=0 comments: OK — no tracked file matches COMMIT_GUARDS_COMMENT_PATHS ($(sed -n 's/^GG_COMMENT_PATHS_DEFAULT="\(.*\)"$/\1/p' "$SKILL_DIR/scripts/lib/comment-text.sh"))" \
  "the remedy and the summary name the list in force|fx_exc_alt_hit||--excludes alt|rc=1 $(hit "$ID" gen/out.ts 1 " $W" alt);$(idx 1 1 alt)" \
  "--excludes=PATH is the same flag|fx_exc_alt_eq||--excludes=alt|rc=0 comments: OK — no tracked file matches COMMIT_GUARDS_COMMENT_PATHS ($(sed -n 's/^GG_COMMENT_PATHS_DEFAULT="\(.*\)"$/\1/p' "$SKILL_DIR/scripts/lib/comment-text.sh"))"

SECTION=staged
echo "=== --staged judges the lines the commit adds, with comment state from the whole file ==="
# A block comment the commit did not open, and a committed reference the
# commit does not touch.
seeded() { repo "$1"; put ok.rs '/* a block comment that\n   spans lines */\nfn main() {}\n'; stage; commit; put fixture.rs "// committed $W\n"; stage; commit fixture; } # NAME
fx_stg_block() { seeded stg-block; put ok.rs "/* a block comment that\n   $W\n   spans lines */\nfn main() {}\n"; git -C "$R" add ok.rs; }
fx_stg_clean() { seeded stg-clean; put ok.rs '/* a block comment that\n   spans lines */\nfn main() {}\nfn other() {}\n'; git -C "$R" add ok.rs; }
fx_stg_index() { seeded stg-index; }
fx_stg_bytes() { seeded stg-bytes; put ok.rs "fn main() {} // $W\n"; git -C "$R" add ok.rs; put ok.rs 'fn main() {}\n'; }
fx_stg_untouched() { seeded stg-untouched; put fixture.rs "// committed $W\nfn added() {}\n"; git -C "$R" add fixture.rs; }
fx_stg_unclosed() { seeded stg-unclosed; put ok.rs "int x;\n/* open\n"; git -C "$R" add ok.rs; }
fx_stg_rename() { seeded stg-rename; git -C "$R" mv fixture.rs moved.rs; }
fx_stg_moved() { seeded stg-moved; git -C "$R" mv fixture.rs moved.rs; put moved.rs "// committed $W\n// and $W again\n"; git -C "$R" add moved.rs; }
fx_stg_first() { repo stg-first; put a.rs "// $W\n"; stage; }
fx_stg_first_clean() { repo stg-first-clean; put a.rs '// clean\n'; stage; }
fx_stg_md() { repo stg-md; put notes.md "# $W\n"; stage; }
fx_stg_nogrammar() { repo stg-nogrammar; put run "# $W\necho hi\n"; stage; }
fx_stg_vendor() { repo stg-vendor; put vendor/v.rs "// $W\n"; put $EXCL 'vendor/*\tvendored\n'; stage; }
fx_stg_vendor_none() { repo stg-vendor-none; put vendor/v.rs "// $W\n"; stage; }
run_rows \
  "a line added inside a block comment the commit did not open is judged at its line, the untouched fixture out of the verdict|fx_stg_block||--staged|rc=1 $(hit "$ID" ok.rs 2 "   $W");$(stg 1)" \
  "a commit adding no reference passes on a repository whose index holds one|fx_stg_clean||--staged|rc=0 $(ok_stg 1)" \
  "control: the index scan still refuses the committed reference|fx_stg_index|||rc=1 $(hit "$ID" fixture.rs 1 " committed $W");$(idx 1 2)" \
  "staged bytes decide, whatever the work tree says now|fx_stg_bytes||--staged|rc=1 $(hit "$ID" ok.rs 1 " $W");$(stg 1)" \
  "a hit on a line the commit did not touch is not this commit's, though the file is read whole|fx_stg_untouched||--staged|rc=0 $(ok_stg 1)" \
  "a staged file that cannot be extracted makes the staged verdict incomplete, exit 2|fx_stg_unclosed||--staged|rc=2 $(skip ok.rs 'comment text could not be extracted: a block comment opened at line 2 is never closed ');$(incomplete 1 0 0)$(unread 1)" \
  "a pure rename adds no line and reads no file|fx_stg_rename||--staged|rc=0 $(ok_stg 0)" \
  "a file that moved and changed is read whole|fx_stg_moved||--staged|rc=1 $(hit "$ID" moved.rs 1 " committed $W");$(hit "$ID" moved.rs 2 " and $W again");$(stg 2)" \
  "on a repository's first commit the whole staged tree reads as added|fx_stg_first||--staged|rc=1 $(hit "$ID" a.rs 1 " $W");$(stg 1)" \
  "control: a clean first commit passes, not exit 2 for want of a HEAD|fx_stg_first_clean||--staged|rc=0 $(ok_stg 1)" \
  "--staged honours the path list: markdown is not read|fx_stg_md||--staged|rc=0 $(ok_stg 0)" \
  "--staged names a path with no grammar as unmeasured, never judged|fx_stg_nogrammar|COMMIT_GUARDS_COMMENT_PATHS=run|--staged|rc=0 $(skip run 'no comment grammar for this path (CHECKS.md § comments)');$(ok_stg 0)$(unread 1)" \
  "--staged honours the exclusion list|fx_stg_vendor||--staged|rc=0 $(ok_stg 0)" \
  "control: without the row the staged vendored comment fails|fx_stg_vendor_none||--staged|rc=1 $(hit "$ID" vendor/v.rs 1 " $W");$(stg 1)"

SECTION=dispatch
echo "=== the dispatcher knows the lane and hands it --staged; the default batch omits it ==="
fx_dispatch() { repo dispatch; put ok.rs 'fn main() {}\n'; stage; commit; put a.rs "// $W\n"; stage; }
BIN="$GG"
fx_dispatch
assert_eq "'commit-guards comments' reaches the lane" "rc=1 $(hit "$ID" a.rs 1 " $W");$(idx 1 2)" "$(run "" comments)"
assert_eq "the batch hands comments --staged at commit scope" "rc=1 === commit-guards: comments --staged;$(hit "$ID" a.rs 1 " $W");$(stg 1);commit-guards: violations — see the failures above" "$(run COMMIT_GUARDS_CHECKS=comments 'all --staged')"
DEFAULT_BATCH="$(run "" "")"
assert_eq "the default batch passes on this tree" "rc=0" "${DEFAULT_BATCH%% *}"
assert_eq "and does not run the lane" "" "$(printf '%s' "$DEFAULT_BATCH" | tr ';' '\n' | grep 'commit-guards: comments' || true)"
BIN="$CM"

echo "=== the usage is answered ==="
repo help
assert_eq "--help prints the usage and exits 0" "rc=0 usage: comments [--staged] [--excludes FILE]" "$(run "" --help | cut -d';' -f1)"
assert_eq "-h is the same flag" "$(run "" --help)" "$(run "" -h)"

echo "=== the skill's own shipped shell scans clean under its own lane ==="
repo self
mkdir -p "$R/skills/commit-guards/scripts/lib"
cp "$SKILL_DIR/scripts/comments" "$R/skills/commit-guards/scripts/comments"
cp "$SKILL_DIR/scripts/lib/comment-text.sh" "$SKILL_DIR/scripts/lib/staged-lines.sh" "$R/skills/commit-guards/scripts/lib/"
cp "$TEST_DIR/comments.test.sh" "$R/skills/commit-guards/comments.test.sh"
stage
assert_eq "the lane, its libraries and this suite carry no history in their comments" "rc=0 $(ok_idx 4)" "$(run 'COMMIT_GUARDS_COMMENT_PATHS=*.sh skills/*/scripts/*' "")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
