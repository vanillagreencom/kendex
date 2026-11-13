#!/usr/bin/env bash
# Linear GraphQL API - Main Entry Point
# Usage: ./linear.sh <resource> <action> [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/bash-version.sh
source "$SCRIPT_DIR/lib/bash-version.sh"
linear_require_supported_bash || exit $?

set -euo pipefail

show_help() {
    cat << 'EOF'
Linear GraphQL API CLI

Usage: ./linear.sh <resource> <action> [options]

Resources:
  issues          Issue operations (list, get, create, update, list-relations, add-relation)
  comments        Comment operations (list, create/update; supports --body-file)
  projects        Project operations (list, create, update, list-dependencies, add-dependency, post-update, list-updates)
  initiatives     Initiative operations (list, get, create, add-project)
  milestones      Project milestone operations (list, get, create)
  labels          Issue label operations (list, create, update, delete, audit)
  project-labels  Project label operations (list, create, update, delete)
  teams           Team operations (list, get)
  users           User operations (list, get)
  cycles          Cycle operations (list, create, update)
  statuses        Workflow state operations (list, get)
  documents       Document operations (list, get)
  graphql         One read document as written (--query DOC [--variables JSON])
  attachments    Files an issue references, read live (list), and one download (fetch)
  session-status  Aggregated session status for /start workflow
  auth-check      Credential, actor and team preflight (--strict fails with no team)
  auth-mint       Mint app token JSON from the client pair without writing files
  done-when       Parse a description's Done-when checklist (parse); reads nothing
  journal         Opt-in bounded attempt metadata (start, stop, read)

Every read goes to Linear's API as it runs; no local copy is kept. The
removed cache verb refuses naming the live command to run instead, and the
removed sync verb refuses naming none, since every read is live.

Examples:
  # Issues with parent/sub-issues and relations
  ./linear.sh issues list --label "backend" --state "Todo,In Progress"
  ./linear.sh issues create --title "Task" --parent PROJ-42 --labels "agent:rust" --description-file body.md
  ./linear.sh issues list-relations PROJ-42
  ./linear.sh issues add-relation PROJ-42 --blocks PROJ-43
  ./linear.sh issues get PROJ-42                   # The issue and its children (3 levels)

  # Projects with dependencies and health updates
  ./linear.sh projects list --state started
  ./linear.sh projects list-dependencies <id>
  ./linear.sh projects add-dependency <id> --blocked-by <other-id>
  ./linear.sh projects post-update <id> --health on-track --body "Progressing well"

  # Initiatives
  ./linear.sh initiatives list
  ./linear.sh initiatives create --name "Phase 1" --target-date 2025-03-31
  ./linear.sh initiatives add-project <id> --project "Market Data Pipeline"

  # Milestones
  ./linear.sh milestones list --project "Market Data Pipeline"
  ./linear.sh milestones create --project <id> --name "Alpha" --target-date 2025-02-15

Environment:
  Runtime         Bash 4.0 or newer. macOS system Bash 3.2 is unsupported.
  LINEAR_APP_TOKEN Pre-minted app token, sent as Bearer. Wins over pair and key.
                  Set in the private env file or secret store (op:// supported).
                  Never renewed or cached; replace an expired or revoked token.
  LINEAR_CLIENT_ID / LINEAR_CLIENT_SECRET
                  App credentials in .env.local. Together they win over the key
                  when no app token is set. Tokens use the fixed scope
                  read,write,issues:create,comments:create,timeSchedule:write,
                  initiative:read,initiative:write,customer:read,customer:write.
                  auth-mint prints access_token and expires_at and writes no
                  file; the pair's API path keeps its token until it expires in
                  kendex/linear-oauth/ under XDG_CACHE_HOME, else ~/.cache,
                  or, when neither is set or this user cannot write there, in
                  kendex-linear-oauth-<uid>/ under TMPDIR or /tmp.
  LINEAR_API_KEY  Fallback. Set in .env.local; a key from project files wins
                  over a plain environment export (auth-check warns when they
                  differ). LINEAR_API_KEY_OVERRIDE overrides personal-key
                  sources for one invocation (inline/test channel). It does not
                  bypass app selection or refusal of an incomplete app pair.
  LINEAR_TEAM     Target for writes that need a configured team; no default.
                  Set it in kendex.settings.toml [env] (committed, non-secret).
                  Existing-issue writes use the issue team, and an issue
                  create, field change, archive or trash outside this team
                  is refused (comments, relations and reads are not). With no
                  team, other writes refuse and reads run without a team
                  filter.
                  Only issues/projects/cycles/
                  labels create, labels audit, projects audit, cycles list
                  and statuses list/get take --team <key-or-name> as a
                  per-call override.

For resource-specific help:
  ./linear.sh <resource> --help
EOF
}

# Route to appropriate command script
resource="${1:-help}"
shift || true

# Normalize singular to plural (common mistake)
case "$resource" in
    issue) resource="issues" ;;
    comment) resource="comments" ;;
    project) resource="projects" ;;
    initiative) resource="initiatives" ;;
    milestone) resource="milestones" ;;
    label) resource="labels" ;;
    project-label) resource="project-labels" ;;
    team) resource="teams" ;;
    user) resource="users" ;;
    cycle) resource="cycles" ;;
    status) resource="statuses" ;;
    document) resource="documents" ;;
    attachment) resource="attachments" ;;
