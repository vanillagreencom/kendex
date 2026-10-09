#!/usr/bin/env bash
# Tests for orch/scripts/approval-wait, the reviewer-gate poller. It reads
# formal review verdicts (`gh pr view --json reviewDecision,latestReviews`)
# and the unresolved review-thread count, never emoji reactions, sticky
# comments or checklist prose; and it resolves its mode from the approval
# count GitHub's rulesets require on the PR's base branch and the PR's own
# reviewDecision.
#
# One case per behaviour surface; shaped input is one table per case, one
# asserted row per shape. A row's `expect` names the fields it pins; `observe`
# reads exactly those from the run, so a row fails on the field it names.
# The parser layer that answers before gh (--help, unknown flags, missing
# values) is approval_wait_cli.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo 'approval_wait: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "approval_wait: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'approval_wait: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"

mkdir -p "$TMP_ROOT/repo/.agents/skills" "$TMP_ROOT/bin" "$TMP_ROOT/runs"
ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/repo/.agents/skills/orch"
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/repo/.agents/skills/github"
ln -s "$REPO_ROOT/skills/review-gate" "$TMP_ROOT/repo/.agents/skills/review-gate"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config gc.auto 0
git -C "$TMP_ROOT/repo" config maintenance.auto false
git -C "$TMP_ROOT/repo" config user.email test@example.com
git -C "$TMP_ROOT/repo" config user.name Test

# Parametrized `gh` stub (same auth model as the ci_wait stub), a neutral fake
# GitHub: every payload is selected per run by the STUB_* variables below, so
# no case inherits another's world.
#   STUB_APPROVAL_MODE selects the canned `pr view --json
#   reviewDecision,latestReviews` payload; STUB_THREADS_UNRESOLVED sets the
#   unresolved count returned by the `api graphql` reviewThreads query.
#   STUB_APPROVAL_COUNT_FILE turns *_later and *_after_* modes into
#   poll-count-driven sequences (first polls pending or failing, a later one
#   terminal). STUB_HEAD_MODE=changes moves the payload's head from
#   "headsha1" to "headsha2" after two polls, counted in STUB_HEAD_COUNT_FILE.
#   The PR is opened by a GitHub App, as every fleet PR is, so the stub spells
#   its author the three ways GitHub does: `api repos/*/pulls/<n>` answers a
#   PR object whose .user.login is "pr-author[bot]" and whose
#   .head.user.login is a fork owner, filtered through the call's -q as gh
#   does (STUB_PR_AUTHOR_MODE=empty/http_404/flaky_503 answering an empty
#   login, failing the read, or failing it twice with a 503 counted in
#   STUB_AUTHOR_COUNT_FILE), `pr view --json author`
#   answers "app/pr-author", and the latestReviews rows spell the same
#   account "pr-author".
#   Mode resolution: `pr view --json baseRefName,reviewDecision` answers
#   STUB_BASE_REF and STUB_BASE_DECISION (default empty, as GitHub answers a
#   base that requires no review); STUB_BASE_MODE=fail fails it, empty
#   answers an empty base, and not_string a reviewDecision that is no string;
#   `api
#   repos/*/rules/branches/<base>` answers one pull_request rule requiring
#   STUB_REQUIRED_APPROVALS (default 1) beside a deletion rule, and appends
#   the URL it was asked for to STUB_RULES_LOG. STUB_RULES_MODE=none answers
#   no pull_request rule, fail a 500, zero_byte nothing at exit 0, object a
#   JSON object, not_number a count of "1", fraction a count of 0.5, and
#   paged a second page, read only under --paginate, carrying a second
#   pull_request rule that requires STUB_REQUIRED_APPROVALS_PAGE2.
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

