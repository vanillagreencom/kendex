#!/usr/bin/env bash
# ---
# name: block-repo-copy
# event: PreToolUse
# matcher: Bash
# description: Block a copy (cp, rsync, tar, git clone) whose source names a `.git` or `target` path component and whose destination is under /tmp, /var/tmp or $TMPDIR. Suggests reading the source in place or building a minimal fixture.
# summary: Stops executable copies of .git or target into temporary folders. Ordinary quoted arguments and proven simple data-reader here-documents pass; here-documents with groups, control operators or substitutions can warn or refuse on guarded text.
# safety: Advisory reader: dependency or payload failures warn once and allow the call. Executable command matches retain exit 2. The commit-guards command-position reader selects command words and masks quoted data and proven simple data-reader here-document bodies. Here-documents with groups, control operators or substitutions can warn or refuse when their bodies hold guarded text. This is a lexical check; assembled command names and unknown launcher option forms are outside its contract. Every diagnostic starts with block-repo-copy: <key>=<value>.
# requires-skills: [commit-guards]
# ---

set -euo pipefail
trap 'rc=$?; case $rc in 0 | 2) ;; *) refuse exit "$rc" ;; esac' EXIT

# The command as it was read, empty until the reader has it: the refusal quotes
# it, and a refusal can be reached before it is set.
COMMAND=""
# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `block-repo-copy: <key>=<value>`: a
# stable key for the condition and the value acted on — the missing tool, why
# the payload could not be read, or the copy verb the command spelled. The
# English explanation and the alternatives follow on later lines.
# The keyed line stands first, at position 1. What a command this hook runs
# wrote is captured where the hook reads it and passed here as the cause, so
# it is replayed under the key rather than ahead of it.
refuse() { # KEY VALUE [CAUSE]
  printf 'block-repo-copy: %s=%s\n' "$1" "$2" >&2
  case "$1=$2" in
    missing-tools=*)
      echo "the commands ${2//,/, } are required to read the hook payload and are not on PATH; this check is unavailable" >&2
      ;;
    payload=invalid-json)
      echo "the hook payload is not valid JSON, or names a command that is not a string; this check is unavailable" >&2
      ;;
    refused=*)
      echo "Refusing a copy of a repository or build tree into scratch space." >&2
      echo "  command: $COMMAND" >&2
      echo >&2
      echo "A source whose last component is .git or target is large by construction, and" >&2
      echo "temp/scratch filesystems are commonly RAM-backed tmpfs — the copy can fill the" >&2
      echo "filesystem, after which every process writing there fails with ENOSPC." >&2
      echo >&2
      echo "Do one of these instead:" >&2
      echo "  - Read the source in place. Reading does not mutate it, so no copy is needed" >&2
      echo "    to leave it unchanged." >&2
      echo "  - Build a MINIMAL synthetic fixture:" >&2
      echo '      d=$(mktemp -d); mkdir -p "$d/repo/.git" "$d/repo/target"; touch "$d/repo/f"' >&2
      ;;
  esac
  # The cause a command this hook ran wrote, captured at the site and replayed
  # here: under the keyed line, never ahead of it.
  [ -z "${3:-}" ] || printf '%s\n' "$3" >&2
  case "$1" in
    refused | path) exit 2 ;;
    *)
      echo "Check skipped. Repair the hook installation, tools or payload adapter; retry the command." >&2
      exit 0 ;;
  esac
}

# jq is the only reader of the payload. Without it the command cannot be read,
# and a command this hook has not read cannot be shown not to be the copy. The value
# names every one of them the PATH is missing, in the order checked.
MISSING=""
for dependency in jq cat; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"

INPUT=$(cat 2>&1) || refuse payload unreadable "$INPUT"

