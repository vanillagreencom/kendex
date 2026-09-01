#!/usr/bin/env bash
# ---
# name: block-repo-copy
# event: PreToolUse
# matcher: Bash
# description: Block a copy (cp, rsync, tar, local git clone) whose source names a `.git` or `target` directory and whose destination is under /tmp, /var/tmp or $TMPDIR. Suggests reading the source in place or building a minimal fixture.
# safety: Temp destinations are commonly RAM-backed tmpfs; a multi-gigabyte tree copy fills the filesystem and every process writing there then fails with ENOSPC. One regex over the raw command decides, in the order the words stand, so nothing is resolved, expanded or stat-ed: a source whose last path component is `.git` or `target` is expensive by construction, and a destination spelled under a temp root is scratch. A source reached through a variable, and a repository named only by its working-tree path, are not seen. The reading runs the other way too: the three parts count wherever they stand, a quoted string and a comment tail included, so a read-only command spelling out a copy is refused as the copy it is not.
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
# root. `/?["'"'"'[:space:]]` is what keeps the source component last, so
# `target/debug/kendex` — one binary out of a build tree — is not a tree copy.
# `(.*[[:space:]])?` before the destination is what keeps the destination a
# word of its own, so `/home/tmp/x` is not `/tmp`.
#
# The shell tokenizer this replaced resolved every operand and stat-ed it for
# marker directories, to catch a source spelled as a working-tree path or
# reached through a variable. Those are not seen here, and that is the trade:
# it is the frozen lexical-scanner class, and a finding of that shape against
# this file is declined, not patched.
BLOCK_RE='(^|[^[:alnum:]_.-])(cp|rsync|tar|git[[:space:]]+clone)[[:space:]].*(\.git|target)/?["'"'"'[:space:]](.*[[:space:]])?["'"'"']?(/tmp|/var/tmp|\$\{TMPDIR\}|\$TMPDIR)(/|["'"'"'[:space:]]|$)'

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
