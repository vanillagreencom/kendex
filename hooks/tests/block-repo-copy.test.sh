#!/usr/bin/env bash
# Tests for the block-repo-copy hook.
#
# One regex decides, and it has three parts in the order the words stand: a
# copy verb, a source word whose last path component is `.git` or `target`, and
# a destination under /tmp, /var/tmp or $TMPDIR. Each part is varied
# independently below, so a change that dropped one of them reds here rather
# than scoring on the other two. Nothing is resolved or stat-ed, so there are no
# filesystem fixtures: the command's own text is the whole input.
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls
# (a no-op hook, an always-block hook) can be run against these same
# assertions.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/block-repo-copy.sh}"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
ERR_FILE="$TMP_ROOT/stderr"
BASH_BIN="$(command -v bash)"

assert_eq() {
  if [[ "$1" == "$2" ]]; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$3" "$2" "$1"; fi
}
assert_contains() {
  if [[ "$1" == *"$2"* ]]; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected to contain: %s\n        got:      %s\n' "$3" "$2" "$1"; fi
}

# The command reaches the hook JSON-encoded, exactly as the harness sends it.
# jq does the encoding rather than sed: a Bash tool call is routinely several
# lines, and a raw newline inside a JSON string is not JSON, so a sed-built
# fixture could not express the multi-line rows at all.
json_for() {
  jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'
}

run_hook() { # command -> rc, stderr in $err
  set +e
  json_for "$1" | "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE"
  rc=$?
  set -e
  err="$(cat "$ERR_FILE")"
}

run_payload() { # raw-json [PATH] -> rc, stderr in $err
  set +e
  if [ -n "${2:-}" ]; then
    printf '%s' "$1" | env -i HOME="$HOME" PWD="$PWD" PATH="$2" "$BASH_BIN" "$HOOK" \
      >/dev/null 2>"$ERR_FILE"
  else
    printf '%s' "$1" | "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE"
  fi
  rc=$?
  set -e
  err="$(cat "$ERR_FILE")"
}

REPO=/home/agent/dev/project

echo "=== block-repo-copy: every copy verb reaches the same verdict ==="
run_hook "cp -r $REPO/.git /tmp/copy";                 assert_eq "$rc" 2 'cp of a .git directory into /tmp is refused'
run_hook "rsync -a $REPO/target /tmp/copy";            assert_eq "$rc" 2 'rsync of a build tree into /tmp is refused'
run_hook "git clone $REPO/.git /tmp/copy";             assert_eq "$rc" 2 'a local git clone into /tmp is refused'
run_hook "tar -cf - $REPO/target | tar -xf - -C /tmp"; assert_eq "$rc" 2 'a tar create-to-extract pipe into /tmp is refused'
# The same pipe as it is normally written once it is long: the newline after
# the `|` does not end the command, so the destination on the far side is
# still this copy's.
run_hook "$(printf 'tar -cf - %s/target |\n  tar -xf - -C /tmp' "$REPO")"
assert_eq "$rc" 2 'and wrapping that pipe after the | is still one copy'
# The same wrap one space later. The newline may stand at any distance from the
# `|`, which is what an editor leaves when a long pipe is wrapped by hand, so
# the blanks between them are a class of their own and this row is what pins it.
run_hook "$(printf 'tar -cf - %s/target | \n  tar -xf - -C /tmp' "$REPO")"
assert_eq "$rc" 2 'and a blank between the | and the newline does not unbind it'
run_hook "mkdir -p /tmp/x && cp -a $REPO/.git /tmp/x"; assert_eq "$rc" 2 'the copy is found in a chained command'
# The verb is a word, not a substring: a path in front of it is a prefix the
# class allows, a letter is not.
run_hook "/usr/bin/cp -r $REPO/.git /tmp/x";           assert_eq "$rc" 2 'an absolute path in front of the verb is still the verb'
run_hook "scp -r $REPO/.git /tmp/x";                   assert_eq "$rc" 0 'a word merely ending in the verb is not the verb'

