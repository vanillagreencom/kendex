#!/usr/bin/env bash
# Regression tests for label-add capability and policy handling.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local got="$1" want="$2" name="$3"
    if [ "$got" != "$want" ]; then
        fail "$name: expected '$want', got '$got'"
    fi
    printf 'ok - %s\n' "$name"
}

assert_no_mutation_request() {
    local name="$1"
    if grep -Eq '^api repos/owner/repo/issues/[0-9]+/labels ' "$TMP_ROOT/gh.calls"; then
        fail "$name: label mutation was attempted"
    fi
    printf 'ok - %s\n' "$name"
}

assert_no_successful_mutation() {
    local name="$1"
    if [ -e "$TMP_ROOT/mutated" ]; then
        fail "$name: target was mutated"
    fi
    printf 'ok - %s\n' "$name"
}

reset_state() {
    : >"$TMP_ROOT/gh.calls"
    rm -f "$TMP_ROOT/mutated" "$TMP_ROOT/mutation-label"
}

mkdir -p "$TMP_ROOT/repo" "$TMP_ROOT/bin"
git -C "$TMP_ROOT/repo" init -q

cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$STUB_CALLS"

case "${1:-} ${2:-}" in
    "api user")
        if [ "${STUB_APP_USER_UNAVAILABLE:-0}" = "1" ]; then
            printf 'gh: Resource not accessible by integration (HTTP 403)\n' >&2
            exit 1
        fi
        printf '{"login":"test-user"}\n'
        ;;
    "repo view")
        if [ "${STUB_REPO_FAILURE:-0}" = "1" ]; then
            printf 'repository unavailable\n' >&2
            exit 1
        fi
        if [ -n "${STUB_REPO_JSON:-}" ]; then
            printf '%s\n' "$STUB_REPO_JSON"
        else
            printf '{"nameWithOwner":"owner/repo"}\n'
        fi
        ;;
    "api repos/owner/repo/labels/"*)
        if [ "${STUB_LABEL_FAILURE:-0}" = "1" ]; then
            printf 'gh: server error (HTTP 500)\n' >&2
            exit 1
        fi
        if [ "${STUB_LABEL_EXISTS:-1}" = "1" ]; then
            printf '{"name":"label"}\n'
            exit 0
        fi
        printf '{"message":"Not Found","status":"404"}\n' >&2
        printf 'gh: Not Found (HTTP 404)\n' >&2
        exit 1
        ;;
    "pr view")
        if [ "${STUB_TARGET_FAILURE:-0}" = "1" ]; then
            printf 'target unavailable\n' >&2
            exit 1
        fi
        printf '{"number":42}\n'
        ;;
    "issue view")
        if [ "${STUB_TARGET_FAILURE:-0}" = "1" ]; then
            printf 'target unavailable\n' >&2
            exit 1
        fi
        printf '{"number":84}\n'
        ;;
    "api repos/owner/repo/issues/42/labels"|"api repos/owner/repo/issues/84/labels")
        if [ "$#" -ne 6 ] || [ "${3:-}" != "--method" ] || [ "${4:-}" != "POST" ] || \
            [ "${5:-}" != "--raw-field" ]; then
            printf 'label mutation must use one literal --raw-field: %s\n' "$*" >&2
            exit 1
        fi
        case "${6:-}" in
            'labels[]='*) ;;
            *)
                printf 'label mutation must use labels[] payload: %s\n' "$*" >&2
                exit 1
                ;;
        esac
        case "${STUB_MUTATION_RESULT:-success}" in
            app-denied)
                printf 'gh: Resource not accessible by integration (HTTP 403)\n' >&2
                exit 1
                ;;
            pat-denied)
                printf 'gh: Resource not accessible by personal access token (HTTP 403)\n' >&2
                exit 1
                ;;
            hidden-denied)
                printf 'gh: Not Found (HTTP 404)\n' >&2
                exit 1
                ;;
            server-error)
                printf 'gh: server error (HTTP 500)\n' >&2
                exit 1
                ;;
        esac
        : >"$STUB_MUTATION_STATE"
        printf '%s\n' "${6#labels[]=}" >"$STUB_MUTATION_LABEL"
        printf 'updated\n'
        ;;
    *)
        printf 'unexpected gh call: %s\n' "$*" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/gh"

