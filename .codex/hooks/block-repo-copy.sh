#!/usr/bin/env bash
# ---
# name: block-repo-copy
# event: PreToolUse
# matcher: Bash
# description: Block a copy (cp, rsync, tar, git clone) whose source names a `.git` or `target` path component and whose destination is under /tmp, /var/tmp or $TMPDIR. Suggests reading the source in place or building a minimal fixture.
# safety: Temp destinations are commonly RAM-backed tmpfs; a multi-gigabyte tree copy fills the filesystem and every process writing there then fails with ENOSPC. One regex over the raw command decides, in the order the words stand, so nothing is resolved, expanded or stat-ed: a source whose last path component IS `.git` or `target` is expensive by construction, and a destination spelled under a temp root is scratch. Both edges of that component are tested, so a word merely ending in one — a `…/bar.git` clone URL, a `build-target` directory — is not it. A source reached through a variable, and a repository named only by its working-tree path, are not seen; neither is a `tar -czf DEST SRC`, which spells the destination before the source. The reading runs the other way too: the three parts count wherever they stand, a quoted string and a comment tail included, so a read-only command spelling out a copy is refused as the copy it is not.
# ---

set -euo pipefail

# jq is the only reader of the payload. Without it the command cannot be read,
# and a command this hook has not read cannot be shown not to be the copy.
if ! command -v jq >/dev/null 2>&1 || ! command -v cat >/dev/null 2>&1; then
  echo "block-repo-copy: jq and cat are required to read the hook payload; refusing rather than skipping the guard" >&2
  exit 2
fi

INPUT=$(cat)

