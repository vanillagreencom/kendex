#!/bin/bash
# Linear GraphQL API - Common functions
# Source this file in command scripts

set -euo pipefail

# Configuration
LINEAR_API="https://api.linear.app/graphql"

# Linear API field limits (discovered through testing)
LINEAR_LIMIT_SHORT_DESC=255    # Initiatives, projects, milestones, labels
LINEAR_LIMIT_ISSUE_DESC=100000 # Issues have no practical limit

# Internal lib directory (underscore prefix avoids overwriting caller's SCRIPT_DIR)
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

linear_canonical_existing_dir() {
    local path="$1"
    [[ -d "$path" ]] || return 1
    (cd "$path" && pwd -P)
}

# Command scripts may be invoked directly instead of through linear.sh. Keep
# their runtime failure deterministic and ahead of Bash-4-only shared config.
# shellcheck source=bash-version.sh
source "$_LIB_DIR/bash-version.sh"
linear_require_supported_bash || exit $?

PROJECT_ROOT_RAW="$(git rev-parse --show-toplevel 2>/dev/null)"
PROJECT_ROOT="$(linear_canonical_existing_dir "$PROJECT_ROOT_RAW")"
unset PROJECT_ROOT_RAW

# First 12 hex chars of sha256 — enough to tell two keys apart in a diagnostic
# without exposing key material. macOS ships shasum, not sha256sum.
linear_key_fingerprint() {
    if command -v sha256sum &>/dev/null; then
        printf '%s' "$1" | sha256sum | cut -c1-12
    else
        printf '%s' "$1" | shasum -a 256 | cut -c1-12
    fi
}

# LINEAR_API_KEY precedence, highest first:
#   1. LINEAR_API_KEY_OVERRIDE — the explicit inline channel. Tests rely on it
#      so fake/op:// values are not replaced by a developer's .env.local.
#   2. Project files (settings [env], then .env.local).
#   3. Plain inherited LINEAR_API_KEY — only when no file provides a key.
# Per-repo workspaces make a box-global export actively wrong for every other
# repo, so unlike LINEAR_TEAM the inherited key must never shadow the project's
# own (#1002). kendex_load_project_env re-asserts parent env over project files,
# so the inherited value is snapshotted and unset before the files load.
_CALLER_LINEAR_API_KEY="${LINEAR_API_KEY:-}"
unset LINEAR_API_KEY

# Captured before project files load so auth-check can tell a box-global export
# (which reaches whatever workspace the key owns) from project configuration.
# An exported-but-empty value is tracked separately: the env snapshot in
# kendex-env.sh makes it win over the project files, so it silently blocks a
# configured team rather than being absent.
_CALLER_LINEAR_TEAM_SET="${LINEAR_TEAM+x}"
_CALLER_LINEAR_TEAM="${LINEAR_TEAM:-}"

# Load public config and local secrets before deriving defaults.
# shellcheck source=kendex-env.sh
source "$_LIB_DIR/kendex-env.sh"
kendex_load_project_env "$PROJECT_ROOT"

# Seconds before the first retry of a rate-limited or failed GraphQL call;
# each further attempt doubles it. Overridable so a suite driving the retry
# path against a stubbed curl does not spend the real backoff — the wait is
# for Linear's benefit, and there is no Linear on the other end of a stub.
#
# Below the project load, where every LINEAR_* value resolves:
# kendex_load_project_env snapshots only EXPORTED names, so a default assigned
# above it is a plain variable the settings files overwrite unvalidated. Base
# ten at the seed, so a leading zero is decimal and not the octal 08 rejects.
# Bounded on width too, and 18 digits survives all three doublings: past that
# the arithmetic wraps and the backoff is a negative sleep, not a refusal.
LINEAR_RETRY_BASE_DELAY="${LINEAR_RETRY_BASE_DELAY:-1}"
if ! [[ "$LINEAR_RETRY_BASE_DELAY" =~ ^[0-9]{1,18}$ ]]; then
    echo '{"error": "LINEAR_RETRY_BASE_DELAY must be a whole number of seconds"}' >&2
    exit 1
