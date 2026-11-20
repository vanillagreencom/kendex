#!/usr/bin/env bash
# ---
# name: ui-copy-note
# event: PostToolUse
# matcher: Edit|MultiEdit|Write|Bash
# description: Gives the session the installed code-quality UI copy reference after the first matching edit attempt. Successful Claude Code Bash calls check tracked changes across the checkout, including changes already present. Matches each path relative to its project against QA_UI_PATHS. When the setting is unset or empty, the fallback is *.qml *.tsx *.jsx *.vue *.svelte. Codex apply_patch renames use the destination and deletions are skipped. Not run on pi: delivery is tracked in KEN-5303. Not run on copilot: postToolUse has no measured additionalContext delivery to the model. Not run on gemini: the AfterTool edit payload and context delivery are unmeasured. Not run on opencode: it executes no hook commands. Not run on cursor: it executes no edit event. Not run on antigravity: its toolCall.args payload has no reader here.
# summary: Points the assistant at the UI copy rules on the first matching edit attempt or Claude Code Bash result with matching tracked changes.
# safety: Advisory reader. The standard installed settings loader resolves the effective QA_UI_PATHS value from the process environment and the edited project's settings and private env data. Claude Code Bash calls also read tracked Git status. Writes a session marker under the XDG state directory and prunes markers older than 30 days. Reader or marker failures produce keyed context at exit 0.
# timeout: 10
# harnesses: [claude, codex]
# requires-skills: [code-quality, decider]
# ---

set -euo pipefail