echo "=== block-repo-copy: the source half of the predicate ==="
run_hook "cp -r $REPO/target/ /tmp/copy";      assert_eq "$rc" 2 'a trailing slash does not hide the component'
run_hook "cp -r \"$REPO/spaced dir/.git\" /tmp/copy"; assert_eq "$rc" 2 'a quoted source path containing a space is still read'
# Same verb, same destination, a source that is neither marker: the source half
# is what decides. Without this row, refusing every copy into /tmp would score.
run_hook "cp -r $REPO/docs /tmp/copy";         assert_eq "$rc" 0 'a source naming neither .git nor target is copied freely'
run_hook "cp $REPO/target/debug/kendex /tmp/kendex"; assert_eq "$rc" 0 'one file out of a build tree is not a tree copy'
# The other edge of the same component. Without these a pattern that only
# pinned the right edge would score, and a remote clone — the cheap way to get
# a repository into scratch — would be refused with no rewrite available.
run_hook "git clone --depth 1 https://github.com/o/r.git /tmp/r"; assert_eq "$rc" 0 'a clone URL merely ending in .git is not a .git component'
run_hook "cp -r /home/agent/dl/mytarget /tmp/x"; assert_eq "$rc" 0 'a word merely ending in target is not the build tree'
run_hook "rsync -a build-target/ /tmp/out";    assert_eq "$rc" 0 'a hyphenated name ending in target is not it either'
# The marker standing as the FIRST operand, whose left edge is the one
# separator after the verb. The clone URL and build-target rows above are the
# passing partners: the same words, one character later, are not the marker.
run_hook "cp .git /tmp/x";                     assert_eq "$rc" 2 'a marker as the first operand is still the marker'
run_hook "git clone .git /tmp/scratch";        assert_eq "$rc" 2 'a local clone of the repository into scratch is refused'

echo "=== block-repo-copy: the destination half of the predicate ==="
run_hook "cp -r $REPO/.git /var/tmp/copy";   assert_eq "$rc" 2 '/var/tmp is a scratch destination'
run_hook 'cp -r '"$REPO"'/.git $TMPDIR/keep';   assert_eq "$rc" 2 'an unexpanded $TMPDIR destination is a scratch destination'
run_hook 'cp -r '"$REPO"'/.git ${TMPDIR}/keep'; assert_eq "$rc" 2 'the braced form of the same variable is too'
run_hook "cp -r $REPO/.git /tmp";            assert_eq "$rc" 2 'the temp root itself is a scratch destination'
# The one place a newline is still whitespace: it ends the destination word.
# Every other run in the pattern refuses to cross one.
run_hook "$(printf 'cp -r %s/.git /tmp\necho done' "$REPO")"
assert_eq "$rc" 2 'a newline ends the destination word rather than reaching past it'
# A destination ends where its PATH ends, so this row stands for every
# character that is not one a path may hold. The closing parenthesis is the
# member of that class no list of separators would have carried: it is not a
# quote, not whitespace, and not one of ENDERS, which answers where a COMMAND
# ends rather than where this word does.
run_hook "cp -r $REPO/.git /tmp)"
assert_eq "$rc" 2 'a destination ends where the path ends, not at a listed separator'
run_hook "cp -r $REPO/.git \"/tmp/x\"";      assert_eq "$rc" 2 'a quoted destination is still the destination'
# Same verb, same source, a destination outside every temp root: the
# destination half is what decides, and its trailing boundary is what keeps
# the root a component rather than a prefix.
run_hook "cp -r $REPO/.git /srv/archive/keepme"; assert_eq "$rc" 0 'a repository copied outside scratch is allowed'
run_hook "cp -r $REPO/.git /home/agent/tmp/x";   assert_eq "$rc" 0 'a temp root spelled inside a longer path is not the temp root'
run_hook "cp -r $REPO/.git /tmpfoo/x";           assert_eq "$rc" 0 'nor is one a longer first component merely starts with'

