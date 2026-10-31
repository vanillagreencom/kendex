#!/usr/bin/env bash
# The legacy oracle of the verify differential test (tests/rust/verify.rs):
# one corpus case, judged by the legacy's own functions. `ci-run-correlation.sh`
# beside this file is sourced whole; `ci-wait` beside it supplies, by line
# number, `superseding_run_state` (719-804), `classify_checks` (806-816),
# `confirm_actions_for_checks` (821-833), the poll's `gh pr checks` read
# with its `checks-failed` exit (854-864) and the poll body from the
# required set read to the final sleep (884-1162). Both are verbatim copies;
# README.md names their commit. Nothing here is a workflow: the body runs
# once, in a subshell, against a `gh` function that answers from the case.
#
#   oracle.sh CASE.json EVENTS.json
#
# CASE.json is the adapter's rendering of a case to the legacy's inputs:
#   head, repo, repo_id, required_only, rollup (`gh pr checks` entries, or
#   null where `gh pr checks` failed: gh's GraphQL client fails it on any
#   reply error, so the legacy printed `checks-failed` and no verdict),
#   runs (the Actions list, one page; a run with a suite carries `_node`,
#   its check-suite node as the GraphQL answer returns it), rules, branch,
#   sources ([{id, full_name}], the repositories `repos/<name>` answers),
#   suites ({suite id: [{name, html_url}]}).
# EVENTS.json is the substantive-event list the correlation runs with: the
# legacy's literal in `superseding_run_state` is replaced by it, once.
#
# One JSON line on stdout:
#   outcome         complete | pending | unavailable | error
#   cause           on error, the key `emit_error` was given (checks-failed)
#   exit            the body's exit: complete 0 is the legacy's pass, 1 its fail
#   required_state  ready | pending | failed | unreadable (the required set read)
#   pending, failed, passed   the classification counts, null before one
#   supersede       every `supersede_state` the correlation produced, in order
#   classes         the classes the result carried ({pending, failed, passed})
#   scoped          the scoped rollup with buckets, null when never scoped
#   scoped_required the scoped members the requirements count
#   requirements    the evidence `classify_checks` read (REQUIREMENTS), null before one
#   rollup_classification  `classify_checks_rollup` over the rollup the body
#                   scoped and those requirements, as pr-merge called it:
#                   {head_runs, pending, failed, optional_failed}; null when
#                   never scoped
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE="$1"
EVENTS="$2"
[ -f "$CASE" ] && [ -f "$EVENTS" ] || { echo 'oracle: inputs=missing' >&2; exit 64; }

WORK="$(mktemp -d)" || { echo 'oracle: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $WORK && ! -L $WORK ]] || { echo "oracle: scratch=not-a-directory value=[$WORK]" >&2; exit 1; }
WORK="$(cd -- "$WORK" && pwd -P)" || { echo 'oracle: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${WORK:?}"' EXIT

REPO="$(jq -r .repo "$CASE")"
HEAD="$(jq -r .head "$CASE")"
ROLLUP="$(jq -c .rollup "$CASE")"
[ "$ROLLUP" != "[]" ] || { echo 'oracle: empty-rollup is not a corpus input' >&2; exit 64; }
jq -e '.rollup | type == "array" or type == "null"' "$CASE" >/dev/null || { echo 'oracle: rollup is neither an array nor null' >&2; exit 64; }

# The legacy's GitHub, answered from the case. Every call the copied
# functions make is listed; any other is a failure of this oracle.
gh() {
  local last="${*: -1}" suite
  case "$*" in
    "pr checks 1 --repo $REPO --json name,state,bucket,link,startedAt,workflow")
      # The rollup, or the failure gh's GraphQL client turned a reply error
      # into (gh v2.103.3 `api/client.go` `Client.GraphQL`; `checks.go:281`).
      [ "$ROLLUP" != null ] || { echo 'GraphQL: Something went wrong while executing your query.' >&2; return 1; }
      printf '%s\n' "$ROLLUP" ;;
    "pr view 1 --repo $REPO --json baseRefName --jq .baseRefName") echo main ;;
    "pr view 1 --repo $REPO --json headRefOid --jq .headRefOid") printf '%s\n' "$HEAD" ;;
    "api repos/$REPO/rules/branches/main --paginate --jq "*) jq -r "$last" <<<"$(jq -c .rules "$CASE")" ;;
    "api repos/$REPO/branches/main") jq -c .branch "$CASE" ;;
    "api repos/$REPO --jq .id") jq -r .repo_id "$CASE" ;;
    "api repos/$REPO/actions/runs?head_sha=$HEAD&per_page=100 --paginate --slurp")
      jq -c '[{total_count: (.runs | length), workflow_runs: (.runs | map(del(._node)))}]' "$CASE" ;;
    "api graphql --input -")
      # One node per id asked, as GitHub answers `nodes(ids:)`: the run's
      # `_node`, rendered from the case's source fields, null for an id no
      # run carries.
      jq -c --argjson request "$(cat)" '
        [.runs[] | select(has("_node")) | ._node] as $nodes
        | {data: {nodes: [$request.variables.ids[] | . as $id | ([$nodes[] | select(.id == $id)] | .[0])]}}' "$CASE" ;;
    "api repos/$REPO/check-suites/"*"/check-runs?per_page=100 --paginate --slurp")
      suite="${2#*/check-suites/}"
      suite="${suite%%/*}"
      jq -c --arg s "$suite" '(.suites[$s] // []) | [{total_count: length, check_runs: .}]' "$CASE" ;;
    "api repos/"*)
      # The repositories the proofs name, by name; an unknown name is gh's
      # failed request.
      [ "$#" -eq 2 ] || { echo "oracle: unexpected-gh-call args=[$*]" >&2; return 70; }
      jq -ce --arg name "${2#repos/}" '[.sources[] | select((.full_name | ascii_downcase) == ($name | ascii_downcase))] | .[0] // empty' "$CASE" >/dev/null 2>&1 || return 1
      jq -c --arg name "${2#repos/}" '[.sources[] | select((.full_name | ascii_downcase) == ($name | ascii_downcase))] | .[0]' "$CASE" ;;
    *) echo "oracle: unexpected-gh-call args=[$*]" >&2; return 70 ;;
  esac
}

