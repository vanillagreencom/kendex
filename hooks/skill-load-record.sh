#!/usr/bin/env bash
# ---
# name: skill-load-record
# event: PostToolUse
# matcher: Skill
# description: Writes down each skill a Copilot agent finished loading, so the skill-load-check hook can judge that agent's calls on Copilot, whose payload names no transcript to read loads from. The recording is the skill-load-check hook's, run from beside this one with the argument `record`: after a `skill` tool call whose `toolResult.resultType` is `success`, it appends the skill `toolArgs.skill` names to the record of the agent the payload's `sessionId` names, under `$XDG_STATE_HOME/kendex/skill-load-check/` or `~/.local/state/kendex/skill-load-check/` where that is unset, and removes records untouched for 30 days. It never refuses: the tool has already run, so a load it could not record is its keyed line on stderr and the same text as `additionalContext` on stdout at exit 0, and so is a skill-load-check missing from beside it, opening `skill-load-record: judge=<path>`. Not run on claude: a skill load is a Skill tool call in the transcript skill-load-check reads. Not run on codex: skill-load-check does not run there, a file write being `apply_patch`, whose payload carries no `tool_input.file_path`. Not run on pi: a skill load is a `read` of SKILL.md in the session file skill-load-check reads. Not run on gemini: skill-load-check does not run there, its tool-call payload and its record of a skill load unmeasured. Not run on copilot: skill-load-check, the hook it requires, is not installed there until the skill-load row of `tools/harness-smoke --only copilot` passes on a host where Copilot is logged in. Not run on antigravity: skill-load-check does not run there, a skill load being a `view_file` read with no skill record. Not run on opencode: kendex delivers a hook there only as advisory rule prose, and a record taken as an instruction records nothing. Not run on cursor: kendex delivers a hook there only as advisory rule prose, and a record taken as an instruction records nothing.
# summary: Remembers which skills each Copilot agent has loaded, so the skill-load check can let that agent's edits and Linear commands through once it has.
# safety: Runs only the skill-load-check hook installed in its own directory, whose safety line covers the payload it reads and the record it writes. A judge that is not there is reported, never run from elsewhere.
# timeout: 15
# harnesses: [copilot]
# requires: [skill-load-check]
# ---

set -euo pipefail

# The judge is the skill-load-check hook installed beside this one: the one
# reader and writer of the record. A finished tool call is never refused, so
# a judge that is not there is reported, on stderr and to the model as
# Copilot's postToolUse `additionalContext` where jq can write it, and passed;
# a jq that fails ends the run at exit 2, which Copilot shows the user. The
# directory is read by parameter expansion, as the judge reads its own, so no
# command outside the shell stands between this hook and the judge's check of
# the tools it needs.
JUDGE=""
HOOK_DIR=${BASH_SOURCE[0]%/*}
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
if HOOK_DIR=$(cd -- "$HOOK_DIR" && pwd -P); then
  JUDGE="$HOOK_DIR/skill-load-check.sh"
fi
if [ -z "$JUDGE" ] || [ ! -f "$JUDGE" ]; then
  TEXT="skill-load-record: judge=${JUDGE:-unlocatable}
the skill-load-check hook this one runs is not installed beside it, so this skill load is not recorded; install skill-load-check in the same scope"
  printf '%s\n' "$TEXT" >&2
  if command -v jq >/dev/null 2>&1; then
    jq -n -c --arg t "$TEXT" '{additionalContext: $t}' || exit 2
  fi
  exit 0
fi
exec "$BASH" "$JUDGE" record
