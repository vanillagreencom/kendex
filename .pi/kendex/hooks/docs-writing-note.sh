#!/usr/bin/env bash
# ---
# name: docs-writing-note
# event: PreToolUse
# matcher: Edit|MultiEdit|Write
# description: On the first Markdown edit of a session, hands the session the edited file's docs-writing type and the paths of that type's reference and example, as the commit-guards md-type lane installed in this hook's own scope routes them, once per session. The first line is `docs-writing-note: path=<file> type=<type>`, or `type=unclassified` naming the route table in docs-writing's SKILL.md. Later Markdown edits of the session, any other edit, a git-ignored file and a file outside a repository get nothing. A Claude Code subagent counts as its own session. Codex reports the edit as apply_patch, and the hook reads the patch's Add, Update, Move and Delete headers, excluding deleted files and taking a moved file by its destination; a Codex subagent shares its lead's session. Not run on copilot: preToolUse has no measured additionalContext delivery to the model. Not run on gemini: the BeforeTool edit payload and context delivery are unmeasured. Not run on opencode: it executes no hook commands. Not run on cursor: it reads hooks as advisory prose and executes no edit event. Not run on antigravity: its toolCall.args payload has no tool_input.file_path reader here.
# summary: Points the assistant at the docs-writing rules and example for the first Markdown file it edits in a session. Deleted files need no reminder, and every edit remains allowed.
# safety: Advisory reader. Reads the tool payload. Runs `git rev-parse` in the session's directory to bound its install walk. Runs only the commit-guards md-type installed with this hook, never one found from the edited path; md-type reads the edited repository's installed docs-writing files as data and runs `git rev-parse` and `git check-ignore` there. Writes one marker file per session under the XDG state directory, and prunes markers older than 30 days. Missing tools, an unreadable payload, a missing judge or an unwritable marker produce a keyed notice at exit 0. Uses additionalContext on stdout because successful stderr does not reach the Claude Code model.
# timeout: 10
# harnesses: [claude, codex, pi]
# requires-skills: [docs-writing]
# ---

set -euo pipefail

# A reader failure must never refuse the edit, including an unexpected status.
trap 'status=$?; trap - EXIT; if [ "$status" -ne 0 ]; then notice payload reader-failed; fi; exit 0' EXIT