# A payload that does not parse, or that names a command which is not a
# string, produces a warning and allows the call. An absent command is the empty
# string and passes. The command is read where each harness carries it:
# `tool_input.command` (Claude Code, Codex, Gemini CLI and the Pi carrier), a
# bare `command`, or Copilot's `toolArgs.command`, whose `toolArgs` arrives as
# an object or as one JSON-encoded string. The null tests are spelled out
# because jq's `//` reads `false` as absent, and `false` is not a command
# either.
COMMAND=$(printf '%s' "$INPUT" \
  | jq -er 'def copilot: .toolArgs
             | if . == null then null elif type == "string" then fromjson else . end
             | if . == null then null elif type == "object" then .command else error end;
           if .tool_input.command != null then .tool_input.command
           elif .command != null then .command
           elif copilot != null then copilot
           else "" end
           | if type == "string" then . else error end' 2>/dev/null) ||
  refuse payload invalid-json

# Resolve only this hook's installed dependency, never a payload-selected path.
reader=""
for candidate in "${BASH_SOURCE[0]%/*}/../skills/commit-guards/scripts/lib/command-position.sh" \
  "${BASH_SOURCE[0]%/*}/../.agents/skills/commit-guards/scripts/lib/command-position.sh" \
  "${BASH_SOURCE[0]%/*}/../../.agents/skills/commit-guards/scripts/lib/command-position.sh" \
  "${BASH_SOURCE[0]%/*}/../../../.agents/skills/commit-guards/scripts/lib/command-position.sh" \
  "${BASH_SOURCE[0]%/*}/../../skills/commit-guards/scripts/lib/command-position.sh" \
  "${HOME:+$HOME/.agents/skills/commit-guards/scripts/lib/command-position.sh}"; do
  if [ -f "$candidate" ]; then reader=$candidate; break; fi
done
[ -n "$reader" ] || refuse reader unavailable
# shellcheck source=../skills/commit-guards/scripts/lib/command-position.sh
source "$reader" 2>/dev/null || refuse reader unreadable
# The tar create-to-extract pipeline retains its destination.
ENDERS='&;'$'\n'
CROSSABLE="[^${ENDERS}]"
# BLANK is the class name as it is spelled INSIDE a bracket expression, so the
# one definition serves a class of its own and a member of a larger one.
BLANK='[:blank:]'
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
# Every character in this class is one that stops ending the word, so this guard
# fails closed by holding only what a row can bind: the alnum run that makes
# `/tmpfoo` a different directory, and the slash a path continues with. Only
# the FIRST character after the temp root is ever consulted, so a member is
# provable one row at a time — punctuation was cut rather than carried
# untested, and the `/tmp-old` it costs is a row in the stated limits.
PATH_CHAR='[:alnum:]/'
END_EDGE="[^${PATH_CHAR}]"
MARKER='(\.git|target)'
DEST='(/tmp|/var/tmp|\$\{TMPDIR\}|\$TMPDIR)'
BLOCK_RE="(^)${VERB}(${GAP}|${JOIN})(${RUN}(${LEFT_EDGE}|${JOIN}))?${MARKER}/?${RIGHT_EDGE}(${RUN}(${GAP}|${JOIN}))?${QUOTE}?${DEST}(/|${END_EDGE}|\$)"

command_segments "$COMMAND" pipes
while IFS= read -r segment; do
  remaining=$segment
  while :; do
    command_text "${remaining%%|*}"
    selected=${COMMAND_TEXTS%"$NL"}
    selections=$COMMAND_TEXTS
    if [[ $remaining == *"|"* ]]; then
      receiver=${remaining#*|}
      receiver_head=${receiver#"${receiver%%[![:space:]]*}"}
      command_text "${receiver%%|*}"
      if [[ $receiver_head == "$MASK_OPEN"* ]]; then
        # Inspect the receiver with the same reader. Only actual cd and tar
        # commands can connect the sender to a temporary extraction directory.
        # Other copy commands in the group keep their own checks.
        receiver_text=$COMMAND_TEXTS
        directory=""
        command_segments "$receiver_text"
        while IFS= read -r receiving; do
          command_text "$receiving"
          selections=$selections$COMMAND_TEXTS
          while IFS= read -r receiving_command; do
            case "$receiving_command" in
              cd[[:space:]]*) directory=$receiving_command ;;
              tar[[:space:]]*)
                if [[ $selected == tar[[:space:]]* ]]; then
                  selections=$selections$selected" "$receiving_command" "$directory$NL
                fi ;;
            esac
          done <<<"$COMMAND_TEXTS"
        done <<<"$SEGMENTS"
      elif [[ $selected == tar[[:space:]]* && $COMMAND_TEXTS == tar[[:space:]]* ]]; then
        # A direct tar receiver carries its own destination argument.
        command_text "$remaining"
        selections=$COMMAND_TEXTS
      fi
    fi
    while IFS= read -r selected; do
      if [[ $selected =~ $BLOCK_RE ]]; then
        VERB_HIT=${BASH_REMATCH[2]}
        case "$VERB_HIT" in
          *[[:space:]]*) VERB_HIT="${VERB_HIT%%[[:space:]]*} ${VERB_HIT##*[[:space:]]}" ;;
        esac
        refuse refused "$VERB_HIT"
      fi
    done <<<"$selections"
    [[ $remaining == *"|"* ]] || break
    remaining=${remaining#*|}
  done
done <<<"$SEGMENTS"
exit 0
