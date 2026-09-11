#!/usr/bin/env bash
# Tests for orch/scripts/approval-wait, the reviewer-gate poller. It reads
# formal review verdicts (`gh pr view --json reviewDecision,latestReviews` in
# approval mode; the REST reviews listing pinned to the current head in
# --mode review), the unresolved review-thread count and, in review mode, the
# trusted check-run or commit-status evidence PR_REVIEW_CHECK names; never
# emoji reactions, sticky comments or checklist prose.
#
# One case per behaviour surface; shaped input is one table per case, one
# asserted row per shape. A row's `expect` names the fields it pins; `observe`
# reads exactly those from the run, so a row fails on the field it names.
# The pre-poll CLI layer (--resolve-mode, --help, unknown flags) is
# approval_wait_cli.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# The pass/fail counters and the assertion vocabulary every waiter suite shares.
# shellcheck source=lib/waiter-assertions.sh
source "$TEST_DIR/lib/waiter-assertions.sh"

mkdir -p "$TMP_ROOT/repo/.agents/skills" "$TMP_ROOT/bin" "$TMP_ROOT/runs"
ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/repo/.agents/skills/orch"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config user.email test@example.com
git -C "$TMP_ROOT/repo" config user.name Test

# Parametrized `gh` stub (same auth model as the ci_wait stub), a neutral fake
# GitHub: every payload is selected per run by the STUB_* variables below, so
# no case inherits another's world.
#   STUB_APPROVAL_MODE selects the canned `pr view --json
#   reviewDecision,latestReviews` payload; STUB_THREADS_UNRESOLVED sets the
#   unresolved count returned by the `api graphql` reviewThreads query.
#   STUB_APPROVAL_COUNT_FILE turns *_later modes into poll-count-driven
#   sequences (first poll pending, second poll terminal).
#   Review mode: `pr view --json headRefOid,author` reports head "headsha1"
#   and author "pr-author" (STUB_HEAD_MODE=changes flips to "headsha2" after
#   two calls via STUB_HEAD_COUNT_FILE); STUB_REVIEWS_MODE selects the canned
#   REST pulls/reviews payload, with STUB_REVIEWS_COUNT_FILE driving the
#   reviewed_later poll sequence.
#   Check-runs: `api repos/*/commits/<sha>/check-runs` answers per the sha in
#   the URL — STUB_CHECKS_MODE=success_at_head/failure_at_head publishes a
#   "Review Bot" run (older failure + newer terminal run, plus an unrelated
#   "Other Check") on headsha1 only; success_stale publishes it on oldsha
#   only, so the current-head query finds nothing.
#   Automatic-review target set: `api repos/owner/repo` answers the default
#   branch (STUB_DEFAULT_BRANCH, or a 500 under STUB_DEFAULT_BRANCH_MODE=fail);
#   `api repos/*/rulesets` and its detail answer ruleset 1 carrying the
#   copilot_code_review rule — STUB_RULESET_INCLUDE / STUB_RULESET_EXCLUDE are
#   its space-separated ref_name conditions and STUB_RULESET_DETAIL_MODE=fail
#   fails its detail read; STUB_RULESET2_INCLUDE / STUB_RULESET2_EXCLUDE give
#   ruleset 2, walked first, a rule of its own. STUB_RULESETS_MODE=none drops
#   the rule; fail, denied, not_found and rate_limited fail the listing with a
#   500, a 403, a 404 and a rate-limited 403; paged moves ruleset 1 to a second
#   page that only --paginate reads. Every `pr view` payload carries
#   STUB_BASE_REF.
#   Commit statuses: `api repos/*/commits/<sha>/status` (combined status)
#   answers likewise — STUB_STATUS_MODE=success_at_head/pending_at_head/
#   failure_at_head/error_at_head publishes a "Review Bot" context (older
#   pending entry + newer terminal status, plus an unrelated "Other Status")
#   on headsha1 only; success_stale publishes it on oldsha only. Each status
#   query appends to STUB_STATUS_LOG (when set) so tests can assert the
#   fallback is skipped once a check-run matches.
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

_stub_auth_ok() {
  local tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -n "$tok" ]]; then
    [[ -n "${STUB_GH_VALID_TOKEN:-}" && "$tok" == "$STUB_GH_VALID_TOKEN" ]] && return 0
    return 1
  fi
  [[ "${STUB_GH_DENY_KEYRING:-0}" == "1" ]] && return 1
  return 0
}

# A JSON array from space-separated words, for the ruleset ref_name conditions.
_stub_json_array() { # WORDS
  local out="" word
  for word in $1; do
    [[ -n "$out" ]] && out+=","
    out+="\"$word\""
  done
  printf '[%s]' "$out"
}

# A ruleset detail carrying the copilot_code_review rule beside a deletion rule.
_stub_copilot_ruleset() { # ID INCLUDE_WORDS EXCLUDE_WORDS
  printf '{"id":%s,"target":"branch","enforcement":"active","conditions":{"ref_name":{"include":%s,"exclude":%s}},"rules":[{"type":"deletion"},{"type":"copilot_code_review","parameters":{"review_on_push":true,"review_draft_pull_requests":false}}]}\n' \
    "$1" "$(_stub_json_array "$2")" "$(_stub_json_array "$3")"
}

_bump_count() {
  local count=0
  if [[ -f "${STUB_APPROVAL_COUNT_FILE:?}" ]]; then
    count="$(cat "$STUB_APPROVAL_COUNT_FILE")"
  fi
  count=$((count + 1))
  printf '%s' "$count" > "$STUB_APPROVAL_COUNT_FILE"
  printf '%s' "$count"
}