NOTICE_PREFIX=""
notice() { # KEY VALUE [DETAIL]
  local text encoded bs=\\ q='"' octal char escaped
  printf -v text 'docs-writing-note: %s=%s' "$1" "$2"
  [ -z "${3:-}" ] || text="$text"$'\n'"$3"
  [ -z "$NOTICE_PREFIX" ] || text="$NOTICE_PREFIX"$'\n'"$text"
  # Builtins keep the advisory context available when jq is missing or broken.
  encoded=${text//"$bs"/"$bs$bs"}
  encoded=${encoded//"$q"/"$bs$q"}
  for octal in 001 002 003 004 005 006 007 010 011 012 013 014 015 016 017 \
      020 021 022 023 024 025 026 027 030 031 032 033 034 035 036 037; do
    printf -v char '%b' "\\0$octal"
    printf -v escaped '\\u%04x' "0$octal"
    encoded=${encoded//"$char"/$escaped}
  done
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$encoded"
}

MISSING=""
for dependency in jq cat; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || { notice missing-tools "${MISSING#,}"; exit 0; }
INPUT=$(cat 2>&1) || { notice payload unreadable "$INPUT"; exit 0; }
TOOL=$(jq -r '.tool_name | strings | select(length > 0)' 2>&1 <<<"$INPUT") ||
  { notice reader tool-name "$TOOL"; exit 0; }
[ -n "$TOOL" ] || { notice payload invalid-json; exit 0; }

# The edited files, one per line. apply_patch names them in its patch
# headers: Codex writes absolute paths there, and a relative one is read
# against the session's directory. A rename is an Update header followed at
# once by a Move header, and the file it leaves is the destination, so the
# pair yields that path alone.
case "$TOOL" in
  Edit | MultiEdit | Write)
    TARGETS=$(jq -r '.tool_input.file_path | strings | select(length > 0)' 2>&1 <<<"$INPUT") ||
      { notice reader target "$TARGETS"; exit 0; }
    ;;
  apply_patch)
    TARGETS=$(jq -r '.tool_input.command | strings' 2>&1 <<<"$INPUT") ||
      { notice reader target "$TARGETS"; exit 0; }
    TARGETS=$(printf '%s\n' "$TARGETS" | awk '
      function flush() { if (held != "") { print held; edited = 1 }; held = "" }
      /^\*\*\* Add File: / { flush(); print substr($0, 15); edited = 1; next }
      /^\*\*\* Update File: / { flush(); held = substr($0, 18); next }
      /^\*\*\* Move to: / { held = substr($0, 14); flush(); next }
      /^\*\*\* Delete File: / { flush(); deleted = 1; next }
      { flush() }
      END { flush(); if (deleted && !edited) exit 3 }' 2>&1) ||
      { [ "$?" -ne 3 ] || exit 0; notice reader patch-headers "$TARGETS"; exit 0; }
    ;;
  *) notice payload unknown-tool; exit 0 ;;
esac
[ -n "$TARGETS" ] || { notice payload no-file-path; exit 0; }
BASE=$(jq -r '.cwd | strings | select(length > 0)' 2>/dev/null <<<"$INPUT") || BASE=""
[ -n "$BASE" ] || BASE=$PWD
TARGET=""
while IFS= read -r candidate; do
  case "$candidate" in
    *.md)
      case "$candidate" in /*) ;; *) candidate="$BASE/$candidate" ;; esac
      TARGET=$candidate
      break
      ;;
  esac
done <<<"$TARGETS"
[ -n "$TARGET" ] || exit 0

# One reminder per session: a Claude Code subagent carries its own agent_id
# and counts apart; a Codex subagent carries its lead's session_id.
KEY=$(jq -r '[.session_id, .agent_id] | map(strings | select(length > 0)) | join(".")' 2>/dev/null <<<"$INPUT") || KEY=""
KEY_STATE=ok
case "$KEY" in
  "") KEY_STATE=no-session-id ;;
  .* | *[!A-Za-z0-9._-]*) KEY_STATE=session-id-invalid ;;
esac
STATE_DIR="${XDG_STATE_HOME:-${HOME:-}/.local/state}/kendex/docs-writing-note"
if [ "$KEY_STATE" = ok ] && [ -e "$STATE_DIR/$KEY" ]; then exit 0; fi

# The harness this copy was installed for, from where kendex renders it,
# for the marker.
HOOK_DIR=$(cd -- "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd -P) || HOOK_DIR=""
case "$HOOK_DIR" in
  */.claude/hooks) HARNESS=claude ;;
  */.codex/hooks | "${CODEX_HOME:-/nonexistent}/hooks") HARNESS=codex ;;
  */.pi/agent/kendex/hooks | */.pi/kendex/hooks | "${PI_CODING_AGENT_DIR:-/nonexistent}/kendex/hooks") HARNESS=pi ;;
  "") HARNESS=unknown ;;
  *) HARNESS=source ;;
