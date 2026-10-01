#!/usr/bin/env bash
# ---
# name: skill-load-record
# event: PostToolUse
# matcher: Skill|skill
# description: Writes down each skill a Copilot agent finished loading, so the skill-load-check hook can judge that agent's calls on Copilot, whose payload names no transcript to read loads from. The recording is the skill-load-check hook's, run from beside this one with the argument `record`: after a `skill` tool call whose `toolResult.resultType` is `success`, it appends the skill `toolArgs.skill` names to the record of the agent the payload's `sessionId` names, under `$XDG_STATE_HOME/kendex/skill-load-check/` or `~/.local/state/kendex/skill-load-check/` where that is unset, and removes records untouched for 30 days. It never refuses: the tool has already run, so a load it could not record is its keyed line on stderr and the same text as `additionalContext` on stdout at exit 0, and so is a skill-load-check missing from beside it, opening `skill-load-record: judge=<path>`. On claude, codex and pi this companion exits without recording: skill-load-check reads their transcripts instead. Not run on gemini: skill-load-check does not run there, its tool-call payload and its record of a skill load unmeasured. Not run on antigravity: skill-load-check does not run there, a skill load being a `view_file` read with no skill record. On opencode and cursor kendex delivers this companion as advisory prose, not an executable recorder.
# summary: Remembers which skills each Copilot agent has loaded, so the skill-load check can let that agent's edits and Linear commands through once it has.
# safety: On a Copilot installation, runs only the skill-load-check hook installed in its own directory, whose safety line covers the payload it reads and the record it writes. A judge that is not there is reported, never run from elsewhere. Other installations exit without reading the payload or writing a record.
# timeout: 15
# harnesses: [claude, codex, pi, copilot, opencode, cursor]
# requires: [skill-load-check]
# ---

# The matcher names Copilot's own `skill` beside `Skill`. Copilot anchors
# the matcher and names a skill load `skill`, and kendex 1.2.0 leaves a tool
# name it does not map as written, so there `Skill` alone would never fire
# and skill-load-check would refuse every guarded call. A kendex that maps
# `Skill` to `skill` says the pair once. Drop `skill` once the oldest kendex
# installing this catalog is a release after 1.2.0.

set -euo pipefail

# kendex 1.2.0 and 1.3.0 require the companion on every judge harness.
# Keep delivery aligned until the oldest consumer runs a release with the
# harness-scoped companion walk; recording still belongs only to Copilot.
HOOK_DIR=${BASH_SOURCE[0]%/*}
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.

# The judge is the skill-load-check hook installed beside this one: the one
# reader and writer of the record. A finished tool call is never refused, so
# a judge that is not there is reported, on stderr and to the model as
# Copilot's postToolUse `additionalContext` where jq can write it, and passed;
# a jq that fails ends the run at exit 2, which Copilot shows the user. The
# directory is read by parameter expansion, as the judge reads its own, so no
# command outside the shell stands between this hook and the judge's check of
# the tools it needs.
JUDGE=""
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