case "${1:-}" in
  auth)
    if [[ "${2:-}" == "status" ]]; then
      if _stub_auth_ok; then
        echo "Logged in"
        exit 0
      fi
      echo "auth failed" >&2
      exit 1
    fi
    ;;
  api)
    # Commit-status POST tripwire: repos/<repo>/statuses/<sha> (plural —
    # distinct from the singular commits/<sha>/status read). approval-wait must
    # never post a commit status; tests opt in via STUB_MARKER_LOG and assert
    # the log stays empty.
    if [[ "$*" == *"/statuses/"* ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      [[ -n "${STUB_MARKER_LOG:-}" ]] && printf 'marker:%s\n' "$*" >> "$STUB_MARKER_LOG"
      echo '{}'
      exit 0
    fi
    if [[ "${2:-}" == "user" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "test-user"
      exit 0
    fi
    # Repository metadata: approval-wait reads only .default_branch, through
    # gh's own -q filter, so the stub answers with the branch name.
    if [[ "${2:-}" == "repos/owner/repo" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      if [[ "${STUB_DEFAULT_BRANCH_MODE:-ok}" == "fail" ]]; then
        echo "HTTP 500: Internal Server Error" >&2
        exit 1
      fi
      printf '%s\n' "${STUB_DEFAULT_BRANCH:-main}"
      exit 0
    fi
    # Ruleset listing: no rules or conditions, exactly as GitHub's does. The
    # copilot_code_review rule lives on ruleset 1 alone, behind a tag ruleset, an
    # inactive branch ruleset and a branch ruleset with only a deletion rule, so
    # the walk must filter and step past all three to find it.
    if [[ "${2:-}" == repos/*/rulesets ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      case "${STUB_RULESETS_MODE:-copilot}" in
        fail) echo "HTTP 500: Internal Server Error" >&2; exit 1 ;;
        denied) echo "HTTP 403: Resource not accessible by integration" >&2; exit 1 ;;
        not_found) echo "HTTP 404: Not Found" >&2; exit 1 ;;
        rate_limited) echo "HTTP 403: API rate limit exceeded for installation ID 1." >&2; exit 1 ;;
        none) echo '[{"id":2,"target":"branch","enforcement":"active"}]' ;;
        paged)
          echo '[{"id":3,"target":"tag","enforcement":"active"},{"id":2,"target":"branch","enforcement":"active"}]'
          if [[ " $* " == *" --paginate "* ]]; then
            echo '[{"id":1,"target":"branch","enforcement":"active"}]'
          fi
          ;;
        *) echo '[{"id":3,"target":"tag","enforcement":"active"},{"id":4,"target":"branch","enforcement":"evaluate"},{"id":2,"target":"branch","enforcement":"active"},{"id":1,"target":"branch","enforcement":"active"}]' ;;
      esac
      exit 0
    fi
    if [[ "${2:-}" == repos/*/rulesets/* ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      ruleset_id="${2##*/}"
      if [[ "$ruleset_id" == "2" && -n "${STUB_RULESET2_INCLUDE:-}" ]]; then
        _stub_copilot_ruleset 2 "$STUB_RULESET2_INCLUDE" "${STUB_RULESET2_EXCLUDE:-}"
        exit 0
      fi
      if [[ "$ruleset_id" != "1" ]]; then
        printf '{"id":%s,"target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},"rules":[{"type":"deletion"}]}\n' "$ruleset_id"
        exit 0
      fi
      if [[ "${STUB_RULESET_DETAIL_MODE:-ok}" == "fail" ]]; then
        echo "HTTP 500: Internal Server Error" >&2
        exit 1
      fi
      _stub_copilot_ruleset 1 "${STUB_RULESET_INCLUDE:-~DEFAULT_BRANCH}" "${STUB_RULESET_EXCLUDE:-}"
      exit 0
    fi
    if [[ "${2:-}" == repos/*/pulls/*/reviews ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      mode="${STUB_REVIEWS_MODE:-none}"
      if [[ "$mode" == "flaky_503" ]]; then
        count=0
        if [[ -f "${STUB_REVIEWS_COUNT_FILE:?}" ]]; then
          count="$(cat "$STUB_REVIEWS_COUNT_FILE")"
        fi
        count=$((count + 1))
        printf '%s' "$count" > "$STUB_REVIEWS_COUNT_FILE"
        if [[ "$count" -le 2 ]]; then
          echo "HTTP 503: No server is currently available to service your request." >&2
          exit 1
        fi
        mode="commented_at_head"
      fi
      if [[ "$mode" == "flaky_429" ]]; then
        count=0
        if [[ -f "${STUB_REVIEWS_COUNT_FILE:?}" ]]; then
          count="$(cat "$STUB_REVIEWS_COUNT_FILE")"
        fi
        count=$((count + 1))
        printf '%s' "$count" > "$STUB_REVIEWS_COUNT_FILE"
        if [[ "$count" -le 2 ]]; then
          echo "HTTP 429: You have exceeded a secondary rate limit. Please wait a few minutes before you try again." >&2
          exit 1
        fi
        mode="commented_at_head"
      fi
      if [[ "$mode" == "http_503" ]]; then
        echo "HTTP 503: No server is currently available to service your request." >&2
        exit 1
      fi
      if [[ "$mode" == "http_404" ]]; then
        echo "HTTP 404: Not Found (https://api.github.com/repos/owner/repo/pulls/1/reviews)" >&2
        exit 1
      fi
      if [[ "$mode" == "reviewed_later" ]]; then
        count=0
        if [[ -f "${STUB_REVIEWS_COUNT_FILE:?}" ]]; then
          count="$(cat "$STUB_REVIEWS_COUNT_FILE")"
        fi
        count=$((count + 1))
        printf '%s' "$count" > "$STUB_REVIEWS_COUNT_FILE"
        if [[ "$count" -lt 2 ]]; then
          mode="none"
        else
          mode="commented_at_head"
        fi
      fi
      case "$mode" in
        commented_at_head)
          echo '[{"user":{"login":"reviewer1"},"state":"COMMENTED","commit_id":"headsha1"}]'
          ;;
        commented_stale)
          echo '[{"user":{"login":"reviewer1"},"state":"COMMENTED","commit_id":"oldsha"}]'
          ;;
        author_only)
          echo '[{"user":{"login":"pr-author"},"state":"COMMENTED","commit_id":"headsha1"}]'
          ;;
        dismissed_only)
          echo '[{"user":{"login":"reviewer1"},"state":"DISMISSED","commit_id":"headsha1"}]'
          ;;
        changes_standing)
          echo '[{"user":{"login":"reviewer1"},"state":"CHANGES_REQUESTED","commit_id":"headsha1"}]'
          ;;
        changes_superseded)
          echo '[{"user":{"login":"reviewer1"},"state":"CHANGES_REQUESTED","commit_id":"oldsha"},{"user":{"login":"reviewer1"},"state":"COMMENTED","commit_id":"headsha1"}]'
          ;;
        approved_at_head)
          echo '[{"user":{"login":"reviewer1"},"state":"APPROVED","commit_id":"headsha1"}]'
          ;;
        none|*)
          echo '[]'
          ;;
      esac
      exit 0
    fi
    if [[ "${2:-}" == repos/*/commits/*/check-runs ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      sha="${2##*/commits/}"
      sha="${sha%/check-runs}"
      mode="${STUB_CHECKS_MODE:-none}"
      run_sha="headsha1"
      [[ "$mode" == "success_stale" ]] && run_sha="oldsha"
      conclusion="success"
      [[ "$mode" == "failure_at_head" ]] && conclusion="failure"
      if [[ "$mode" != "none" && "$sha" == "$run_sha" ]]; then
        # Older same-name failure + newer terminal run of "Review Bot" (the
        # newest of the name must win) + an unrelated always-green check (the
        # name filter must exclude it).
        printf '{"total_count":3,"check_runs":[{"name":"Review Bot","conclusion":"failure","started_at":"2026-01-01T00:00:00Z","app":{"slug":"review-bot"}},{"name":"Review Bot","conclusion":"%s","started_at":"2026-01-02T00:00:00Z","app":{"slug":"review-bot"}},{"name":"Other Check","conclusion":"success","started_at":"2026-01-03T00:00:00Z","app":{"slug":"other-app"}}]}\n' "$conclusion"
      else
        echo '{"total_count":0,"check_runs":[]}'
      fi
      exit 0
    fi
    if [[ "${2:-}" == repos/*/commits/*/status ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      if [[ -n "${STUB_STATUS_LOG:-}" ]]; then
        echo "status:$2" >> "$STUB_STATUS_LOG"
      fi
      sha="${2##*/commits/}"
      sha="${sha%/status}"
      mode="${STUB_STATUS_MODE:-none}"
      run_sha="headsha1"
      [[ "$mode" == "success_stale" ]] && run_sha="oldsha"
      state="success"
      case "$mode" in
        pending_at_head) state="pending" ;;
        failure_at_head) state="failure" ;;
        error_at_head) state="error" ;;
      esac
      if [[ "$mode" != "none" && "$sha" == "$run_sha" ]]; then
        # Older same-context pending entry + newer terminal status of
        # "Review Bot" (the newest of the context must win) + an unrelated
        # always-green context (the context filter must exclude it).
        printf '{"state":"pending","total_count":3,"statuses":[{"context":"Review Bot","state":"pending","updated_at":"2026-01-01T00:00:00Z","creator":{"login":"review-bot[bot]"}},{"context":"Review Bot","state":"%s","updated_at":"2026-01-02T00:00:00Z","creator":{"login":"review-bot[bot]"}},{"context":"Other Status","state":"success","updated_at":"2026-01-03T00:00:00Z","creator":{"login":"other-bot"}}]}\n' "$state"
      else
        echo '{"state":"pending","total_count":0,"statuses":[]}'
      fi
      exit 0
    fi
    if [[ "${2:-}" == "graphql" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      unresolved="${STUB_THREADS_UNRESOLVED:-0}"
      nodes=""
      for ((i=0; i<unresolved; i++)); do
        [[ -n "$nodes" ]] && nodes+=","
        nodes+='{"isResolved":false}'
      done
      printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[%s],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}\n' "$nodes"
      exit 0
    fi
    ;;
  repo)
    if [[ "${2:-}" == "view" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "owner/repo"
      exit 0
    fi
    ;;
  pr)
    if [[ "${2:-}" == "view" ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      # Head-only confirm query (`--json headRefOid -q .headRefOid`), distinct
      # from the poll snapshots: return the raw sha. STUB_CONFIRM_HEAD overrides
      # it to simulate a push in the last-poll -> emit window; default matches
      # the poll head so a stable wait confirms and proceeds.
      if [[ "$*" == *"-q .headRefOid"* ]]; then
        printf '%s\n' "${STUB_CONFIRM_HEAD:-headsha1}"
        exit 0
      fi
      if [[ "$*" == *reviewDecision* ]]; then
        mode="${STUB_APPROVAL_MODE:-none}"
        if [[ "$mode" == "approved_after_503" ]]; then
          count="$(_bump_count)"
          if [[ "$count" -le 2 ]]; then
            echo "HTTP 503: No server is currently available to service your request." >&2
            exit 1
          fi
          mode="approved_decision"
        fi
        if [[ "$mode" == "approved_later" ]]; then
          count="$(_bump_count)"
          if [[ "$count" -lt 2 ]]; then
            mode="none"
          else
            mode="approved_decision"
          fi
        fi
        case "$mode" in
          approved_decision)
            echo '{"reviewDecision":"APPROVED","headRefOid":"headsha1","baseRefName":"'"${STUB_BASE_REF:-main}"'","latestReviews":[{"author":{"login":"reviewer1"},"state":"APPROVED"}]}'
            ;;
          approved_latest)
            echo '{"reviewDecision":"","headRefOid":"headsha1","baseRefName":"'"${STUB_BASE_REF:-main}"'","latestReviews":[{"author":{"login":"reviewer1"},"state":"APPROVED"},{"author":{"login":"colleague"},"state":"COMMENTED"}]}'
            ;;
          changes)
            echo '{"reviewDecision":"","headRefOid":"headsha1","baseRefName":"'"${STUB_BASE_REF:-main}"'","latestReviews":[{"author":{"login":"reviewer1"},"state":"CHANGES_REQUESTED"},{"author":{"login":"colleague"},"state":"APPROVED"}]}'
            ;;
          commented_only)
            echo '{"reviewDecision":"","headRefOid":"headsha1","baseRefName":"'"${STUB_BASE_REF:-main}"'","latestReviews":[{"author":{"login":"reviewer1"},"state":"COMMENTED"}]}'
            ;;
          required_pending)
            echo '{"reviewDecision":"REVIEW_REQUIRED","headRefOid":"headsha1","baseRefName":"'"${STUB_BASE_REF:-main}"'","latestReviews":[{"author":{"login":"colleague"},"state":"APPROVED"}]}'
            ;;
          none|*)
            echo '{"reviewDecision":"","headRefOid":"headsha1","baseRefName":"'"${STUB_BASE_REF:-main}"'","latestReviews":[]}'
            ;;
        esac
        exit 0
      fi
      if [[ "$*" == *headRefOid* ]]; then
        head="headsha1"
        if [[ "${STUB_HEAD_MODE:-static}" == "changes" ]]; then
          count=0
          if [[ -f "${STUB_HEAD_COUNT_FILE:?}" ]]; then
            count="$(cat "$STUB_HEAD_COUNT_FILE")"
          fi
          count=$((count + 1))
          printf '%s' "$count" > "$STUB_HEAD_COUNT_FILE"
          if [[ "$count" -gt 2 ]]; then
            head="headsha2"
          fi
        fi
        printf '{"headRefOid":"%s","author":{"login":"pr-author"},"baseRefName":"%s"}\n' "$head" "${STUB_BASE_REF:-main}"
        exit 0
      fi
    fi
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"

