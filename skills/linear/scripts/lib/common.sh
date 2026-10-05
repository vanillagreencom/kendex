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

# Both assignments sit in the condition on purpose (KEN-1193): `git rev-parse`
# exits 128 outside a repository and linear_canonical_existing_dir returns 1 on
# a path that is not a directory, and under `set -e` a bare assignment carries
# either status out before any guard below can print. Every subcommand died at
# a bare 128 with nothing on stdout or stderr. Everything past this line — the
# project settings, .env.local and the label taxonomy — is read from the
# repository, so the resolution refuses rather than degrading.
if ! PROJECT_ROOT_RAW="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || ! PROJECT_ROOT="$(linear_canonical_existing_dir "$PROJECT_ROOT_RAW")"; then
    jq -cn --arg cwd "$PWD" \
        '{error: ("Could not resolve a git repository from: " + $cwd + ". Run linear.sh from a checkout of the repository whose Linear workspace you mean.")}' >&2
    exit 1
fi
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
# own. kendex_load_project_env re-asserts parent env over project files,
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

# The local store is gone, and a root setting left in the environment or a
# project file would otherwise read as if it still redirected something.
if [[ -n "${LINEAR_CACHE_ROOT+set}" ]]; then
    printf '%s\n' 'linear-setting: retired=LINEAR_CACHE_ROOT' >&2
    printf '%s\n' 'Remove LINEAR_CACHE_ROOT from the environment, kendex.settings.toml and .env.local: every read goes to the live API and no local store exists to redirect.' >&2
    exit 1
fi

# Seconds before the first retry of a rate-limited, 5xx or unanswered call;
# each further attempt doubles it. Overridable so a suite driving the retry
# path against a stubbed curl does not spend the real backoff — the wait is
# for Linear's benefit, and there is no Linear on the other end of a stub.
#
# Below the project load, where every LINEAR_* value resolves:
# kendex_load_project_env snapshots only EXPORTED names, so a default assigned
# above it is a plain variable the settings files overwrite unvalidated. Base
# ten at the seed, so a leading zero is decimal and not the octal 08 rejects.
# Bounded on width too, and 18 digits survives the doubling: past that
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
# writes needing a configured team refuse (see linear_require_team_target).
DEFAULT_TEAM="${LINEAR_TEAM:-}"
DEFAULT_FORMAT="${LINEAR_FORMAT:-safe}"    # safe, raw, ids, table
DEFAULT_PREFIX="${LINEAR_TEAM_PREFIX:-PROJ}" # Issue identifier prefix (e.g., PROJ-123)

# Team target for this invocation. An explicit --team registers over the
# configured value through linear_set_team_target.
LINEAR_TEAM_TARGET="$DEFAULT_TEAM"

# Source formatters
source "$_LIB_DIR/formatters.sh"
# shellcheck source=cycle-dates.sh
source "$_LIB_DIR/cycle-dates.sh"

# shellcheck source=auth.sh
source "$_LIB_DIR/auth.sh"

# Every command but auth-mint reads the selected credential, so op://
# references resolve at startup and an authentication failure surfaces before
# any read or write. auth-mint resolves the client pair on its own.
if [[ "${LINEAR_SKIP_API_KEY_RESOLUTION:-}" != "1" ]]; then
    linear_resolve_credentials || exit 1
fi