run_label_add() {
    local -a command
    local repo_json="${STUB_REPO_JSON:-}"
    if [ -z "$repo_json" ]; then
        repo_json='{"nameWithOwner":"owner/repo"}'
    fi
    command=(env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN)
    if [ -n "${STUB_TOKEN_VAR:-}" ]; then
        command+=("$STUB_TOKEN_VAR=${STUB_TOKEN:-}")
    fi
    "${command[@]}" \
        PATH="$TMP_ROOT/bin:$PATH" \
        STUB_CALLS="$TMP_ROOT/gh.calls" \
        STUB_MUTATION_STATE="$TMP_ROOT/mutated" \
        STUB_MUTATION_LABEL="$TMP_ROOT/mutation-label" \
        STUB_REPO_JSON="$repo_json" \
        STUB_LABEL_EXISTS="${STUB_LABEL_EXISTS:-1}" \
        STUB_REPO_FAILURE="${STUB_REPO_FAILURE:-0}" \
        STUB_LABEL_FAILURE="${STUB_LABEL_FAILURE:-0}" \
        STUB_TARGET_FAILURE="${STUB_TARGET_FAILURE:-0}" \
        STUB_MUTATION_RESULT="${STUB_MUTATION_RESULT:-success}" \
        STUB_APP_USER_UNAVAILABLE="${STUB_APP_USER_UNAVAILABLE:-0}" \
        "$REPO_ROOT/skills/github/scripts/commands/label-add.sh" "$@"
}

cd "$TMP_ROOT/repo"

reset_state
output="$(
    STUB_TOKEN_VAR=GH_BOT_TOKEN \
    STUB_TOKEN=ghs_APP_INSTALLATION123 \
    STUB_APP_USER_UNAVAILABLE=1 \
    run_label_add 42 needs-review
)"
assert_eq "$output" "updated" "GitHub App installation token can add an existing label"
assert_eq "$(grep -c 'viewerPermission' "$TMP_ROOT/gh.calls" || true)" "0" "GitHub App flow does not query viewerPermission"
assert_eq "$(grep -c '^api user --jq .login$' "$TMP_ROOT/gh.calls")" "1" "GitHub App user lookup may be unavailable"
assert_eq "$(grep -c '^api repos/owner/repo/issues/42/labels --method POST --raw-field labels\[\]=needs-review$' "$TMP_ROOT/gh.calls")" "1" "REST endpoint applies the PR label as a literal string"
assert_eq "$(test -e "$TMP_ROOT/mutated" && printf yes || printf no)" "yes" "successful endpoint response records mutation"

reset_state
set +e
required_missing="$(STUB_LABEL_EXISTS=0 run_label_add 42 needs-review --required 2>&1)"
required_missing_rc=$?
set -e
assert_eq "$required_missing_rc" "78" "required missing label is a configuration error"
assert_eq "$(jq -r .status <<<"$required_missing")" "configuration_error" "required missing label has structured status"
assert_eq "$(jq -r .reason <<<"$required_missing")" "label_missing" "required missing label has structured reason"
assert_eq "$(jq -r .message <<<"$required_missing")" 'Required label "needs-review" is not configured in owner/repo' "required missing label explains repository configuration"
assert_no_mutation_request "required missing label stops before mutation"
assert_no_successful_mutation "required missing label leaves target unchanged"

reset_state
optional_missing="$(STUB_LABEL_EXISTS=0 run_label_add 42 informational --optional)"
assert_eq "$(jq -r .status <<<"$optional_missing")" "optional_unsupported" "optional missing label is a supported skip"
assert_eq "$(jq -r .reason <<<"$optional_missing")" "label_missing" "optional missing label explains why it skipped"
assert_eq "$(jq -r .message <<<"$optional_missing")" 'Optional label "informational" is not configured; mutation skipped' "optional missing label reports skipped mutation"
assert_no_mutation_request "optional missing label skips mutation"
assert_no_successful_mutation "optional missing label leaves target unchanged"

reset_state
set +e
required_denied="$(
    STUB_TOKEN_VAR=GH_TOKEN \
    STUB_TOKEN=github_pat_FINE_GRAINED123 \
    STUB_REPO_JSON='{"nameWithOwner":"owner/repo","viewerPermission":"WRITE"}' \
    STUB_MUTATION_RESULT=pat-denied \
    run_label_add 42 needs-review --required 2>&1
)"
required_denied_rc=$?
set -e
assert_eq "$required_denied_rc" "77" "required fine-grained token denial is a capability error"
assert_eq "$(jq -r .status <<<"$required_denied")" "capability_error" "required permission denial has structured status"
assert_eq "$(jq -r .reason <<<"$required_denied")" "insufficient_permission" "required permission denial has structured reason"
assert_eq "$(jq -r .required_permission <<<"$required_denied")" "issues=write or pull_requests=write" "permission denial names effective token grant"
assert_no_successful_mutation "required permission denial leaves target unchanged"

