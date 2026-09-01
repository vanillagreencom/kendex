#!/bin/bash
# GitHub API CLI - Main Entry Point
# Usage: ./github.sh [-C <path>] <command> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/gh-auth.sh
source "$SCRIPT_DIR/lib/gh-auth.sh"

# Parse -C flag (must come before command, like git)
WORK_DIR=""
if [ "${1:-}" = "-C" ]; then
    if [ -z "${2:-}" ]; then
        echo "Error: -C requires a path argument" >&2
        exit 1
    fi
    WORK_DIR="$2"
    shift 2
fi

show_help() {
    cat << 'EOF'
GitHub API CLI

Usage: ./github.sh [-C <path>] <command> [options]

Global Options:
  -C <path>    Run as if started in <path> (like git -C)

Commands:
  pr-data            Get PR with threads, comments, and files
  pr-view            View PR details (current branch or by number)
  pr-threads         Get PR review threads (optionally filtered)
  pr-list-ready      List PRs ready for merge
  pr-list-failing    List PRs with CI failures
  pr-create          Create PR as bot account
  pr-edit-body       Update PR body from a file
  pr-merge           Merge PR as bot account (with safety checks)
  ci-classify-refusal  Name the cause of a pr-merge refusal (threads, conflicts,
                     current vs superseded CI failures)
  pr-cross-check     Analyze multiple PRs for conflicts/dependencies
  pr-issue           Extract issue ID from PR branch name
  label-add          Add a PR/issue label
  label-remove       Remove a PR/issue label
  await-mergeable    Wait for GitHub to resolve a PR's merge state (post-push or post-merge)
  ci-logs            Get CI failure logs for a PR
  bot-token          Check bot token configuration
  dismiss-review     Dismiss a PR review (bot or specific user)
  resolve-thread     Resolve a review thread
  unresolve-thread   Unresolve a review thread
  post-reply         Reply to a review comment
  post-comment       Post a PR-level comment
  find-comment       Find a comment by pattern/author
  edit-comment       Edit an existing comment
  sticky-comment     Get claude bot sticky comment with verdict

Output Formats:
  --format is command-specific, not a global option. Supported modes
  (default is safe where applicable):
    pr-data          safe | raw
    pr-threads       safe | raw
    pr-list-ready    safe | table
    pr-list-failing  safe | table
    ci-logs          safe | text
    pr-issue         safe | text
    bot-token        safe | text
  Commands not listed above (e.g. pr-view) do not accept --format; see
  './github.sh <command> --help'. For a normalized safe/raw PR view, use
  pr-data. An unrecognized format value is an error, never a silent
  fallback to safe. pr-data and pr-threads take --format=safe|raw only
  and reject unknown flags.

Argument rules:
  Most subcommands reject unknown flags and extra positionals beyond Usage.
  pr-view passes other flags and extra positionals to gh pr view, except its
  explicit --format rejection. sticky-comment keeps legacy permissive parsing:
  unrecognized flags become positional input, and surplus positionals are ignored.

Configuration:
  Project files load in this order, from lowest to highest precedence:
    kendex.settings.toml [env]
    .kendex/settings.toml [env]
    .env.local
  Values exported by the parent process override every project file. A .env
  file is never read.

  GH_TOKEN / GITHUB_TOKEN
      Pre-resolved user token. Falls back to gh keyring auth.
  GH_BOT_TOKEN
      Bot token. Falls back to GH_TOKEN, GITHUB_TOKEN, then gh keyring auth.
  GH_BOT_USERNAME
      Username used for review and comment filtering. Default: review-bot[bot]
  GH_ISSUE_PATTERN
      Branch issue-id regex. Default: [A-Z]+-[0-9]+
  GH_VERIFY_CMD
      Command used by pr-cross-check --verify. Default: auto-detect.
  KENDEX_GITHUB_OP_TIMEOUT
      Seconds allowed for op read. Default: 10.
  KENDEX_GITHUB_AUTH_TIMEOUT
      Seconds allowed for GitHub auth preflight. Default: 10.
  KENDEX_GITHUB_PR_VIEW_TIMEOUT
      Seconds allowed for gh pr view in pr-view. Default: 30.
  KENDEX_GITHUB_GIT_HTTPS_FALLBACK
      git-https-auth mode: auto, never, or always. Default: auto.

Token selection:
  Tokens may be literal ghp_*, gho_*, ghu_*, ghs_*, ghr_*, or github_pat_*
  values, or op://vault/item/field references. The router selects one token
  before resolving any 1Password reference. It first checks resolved values
  in GH_TOKEN, GH_BOT_TOKEN, GITHUB_TOKEN order, then checks op:// references
  in the same order. Only that selection is passed to op read.

  A resolved selection is exported as GH_TOKEN and GITHUB_TOKEN is removed.
  If an op:// selection cannot resolve, GH_TOKEN and GITHUB_TOKEN are removed
  so gh may use keyring auth. A selected GH_BOT_TOKEN keeps its bot identity
  and does not fall back to a different keyring identity after auth failure.

Auth preflight:
  When GH_TOKEN or GITHUB_TOKEN is selected, gh api user is authoritative.
  gh auth status is authoritative only when no environment token is selected.
  A failed non-bot environment token is removed only when keyring auth passes.

Errors and retries:
  Most commands write {"error": "message"} JSON to stderr and exit 1.
  pr-view --json writes its structured failure object to stdout; run
  'github.sh pr-view --help' for its status values and exit codes.
  gh_graphql retries only nonzero gh command failures with no GraphQL errors
  object. gh_rest retries rate limits and other command failures except
  authentication and not-found responses. Both stop after at most 3 attempts
  with exponential backoff. GraphQL error objects and excluded REST failures
  return on the first attempt. Other operations keep command-specific failure
  behavior. An unreadable thread list, comment list, or CI log is an error,
  never an empty result.

Examples:
  # Get PR data with all threads and comments
  ./github.sh pr-data 23
  ./github.sh pr-data              # Uses current branch's PR

  # Get unresolved threads only
  ./github.sh pr-threads 23 --unresolved

  # Resolve a thread
  ./github.sh resolve-thread PRRT_kwDO...

  # Post replies
  ./github.sh post-reply 12345678 "Thanks, fixed!"
  ./github.sh post-comment 23 "Addressed all feedback"

For command-specific help:
  ./github.sh <command> --help
EOF
}

