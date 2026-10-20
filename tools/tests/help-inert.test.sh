#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
mkdir -p "$ROOT/tmp"
TMP="$(mktemp -d "$ROOT/tmp/help-inert.XXXXXX")"
FIXTURE="$TMP/repo"
MARKER="$FIXTURE/env-loaded"
CALLS="$TMP/dependency-calls"
PASS=0
FAIL=0

trap 'rm -rf -- "$TMP"' EXIT

mkdir -p "$FIXTURE/.agents/skills/control/scripts" "$FIXTURE/bin"
cp -R "$ROOT/skills/decider" "$FIXTURE/.agents/skills/decider"
cp -R "$ROOT/skills/github" "$FIXTURE/.agents/skills/github"
cp -R "$ROOT/skills/linear" "$FIXTURE/.agents/skills/linear"
cp -R "$ROOT/skills/orch" "$FIXTURE/.agents/skills/orch"
cp -R "$ROOT/skills/second-opinion" "$FIXTURE/.agents/skills/second-opinion"
cp -R "$ROOT/skills/worktree" "$FIXTURE/.agents/skills/worktree"
git -C "$FIXTURE" init -q
printf 'touch "%s"\n' "$MARKER" >"$FIXTURE/.env.local"
printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s %s\n" "$0" "$*" >>"${HELP_INERT_CALLS:?}"' \
    'exit 1' >"$FIXTURE/bin/blocked"
printf '%s\n' \
    '#!/bin/sh' \
    'gh auth status >/dev/null 2>&1 || true' \
    'printf "dependency control\n"' \
    >"$FIXTURE/.agents/skills/control/scripts/dependency-call"
printf '%s\n' \
    '#!/bin/sh' \
    '. "$PWD/.env.local"' \
    'printf "environment control\n"' \
    >"$FIXTURE/.agents/skills/control/scripts/environment-load"
printf '%s\n' \
    '#!/bin/sh' \
    ':' \
    >"$FIXTURE/.agents/skills/control/scripts/command-swallow"
cp "$FIXTURE/bin/blocked" "$FIXTURE/bin/gh"
cp "$FIXTURE/bin/blocked" "$FIXTURE/bin/codex"
cp "$FIXTURE/bin/blocked" "$FIXTURE/bin/curl"
chmod +x "$FIXTURE/bin/blocked" "$FIXTURE/bin/gh" "$FIXTURE/bin/codex" \
    "$FIXTURE/bin/curl" "$FIXTURE/.agents/skills/control/scripts/dependency-call" \
    "$FIXTURE/.agents/skills/control/scripts/environment-load" \
    "$FIXTURE/.agents/skills/control/scripts/command-swallow"
export HELP_INERT_CALLS="$CALLS"

