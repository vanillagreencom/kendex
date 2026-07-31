#!/bin/bash
# Auth + target preflight
# Usage: ./linear.sh auth-check [--strict]
# Returns: {"ok": true/false, "team": ..., "team_source": ..., "writes_enabled": ...}
# Exit 0 when the API key works. With --strict, also requires a team target so
# the check matches what a write would do.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

strict=0
while [[ $# -gt 0 ]]; do
  case "$1" in
  --strict)
    strict=1
    shift
    ;;
  --help | -h)
    cat <<'EOF'
Auth + target preflight

Usage: auth-check [--strict]

Reports API key validity, the resolved Linear team, and where that team came
from. Linear writes refuse when no team resolves, so run this before the first
mutation in a new project.

Options:
  --strict    Exit 1 when no team target is configured (writes would refuse)

Fields:
  ok                API key is set and the API answered
  team              Resolved team name, or null
  team_source       environment | project-config | unset
  team_source_file  Project file that set the resolved team, or null
  api_key_source    environment | project-config | unset
  writes_enabled    false when a mutation would be refused
  warnings          Configuration hazards found
EOF
    exit 0
    ;;
  *)
    echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2
    exit 1
    ;;
  esac
done

# Team declared by project files, read independently of the process environment
# so a box-global export that shadows project config is visible here.
project_declared_team=""
if [[ -n "$PROJECT_ROOT" ]]; then
  project_declared_team="$(
    unset LINEAR_TEAM
    vstack_source_env_file "$PROJECT_ROOT/.env"
    vstack_load_settings_file "$PROJECT_ROOT/vstack.settings.toml"
    vstack_load_settings_file "$PROJECT_ROOT/.vstack/settings.toml"
    vstack_source_env_file "$PROJECT_ROOT/.env.local"
    printf '%s' "${LINEAR_TEAM:-}"
  )" || project_declared_team=""
fi

team_source_file=""
if [[ -n "$PROJECT_ROOT" ]]; then
  for candidate in .env vstack.settings.toml .vstack/settings.toml .env.local; do
    [[ -f "$PROJECT_ROOT/$candidate" ]] || continue
    if grep -Eq '^[[:space:]]*(export[[:space:]]+)?LINEAR_TEAM[[:space:]]*=' "$PROJECT_ROOT/$candidate"; then
      team_source_file="$candidate"
    fi
  done
fi

warnings=()

if [[ -z "$LINEAR_TEAM_TARGET" ]]; then
  # Nothing resolved, so no file is the source of the target.
  team_source_file=""
  warnings+=("No LINEAR_TEAM configured: Linear writes are refused. Set LINEAR_TEAM in vstack.settings.toml [env] (committed, non-secret) or .env.local.")
  if [[ "${LINEAR_TEAM_ENV_BLANK:-0}" == "1" && -n "$project_declared_team" ]]; then
    warnings+=("LINEAR_TEAM is exported as an empty value, which overrides the project value (\"$project_declared_team\"). Unset it in the environment to use project configuration.")
  fi
  if [[ "$LINEAR_API_KEY_SOURCE" == "environment" ]]; then
    warnings+=("LINEAR_API_KEY comes from the process environment (a machine-wide key reaches every workspace it owns) while this project names no team. Until LINEAR_TEAM is set, this project has no Linear target of its own.")
  fi
elif [[ "$LINEAR_TEAM_SOURCE" == "environment" ]]; then
  team_source_file=""
  if [[ -n "$project_declared_team" && "$project_declared_team" != "$LINEAR_TEAM_TARGET" ]]; then
    warnings+=("LINEAR_TEAM from the process environment (\"$LINEAR_TEAM_TARGET\") overrides the project value (\"$project_declared_team\"). Writes go to the environment value.")
  fi
fi

emit() {
  local ok="$1"
  local error="${2:-}"
  local writes_enabled="false"
  [[ -n "$LINEAR_TEAM_TARGET" ]] && writes_enabled="true"

  jq -cn \
    --argjson ok "$ok" \
    --arg error "$error" \
    --arg team "$LINEAR_TEAM_TARGET" \
    --arg team_source "$LINEAR_TEAM_SOURCE" \
    --arg team_source_file "$team_source_file" \
    --arg api_key_source "$LINEAR_API_KEY_SOURCE" \
    --argjson writes_enabled "$writes_enabled" \
    --args \
    '{ok: $ok}
     + (if $error == "" then {} else {error: $error} end)
     + {
         team: (if $team == "" then null else $team end),
         team_source: $team_source,
         team_source_file: (if $team_source_file == "" then null else $team_source_file end),
         api_key_source: $api_key_source,
         writes_enabled: $writes_enabled,
         warnings: $ARGS.positional
       }' "${warnings[@]+"${warnings[@]}"}"
}

if [[ -z "${LINEAR_API_KEY:-}" ]]; then
  emit false "LINEAR_API_KEY not set"
  exit 1
fi

result=$(graphql_query "{ viewer { id } }" "{}" 2>/dev/null) || {
  emit false "API request failed"
  exit 1
}

viewer_id=$(echo "$result" | jq -r '.viewer.id // empty')
if [[ -z "$viewer_id" ]]; then
  emit false "Invalid API key"
  exit 1
fi

emit true
if ((strict)) && [[ -z "$LINEAR_TEAM_TARGET" ]]; then
  exit 1
fi