# Fail the first two calls counted in COUNT_FILE with a 503, as a flaky
# service does, and return on every later call.
_stub_flaky_503() { # COUNT_FILE
  local count=0
  [[ -f "$1" ]] && count="$(cat "$1")"
  count=$((count + 1))
  printf '%s' "$count" > "$1"
  if [[ "$count" -le 2 ]]; then
    echo "HTTP 503: No server is currently available to service your request." >&2
    exit 1
  fi
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
    if [[ "${2:-}" == repos/*/commits/*/check-runs\?* ]]; then
      mode="${STUB_COPILOT_FLIGHT:-completed}"
      count=0
      [[ ! -f "$STUB_COPILOT_COUNT_FILE" ]] || count=$(cat "$STUB_COPILOT_COUNT_FILE")
      count=$((count + 1))
      printf '%s\n' "$count" > "$STUB_COPILOT_COUNT_FILE"
      [[ "$mode" != fail ]] || { echo 'HTTP 403: Forbidden' >&2; exit 1; }
      [[ "$mode" != timeline && "$mode" != cycle-* ]] || { echo '[{"check_runs":[]}]'; exit 0; }
      if [[ "$mode" == finishing ]]; then
        mode=in_progress
        [[ "$count" -eq 1 ]] || mode=completed
      fi
      printf '[{"check_runs":[{"id":72,"name":"copilot-pull-request-reviewer","status":"%s","started_at":"2026-10-09T06:41:20Z"}]}]\n' "$mode"
      exit 0
    fi
    if [[ "${2:-}" == repos/*/issues/*/timeline\?* ]]; then
      if [[ "${STUB_COPILOT_FLIGHT:-completed}" == cycle-* ]]; then
        jq -nc --arg head "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" --arg current "${STUB_CONFIRM_HEAD:-headsha1}" --arg old "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" --arg mode "$STUB_COPILOT_FLIGHT" --argjson count "$(cat "$STUB_COPILOT_COUNT_FILE")" '
        def req($id;$at): {event:"review_requested",id:$id,commit_id:null,created_at:$at,requested_reviewer:{login:"Copilot",type:"Bot"}};
        def work($id;$at): {event:"copilot_work_started",id:$id,commit_id:null,commit_url:null,created_at:$at,actor:{login:"bmethod",type:"User"},performed_via_github_app:{slug:"copilot-pull-request-reviewer"}};
        def rev($id;$head;$at): {event:"reviewed",id:$id,commit_id:$head,user:{login:"Copilot",type:"Bot"},state:"commented",submitted_at:$at};
        (if ($mode | startswith("cycle-cancel")) then "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" else $head end) as $b |
        [[{event:"committed",sha:$b,committer:{date:"2026-10-09T05:00:00Z"}},
          {event:"committed",sha:$current,committer:{date:"2026-10-09T05:00:01Z"}},
          {event:"head_ref_force_pushed",commit_id:$old,created_at:"2026-10-09T06:00:00Z"},req(73;"2026-10-09T06:10:00Z")],
         (if ($mode | startswith("cycle-cancel")) then [{event:"review_request_removed",created_at:"2026-10-09T06:11:00Z",requested_reviewer:{login:"Copilot",type:"Bot"}}]
          else [work(75;"2026-10-09T06:10:35Z"),rev(81;$old;"2026-10-09T06:20:00Z")] end),
         (if $mode == "cycle-cancel-boundary" then [{event:"head_ref_force_pushed",commit_id:$b,created_at:"2026-10-09T06:30:00Z"}] else [] end),
         (if ($mode | startswith("cycle-rereview")) then [req(76;"2026-10-09T06:25:00Z"),work(77;"2026-10-09T06:25:35Z"),rev(82;$old;"2026-10-09T06:26:00Z")] else [] end),
         (if ($mode | startswith("cycle-cancel")) then [req(74;"2026-10-09T06:41:20Z"),work(78;"2026-10-09T06:41:55Z"),rev(83;$b;"2026-10-09T06:42:05Z")] else [] end),
         (if ($mode | contains("newer")) then [req(79;"2026-10-09T06:43:00Z"),work(80;"2026-10-09T06:43:35Z")] else [] end),
         (if $count > 1 then [rev(84;$current;"2026-10-09T06:45:00Z")] else [] end)]'
      elif [[ "${STUB_COPILOT_FLIGHT:-completed}" == timeline ]]; then
        jq -nc --argjson count "$(cat "$STUB_COPILOT_COUNT_FILE")" '
          [[{event:"review_requested",id:73,created_at:"2026-10-09T06:41:20Z",requested_reviewer:{login:"Copilot"}}],
           if $count > 1 then [{event:"reviewed",id:81,commit_id:"headsha1",user:{login:"Copilot"},submitted_at:"2026-10-09T06:42:05Z"}] else [] end]'
      else echo '[[]]'; fi
      exit 0
    fi
    if [[ "${2:-}" == repos/*/pulls/*/reviews ]]; then
      case "${STUB_REVIEW_READ:-ok}" in
        fail) echo 'HTTP 404: Not Found' >&2; exit 1 ;;
        empty) exit 0 ;;
        invalid) echo '{}'; exit 0 ;;
      esac
      id="${STUB_ERROR_ID:-1}"
      poll="$(cat "$STUB_APPROVAL_COUNT_FILE")"
      if [[ "${STUB_DUPLICATE_ERRORS:-0}" == 1 ]]; then id=2; fi
      if [[ "${STUB_APPROVAL_MODE:-}" == copilot_error_twice && "$poll" -ge 3 ]]; then id=$((id + 1)); fi
      head="${STUB_ERROR_HEAD:-headsha1}"
      body='Copilot encountered an error and was unable to review this pull request. You can try again by re-requesting a review.'
      login='copilot-pull-request-reviewer[bot]'
      [[ "${STUB_APPROVAL_MODE:-}" != human_error ]] || login=colleague
      [[ "${STUB_APPROVAL_MODE:-}" != copilot_comment ]] || body='Review completed with findings.'
      [[ "${STUB_REST_REVIEWER:-}" != human ]] || login=colleague
      rows="$(jq -nc --arg head "$head" --arg body "$body" --argjson id "$id" --arg login "$login" \
        '[{id:$id,user:{login:$login},commit_id:$head,state:"COMMENTED",body:$body}]')"
      if [[ "${STUB_DUPLICATE_ERRORS:-0}" == 1 ]]; then
        rows="$(jq -c '[.[0] + {id:1}] + .' <<<"$rows")"
      fi
      if [[ "${STUB_REVIEW_PAGES:-0}" == 1 ]]; then
        echo '[]'
        [[ " $* " == *' --paginate '* ]] || exit 0
      fi
      echo "$rows"
      exit 0
    fi
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
    # The rules GitHub applies to one branch, organization rulesets included:
    # a list of rule objects, as GitHub answers it.
    if [[ "${2:-}" == repos/*/rules/branches/* ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      [[ -n "${STUB_RULES_LOG:-}" ]] && printf '%s\n' "$2" >> "$STUB_RULES_LOG"
      pr_rule='{"type":"pull_request","parameters":{"required_approving_review_count":%s,"required_review_thread_resolution":true}}'
      case "${STUB_RULES_MODE:-ok}" in
        fail) echo "HTTP 500: Internal Server Error" >&2; exit 1 ;;
        zero_byte) ;;
        object) echo '{"message":"not a list"}' ;;
        none) echo '[{"type":"deletion"},{"type":"non_fast_forward"}]' ;;
        not_number) printf '[%s]\n' "$(printf "$pr_rule" '"1"')" ;;
        fraction) printf '[%s]\n' "$(printf "$pr_rule" '0.5')" ;;
        paged)
          printf '[{"type":"deletion"},%s]\n' "$(printf "$pr_rule" "${STUB_REQUIRED_APPROVALS:-0}")"
          if [[ " $* " == *" --paginate "* ]]; then
            printf '[%s]\n' "$(printf "$pr_rule" "${STUB_REQUIRED_APPROVALS_PAGE2:?}")"
          fi
          ;;
        *) printf '[{"type":"deletion"},%s]\n' "$(printf "$pr_rule" "${STUB_REQUIRED_APPROVALS:-1}")" ;;
      esac
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
    # The PR object, read for the author login under the same spelling the
    # reviews listing above carries. The head carries a different login, so
    # a filter reading the wrong field answers the fork owner, not the author.
    if [[ "${2:-}" == repos/*/pulls/* ]]; then
      _stub_auth_ok || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      filter="."
      for ((i = 3; i <= $#; i++)); do
        if [[ "${!i}" == "-q" ]]; then
          next=$((i + 1))
          filter="${!next}"
        fi
      done
      login="pr-author[bot]"
      case "${STUB_PR_AUTHOR_MODE:-ok}" in
        empty) login="" ;;
        http_404) echo "HTTP 404: Not Found (https://api.github.com/repos/owner/repo/pulls/1)" >&2; exit 1 ;;
        flaky_503) _stub_flaky_503 "${STUB_AUTHOR_COUNT_FILE:?}" ;;
      esac
      jq -nc --arg login "$login" '{user: {login: $login}, head: {user: {login: "fork-owner"}}}' \
        | jq -r "$filter"
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
    if [[ "${2:-}" == edit ]]; then
      printf '%s\n' "$*" >> "$STUB_REQUEST_LOG"
      exit "${STUB_REQUEST_EXIT:-0}"
    fi
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
      # Mode resolution's read: `--json baseRefName,reviewDecision`.
      if [[ "$*" == *"--json baseRefName,reviewDecision"* ]]; then
        case "${STUB_BASE_MODE:-ok}" in
          fail) echo "HTTP 404: Not Found (https://api.github.com/repos/owner/repo/pulls/1)" >&2; exit 1 ;;
          empty) echo '{"baseRefName":"","reviewDecision":""}' ;;
          not_string) jq -nc --arg base "${STUB_BASE_REF:-main}" '{baseRefName: $base, reviewDecision: 1}' ;;
          *) jq -nc --arg base "${STUB_BASE_REF:-main}" --arg decision "${STUB_BASE_DECISION:-}" \
               '{baseRefName: $base, reviewDecision: $decision}' ;;
        esac
        exit 0
      fi
      if [[ "$*" == *reviewDecision* ]]; then
        mode="${STUB_APPROVAL_MODE:-none}"
        if [[ "$mode" == "approved_after_503" || "$mode" == "approved_after_429" ]]; then
          count="$(_bump_count)"
          if [[ "$count" -le 2 ]]; then
            if [[ "$mode" == "approved_after_429" ]]; then
              echo "HTTP 429: You have exceeded a secondary rate limit. Please wait a few minutes before you try again." >&2
            else
              echo "HTTP 503: No server is currently available to service your request." >&2
            fi
            exit 1
          fi
          mode="approved_decision"
        fi
        if [[ "$mode" == copilot_error* || "$mode" == human_error || "$mode" == copilot_comment ]]; then
          count="$(_bump_count)"
          if [[ "$mode" == copilot_error_approved && "$count" -ge 3 ]]; then mode=approved_decision; fi
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
          http_503) echo "HTTP 503: No server is currently available to service your request." >&2; exit 1 ;;
          http_404) echo "HTTP 404: Not Found (https://api.github.com/repos/owner/repo/pulls/1)" >&2; exit 1 ;;
        esac
        head="headsha1"
        [[ "${STUB_COPILOT_FLIGHT:-}" != cycle-* ]] || head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        [[ "${STUB_COPILOT_FLIGHT:-}" != cycle-cancel-* ]] || head=cccccccccccccccccccccccccccccccccccccccc
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
        decision=""
        case "$mode" in
          approved_decision)
            decision="APPROVED"
            reviews='[{"author":{"login":"reviewer1"},"state":"APPROVED"}]'
            ;;
          approved_latest)
            reviews='[{"author":{"login":"reviewer1"},"state":"APPROVED"},{"author":{"login":"colleague"},"state":"COMMENTED"}]'
            ;;
          changes)
            reviews='[{"author":{"login":"reviewer1"},"state":"CHANGES_REQUESTED"},{"author":{"login":"colleague"},"state":"APPROVED"}]'
            ;;
          approved_with_changes)
            # A request GitHub does not count, from a reviewer without write
            # access, beside a decision that approves.
            decision="APPROVED"
            reviews='[{"author":{"login":"reviewer1"},"state":"CHANGES_REQUESTED"},{"author":{"login":"colleague"},"state":"APPROVED"}]'
            ;;
          copilot_error*|human_error|copilot_comment)
            decision="REVIEW_REQUIRED"
            login=copilot-pull-request-reviewer
            body='Copilot encountered an error and was unable to review this pull request. You can try again by re-requesting a review.'
            [[ "$mode" != human_error ]] || login=colleague
            [[ "$mode" != copilot_comment ]] || body='Review completed with findings.'
            reviews="$(jq -nc --arg login "$login" --arg body "$body" '[{author:{login:$login},state:"COMMENTED",body:$body}]')"
            ;;
          commented_only)
            reviews='[{"author":{"login":"reviewer1"},"state":"COMMENTED"}]'
            ;;
          author_commented)
            reviews='[{"author":{"login":"pr-author"},"state":"COMMENTED"}]'
            ;;
          required_pending)
            decision="REVIEW_REQUIRED"
            reviews='[{"author":{"login":"colleague"},"state":"APPROVED"}]'
            ;;
          none|*)
            reviews='[]'
            ;;
        esac
        jq -nc --arg decision "$decision" --arg head "$head" --arg base "${STUB_BASE_REF:-main}" --argjson reviews "$reviews" \
          '{reviewDecision: $decision, headRefOid: $head, baseRefName: $base,
            author: {login: "app/pr-author"}, latestReviews: $reviews}'
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
# how production invokes it, with the stub PATH, in the project at $WAIT_REPO:
# the fixture repo unless a control points it at a mutant. ENV is a
# comma-separated list of `env` arguments (assignments or `-u NAME`), so a
# value may carry a space. Every run gets its own count, log and stderr files
# under $RUN, so no row reads another's polls or posts. The caller's GitHub
# tokens are cleared, so auth resolves to the stub's keyring unless a row
# names a token. Sets OUT and RC.
RUN=""
WAIT_REPO="$TMP_ROOT/repo"
run_wait() {
  local env_list="$1" env_args=()
  shift
  RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"
  RUN_ITEM=""
  local arg prev=""
  for arg in "$@"; do
    [[ "$prev" != --item ]] || RUN_ITEM="$arg"
    prev="$arg"
  done
  mkdir -p "$RUN"
  if [[ -n "$RUN_ITEM" && ! -f "$WAIT_REPO/tmp/workflow-state-$RUN_ITEM.json" ]]; then
    mkdir -p "$WAIT_REPO/tmp"
    printf '{}\n' > "$WAIT_REPO/tmp/workflow-state-$RUN_ITEM.json"
  fi
  local base_args=()
  if [[ " $* " == *' --mode '* && "$env_list" != *STUB_NO_BASE_CHECKOUT=1* ]]; then
    base_args=(--base-checkout "$WAIT_REPO")
  fi
  [[ -z "$env_list" ]] || IFS=',' read -ra env_args <<<"$env_list"
  set +e
  OUT=$(cd "$WAIT_REPO" && PATH="$TMP_ROOT/bin:$PATH" \
    env -u GH_REPO -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u ORCH_STATE_DIR ${env_args[@]+"${env_args[@]}"} \
        STUB_APPROVAL_COUNT_FILE="$RUN/approval-polls" \
        STUB_HEAD_COUNT_FILE="$RUN/head-polls" \
        STUB_AUTHOR_COUNT_FILE="$RUN/author-reads" \
        STUB_RULES_LOG="$RUN/rules-reads" \
        STUB_MARKER_LOG="$RUN/marker-posts" \
        STUB_REQUEST_LOG="$RUN/requests" \
        STUB_COPILOT_COUNT_FILE="$RUN/copilot-polls" \
        .agents/skills/orch/scripts/approval-wait "$@" ${base_args[@]+"${base_args[@]}"} 2>"$RUN/stderr")
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
#   mode      stdout whole, the --resolve-mode answer
#   approval_polls                  how often the stub answered the pr view
#   rules_reads                     rules/branches reads the stub served
#   rules_url                       the last rules/branches path asked for
#   marker_posts                    commit-status POSTs the stub received
#   outage_marker                   whether the JSON carries that field
#   target_patterns   auto_review_targets joined, so a row compares as one word
#   transient_errors_seen           transient_api_errors >= 1
#   text_status / text_repo  those fields on the plain result's first line
#   error_line  first line of the JSON error, spaces encoded as +
#   stderr_line the first line of stderr, spaces encoded as +
#   mail        the count on an `approval-wait: mail=` stdout line
#   fallback_notices  each copilot-fallback notice in the mailbox of the
#               run's --item, in send order, as HEAD:CAUSE:LANE_STATUS: the
#               head and cause= fields of its first line and the path its
#               `Lane status:` second line names, the three the overseer
#               routes on; `none` when none went out
#   unsent      copilot-fallback-unsent lines on stderr
observe() {
  local got="" token name
  for token in $1; do
    name="${token%%=*}"
    case "$name" in
      rc) got="$got rc=$RC" ;;
      early) got="$got early=$(json '.elapsed_seconds < 3')" ;;
      spent) got="$got spent=$(json '.elapsed_seconds >= 3')" ;;
      stdout) got="$got stdout=$([[ -n "$OUT" ]] && echo line || echo empty)" ;;
      mode) got="$got mode=${OUT// /+}" ;;
      text_status) got="$got text_status=$(sed -n '1s/^approval-wait: result status=\([^ ]*\).*$/\1/p' <<<"$OUT")" ;;
      text_repo) got="$got text_repo=$(sed -n '1s/^approval-wait: result .* repo=\([^ ]*\).*$/\1/p' <<<"$OUT")" ;;
      error_line) got="$got error_line=$(json '.error | split("\n")[0]' | tr ' ' '+')" ;;
      mail) got="$got mail=$(sed -n '1s/^approval-wait: mail=\([0-9]*\)$/\1/p' <<<"$OUT")" ;;
      stderr_line) got="$got stderr_line=$(sed -n '1p' "$RUN/stderr" | tr ' ' '+')" ;;
      fallback_notices) got="$got fallback_notices=$(fallback_notices)" ;;
      unsent) got="$got unsent=$(grep -c '^approval-wait: copilot-fallback-unsent ' "$RUN/stderr" || true)" ;;
      requests) got="$got requests=$(count_lines "$RUN/requests")" ;;
      request_argv) got="$got request_argv=$(tr ' ' '+' < "$RUN/requests")" ;;
      approval_polls) got="$got approval_polls=$(cat "$RUN/approval-polls" 2>/dev/null || echo 0)" ;;
      copilot_polls) got="$got copilot_polls=$(cat "$RUN/copilot-polls" 2>/dev/null || echo 0)" ;;
      rules_reads) got="$got rules_reads=$(count_lines "$RUN/rules-reads")" ;;
      rules_url) got="$got rules_url=$(sed -n '$p' "$RUN/rules-reads" 2>/dev/null)" ;;
      marker_posts) got="$got marker_posts=$(count_lines "$RUN/marker-posts")" ;;
      outage_marker) got="$got outage_marker=$(json 'has("outage_marker")')" ;;
      transient_errors_seen) got="$got transient_errors_seen=$(json '.transient_api_errors >= 1')" ;;
      target_patterns) got="$got target_patterns=$(json '.auto_review_targets | join(",")')" ;;
      *) got="$got $name=$(json ".$name" | tr ' ' '+')" ;;
    esac
  done
  printf '%s' "${got# }"
}
json() { jq -r "$1" <<<"$OUT" 2>/dev/null || echo UNPARSEABLE; }
fallback_notices() {
  local file="$WAIT_REPO/tmp/lane-mail/$RUN_ITEM/to-overseer.jsonl" notices
  [[ -f "$file" ]] || { printf 'none'; return 0; }
  # capture yields nothing on a line it does not match, so a notice that
  # went out malformed would read as none: make that an error instead.
  notices="$(jq -r '.text | split("\n")
    | (.[0] | capture("^copilot-fallback PR #[0-9]+ head (?<head>[^ ]+) cause=(?<cause>[^ ]+)$") // error("first line")) as $first
    | (.[1] | capture("^Lane status: (?<path>[^ ]+)$") // error("second line")) as $second
    | "\($first.head):\($first.cause):\($second.path)"' "$file" 2>/dev/null)" || notices=UNPARSEABLE
  notices="$(paste -sd, - <<<"$notices")"
  printf '%s' "${notices:-none}"
}

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

# Every row outside the two resolution cases passes --mode approval, so the
# wait reads no rules and a row's answer is its own verdict alone.
APPROVAL='1 1 3 --json --mode approval'
RESOLVE='1 --resolve-mode --base-checkout .'

echo "=== --resolve-mode: the base's rulesets and the PR's reviewDecision decide ==="
# At least one approval the base's rulesets require is approval, and the
# largest count over every page wins. The rules read does not show classic
# branch protection, so a non-empty reviewDecision, which GitHub sets only
# where the base requires a review, is approval too. Off needs both: no
# required approval in the rules and an empty reviewDecision. A read that
# fails, answers nothing, answers a non-list or a count that is not a number
# is no mode: exit 2, a diagnostic naming the branch, and nothing on stdout,
# never an off that would skip the wait. The base is read from the PR, and a
# branch holding a slash is sent URL-encoded.
table "$RESOLVE" \
  'rules requiring 1 approval resolve approval||STUB_REQUIRED_APPROVALS=1|rc=0 mode=approval rules_reads=1' \
  'rules requiring 2 approvals resolve approval||STUB_REQUIRED_APPROVALS=2|rc=0 mode=approval' \
  'rules requiring 0 approvals resolve off||STUB_REQUIRED_APPROVALS=0|rc=0 mode=off' \
  'a base with no pull_request rule resolves off||STUB_RULES_MODE=none|rc=0 mode=off' \
  'rules requiring 0 beside a REVIEW_REQUIRED decision resolve approval, as classic protection reads||STUB_REQUIRED_APPROVALS=0,STUB_BASE_DECISION=REVIEW_REQUIRED|rc=0 mode=approval' \
  'no pull_request rule beside an APPROVED decision resolves approval||STUB_RULES_MODE=none,STUB_BASE_DECISION=APPROVED|rc=0 mode=approval' \
  'a count on a later page is read, and the largest wins||STUB_RULES_MODE=paged,STUB_REQUIRED_APPROVALS=0,STUB_REQUIRED_APPROVALS_PAGE2=1|rc=0 mode=approval' \
  'the base is the one the PR names, URL-encoded||STUB_BASE_REF=release/1.x|rc=0 mode=approval rules_url=repos/owner/repo/rules/branches/release%2F1.x' \
  'a failed rules read is no mode||STUB_RULES_MODE=fail|rc=2 stdout=empty stderr_line=approval-wait:+rules-unreadable+branch=main+repo=owner/repo' \
  'a zero-byte rules answer is a failed read||STUB_RULES_MODE=zero_byte|rc=2 stdout=empty stderr_line=approval-wait:+rules-unreadable+branch=main+repo=owner/repo' \
  'a rules answer that is not a list is a failed read||STUB_RULES_MODE=object|rc=2 stdout=empty' \
  'a count that is not a number is a failed read||STUB_RULES_MODE=not_number|rc=2 stdout=empty' \
  'a count that is not a whole number is a failed read||STUB_RULES_MODE=fraction|rc=2 stdout=empty' \
  'a failed base read is no mode, and no rules are read||STUB_BASE_MODE=fail|rc=2 stdout=empty rules_reads=0 stderr_line=approval-wait:+base-unreadable+pr=1+repo=owner/repo' \
  'an empty base is a failed read||STUB_BASE_MODE=empty|rc=2 stdout=empty rules_reads=0' \
  'a reviewDecision that is no string is a failed read||STUB_BASE_MODE=not_string|rc=2 stdout=empty rules_reads=0 stderr_line=approval-wait:+base-unreadable+pr=1+repo=owner/repo' \
  'an auth failure is no mode and prints nothing on stdout||GH_TOKEN=bad-token,STUB_GH_DENY_KEYRING=1|rc=3 stdout=empty'

echo "=== waits require a resolved mode ==="
table '1 1 3 --json' \
  'a wait without --mode is refused||STUB_APPROVAL_MODE=approved_decision|rc=2 stdout=empty stderr_line=approval-wait:+missing-mode+option=--mode rules_reads=0 approval_polls=0' \
  '--mode approval reads no rules|1 1 3 --json --mode approval|STUB_RULES_MODE=fail,STUB_APPROVAL_MODE=approved_decision|rc=0 status=approved rules_reads=0'

echo "=== approval mode: the verdict rule over the pr view payload and the thread count ==="
# A reviewDecision decides; with none, the latest review per reviewer does,
# and REVIEW_REQUIRED means the rule still wants more. COMMENTED is never a
# verdict. An open thread holds every head at comments, approved or not,
# since orch's own merge gates refuse an open thread; a standing
# CHANGES_REQUESTED without an approval outranks it, and one an APPROVED
# decision overrides does not. A later poll picks up a verdict the first
# missed.
table "$APPROVAL" \
  'reviewDecision APPROVED approves||STUB_APPROVAL_MODE=approved_decision|rc=0 status=approved review_decision=APPROVED approvals=1' \
  'no reviewDecision, a latest APPROVED approves via latestReviews||STUB_APPROVAL_MODE=approved_latest|rc=0 status=approved review_decision= approvals=1' \
  'a latest CHANGES_REQUESTED blocks beside another approval||STUB_APPROVAL_MODE=changes|rc=1 status=changes_requested changes_requested=1' \
  'a CHANGES_REQUESTED outranks open threads||STUB_APPROVAL_MODE=changes,STUB_THREADS_UNRESOLVED=2|rc=1 status=changes_requested' \
  'a CHANGES_REQUESTED the APPROVED decision overrides leaves open threads at comments||STUB_APPROVAL_MODE=approved_with_changes,STUB_THREADS_UNRESOLVED=1|rc=1 status=comments review_decision=APPROVED changes_requested=1' \
  'COMMENTED-only latest reviews are no verdict||STUB_APPROVAL_MODE=commented_only|rc=1 status=timeout approvals=0' \
  'open threads with no verdict return comments before the deadline||STUB_APPROVAL_MODE=none,STUB_THREADS_UNRESOLVED=2|rc=1 status=comments unresolved_count=2 early=true' \
  'nothing at the deadline is a timeout||STUB_APPROVAL_MODE=none|rc=1 status=timeout' \
  'REVIEW_REQUIRED keeps a latest APPROVED from approving||STUB_APPROVAL_MODE=required_pending|rc=1 status=timeout review_decision=REVIEW_REQUIRED' \
  'an APPROVED decision with an open thread returns comments||STUB_APPROVAL_MODE=approved_decision,STUB_THREADS_UNRESOLVED=1|rc=1 status=comments review_decision=APPROVED unresolved_count=1 early=true' \
  'a latestReviews approval with an open thread returns comments||STUB_APPROVAL_MODE=approved_latest,STUB_THREADS_UNRESOLVED=1|rc=1 status=comments approvals=1 unresolved_count=1' \
  'a verdict arriving on the second poll approves||STUB_APPROVAL_MODE=approved_later|rc=0 status=approved approval_polls=2' \
  'an auth failure is a parseable error object||GH_TOKEN=bad-token,STUB_GH_DENY_KEYRING=1|rc=3 status=error'

echo "=== the PR author read that fails decides nothing ==="
# Comparing every review row against an empty login would exclude nobody, so a
# failed or empty author read ends the wait instead. The filter compares the
# GraphQL actor spelling the latestReviews rows carry, so the author's own
# COMMENTED review is not the reviewer engagement that suppresses the proceed
# degrade (the reviewer1 row in the table below is that inverse).
table "$APPROVAL" \
  'a failed author read ends the wait||STUB_PR_AUTHOR_MODE=http_404,STUB_APPROVAL_MODE=approved_decision|rc=1 status=error early=true error_line=approval-wait:+author-failed+pr=1+repo=owner/repo' \
  'an empty author login is a failed read, not an authorless PR||STUB_PR_AUTHOR_MODE=empty,STUB_APPROVAL_MODE=approved_decision|rc=1 status=error error_line=approval-wait:+author-failed+pr=1+repo=owner/repo' \
  "the author's own COMMENTED review is excluded||STUB_APPROVAL_MODE=author_commented,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 status=proceeded"

echo "=== PR_REVIEW_ON_TIMEOUT: a deadline degrades to proceeded only on reviewer silence over an unchanged head ==="
# Silence is no non-author review of any state and no open thread; the head is
# the one the wait started on, confirmed again at the decision. Everything
# else at the deadline stays a timeout or its verdict, and a proceed never
# manufactures review evidence: no commit status is posted and the JSON
# carries no marker field even with an outage context exported.
table "$APPROVAL" \
  'no review and zero threads under proceed exits 0 as proceeded||STUB_APPROVAL_MODE=none,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 status=proceeded unresolved_count=0' \
  'the --on-timeout flag proceeds over the exported block|1 1 3 --json --mode approval --on-timeout proceed|STUB_APPROVAL_MODE=none|rc=0 status=proceeded' \
  'the unset default proceeds||-u,PR_REVIEW_ON_TIMEOUT,STUB_APPROVAL_MODE=none|rc=0 status=proceeded' \
  'an unrecognized value falls back to block||STUB_APPROVAL_MODE=none,PR_REVIEW_ON_TIMEOUT=bogus|rc=1 status=timeout' \
  'open threads still return comments under proceed||STUB_APPROVAL_MODE=none,STUB_THREADS_UNRESOLVED=2,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=comments' \
  'a standing CHANGES_REQUESTED still blocks under proceed||STUB_APPROVAL_MODE=changes,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=changes_requested' \
  'an active COMMENTED review is engagement, not silence||STUB_APPROVAL_MODE=commented_only,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout' \
  'a head that moved during the wait falls back to timeout even when the confirm agrees with the new head|1 1 5 --json --mode approval|STUB_APPROVAL_MODE=none,STUB_HEAD_MODE=changes,STUB_CONFIRM_HEAD=headsha2,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout' \
  'a head that moved in the last-poll to emit window falls back to timeout||STUB_APPROVAL_MODE=none,STUB_CONFIRM_HEAD=headsha2,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout' \
  'a proceed posts no commit status and emits no outage marker||STUB_APPROVAL_MODE=none,PR_REVIEW_ON_TIMEOUT=proceed,PR_REVIEW_OUTAGE_CONTEXT=kendex-reviewer-outage|rc=0 status=proceeded marker_posts=0 outage_marker=false'

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
table "$APPROVAL" \
  'an untargeted base under proceed is unreviewable, not proceeded||STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=unreviewable base_ref=stack-base auto_review_targeted=false auto_review_target_source=ruleset target_patterns=~DEFAULT_BRANCH' \
  'an untargeted base under block is unreviewable, not a timeout||STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=block|rc=1 status=unreviewable' \
  'control: the same silence on the targeted base still proceeds||STUB_BASE_REF=main,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 status=proceeded auto_review_targeted=true' \
  'a reviewer engaged on an untargeted base is a timeout, not unreviewable||STUB_APPROVAL_MODE=commented_only,STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout' \
  'a ~ALL ruleset covers a stacked base||STUB_RULESET_INCLUDE=~ALL,STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 status=proceeded auto_review_targeted=true target_patterns=~ALL' \
  'a ref pattern is matched as the full literal ref||STUB_RULESET_INCLUDE=refs/heads/stack-base,STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 status=proceeded auto_review_targeted=true' \
  'an exclude pattern beats the include||STUB_RULESET_INCLUDE=~ALL,STUB_RULESET_EXCLUDE=refs/heads/stack-base,STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=unreviewable auto_review_targeted=false' \
  'a base any one Copilot ruleset covers is targeted, over the union of includes||STUB_RULESET2_INCLUDE=~DEFAULT_BRANCH,STUB_RULESET_INCLUDE=refs/heads/stack-base,STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 status=proceeded auto_review_targeted=true target_patterns=~DEFAULT_BRANCH,refs/heads/stack-base' \
  "an exclude narrows only its own ruleset, not another's include||STUB_RULESET2_INCLUDE=~ALL,STUB_RULESET2_EXCLUDE=refs/heads/stack-base,STUB_RULESET_INCLUDE=refs/heads/stack-base,STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 status=proceeded auto_review_targeted=true" \
  'a Copilot ruleset on a later listing page is read||STUB_RULESETS_MODE=paged,STUB_RULESET_INCLUDE=refs/heads/stack-base,STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 status=proceeded auto_review_target_source=ruleset' \
  'a glob pattern leaves the set unresolved, since GitHub does not match * across /||STUB_RULESET_INCLUDE=refs/heads/release/*,STUB_BASE_REF=release/foo/bar,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout auto_review_target_source=unresolved' \
  'no ruleset carries the rule, so the default branch is the whole set||STUB_RULESETS_MODE=none,STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=unreviewable auto_review_target_source=default_branch target_patterns=~DEFAULT_BRANCH' \
  'a listing denied with 403 falls back to the default branch||STUB_RULESETS_MODE=denied,STUB_BASE_REF=main,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 status=proceeded auto_review_target_source=default_branch' \
  'a listing answered 404 falls back to the default branch||STUB_RULESETS_MODE=not_found,STUB_BASE_REF=main,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 status=proceeded auto_review_target_source=default_branch' \
  'a rate-limited 403 listing is unresolved, not a denial||STUB_RULESETS_MODE=rate_limited,STUB_BASE_REF=main,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout auto_review_target_source=unresolved' \
  'any other listing failure is unresolved, not the default branch||STUB_RULESETS_MODE=fail,STUB_BASE_REF=main,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout auto_review_target_source=unresolved' \
  'a failed ruleset detail read is unresolved||STUB_RULESET_DETAIL_MODE=fail,STUB_BASE_REF=main,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout auto_review_target_source=unresolved' \
  'a denied listing with no readable default branch is unresolved||STUB_RULESETS_MODE=denied,STUB_DEFAULT_BRANCH_MODE=fail,STUB_BASE_REF=main,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout auto_review_target_source=unresolved target_patterns=' \
  'a ruleset naming ~DEFAULT_BRANCH with no readable default branch is unresolved||STUB_DEFAULT_BRANCH_MODE=fail,STUB_BASE_REF=stack-base,PR_REVIEW_ON_TIMEOUT=proceed|rc=1 status=timeout auto_review_target_source=unresolved'

echo "=== Copilot error answers retry once through the request owner ==="
# KEN-3421 produced duplicate error reviews for one request. The first snapshot
# consumes one retry; unchanged IDs are not new answers. A later ID is terminal.
table "$APPROVAL" \
  'the error retries once and an approval ends the continued wait||STUB_APPROVAL_MODE=copilot_error_approved|rc=0 status=approved requests=1 approval_polls=3 request_argv=pr+edit+1+--repo+owner/repo+--add-reviewer+@copilot' \
  'a new error after unchanged polls ends early||STUB_APPROVAL_MODE=copilot_error_twice|rc=1 status=copilot-error requests=1 approval_polls=3 head_sha=headsha1 copilot_fallback_cause=error elapsed_seconds=2' \
  'duplicate errors in the initial snapshot still permit one retry||STUB_APPROVAL_MODE=copilot_error_twice,STUB_DUPLICATE_ERRORS=1|rc=1 status=copilot-error requests=1 approval_polls=3' \
  'the same error keeps waiting to the original deadline||STUB_APPROVAL_MODE=copilot_error|rc=1 status=timeout requests=1 approval_polls=4 elapsed_seconds=3' \
  'an earlier-head error consumes no request||STUB_APPROVAL_MODE=copilot_error,STUB_ERROR_HEAD=oldsha|rc=1 status=timeout requests=0' \
  'the sentence from another reviewer consumes no request||STUB_APPROVAL_MODE=human_error|rc=1 status=timeout requests=0' \
  'a completed Copilot comment consumes no request||STUB_APPROVAL_MODE=copilot_comment|rc=1 status=timeout requests=0' \
  'review identities on a later page are read||STUB_APPROVAL_MODE=copilot_error_twice,STUB_REVIEW_PAGES=1|rc=1 status=copilot-error requests=1' \
  'a spent request allowance returns the existing refusal cause||STUB_APPROVAL_MODE=copilot_error,STUB_REQUEST_EXIT=8|rc=1 status=copilot-error requests=1 copilot_fallback_cause=refused+exit=8' \
  'unreadable review identities refuse without a request||STUB_APPROVAL_MODE=copilot_error,STUB_REVIEW_READ=fail|rc=1 status=error requests=0' \
  'an empty success body is no review evidence||STUB_APPROVAL_MODE=copilot_error,STUB_REVIEW_READ=empty|rc=1 status=error requests=0' \
  'a non-list body is no review evidence||STUB_APPROVAL_MODE=copilot_error,STUB_REVIEW_READ=invalid|rc=1 status=error requests=0' \
  'missing retry context stops without a request||STUB_APPROVAL_MODE=copilot_error,STUB_NO_BASE_CHECKOUT=1|rc=2 stdout=empty requests=0' \
  'a failed mode read stops without a request||STUB_APPROVAL_MODE=copilot_error,STUB_BASE_MODE=fail|rc=2 stdout=empty requests=0' \
  'a REST reviewer mismatch consumes no request||STUB_APPROVAL_MODE=copilot_error,STUB_REST_REVIEWER=human|rc=1 status=timeout requests=0' \
  'an open thread routes before any retry||STUB_APPROVAL_MODE=copilot_error,STUB_THREADS_UNRESOLVED=1|rc=1 status=comments requests=0'

echo "=== a restart preserves the error retry at this head ==="
table '1 1 3 --json --mode approval --item KEN-error-mode-restart' \
  'a failed mode read leaves the unsent retry available||STUB_APPROVAL_MODE=copilot_error,STUB_BASE_MODE=fail|rc=2 stdout=empty requests=0' \
  'a same-head restart sends the retry after the mode read recovers||STUB_APPROVAL_MODE=copilot_error_approved|rc=0 status=approved requests=1 approval_polls=3'

table '1 1 3 --json --mode approval --item KEN-error' \
  'the first wait claims the retry||STUB_APPROVAL_MODE=copilot_error|rc=1 status=timeout requests=1' \
  'a timeout restart cannot retry the same answer||STUB_APPROVAL_MODE=copilot_error|rc=1 status=timeout requests=0' \
  'a distinct answer on a later wait names the fallback||STUB_APPROVAL_MODE=copilot_error,STUB_ERROR_ID=2|rc=1 status=copilot-error requests=0 head_sha=headsha1' \
  'the fallback wait spends its period waiting for app approval||STUB_APPROVAL_MODE=copilot_error,STUB_ERROR_ID=2|rc=1 status=timeout requests=0 elapsed_seconds=3' \
  'an app approval ends the fallback wait||STUB_APPROVAL_MODE=approved_decision|rc=0 status=approved requests=0'

mkdir -p "$TMP_ROOT/repo/tmp/lane-mail/KEN-error-mail"
table '1 1 3 --json --mode approval --item KEN-error-mail' \
  "mail after a retry interrupts without a gate verdict||STUB_APPROVAL_MODE=copilot_error,STUB_MAIL_TO=$TMP_ROOT/repo/tmp/lane-mail/KEN-error-mail/to-lane.jsonl|rc=5 mail=1 requests=1"
rm -f -- "${TMP_ROOT:?}/repo/tmp/lane-mail/KEN-error-mail/to-lane.jsonl"
table '1 1 3 --json --mode approval --item KEN-error-mail' \
  'a mail restart cannot repeat the claimed retry||STUB_APPROVAL_MODE=copilot_error|rc=1 status=timeout requests=0'

echo "=== transient GitHub API failures are retried inside the budget and counted ==="
# A 5xx or 429 from the pr view, or from the author read, is absorbed with
# backoff and reported as transient_api_errors on the eventual result; one
# that never clears becomes terminal only when the budget is spent. A 404 is
# terminal at once and carries no count.
table "$APPROVAL" \
  'pr view 503s twice, then an approval is approved with the count||STUB_APPROVAL_MODE=approved_after_503|rc=0 status=approved transient_api_errors=2 approval_polls=3' \
  'pr view 429s twice, then an approval is approved with the count||STUB_APPROVAL_MODE=approved_after_429|rc=0 status=approved transient_api_errors=2' \
  'an author read that 503s twice retries, then the approval counts||STUB_PR_AUTHOR_MODE=flaky_503,STUB_APPROVAL_MODE=approved_decision|rc=0 status=approved transient_api_errors=2' \
  'a persistent 503 is an error only once the budget is spent||STUB_APPROVAL_MODE=http_503|rc=1 status=error transient_errors_seen=true spent=true' \
  'a 404 is terminal at once with no transient count||STUB_APPROVAL_MODE=http_404|rc=1 status=error transient_api_errors=null early=true'

echo "=== the verdict names the repository it read ==="
# The resolution ladder is lib/gh-repo.sh's, and gh-repo-resolve.test.sh holds
# its rows. These hold approval-wait's own use of it: the slug GH_REPO names is the
# repository the verdict carries, over the checkout `gh repo view` answers for,
# and a value the resolver refuses is approval-wait's repo-shape error, with the
# result's repo left empty so nothing reads an unvalidated candidate as the
# repository the verdict is about.
table "$APPROVAL" \
  'GH_REPO names the repository, over the checkout gh repo view answers for||GH_REPO=other/elsewhere,STUB_APPROVAL_MODE=approved_decision|rc=0 status=approved repo=other/elsewhere' \
  'a GH_REPO that is not owner/name is refused||GH_REPO=elsewhere,STUB_APPROVAL_MODE=approved_decision|rc=1 status=error repo= error_line=approval-wait:+repo-shape+repo=elsewhere'

echo "=== text mode prints a result line for every branch the emitter has ==="
# The line's wording is not a contract anything parses; what holds is that no
# terminal status leaves stdout empty, with the same exit code as --json.
table '1 1 3 --mode approval' \
  'text: approved||STUB_APPROVAL_MODE=approved_decision|rc=0 text_status=approved' \
  'text: changes requested||STUB_APPROVAL_MODE=changes|rc=1 text_status=changes_requested' \
  'text: comments||STUB_APPROVAL_MODE=none,STUB_THREADS_UNRESOLVED=2|rc=1 text_status=comments' \
  'text: timeout||STUB_APPROVAL_MODE=none|rc=1 text_status=timeout' \
  'text: error||GH_TOKEN=bad-token,STUB_GH_DENY_KEYRING=1|rc=3 text_status=error' \
  'text: proceeded||STUB_APPROVAL_MODE=none,PR_REVIEW_ON_TIMEOUT=proceed|rc=0 text_status=proceeded' \
  'text: unreviewable||STUB_APPROVAL_MODE=none,STUB_BASE_REF=stack-base|rc=1 text_status=unreviewable' \
  'the result line names the repository it read||GH_REPO=other/elsewhere,STUB_APPROVAL_MODE=approved_decision|rc=0 text_status=approved text_repo=other/elsewhere'

echo "=== PR_REVIEW_WAIT_SECS: an absent max_wait positional resolves through orch-env ==="
# Process env beats kendex.settings.toml [env], and an explicit positional
# beats both. On the virtual clock a timeout lands on its deadline exactly, so
# each row pins the deadline it resolved, none of them the 900s built-in
# default. The settings file is this case's private fixture.
# Row: `label|settings value or empty|args|env|expect`.
SETTINGS_FILE="$TMP_ROOT/repo/kendex.settings.toml"
waitsecs_rows=(
  'the env value drives the deadline||1 1 --json --mode approval|STUB_APPROVAL_MODE=none,PR_REVIEW_WAIT_SECS=1|rc=1 status=timeout elapsed_seconds=1'
  'the settings-file value applies when the env is silent|1|1 1 --json --mode approval|STUB_APPROVAL_MODE=none|rc=1 status=timeout elapsed_seconds=1'
  'the env value outlives the settings file|1|1 1 --json --mode approval|STUB_APPROVAL_MODE=none,PR_REVIEW_WAIT_SECS=3|rc=1 status=timeout elapsed_seconds=3'
  'an explicit positional wins over the setting|600|1 1 3 --json --mode approval|STUB_APPROVAL_MODE=none|rc=1 status=timeout elapsed_seconds=3'
)
for row in "${waitsecs_rows[@]}"; do
  IFS='|' read -r label setting args env expect <<<"$row"
  [[ -n "$expect" ]] || { printf 'waitsecs: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
  rm -f -- "${SETTINGS_FILE:?}"
  [[ -z "$setting" ]] || printf '[env]\nPR_REVIEW_WAIT_SECS = "%s"\n' "$setting" >"$SETTINGS_FILE"
  # shellcheck disable=SC2086
  run_wait "$env" $args
  assert_eq "$(observe "$expect")" "$expect" "waitsecs: $label" "$RUN/stderr"
done
rm -f -- "${SETTINGS_FILE:?}"

echo "=== unread lane mail ends the wait early ==="
# A directive the virtual clock's first sleep delivers to the lane's mailbox;
# the poll interval equals the budget, so a wait that does not watch the
# mailbox inside its sleep reaches the deadline instead.
table "$APPROVAL" \
  "a directive written mid-wait returns the keyed line with exit 5|1 30 30 --json --mode approval --item KEN-2|STUB_APPROVAL_MODE=none,STUB_MAIL_TO=$TMP_ROOT/repo/tmp/lane-mail/KEN-2/to-lane.jsonl|rc=5 mail=1"

echo "=== PR_COPILOT_REQUESTS=off: a wait in a lane asks the overseer once per head ==="
# No Copilot review will come, so the wait asks the overseer for the head
# approval itself. Rows on one item share its mailbox, so a row's
# fallback_notices is every notice that item has sent so far: a second wait on
# the same head adds none and a new head adds its own. Polls fall 61 virtual seconds apart, past lane-mail's
# minute repeat check, so only the wait's own once-per-head key can hold a
# repeat back. A wait with no lane mailbox, with requests on, or on an approved
# head sends nothing, and a send that fails leaves the wait running and tries
# again on the next poll.
mkdir -p "$TMP_ROOT/repo/tmp/lane-mail/KEN-9" "$TMP_ROOT/repo/tmp/lane-mail/KEN-8" \
  "$TMP_ROOT/repo/tmp/lane-mail/KEN-3" "$TMP_ROOT/repo/tmp/lane-mail/KEN-2" \
  "$TMP_ROOT/repo/tmp/lane-mail/KEN-6/to-overseer.jsonl"
for item in KEN-20 KEN-21 KEN-22 KEN-23 KEN-24 KEN-25 KEN-26 KEN-27 KEN-28 KEN-29 KEN-30 KEN-31; do mkdir -p "$TMP_ROOT/repo/tmp/lane-mail/$item"; done
table '1 61 61 --json --mode approval --item KEN-9' \
  'a wait on an unapproved head sends one notice over two polls||PR_COPILOT_REQUESTS=off|rc=1 status=timeout unsent=0 fallback_notices=headsha1:off:tmp/lane-status-KEN-9.md' \
  'a second wait on the same head sends nothing||PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=fail|rc=1 status=timeout copilot_polls=0 unsent=0 fallback_notices=headsha1:off:tmp/lane-status-KEN-9.md' \
  'a new head sends its own notice|1 61 183 --json --mode approval --item KEN-9|PR_COPILOT_REQUESTS=off,STUB_HEAD_MODE=changes|rc=1 status=timeout fallback_notices=headsha1:off:tmp/lane-status-KEN-9.md,headsha2:off:tmp/lane-status-KEN-9.md' \
  'requests on send nothing|1 61 61 --json --mode approval --item KEN-8||rc=1 status=timeout fallback_notices=none' \
  'an approved head sends nothing|1 61 61 --json --mode approval --item KEN-8|PR_COPILOT_REQUESTS=off,STUB_APPROVAL_MODE=approved_decision|rc=0 status=approved fallback_notices=none' \
  'a wait outside a lane sends nothing|1 61 61 --json --mode approval --item KEN-7|PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=fail|rc=1 status=timeout copilot_polls=0 unsent=0 fallback_notices=none' \
  'a wait without an item reads no Copilot work|1 1 1 --json --mode approval|PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=fail|rc=1 status=timeout copilot_polls=0' \
  'active Copilot work holds the off notice|1 1 1 --json --mode approval --item KEN-8|PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=in_progress|rc=1 status=timeout fallback_notices=none' \
  'completion releases the off notice|1 1 1 --json --mode approval --item KEN-8|PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=finishing|rc=1 status=timeout fallback_notices=headsha1:off:tmp/lane-status-KEN-8.md' \
  'a failed Copilot read sends no notice|1 1 1 --json --mode approval --item KEN-3|PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=fail|rc=1 status=error fallback_notices=none' \
  'pending timeline work holds the notice until reviewed|1 1 1 --json --mode approval --item KEN-2|PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=timeline|rc=1 status=timeout copilot_polls=2 fallback_notices=headsha1:off:tmp/lane-status-KEN-2.md' \
  'request cycle completed|1 1 1 --json --mode approval --item KEN-20|PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=cycle-completed,STUB_CONFIRM_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|rc=1 status=timeout copilot_polls=1 fallback_notices=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:off:tmp/lane-status-KEN-20.md' \
  'completed cycle after ordinary push|1 1 1 --json --mode approval --item KEN-24|PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=cycle-completed-ordinary,STUB_CONFIRM_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|rc=1 status=timeout copilot_polls=1 fallback_notices=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:off:tmp/lane-status-KEN-24.md' \
  'new request after ordinary push|1 1 1 --json --mode approval --item KEN-25|PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=cycle-newer-ordinary,STUB_CONFIRM_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|rc=1 status=timeout copilot_polls=2 fallback_notices=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:off:tmp/lane-status-KEN-25.md' \
  'second review cycle completed|1 1 1 --json --mode approval --item KEN-26|PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=cycle-rereview-completed-ordinary,STUB_CONFIRM_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|rc=1 status=timeout copilot_polls=1 fallback_notices=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:off:tmp/lane-status-KEN-26.md' \
  'second review cycle newer|1 1 1 --json --mode approval --item KEN-27|PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=cycle-rereview-newer-ordinary,STUB_CONFIRM_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|rc=1 status=timeout copilot_polls=2 fallback_notices=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:off:tmp/lane-status-KEN-27.md' \
  'cancelled completed review after ordinary pushes|1 1 1 --json --mode approval --item KEN-29|PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=cycle-cancel-completed,STUB_CONFIRM_HEAD=cccccccccccccccccccccccccccccccccccccccc|rc=1 status=timeout copilot_polls=1 fallback_notices=cccccccccccccccccccccccccccccccccccccccc:off:tmp/lane-status-KEN-29.md' \
  'unanswered request after cancelled completed history|1 1 1 --json --mode approval --item KEN-30|PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=cycle-cancel-newer,STUB_CONFIRM_HEAD=cccccccccccccccccccccccccccccccccccccccc|rc=1 status=timeout copilot_polls=2 fallback_notices=cccccccccccccccccccccccccccccccccccccccc:off:tmp/lane-status-KEN-30.md' \
  'cancelled completed review after a verified boundary|1 1 1 --json --mode approval --item KEN-31|PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=cycle-cancel-boundary,STUB_CONFIRM_HEAD=cccccccccccccccccccccccccccccccccccccccc|rc=1 status=timeout copilot_polls=1 fallback_notices=cccccccccccccccccccccccccccccccccccccccc:off:tmp/lane-status-KEN-31.md' \
  'request cycle newer|1 1 1 --json --mode approval --item KEN-21|PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=cycle-newer,STUB_CONFIRM_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|rc=1 status=timeout copilot_polls=2 fallback_notices=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:off:tmp/lane-status-KEN-21.md' \
  'a failed send is retried and ends no wait|1 61 61 --json --mode approval --item KEN-6|PR_COPILOT_REQUESTS=off|rc=1 status=timeout unsent=2' \
  'an unknown setting is refused|1 61 61 --json --mode approval --item KEN-9|PR_COPILOT_REQUESTS=junk|rc=2 stdout=empty stderr_line=approval-wait:+copilot-requests-invalid+value=junk'

echo "=== must-fail controls: each resolution rule and the route's two orderings ==="
# Each control edits a copy of approval-wait in a project of its own, never
# the tracked file, and asserts its substitution matched exactly once. The
# mutant keeps the matched line and removes one rule, so the row that rule
# decides answers otherwise:
#   threshold-up           the approval branch needs 2, so 1 required
#                          answers off
#   threshold-down         the approval branch needs 0, so 0 required
#                          answers approval
#   decision-ignored       the reviewDecision is dropped, so 0 required
#                          beside REVIEW_REQUIRED answers off
#   fail-open              a failed rules read yields a count of 0 and
#                          answers off
#   approved-first         an approval no longer waits for its threads to
#                          resolve
#   changes-over-approval  a CHANGES_REQUESTED review blocks beside an
#                          APPROVED decision, so an approved head with a
#                          thread answers changes_requested, not comments
#   fallback-once          the notice file is no longer created
#                          exclusively, so a second wait on a head the first
#                          already announced sends it again
#   fallback-outside-lane  a missing mailbox no longer ends the notice, so a
#                          wait outside a lane tries to send one
# The same project's unmutated copy answers each row first, so a control
# reddens its row through its mutation alone.
MUTANT_REPO="$TMP_ROOT/mutant"
mkdir -p "$MUTANT_REPO/.agents/skills/orch"
cp -R "$REPO_ROOT/skills/orch/scripts" "$MUTANT_REPO/.agents/skills/orch/scripts"
ln -s "$REPO_ROOT/skills/github" "$MUTANT_REPO/.agents/skills/github"
ln -s "$REPO_ROOT/skills/review-gate" "$MUTANT_REPO/.agents/skills/review-gate"
git -C "$MUTANT_REPO" init -q
git -C "$MUTANT_REPO" config gc.auto 0
git -C "$MUTANT_REPO" config maintenance.auto false
mkdir -p "$MUTANT_REPO/tmp/lane-mail/KEN-9"
for item in KEN-20 KEN-21 KEN-22 KEN-23 KEN-24 KEN-25 KEN-26 KEN-27 KEN-28 KEN-29 KEN-30 KEN-31; do mkdir -p "$MUTANT_REPO/tmp/lane-mail/$item"; done
mkdir -p "$MUTANT_REPO/tmp/lane-mail/KEN-5" "$MUTANT_REPO/tmp/lane-mail/KEN-4" "$MUTANT_REPO/tmp/lane-mail/KEN-2"
MUTANT_SCRIPT="$MUTANT_REPO/.agents/skills/orch/scripts/approval-wait"
PRISTINE="$TMP_ROOT/approval-wait.pristine"
cp "$MUTANT_SCRIPT" "$PRISTINE"
MUTANT_READER="$MUTANT_REPO/.agents/skills/orch/scripts/lib/copilot-check-runs.sh"
READER_PRISTINE="$TMP_ROOT/copilot-reader.pristine"
cp "$MUTANT_READER" "$READER_PRISTINE"

# control NAME FROM TO ARGS ENV EXPECT — EXPECT holds against the unmutated
# copy, and fails once the one line FROM reads TO.
control() {
  local name="$1" from="$2" to="$3" args="$4" env="$5" expect="$6" count target="$MUTANT_SCRIPT" pristine="$PRISTINE"
  if [[ "$name" == fallback-cancel ]]; then target="$MUTANT_READER"; pristine="$READER_PRISTINE"; fi
  cp "$pristine" "$target"
  cp "$PRISTINE" "$MUTANT_SCRIPT"
  WAIT_REPO="$MUTANT_REPO"
  if [[ "$name" == fallback-timeline ]]; then rm -f "$WAIT_REPO/tmp/lane-mail/KEN-2/copilot-fallback-headsha1.md" "$WAIT_REPO/tmp/lane-mail/KEN-2/to-overseer.jsonl"; fi
  if [[ "$name" == fallback-cancel ]]; then rm -f -- "${WAIT_REPO:?}/tmp/lane-mail/KEN-29/copilot-fallback-cccccccccccccccccccccccccccccccccccccccc.md" "${WAIT_REPO:?}/tmp/lane-mail/KEN-29/to-overseer.jsonl"; fi
  # shellcheck disable=SC2086
  run_wait "$env" $args
  assert_eq "$(observe "$expect")" "$expect" "control $name: the unmutated copy answers the row" "$RUN/stderr"
  count="$(grep -Fxc -- "$from" "$pristine" || true)"
  assert_eq "$count" "1" "control $name: the substitution matches one line"
  # ENVIRON, not -v: awk -v escape-processes its value, and awks disagree on
  # the trailing backslash the changes-over-approval lines end in.
  MUT_FROM="$from" MUT_TO="$to" awk '$0 == ENVIRON["MUT_FROM"] { print ENVIRON["MUT_TO"]; next } { print }' "$pristine" >"$target"
  if cmp -s "$target" "$pristine"; then
    fail "control $name: the mutant must differ from the script"
  fi
  if [[ "$name" == fallback-timeline ]]; then rm -f "$WAIT_REPO/tmp/lane-mail/KEN-2/copilot-fallback-headsha1.md" "$WAIT_REPO/tmp/lane-mail/KEN-2/to-overseer.jsonl"; fi
  if [[ "$name" == fallback-cancel ]]; then rm -f -- "${WAIT_REPO:?}/tmp/lane-mail/KEN-29/copilot-fallback-cccccccccccccccccccccccccccccccccccccccc.md" "${WAIT_REPO:?}/tmp/lane-mail/KEN-29/to-overseer.jsonl"; fi
  # shellcheck disable=SC2086
  run_wait "$env" $args
  if [[ "$(observe "$expect")" == "$expect" ]]; then
    fail "must-fail $name: the mutant still answers $expect"
  else
    pass "must-fail $name: the mutant breaks $expect"
  fi
  cp "$pristine" "$target"
  WAIT_REPO="$TMP_ROOT/repo"
}

# shellcheck disable=SC2016 # the lines are matched literally, unexpanded
control threshold-up '  if [ "$required" -ge 1 ] || [ -n "$decision" ]; then' \
  '  if [ "$required" -ge 2 ] || [ -n "$decision" ]; then' \
  "$RESOLVE" 'STUB_REQUIRED_APPROVALS=1' 'rc=0 mode=approval'
# shellcheck disable=SC2016 # the lines are matched literally, unexpanded
control threshold-down '  if [ "$required" -ge 1 ] || [ -n "$decision" ]; then' \
  '  if [ "$required" -ge 0 ] || [ -n "$decision" ]; then' \
  "$RESOLVE" 'STUB_REQUIRED_APPROVALS=0' 'rc=0 mode=off'
# shellcheck disable=SC2016 # the lines are matched literally, unexpanded
control decision-ignored '  if [ "$required" -ge 1 ] || [ -n "$decision" ]; then' \
  '  if [ "$required" -ge 1 ]; then' \
  "$RESOLVE" 'STUB_REQUIRED_APPROVALS=0,STUB_BASE_DECISION=REVIEW_REQUIRED' 'rc=0 mode=approval'
# shellcheck disable=SC2016 # the lines are matched literally, unexpanded
control fail-open '  if ! required=$(read_required_approvals "$RULES_BRANCH"); then' \
  '  if ! required=$(read_required_approvals "$RULES_BRANCH" || echo 0); then' \
  "$RESOLVE" 'STUB_RULES_MODE=fail' 'rc=2 stdout=empty'
control wait-mode '[[ -n "$MODE" ]] || $RESOLVE_MODE || $REQUEST_REVIEW || { approval_message missing-mode >&2; exit 2; }' \
  ': # [[ -n "$MODE" ]] || $RESOLVE_MODE || $REQUEST_REVIEW || { approval_message missing-mode >&2; exit 2; }' \
  '1 1 3 --json' 'STUB_APPROVAL_MODE=approved_decision' 'rc=2 stdout=empty'
control consumer-context '  [[ -n "$BASE_CHECKOUT" ]] || { approval_message base-checkout-invalid >&2; return 1; }' \
  '  : # [[ -n "$BASE_CHECKOUT" ]] || { approval_message base-checkout-invalid >&2; return 1; }' \
  '1 --resolve-mode' 'STUB_REQUIRED_APPROVALS=1' 'rc=2 stdout=empty rules_reads=0'
# shellcheck disable=SC2016 # the lines are matched literally, unexpanded
control approved-first '  if [ "$approved" = true ] && [ "$last_unresolved" -eq 0 ]; then' \
  '  if [ "$approved" = true ]; then' \
  "$APPROVAL" 'STUB_APPROVAL_MODE=approved_decision,STUB_THREADS_UNRESOLVED=1' 'rc=1 status=comments'
# shellcheck disable=SC2016,SC1003 # the lines are matched literally, unexpanded; each ends in a backslash
control changes-over-approval '  if [ "$approved" = false ] \' '  if [ "$approved" = true ] \' \
  "$APPROVAL" 'STUB_APPROVAL_MODE=approved_with_changes,STUB_THREADS_UNRESOLVED=1' 'rc=1 status=comments'
# shellcheck disable=SC2016 # the lines are matched literally, unexpanded
control fallback-once '  if ! (set -o noclobber; cat >"$notice" <<<"$text") 2>/dev/null; then' \
  '  if ! (set +o noclobber; cat >"$notice" <<<"$text") 2>/dev/null; then' \
  '1 61 61 --json --mode approval --item KEN-9' 'PR_COPILOT_REQUESTS=off' 'rc=1 status=timeout fallback_notices=headsha1:off:tmp/lane-status-KEN-9.md'
# shellcheck disable=SC2016 # the lines are matched literally, unexpanded
control fallback-outside-lane '  [ -d "$box" ] || return 0' '  : # [ -d "$box" ] || return 0' \
  '1 61 61 --json --mode approval --item KEN-7' 'PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=fail' 'rc=1 status=timeout copilot_polls=0 unsent=0 fallback_notices=none'
# shellcheck disable=SC2016
control fallback-existing '  if [ ! -e "$notice" ]; then' '  if true; then # if [ ! -e "$notice" ]; then' \
  '1 1 1 --json --mode approval --item KEN-9' 'PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=fail' 'rc=1 status=timeout copilot_polls=0'

# shellcheck disable=SC2016
control fallback-in-flight '    [ "$copilot_runs" = '\''[]'\'' ] || return 0' \
  '    : # [ "$copilot_runs" = '\''[]'\'' ] || return 0' \
  '1 1 1 --json --mode approval --item KEN-5' 'PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=in_progress' 'rc=1 status=timeout fallback_notices=none'
# shellcheck disable=SC2016
control fallback-read-failed '    if ! copilot_runs=$(orch_copilot_check_runs "$REPO" "$1" "$PR_NUM" 2>"$GH_ERR_FILE"); then' \
  '    if ! copilot_runs=$(orch_copilot_check_runs "$REPO" "$1" "$PR_NUM" 2>"$GH_ERR_FILE" || printf "[]\\n"); then' \
  '1 1 1 --json --mode approval --item KEN-4' 'PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=fail' 'rc=1 status=error fallback_notices=none'
# shellcheck disable=SC2016
control fallback-cancel '           elif . != null and $event.submitted_at >= .started_at' \
  '           elif false and . != null and $event.submitted_at >= .started_at' \
  '1 1 1 --json --mode approval --item KEN-29' 'PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=cycle-cancel-completed,STUB_CONFIRM_HEAD=cccccccccccccccccccccccccccccccccccccccc' \
  'rc=1 status=timeout copilot_polls=1 fallback_notices=cccccccccccccccccccccccccccccccccccccccc:off:tmp/lane-status-KEN-29.md'
# shellcheck disable=SC2016
control fallback-timeline '    if ! copilot_runs=$(orch_copilot_check_runs "$REPO" "$1" "$PR_NUM" 2>"$GH_ERR_FILE"); then' \
  '    if ! copilot_runs=$(orch_copilot_check_runs "$REPO" "$1" 2>"$GH_ERR_FILE"); then' \
  '1 1 1 --json --mode approval --item KEN-2' 'PR_COPILOT_REQUESTS=off,STUB_COPILOT_FLIGHT=timeline' \
  'rc=1 status=timeout copilot_polls=2 fallback_notices=headsha1:off:tmp/lane-status-KEN-2.md'

# The old loop keeps the error snapshot but performs no request. This must
# redden the same request-and-continued-wait row, not merely its final status.
# shellcheck disable=SC2016
control copilot-error-no-retry '  if [ "$COPILOT_REQUESTS" = on ] && jq -e --arg reviewer "$COPILOT_REVIEWER" '"'"'' \
  '  if false && jq -e --arg reviewer "$COPILOT_REVIEWER" '"'"'' \
  "$APPROVAL" 'STUB_APPROVAL_MODE=copilot_error_twice' 'rc=1 status=copilot-error requests=1 approval_polls=3'

# shellcheck disable=SC2016
control copilot-current-head '        and .commit_id == $head and (.state == "COMMENTED" or .state == "APPROVED" or .state == "CHANGES_REQUESTED"))]' \
  '        and (.state == "COMMENTED" or .state == "APPROVED" or .state == "CHANGES_REQUESTED"))]' \
  "$APPROVAL" 'STUB_APPROVAL_MODE=copilot_error,STUB_ERROR_HEAD=oldsha' 'rc=1 status=timeout requests=0'
# shellcheck disable=SC2016
control copilot-reviewer '    | [.[] | select(.user.login == $reviewer' \
  '    | [.[] | select(true' \
  "$APPROVAL" 'STUB_APPROVAL_MODE=copilot_error,STUB_REST_REVIEWER=human' 'rc=1 status=timeout requests=0'
# shellcheck disable=SC2016
control copilot-error-body '    | if .state == "COMMENTED" and ((.body // "") | contains($sentence))' \
  '    | if .state == "COMMENTED"' \
  "$APPROVAL" 'STUB_APPROVAL_MODE=copilot_comment' 'rc=1 status=timeout requests=0'
# shellcheck disable=SC2016
control copilot-distinct-answer '        && [ "$(jq -r '\''.review_id'\'' <<<"$copilot_retry")" != "$copilot_error_id" ]; then' \
  '        && [ "$(jq -r '\''.review_id'\'' <<<"$copilot_retry")" = "$copilot_error_id" ]; then' \
  "$APPROVAL" 'STUB_APPROVAL_MODE=copilot_error' 'rc=1 status=timeout requests=1 approval_polls=4'

# The seeded state belongs to the copied script's first wait. A fresh process
# must reuse that record; local memory alone cannot satisfy this row.
cp "$PRISTINE" "$MUTANT_SCRIPT"
WAIT_REPO="$MUTANT_REPO"
run_wait 'STUB_APPROVAL_MODE=copilot_error' 1 1 3 --json --mode approval --item KEN-control-error
assert_eq "$(observe 'rc=1 status=timeout requests=1')" 'rc=1 status=timeout requests=1' 'the first copied wait claims its retry' "$RUN/stderr"
WAIT_REPO="$TMP_ROOT/repo"
# shellcheck disable=SC2016
control copilot-error-restart '  if [[ -n "$ITEM" ]]; then' '  if false; then' \
  '1 1 3 --json --mode approval --item KEN-control-error' 'STUB_APPROVAL_MODE=copilot_error' 'rc=1 status=timeout requests=0'

# A failed GitHub mode read must leave no consumed retry on a fresh wait.
# Keep the update call and change only its filter so the failed wait persists
# the claim; the recovered wait must then lose the request assertion.
from='            '\''del(.pr_approval.copilot_error_retries[$head])'\''; then'
to='            '\''.'\''; then'
count="$(grep -Fxc -- "$from" "$PRISTINE" || true)"
assert_eq "$count" '1' 'control copilot-mode-restart: the substitution matches one line'
MUT_FROM="$from" MUT_TO="$to" awk '$0 == ENVIRON["MUT_FROM"] { print ENVIRON["MUT_TO"]; next } { print }' "$PRISTINE" >"$MUTANT_SCRIPT"
if cmp -s "$MUTANT_SCRIPT" "$PRISTINE"; then
  fail 'control copilot-mode-restart: the mutant must differ from the script'
fi
WAIT_REPO="$MUTANT_REPO"
run_wait 'STUB_APPROVAL_MODE=copilot_error,STUB_BASE_MODE=fail' 1 1 3 --json --mode approval --item KEN-control-mode-restart
assert_eq "$(observe 'rc=2 stdout=empty requests=0')" 'rc=2 stdout=empty requests=0' 'the mutant keeps the failed mode-read exit' "$RUN/stderr"
run_wait 'STUB_APPROVAL_MODE=copilot_error_approved' 1 1 3 --json --mode approval --item KEN-control-mode-restart
if [[ "$(observe 'rc=0 status=approved requests=1 approval_polls=3')" == 'rc=0 status=approved requests=1 approval_polls=3' ]]; then
  fail 'must-fail copilot-mode-restart: the mutant still sends the retry'
else
  pass 'must-fail copilot-mode-restart: the retained claim prevents the retry'
fi
WAIT_REPO="$TMP_ROOT/repo"

echo "=== a failed emit_result never reports a successful gate ==="
# emit_result builds the --json object with `jq -n`, so this stub fails
# EXACTLY that call and passes every parse through to the real jq: the
# emission fails while the poll that reached the verdict succeeds — a closed
# pipe or a write failure. Each emit site must propagate jq's status 5 and
# write nothing: the run_approved_gate site under both approval signals, and
# the bare deadline `emit_result "timeout"` where nothing but errexit stands
# before `exit 1`, so a 1 there would mean a `set +e` had migrated above the
# emit.
REAL_JQ="$(command -v jq)"
JQ_STUB="$TMP_ROOT/bin/jq"
cat > "$JQ_STUB" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-n" ]; then
  echo "jq: emission failed (stub)" >&2
  exit 5
fi
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$JQ_STUB"
table "$APPROVAL" \
  'emit failure at the reviewDecision gate site||STUB_APPROVAL_MODE=approved_decision|rc=5 stdout=empty' \
  'emit failure at the latestReviews gate site||STUB_APPROVAL_MODE=approved_latest|rc=5 stdout=empty' \
  'emit failure on the bare timeout path|1 1 2 --json --mode approval|STUB_APPROVAL_MODE=none|rc=5 stdout=empty'
rm -f -- "${JQ_STUB:?}"
# Control: with the real jq back the same poll approves, so the rows above
# prove the emission failure and not a broken fixture.
table "$APPROVAL" \
  'control: the same poll approves once emission works||STUB_APPROVAL_MODE=approved_decision|rc=0 status=approved'

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