reset_state
optional_denied="$(
    STUB_TOKEN_VAR=GH_TOKEN \
    STUB_TOKEN=github_pat_FINE_GRAINED123 \
    STUB_REPO_JSON='{"nameWithOwner":"owner/repo","viewerPermission":"WRITE"}' \
    STUB_MUTATION_RESULT=pat-denied \
    run_label_add 42 informational --optional
)"
assert_eq "$(jq -r .status <<<"$optional_denied")" "optional_unsupported" "optional fine-grained token denial is a supported skip"
assert_eq "$(jq -r .reason <<<"$optional_denied")" "insufficient_permission" "optional permission skip explains why"
assert_no_successful_mutation "optional permission denial leaves target unchanged"

reset_state
hidden_denied="$(STUB_MUTATION_RESULT=hidden-denied run_label_add 42 informational --optional)"
assert_eq "$(jq -r .status <<<"$hidden_denied")" "optional_unsupported" "permission-masked 404 is a supported optional skip"
assert_no_successful_mutation "permission-masked 404 leaves target unchanged"

reset_state
set +e
optional_lookup_failure="$(STUB_LABEL_FAILURE=1 run_label_add 42 informational --optional 2>&1)"
optional_lookup_failure_rc=$?
set -e
assert_eq "$optional_lookup_failure_rc" "1" "optional mode does not hide operational label lookup failures"
assert_eq "$(jq -r .status <<<"$optional_lookup_failure")" "preflight_failed" "operational lookup failure has structured status"
assert_no_mutation_request "operational lookup failure stops mutation"

reset_state
set +e
optional_target_failure="$(STUB_TARGET_FAILURE=1 run_label_add 42 informational --optional 2>&1)"
optional_target_failure_rc=$?
set -e
assert_eq "$optional_target_failure_rc" "1" "optional mode does not hide target lookup failures"
assert_eq "$(jq -r .reason <<<"$optional_target_failure")" "target_lookup_failed" "target lookup failure has structured reason"
assert_no_mutation_request "target lookup failure stops mutation"

reset_state
set +e
optional_server_failure="$(STUB_MUTATION_RESULT=server-error run_label_add 42 informational --optional 2>&1)"
optional_server_failure_rc=$?
set -e
assert_eq "$optional_server_failure_rc" "1" "optional mode does not hide mutation server failures"
assert_eq "$optional_server_failure" "gh: server error (HTTP 500)" "mutation server failure preserves operational detail"
assert_no_successful_mutation "mutation server failure leaves target unchanged"

reset_state
encoded_output="$(run_label_add 42 needs/review --required)"
assert_eq "$encoded_output" "updated" "encoded label succeeds"
assert_eq "$(sed -n '2p' "$TMP_ROOT/gh.calls")" "api repos/owner/repo/labels/needs%2Freview" "label lookup URL-encodes the label"

assert_literal_label() {
    local label="$1" expected_encoded="$2" name="$3"
    local literal_output=""

    reset_state
    literal_output="$(run_label_add 42 "$label" <"$TMP_ROOT/stdin-label-source")"
    assert_eq "$literal_output" "updated" "$name succeeds"
    assert_eq "$(cat "$TMP_ROOT/mutation-label")" "$label" "$name remains a literal string"
    assert_eq "$(sed -n '2p' "$TMP_ROOT/gh.calls")" \
        "api repos/owner/repo/labels/$expected_encoded" "$name preflight uses the intended label"
    assert_eq "$(grep -c -- ' --field ' "$TMP_ROOT/gh.calls" || true)" "0" "$name never uses typed --field"
}

printf 'local-file-label-value\n' >"$TMP_ROOT/repo/path"
printf 'stdin-label-value\n' >"$TMP_ROOT/stdin-label-source"
assert_literal_label '@path' '%40path' '@path label'
assert_literal_label '@-' '%40-' '@- label'
assert_literal_label 'true' 'true' 'true label'
assert_literal_label 'false' 'false' 'false label'
assert_literal_label 'null' 'null' 'null label'
assert_literal_label '12345' '12345' 'integer-like label'
assert_literal_label '{owner}' '%7Bowner%7D' 'repository-placeholder label'

reset_state
issue_output="$(run_label_add 84 needs-review --issue)"
assert_eq "$issue_output" "updated" "issue label uses the shared REST endpoint"
assert_eq "$(grep -c '^issue view 84 --json number$' "$TMP_ROOT/gh.calls")" "1" "issue target is resolved"
assert_eq "$(grep -c '^api repos/owner/repo/issues/84/labels --method POST --raw-field labels\[\]=needs-review$' "$TMP_ROOT/gh.calls")" "1" "issue label mutation uses resolved issue number"

reset_state
set +e
conflicting_policy="$(run_label_add 42 needs-review --required --optional 2>&1)"
conflicting_policy_rc=$?
set -e
assert_eq "$conflicting_policy_rc" "2" "conflicting policy flags are rejected"
assert_no_mutation_request "conflicting policy flags stop before mutation"

printf 'all pass\n'