# Validate API key
check_api_key() {
    linear_check_credentials
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

# The value of one header in an answer's header block, the last when it
# repeats, or nothing when the block lacks it. NAME is lower case.
# Usage: linear_header_value <name> "$headers"
linear_header_value() {
    awk -v name="$1:" 'tolower($1) == name { gsub("\r", "", $2); value = $2 } END { print value }' <<<"$2"
}

# Reports a rate-limited final answer, a GraphQL request's or a download's,
# as one JSON line on stderr naming the time the request quota refills, so a
# caller can hold its write until then. The time is an ISO-8601 UTC instant
# read from Linear's X-RateLimit-Requests-Reset header (epoch milliseconds),
# or "unavailable" when the answer carried no usable value.
# Usage: linear_rate_limited "$headers"; return 1
linear_rate_limited() {
    local value reset
    value=$(linear_header_value x-ratelimit-requests-reset "$1") || return 1
    if [[ "$value" =~ ^[0-9]{1,15}$ ]]; then
        reset=$(jq -rn --arg ms "$value" '$ms | tonumber / 1000 | floor | todate') || return 1
    else
        reset=unavailable
    fi
    jq -cn --arg reset "$reset" \
        '{error: ("Rate limited. Requests-Reset=" + $reset), code: "RATELIMITED", requests_reset: $reset}' >&2
}

# Whether a request is sent again after an answer, every Linear request and
# attachment download deciding alike: a rate-limited answer (HTTP 429), a 5xx
# or no answer at all (curl reached no server, code 000) may succeed when sent
# again, twice at most. A 4xx such as a scope or validation refusal answers
# the same way every time. The wait doubles from LINEAR_RETRY_BASE_DELAY, or
# is the answer's Retry-After when that names more whole seconds; a
# Retry-After over 60 seconds makes the answer final, since a request sent
# sooner would be refused again and a caller is better served by the failure
# than by a minute-long hang. ATTEMPT counts the answers so far.
# Returns 0 once the wait is over, 1 when the answer is final.
# Usage: linear_retry_wait <code> <attempt> "$headers"
linear_retry_wait() {
    local code="$1" attempt="$2" delay after
    case "$code" in
    429 | 5?? | 000) ;;
    *) return 1 ;;
    esac
    ((attempt < 3)) || return 1
    delay=$((LINEAR_RETRY_BASE_DELAY << (attempt - 1)))
    after=$(linear_header_value retry-after "$3") || return 1
    if [[ "$after" =~ ^[0-9]{1,9}$ ]]; then
        after=$((10#$after))
        ((after <= 60)) || return 1
        ((after <= delay)) || delay="$after"
    fi
    sleep "$delay"
}

# One POST to Linear, sent again while linear_retry_wait says so. Linear
# serves its RATELIMITED code under a 400 and could serve it under any
# status, so a body carrying it is a rate-limited answer whatever the status.
# A rate-limited final answer is reported by linear_rate_limited and
# returns 1.
# Otherwise prints the final status on the first line and the body after it.
# CONFIG is the curl config lines naming the request.
# Usage: reply=$(linear_http_post "$config") || return 1
linear_http_post() {
    local config="$1" attempt=1 raw code body headers
    local delimiter="___HTTP_CODE___"
    while true; do
        headers=''
        # Headers go to stdout ahead of the body ("-" is curl's own stdout
        # stream, so they cannot interleave), and are split off below.
        if ! raw=$(printf '%s\n%s\n' "$config" 'dump-header = "-"' | curl -s -w "${delimiter}%{http_code}" -K -); then
            raw="${delimiter}000"
        fi
        code="${raw##*"$delimiter"}"
        body="${raw%"$delimiter"*}"
        # A proxy's CONNECT answer or an interim 100 adds a header block of its
        # own before the response's; a JSON body never starts with HTTP/.
        while [[ "$body" == HTTP/* && "$body" == *$'\r\n\r\n'* ]]; do
            headers="${body%%$'\r\n\r\n'*}"
            body="${body#*$'\r\n\r\n'}"
        done
        if jq -e '[.errors[]? | select(.extensions.code == "RATELIMITED")] | length > 0' >/dev/null 2>&1 <<<"$body"; then
            code=429
        fi
        if linear_retry_wait "$code" "$attempt" "$headers"; then
            attempt=$((attempt + 1))
            continue
        fi
        if [[ "$code" == 429 ]]; then
            linear_rate_limited "$headers"
            return 1
        fi
        printf '%s\n%s' "$code" "$body"
        return 0
    done
}

# One GraphQL request, as the transport every read and write goes through.
# linear_http_post owns which answers are sent again; an app pair's token is
# renewed once on an HTTP 401. Returns 2 when Linear answers that the entity
# the request names does not exist for this actor ("Entity not found: Issue",
# under HTTP 200), and 1 on every other failure, so a caller can tell "no
# such thing" from "the read failed". graphql_query passes that status
# through; only graphql_pages returns 1 for both.
# Usage: graphql_request "query string" '{"var": "value"}'
graphql_request() {
    local query="$1"
    local variables="$2"
    if [ -z "$variables" ]; then
        variables='{}'
    fi
    local authorization auth_renewed=0 payload reply http_code response

    check_api_key || return 1
    authorization=$(linear_authorization) || return 1
    # Variables go in on stdin: one argv string is capped at 128 KiB
    # (MAX_ARG_STRLEN), which a long description or a large id filter
    # passes. Slurped so a second or trailing value still refuses.
    if ! payload=$(jq -cs --arg query "$(echo "$query" | tr '\n' ' ')" \
        'if length == 1 then {query: $query, variables: .[0]} else error("not one JSON value") end' \
        <<<"$variables"); then
        echo '{"error": "Invalid GraphQL variables JSON"}' >&2
        return 1
    fi

    while true; do
        reply=$(linear_http_post "$(printf '%s\n' \
            "url = $(curl_config_quote "$LINEAR_API")" \
            'request = "POST"' \
            "header = $(curl_config_quote "Content-Type: application/json")" \
            "header = $(curl_config_quote "Authorization: $authorization")" \
            "data = $(curl_config_quote "$payload")")") || return 1
        http_code="${reply%%$'\n'*}"
        response="${reply#*$'\n'}"

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
                "Entity not found: "*)
                    jq -cn --arg msg "$error_msg" '{error: $msg}' >&2
                    return 2
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
            if [[ "$LINEAR_AUTH_KIND" == "app" && "$auth_renewed" == 0 ]]; then
                authorization=$(linear_authorization renew) || return 1
                auth_renewed=1
                continue
            fi
            linear_auth_unauthorized
            return 1
            ;;
        esac

        # Carry the body's first error message: a bare status code hides
        # the actionable reason (validation detail, quota text, ...).
        # A body that is not JSON, such as a proxy's HTML error page, carries
        # no message, and the status code alone is reported.
        local error_detail=""
        if ! error_detail=$(jq -r '.errors[0].message // empty' 2>/dev/null <<<"$response"); then
            error_detail=""
        fi
        if [ -n "$error_detail" ]; then
            jq -cn --arg code "$http_code" --arg msg "$error_detail" \
                '{error: ("HTTP error: " + $code + ": " + $msg)}' >&2
        else
            echo "{\"error\": \"HTTP error: $http_code\"}" >&2
        fi
        return 1
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

# Reject an unsupported --format before any API work, rather than
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

# A --team read filter must name a team. A workflow interpolating an unresolved
# $LINEAR_TEAM writes `--team ""`, which would send no team filter and read
# every team as if it were the one named, or, unquoted, `--team --max`, which
# would bind the next flag as the team and swallow it. No Linear team key or
# name begins with a dash, so a dash-led value is a missing one.
# Usage: linear_require_team_value "$@", with $1 the --team flag.
linear_require_team_value() {
    linear_require_option_value "$@" || return 1
    case "$2" in
    -*)
        linear_require_option_value "$1"
        return 1
        ;;
    "")
        jq -cn --arg flag "$1" \
            '{error: ($flag + " requires a non-empty team key or name: an empty value would read every team, not the one named")}' >&2
        return 1
        ;;
    esac
    return 0
}

# Days-before-now in Linear's UTC shape, for the --updated-since/--created-since
# "7d" spelling. A non-numeric count is rejected here rather than reaching date.
linear_iso_days_ago() {
    local flag="$1" spec="$2"
    local days="${spec%d}"
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        jq -cn --arg flag "$flag" --arg spec "$spec" \
            '{error: ($flag + " expects a day count such as 7d, got: " + $spec)}' >&2
        return 1
    fi
    linear_utc_days_ago "$days"
}

# Refuse a second project-scope option.
# Usage: linear_project_scope "$scope_so_far" "$flag"
linear_project_scope() {
    [ -n "$1" ] || return 0
    jq -cn --arg first "$1" --arg second "$2" \
        '{error: ($second + " cannot be combined with " + $first + ": each names the project scope")}' >&2
    return 1
}

# Parse common CLI arguments into GraphQL filter
# Usage: parse_filter "$@"
# Sets global FILTER_JSON variable; --limit sets the list bound
# (linear_list_option), so the caller resets it before.
# Every value is carried through jq --arg: a label, project, team, or state name
# holding a quote or backslash must not be able to reshape the filter object.
parse_filter() {
    local filter_parts=()
    local team=""
    local include_archived="false"
    # --project, --project-id, --all-projects and --no-project each name the
    # project scope; two of them would AND into a filter nobody asked for.
    local project_scope=""
    # Every --label and --labels name must be on the issue: one AND clause.
    local label_names=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --label)
            linear_require_option_value "$@" || return 1
            label_names+=("$2")
            shift 2
            ;;
        --labels)
            linear_require_option_value "$@" || return 1
            local label_name
            while IFS= read -r label_name; do
                [ -n "$label_name" ] && label_names+=("$label_name")
            done < <(jq -rn --arg v "$2" '$v | split(",")[] | sub("^\\s+"; "") | sub("\\s+$"; "")')
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
            linear_project_scope "$project_scope" "$1" || return 1
            project_scope="$1"
            filter_parts+=("$(jq -cn --arg v "$2" '{project: {name: {eq: $v}}}')")
            shift 2
            ;;
        --project-id)
            linear_require_option_value "$@" || return 1
            linear_project_scope "$project_scope" "$1" || return 1
            project_scope="$1"
            filter_parts+=("$(jq -cn --arg v "$2" '{project: {id: {eq: $v}}}')")
            shift 2
            ;;
        --all-projects)
            # Every project in one read: no project filter at all.
            linear_project_scope "$project_scope" "$1" || return 1
            project_scope="$1"
            shift
            ;;
        --no-project)
            linear_project_scope "$project_scope" "$1" || return 1
            project_scope="$1"
            filter_parts+=('{"project": {"null": true}}')
            shift
            ;;
        --team)
            linear_require_team_value "$@" || return 1
            team="$2"
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
            linear_list_option "$@" || return 1
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

    if [ ${#label_names[@]} -gt 0 ]; then
        filter_parts+=("$(printf '%s\n' "${label_names[@]}" | jq -cRn '[inputs | {labels: {name: {eq: .}}}] |
            if length == 1 then .[0] else {and: .} end')")
    fi

    # Resolved after the loop, so a malformed option refuses before any API call.
    if [ -n "$team" ]; then
        local team_id
        team_id=$(resolve_team_id "$team") || return 1
        filter_parts+=("$(jq -cn --arg v "$team_id" '{team: {id: {eq: $v}}}')")
    fi

    if [ ${#filter_parts[@]} -gt 0 ]; then
        FILTER_JSON=$(printf '%s\n' "${filter_parts[@]}" | jq -cs 'add')
    else
        FILTER_JSON="{}"
    fi
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

# The issue references a bulk read names, as one JSON array: an identifier
# upper-cased, a UUID as given. Linear's id comparator takes both shapes. A
# reference of any other shape, or one holding a line break (a quoted list
# whose spelling is --stdin), refuses before any request: sent, it would read
# as an issue that does not exist. KIND `identifiers` takes identifiers only,
# for an output keyed by identifier; `refs` takes either shape.
# Usage: refs=$(linear_issue_refs identifiers|refs REF...)
linear_issue_refs() {
    local kind="$1" refs bad
    shift
    if [[ $# -eq 0 ]]; then
        echo '{"error": "No issue identifiers provided"}' >&2
        return 1
    fi
    # jq's $ also matches before a final line break; \A and \z hold the whole value.
    local defs='def identifier: test("\\A[A-Za-z0-9]+-[0-9]+\\z");
        def uuid: test("\\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\z");
        def accepted: identifier or ($kind == "refs" and uuid);'
    refs=$(printf '%s\0' "$@" | jq -cRs 'split("\u0000")[:-1]') || return 1
    bad=$(jq -c --arg kind "$kind" "$defs"'[.[] | select(accepted | not)]' <<<"$refs") || return 1
    if [[ "$bad" != "[]" ]]; then
        jq -c --arg kind "$kind" '{error: ("Not an issue " + (if $kind == "refs" then "identifier (TEAM-123) or UUID" else "identifier (TEAM-123)" end)
            + ": " + (map(@json) | join(", ")))}' <<<"$bad" >&2
        return 1
    fi
    jq -c --arg kind "$kind" "$defs"'map(if identifier then ascii_upcase else . end)' <<<"$refs"
}

# Read the issues REFS names (linear_issue_refs' array), each row selecting
# FIELDS, which must hold `id` and `identifier`. Prints {nodes, refs}: the
# rows in REFS order, each once, and the identifier that answers each ref.
# One `id: {in: REFS}` read answers a ref by identifier or id. A ref it leaves
# unanswered gets one `issue(id:)` lookup, the read that resolves a moved
# issue's earlier identifier. A named issue is read whether or not it is
# archived. A ref Linear answers it has no issue for refuses the whole read
# with `missing`, after the lookup's own error line. A lookup that fails any
# other way (a quota, a 5xx, no answer) fails the read at once with no
# `missing`, since whether that issue exists is unknown, and spends no
# request on the refs after it.
# Usage: read=$(linear_issue_refs_read "$fields" "$refs")
linear_issue_refs_read() {
    local fields="$1" refs="$2" query variables result rows answered unanswered ref row rc missing='[]'
    query="query IssueRefs(\$filter: IssueFilter!, \$after: String) {
        issues(filter: \$filter, first: 50, after: \$after, includeArchived: true) {
            pageInfo { hasNextPage endCursor }
            nodes { $fields }
        }
    }"
    variables=$(jq -c '{filter: {id: {in: .}}}' <<<"$refs") || return 1
    result=$(graphql_pages "$query" "$variables" issues) || return 1
    rows=$(jq -c '.issues.nodes' <<<"$result") || return 1
    answered=$(jq -cs '.[1] as $rows | [.[0][] | . as $r
        | {key: $r, value: ([$rows[] | select(.identifier == $r or .id == $r) | .identifier] | first)}]
        | from_entries' <<<"$refs"$'\n'"$rows") || return 1
    unanswered=$(jq -r 'to_entries[] | select(.value == null) | .key' <<<"$answered") || return 1
    while IFS= read -r ref; do
        [[ -n "$ref" ]] || continue
        variables=$(jq -cn --arg id "$ref" '{id: $id}') || return 1
        rc=0
        result=$(graphql_query "query IssueRef(\$id: String!) { issue(id: \$id) { $fields } }" "$variables") || rc=$?
        if ((rc == 2)); then
            missing=$(jq -c --arg ref "$ref" '. + [$ref]' <<<"$missing") || return 1
            continue
        fi
        ((rc == 0)) || return 1
        if ! row=$(jq -ce '.issue | select(type == "object" and (.identifier | type == "string"))' <<<"$result"); then
            jq -cn --arg ref "$ref" '{error: ("Issue lookup for " + $ref + " answered no issue and no error")}' >&2
            return 1
        fi
        rows=$(jq -cs '.[0] + [.[1]]' <<<"$rows"$'\n'"$row") || return 1
        answered=$(jq -cs --arg ref "$ref" '.[0] + {($ref): .[1].identifier}' <<<"$answered"$'\n'"$row") || return 1
    done <<<"$unanswered"
    if [[ "$missing" != "[]" ]]; then
        jq -c '{error: ("Issues not read: " + join(", ")), missing: .}' <<<"$missing" >&2
        return 1
    fi
    jq -cs '.[0] as $refs | .[1] as $answered | .[2] as $rows
        | {nodes: ([$refs[] | $answered[.] as $id | $rows[] | select(.identifier == $id)] | reduce .[] as $row ([];
            if any(.[]; .id == $row.id) then . else . + [$row] end)),
           refs: $answered}' <<<"$refs"$'\n'"$answered"$'\n'"$rows"
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
    echo '{"error": "No Linear team configured for this project - refusing to write. A team name resolves inside whatever workspace LINEAR_API_KEY reaches, so writing without one can land in another project tracker. Fix: set LINEAR_TEAM in this project kendex.settings.toml [env] (committed, non-secret) or .env.local. The create actions that take a team (issues, projects, cycles, labels) also accept --team <key-or-name> for one call. Verify with: linear.sh auth-check --strict"}' >&2
}

# Gate for writes that need a configured team rather than an existing issue.
linear_require_team_target() {
    if [ -n "${LINEAR_TEAM_TARGET:-}" ]; then
        return 0
    fi
    linear_team_target_error
    return 1
}

# Dispatcher guard: refuse an action needing a configured team before any API
# call when no target resolves. It never searches argv for a team - a `--team`
# token in unparsed arguments can be free text (a comment body, an issue title),
# and honoring it would let user content open the gate. Only the first remaining
# argument is read, and only to let `<action> --help` through. The action list
# therefore holds only the write actions with no --team parser of their own;
# actions that do parse it call linear_set_team_target + linear_require_team_target
# after their parse loop, before any API call. Existing-issue writes route by
# the issue identifier and do not register with this guard.
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
# Usage: resolve_project_id "Project name" or resolve_project_id "uuid-here"
#
# Linear keeps a canceled project under the name a live one reuses, and the
# name query returns both in no fixed order, so nodes[0] handed writes the
# canceled one at random and `issues create --project` reported success on an
# issue nobody could find. PROJECT_PICK_JQ (lib/formatters.sh) states the rule
# that settles it and every other spelling of the lookup.
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
    local query='query GetProject($name: String!, $after: String) { projects(filter: {name: {eq: $name}}, after: $after) { pageInfo { hasNextPage endCursor } nodes { id state } } }'
    local variables
    variables=$(jq -nc --arg name "$project_ref" '{name: $name}')
    local result
    # A FAILED query is an API failure (rate limit, outage); "Project not
    # found" is only true of a lookup that succeeded and matched nothing.
    if ! result=$(graphql_pages "$query" "$variables" projects); then
        jq -nc --arg name "$project_ref" \
            '{error: ("Could not resolve project \"" + $name + "\": Linear API request failed (see previous error)")}' >&2
        return 1
    fi

    # PROJECT_PICK_JQ (lib/formatters.sh) is the rule; this is one of its
    # callers. The name query cannot return an id match, so only the
    # canceled-loses-to-live arm ever fires here, and passing $ref anyway is
    # what keeps this spelling the same one every other caller reads.
    local project_id
    project_id=$(echo "$result" | jq -r --arg ref "$project_ref" \
        "$PROJECT_PICK_JQ"'(.projects.nodes // []) | (live_project_pick($ref) | .id) // ""')

    if [ -n "$project_id" ]; then
        echo "$project_id"
        return 0
    fi

    # Naming each rejected UUID and its state is what lets a deliberate read of
    # a canceled project pass one; with nothing matched at all the same builder
    # emits the plain not-found line.
    echo "$result" | jq -c --arg ref "$project_ref" \
        "$PROJECT_PICK_JQ"'(.projects.nodes // []) | live_project_refusal($ref; "Project not found")' >&2
    return 1
}

# Resolve a team UUID, key or name to its UUID. A reference that is one team's
# key and another team's name is refused as ambiguous, naming both.
# Usage: resolve_team_id "$LINEAR_TEAM_TARGET"
resolve_team_id() {
    local team_ref="$1"

    # Check if it's already a UUID
    if [[ "$team_ref" =~ $LINEAR_UUID_PATTERN ]]; then
        echo "$team_ref"
        return 0
    fi

    # Look up by key or name. A FAILED query must propagate as the API
    # failure it is (rate limit, outage) — "Team not found" is only true for
    # a successful lookup that returned no match.
    local query='query GetTeam($name: String!, $after: String) { teams(filter: {or: [{key: {eq: $name}}, {name: {eq: $name}}]}, after: $after) { pageInfo { hasNextPage endCursor } nodes { id key name } } }'
    # Build variables and diagnostics with jq: a team name containing a
    # quote or backslash must neither break the request JSON nor the error.
    local vars result
    vars=$(jq -cn --arg name "$team_ref" '{name: $name}')
    if ! result=$(graphql_pages "$query" "$vars" teams); then
        jq -cn --arg team "$team_ref" \
            '{error: ("Could not resolve team '\''" + $team + "'\'': Linear API request failed (see previous error)")}' >&2
        return 1
    fi
    # Keys are unique and names are unique, so more than one node is one
    # team's key and another team's name.
    local teams
    teams=$(echo "$result" | jq -c '.teams.nodes // []') || return 1
    case "$(jq -r 'length' <<<"$teams")" in
        0)
            jq -cn --arg team "$team_ref" '{error: ("Team not found: " + $team)}' >&2
            return 1
            ;;
        1)
            jq -r '.[0].id' <<<"$teams"
            ;;
        *)
            jq -c --arg team "$team_ref" \
                '{error: ("Ambiguous team: " + $team + " matches " + (map(.name + " (key " + .key + ")") | join(" and ")))}' \
                <<<"$teams" >&2
            return 1
            ;;
    esac
}

# Resolve workflow state name to UUID for a specific team
# Usage: resolve_state_id "In Progress" "team-uuid-or-name"
# Second arg can be team UUID, key or name (will resolve)
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
    local query='query GetState($name: String!, $teamId: ID!, $after: String) { workflowStates(filter: {name: {eq: $name}, team: {id: {eq: $teamId}}}, after: $after) { pageInfo { hasNextPage endCursor } nodes { id } } }'
    local vars result
    vars=$(jq -cn --arg name "$state_name" --arg teamId "$team_id" '{name: $name, teamId: $teamId}')
    result=$(graphql_pages "$query" "$vars" workflowStates) || return 1
    local state_id
    state_id=$(echo "$result" | jq -r '.workflowStates.nodes[0].id // empty')

    if [ -z "$state_id" ]; then
        # Name the unknown state even when the follow-up listing fails — losing
        # the real diagnostic to a second failed request helps nobody.
        local team_vars all_result available=""
        team_vars=$(jq -cn --arg teamId "$team_id" '{teamId: $teamId}')
        local all_query='query GetStates($teamId: ID!, $after: String) { workflowStates(filter: {team: {id: {eq: $teamId}}}, after: $after) { pageInfo { hasNextPage endCursor } nodes { name } } }'
        if all_result=$(graphql_pages "$all_query" "$team_vars" workflowStates); then
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
# Usage: resolve_label_id "backend" team-id|team-name "issue-team"
# Only that team's labels and workspace labels can match. Two teams can each
# own a label of one name, and an unscoped lookup returns whichever the API
# lists first, which Linear refuses as another team's label. The caller says
# which form its team is in: resolve_team_id alone decides whether a reference
# is an id or a name, so this function never guesses.
# Exit 1 = no label of that name in scope, with nothing printed: the caller
# names the miss, because whether it is a warning (a create skips the label) or
# a refusal (an update replaces the whole set) is the caller's decision.
# Exit 2 = the lookup itself failed, so whether the label exists is
# unknown — a caller rebuilding a label set must abort rather than drop it,
# because "not found" and "could not ask" produce the same empty result.
resolve_label_id() {
    local label_name="$1" scope="$2" team="$3"

    local query team_var
    case "$scope" in
    team-id)
        team_var=teamId
        query='query GetLabel($name: String!, $teamId: ID!, $after: String) { issueLabels(filter: {name: {eq: $name}, or: [{team: {id: {eq: $teamId}}}, {team: {null: true}}]}, after: $after) { pageInfo { hasNextPage endCursor } nodes { id } } }'
        ;;
    team-name)
        team_var=teamName
        query='query GetLabel($name: String!, $teamName: String!, $after: String) { issueLabels(filter: {name: {eq: $name}, or: [{team: {name: {eq: $teamName}}}, {team: {null: true}}]}, after: $after) { pageInfo { hasNextPage endCursor } nodes { id } } }'
        ;;
    *)
        jq -cn --arg scope "$scope" \
            '{error: ("resolve_label_id: unknown team scope " + ($scope | tojson) + "; callers pass team-id or team-name")}' >&2
        return 2
        ;;
    esac
    local vars result
    vars=$(jq -cn --arg name "$label_name" --arg key "$team_var" --arg team "$team" \
        '{name: $name, ($key): $team}') || return 2
    if ! result=$(graphql_pages "$query" "$vars" issueLabels); then
        jq -cn --arg name "$label_name" \
            '{error: ("Label lookup failed for " + ($name | tojson) + ": Linear API request failed (see previous error)")}' >&2
        return 2
    fi
    local label_id
    label_id=$(echo "$result" | jq -r '.issueLabels.nodes[0].id // empty') || return 2

    [ -n "$label_id" ] || return 1

    echo "$label_id"
}

# Label taxonomy
# -----------------------------------------------------------------------------
# A repository declares its labels once: the JSON contract of project-management
# references/labels.md, in the first ```json block under `### Project taxonomy`
# in that skill's project instructions, which kendex renders from the manifest's
# [skill-instructions].project-management into each project skills directory a
# delivery writes: `.agents/skills`, and under method = "copy" each tool's own
# `.<tool>/skills` (every project root in crates/core/src/guard/resolve.rs
# SKILL_ROOTS but the source layout `skills`). Every render read is one
# project's, so all of them render one manifest: each
# `<root>/.<tool>/skills/project-management/SKILL.md` (`.[!.]*` keeps out `.`
# and `..`, which bash before 5.2 matches with `.*`, and the source layout).
# linear_taxonomy_root names that project. Renders of one manifest carry one
# block, so two that differ refuse. Its declared names are every category's
# `labels[]` and `match.parent`, plus each LINEAR_AGENT_LABELS name. With no
# such heading the repository declares no taxonomy, and no rule below applies.
# LINEAR_TAXONOMY_FILE is the render a message names: the first found, or the
# shared one when none is.

# Print the project whose renders hold the taxonomy: the nearest directory
# from the working directory up to a bound that holds a render, else the
# bound. A linear install in a `.<tool>/skills` directory in the repository
# bounds the walk at the project holding that directory, as commit-guards'
# gg_project_root derives it, so a kendex project nested inside it that
# declares its own taxonomy keeps it; run from outside that project, the
# install's project is the answer. Any other install, at global scope or in
# the catalog's source layout, is bounded at the git top level: reading the
# global render would enforce nothing in a project that declares a taxonomy.
# The walk stops at the bound: a render above it, in a home directory say,
# never applies.
linear_taxonomy_root() {
    local install bound dir render
    if ! install=$(cd -- "$_LIB_DIR/../../.." && pwd -P); then
        jq -cn --arg dir "$_LIB_DIR" '{error: ("Could not resolve the skills directory holding the linear install at " + $dir)}' >&2
        return 1
    fi
    bound="$PROJECT_ROOT"
    if [[ "$install/" == "$PROJECT_ROOT/"* && "$install" =~ ^(.*)/\.[^./][^/]*/skills$ ]]; then
        bound="${BASH_REMATCH[1]}"
    fi
    if ! dir=$(pwd -P); then
        jq -cn '{error: "Could not resolve the working directory to find the project whose label taxonomy applies."}' >&2
        return 1
    fi
    if [[ "$dir/" == "$bound/"* ]]; then
        while :; do
            for render in "$dir"/.[!.]*/skills/project-management/SKILL.md; do
                if [[ -e "$render" || -L "$render" ]]; then
                    printf '%s\n' "$dir"
                    return 0
                fi
            done
            [[ "$dir" != "$bound" ]] || break
            dir="${dir%/*}"
        done
    fi
    printf '%s\n' "$bound"
}

_linear_taxonomy_root=$(linear_taxonomy_root) || exit 1
LINEAR_TAXONOMY_RENDERS=()
for _linear_render in "$_linear_taxonomy_root"/.[!.]*/skills/project-management/SKILL.md; do
    [[ -e "$_linear_render" || -L "$_linear_render" ]] || continue
    LINEAR_TAXONOMY_RENDERS+=("$_linear_render")
done
LINEAR_TAXONOMY_FILE="${LINEAR_TAXONOMY_RENDERS[0]:-$_linear_taxonomy_root/.agents/skills/project-management/SKILL.md}"
unset _linear_taxonomy_root _linear_render

# Every taxonomy and label-definition refusal: the keyed first line, then the
# JSON error.
linear_label_message() {
    local key="$1" value="$2" other="${3:-}"
    case "$key" in
    undeclared)
        printf 'linear-labels: undeclared labels=%s taxonomy=%s\n' "$value" "$LINEAR_TAXONOMY_FILE"
        jq -cn --arg labels "$value" --arg file "$LINEAR_TAXONOMY_FILE" \
            '{error: ("Refusing labels the repository taxonomy does not declare: " + $labels + ". A label is a taxonomy change, never a side effect: use a declared label, or add this one to the taxonomy in the manifest [skill-instructions].project-management (agent labels: LINEAR_AGENT_LABELS) through a reviewed commit and render it; " + $file + " is that render.")}'
        ;;
    declared-missing)
        printf 'linear-labels: declared-missing label=%s taxonomy=%s\n' "$value" "$LINEAR_TAXONOMY_FILE"
        jq -cn --arg label "$value" --arg file "$LINEAR_TAXONOMY_FILE" \
            '{error: ("The taxonomy in " + $file + " declares label " + ($label | tojson) + " but Linear has no such label for this team or the workspace. Refusing rather than writing the issue without a declared label: create the label (project-management references/labels.md § Creating Labels), then retry.")}'
        ;;
    unreadable)
        printf 'linear-labels: taxonomy-unreadable taxonomy=%s\n' "$value"
        jq -cn --arg file "$value" \
            '{error: ("The repository declares a label taxonomy in " + $file + " but its ### Project taxonomy section holds no readable JSON contract (project-management references/labels.md § Project Taxonomy Contract), so no label can be judged. Fix the manifest [skill-instructions].project-management and render it.")}'
        ;;
    renders-differ)
        printf 'linear-labels: taxonomy-unreadable taxonomy=%s differs=%s\n' "$value" "$other"
        jq -cn --arg file "$value" --arg other "$other" \
            '{error: ("The project-management renders " + $file + " and " + $other + " carry different ### Project taxonomy sections, so no label can be judged: one is a stale render. Render the manifest [skill-instructions].project-management again (kendex refresh) so every render carries one taxonomy.")}'
        ;;
    absent)
        printf 'linear-labels: taxonomy-absent taxonomy=%s\n' "$value"
        jq -cn --arg file "$value" \
            '{error: ("No label taxonomy is declared (no ### Project taxonomy section in " + $file + "), so there is nothing to audit labels against.")}'
        ;;
    workspace-duplicate)
        printf 'linear-labels: workspace-duplicate name=%s\n' "$value"
        jq -cn --arg name "$value" \
            '{error: ("Refusing label name " + ($name | tojson) + ": a workspace label already uses this name, and a second label of one name makes every name lookup ambiguous. Use the workspace label.")}'
        ;;
    no-team)
        printf 'linear-labels: no-team\n'
        jq -cn '{error: "labels audit reads the open issues of one team: set LINEAR_TEAM in kendex.settings.toml [env] or pass --team <key-or-name>."}'
        ;;
    *)
        printf 'linear-labels: unknown-message key=%s\n' "$key"
        return 1
        ;;
    esac
}