fi
LINEAR_RETRY_BASE_DELAY=$((10#$LINEAR_RETRY_BASE_DELAY))

# Where each target-selecting value came from: override (LINEAR_API_KEY_OVERRIDE),
# project-config (kendex.settings.toml / .env.local), environment (process
# env, used because the project files provided nothing), or unset. auth-check
# reports these; a global key with no project team is the combination that
# writes into another project's workspace.
_PROJECT_LINEAR_API_KEY="${LINEAR_API_KEY:-}"
if [[ -n "${LINEAR_API_KEY_OVERRIDE:-}" ]]; then
    LINEAR_API_KEY="$LINEAR_API_KEY_OVERRIDE"
    export LINEAR_API_KEY
    LINEAR_API_KEY_SOURCE="override"
elif [[ -n "$_PROJECT_LINEAR_API_KEY" ]]; then
    LINEAR_API_KEY_SOURCE="project-config"
elif [[ -n "$_CALLER_LINEAR_API_KEY" ]]; then
    LINEAR_API_KEY="$_CALLER_LINEAR_API_KEY"
    export LINEAR_API_KEY
    LINEAR_API_KEY_SOURCE="environment"
else
    LINEAR_API_KEY_SOURCE="unset"
fi

# The silent-shadowing signature: an inherited env key existed, a differing
# project-file key won. auth-check surfaces it as a warning — fingerprints
# only, never key material.
LINEAR_API_KEY_ENV_SHADOWED=0
LINEAR_API_KEY_ENV_FINGERPRINT=""
LINEAR_API_KEY_PROJECT_FINGERPRINT=""
if [[ "$LINEAR_API_KEY_SOURCE" == "project-config" && -n "$_CALLER_LINEAR_API_KEY" &&
    "$_CALLER_LINEAR_API_KEY" != "$_PROJECT_LINEAR_API_KEY" ]]; then
    LINEAR_API_KEY_ENV_SHADOWED=1
    LINEAR_API_KEY_ENV_FINGERPRINT="$(linear_key_fingerprint "$_CALLER_LINEAR_API_KEY")"
    LINEAR_API_KEY_PROJECT_FINGERPRINT="$(linear_key_fingerprint "$_PROJECT_LINEAR_API_KEY")"
fi

if [[ -n "$_CALLER_LINEAR_TEAM" ]]; then
    LINEAR_TEAM_SOURCE="environment"
elif [[ -n "${LINEAR_TEAM:-}" ]]; then
    LINEAR_TEAM_SOURCE="project-config"
else
    LINEAR_TEAM_SOURCE="unset"
fi

# 1 when the process environment exported LINEAR_TEAM as an empty value, which
# resolves to no target while shadowing anything the project files declare.
if [[ -n "$_CALLER_LINEAR_TEAM_SET" && -z "$_CALLER_LINEAR_TEAM" ]]; then
    LINEAR_TEAM_ENV_BLANK=1
else
    LINEAR_TEAM_ENV_BLANK=0
fi

unset _CALLER_LINEAR_API_KEY _PROJECT_LINEAR_API_KEY _CALLER_LINEAR_TEAM _CALLER_LINEAR_TEAM_SET

# Default values can be overridden by kendex.settings.toml [env] or .env.local.
# LINEAR_TEAM has no built-in fallback on purpose: a team name resolves inside
# whatever workspace the API key reaches, so a guessed default silently targets
# another project's tracker. Unset means "no team" — reads drop the team filter,
# writes refuse (see linear_require_team_target).
DEFAULT_TEAM="${LINEAR_TEAM:-}"
DEFAULT_FORMAT="${LINEAR_FORMAT:-safe}"    # safe, raw, ids, table
DEFAULT_PREFIX="${LINEAR_TEAM_PREFIX:-PROJ}" # Issue identifier prefix (e.g., PROJ-123)

# Team target for this invocation. An explicit --team registers over the
# configured value through linear_set_team_target.
LINEAR_TEAM_TARGET="$DEFAULT_TEAM"

# Source formatters
source "$_LIB_DIR/formatters.sh"

# Resolve 1Password references when the env file contains op:// secrets.
resolve_linear_api_key() {
    local token="${LINEAR_API_KEY:-}"

    if [[ -z "$token" ]]; then
        return 0
    fi

    if [[ "$token" == op://* ]]; then
        if command -v op &>/dev/null; then
            local resolved
            if resolved=$(op read "$token" 2>/dev/null); then
                LINEAR_API_KEY="$resolved"
                export LINEAR_API_KEY
            else
                echo '{"error": "Failed to resolve LINEAR_API_KEY from 1Password. Run: op signin"}' >&2
                return 1
            fi
        else
            echo '{"error": "LINEAR_API_KEY is a 1Password reference but the op CLI is not installed"}' >&2
            return 1
        fi
    fi

    return 0
}

# Most commands hit the Linear API and should resolve op:// references during
# startup so authentication failures surface before any mutation/read work.
# Local-cache commands source this file only for shared formatters/defaults; they
# must not require API auth for documented cache-only reads.
if [[ "${LINEAR_SKIP_API_KEY_RESOLUTION:-}" != "1" ]]; then
    resolve_linear_api_key || exit 1
fi

# Validate API key
check_api_key() {
    if [ -z "${LINEAR_API_KEY:-}" ]; then
        echo '{"error": "LINEAR_API_KEY not set. Add it to .env.local or export it."}' >&2
        exit 1
    fi
}

json_or_default() {
    local fallback="$1"
    local expected_type="$2"
    shift 2

    local output=""
    if ! output=$("$@" 2>/dev/null); then
        :
    fi

    if ! jq -e --arg type "$expected_type" 'type == $type' >/dev/null 2>&1 <<<"$output"; then
        output="$fallback"
    fi

    printf '%s' "$output"
}

curl_config_quote() {
    printf '%s' "$1" | jq -Rs .
}

# Validate field length and return error if exceeded
# Usage: validate_length "field_name" "$value" $max_length
validate_length() {
    local field="$1"
    local value="$2"
    local max="$3"
    local len=${#value}

    if [ $len -gt $max ]; then
        echo "{\"error\": \"$field exceeds max length ($len > $max chars)\"}" >&2
        return 1
    fi
    return 0
}

# A GraphQL document is a write when its first token is `mutation`.
linear_query_is_mutation() {
    local query="${1:-}"
    local leading="${query%%[![:space:]]*}"
    query="${query#"$leading"}"

    case "$query" in
    mutation | mutation[!A-Za-z0-9_]*) return 0 ;;
    esac
    return 1
}

# Make GraphQL request with error handling and retry
# Usage: graphql_query "query string" '{"var": "value"}'
graphql_query() {
    local query="$1"
    local variables="$2"
    if [ -z "$variables" ]; then
        variables='{}'
    fi
    local max_retries=3
    local retry_delay="$LINEAR_RETRY_BASE_DELAY"
    local attempt=1

    # Single choke point for writes: no mutation leaves this process without a
    # resolved team target, whatever path built it.
    if linear_query_is_mutation "$query"; then
        linear_require_team_target || return 1
    fi

    check_api_key

    while [ $attempt -le $max_retries ]; do
        local response
        local http_code
        local payload

        # Use unique delimiter to separate response from HTTP code
        # This handles JSON with literal newlines in string values
        local delimiter="___HTTP_CODE___"
        local raw_output
        if ! payload=$(jq -cn --arg query "$(echo "$query" | tr '\n' ' ')" --argjson variables "$variables" \
            '{query: $query, variables: $variables}'); then
            echo '{"error": "Invalid GraphQL variables JSON"}' >&2
            return 1
        fi

        if ! raw_output=$(
            printf '%s\n' \
                "url = $(curl_config_quote "$LINEAR_API")" \
                'request = "POST"' \
                "header = $(curl_config_quote "Content-Type: application/json")" \
                "header = $(curl_config_quote "Authorization: $LINEAR_API_KEY")" \
                "data = $(curl_config_quote "$payload")" \
            | curl -s -w "${delimiter}%{http_code}" -K -
        ); then
            raw_output="${delimiter}000"
        fi

        http_code="${raw_output##*${delimiter}}"
        response="${raw_output%${delimiter}*}"

        # Linear emits rate-limit rejections with an OUTER HTTP 400 (the body
        # carries extensions.code RATELIMITED / extensions.statusCode 429), so
        # normalize on the body marker: without this they fall into the
        # generic branch and surface as "HTTP error: 400" — and callers like
        # resolve_team_id then compound it into "Team not found".
        if [ "$http_code" != "200" ] && echo "$response" | jq -e \
            '[.errors[]? | select(.extensions.code == "RATELIMITED")] | length > 0' >/dev/null 2>&1; then
            http_code=429
        fi

        # Handle HTTP errors
        case "$http_code" in
        200)
            # Check for GraphQL errors
            local errors
            errors=$(echo "$response" | jq -r '.errors // empty')
            if [ -n "$errors" ] && [ "$errors" != "null" ]; then
                local error_msg
                error_msg=$(echo "$response" | jq -r '.errors[0].message')
                # Translate common errors to actionable messages
                case "$error_msg" in
                *"labelIds not exclusive"*)
                    echo '{"error": "Label conflict: Mutually exclusive label groups detected. Check --labels for conflicting group labels"}' >&2
                    ;;
                *"Issue not found"*)
                    echo '{"error": "Issue not found. Check the identifier (e.g., PROJ-42)"}' >&2
                    ;;
                *"Project not found"*)
                    echo '{"error": "Project not found. Use exact name or UUID"}' >&2
                    ;;
                *"relation"*"exist"* | *"already exist"* | *"duplicate"*"relation"*)
                    # Idempotent: relation/dependency already exists — not an error
                    echo '{"already_exists": true}' >&2
                    echo '{"already_exists": true}'
                    return 0
                    ;;
                *)
                    echo "$response" | jq -c '{error: .errors[0].message}' >&2
                    ;;
                esac
                return 1
            fi
            # Success - return data
            echo "$response" | jq -c '.data'
            return 0
            ;;
        401)
            echo '{"error": "Authentication failed. Check your LINEAR_API_KEY."}' >&2
            return 1
            ;;
        429)
            if [ $attempt -lt $max_retries ]; then
                sleep $retry_delay
                retry_delay=$((retry_delay * 2))
                attempt=$((attempt + 1))
                continue
            fi
            echo '{"error": "Rate limited. Try again later."}' >&2
            return 1
            ;;
        *)
            if [ $attempt -lt $max_retries ]; then
                sleep $retry_delay
                retry_delay=$((retry_delay * 2))
                attempt=$((attempt + 1))
                continue
            fi
            # Carry the body's first error message: a bare status code hides
            # the actionable reason (validation detail, quota text, ...).
            local error_detail
            error_detail=$(echo "$response" | jq -r '.errors[0].message // empty' 2>/dev/null || true)
            if [ -n "$error_detail" ]; then
                jq -cn --arg code "$http_code" --arg msg "$error_detail" \
                    '{error: ("HTTP error: " + $code + ": " + $msg)}' >&2
            else
                echo "{\"error\": \"HTTP error: $http_code\"}" >&2
            fi
            return 1
            ;;
        esac
    done
}