echo "=== block-repo-copy: one copy, not three commands ==="
# A `;`, an `&` and a BARE newline end a command, so unrelated commands
# standing beside each other do not add up to one copy. Each pair differs only
# in whether the three parts stand within one command. A newline a backslash
# escapes, and a newline after a pipe, are the two that do not end one: they
# bind their two lines into a single copy, and the two rows below the pairs are
# theirs.
run_hook "$(printf 'cp README.md /home/me/out\necho target\necho /tmp')"
assert_eq "$rc" 0 'a verb, a marker and a temp path on three lines are three commands'
run_hook "$(printf 'ls /home/me\ncp -r %s/.git /tmp/x' "$REPO")"
assert_eq "$rc" 2 'and a copy standing whole on the second line is refused'
run_hook "cp -r $REPO/.git /srv/keep; ls /tmp"; assert_eq "$rc" 0 'a semicolon ends the copy before the temp path'
run_hook "cp -r $REPO/.git /tmp/keep; ls /srv"; assert_eq "$rc" 2 'and a copy whole before the semicolon is refused'
# The rows above reach their verdict at the marker's right edge, which admits
# no newline, so neither the newline nor the `&` is what decided them. These
# three put a BLANK after the marker word so the scan gets past that edge and
# the separator itself is the only thing left to decide; the one-line row is
# the refusing partner for both, being the same words with the separator
# spelled as a space.
run_hook "$(printf 'cp README.md /home/me/out\necho target x\necho /tmp')"
assert_eq "$rc" 0 'a newline between the parts still ends the command before it'
run_hook 'cp README.md /home/me/out & echo target x & echo /tmp'
assert_eq "$rc" 0 'an ampersand ends it the same way'
run_hook 'cp README.md /home/me/out echo target x echo /tmp'
assert_eq "$rc" 2 'and the same words within one command are one copy'
# The two newlines that bind rather than end. Each has the multi-line pair
# above as its partner: the same wrapping, one character earlier.
run_hook "$(printf 'cp -r %s/.git \\\n  /tmp/copy' "$REPO")"
assert_eq "$rc" 2 'a backslash continuation before the destination is one copy'
# The same copy with the continuation unindented. The separator standing before
# the destination is then the binding newline itself and no blank follows it,
# so this row and the indented one above are what keep the two spellings from
# reaching different verdicts. The row after it is the marker's left edge read
# the same way: the marker as the first operand, whose left edge is the binding
# newline once the operand opens the continuation line. The one-line partner of
# that row is the first-operand row in the source section above.
run_hook "$(printf 'cp -r %s/.git \\\n/tmp/copy' "$REPO")"
assert_eq "$rc" 2 'and the destination alone at column 0 is the same one copy'
run_hook "$(printf 'cp -r \\\n.git /tmp/x')"
assert_eq "$rc" 2 'a marker opening the continuation line is still the marker'
# The third separator that takes a JOIN: the one after the verb. It has no
# blank before the backslash, which is what makes the binding newline the only
# separator there — with a blank, the GAP alone already carries this row.
run_hook "$(printf 'cp\\\n -r %s/.git /tmp/x' "$REPO")"
assert_eq "$rc" 2 'a continuation abutting the verb is the separator after it'
run_hook "$(printf 'rsync -a \\\n  %s/target \\\n  /tmp/out' "$REPO")"
assert_eq "$rc" 2 'and so is an rsync wrapped over three lines'
# A doubled pipe is two pipes: the first is crossed as ordinary text because the
# pipe is the one separator deliberately left out of ENDERS, and the second
# carries the binding newline. So a wrapped or-list binds exactly as a single
# pipe does, and its fallback's temp path is read as this copy's destination —
# the same trade as the redirection row below, recorded here so revisiting the
# pipe decision reds rather than moving this shape in silence.
run_hook "$(printf 'cp -r %s/.git /srv/keep ||\n  echo /tmp' "$REPO")"
assert_eq "$rc" 2 'a wrapped or-list binds across the || as one command'

echo "=== block-repo-copy: commands that are not copies at all ==="
run_hook "git status --short";               assert_eq "$rc" 0 'a non-copy command passes'
run_hook "ls -la $REPO/.git /tmp";           assert_eq "$rc" 0 'reading a repository next to a scratch path is not a copy'
run_hook "grep -rn target /tmp/build.log";   assert_eq "$rc" 0 'a word merely containing tar is not the verb'
run_hook "cargo build --target x86_64-unknown-linux-gnu"; assert_eq "$rc" 0 'a --target flag is not a source operand'

echo "=== block-repo-copy: the refusal names the cause and the alternatives ==="
run_hook "cp -r $REPO/target /tmp/copy"
assert_contains "$err" "cp -r $REPO/target /tmp/copy" 'the refusal quotes the command it judged'
assert_contains "$err" "ENOSPC" 'the refusal names the failure the copy causes'
assert_contains "$err" "Read the source in place" 'the refusal offers reading in place'
assert_contains "$err" "MINIMAL synthetic fixture" 'the refusal offers a minimal fixture'
assert_contains "$err" 'mktemp -d' 'the refusal shows how to build the fixture'

echo "=== block-repo-copy: a payload it cannot read refuses ==="
run_payload "{\"tool_input\":{\"command\":\"cp -r $REPO/.git /tmp/copy"
assert_eq "$rc" 2 'a truncated JSON payload refuses rather than skipping the guard'
assert_contains "$err" 'not valid JSON' 'the parse refusal names the cause'
run_payload '{"tool_input":{"command":123}}'
assert_eq "$rc" 2 'a command that is not a string refuses'
run_payload '{"tool_input":{"command":false}}'
assert_eq "$rc" 2 'a command of false refuses, not read as an absent one'
run_payload '{"tool_name":"Bash","tool_input":{}}'
assert_eq "$rc" 0 'a payload naming no command passes'
run_payload '{"tool_input":{"command":""}}'
assert_eq "$rc" 0 'an empty command is read, not a read failure'
# The harness sends the command under tool_input; a payload naming it at the
# top level is read the same way, and that fallback is a branch of its own.
run_payload "{\"command\":\"cp -r $REPO/.git /tmp/copy\"}"
assert_eq "$rc" 2 'a top-level command field is read like a nested one'