# Print the declared label names as a JSON array, or nothing when the
# repository declares no taxonomy. A declared taxonomy this cannot read
# refuses: enforcing nothing then would pass every label it exists to stop.
linear_declared_labels() {
    local file block rc=0 first=""
    [[ ${#LINEAR_TAXONOMY_RENDERS[@]} -gt 0 ]] || return 0
    for file in "${LINEAR_TAXONOMY_RENDERS[@]}"; do
        rc=0
        block=$(awk '
            $0 == "<!-- kendex:project-instructions:start -->" { inside = 1; next }
            $0 == "<!-- kendex:project-instructions:end -->" { inside = 0; next }
            !inside { next }
            state == 0 && $0 == "### Project taxonomy" { state = 1; next }
            state == 1 && /^```json *$/ { state = 2; next }
            state == 1 && /^##?#? / { exit 3 }
            state == 2 && /^``` *$/ { state = 3; exit }
            state == 2 { print }
            END { if (state == 0) exit 5; if (state != 3) exit 3 }
        ' "$file") || rc=$?
        [[ -n "$first" ]] || first="$rc:$block"
        if [[ "$rc:$block" != "$first" ]]; then
            linear_label_message renders-differ "$LINEAR_TAXONOMY_FILE" "$file" >&2
            return 1
        fi
    done
    # Exit 5 is no heading: the repository declares no taxonomy. A heading
    # whose block is empty reaches jq with no input, which refuses it.
    [[ "$rc" != 5 ]] || return 0
    if [[ "$rc" != 0 ]]; then
        linear_label_message unreadable "$LINEAR_TAXONOMY_FILE" >&2
        return 1
    fi
    if ! jq -ce --arg agents "${LINEAR_AGENT_LABELS:-}" '
        select(type == "object" and (.categories | type == "object")
            and all(.categories[]; type == "object"
                and ((.labels // []) | type == "array" and all(type == "string"))
                and ((.match.parent // "") | type == "string")))
        | [.categories[] | (.labels // [])[], (.match.parent // empty)]
            + [$agents | splits("[, ]+") | select(length > 0)]
        | unique' <<<"$block" 2>/dev/null; then
        linear_label_message unreadable "$LINEAR_TAXONOMY_FILE" >&2
        return 1
    fi
}

# Refuse, before any write, a label name the taxonomy does not declare.
# Usage: linear_require_declared_labels "a,b" ['["name already on the issue"]']
#        linear_require_declared_labels --name NAME
# A list is an issue's comma-separated label assignment. --name judges the
# whole string as one label name, commas and all, for a label definition. A
# name the issue already carries is kept, not applied: it is drift for
# `labels audit` to list, and refusing it would stop every write to an issue
# labelled before the taxonomy.
linear_require_declared_labels() {
    local requested kept="[]" declared undeclared
    declared=$(linear_declared_labels) || return 1
    [[ -n "$declared" ]] || return 0
    if [[ "$1" == --name ]]; then
        requested=$(jq -cn --arg name "$2" '[$name]') || return 1
    else
        requested=$(jq -cn --arg list "$1" '$list | split(",") | map(select(length > 0))') || return 1
        kept="${2:-[]}"
    fi
    undeclared=$(jq -nr --argjson requested "$requested" --argjson kept "$kept" --argjson declared "$declared" '
        $requested - $declared - $kept | unique | join(",")') || return 1
    [[ -n "$undeclared" ]] || return 0
    linear_label_message undeclared "$undeclared" >&2
    return 1
}

# A milestone reference that is already a UUID, and so needs no project to
# resolve it in. One statement of the rule: the pre-upload guard below and
# resolve_milestone_id must agree on it, or a reference one calls a name the
# other calls resolved. LINEAR_UUID_PATTERN is that grammar everywhere else,
# `--cycle` included, and it accepts uppercase hex; a second, lowercase-only
# spelling here would refuse an uppercase UUID for want of a project the
# option's contract says it does not need.
milestone_ref_is_uuid() {
    [[ "$1" =~ $LINEAR_UUID_PATTERN ]]
}

# Refuse a milestone NAME that has no project to resolve it in.
# Usage: require_milestone_project "$milestone" "$project_scope"
#
# The scope is any project reference the caller has: the --project argument
# before it is resolved, or the issue's own project on the update path. Only
# whether one exists is judged here, never which.
#
# Both call sites run this from their arguments BEFORE uploading --attach
# files: a refusal after an upload strands the asset in Linear storage with no
# issue referencing it, which is the rule issues.sh states at its label
# pre-resolution. resolve_milestone_id runs it again on the resolved id.
# Plain `if`, not `test && return`: a false `&&` compound is a non-zero status
# under this file's errexit, which would end a bare call before its diagnostic.
require_milestone_project() {
    local milestone_ref="$1" project_scope="${2:-}"

    if [ -z "$milestone_ref" ] || [ -n "$project_scope" ]; then
        return 0
    fi
    if milestone_ref_is_uuid "$milestone_ref"; then
        return 0
    fi

    jq -cn --arg ref "$milestone_ref" \
        '{error: ("Cannot resolve milestone " + ($ref | tojson) + " without a project: the same milestone name exists in other projects. Pass --project, or pass the milestone UUID.")}' >&2
    return 1
}

# Resolve milestone name or UUID to UUID, within one project
# Usage: resolve_milestone_id "Alpha" "project-uuid" or resolve_milestone_id "uuid-here"
#
# A milestone name is unique to its project and nothing more: "Alpha" exists in
# as many projects as reuse it, and an unscoped name query returns all of them
# in no fixed order, so nodes[0] filed the issue under whichever project the API
# listed first. The project the caller already resolved is the scope, and a name
# with no project to scope it is refused rather than guessed at.
resolve_milestone_id() {
    local milestone_ref="$1"
    local project_id="${2:-}"

    # Check if it's already a UUID
    if milestone_ref_is_uuid "$milestone_ref"; then
        echo "$milestone_ref"
        return 0
    fi

    require_milestone_project "$milestone_ref" "$project_id" || return 1

    # Look up by name within the project.
    local query='query GetMilestone($name: String!, $projectId: ID!, $after: String) { projectMilestones(filter: {name: {eq: $name}, project: {id: {eq: $projectId}}}, after: $after) { pageInfo { hasNextPage endCursor } nodes { id } } }'
    local vars result
    vars=$(jq -cn --arg name "$milestone_ref" --arg projectId "$project_id" '{name: $name, projectId: $projectId}')
    # A FAILED query is an API failure (rate limit, outage); "Milestone not
    # found" is only true of a lookup that succeeded and matched nothing.
    if ! result=$(graphql_pages "$query" "$vars" projectMilestones); then
        jq -cn --arg ref "$milestone_ref" \
            '{error: ("Could not resolve milestone " + ($ref | tojson) + ": Linear API request failed (see previous error)")}' >&2
        return 1
    fi

    # The whole match set, joined: a UUID holds no comma, so a comma in the
    # join is exactly a second match, and the same string names the candidates
    # in the refusal.
    local milestone_ids
    milestone_ids=$(echo "$result" | jq -r '[(.projectMilestones.nodes // [])[].id] | join(", ")')

    if [ -z "$milestone_ids" ]; then
        jq -cn --arg ref "$milestone_ref" '{error: ("Milestone not found: " + $ref)}' >&2
        return 1
    fi

    if [[ "$milestone_ids" == *,* ]]; then
        jq -cn --arg ref "$milestone_ref" --arg matches "$milestone_ids" \
            '{error: ("Milestone name is ambiguous within the project: " + ($ref | tojson) + " matches " + $matches + "; pass a milestone UUID to target one)")}' >&2
        return 1
    fi

    echo "$milestone_ids"
}

# Cursor traversal and nested completion; graphql_query is defined there.
# shellcheck source=pages.sh
source "$_LIB_DIR/pages.sh"
