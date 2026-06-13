#!/bin/bash
# Linear GraphQL API - Main Entry Point
# Usage: ./linear.sh <resource> <action> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_help() {
    cat << 'EOF'
Linear GraphQL API CLI

Usage: ./linear.sh <resource> <action> [options]

Resources:
  issues          Issue operations (list, get, create, update, children, relations)
  comments        Comment operations (list, create/update; supports --body-file)
  projects        Project operations (list, get, create, update, dependencies, updates)
  initiatives     Initiative operations (list, get, create, add-project)
  milestones      Project milestone operations (list, get, create)
  labels          Issue label operations (list, create)
  project-labels  Project label operations (list, create)
  teams           Team operations (list, get)
  users           User operations (list, get)
  cycles          Cycle operations (list)
  statuses        Workflow state operations (list, get)
  documents       Document operations (list, get)
  session-status  Aggregated session status for /start workflow
  auth-check      Lightweight API key validation (exit 0 = ok)
  sync            Sync Linear data to local cache
  cache           Query local cache (issues, projects, cycles, initiatives, comments, labels)

Examples:
  # Issues with parent/sub-issues and relations
  ./linear.sh issues list --label "backend" --state "Todo,In Progress"
  ./linear.sh issues create --title "Task" --parent PROJ-42
  ./linear.sh issues add-relation PROJ-42 --blocks PROJ-43
  ./linear.sh issues children PROJ-42              # Direct children
  ./linear.sh issues children PROJ-42 --recursive  # All descendants (3 levels)

  # Projects with dependencies and health updates
  ./linear.sh projects list --state started
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
  LINEAR_API_KEY  Required. Set in .env.local or export directly.
                  Non-secret defaults such as LINEAR_TEAM can be set in vstack.settings.toml.

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
esac

case "$resource" in
    sync)
        exec bash "$SCRIPT_DIR/commands/sync.sh" "$@"
        ;;
    cache)
        exec bash "$SCRIPT_DIR/commands/cache-query.sh" "$@"
        ;;
    issues|comments|projects|initiatives|milestones|labels|project-labels|teams|users|cycles|statuses|documents|session-status|auth-check)
        script="$SCRIPT_DIR/commands/${resource}.sh"
        if [ -f "$script" ]; then
            exec bash "$script" "$@"
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