esac

case "$resource" in
    journal)
        LINEAR_SKIP_API_KEY_RESOLUTION=1
        source "$SCRIPT_DIR/lib/common.sh"
        linear_journal_command "$@"
        ;;
    # The one Done-when parse other packages read (orch's watch, which keeps
    # no parser of its own): the checklist JSON `done_when_parse` builds for
    # a description given inline or by file, with no credential and no
    # request. `--merged-at` is the merge stamp the post-merge rules judge
    # against, as `issues complete --post-merge-at` passes it.
    done-when)
        action="${1:-}"
        shift || true
        [[ "$action" == parse ]] || {
            echo "linear: done-when takes one action, parse: linear.sh done-when parse (--description TEXT | --description-file PATH) [--merged-at UTC]" >&2
            exit 1
        }
        dw_description="" dw_file="" dw_merged="" dw_given=0
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --description | --description-file | --merged-at)
                    [[ $# -ge 2 ]] || { echo "linear: done-when parse: $1 needs a value" >&2; exit 1; }
                    case "$1" in
                        --description) dw_description="$2"; dw_given=$((dw_given + 1)) ;;
                        --description-file) dw_file="$2"; dw_given=$((dw_given + 1)) ;;
                        --merged-at) dw_merged="$2" ;;
                    esac
                    shift 2
                    ;;
                *) echo "linear: done-when parse: unknown option $1" >&2; exit 1 ;;
            esac
        done
        [[ "$dw_given" -eq 1 ]] || { echo "linear: done-when parse takes exactly one of --description and --description-file" >&2; exit 1; }
        if [[ -n "$dw_file" ]]; then
            # The sentinel keeps the file's trailing newlines through the
            # substitution, as the lib's own callers keep them.
            dw_description="$(cat -- "$dw_file" && printf .)" || { echo "linear: done-when parse: unreadable $dw_file" >&2; exit 1; }
            dw_description="${dw_description%.}"
        fi
        source "$SCRIPT_DIR/lib/issue-validation.sh"
        done_when_parse "$dw_description" '[]' "$dw_merged"
        ;;
    # The local store is gone. Each removed verb answers with one line naming
    # what to run instead and exits nonzero, so a caller still running it fails
    # rather than reading a store that no longer exists.
    sync)
        echo "linear: removed=sync replacement=none: every read goes to the live API, so drop the sync step" >&2
        exit 1
        ;;
    cache)
        case "${1:-}" in
        "" | -*) echo "linear: removed=cache replacement=linear.sh <resource> <action>: the live read of the same resource; a whole-set list takes --max" >&2 ;;
        status) echo "linear: removed=cache replacement=linear.sh auth-check: no local store has a status" >&2 ;;
        *)
            # The live read that answers what the cache verb did: a store list
            # of projects, labels or initiatives held the whole set, so its
            # live read takes --max; the store's cycle types have live names.
            cache_args=("$@")
            if [[ "$1:${2:-}" == issues:list-comments ]]; then
                cache_args=(comments list "${@:3}")
            fi
            if [[ "${2:-}" == list ]]; then
                cache_bounded=false
                for ((i = 2; i < ${#cache_args[@]}; i++)); do
                    case "${cache_args[i]}" in
                    --limit | --max) cache_bounded=true ;;
                    past | upcoming)
                        if [[ "${cache_args[i - 1]}" == --type ]]; then
                            if [[ "${cache_args[i]}" == past ]]; then cache_args[i]=previous; else cache_args[i]=next; fi
                        fi
                        ;;
                    esac
                done
                case "$1" in
                projects | labels | initiatives) [[ "$cache_bounded" == true ]] || cache_args+=(--max) ;;
                esac
            fi
            echo "linear: removed=cache replacement=linear.sh ${cache_args[*]}" >&2
            ;;
        esac
        exit 1
        ;;
    issues|comments|projects|initiatives|milestones|labels|project-labels|teams|users|cycles|statuses|documents|graphql|attachments|session-status|auth-check|auth-mint)
        script="$SCRIPT_DIR/commands/${resource}.sh"
        if [ -f "$script" ]; then
            exec "$BASH" "$script" "$@"
        else
            echo "Error: Command script not found: $script" >&2
            exit 1
        fi
        ;;
    help|--help|-h)
        show_help
        ;;
    # Common mistakes - provide helpful redirects
    relations|relation)
        echo "Error: 'relations' is not a resource. Issue relations are managed via:" >&2
        echo "  ./linear.sh issues add-relation PROJ-42 --blocks PROJ-43" >&2
        echo "  ./linear.sh issues add-relation PROJ-42 --blocked-by PROJ-41" >&2
        echo "  ./linear.sh issues list-relations PROJ-42" >&2
        exit 1
        ;;
    workflow|workflows|states)
        echo "Error: Use 'statuses' for workflow states:" >&2
        echo "  ./linear.sh statuses list" >&2
        exit 1
        ;;
    sprint|sprints)
        echo "Error: Use 'cycles' for sprints:" >&2
        echo "  ./linear.sh cycles list" >&2
        exit 1
        ;;
    *)
        echo "Error: Unknown resource '$resource'" >&2
        echo "Run './linear.sh --help' for usage." >&2
        exit 1
        ;;
esac