# Virtual clock, on the same PATH as the gh stub: `date +%s` reads a file the
# `sleep` stub advances, so the poll budgets below are spent in arithmetic
# rather than in real seconds. Rationale and the per-case escape hatch back to
# real time: lib/virtual-clock.sh.
# shellcheck source=lib/virtual-clock.sh
source "$TEST_DIR/lib/virtual-clock.sh"
virtual_clock_install "$TMP_ROOT/bin" "$TMP_ROOT/clock"

# The suite's own default for the reviewer-down setting; the on-timeout case
# overrides or unsets it per row.
export PR_REVIEW_ON_TIMEOUT=block

# run_wait ENV ARGS... — runs approval-wait via the .agents symlink, exactly
# how production invokes it, in the fixture repo with the stub PATH. ENV is a
# comma-separated list of `env` arguments (assignments or `-u NAME`), so a
# value may carry a space. Every run gets its own count, log and stderr files
# under $RUN, so no row reads another's polls or posts. Sets OUT and RC.
RUN=""
run_wait() {
  local env_list="$1" env_args=()
  shift
  RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"
  mkdir -p "$RUN"
  [[ -z "$env_list" ]] || IFS=',' read -ra env_args <<<"$env_list"
  set +e
  OUT=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" \
    env ${env_args[@]+"${env_args[@]}"} \
        STUB_APPROVAL_COUNT_FILE="$RUN/approval-polls" \
        STUB_REVIEWS_COUNT_FILE="$RUN/review-polls" \
        STUB_HEAD_COUNT_FILE="$RUN/head-polls" \
        STUB_STATUS_LOG="$RUN/status-queries" \
        STUB_MARKER_LOG="$RUN/marker-posts" \
        .agents/skills/orch/scripts/approval-wait "$@" 2>"$RUN/stderr")
  RC=$?
  set -e
}
RUN_SEQ=0