context() { # TEXT
  local text=$1 encoded bs=\\ q='"' octal char escaped
  # Keep the additionalContext envelope available even when jq fails.
  encoded=${text//"$bs"/"$bs$bs"}
  encoded=${encoded//"$q"/"$bs$q"}
  for octal in 001 002 003 004 005 006 007 010 011 012 013 014 015 016 017 \
      020 021 022 023 024 025 026 027 030 031 032 033 034 035 036 037; do
    printf -v char '%b' "\\0$octal"
    printf -v escaped '\\u%04x' "0$octal"
    encoded=${encoded//"$char"/$escaped}
  done
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$encoded"
}

notice() { # KEY VALUE [DETAIL]
  local detail=${3:-}
  context "ui-copy-note: $1=$2${detail:+$'\n'$detail}"
}

trap 'status=$?; trap - EXIT; if [ "$status" -ne 0 ]; then notice reader unexpected; fi; exit 0' EXIT

command -v jq >/dev/null 2>&1 || { notice missing-tool jq; exit 0; }
# Headers occupy three lines. The last field can contain an entire patch.
PAYLOAD=$(jq -ers '
  def header: strings | if test("[\r\n]") then error("newline in payload header") else . end;
  if length != 1 or (.[0] | type) != "object" then error("expected one tool payload") else .[0] end
  | (.tool_name | header | select(length > 0)) as $tool
  | ((.session_id | strings) // "") as $session
  | [ $tool,
      (if $session == "" then "" else
        [$session, (.agent_id | strings | select(length > 0))] | join(".")
      end | if test("[\r\n]") then "" else . end),
      ((.cwd | header) // ""),
      ((.tool_input | objects | if $tool == "apply_patch" then .command else .file_path end | strings) // "")
    ] | join("\n") + "\u001f"' 2>&1) || { notice reader payload "$PAYLOAD"; exit 0; }
TOOL=${PAYLOAD%%$'\n'*}
PAYLOAD=${PAYLOAD#*$'\n'}
KEY=${PAYLOAD%%$'\n'*}
case "$KEY" in '' | .* | *[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._-]*) KEY='' ;; esac
STATE_DIR="${XDG_STATE_HOME:-${HOME:-}/.local/state}/kendex/ui-copy-note"
[ -z "$KEY" ] || [ ! -e "$STATE_DIR/$KEY" ] || exit 0

case "$TOOL" in Edit | MultiEdit | Write | apply_patch | Bash) ;; *) exit 0 ;; esac

physical_dir() { (cd -P -- "$1" && pwd -P); }
PAYLOAD=${PAYLOAD#*$'\n'}
BASE=${PAYLOAD%%$'\n'*}
BASE=${BASE:-$PWD}
TARGETS=${PAYLOAD#*$'\n'}
TARGETS=${TARGETS%$'\037'}

HOOK_PATH=${BASH_SOURCE[0]}
HOME_PATH=${HOME:-/nonexistent}
case "$OSTYPE" in
  msys* | cygwin* | win32*)
    HOME_PATH=${USERPROFILE:-$HOME_PATH}
    HOME_PATH=${HOME_PATH//\\//}
    HOOK_PATH=${HOOK_PATH//\\//}
    absolute_root='^([A-Za-z]:/|//[^/]+/[^/]+)'
    ;;
  *) absolute_root='^/' ;;
esac
[[ "$HOOK_PATH" == /* || "$HOOK_PATH" =~ $absolute_root ]] || { notice reader install-layout; exit 0; }
HOME_DIR=$(physical_dir "$HOME_PATH" 2>/dev/null) || HOME_DIR=''
SHARED_ROOT=$HOME_DIR
PROJECT_INSTALL=''
CODEX_ROOT=${CODEX_HOME-$HOME_PATH/.codex}
CLAUDE_ROOT="$HOME_PATH/.claude"

# Global identity takes precedence when aliases land both registrations on
# the same script. Project ownership comes from the renderer's argv spelling.
if [ -n "$CODEX_ROOT" ] && [ "$HOOK_PATH" -ef "$CODEX_ROOT/hooks/ui-copy-note.sh" ]; then
  NATIVE_ROOT=$CODEX_ROOT
  HARNESS=codex
elif [ "$HOOK_PATH" -ef "$CLAUDE_ROOT/hooks/ui-copy-note.sh" ]; then
  NATIVE_ROOT=$CLAUDE_ROOT
  HARNESS=claude
else
  case "$HOOK_PATH" in
    */.claude/hooks/ui-copy-note.sh) PROJECT_INSTALL=${HOOK_PATH%/.claude/hooks/ui-copy-note.sh}; HARNESS=claude ;;
    */.codex/hooks/ui-copy-note.sh) PROJECT_INSTALL=${HOOK_PATH%/.codex/hooks/ui-copy-note.sh}; HARNESS=codex ;;
    *) notice reader install-layout; exit 0 ;;
  esac
  PROJECT_INSTALL=$(physical_dir "${PROJECT_INSTALL:-/}" 2>&1) ||
    { notice reader install-layout "$PROJECT_INSTALL"; exit 0; }
  NATIVE_ROOT="${PROJECT_INSTALL%/}/.$HARNESS"
  SHARED_ROOT=$PROJECT_INSTALL
fi

installed() { # SKILL FILE — only this hook's native and shared skill roots
  local relative="$1/$2"
  if [ -f "$NATIVE_ROOT/skills/$relative" ]; then
    printf '%s\n' "$NATIVE_ROOT/skills/$relative"
  elif [ -n "$SHARED_ROOT" ] && [ -f "$SHARED_ROOT/.agents/skills/$relative" ]; then
    printf '%s\n' "$SHARED_ROOT/.agents/skills/$relative"
  else
    return 1
  fi
}

# A Git worktree, explicit kendex project, or the scope of this project
# registration can own settings. Walk from the edited file, including when
# a session edits a sibling checkout admitted by Claude Code's add-dir.
project_root() { # PHYSICAL-DIRECTORY
  local dir=$1
  while [ -n "$dir" ] && [ "$dir" != "$HOME_DIR" ]; do
    if [ "$dir" = "$PROJECT_INSTALL" ] || [ -e "$dir/.git" ] ||
        [ -f "$dir/kendex.toml" ] || [ -f "$dir/.kendex-lock.json" ] ||
        [ -e "$dir/kendex.settings.toml" ] || [ -L "$dir/kendex.settings.toml" ] ||
        [ -e "$dir/.kendex/settings.toml" ] || [ -L "$dir/.kendex/settings.toml" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir=${dir%/*}
  done
  return 1
}

bash_targets() ( # GIT-ROOT
  local root=$1 porcelain failure paths
  porcelain=$(mktemp 2>&1) || { printf 'git-status-scratch\n%s\n' "$porcelain"; return 1; }
  trap 'rm -f -- "$porcelain"' EXIT
  failure=$(LC_ALL=C git --no-optional-locks -C "$root" status --porcelain=v1 -z \
    --untracked-files=no --no-renames 2>&1 >"$porcelain") ||
    { printf 'git-status\n%s\n' "$failure"; return 1; }
  paths=$(jq -Rrs --arg root "$root" 'split("\u0000")[] | select(length > 3) |
    select(.[0:2] | contains("D") | not) | $root + "/" + .[3:]' <"$porcelain" 2>&1) ||
    { printf 'git-porcelain\n%s\n' "$paths"; return 1; }
  printf '%s\n' "$paths"
)

case "$TOOL" in
  Edit | MultiEdit | Write)
    [ -n "$TARGETS" ] || { notice reader target 'The edit payload has no file path.'; exit 0; }
    ;;
  apply_patch)
    [ -n "$TARGETS" ] || { notice reader patch 'The apply_patch payload has no command.'; exit 0; }
    command -v awk >/dev/null 2>&1 || { notice missing-tool awk; exit 0; }
    TARGETS=$(awk '
      function flush() { if (update != "") print update; update = "" }
      /^\*\*\* Move to: / && update != "" { update = substr($0, 14); flush(); next }
      { flush() }
      /^\*\*\* Add File: / { seen = 1; print substr($0, 15) }
      /^\*\*\* Update File: / { seen = 1; update = substr($0, 18) }
      /^\*\*\* Delete File: / { seen = 1 }
      END { flush(); if (!seen) exit 3 }' 2>&1 <<<"$TARGETS") ||
      { notice reader patch-headers "$TARGETS"; exit 0; }
    [ -n "$TARGETS" ] || exit 0
    ;;
  Bash)
    [ "$HARNESS" = claude ] || exit 0
    command -v git >/dev/null 2>&1 || { notice missing-tool git; exit 0; }
    GIT_ROOT=$(LC_ALL=C git -C "$BASE" rev-parse --show-toplevel 2>&1) || {
      case "$GIT_ROOT" in *'not a git repository'*) exit 0 ;; esac
      notice reader git-root "$GIT_ROOT"
      exit 0
    }
    # The Bash payload names the command, not which files it wrote. As in
    # docs-writing-note, use tracked, non-deleted status after the call.
    TARGETS=$(bash_targets "$GIT_ROOT" 2>&1) ||
      { notice reader "${TARGETS%%$'\n'*}" "${TARGETS#*$'\n'}"; exit 0; }
    [ -n "$TARGETS" ] || exit 0
    ;;
esac

edited_file() { # PATH — resolve the parent, including parents yet to be made
  local path=$1 parent suffix
  case "$path" in /*) ;; *) path="$BASE/$path" ;; esac
  parent=${path%/*}
  suffix=/${path##*/}
  while [ ! -d "${parent:-/}" ]; do
    case "${parent##*/}" in . | .. | '') return 2 ;; esac
    suffix="/${parent##*/}$suffix"
    parent=${parent%/*}
  done
  parent=$(physical_dir "${parent:-/}") || return 2
  printf '%s' "${parent%/}$suffix"
}

# QA_UI_PATHS follows the orch runtime's record-qa-decision matcher
# (skills/orch/runtime/src/ops/qa.rs); this hook keeps its own copy until a
# runtime verb answers the match.
shopt -s extglob
ANY_DIRS='@(*/|)'
MATCH=''
ISSUES='' LOADED_ROOT=''
reader_issue() { # KEY VALUE [CAUSE]
  local cause=${3:-}
  ISSUES="${ISSUES:+$ISSUES$'\n'}ui-copy-note: $1=$2${cause:+$'\n'$cause}"
}
while IFS= read -r candidate; do
  if ! file=$(edited_file "$candidate" 2>&1); then
    reader_issue reader path "${file:-Could not resolve the parent directory.}"
    continue
  fi
  root=$(project_root "${file%/*}") || continue
  if [ "$root" != "$LOADED_ROOT" ]; then
    LOADED_ROOT=$root
    GLOBS=()
    READER=$(installed decider scripts/lib/kendex-env.sh) ||
      { reader_issue settings reader-missing; continue; }
    SETTING=$( (
      # shellcheck source=../skills/decider/scripts/lib/kendex-env.sh
      source "$READER" && kendex_load_project_env "$root" -- QA_UI_PATHS &&
        printf '%s\n' "${QA_UI_PATHS:-*.qml *.tsx *.jsx *.vue *.svelte}"
    ) 2>&1) || {
      reader_issue settings unreadable "$SETTING"
      continue
    }
    read -r -a GLOBS <<<"$SETTING"
  fi
  [ -z "$MATCH" ] || continue
  path=${file#"$root"/}
  for glob in ${GLOBS[@]+"${GLOBS[@]}"}; do
    pattern=${glob%/}
    pattern=${pattern//\*\*\//$ANY_DIRS}
    # shellcheck disable=SC2053 # Unquoted by design: QA_UI_PATHS is a pattern.
    if [[ "$path" == $pattern || "$path" == $pattern/* ]]; then MATCH=$path; break; fi
  done
done <<<"$TARGETS"
if [ -z "$MATCH" ]; then
  [ -z "$ISSUES" ] || context "$ISSUES"
  exit 0
fi

REFERENCE=$(installed code-quality references/ui.md) || { notice reference missing "$ISSUES"; exit 0; }
DETAIL="Read § UI copy in $REFERENCE and apply it to this edit."
# The exclusive create lets just one competing edit print a reminder.
if [ -z "$KEY" ]; then
  DETAIL="$DETAIL"$'\n''ui-copy-note: marker=no-session-id'
elif (umask 077 && mkdir -p -- "$STATE_DIR" && set -C && : >"$STATE_DIR/$KEY") 2>/dev/null; then
  find "$STATE_DIR" -type f -mtime +30 -delete 2>/dev/null || DETAIL="$DETAIL"$'\n''ui-copy-note: marker=prune-failed'
elif [ -e "$STATE_DIR/$KEY" ]; then
  [ -z "$ISSUES" ] || context "$ISSUES"
  exit 0
else
  DETAIL="$DETAIL"$'\n''ui-copy-note: marker=unwritable'
fi
notice path "$MATCH" "$DETAIL${ISSUES:+$'\n'$ISSUES}"