esac
# The skills come from this hook's own install, never from the edited path,
# which a clone or another project controls. The walk goes from the hook's
# physical directory up five levels, each level's `skills/` and shared
# `.agents/skills/` tree, which reaches a harness's own copy delivery such as
# ~/.codex/skills, stopping after the open repository's root and after the
# home directory; then the home's shared tree, for a harness root CODEX_HOME
# or PI_CODING_AGENT_DIR moved out of the home. At the root only
# `.agents/skills/` is read: a repository's own `skills/` is a catalog's
# source tree, not an install (docs/adapters/README.md). This departs from
# hooks/lane-mail-check.sh's reader walk, which stops before the root and
# reads the root's `.agents/skills/` last, after the home's tree: here a hook
# installed in the repository takes the repository's install before any
# global one, while a global hook never reaches that root.
HOME_DIR=$(cd -- "${HOME:-/}" 2>/dev/null && pwd -P) || HOME_DIR=""
ROOT=$(git -C "$BASE" rev-parse --show-toplevel 2>/dev/null) || ROOT=""
in_scope() { # SKILL — the skill's directory in this hook's install; 1 when none
  local at="$HOOK_DIR" levels=0 candidate
  [ -n "$at" ] || return 1
  while [ "$levels" -lt 5 ] && [ "$at" != / ]; do
    for candidate in "$at/skills/$1" "$at/.agents/skills/$1"; do
      [ "$at" != "$ROOT" ] || [ "$candidate" = "$at/.agents/skills/$1" ] || continue
      if [ -d "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
    [ "$at" != "$ROOT" ] && [ "$at" != "$HOME_DIR" ] || break
    at=${at%/*}
    [ -n "$at" ] || at=/
    levels=$((levels + 1))
  done
  if [ -n "$HOME_DIR" ] && [ "$HOME_DIR" != "$ROOT" ] && [ -d "$HOME_DIR/.agents/skills/$1" ]; then
    printf '%s\n' "$HOME_DIR/.agents/skills/$1"
    return 0
  fi
  return 1
}

if [ "$KEY_STATE" != ok ]; then
  # With no usable session key the first edit cannot be known, so every
  # Markdown edit gets the route.
  NOTICE_PREFIX="docs-writing-note: payload=$KEY_STATE"
fi

ROUTE=""
ROUTE_STATUS=0
JUDGE=""
if GUARDS=$(in_scope commit-guards); then JUDGE="$GUARDS/scripts/md-type"; fi
if [ -n "$JUDGE" ] && [ -f "$JUDGE" ]; then
  ROUTE=$("$BASH" "$JUDGE" --route "$TARGET" 2>&1) || ROUTE_STATUS=$?
else
  ROUTE_STATUS=judge-missing
fi
route_field() { # KEY — md-type's value for KEY
  local line
  while IFS= read -r line; do
    case "$line" in "md-type: $1="*) printf '%s' "${line#"md-type: $1="}"; return 0 ;; esac
  done <<<"$ROUTE"
  return 1
}
if [ "$ROUTE_STATUS" = 0 ]; then
  case "$(route_field route || true)" in
    ignored | outside-repo) exit 0 ;;
  esac
fi

# The marker is the record of a firing, written by the exclusive create that
# decides the session's one reminder, so a second call racing this one
# prints nothing.
MARKER_NOTE=""
if [ "$KEY_STATE" = ok ]; then
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || NOW=unknown
  created=0
  if (umask 077 && mkdir -p -- "$STATE_DIR") 2>/dev/null; then
    if (set -C; printf 'harness=%s session=%s path=%s at=%s\n' "$HARNESS" "$KEY" "$TARGET" "$NOW" >"$STATE_DIR/$KEY") 2>/dev/null; then
      created=1
    elif [ -e "$STATE_DIR/$KEY" ]; then
      exit 0
    fi
  fi
  if [ "$created" -eq 1 ]; then
    find "$STATE_DIR" -type f -mtime +30 -delete 2>/dev/null || MARKER_NOTE="docs-writing-note: marker=prune-failed"
  else
    MARKER_NOTE="docs-writing-note: marker=unwritable"
  fi
fi

ONCE="This note is shown once per session."
[ "$KEY_STATE" = ok ] || ONCE="This note repeats on each Markdown edit, because the payload names no usable session."
if [ "$ROUTE_STATUS" = 0 ] && TYPE=$(route_field type) && REFERENCE=$(route_field reference); then
  EXAMPLE=$(route_field example || true)
  DETAIL="Before you finish this Markdown edit, read $REFERENCE${EXAMPLE:+ and $EXAMPLE}. Check the file against them. $ONCE"
  notice path "$TARGET type=$TYPE" "$DETAIL${MARKER_NOTE:+$'\n'$MARKER_NOTE}"
  exit 0
fi
if [ "$ROUTE_STATUS" = 0 ] && SKILL_FILE=$(route_field skill); then
  notice path "$TARGET type=unclassified" "Before you finish this Markdown edit, find its type in the route table under ## Per file type in $SKILL_FILE, then read that type's reference and example. $ONCE${MARKER_NOTE:+$'\n'$MARKER_NOTE}"
  exit 0
fi

# No route: name why, and send the session to the route table in this
# scope's docs-writing.
SKILL_FILE=""
if DOCS=$(in_scope docs-writing); then SKILL_FILE="$DOCS/SKILL.md"; fi
if [ "$ROUTE_STATUS" = judge-missing ]; then
  KEYED_KEY=judge
  KEYED_VALUE=missing
  CAUSE="The commit-guards md-type lane is not installed in this hook's scope, so the file's type was not classified."
else
  KEYED_KEY=route
  KEYED_VALUE=failed
  CAUSE="md-type --route exited $ROUTE_STATUS:"$'\n'"$ROUTE"
fi
DETAIL="docs-writing-note: path=$TARGET"$'\n'"$CAUSE"$'\n'"Before you finish this Markdown edit, find its type in the route table under ## Per file type in ${SKILL_FILE:-the installed docs-writing SKILL.md}, then read that type's reference and example. $ONCE"
notice "$KEYED_KEY" "$KEYED_VALUE" "$DETAIL${MARKER_NOTE:+$'\n'$MARKER_NOTE}"
exit 0