count_lines() { # FILE — 0 when it was never written
  [[ -f "$1" ]] && wc -l <"$1" | tr -d ' ' || echo 0
}

# observe EXPECT — prints the run's value of every `name=` field EXPECT names,
# in EXPECT's order, so a row compares as one string. Plain names are JSON
# result fields; the derived names read the run's files or its timing:
#   early     elapsed_seconds < 3, the return came before a 3s deadline
#   spent     elapsed_seconds >= 3, the whole 3s budget was used
#   stdout    `line` when anything was printed, `empty` otherwise
#   approval_polls / review_polls   how often the stub answered that listing
#   status_queries                  combined-status reads the stub served
#   marker_posts                    commit-status POSTs the stub received
#   outage_marker                   whether the JSON carries that field
#   target_patterns   auto_review_targets joined, so a row compares as one word
#   transient_errors_seen           transient_api_errors >= 1
observe() {
  local got="" token name
  for token in $1; do
    name="${token%%=*}"
    case "$name" in
      rc) got="$got rc=$RC" ;;
      early) got="$got early=$(json '.elapsed_seconds < 3')" ;;
      spent) got="$got spent=$(json '.elapsed_seconds >= 3')" ;;
      stdout) got="$got stdout=$([[ -n "$OUT" ]] && echo line || echo empty)" ;;
      text_status) got="$got text_status=$(sed -n '1s/^approval-wait: result status=\([^ ]*\).*$/\1/p' <<<"$OUT")" ;;
      approval_polls) got="$got approval_polls=$(cat "$RUN/approval-polls" 2>/dev/null || echo 0)" ;;
      review_polls) got="$got review_polls=$(cat "$RUN/review-polls" 2>/dev/null || echo 0)" ;;
      status_queries) got="$got status_queries=$(count_lines "$RUN/status-queries")" ;;
      marker_posts) got="$got marker_posts=$(count_lines "$RUN/marker-posts")" ;;
      outage_marker) got="$got outage_marker=$(json 'has("outage_marker")')" ;;
      transient_errors_seen) got="$got transient_errors_seen=$(json '.transient_api_errors >= 1')" ;;
      target_patterns) got="$got target_patterns=$(json '.auto_review_targets | join(",")')" ;;
      *) got="$got $name=$(json ".$name")" ;;
    esac
  done
  printf '%s' "${got# }"
}
json() { jq -r "$1" <<<"$OUT" 2>/dev/null || echo UNPARSEABLE; }

# table DEFAULT_ARGS ROW... — one run and one assertion per row. A row is
# `label|args|env|expect`; empty args mean DEFAULT_ARGS. Positional args are
# `<pr> <poll-interval> <budget-seconds>` plus flags, on the virtual clock.
table() {
  local default_args="$1" row label args env expect
  shift
  for row in "$@"; do
    IFS='|' read -r label args env expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    [[ -n "$args" ]] || args="$default_args"
    # shellcheck disable=SC2086
    run_wait "$env" $args
    assert_eq "$(observe "$expect")" "$expect" "$label" "$RUN/stderr"
  done
}