NOJQ_BIN="$TMP_ROOT/nojq"
mkdir -p "$NOJQ_BIN"
# type -P, not command -v: cat and friends are shell functions in some
# interactive environments, and a function name symlinks to nothing.
for tool in cat sed grep; do
  real="$(type -P "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && [ -x "$real" ] || continue
  ln -sf "$real" "$NOJQ_BIN/$tool"
done
run_payload "{\"tool_input\":{\"command\":\"cp -r $REPO/.git /tmp/copy\"}}" "$NOJQ_BIN"
assert_eq "$rc" 2 'no jq refuses rather than guessing at the payload'
assert_contains "$err" 'required to read the hook payload' 'the refusal names what is missing'
run_payload "{\"tool_input\":{\"command\":\"git status --short\"}}" /nonexistent
assert_eq "$rc" 2 'no text tools at all refuses too, whatever the command'

# cat is the other half of the same guard: jq reads the payload, cat is what
# hands it over. A PATH holding jq and not cat is what tells the two apart.
NOCAT_BIN="$TMP_ROOT/nocat"
mkdir -p "$NOCAT_BIN"
for tool in jq sed grep; do
  real="$(type -P "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && [ -x "$real" ] || continue
  ln -sf "$real" "$NOCAT_BIN/$tool"
done
run_payload "{\"tool_input\":{\"command\":\"git status --short\"}}" "$NOCAT_BIN"
assert_eq "$rc" 2 'no cat refuses rather than skipping the guard'
assert_contains "$err" 'required to read the hook payload' 'the refusal names what is missing'
# The control that the exact PATH is what decided: the same benign command
# passes once cat is on it.
ln -sf "$(type -P cat)" "$NOCAT_BIN/cat"
run_payload "{\"tool_input\":{\"command\":\"git status --short\"}}" "$NOCAT_BIN"
assert_eq "$rc" 0 'and the same PATH with cat added passes'

echo "=== block-repo-copy: the stated limits ==="
# Reading the command's text rather than resolving its operands costs in both
# directions, and every cost is a row so nobody grows a tokenizer back to close
# one. A source spelled as the working tree that HOLDS the repository is not
# seen; neither is a tar that spells its destination before its source, which
# is why the create-to-extract pipe above is the tar form worth having; and a
# copy spelled inside a quoted string is read as the copy it is not.
run_hook "cp -r $REPO /tmp/copy"
assert_eq "$rc" 0 'a repository named by its working-tree path is not seen'
# The other half of the same trade: nothing here resolves or expands an
# operand, so a source the command reaches through a variable carries no
# marker text to read and the copy is not seen.
run_hook 'cp -r "$SRC" /tmp/x'
assert_eq "$rc" 0 'a source reached through a variable is not seen'
run_hook "tar -czf /tmp/repo.tgz $REPO/.git"
assert_eq "$rc" 0 'a tar naming its destination before its source is not seen'
run_hook "echo \"cp -r $REPO/.git /tmp/copy\" >>notes.md"
assert_eq "$rc" 2 'a copy spelled inside a quoted string is refused as the copy it is not'
# The comment tail is the same reading: the whole command text is read, so the
# three parts count where they stand after a `#` and a read-only command
# carrying a copy in its comment is refused as the copy it is not.
run_hook "ls -la $REPO  # cp -r $REPO/.git /tmp/copy"
assert_eq "$rc" 2 'and so is one spelled in a comment tail'
# The run between the marker and the destination crosses everything that is
# not an ender, the pipe being only the one deliberately left out of ENDERS. A
# redirection standing between them is crossed too, so a temp path that is a
# log rather than the copy's destination is read as the destination.
run_hook "cp -r $REPO/target /srv/keep > /tmp/copy.log"
assert_eq "$rc" 2 'a temp path reached across a redirection is read as the destination'
# PATH_CHAR is what a row can bind, not everything a filename may take, so a
# sibling directory spelled with punctuation reads as the temp root and a
# hyphen ends the word. The cost runs the safe way — a copy outside scratch
# refused, never one into it allowed — and widening PATH_CHAR reds this row.
run_hook "cp -r $REPO/.git /tmp-old/x"
assert_eq "$rc" 2 'a sibling of the temp root spelled with punctuation is refused with it'

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
