#!/usr/bin/env bash
# Regression test: a project name that matches both a canceled and a live
# project must resolve to the live one (KEN-1022).
#
# Linear keeps a canceled project under the name a live one reuses, and the
# name query returns both in no fixed order. resolve_project_id took nodes[0],
# so `issues create --project "<name>"` landed the issue in whichever the API
# happened to list first — silently, since a create carrying a valid project id
# succeeds either way.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

# GIT_DIR outranks -C, so where it is inherited `git -C "$TMP_ROOT" init` below
# re-inits the ambient repository and leaves no fixture repo at all. Git sets it
# for a hook run in a linked worktree; a hook in the main checkout gets
# GIT_INDEX_FILE instead. Reaching the developer's real cache needs GIT_WORK_TREE
# or core.worktree inherited as well, so all four go, which is the house rule in
# .claude/CLAUDE.md. Unsetting at suite scope covers git and the CLI alike.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin" "$TMP_ROOT/.cache/linear"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
# Isolate CACHE_DIR resolution (git rev-parse --show-toplevel) to this
# throwaway root so cache writes from `issues create` stay out of the real
# project's `.cache/linear` (kendex#43).
git -C "$TMP_ROOT" init -q -b main
# Proof the isolation held. Without the unset the line above re-inits the
# ambient repository and leaves no fixture repo behind, and a run that goes on
# from there is writing somewhere nobody sandboxed, so this stops the suite
# rather than recording a failure and continuing.
if [[ ! -d "$TMP_ROOT/.git" ]]; then
  assert_stop "the fixture repository is the one git init created" \
    "no repository at $TMP_ROOT/.git: a git environment variable redirected git init"
fi

cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
scenario="${LINEAR_PROJECT_TEST_CASE:-canceled-first}"
printf '%s\n' "$payload" >> "${CURL_PAYLOAD_LOG:?}"

live='{"id":"live-uuid","state":"backlog"}'
dead='{"id":"dead-uuid","state":"canceled"}'
other_dead='{"id":"dead-two-uuid","state":"canceled"}'

case "$query" in
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"projects(filter:"*)
  case "$scenario" in
  canceled-first)
    printf '%s' "{\"data\":{\"projects\":{\"nodes\":[$dead,$live]}}}___HTTP_CODE___200"
    ;;
  live-first)
    printf '%s' "{\"data\":{\"projects\":{\"nodes\":[$live,$dead]}}}___HTTP_CODE___200"
    ;;
  only-canceled)
    printf '%s' "{\"data\":{\"projects\":{\"nodes\":[$dead,$other_dead]}}}___HTTP_CODE___200"
    ;;
  no-match)
    printf '%s' '{"data":{"projects":{"nodes":[]}}}___HTTP_CODE___200'
    ;;
  api-failure)
    printf '%s' '{"errors":[{"message":"unauthenticated"}]}___HTTP_CODE___401'
    ;;
  *)
    printf '%s' '{"errors":[{"message":"unknown scenario"}]}___HTTP_CODE___200'
    ;;
  esac
  ;;
*"issueLabels(filter:"*)
  printf '%s' '{"data":{"issueLabels":{"nodes":[{"id":"label-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"issueCreate(input:"*)
  printf '%s' '{"data":{"issueCreate":{"success":true,"issue":{"id":"child-uuid","identifier":"CC-900","title":"t","description":"d","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":{"id":"live-uuid","name":"Dup"},"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Claude"},"labels":{"nodes":[{"name":"agent:rust"}]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/CC-900","createdAt":"2026-09-02T00:00:00Z","updatedAt":"2026-09-02T00:00:00Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

run_create() {
  local scenario="$1"
  (
    cd "$TMP_ROOT" && \
    PATH="$TMP_ROOT/bin:$PATH" \
      LINEAR_API_KEY_OVERRIDE=test-token \
      CURL_PAYLOAD_LOG="$TMP_ROOT/$scenario-payloads.jsonl" \
      LINEAR_PROJECT_TEST_CASE="$scenario" \
      bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues create \
        --title t \
        --team Claude \
        --project Dup \
        --labels agent:rust \
        --priority 3 \
        --description d
  ) >"$TMP_ROOT/$scenario.out" 2>"$TMP_ROOT/$scenario.err"
}

# --- a live match wins, whichever order the API lists the duplicates in ------