APPROVAL='1 1 3 --json'
REVIEW='1 1 3 --json --mode review'

echo "=== approval mode: the verdict rule over the pr view payload and the thread count ==="
# A reviewDecision decides; with none, the latest review per reviewer does,
# and REVIEW_REQUIRED means protection still wants more. COMMENTED is never a
# verdict. Open threads with no verdict return before the deadline so the
# caller triages; open threads beside an approval ride along as a count for
# the caller's own gate. A later poll picks up a verdict the first missed.
table "$APPROVAL" \
  'reviewDecision APPROVED approves||STUB_APPROVAL_MODE=approved_decision|rc=0 status=approved review_decision=APPROVED approvals=1' \
  'no reviewDecision, a latest APPROVED approves via latestReviews||STUB_APPROVAL_MODE=approved_latest|rc=0 status=approved review_decision= approvals=1' \
  'a latest CHANGES_REQUESTED blocks beside another approval||STUB_APPROVAL_MODE=changes|rc=1 status=changes_requested changes_requested=1' \
  'COMMENTED-only latest reviews are no verdict||STUB_APPROVAL_MODE=commented_only|rc=1 status=timeout approvals=0' \
  'open threads with no verdict return comments before the deadline||STUB_APPROVAL_MODE=none,STUB_THREADS_UNRESOLVED=2|rc=1 status=comments unresolved_count=2 early=true' \
  'nothing at the deadline is a timeout||STUB_APPROVAL_MODE=none|rc=1 status=timeout' \
  'REVIEW_REQUIRED keeps a latest APPROVED from approving||STUB_APPROVAL_MODE=required_pending|rc=1 status=timeout review_decision=REVIEW_REQUIRED' \
  'approved with open threads stays approved and carries the count||STUB_APPROVAL_MODE=approved_decision,STUB_THREADS_UNRESOLVED=1|rc=0 status=approved unresolved_count=1' \
  'a verdict arriving on the second poll approves||STUB_APPROVAL_MODE=approved_later|rc=0 status=approved approval_polls=2' \
  'an auth failure is a parseable error object||GH_TOKEN=bad-token,STUB_GH_DENY_KEYRING=1|rc=3 status=error'

echo "=== review mode: the evidence rule over reviews, check-runs and commit statuses at the head ==="
# A review counts only at the current head, from someone other than the
# author, not dismissed; the latest per reviewer stands, so a standing
# CHANGES_REQUESTED blocks and a superseded one does not. With PR_REVIEW_CHECK
# set, a success of that name on the head is evidence too: check-runs first,
# then the combined status, newest of the name winning and unrelated names
# ignored (the stub publishes both distractors). A review object outranks
# either surface; open threads and a standing CHANGES_REQUESTED block whatever
# the evidence; an empty PR_REVIEW_CHECK reads neither surface.
table "$REVIEW" \
  'a COMMENTED review at head with no open threads is reviewed||STUB_REVIEWS_MODE=commented_at_head|rc=0 status=reviewed mode=review head_sha=headsha1 reviews_at_head=1' \
  'a review at head with open threads returns comments before the deadline||STUB_REVIEWS_MODE=commented_at_head,STUB_THREADS_UNRESOLVED=2|rc=1 status=comments unresolved_count=2 early=true' \
  'a review of a superseded commit is not at head||STUB_REVIEWS_MODE=commented_stale|rc=1 status=timeout reviews_at_head=0' \
  "the author's own review is excluded||STUB_REVIEWS_MODE=author_only|rc=1 status=timeout reviews_at_head=0" \
  'a DISMISSED review is excluded||STUB_REVIEWS_MODE=dismissed_only|rc=1 status=timeout reviews_at_head=0' \
  'a standing CHANGES_REQUESTED blocks the review gate||STUB_REVIEWS_MODE=changes_standing|rc=1 status=changes_requested changes_requested=1' \
  'a CHANGES_REQUESTED superseded by the same reviewer no longer stands||STUB_REVIEWS_MODE=changes_superseded|rc=0 status=reviewed changes_requested=0' \
  'an APPROVED review at head is a review||STUB_REVIEWS_MODE=approved_at_head|rc=0 status=reviewed' \
  'a review arriving on the second poll is picked up||STUB_REVIEWS_MODE=reviewed_later|rc=0 status=reviewed review_polls=2' \
  'a trusted check-run success at head opens the gate||STUB_REVIEWS_MODE=none,STUB_CHECKS_MODE=success_at_head,PR_REVIEW_CHECK=Review Bot|rc=0 status=reviewed review_evidence=check review_evidence_surface=check_run reviews_at_head=0 head_sha=headsha1' \
  'a check-run success on a stale sha is not evidence||STUB_REVIEWS_MODE=none,STUB_CHECKS_MODE=success_stale,PR_REVIEW_CHECK=Review Bot|rc=1 status=timeout' \
  'a failed check-run conclusion is not evidence||STUB_REVIEWS_MODE=none,STUB_CHECKS_MODE=failure_at_head,PR_REVIEW_CHECK=Review Bot|rc=1 status=timeout' \
  'check-run success with open threads returns comments||STUB_REVIEWS_MODE=none,STUB_CHECKS_MODE=success_at_head,PR_REVIEW_CHECK=Review Bot,STUB_THREADS_UNRESOLVED=2|rc=1 status=comments unresolved_count=2 early=true' \
  'check-run success beside a standing CHANGES_REQUESTED still blocks||STUB_REVIEWS_MODE=changes_standing,STUB_CHECKS_MODE=success_at_head,PR_REVIEW_CHECK=Review Bot|rc=1 status=changes_requested' \
  'a review object outranks the check surface with the feature on||STUB_REVIEWS_MODE=commented_at_head,STUB_CHECKS_MODE=none,PR_REVIEW_CHECK=Review Bot|rc=0 status=reviewed review_evidence=review review_evidence_surface=null reviews_at_head=1' \
  'a trusted commit-status success at head opens the gate when no check-run matches||STUB_REVIEWS_MODE=none,STUB_CHECKS_MODE=none,STUB_STATUS_MODE=success_at_head,PR_REVIEW_CHECK=Review Bot|rc=0 status=reviewed review_evidence=check review_evidence_surface=status reviews_at_head=0 head_sha=headsha1' \
  'a matching check-run wins and the status endpoint is never read||STUB_REVIEWS_MODE=none,STUB_CHECKS_MODE=success_at_head,STUB_STATUS_MODE=success_at_head,PR_REVIEW_CHECK=Review Bot|rc=0 review_evidence_surface=check_run status_queries=0' \
  'a pending status is not evidence||STUB_REVIEWS_MODE=none,STUB_CHECKS_MODE=none,STUB_STATUS_MODE=pending_at_head,PR_REVIEW_CHECK=Review Bot|rc=1 status=timeout' \
  'a failure status is not evidence||STUB_REVIEWS_MODE=none,STUB_CHECKS_MODE=none,STUB_STATUS_MODE=failure_at_head,PR_REVIEW_CHECK=Review Bot|rc=1 status=timeout' \
  'an error status is not evidence||STUB_REVIEWS_MODE=none,STUB_CHECKS_MODE=none,STUB_STATUS_MODE=error_at_head,PR_REVIEW_CHECK=Review Bot|rc=1 status=timeout' \
  'a status success on a stale sha is not evidence||STUB_REVIEWS_MODE=none,STUB_CHECKS_MODE=none,STUB_STATUS_MODE=success_stale,PR_REVIEW_CHECK=Review Bot|rc=1 status=timeout' \
  'an empty PR_REVIEW_CHECK reads neither surface||STUB_REVIEWS_MODE=none,STUB_CHECKS_MODE=success_at_head,STUB_STATUS_MODE=success_at_head|rc=1 status=timeout status_queries=0' \
  'a review object outranks a status success||STUB_REVIEWS_MODE=commented_at_head,STUB_CHECKS_MODE=none,STUB_STATUS_MODE=success_at_head,PR_REVIEW_CHECK=Review Bot|rc=0 review_evidence=review review_evidence_surface=null' \
  'status success with open threads returns comments||STUB_REVIEWS_MODE=none,STUB_CHECKS_MODE=none,STUB_STATUS_MODE=success_at_head,PR_REVIEW_CHECK=Review Bot,STUB_THREADS_UNRESOLVED=2|rc=1 status=comments early=true'