command="${1:-help}"
shift || true

# Help is answered before project configuration or auth is touched:
# sourcing a repo's .env.local under --help would execute
# repository-controlled shell code, and help must not fail on auth. A subcommand's --help routes
# straight to its script, which prints help before any API work. The scan
# covers every argv position — enumerating positions is how this class
# leaks — but skips the value an option consumes, so '--pattern -h' stays
# data. An option missing from the value list only re-enables help routing
# on a help-shaped value; configuration is still never loaded on an
# apparent help call.
case "$command" in
    help|--help|-h) show_help; exit 0 ;;
esac

# Does this option consume the following argument? Arity is a property of
# one command's parser, never of an option name — --body selects a field in
# sticky-comment but takes a body in post-comment — so every entry is
# command-scoped. An option invalid for the routed command consumes
# nothing, so a --help after it is still a help request.
_takes_value() {
    case "$command:$1" in
        await-mergeable:--interval | await-mergeable:--max-iter) return 0 ;;
        ci-logs:--lines) return 0 ;;
        dismiss-review:--message | dismiss-review:--user) return 0 ;;
        edit-comment:--body | edit-comment:--body-file) return 0 ;;
        find-comment:--author | find-comment:--pattern) return 0 ;;
        post-comment:--body | post-comment:--body-file) return 0 ;;
        post-reply:--body | post-reply:--body-file | post-reply:--pr) return 0 ;;
        pr-create:--title | pr-create:--body | pr-create:--body-file) return 0 ;;
        pr-create:--base | pr-create:--head | pr-create:--label) return 0 ;;
        pr-data:--format | pr-threads:--format) return 0 ;;
        pr-edit-body:--body-file) return 0 ;;
        pr-view:--json | pr-view:--jq | pr-view:--template | pr-view:--repo) return 0 ;;
        pr-view:-q | pr-view:-t | pr-view:-R) return 0 ;;
        sticky-comment:--bot) return 0 ;;
        *) return 1 ;;
    esac
}
_help_route=""
_skip_value=""
for _arg in "$@"; do
    if [ -n "$_skip_value" ]; then
        _skip_value=""
        continue
    fi
    case "$_arg" in
        --help|-h) _help_route=1; break ;;
        -*) if _takes_value "$_arg"; then _skip_value=1; fi ;;
    esac