for scenario in canceled-first live-first; do
  : >"$TMP_ROOT/$scenario-payloads.jsonl"
  rc=0
  run_status rc run_create "$scenario"

  assert_eq "issues create succeeds when a canceled project shares the name ($scenario)" \
    "$rc" 0

  assert "the issueCreate payload carries the live project id, not the canceled one ($scenario)" \
    jq -s -e 'any(.[]; (.query | contains("issueCreate")) and .variables.input.projectId == "live-uuid")' \
    "$TMP_ROOT/$scenario-payloads.jsonl" >/dev/null

  assert_not "no request names the canceled project id ($scenario)" \
    grep -qF 'dead-uuid' "$TMP_ROOT/$scenario-payloads.jsonl"
done

# The lookup asks for `state`: without it every match looks live and the
# selection above cannot be made.
assert "the project lookup selects state alongside id" \
  jq -s -e 'any(.[]; (.query | contains("projects(filter:")) and (.query | contains("nodes { id state }")))' \
  "$TMP_ROOT/canceled-first-payloads.jsonl" >/dev/null

# --- only-canceled matches are refused, not silently used --------------------

: >"$TMP_ROOT/only-canceled-payloads.jsonl"
rc=0
run_status rc run_create only-canceled

assert_ne "issues create fails when every same-name project is canceled" "$rc" 0

only_canceled_err="$(cat "$TMP_ROOT/only-canceled.err")"
assert_contains "the refusal names the project asked for" \
  "$only_canceled_err" "Project not found: Dup"
assert_contains "the refusal says no live project has the name" \
  "$only_canceled_err" "no live project has this name"
assert_contains "the refusal names each rejected uuid with the state that rejected it" \
  "$only_canceled_err" "dead-uuid (canceled), dead-two-uuid (canceled)"

assert_not "no issue is created against a canceled project" \
  grep -qF 'issueCreate' "$TMP_ROOT/only-canceled-payloads.jsonl"

# --- a genuine miss keeps the plain diagnostic -------------------------------

: >"$TMP_ROOT/no-match-payloads.jsonl"
rc=0
run_status rc run_create no-match

assert_ne "issues create fails when the name matches nothing" "$rc" 0
no_match_err="$(cat "$TMP_ROOT/no-match.err")"
assert_contains "a name that matches nothing reports a plain miss" \
  "$no_match_err" "Project not found: Dup"
assert_not_contains "a plain miss does not claim canceled matches" \
  "$no_match_err" "canceled"

# --- an API failure is not reported as a missing project ---------------------

: >"$TMP_ROOT/api-failure-payloads.jsonl"
rc=0
run_status rc run_create api-failure

assert_ne "issues create fails when the project lookup errors" "$rc" 0
api_failure_err="$(cat "$TMP_ROOT/api-failure.err")"
assert_contains "a failed lookup is reported as an API failure" \
  "$api_failure_err" "Linear API request failed"
assert_not_contains "a failed lookup is not reported as a missing project" \
  "$api_failure_err" "Project not found"

# --- a lone live match returns rather than aborting --------------------------
#
# The resolver reads the selection back as two lines, and with nothing rejected
# the second read hits EOF. Under the file's own errexit that status ended the
# function before it printed the id. Every call site here spells the call
# `var=$(resolve_project_id ...)`, which hides it, so the two shapes that do
# not are exercised directly: a bare call, and a command substitution under
# `shopt -s inherit_errexit`, which sync.sh sets.

cat >"$TMP_ROOT/direct.sh" <<'SH'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = inherit ]; then
  shopt -s inherit_errexit
fi
source "$2/.agents/skills/linear/scripts/lib/common.sh"
graphql_query() {
  printf '%s' '{"projects":{"nodes":[{"id":"live-uuid","state":"backlog"}]}}'
}
if [ "${1:-}" = inherit ]; then
  resolved="$(resolve_project_id Dup)"
  printf '%s\n' "$resolved"
else
  resolve_project_id Dup
fi
echo reached-the-end
SH

run_direct() {
  (
    cd "$TMP_ROOT" && LINEAR_API_KEY_OVERRIDE=test-token \
      bash "$TMP_ROOT/direct.sh" "$1" "$TMP_ROOT"
  ) >"$TMP_ROOT/direct-$1.out" 2>&1
}

for shape in bare inherit; do
  rc=0
  run_status rc run_direct "$shape"
  assert_eq "a lone live match resolves without aborting ($shape)" "$rc" 0
  direct_out="$(cat "$TMP_ROOT/direct-$shape.out")"
  assert_contains "the resolved id is printed ($shape)" "$direct_out" "live-uuid"
  assert_contains "the caller runs on past the resolve ($shape)" \
    "$direct_out" "reached-the-end"
done