echo "=== PR_REVIEW_ON_TIMEOUT: a deadline degrades to proceeded only on reviewer silence over an unchanged head ==="
# Silence is no review, no trusted check or status of any state, and no open
# thread; the head is the one the wait started on, confirmed again at the
# decision. Everything else at the deadline stays a timeout or its verdict,
# and a proceed never manufactures review evidence: no commit status is
# posted and the JSON carries no marker field even with an outage context
# exported.
table "$REVIEW" \
  'no evidence and zero threads under proceed exits 0 as proceeded||STUB_REVIEWS_MODE=none,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 status=proceeded unresolved_count=0' \
  'the --on-timeout flag proceeds over the exported block|1 1 3 --json --mode review --on-timeout proceed|STUB_REVIEWS_MODE=none|rc=0 status=proceeded' \
  'the unset default proceeds||-u,PR_REVIEW_ON_TIMEOUT,STUB_REVIEWS_MODE=none|rc=0 status=proceeded' \
  'approval mode degrades the same way|1 1 3 --json|STUB_APPROVAL_MODE=none,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 status=proceeded' \
  'an unrecognized value falls back to block||STUB_REVIEWS_MODE=none,PR_REVIEW_ON_TIMEOUT=bogus|rc=1 status=timeout' \
  'open threads still return comments under proceed||STUB_REVIEWS_MODE=none,STUB_THREADS_UNRESOLVED=2,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=comments' \
  'a standing CHANGES_REQUESTED still blocks under proceed||STUB_REVIEWS_MODE=changes_standing,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=changes_requested' \
  'an active COMMENTED review in approval mode is engagement, not silence|1 1 3 --json|STUB_APPROVAL_MODE=commented_only,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout' \
  'a failed trusted check-run at head is engagement, not silence||STUB_REVIEWS_MODE=none,STUB_CHECKS_MODE=failure_at_head,PR_REVIEW_CHECK=Review Bot,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout' \
  'a pending trusted status at head is engagement, not silence||STUB_REVIEWS_MODE=none,STUB_STATUS_MODE=pending_at_head,PR_REVIEW_CHECK=Review Bot,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout' \
  'a head that moved during the wait falls back to timeout even when the confirm agrees with the new head|1 1 5 --json --mode review|STUB_REVIEWS_MODE=none,STUB_HEAD_MODE=changes,STUB_CONFIRM_HEAD=headsha2,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout' \
  'a head that moved in the last-poll to emit window falls back to timeout||STUB_REVIEWS_MODE=none,STUB_CONFIRM_HEAD=headsha2,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout' \
  'a proceed posts no commit status and emits no outage marker||STUB_REVIEWS_MODE=none,PR_REVIEW_ON_TIMEOUT=proceed,PR_REVIEW_OUTAGE_CONTEXT=kendex-reviewer-outage|rc=0 status=proceeded marker_posts=0 outage_marker=false'