done
unset _arg _skip_value

if [ -z "$_help_route" ]; then
    # Auto-source project config and export GH_TOKEN for all subcommands.
    # Handles the case where `gh auth login` is tied to a different account than
    # the repo grants permissions to — without GH_TOKEN, read commands fail with
    # "Could not resolve to a Repository". Only fills GH_TOKEN from GH_BOT_TOKEN
    # when GH_TOKEN is still unset after config load.
    _CALLER_GH_TOKEN_SET="${GH_TOKEN+x}"
    _CALLER_GH_TOKEN="${GH_TOKEN:-}"
    _CALLER_GITHUB_TOKEN_SET="${GITHUB_TOKEN+x}"
    _CALLER_GITHUB_TOKEN="${GITHUB_TOKEN:-}"
    _CALLER_GH_BOT_TOKEN_SET="${GH_BOT_TOKEN+x}"
    _CALLER_GH_BOT_TOKEN="${GH_BOT_TOKEN:-}"

    # Any failure to resolve a repository root — not in a repo, unreadable
    # WORK_DIR — means the same thing: no project env to load.
    _env_root=""
    if [ -n "$WORK_DIR" ]; then
        _env_root=$(cd "$WORK_DIR" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || _env_root=""
    else
        _env_root=$(git rev-parse --show-toplevel 2>/dev/null) || _env_root=""
    fi
    if [ -n "$_env_root" ]; then
        # shellcheck source=lib/kendex-env.sh
        source "$SCRIPT_DIR/lib/kendex-env.sh"
        kendex_load_project_env "$_env_root"
    fi
    if [ -n "$_CALLER_GH_TOKEN_SET" ]; then
        export GH_TOKEN="$_CALLER_GH_TOKEN"
    fi
    if [ -n "$_CALLER_GITHUB_TOKEN_SET" ]; then
        export GITHUB_TOKEN="$_CALLER_GITHUB_TOKEN"
    fi
    if [ -n "$_CALLER_GH_BOT_TOKEN_SET" ]; then
        export GH_BOT_TOKEN="$_CALLER_GH_BOT_TOKEN"
    fi
    kendex_github_apply_selected_auth_token router || true
    kendex_github_sanitize_gh_env
    unset _env_root _CALLER_GH_TOKEN_SET _CALLER_GH_TOKEN _CALLER_GITHUB_TOKEN_SET _CALLER_GITHUB_TOKEN _CALLER_GH_BOT_TOKEN_SET _CALLER_GH_BOT_TOKEN
fi
unset _help_route




case "$command" in
    pr-data|pr-view|pr-threads|pr-list-ready|pr-list-failing|pr-create|pr-edit-body|pr-merge|ci-classify-refusal|pr-cross-check|pr-issue|label-add|label-remove|await-mergeable|ci-logs|bot-token|dismiss-review|resolve-thread|unresolve-thread|post-reply|post-comment|find-comment|edit-comment|sticky-comment)
        script="$SCRIPT_DIR/commands/${command}.sh"
        if [ -f "$script" ]; then
            if [ -n "$WORK_DIR" ]; then
                # Run in subshell to preserve caller's cwd
                (cd "$WORK_DIR" && exec bash "$script" "$@")
            else
                exec bash "$script" "$@"
            fi
        else
            echo "Error: Command script not found: $script" >&2
            exit 1
        fi
        ;;
    ci-wait|ciwait|ci_wait)
        echo "Error: Unknown command '$command' — CI waiting is the orch skill's script: .agents/skills/orch/scripts/ci-wait <PR_NUMBER> [interval] [max_wait] [--json]" >&2
        exit 1
        ;;
    *)
        echo "Error: Unknown command '$command'" >&2
        echo "Run './github.sh --help' for usage." >&2
        exit 1
        ;;
esac