# Reject a value before it reaches a spot that cannot defend itself: an unquoted
# splice into a JSON payload, a jq program, or a shell arithmetic context. Each
# of those turns a malformed value into either a wrong-cause diagnostic ("Invalid
# GraphQL variables JSON") or an injection point.
# Usage: linear_require_pattern --priority "$priority" '^[0-4]$' "an integer 0-4"
linear_require_pattern() {
    local flag="$1" value="$2" pattern="$3" expected="$4"
    if [[ "$value" =~ $pattern ]]; then
        return 0
    fi
    jq -cn --arg flag "$flag" --arg v "$value" --arg exp "$expected" \
        '{error: ($flag + " must be " + $exp + ", got: " + $v)}' >&2
    return 1
}

# Reject an unsupported --format before any API or cache work, rather than
# letting a `safe | *` catch-all silently serve safe output under the name the
# caller asked for. The supported set differs per action (only the list actions
# emit ids), so each caller passes its own.
# Usage: linear_require_format "$FORMAT" safe raw compact
linear_require_format() {
    local value="$1"
    shift
    local candidate
    for candidate in "$@"; do
        [ "$value" = "$candidate" ] && return 0
    done
    local list
    list=$(printf '%s, ' "$@")
    jq -cn --arg v "$value" --arg list "${list%, }" \
        '{error: ("Invalid format: " + $v + ". Use: " + $list)}' >&2
    return 1
}