echo "=== the automatic-review target set decides whether silence is a timeout or unreviewable ==="
# The automatic reviewer is armed by any active branch ruleset carrying a
# copilot_code_review rule; a base draws one when such a ruleset includes it
# and that same ruleset does not exclude it. A base outside that set can never
# draw one, so silence there is "unreviewable" (exit 1) under either on-timeout
# policy, never the fail-open "proceeded" — while the same silence on a covered
# base still proceeds. A reviewer that engaged is a timeout wherever the base
# sits, and a target set that could not be read or judged is a timeout too: only
# a listing denied as a permission, or one with no ruleset carrying the rule,
# lets the default branch stand in, and a glob pattern is never matched.
# The patterns and the listing answers are shaped input, one asserted row per
# shape.
table "$REVIEW" \
  'an untargeted base under proceed is unreviewable, not proceeded||STUB_REVIEWS_MODE=none,STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=unreviewable base_ref=stack-base auto_review_targeted=false auto_review_target_source=ruleset target_patterns=~DEFAULT_BRANCH' \
  'an untargeted base under block is unreviewable, not a timeout||STUB_REVIEWS_MODE=none,STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=block|rc=1 status=unreviewable' \
  'control: the same silence on the targeted base still proceeds||STUB_REVIEWS_MODE=none,STUB_BASE_REF=main,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 status=proceeded auto_review_targeted=true' \
  'a reviewer engaged on an untargeted base is a timeout, not unreviewable||STUB_REVIEWS_MODE=none,STUB_CHECKS_MODE=failure_at_head,PR_REVIEW_CHECK=Review Bot,STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout' \
  'approval mode reads the same base and reaches the same verdict|1 1 3 --json|STUB_APPROVAL_MODE=none,STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=unreviewable base_ref=stack-base' \
  'a ~ALL ruleset covers a stacked base||STUB_REVIEWS_MODE=none,STUB_RULESET_INCLUDE=~ALL,STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 status=proceeded auto_review_targeted=true target_patterns=~ALL' \
  'a ref pattern is matched as the full literal ref||STUB_REVIEWS_MODE=none,STUB_RULESET_INCLUDE=refs/heads/stack-base,STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 status=proceeded auto_review_targeted=true' \
  'an exclude pattern beats the include||STUB_REVIEWS_MODE=none,STUB_RULESET_INCLUDE=~ALL,STUB_RULESET_EXCLUDE=refs/heads/stack-base,STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=unreviewable auto_review_targeted=false' \
  'a base any one Copilot ruleset covers is targeted, over the union of includes||STUB_REVIEWS_MODE=none,STUB_RULESET2_INCLUDE=~DEFAULT_BRANCH,STUB_RULESET_INCLUDE=refs/heads/stack-base,STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 status=proceeded auto_review_targeted=true target_patterns=~DEFAULT_BRANCH,refs/heads/stack-base' \
  "an exclude narrows only its own ruleset, not another's include||STUB_REVIEWS_MODE=none,STUB_RULESET2_INCLUDE=~ALL,STUB_RULESET2_EXCLUDE=refs/heads/stack-base,STUB_RULESET_INCLUDE=refs/heads/stack-base,STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 status=proceeded auto_review_targeted=true" \
  'a Copilot ruleset on a later listing page is read||STUB_REVIEWS_MODE=none,STUB_RULESETS_MODE=paged,STUB_RULESET_INCLUDE=refs/heads/stack-base,STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 status=proceeded auto_review_target_source=ruleset' \
  'a glob pattern leaves the set unresolved, since GitHub does not match * across /||STUB_REVIEWS_MODE=none,STUB_RULESET_INCLUDE=refs/heads/release/*,STUB_BASE_REF=release/foo/bar,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout auto_review_target_source=unresolved' \
  'no ruleset carries the rule, so the default branch is the whole set||STUB_REVIEWS_MODE=none,STUB_RULESETS_MODE=none,STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=unreviewable auto_review_target_source=default_branch target_patterns=~DEFAULT_BRANCH' \
  'a listing denied with 403 falls back to the default branch||STUB_REVIEWS_MODE=none,STUB_RULESETS_MODE=denied,STUB_BASE_REF=main,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 status=proceeded auto_review_target_source=default_branch' \
  'a listing answered 404 falls back to the default branch||STUB_REVIEWS_MODE=none,STUB_RULESETS_MODE=not_found,STUB_BASE_REF=main,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 status=proceeded auto_review_target_source=default_branch' \
  'a rate-limited 403 listing is unresolved, not a denial||STUB_REVIEWS_MODE=none,STUB_RULESETS_MODE=rate_limited,STUB_BASE_REF=main,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout auto_review_target_source=unresolved' \
  'any other listing failure is unresolved, not the default branch||STUB_REVIEWS_MODE=none,STUB_RULESETS_MODE=fail,STUB_BASE_REF=main,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout auto_review_target_source=unresolved' \
  'a failed ruleset detail read is unresolved||STUB_REVIEWS_MODE=none,STUB_RULESET_DETAIL_MODE=fail,STUB_BASE_REF=main,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout auto_review_target_source=unresolved' \
  'a denied listing with no readable default branch is unresolved||STUB_REVIEWS_MODE=none,STUB_RULESETS_MODE=denied,STUB_DEFAULT_BRANCH_MODE=fail,STUB_BASE_REF=main,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout auto_review_target_source=unresolved target_patterns=' \
  'a ruleset naming ~DEFAULT_BRANCH with no readable default branch is unresolved||STUB_REVIEWS_MODE=none,STUB_DEFAULT_BRANCH_MODE=fail,STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout auto_review_target_source=unresolved'

echo "=== transient GitHub API failures are retried inside the budget and counted ==="
# A 5xx or 429 from the reviews listing, or from the approval-mode pr view, is
# absorbed with backoff and reported as transient_api_errors on the eventual
# result; one that never clears becomes terminal only when the budget is
# spent. A 404 is terminal at once and carries no count.
table "$REVIEW" \
  '503 twice then a review at head is reviewed with the count||STUB_REVIEWS_MODE=flaky_503|rc=0 status=reviewed transient_api_errors=2 review_polls=3' \
  '429 twice then a review at head is reviewed with the count||STUB_REVIEWS_MODE=flaky_429|rc=0 status=reviewed transient_api_errors=2' \
  'a persistent 503 is an error only once the budget is spent||STUB_REVIEWS_MODE=http_503|rc=1 status=error transient_errors_seen=true spent=true' \
  'a 404 is terminal at once with no transient count||STUB_REVIEWS_MODE=http_404|rc=1 status=error transient_api_errors=null early=true' \
  'approval-mode pr view 503s then an approval is approved with the count|1 1 3 --json|STUB_APPROVAL_MODE=approved_after_503|rc=0 status=approved transient_api_errors=2'