# A payload that does not parse, or that names a command which is not a
# string, is refused rather than skipped. An absent command is the empty
# string and passes. The null tests are spelled out because jq's `//` reads
# `false` as absent, and `false` is not a command either.
if ! COMMAND=$(printf '%s' "$INPUT" \
  | jq -r 'if .tool_input.command == null then (if .command == null then "" else .command end)
           else .tool_input.command end
           | if type == "string" then . else error end' 2>/dev/null); then
  echo "block-repo-copy: hook payload is not valid JSON, or names a command that is not a string; refusing rather than skipping the guard" >&2
  exit 2
fi

# The whole rule, in the order the words stand: a copy verb, then a word whose
# last path component is `.git` or `target`, then a destination under a temp
# root. ENDERS says where one command ends and the next begins. How far a scan
# may REACH once inside one is the separate question RUN and GAP answer, and
# both are derived from ENDERS, so the two answers cannot drift apart:
#
#   ENDERS    the characters that END one command here: `;`, `&` and a
#             newline. The pipe is deliberately NOT one of them, because
#             `tar -cf - SRC | tar -xf - -C DEST` is one copy written across a
#             pipe and the scan has to reach the destination on its far side.
#   CROSSABLE any character but ENDERS — the ordinary text a scan crosses to
#             get from one part of the copy to the next.
#   JOIN      the two newlines that do NOT end a command: one a backslash
#             escapes, and one standing after a pipe. Each binds the words on
#             either side of it into ONE command, so a copy wrapped over two
#             lines — how a long tar or rsync is normally written — is one copy
#             still. It SEPARATES those words as well: it stands between them
#             the way a GAP does, and it is the only separator left when the
#             continuation is not indented.
#   RUN       CROSSABLE or JOIN, repeated: everything one command may hold
#             between two of its own words. A BARE newline is in neither half,
#             so three unrelated commands on three lines are three commands.
#   GAP       the whitespace standing between two words of ONE command:
#             horizontal whitespace and nothing else, since the only
#             whitespace character in ENDERS is the newline.
#
# END_EDGE answers a different question and is NOT derived from ENDERS: where
# the destination WORD ends, not where a command does. Every character that is
# not part of a path answers it — the pipe ENDERS leaves out on purpose, a
# subshell's closing parenthesis, the newline that is still whitespace here —
# so it is stated as the negation of PATH_CHAR, what a path may hold. That way
# a separator nobody has named yet ends the word without being added to a list.
#
# Both edges of the marker component are tested and both carry a case: the
# `/?` and quote-or-GAP after it are what keep it last, so `target/debug/kendex`
# — one binary out of a build tree — is not a tree copy; the optional RUN
# ending in a slash, quote or GAP before it is what makes it a component of its
# own, so a `…/bar.git` clone URL and a `build-target` directory are not the
# marker. That run is OPTIONAL because the one mandatory separator after the
# verb is itself the left edge when the marker is the first operand, as in
# `git clone .git /tmp/scratch`; requiring a second separator there would let a
# whole local clone through. The run before the destination is what keeps the
# destination a word of its own, so `/home/tmp/x` is not `/tmp`. Every one of
# those separators but the marker's RIGHT edge takes a JOIN as well as its own
# class, because a binding newline is where a word ends when a wrapped line is
# not indented, and without them the same copy reaches different verdicts for
# its indentation alone. That right edge does not, and must not: a backslash
# there has no blank before it, so bash removes the continuation and joins the
# two words into one operand — `cp -r repo/.git\` and `/tmp/x` on the next line
# is `cp -r repo/.git/tmp/x`, which names no destination and copies nothing.
#
# The shell tokenizer this replaced resolved every operand and stat-ed it for
# marker directories, to catch a source spelled as a working-tree path or
# reached through a variable. Those are not seen here, and that is the trade:
# it is the frozen lexical-scanner class, and a finding of that shape against
# this file is declined, not patched.
# The ampersand leads so this string does not spell bash 4's case fall-through
# operator, which tools/bash32-lint flags in string data too. A bracket
# expression carries no order, so the set below is the set named above.
ENDERS='&;'$'\n'
CROSSABLE="[^${ENDERS}]"
# BLANK and SPACE_ANY are the class names as they are spelled INSIDE a bracket
# expression, so the same two definitions serve a class of their own and a
# member of a larger one.
BLANK='[:blank:]'
SPACE_ANY='[:space:]'
GAP="[${BLANK}]"
# The backslash is doubled twice over: once for the double quotes, once for the
# regex, so this alternative is a literal backslash or a literal pipe followed
# by the newline it binds.
JOIN="(\\\\|\\|[${BLANK}]*)"$'\n'
RUN="(${CROSSABLE}|${JOIN})*"
QUOTES="\"'"
QUOTE="[${QUOTES}]"
VERB="(cp|rsync|tar|git${GAP}+clone)"
LEFT_EDGE="[/${QUOTES}${BLANK}]"
RIGHT_EDGE="[${QUOTES}${BLANK}]"
# Every character ADDED here is one that stops ending the word, so this guard
# fails closed by holding only what a row can bind: the alnum run that makes
# `/tmpfoo` a different directory, and the slash a path continues with. Only
# the FIRST character after the temp root is ever consulted, so a member is
# provable one row at a time — punctuation was cut rather than carried
# untested, and the `/tmp-old` it costs is a row in the stated limits.
PATH_CHAR='[:alnum:]/'
END_EDGE="[^${PATH_CHAR}]"
MARKER='(\.git|target)'
DEST='(/tmp|/var/tmp|\$\{TMPDIR\}|\$TMPDIR)'
BLOCK_RE="(^|[^[:alnum:]_.-])${VERB}(${GAP}|${JOIN})(${RUN}(${LEFT_EDGE}|${JOIN}))?${MARKER}/?${RIGHT_EDGE}(${RUN}(${GAP}|${JOIN}))?${QUOTE}?${DEST}(/|${END_EDGE}|\$)"

if [[ ! $COMMAND =~ $BLOCK_RE ]]; then
  exit 0
fi

{
  echo "Refusing a copy of a repository or build tree into scratch space."
  echo "  command: $COMMAND"
  echo
  echo "A source whose last component is .git or target is large by construction, and"
  echo "temp/scratch filesystems are commonly RAM-backed tmpfs — the copy can fill the"
  echo "filesystem, after which every process writing there fails with ENOSPC."
  echo
  echo "Do one of these instead:"
  echo "  - Read the source in place. Reading does not mutate it, so no copy is needed"
  echo "    to leave it unchanged."
  echo "  - Build a MINIMAL synthetic fixture:"
  echo '      d=$(mktemp -d); mkdir -p "$d/repo/.git" "$d/repo/target"; touch "$d/repo/f"'
} >&2
exit 2
