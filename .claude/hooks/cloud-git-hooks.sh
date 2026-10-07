#!/usr/bin/env bash
# ---
# name: cloud-git-hooks
# event: SessionStart
# matcher: startup|resume
# description: Runs the commit-guards installer and its read-only check only when CLAUDE_CODE_REMOTE=true and HEAD commits this hook's project SessionStart registration in .claude/settings.json. A global install reaches no repository without that committed registration. Reports an arming gap as session context without refusing startup. Not run on codex: its SessionStart environment supplies no CLAUDE_CODE_REMOTE cloud flag. Not run on pi: its session_start environment supplies no CLAUDE_CODE_REMOTE cloud flag. Not run on gemini: its SessionStart environment supplies no CLAUDE_CODE_REMOTE cloud flag. Not run on copilot: its sessionStart environment supplies no CLAUDE_CODE_REMOTE cloud flag. Not run on antigravity: it has no SessionStart event. Not run on opencode: its session.created environment supplies no CLAUDE_CODE_REMOTE cloud flag. Not run on cursor: its sessionStart environment supplies no CLAUDE_CODE_REMOTE cloud flag.
# summary: Arms the repository's git checks when a Claude Code cloud session starts or resumes. Local sessions do nothing; an installation gap is reported to the agent.
# safety: Runs only in Claude Code cloud sessions after a repository commits this hook's project SessionStart registration. Calls the existing idempotent installer to arm the git pre-commit, commit-msg and pre-push hooks, then checks them. Writes no kendex arming record and never blocks session startup.
# timeout: 30
# harnesses: [claude]
# requires-skills: [commit-guards]
# ---
set -euo pipefail

# Git does not clone hooks. The committed enable licenses this cloud run;
# local clones still require their own setup.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJECT_DIR" ]; then
  printf 'cloud-git-hooks: gap=project-dir\n'
  printf 'Claude Code supplied no project directory. Git checks were not armed.\n'
  exit 0
fi

# Claude supports global hooks too. Only the repository's committed native
# project registration grants consent, not an installed script or a dirty
# manifest. Read that JSON instead of parsing the manifest a second time.
# An absent or unreadable registration grants no licence to run an installer.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
if ! COMMITTED_SETTINGS=$(git -C "$PROJECT_DIR" show HEAD:.claude/settings.json 2>/dev/null); then
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'cloud-git-hooks: missing-tools=jq\n'
  printf 'Committed session settings could not be checked. Git checks were not armed. Install jq before committing.\n'
  exit 0
fi
if ! jq -e --arg target '"$CLAUDE_PROJECT_DIR/.claude/hooks/cloud-git-hooks.sh"' '
  any(.hooks.SessionStart[]?;
    .matcher == "startup|resume" and
    any(.hooks[]?; .type == "command" and (.command | endswith($target))))
' <<<"$COMMITTED_SETTINGS" >/dev/null 2>&1; then
  exit 0
fi

# The installer can skip a configured hooks path at exit 0. Its checker owns
# the answer to whether git will run the installed checks.
if OUTPUT=$(
  (cd -- "$PROJECT_DIR" &&
    bash "$PROJECT_DIR/.agents/skills/commit-guards/scripts/install-git-hooks" &&
    bash "$PROJECT_DIR/.agents/skills/commit-guards/scripts/install-git-hooks" --check) 2>&1
  ); then
  printf 'cloud-git-hooks: armed=%s\n' "$PROJECT_DIR"
else
  printf 'cloud-git-hooks: gap=%s\n' "$PROJECT_DIR"
  printf 'Git checks could not be armed. Read the installer report before committing.\n'
  printf '%s\n' "$OUTPUT"
fi
exit 0