echo "=== text mode prints a result line for every branch the emitter has ==="
# The line's wording is not a contract anything parses; what holds is that no
# terminal status leaves stdout empty, with the same exit code as --json. The
# emitter branches per mode for every status and per evidence surface for
# reviewed, so each branch is a row.
TEXT_REVIEW='1 1 3 --mode review'
table '1 1 3' \
  'approval: approved||STUB_APPROVAL_MODE=approved_decision|rc=0 text_status=approved' \
  'approval: changes requested||STUB_APPROVAL_MODE=changes|rc=1 text_status=changes_requested' \
  'approval: comments||STUB_APPROVAL_MODE=none,STUB_THREADS_UNRESOLVED=2|rc=1 text_status=comments' \
  'approval: timeout||STUB_APPROVAL_MODE=none|rc=1 text_status=timeout' \
  'approval: error||GH_TOKEN=bad-token,STUB_GH_DENY_KEYRING=1|rc=3 text_status=error' \
  'approval: proceeded||STUB_APPROVAL_MODE=none,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 text_status=proceeded' \
  "review: reviewed via a review object|$TEXT_REVIEW|STUB_REVIEWS_MODE=commented_at_head|rc=0 text_status=reviewed" \
  "review: reviewed via a check-run|$TEXT_REVIEW|STUB_REVIEWS_MODE=none,STUB_CHECKS_MODE=success_at_head,PR_REVIEW_CHECK=Review Bot|rc=0 text_status=reviewed" \
  "review: reviewed via a commit status|$TEXT_REVIEW|STUB_REVIEWS_MODE=none,STUB_STATUS_MODE=success_at_head,PR_REVIEW_CHECK=Review Bot|rc=0 text_status=reviewed" \
  "review: changes requested|$TEXT_REVIEW|STUB_REVIEWS_MODE=changes_standing|rc=1 text_status=changes_requested" \
  "review: comments|$TEXT_REVIEW|STUB_REVIEWS_MODE=commented_at_head,STUB_THREADS_UNRESOLVED=2|rc=1 text_status=comments" \
  "review: timeout|$TEXT_REVIEW|STUB_REVIEWS_MODE=none|rc=1 text_status=timeout" \
  "review: error|$TEXT_REVIEW|GH_TOKEN=bad-token,STUB_GH_DENY_KEYRING=1|rc=3 text_status=error" \
  "review: proceeded|$TEXT_REVIEW|STUB_REVIEWS_MODE=none,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 text_status=proceeded" \
  "review: unreviewable|$TEXT_REVIEW|STUB_REVIEWS_MODE=none,STUB_BASE_REF=stack-base|rc=1 text_status=unreviewable"

echo "=== PR_REVIEW_WAIT_SECS: an absent max_wait positional resolves through orch-env ==="
# Process env beats kendex.settings.toml [env], and an explicit positional
# beats both. On the virtual clock a timeout lands on its deadline exactly, so
# each row pins the deadline it resolved, none of them the 900s built-in
# default. The settings file is this case's private fixture.
# Row: `label|settings value or empty|args|env|expect`.
waitsecs_rows=(
  'the env value drives the deadline||1 1 --json|STUB_APPROVAL_MODE=none,PR_REVIEW_WAIT_SECS=1|rc=1 status=timeout elapsed_seconds=1'
  'the settings-file value applies when the env is silent|1|1 1 --json|STUB_APPROVAL_MODE=none|rc=1 status=timeout elapsed_seconds=1'
  'the env value outlives the settings file|1|1 1 --json|STUB_APPROVAL_MODE=none,PR_REVIEW_WAIT_SECS=3|rc=1 status=timeout elapsed_seconds=3'
  'an explicit positional wins over the setting|600|1 1 3 --json|STUB_APPROVAL_MODE=none|rc=1 status=timeout elapsed_seconds=3'
)
for row in "${waitsecs_rows[@]}"; do
  IFS='|' read -r label setting args env expect <<<"$row"
  [[ -n "$expect" ]] || { printf 'waitsecs: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
  rm -f "$TMP_ROOT/repo/kendex.settings.toml"
  [[ -z "$setting" ]] || printf '[env]\nPR_REVIEW_WAIT_SECS = "%s"\n' "$setting" >"$TMP_ROOT/repo/kendex.settings.toml"
  # shellcheck disable=SC2086
  run_wait "$env" $args
  assert_eq "$(observe "$expect")" "$expect" "waitsecs: $label" "$RUN/stderr"
done
rm -f "$TMP_ROOT/repo/kendex.settings.toml"

echo "=== a failed emit_result never reports a successful gate ==="
# emit_result builds the --json object with `jq -n`, so this stub fails
# EXACTLY that call and passes every parse through to the real jq: the
# emission fails while the poll that reached the verdict succeeds — a closed
# pipe or a write failure. Each emit site must propagate jq's status 5 and
# write nothing: the two run_approved_gate sites, and the bare deadline
# `emit_result "timeout"` where nothing but errexit stands before `exit 1`,
# so a 1 there would mean a `set +e` had migrated above the emit.
REAL_JQ="$(command -v jq)"
cat > "$TMP_ROOT/bin/jq" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-n" ]; then
  echo "jq: emission failed (stub)" >&2
  exit 5
fi
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$TMP_ROOT/bin/jq"
table "$APPROVAL" \
  'emit failure at the reviewDecision gate site||STUB_APPROVAL_MODE=approved_decision|rc=5 stdout=empty' \
  'emit failure at the latestReviews gate site||STUB_APPROVAL_MODE=approved_latest|rc=5 stdout=empty' \
  'emit failure on the bare timeout path|1 1 2 --json|STUB_APPROVAL_MODE=none|rc=5 stdout=empty'
rm -f "$TMP_ROOT/bin/jq"
# Control: with the real jq back the same poll approves, so the rows above
# prove the emission failure and not a broken fixture.
table "$APPROVAL" \
  'control: the same poll approves once emission works||STUB_APPROVAL_MODE=approved_decision|rc=0 status=approved'

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