# shellcheck source=ci-run-correlation.sh
source "$HERE/ci-run-correlation.sh"

extract() { sed -n "$1,$2p" "$HERE/ci-wait"; }

# The substantive-event list, parameterized: the one literal is replaced,
# and the edit asserts its match count.
superseding="$(extract 719 804)"
literal='IN("pull_request", "pull_request_review", "pull_request_review_comment", "merge_group")'
matches="$(grep -cF -- "$literal" <<<"$superseding")" || true
[ "$matches" = 1 ] || { echo "oracle: event-literal matches=$matches" >&2; exit 65; }
replacement="IN($(jq -r 'map(tojson) | join(", ")' "$EVENTS"))"
parameterized="${superseding/"$literal"/"$replacement"}"
[ "$parameterized" != "$superseding" ] || { echo 'oracle: event-literal edit=unchanged' >&2; exit 65; }
eval "$parameterized"
eval "$(extract 806 816)"
eval "$(extract 821 833)"
extract 854 864 > "$WORK/fetch.sh"
extract 884 1162 > "$WORK/body.sh"

# Recorders around the legacy's own functions: the scoped rollup, the
# requirements the classification read, and every correlation state.
eval "legacy_$(declare -f scope_current_run)"
scope_current_run() {
  local input out
  input="$(cat)"
  printf '%s\n' "$input" > "$WORK/scoped-input.json"
  out="$(legacy_scope_current_run "$@" <<<"$input")" || return $?
  printf '%s\n' "$out" > "$WORK/scoped.json"
  printf '%s\n' "$out"
}
eval "legacy_$(declare -f classify_checks)"
classify_checks() {
  printf '%s\n' "$REQUIREMENTS" > "$WORK/requirements.json"
  legacy_classify_checks "$@"
}
eval "legacy_$(declare -f confirm_actions_for_checks)"
confirm_actions_for_checks() {
  local rc=0
  legacy_confirm_actions_for_checks "$@" || rc=$?
  printf '%s\n' "${supersede_state:-}" >> "$WORK/supersede.log"
  return "$rc"
}

