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
cp "$FIXTURE/bin/blocked" "$FIXTURE/bin/gh"
cp "$FIXTURE/bin/blocked" "$FIXTURE/bin/codex"
cp "$FIXTURE/bin/blocked" "$FIXTURE/bin/curl"
chmod +x "$FIXTURE/bin/blocked" "$FIXTURE/bin/gh" "$FIXTURE/bin/codex" \
    "$FIXTURE/bin/curl" "$FIXTURE/.agents/skills/control/scripts/dependency-call" \
    "$FIXTURE/.agents/skills/control/scripts/environment-load"
export HELP_INERT_CALLS="$CALLS"

# skill, script, expected output, arguments, expected violation. A dash means no arguments.
while IFS=$'\t' read -r skill script token args expected; do
    [ -n "$skill" ] || continue
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
    if [ "$status" -ne 0 ] || [[ "$output" != *"$token"* ]]; then
        observed="command"
    fi
    [ ! -e "$MARKER" ] || observed="${observed:+$observed,}environment"
    [ ! -s "$CALLS" ] || observed="${observed:+$observed,}dependency"
    observed="${observed:-clean}"
    if [ "$observed" = "$expected" ]; then
        PASS=$((PASS + 1))
    else
        printf 'FAIL: %s %s %s\n' "$skill" "$script" "$args" >&2
        printf '  status=%s observed=%s expected=%s token=%s\n' \
            "$status" "$observed" "$expected" "$token" >&2
        if [ -s "$CALLS" ]; then
            sed 's/^/  dependency: /' "$CALLS" >&2
        fi
        printf '%s\n' "$output" | sed 's/^/  | /' >&2
        FAIL=$((FAIL + 1))
    fi