LINEAR_UUID_PATTERN='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# An option that takes a value must have one. Without this a trailing `--label`
# expands `$2` under `set -u` and dies naming `$2` rather than the flag.
linear_require_option_value() {
    local flag="$1"
    if [ "$#" -lt 2 ]; then
        jq -cn --arg flag "$flag" '{error: ($flag + " requires a value")}' >&2
        return 1
    fi
    return 0
}

# Days-before-now as an ISO timestamp, for the --updated-since/--created-since
# "7d" spelling. GNU and BSD date disagree on the flag, so both are tried; a
# non-numeric count is rejected here rather than reaching either.
linear_iso_days_ago() {
    local flag="$1" spec="$2"
    local days="${spec%d}"
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        jq -cn --arg flag "$flag" --arg spec "$spec" \
            '{error: ($flag + " expects a day count such as 7d, got: " + $spec)}' >&2
        return 1
    fi
    date -d "-$days days" -Iseconds 2>/dev/null || date -v-"${days}"d -Iseconds
}

# Parse common CLI arguments into GraphQL filter
# Usage: parse_filter "$@"
# Sets global FILTER_JSON variable
# Every value is carried through jq --arg: a label, project, team, or state name
# holding a quote or backslash must not be able to reshape the filter object.
parse_filter() {
    local filter_parts=()
    local first=75
    local include_archived="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --label)
            linear_require_option_value "$@" || return 1
            filter_parts+=("$(jq -cn --arg v "$2" '{labels: {name: {eq: $v}}}')")
            shift 2
            ;;
        --state | --status)
            linear_require_option_value "$@" || return 1
            # A comma-separated list becomes an `in` match; a single name an `eq`.
            filter_parts+=("$(jq -cn --arg v "$2" '
                ($v | split(",") | map(sub("^\\s+"; "") | sub("\\s+$"; ""))) as $names |
                if ($names | length) == 1
                then {state: {name: {eq: $names[0]}}}
                else {state: {name: {in: $names}}}
                end')")
            shift 2
            ;;
        --project)
            linear_require_option_value "$@" || return 1
            filter_parts+=("$(jq -cn --arg v "$2" '{project: {name: {eq: $v}}}')")
            shift 2
            ;;
        --project-id)
            linear_require_option_value "$@" || return 1
            filter_parts+=("$(jq -cn --arg v "$2" '{project: {id: {eq: $v}}}')")
            shift 2
            ;;
        --team)
            linear_require_option_value "$@" || return 1
            filter_parts+=("$(jq -cn --arg v "$2" '{team: {name: {eq: $v}}}')")
            shift 2
            ;;
        --assignee)
            linear_require_option_value "$@" || return 1
            if [ "$2" = "me" ]; then
                filter_parts+=('{"assignee": {"isMe": {"eq": true}}}')
            else
                filter_parts+=("$(jq -cn --arg v "$2" '{assignee: {name: {eq: $v}}}')")
            fi
            shift 2
            ;;
        --updated-since)
            linear_require_option_value "$@" || return 1
            local updated_since
            updated_since=$(linear_iso_days_ago "$1" "$2") || return 1
            filter_parts+=("$(jq -cn --arg v "$updated_since" '{updatedAt: {gte: $v}}')")
            shift 2
            ;;
        --created-since)
            linear_require_option_value "$@" || return 1
            local created_since
            created_since=$(linear_iso_days_ago "$1" "$2") || return 1
            filter_parts+=("$(jq -cn --arg v "$created_since" '{createdAt: {gte: $v}}')")
            shift 2
            ;;
        --limit)
            linear_require_option_value "$@" || return 1
            # FIRST_JSON is spliced into the variables payload and compared
            # numerically by callers; anything else corrupts both.
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                jq -cn --arg v "$2" '{error: ("--limit must be a non-negative integer, got: " + $v)}' >&2
                return 1
            fi
            first="$2"
            shift 2
            ;;
        --include-archived)
            include_archived="true"
            shift
            ;;
        --*)
            echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2
            return 1
            ;;
        *)
            # Positional argument - skip
            shift
            ;;
        esac
    done

    if [ ${#filter_parts[@]} -gt 0 ]; then
        FILTER_JSON=$(printf '%s\n' "${filter_parts[@]}" | jq -cs 'add')
    else
        FILTER_JSON="{}"
    fi
    FIRST_JSON="$first"
    INCLUDE_ARCHIVED_JSON="$include_archived"
}

# Resolve issue identifier (CC-XXX) or UUID to UUID
# Usage: resolve_issue_id "PROJ-42" or resolve_issue_id "uuid-here"
resolve_issue_id() {
    local issue_ref="$1"

    # Check if it's already a UUID
    if [[ "$issue_ref" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo "$issue_ref"
        return 0
    fi

    # Look up by identifier (e.g., PROJ-42)
    local query='query GetIssue($id: String!) { issue(id: $id) { id } }'
    local vars result
    vars=$(jq -cn --arg id "$issue_ref" '{id: $id}')
    result=$(graphql_query "$query" "$vars")
    local issue_id
    issue_id=$(echo "$result" | jq -r '.issue.id // empty')

    if [ -z "$issue_id" ]; then
        echo "" >&2
        return 1
    fi

    echo "$issue_id"
}

# Normalize mutation response to consistent structure
# Usage: normalize_mutation_response "$result" "issueCreate" "issue"
# Returns: {"success": bool, "identifier": "CC-XXX", "url": "...", "data": {...}}
normalize_mutation_response() {
    local result="$1"
    local operation="$2"
    local entity="$3"

    echo "$result" | jq --arg op "$operation" --arg ent "$entity" '{
        success: .[$op].success,
        identifier: .[$op][$ent].identifier,
        url: (.[$op][$ent].url // null),
        data: .[$op]
    }'
}

# Team targeting
# -----------------------------------------------------------------------------
# Nothing below invents a team name. The API key alone decides which workspace a
# name resolves in, so a substituted default writes into whichever tracker that
# key reaches.

# Set the team target for this invocation: explicit --team wins, otherwise the
# configured LINEAR_TEAM (which may be empty).
# Usage: linear_set_team_target "$team"; team="$LINEAR_TEAM_TARGET"
linear_set_team_target() {
    local explicit="${1:-}"
    if [ -n "$explicit" ]; then
        LINEAR_TEAM_TARGET="$explicit"
    else
        LINEAR_TEAM_TARGET="$DEFAULT_TEAM"
    fi
}

linear_team_target_error() {
    echo '{"error": "No Linear team configured for this project - refusing to write. A team name resolves inside whatever workspace LINEAR_API_KEY reaches, so writing without one can land in another project tracker. Fix: set LINEAR_TEAM in this project kendex.settings.toml [env] (committed, non-secret) or .env.local. The create actions that take a team (issues, projects, cycles, labels) also accept --team <name> for one call. Verify with: linear.sh auth-check --strict"}' >&2
}

# Fail-closed gate for every Linear write.
linear_require_team_target() {
    if [ -n "${LINEAR_TEAM_TARGET:-}" ]; then
        return 0
    fi
    linear_team_target_error
    return 1
}

# Dispatcher guard: refuse a write action before any API call when no team target
# resolves. It never searches argv for a team - a `--team` token in unparsed
# arguments is just as likely to be free text (a comment body, an issue title),
# and honoring it would let user content open the gate. Only the first remaining
# argument is read, and only to let `<action> --help` through. The action list
# therefore holds only the write actions with no --team parser of their own;
# actions that do parse it call linear_set_team_target + linear_require_team_target
# after their parse loop, before any API call. graphql_query enforces the same
# rule at the wire, so a missing entry degrades to a later refusal, never to a
# write.
# Usage: linear_guard_write_action "$action" "update delete" "$@" || exit 1
linear_guard_write_action() {
    local action="${1:-}"
    local write_actions="${2:-}"
    local first_arg="${3:-}"

    case " $write_actions " in
    *" $action "*) ;;
    *) return 0 ;;
    esac

    # `<action> --help` prints usage and writes nothing.
    case "$first_arg" in
    --help | -h) return 0 ;;
    esac

    linear_require_team_target
}