# The body's surroundings, stubbed: one poll, no clock, no retry, no mail.
ci_message() { printf '%s\n' "$1" >> "$WORK/messages.log"; }
read_checks_head() { printf '%s\n' "$HEAD"; }
update_elapsed() { :; }
get_failed_run_id() { :; }
is_transient_failure() { return 1; }
record() { # STATUS CLASSES [CAUSE]
  jq -cn --arg status "$1" --argjson classes "$2" --arg cause "${3:-}" --arg req "$required_state" \
    --arg pending "${pending_count:-}" --arg failed "${failed_count:-}" --arg passed "${success_count:-}" \
    '{status: $status, classes: $classes, required_state: $req,
      cause: (if $cause == "" then null else $cause end),
      pending: ($pending | if . == "" then null else tonumber end),
      failed: ($failed | if . == "" then null else tonumber end),
      passed: ($passed | if . == "" then null else tonumber end)}' > "$WORK/result.json"
}
emit_result() { record "$1" "$2"; }
# The legacy's `emit_error` (`ci-wait:463-465`) is `emit_result "error"
# "$last_check_classes" "$(ci_message "$@")"`; its message is the key, which
# the stubbed `ci_message` logs, so the key is recorded as the cause.
emit_error() { record error "$last_check_classes" "$1"; }
# Every sleep in the body is followed by `continue`: one poll is the whole
# oracle, and the legacy would reach its deadline as `pending`.
poll_sleep() { record pending "$last_check_classes"; exit 3; }

rc=0
(
  PR_NUM=1
  REQUIRED_ONLY="$(jq -r .required_only "$CASE")"
  REQUIREMENTS='[]'
  checks_head="$HEAD"
  confirmation_head="$HEAD"
  checks_stderr="$WORK/checks.stderr"
  seen_in_progress=false
  stale_key=""
  stale_since=0
  elapsed=0
  # A settled green rollup completes once the window has measured it; the
  # one poll stands for that measured window.
  STALE_WINDOW=0
  settled_this_poll=false
  retries=0
  max_retries=0
  required_state=ready
  rollup_key=""
  last_check_classes='{"pending":[],"failed":[],"passed":[]}'
  no_checks_count=0
  checks_seen=false
  no_checks_since=0
  NO_CHECKS_GRACE=600
  max_no_checks=1
  POLL_INTERVAL=1
  MAX_WAIT=600
  ci_probe_done=true
  no_checks_due=false
  JSON_OUTPUT=true
  # The poll's `gh pr checks` read (`ci-wait:854-864`): the rollup, or the
  # legacy's `checks-failed` exit with no verdict.
  # shellcheck source=/dev/null
  source "$WORK/fetch.sh"
  while true; do
    # shellcheck source=/dev/null
    source "$WORK/body.sh"
    break
  done
  echo 'oracle: body fell through without a result' >&2
  exit 70
) || rc=$?
[ -f "$WORK/result.json" ] || { echo "oracle: no-result exit=$rc" >&2; exit 70; }
case "$rc" in 0|1|3) ;; *) echo "oracle: body-exit=$rc" >&2; exit 70 ;; esac

outcome="$(jq -r .status "$WORK/result.json")"
if [ -f "$WORK/messages.log" ] && grep -qxE 'actions-read-failed|actions-response-invalid' "$WORK/messages.log"; then
  outcome=unavailable
fi
scoped=null
scoped_required=null
requirements=null
rollup_classification=null
if [ -f "$WORK/scoped.json" ]; then
  scoped="$(jq -c "$CI_RUN_JQ_DEFS"'map({name, state, bucket: bucket, link: (.link // ""), workflow: (.workflow // ""), _id})' "$WORK/scoped.json")"
  requirements='[]'
  [ ! -f "$WORK/requirements.json" ] || requirements="$(cat "$WORK/requirements.json")"
  scoped_required="$(jq -c --argjson req "$requirements" "$CI_RUN_JQ_DEFS"'map(select(required_only($req)) | {name, state, bucket: bucket, link: (.link // ""), workflow: (.workflow // ""), _id})' "$WORK/scoped.json")"
  # The merge gate's classification over the same rollup and evidence, the
  # legacy's own naming of the runs the selection scoped to.
  rollup_classification="$(classify_checks_rollup "$requirements" < "$WORK/scoped-input.json" | jq -c '{head_runs, pending, failed, optional_failed}')"
fi
supersede='[]'
[ ! -f "$WORK/supersede.log" ] || supersede="$(jq -R -s -c 'split("\n") | map(select(. != ""))' "$WORK/supersede.log")"
jq -c --arg outcome "$outcome" --argjson exit "$rc" --argjson supersede "$supersede" \
  --argjson scoped "$scoped" --argjson scoped_required "$scoped_required" \
  --argjson requirements "$requirements" --argjson rollup_classification "$rollup_classification" \
  '. + {outcome: $outcome, exit: $exit, supersede: $supersede, scoped: $scoped, scoped_required: $scoped_required,
        requirements: $requirements, rollup_classification: $rollup_classification}' \
  "$WORK/result.json"
