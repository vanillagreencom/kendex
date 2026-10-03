#!/usr/bin/env bash
# ---
# name: critical-path-deny
# event: PermissionRequest
# matcher: Bash
# description: Answers Claude Code's critical-path check prompt for a Bash call with deny at once, inside a launched orch lane only, so an unattended lane is not held two minutes per prompt and does not trip the three-prompt circuit breaker. The deny message gives the rewrite the permission-modes page gives for each form the check flags: `${NAME:?}` or a literal path for a glob or trailing slash under a variable, a literal path for a variable set from a directory-printing substitution such as `$(pwd)`, and the substitution run on its own first for a target that is only its output; and, as the lane's own rule, a long inline script written to a file under the lane's `tmp/` and run from there, every rm target in that file still guarded with `:?` or literal. A prompt is the critical-path one where the payload's `permission_suggestions` is present and an empty array and the command holds the text `rm`, the payload Claude Code 2.1.288 was measured sending for it; an ask-rule prompt carries no `permission_suggestions` key and is left alone. Whether the session is a launched lane is the lane-mail-check hook's answer, run from beside this one with the argument `lane`; outside a lane, and for every other prompt, it returns no decision, so the prompt stands. It never answers allow. Not run on codex: the critical-path check whose prompt this answers is Claude Code's, and Codex shows no such prompt. Not run on pi: it has no PermissionRequest event. Not run on gemini: it has no PermissionRequest event. Not run on copilot: the critical-path check whose prompt this answers is Claude Code's, and Copilot shows no such prompt. Not run on antigravity: it has no PermissionRequest event. Not run on opencode: it runs no hooks, and an agent cannot answer its own permission prompt from instructions. Not run on cursor: it runs no hooks, and an agent cannot answer its own permission prompt from instructions.
# summary: In an unattended orch lane, turns down Claude Code's prompt for an rm it could not check at once, with the rewrite that passes, instead of leaving the lane waiting on an answer nobody gives.
# safety: Reads the payload and runs only the lane-mail-check hook installed in its own directory, which reads git state and the lane's launch marker. Writes one scratch file under TMPDIR holding what lane-mail-check writes to stderr, and removes it on exit. The only decision it returns is deny, and only for a critical-path prompt in a launched lane; every gap (a missing jq or cat, an unreadable payload, a lane-mail-check absent or unable to answer, a scratch file that cannot be made) is reported on stderr under `critical-path-deny: <key>=<value>` with no decision, so the prompt stands. Claude Code does not honor exit 2 on this event, so the hook always exits 0.
# timeout: 30
# harnesses: [claude]
# requires: [lane-mail-check]
# ---

# The basis is https://code.claude.com/docs/en/permission-modes.md, § Critical
# paths: in a mode that asks, a PermissionRequest hook can answer the
# critical-path prompt; in bypassPermissions mode the terminal prompt waits two
# minutes before it denies, and after three such prompts run out unanswered
# Claude Code denies every further one at once.

set -euo pipefail

NL='
'

# Every line this hook writes to stderr, and the only place its text lives.
# The first line is `critical-path-deny: <key>=<value>`; what a command this
# hook ran wrote is captured at the site and replayed under it. Claude Code
# ignores exit 2 here, so a gap is reported and the prompt left to stand.
report() { # KEY VALUE [CAUSE]
  printf 'critical-path-deny: %s=%s\n' "$1" "$2" >&2
  case "$1" in
    missing-tools)
      echo "the commands ${2//,/, } are required to read the hook payload and are not on PATH; the prompt is left standing" >&2
      ;;
    payload)
      echo "the hook payload could not be read as JSON; the prompt is left standing" >&2
      ;;
    judge)
      echo "the lane-mail-check hook this one asks whether the session is a launched lane is not installed beside it; the prompt is left standing. Install lane-mail-check in the same scope." >&2
      ;;
    workdir)
      echo "a scratch file for the lane-mail-check hook's own words could not be made under $2; the prompt is left standing:" >&2
      ;;
    lane)
      echo "the lane-mail-check hook beside this one did not answer lane or none to whether the session is a launched lane; the prompt is left standing. What it wrote is below:" >&2
      ;;
  esac
  [ -z "${3:-}" ] || printf '%s\n' "$3" >&2
  exit 0
}

# The deny message Claude hands the model: the keyed line, the rewrite the
# permission-modes page gives for each form the check flags, then the lane's
# own rule for a long inline script, which is not the page's: a file the
# script moves to is read by neither the check nor block-unsafe-rm, so its rm
# targets stay guarded or literal.
DENY_MESSAGE='critical-path-deny: refused=critical-path-removal
Claude Code'"'"'s critical-path check could not prove this rm stays off the filesystem root, the home directory and the working directory, and in an unattended lane nobody answers its prompt, so it is denied at once. Rewrite it the way the check accepts for the form it flagged:
  a glob or trailing slash under a variable: guard each expansion so the shell stops when it is empty, as in rm -rf -- "${DIR:?}"/*, or use a literal path; under a variable that is normally set, such as $HOME, use a literal path;
  a variable set from a directory-printing substitution, such as D=$(pwd): use a literal path, since a :? guard does not clear it;
  a target that is only a command substitution'"'"'s output: run the substitution on its own first, then remove the literal paths it prints.
This lane'"'"'s own rule: for a long inline script (bash -c, sh -c or a heredoc), write it to a file under this lane'"'"'s tmp/ and run that file, with every rm target in that file still guarded with :? or a literal path.
The check reads the text rm anywhere in such a script, a path segment such as drm included.'

MISSING=""
for dependency in jq cat; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || report missing-tools "${MISSING#,}"

INPUT=$(cat 2>&1) || report payload unreadable "$INPUT"

# Claude Code 2.1.288 builds every critical-path ask with an empty suggestion
# list, and an ask rule's request carries no list at all: the payload names no
# reason, so the empty list beside the rm text is the one measured mark.
KIND=$(printf '%s' "$INPUT" | jq -r '
  if .tool_name == "Bash"
     and (.permission_suggestions | type) == "array"
     and (.permission_suggestions | length) == 0
     and (.tool_input.command | type) == "string"
     and (.tool_input.command | contains("rm"))
  then "critical" else "other" end' 2>&1) || report payload invalid-json "$KIND"
[ "$KIND" = critical ] || exit 0

JUDGE=""
if HOOK_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P); then
  JUDGE="$HOOK_DIR/lane-mail-check.sh"
fi
{ [ -n "$JUDGE" ] && [ -f "$JUDGE" ]; } || report judge "${JUDGE:-unlocatable}"

# The template is what makes TMPDIR the parent on both mktemp implementations.
ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/critical-path-deny.XXXXXX" 2>&1) || report workdir "${TMPDIR:-/tmp}" "$ERR_FILE"
trap 'rm -f -- "$ERR_FILE"' EXIT
JUDGE_RC=0
ANSWER=$(printf '%s' "$INPUT" | "$BASH" "$JUDGE" lane 2>"$ERR_FILE") || JUDGE_RC=$?
case "$JUDGE_RC:$ANSWER" in
  0:lane) ;;
  0:none) exit 0 ;;
  0:) report lane empty "$(cat -- "$ERR_FILE")" ;;
  0:*) report lane unexpected "$ANSWER$NL$(cat -- "$ERR_FILE")" ;;
  *) report lane "exit-$JUDGE_RC" "$(cat -- "$ERR_FILE")" ;;
esac

jq -nc --arg message "$DENY_MESSAGE" \
  '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "deny", message: $message}}}'