# Resolve project name or UUID to UUID
# Usage: resolve_project_id "Phase 1" or resolve_project_id "uuid-here"
#
# Linear keeps a canceled project under the name a live one reuses, and the
# name query returns both in no fixed order, so nodes[0] handed writes the
# canceled one at random and `issues create --project` reported success on an
# issue nobody could find (KEN-1022). A canceled match loses to every live one;
# an all-canceled match set is refused, naming its UUIDs so a deliberate read
# can pass one.
resolve_project_id() {
    local project_ref="$1"

    # Check if it's already a UUID
    if [[ "$project_ref" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo "$project_ref"
        return 0
    fi

    # `state` is selected, not filtered on: the server-side `state` filter is
    # broken (see list_projects), and the whole match set is what separates
    # "no such project" from "only canceled ones".
    local query='query GetProject($name: String!) { projects(filter: {name: {eq: $name}}) { nodes { id state } } }'
    local variables
    variables=$(jq -nc --arg name "$project_ref" '{name: $name}')
    local result
    # A FAILED query is an API failure (rate limit, outage); "Project not
    # found" is only true of a lookup that succeeded and matched nothing.
    if ! result=$(graphql_query "$query" "$variables"); then
        jq -nc --arg name "$project_ref" \
            '{error: ("Could not resolve project \"" + $name + "\": Linear API request failed (see previous error)")}' >&2
        return 1
    fi

    # One pass, so the rejected list is the selection's complement rather than
    # a second predicate that can drift from it: line 1 is the chosen id, line 2
    # the rejected ones with the state that rejected each. A widened predicate
    # keeps the message true without being edited.
    local selection project_id rejected
    selection=$(echo "$result" | jq -r '
        (.projects.nodes // []) as $all
        | ($all | map(select((.state // "" | ascii_downcase) != "canceled"))) as $live
        | ($live[0].id // ""),
          ($all - $live | map(.id + " (" + .state + ")") | join(", "))')
    # Command substitution strips the trailing newline, so with nothing
    # rejected — one live project, the everyday case — the second read hits EOF
    # and returns 1. Under this file's errexit that status ends the function
    # before it can print the id it just resolved. Every call site in the skill
    # spells the call var=$(resolve_project_id ...), where bash does not apply
    # errexit, so the abort shows up only in a bare call or in a command
    # substitution under shopt -s inherit_errexit, which sync.sh sets.
    { IFS= read -r project_id; IFS= read -r rejected; } <<<"$selection" || true

    if [ -n "$project_id" ]; then
        echo "$project_id"
        return 0
    fi

    if [ -n "$rejected" ]; then
        jq -nc --arg name "$project_ref" --arg matches "$rejected" \
            '{error: ("Project not found: " + $name + " (no live project has this name; matches: " + $matches + "; pass a project UUID to target one)")}' >&2
        return 1
    fi

    jq -nc --arg message "Project not found: $project_ref" '{error: $message}' >&2
    return 1
}

# Resolve team name to UUID
# Usage: resolve_team_id "$LINEAR_TEAM_TARGET"
resolve_team_id() {
    local team_ref="$1"

    # Check if it's already a UUID
    if [[ "$team_ref" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo "$team_ref"
        return 0
    fi

    # Look up by name. A FAILED query must propagate as the API failure it
    # is (rate limit, outage) — "Team not found" is only true for a
    # successful lookup that returned no match.
    local query='query GetTeam($name: String!) { teams(filter: {name: {eq: $name}}) { nodes { id } } }'
    # Build variables and diagnostics with jq: a team name containing a
    # quote or backslash must neither break the request JSON nor the error.
    local vars result
    vars=$(jq -cn --arg name "$team_ref" '{name: $name}')
    if ! result=$(graphql_query "$query" "$vars"); then
        jq -cn --arg team "$team_ref" \
            '{error: ("Could not resolve team '\''" + $team + "'\'': Linear API request failed (see previous error)")}' >&2
        return 1
    fi
    local team_id
    team_id=$(echo "$result" | jq -r '.teams.nodes[0].id // empty')

    if [ -z "$team_id" ]; then
        jq -cn --arg team "$team_ref" '{error: ("Team not found: " + $team)}' >&2
        return 1
    fi

    echo "$team_id"
}

# Resolve workflow state name to UUID for a specific team
# Usage: resolve_state_id "In Progress" "team-uuid-or-name"
# Second arg can be team UUID or team name (will resolve)
resolve_state_id() {
    local state_name="$1"
    local team_ref="$2"

    # Resolve team to ID if needed (resolve_team_id handles UUID pass-through)
    local team_id
    team_id=$(resolve_team_id "$team_ref")
    if [ -z "$team_id" ]; then
        return 1
    fi

    # Look up state by name + team
    local query='query GetState($name: String!, $teamId: ID!) { workflowStates(filter: {name: {eq: $name}, team: {id: {eq: $teamId}}}) { nodes { id } } }'
    local vars result
    vars=$(jq -cn --arg name "$state_name" --arg teamId "$team_id" '{name: $name, teamId: $teamId}')
    result=$(graphql_query "$query" "$vars")
    local state_id
    state_id=$(echo "$result" | jq -r '.workflowStates.nodes[0].id // empty')

    if [ -z "$state_id" ]; then
        # Name the unknown state even when the follow-up listing fails — losing
        # the real diagnostic to a second failed request helps nobody.
        local team_vars all_result available=""
        team_vars=$(jq -cn --arg teamId "$team_id" '{teamId: $teamId}')
        local all_query='query GetStates($teamId: ID!) { workflowStates(filter: {team: {id: {eq: $teamId}}}) { nodes { name } } }'
        if all_result=$(graphql_query "$all_query" "$team_vars"); then
            available=$(echo "$all_result" | jq -r '[.workflowStates.nodes[].name] | join(", ")')
        fi
        jq -cn --arg name "$state_name" --arg available "$available" \
            '{error: ("State not found: " + ($name | tojson) +
                (if $available == "" then " (state list unavailable)" else ". Available: " + $available end))}' >&2
        return 1
    fi

    echo "$state_id"
}

# Resolve label name to UUID
# Usage: resolve_label_id "backend"
# Exit 1 = the workspace has no such label (a caller handling several labels may
# skip it). Exit 2 = the lookup itself failed, so whether the label exists is
# unknown — a caller rebuilding a label set must abort rather than drop it,
# because "not found" and "could not ask" produce the same empty result.
resolve_label_id() {
    local label_name="$1"

    local query='query GetLabel($name: String!) { issueLabels(filter: {name: {eq: $name}}) { nodes { id } } }'
    local vars result
    vars=$(jq -cn --arg name "$label_name" '{name: $name}')
    if ! result=$(graphql_query "$query" "$vars"); then
        jq -cn --arg name "$label_name" \
            '{error: ("Label lookup failed for " + ($name | tojson) + ": Linear API request failed (see previous error)")}' >&2
        return 2
    fi
    local label_id
    label_id=$(echo "$result" | jq -r '.issueLabels.nodes[0].id // empty')

    if [ -z "$label_id" ]; then
        echo "Warning: Label not found: '$label_name'" >&2
        return 1
    fi

    echo "$label_id"
}

# Resolve milestone name or UUID to UUID
# Usage: resolve_milestone_id "Alpha" or resolve_milestone_id "uuid-here"
resolve_milestone_id() {
    local milestone_ref="$1"

    # Check if it's already a UUID
    if [[ "$milestone_ref" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo "$milestone_ref"
        return 0
    fi

    # Look up by name
    local query='query GetMilestone($name: String!) { projectMilestones(filter: {name: {eq: $name}}) { nodes { id } } }'
    local vars result
    vars=$(jq -cn --arg name "$milestone_ref" '{name: $name}')
    result=$(graphql_query "$query" "$vars")
    local milestone_id
    milestone_id=$(echo "$result" | jq -r '.projectMilestones.nodes[0].id // empty')

    if [ -z "$milestone_id" ]; then
        jq -cn --arg ref "$milestone_ref" '{error: ("Milestone not found: " + $ref)}' >&2
        return 1
    fi

    echo "$milestone_id"
}