done <<'ROWS'
control	scripts/dependency-call	dependency control	--help	dependency
control	scripts/environment-load	environment control	--help	environment
decider	scripts/decisions	Decision Lookup Tool	-
decider	scripts/decisions	Decision Lookup Tool	help
decider	scripts/decisions	Decision Lookup Tool	--help
decider	scripts/decisions	Decision Lookup Tool	-h
decider	scripts/decisions	Decision Lookup Tool	search
decider	scripts/decisions	Decision Lookup Tool	search --help
decider	scripts/decisions	Decision Lookup Tool	list --help
decider	scripts/decisions	Decision Lookup Tool	search query -h
decider	scripts/decisions	Decision Lookup Tool	search query --limit 2 --help
github	scripts/github.sh	GitHub API CLI	-
github	scripts/github.sh	GitHub API CLI	help
github	scripts/github.sh	GitHub API CLI	--help
github	scripts/github.sh	GitHub API CLI	-h
github	scripts/github.sh	Add a label	label-add --help
github	scripts/github.sh	View PR details	pr-view --help
github	scripts/github.sh	Merge PR	pr-merge -h
github	scripts/github.sh	View PR details	pr-view 123 --help
github	scripts/github.sh	Merge PR	pr-merge 42 -h
github	scripts/github.sh	Sticky	sticky-comment 23 --body --help
linear	scripts/commands/issues.sh	Issue Operations	-
linear	scripts/commands/issues.sh	Issue Operations	help
linear	scripts/commands/issues.sh	Issue Operations	--help
linear	scripts/commands/issues.sh	Issue Operations	activate --help
linear	scripts/commands/issues.sh	Issue Operations	get --help
linear	scripts/commands/issues.sh	Issue Operations	validate-completion --help
linear	scripts/commands/issues.sh	Issue Operations	get KEN-1 --help
linear	scripts/commands/issues.sh	Issue Operations	list --limit 5 -h
linear	scripts/commands/projects.sh	Project Operations	--help
linear	scripts/commands/cycles.sh	Cycle Operations	-h
linear	scripts/commands/labels.sh	Label Operations	help
linear	scripts/commands/comments.sh	Comment Operations	--help
linear	scripts/commands/milestones.sh	Project Milestone Operations	--help
linear	scripts/commands/initiatives.sh	Initiative Operations	--help
linear	scripts/commands/sync.sh	Linear Cache Sync	--help
linear	scripts/commands/cache-query.sh	Linear Cache Query	--help
linear	scripts/commands/auth-check.sh	Auth + target preflight	--help
linear	scripts/commands/session-status.sh	Session Status	--help
linear	scripts/commands/teams.sh	Team Operations	--help
linear	scripts/commands/users.sh	User Operations	--help
linear	scripts/commands/statuses.sh	Workflow State Operations	--help
linear	scripts/commands/documents.sh	Document Operations	--help
linear	scripts/commands/project-labels.sh	Project Label Operations	--help
linear	scripts/commands/projects.sh	Project Operations	-
linear	scripts/commands/cache-query.sh	Linear Cache Query	-
linear	scripts/linear.sh	Linear GraphQL API CLI	--help
linear	scripts/linear.sh	Issue Operations	issues --help
linear	scripts/linear.sh	Project Operations	projects --help
linear	scripts/linear.sh	Cycle Operations	cycles -h
linear	scripts/linear.sh	Label Operations	labels help
linear	scripts/linear.sh	Comment Operations	comments --help
linear	scripts/linear.sh	Project Milestone Operations	milestones --help
linear	scripts/linear.sh	Initiative Operations	initiatives --help
linear	scripts/linear.sh	Linear Cache Sync	sync --help
linear	scripts/linear.sh	Linear Cache Query	cache --help
linear	scripts/linear.sh	Auth + target preflight	auth-check --help
linear	scripts/linear.sh	Session Status	session-status --help
linear	scripts/linear.sh	Team Operations	teams --help
linear	scripts/linear.sh	User Operations	users --help
linear	scripts/linear.sh	Workflow State Operations	statuses --help
linear	scripts/linear.sh	Document Operations	documents --help
linear	scripts/linear.sh	Project Label Operations	project-labels --help
linear	scripts/linear.sh	Project Operations	projects
linear	scripts/linear.sh	Linear Cache Query	cache
linear	scripts/linear.sh	Linear Cache Query	cache cycles list --type --help	command,environment
orch	scripts/approval-wait	Usage: approval-wait	--help
orch	scripts/approval-wait	Usage: approval-wait	-h
orch	scripts/approval-wait	Usage: approval-wait	help
orch	scripts/approval-wait	Usage: approval-wait	123 --mode review -h
orch	scripts/lanes	lanes list [--harness claude|codex|all]	-
orch	scripts/lanes	lanes list [--harness claude|codex|all]	--help
orch	scripts/lanes	lanes list [--harness claude|codex|all]	-h
orch	scripts/lanes	lanes list [--harness claude|codex|all]	help
orch	scripts/lanes	lanes list [--harness claude|codex|all]	list --help
orch	scripts/lanes	lanes list [--harness claude|codex|all]	pick --harness claude -h
orch	scripts/open-terminal	Usage: open-terminal	--help
orch	scripts/open-terminal	Usage: open-terminal	-h
orch	scripts/open-terminal	Usage: open-terminal	help
orch	scripts/open-terminal	Usage: open-terminal	KEN-1 --harness claude --help
orch	scripts/orch-env	Usage: orch-env VAR_NAME DEFAULT	--help
orch	scripts/orch-env	Usage: orch-env VAR_NAME DEFAULT	-h
orch	scripts/orch-env	Usage: orch-env VAR_NAME DEFAULT	help
orch	scripts/oversee-watch	Usage: oversee-watch	--help
orch	scripts/oversee-watch	Usage: oversee-watch	-h
orch	scripts/oversee-watch	Usage: oversee-watch	help
orch	scripts/oversee-watch	Usage: oversee-watch	--repo o/r --item KEN-1 -h
orch	scripts/reconcile-work-items	Usage: reconcile-work-items	--help
orch	scripts/reconcile-work-items	Usage: reconcile-work-items	-h
orch	scripts/reconcile-work-items	Usage: reconcile-work-items	help
orch	scripts/workflow-state	Usage: workflow-state	--help
orch	scripts/workflow-state	Usage: workflow-state	-h
orch	scripts/workflow-state	Usage: workflow-state	help
orch	scripts/workflow-state	Usage: workflow-state	--state-dir tmp --help
second-opinion	scripts/second-opinion	Cross-model second opinion	--help
second-opinion	scripts/second-opinion	Cross-model second opinion	-h
second-opinion	scripts/second-opinion	Cross-model second opinion	review --help
second-opinion	scripts/second-opinion	Cross-model second opinion	quick -h
worktree	scripts/worktree	Usage: worktree <command>	--help
worktree	scripts/worktree	Usage: worktree <command>	-h
worktree	scripts/worktree	Usage: worktree <command>	help
worktree	scripts/worktree	Usage: worktree remove	remove CC-1 --help
worktree	scripts/worktree	Usage: worktree cleanup	cleanup --stale --help
worktree	scripts/worktree	Usage: worktree push	push some-id -h
ROWS

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
