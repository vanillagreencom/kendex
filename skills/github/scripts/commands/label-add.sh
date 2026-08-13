#!/usr/bin/env bash
# GitHub label add wrapper.
# Uses the shared issues label endpoint for both PRs and issues.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/gh-auth.sh
source "$SCRIPT_DIR/../lib/gh-auth.sh"

show_help() {
    cat <<'EOF'
Add a label to a PR or issue.

Usage: label-add.sh <pr-or-issue-ref> <label> [--issue] [--required|--optional]

Arguments:
  pr-or-issue-ref   PR number, branch ref, or issue number. Empty
                    string defers to gh's current-branch resolution.
  label             Label name to add (single label per call).

Options:
  --issue           Treat the ref as an issue (default: PR).
  --pr              Treat the ref as a PR (default).
  --required        Treat a missing label or write capability as an error
                    (default; exit 78 for missing label, 77 for permission).
  --optional        Skip with a structured optional_unsupported result when
                    the repository lacks the label or label-write capability.
  --help, -h        Show this help.

Examples:
  label-add.sh 44 needs-qa
  label-add.sh 123 needs-triage --issue
  label-add.sh 44 informational --optional
EOF
}

emit_preflight_result() {
    local status="$1" policy="$2" reason="$3" repository="$4" label="$5"
    local detail="${6:-}"
    jq -cn \
        --arg status "$status" \
        --arg policy "$policy" \
        --arg reason "$reason" \
        --arg repository "$repository" \
        --arg label "$label" \
        --arg detail "$detail" \
        '{
           status:$status,
           policy:$policy,
           reason:$reason,
           repository:$repository,
           label:$label,
           message:(
             if $status == "configuration_error" then
               "Required label \"\($label)\" is not configured in \($repository)"
             elif $status == "capability_error" then
               "Required label \"\($label)\" was not applied because GitHub denied label-write permission"
             elif $reason == "label_missing" then
               "Optional label \"\($label)\" is not configured; mutation skipped"
             elif $reason == "insufficient_permission" then
               "Optional label \"\($label)\" was not applied because GitHub denied label-write permission"
             else
               "Label capability preflight failed before mutation"
             end
           )
         }
         + (if $reason == "insufficient_permission" then
              {required_permission:"issues=write or pull_requests=write"}
            else {} end)
         + (if $detail == "" then {} else {detail:$detail} end)'
}

LABEL_ADD_REPOSITORY=""

preflight_label_add() {
    local label="$1" policy="$2"
    local repo_json="" repo_rc=0 repository=""
    repo_json="$(gh repo view --json nameWithOwner 2>&1)" || repo_rc=$?
    if [ "$repo_rc" -ne 0 ]; then
        emit_preflight_result \
            "preflight_failed" "$policy" "repository_lookup_failed" "" "$label" "$repo_json" >&2
        return "$repo_rc"
    fi

    repository="$(printf '%s' "$repo_json" | jq -r '.nameWithOwner // empty')"
    if [ -z "$repository" ]; then
        emit_preflight_result \
            "preflight_failed" "$policy" "invalid_repository_metadata" "" "$label" "$repo_json" >&2
        return 1
    fi
    LABEL_ADD_REPOSITORY="$repository"

    local encoded_label="" lookup_output="" lookup_rc=0
    encoded_label="$(jq -nr --arg label "$label" '$label | @uri')"
    lookup_output="$(gh api "repos/$repository/labels/$encoded_label" 2>&1)" || lookup_rc=$?
    if [ "$lookup_rc" -eq 0 ]; then
        return 0
    fi

    if printf '%s' "$lookup_output" | grep -Eq 'HTTP 404|"status"[[:space:]]*:[[:space:]]*"?404"?|Not Found'; then
        if [ "$policy" = "optional" ]; then
            emit_preflight_result \
                "optional_unsupported" "$policy" "label_missing" "$repository" "$label"
            return 10
        fi
        emit_preflight_result \
            "configuration_error" "$policy" "label_missing" "$repository" "$label" >&2
        return 78
    fi

    emit_preflight_result \
        "preflight_failed" "$policy" "label_lookup_failed" "$repository" "$label" "$lookup_output" >&2
    return "$lookup_rc"
}