# The linear CLI's contract is Bash 4 or newer (skills/linear/tests/
# bash4-runtime-contract.test.sh): under Bash 3 it refuses before serving
# help, so its rows are out of this suite's reach on that shell.
LINEAR_SKIPPED=0
# skill, script, arguments, expected violation. A dash means no arguments.
while IFS=$'\t' read -r skill script args expected; do
    [ -n "$skill" ] || continue
    if [ "$skill" = linear ] && [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
        [ "$LINEAR_SKIPPED" -eq 1 ] || printf 'skipping linear rows: its contract is Bash 4 or newer, this is %s\n' "$BASH_VERSION"
        LINEAR_SKIPPED=1
        continue
    fi
    expected="${expected:-clean}"
    rm -f "$MARKER"
    : >"$CALLS"
    status=0
    if [ "$args" = - ]; then
        output="$(cd "$FIXTURE" && PATH="$FIXTURE/bin:$PATH" \
            env -u GH_TOKEN -u GITHUB_TOKEN -u LINEAR_API_KEY \
            "$FIXTURE/.agents/skills/$skill/$script" 2>&1)" || status=$?
    else
        # shellcheck disable=SC2086 # The table stores argv as space-separated words.
        output="$(cd "$FIXTURE" && PATH="$FIXTURE/bin:$PATH" \
            env -u GH_TOKEN -u GITHUB_TOKEN -u LINEAR_API_KEY \
            "$FIXTURE/.agents/skills/$skill/$script" $args 2>&1)" || status=$?
    fi
    observed=""
    if [ "$status" -ne 0 ] || [ -z "$output" ]; then
        observed="command"
    fi
    [ ! -e "$MARKER" ] || observed="${observed:+$observed,}environment"
    [ ! -s "$CALLS" ] || observed="${observed:+$observed,}dependency"
    observed="${observed:-clean}"
    if [ "$observed" = "$expected" ]; then
        PASS=$((PASS + 1))
    else
        printf 'FAIL: %s %s %s\n' "$skill" "$script" "$args" >&2
        printf '  status=%s observed=%s expected=%s\n' \
            "$status" "$observed" "$expected" >&2
        if [ -s "$CALLS" ]; then
            sed 's/^/  dependency: /' "$CALLS" >&2
        fi
        printf '%s\n' "$output" | sed 's/^/  | /' >&2
        FAIL=$((FAIL + 1))
    fi
done <<'ROWS'
control	scripts/dependency-call	--help	dependency
control	scripts/environment-load	--help	environment
control	scripts/command-swallow	--help	command
decider	scripts/decisions	-
decider	scripts/decisions	help
decider	scripts/decisions	--help
decider	scripts/decisions	-h
decider	scripts/decisions	search
decider	scripts/decisions	search --help
decider	scripts/decisions	list --help
decider	scripts/decisions	search query -h
decider	scripts/decisions	search query --limit 2 --help
github	scripts/github.sh	-
github	scripts/github.sh	help
github	scripts/github.sh	--help
github	scripts/github.sh	-h
github	scripts/github.sh	label-add --help
github	scripts/github.sh	pr-view --help
github	scripts/github.sh	pr-merge -h
github	scripts/github.sh	pr-view 123 --help
github	scripts/github.sh	pr-merge 42 -h
github	scripts/github.sh	sticky-comment 23 --body --help
github	scripts/github.sh	check-review-replies --help
github	scripts/commands/check-review-replies.sh	-h
linear	scripts/commands/issues.sh	-
linear	scripts/commands/issues.sh	help
linear	scripts/commands/issues.sh	--help
linear	scripts/commands/issues.sh	activate --help
linear	scripts/commands/issues.sh	get --help
linear	scripts/commands/issues.sh	validate-completion --help
linear	scripts/commands/issues.sh	get KEN-1 --help
linear	scripts/commands/issues.sh	list --limit 5 -h
linear	scripts/commands/projects.sh	--help
linear	scripts/commands/cycles.sh	-h
linear	scripts/commands/labels.sh	help
linear	scripts/commands/comments.sh	--help
linear	scripts/commands/milestones.sh	--help
linear	scripts/commands/initiatives.sh	--help
linear	scripts/commands/auth-check.sh	--help
linear	scripts/commands/session-status.sh	--help
linear	scripts/commands/teams.sh	--help
linear	scripts/commands/users.sh	--help
linear	scripts/commands/statuses.sh	--help
linear	scripts/commands/documents.sh	--help
linear	scripts/commands/project-labels.sh	--help
linear	scripts/commands/attachments.sh	--help
linear	scripts/commands/attachments.sh	-
linear	scripts/commands/projects.sh	-
linear	scripts/linear.sh	--help
linear	scripts/linear.sh	issues --help
linear	scripts/linear.sh	projects --help
linear	scripts/linear.sh	cycles -h
linear	scripts/linear.sh	labels help
linear	scripts/linear.sh	comments --help
linear	scripts/linear.sh	milestones --help
linear	scripts/linear.sh	initiatives --help
linear	scripts/linear.sh	auth-check --help
linear	scripts/linear.sh	session-status --help
linear	scripts/linear.sh	teams --help
linear	scripts/linear.sh	users --help
linear	scripts/linear.sh	statuses --help
linear	scripts/linear.sh	documents --help
linear	scripts/linear.sh	project-labels --help
linear	scripts/linear.sh	attachments --help
linear	scripts/linear.sh	projects
orch	scripts/approval-wait	--help
orch	scripts/approval-wait	-h
orch	scripts/approval-wait	help
orch	scripts/approval-wait	123 --mode approval -h
orch	scripts/lanes	-
orch	scripts/lanes	--help
orch	scripts/lanes	-h
orch	scripts/lanes	help
orch	scripts/lanes	list --help
orch	scripts/lanes	pick --harness claude -h
orch	scripts/open-terminal	--help
orch	scripts/open-terminal	-h
orch	scripts/open-terminal	help
orch	scripts/open-terminal	KEN-1 --harness claude --help
orch	scripts/orch-env	--help
orch	scripts/orch-env	-h
orch	scripts/orch-env	help
orch	scripts/oversee-watch	--help
orch	scripts/oversee-watch	-h
orch	scripts/oversee-watch	help
orch	scripts/oversee-watch	--repo o/r --item KEN-1 -h
orch	scripts/reconcile-work-items	--help
orch	scripts/reconcile-work-items	-h
orch	scripts/reconcile-work-items	help
orch	scripts/workflow-state	--help
orch	scripts/workflow-state	-h
orch	scripts/workflow-state	help
orch	scripts/workflow-state	--state-dir tmp --help
orch	scripts/workflow-state	remove --help
orch	scripts/workflow-state	remove -h
orch	scripts/workflow-state	--state-dir tmp remove --help
second-opinion	scripts/second-opinion	--help
second-opinion	scripts/second-opinion	-h
second-opinion	scripts/second-opinion	review --help
second-opinion	scripts/second-opinion	quick -h
worktree	scripts/worktree	--help
worktree	scripts/worktree	-h
worktree	scripts/worktree	help
worktree	scripts/worktree	remove CC-1 --help
worktree	scripts/worktree	cleanup --stale --help
worktree	scripts/worktree	push some-id -h
ROWS

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