resolve_target_number() {
    local kind="$1" ref="$2" policy="$3" repository="$4" label="$5"
    local target_json="" target_rc=0 number=""

    if [ "$kind" = "issue" ]; then
        if [ -n "$ref" ]; then
            target_json="$(gh issue view "$ref" --json number 2>&1)" || target_rc=$?
        else
            target_json="$(gh issue view --json number 2>&1)" || target_rc=$?
        fi
    else
        if [ -n "$ref" ]; then
            target_json="$(gh pr view "$ref" --json number 2>&1)" || target_rc=$?
        else
            target_json="$(gh pr view --json number 2>&1)" || target_rc=$?
        fi
    fi

    if [ "$target_rc" -ne 0 ]; then
        emit_preflight_result \
            "preflight_failed" "$policy" "target_lookup_failed" "$repository" "$label" "$target_json" >&2
        return "$target_rc"
    fi

    number="$(printf '%s' "$target_json" | jq -r '.number // empty')"
    if [ -z "$number" ]; then
        emit_preflight_result \
            "preflight_failed" "$policy" "invalid_target_metadata" "$repository" "$label" "$target_json" >&2
        return 1
    fi

    printf '%s\n' "$number"
}

is_label_write_permission_denial() {
    local output="$1"
    printf '%s' "$output" | grep -Eiq \
        'Resource not accessible by (integration|personal access token)|must have (admin|push) (rights|access)|requires? (repository )?write (access|permission)|write access to (the )?repository not granted|HTTP 404|"status"[[:space:]]*:[[:space:]]*"?404"?|Not Found'
}

apply_label() {
    local number="$1" label="$2" policy="$3" repository="$4"
    local mutation_output="" mutation_rc=0

    mutation_output="$(gh api "repos/$repository/issues/$number/labels" \
        --method POST --raw-field "labels[]=$label" 2>&1)" || mutation_rc=$?
    if [ "$mutation_rc" -eq 0 ]; then
        [ -z "$mutation_output" ] || printf '%s\n' "$mutation_output"
        return 0
    fi

    if is_label_write_permission_denial "$mutation_output"; then
        if [ "$policy" = "optional" ]; then
            emit_preflight_result \
                "optional_unsupported" "$policy" "insufficient_permission" "$repository" "$label" "$mutation_output"
            return 10
        fi
        emit_preflight_result \
            "capability_error" "$policy" "insufficient_permission" "$repository" "$label" "$mutation_output" >&2
        return 77
    fi

    printf '%s\n' "$mutation_output" >&2
    return "$mutation_rc"
}

main() {
    local ref="" label="" kind="pr" policy="required" policy_set=""
    local positional=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h) show_help; exit 0 ;;
            --issue) kind="issue"; shift ;;
            --pr) kind="pr"; shift ;;
            --required|--optional)
                local requested_policy="${1#--}"
                if [ -n "$policy_set" ] && [ "$policy_set" != "$requested_policy" ]; then
                    echo "label-add: --required and --optional are mutually exclusive" >&2
                    exit 2
                fi
                policy="$requested_policy"
                policy_set="$requested_policy"
                shift
                ;;
            --) shift; break ;;
            -*)
                echo "label-add: unknown flag: $1" >&2
                exit 2
                ;;
            *)
                case "$positional" in
                    0) ref="$1"; positional=1 ;;
                    1) label="$1"; positional=2 ;;
                    *) echo "label-add: unexpected positional: $1" >&2; exit 2 ;;
                esac
                shift
                ;;
        esac
    done

    if [ -z "$label" ]; then
        echo "label-add: <label> is required" >&2
        show_help >&2
        exit 2
    fi

    local project_root
    project_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    vstack_github_load_project_env_preserving_caller "$project_root"
    vstack_github_apply_selected_auth_token router || true
    vstack_github_sanitize_gh_env

    local preflight_rc=0
    preflight_label_add "$label" "$policy" || preflight_rc=$?
    if [ "$preflight_rc" -eq 10 ]; then
        exit 0
    fi
    if [ "$preflight_rc" -ne 0 ]; then
        exit "$preflight_rc"
    fi

    local number="" target_rc=0 mutation_rc=0
    number="$(resolve_target_number "$kind" "$ref" "$policy" "$LABEL_ADD_REPOSITORY" "$label")" || target_rc=$?
    if [ "$target_rc" -ne 0 ]; then
        exit "$target_rc"
    fi

    apply_label "$number" "$label" "$policy" "$LABEL_ADD_REPOSITORY" || mutation_rc=$?
    if [ "$mutation_rc" -eq 10 ]; then
        exit 0
    fi
    if [ "$mutation_rc" -ne 0 ]; then
        exit "$mutation_rc"
    fi

    exit 0
}

main "$@"
