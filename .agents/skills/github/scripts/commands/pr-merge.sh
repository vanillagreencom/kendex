#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/github-api.sh"
# Issue prefixes that resolve on their own once GitHub finishes computing or
# CI completes. Callers should `await-mergeable` and retry rather than fix.
TRANSIENT_PREFIXES='unknown:|ci_pending:|ci_unconfigured:|ci_fetch_failed:'

# Scope a `gh pr checks` array to the current authoritative substantive run per
# workflow. Shared with orch `ci-wait` so the merge gate and the waiter cannot
# disagree about which run is current — see the library for the
# full rationale.
# shellcheck source=../lib/ci-run-correlation.sh
source "$SCRIPT_DIR/../lib/ci-run-correlation.sh"

# The disarm/dequeue GraphQL verb, shared with orch ci-wait's queue-wait guard
# so the admin route and the waiter cannot disagree about how a PR leaves the
# merge queue — see the library for the full rationale.
# shellcheck source=../lib/merge-queue.sh
source "$SCRIPT_DIR/../lib/merge-queue.sh"

show_help() {
    cat <<'EOF'
Merge PR as bot account with safety checks

Usage: pr-merge <PR_NUMBER> [options]

Options:
  --squash         Squash and merge (default)
  --merge          Create merge commit
  --rebase         Rebase and merge
  --delete-branch  Delete branch after merge (default: true)
  --keep-branch    Keep branch after merge
  --check          Run checks only, don't merge. JSON on stdout; a one-word
                   verdict (mergeable|blocked|merged|closed) plus the run
                   scope ("head-run: <ids>" — the runs the CI classification
                   was scoped to) on stderr. On a refusal,
                   ci-classify-refusal names the cause.
  --force          Skip checks and merge (requires explicit user decision;
                   cannot be combined with --auto)
  --admin          Explicit current-user admin merge; skips checks; conflicts with --auto
  --admin-credential
                   Overseer route: merge the exact head with the control
                   host's owner credential after every merge condition is
                   checked. Requires --expected-head. Immediate-only and
                   exclusive with --check, --auto, --force, --admin and
                   --dry-run. See Admin-credential route below.
  --auto           If immediate merge is blocked, enable GitHub auto-merge
                   (will fire when CI + branch protection clear). Exits 75.
                   Never bypasses actionable unresolved review threads.
  --expected-head SHA
                   Bind GitHub's match-head merge guard to prepared SHA.
  --dry-run        Show what would happen without merging

Modes:
  (default)        Run checks, block if critical issues, merge if pass
  --check          Run checks, output JSON for workflow to parse
  --force/--admin  Deliberately skip all checks; --admin passes --admin to GitHub
  --auto           Enable auto-merge when immediate merge is blocked

Merge-mode exit codes:
  0    MERGED PR #N
       Merge completed immediately.
  0    ALREADY MERGED PR #N <mergedAt>
       The PR was merged before this call. Nothing was attempted.
  75   QUEUED IN MERGE QUEUE PR #N
       The required merge queue has an active entry.
  75   AUTO-MERGE ENABLED PR #N
       Classic auto-merge is armed until protection clears.
  1    BLOCKED PR #N
       The requested operation failed; a pre-existing queue entry or auto-merge request may remain active.
  1    arm: no-merge-gate=<allow_auto_merge|required_check|unverified> repo=<owner/repo>
       --auto refused, nothing mutated: GitHub would merge at once with nothing to wait on.
  1    CLOSED (not merged) PR #N
       The PR is closed unmerged. Nothing was attempted.

--check exit:
  --check exits 0 after any valid readiness JSON, including can_merge=false for
  blocked or CLOSED. Argument or dispatch failures before JSON remain nonzero.

Exit 75 is volatile:
  A queue ejection can disarm merge state. Block on .agents/skills/orch/scripts/queue-wait <N> <poll> <budget> --json before returning; it produces the verdict for the head just armed. Size the poll and budget as orch merge-pr.md § 5 step 1 does: the default budget outlives any foreground call an agent harness holds, so a call without them is killed before the verdict.
  Route verdicts through queue-wait --help Verdicts, named by SKILL.md § PR Merge Outcomes; the review-gate reducer still reports fleet attention.
  Re-arm only through github.sh pr-merge <N> --auto after that route.
  await-mergeable is not the lifecycle watcher; it stops when GitHub computes state.

Terminal and mutation rules:
  After github.sh router setup, MERGED or CLOSED short-circuits pr-merge safety
  checks, bot-token load, and merge-state mutation; UNKNOWN continues. --check reports state.

  Every gh pr merge invocation is exact-head guarded by --match-head-commit; a changed head is BLOCKED.
  Queue membership comes from GraphQL isInMergeQueue and mergeQueueEntry. An
  OPEN PR with an active queue entry exits 75 even when autoMergeRequest is
  absent. An OPEN PR with no queue or auto-merge proof fails closed. The
  --delete-branch cleanup after MERGED is best-effort, not merge-state mutation.

Review-thread gate:
  Unresolved, non-outdated review threads make can_merge false and block both
  immediate merge and --auto. A failed or malformed thread lookup also blocks.
  This is narrower than required_conversation_resolution, which requires every
  conversation resolved and does not exclude outdated threads.

  The gate is policy, not mechanism. It applies only through pr-merge. A raw
  gh pr merge call or the GitHub UI Merge button bypasses it.

Admin-credential route:
  The overseer's one merge verb for a pull request that needs no further
  process. It overrides no gate: it re-checks every condition below on the
  exact head itself, dequeues a queued PR, then merges with the control host's
  owner credential, whose --admin flag bypasses branch protection for the
  merge alone. It runs ONLY on the control host: ORCH_ADMIN_MERGE_GH_CONFIG_DIR
  names the gh config directory holding the owner credential, and an empty
  value or a path that is not a directory refuses the route. GH_TOKEN and
  GITHUB_TOKEN are cleared for every call, so a lane's own token can never
  reach the merge; the credential itself is never read, printed or passed on.

  Every condition is checked on --expected-head before any mutation, and a
  failed one refuses with nothing dequeued and nothing merged:
    class     ORCH_ADMIN_MERGE_CLASSES, empty for every class. A set value is
              a comma- or space-separated list, and the class comes from the
              change classifier, never from a flag, a label, a branch name or
              any other author-writable field. The classifier
              (<skills>/harness-ci/scripts/change-class, else change-class on
              PATH) ships with KEN-1637 and does not ship here; setting the
              variable before it lands refuses every merge with class-unreadable,
              so leave it empty until then. An empty list is every class, not
              the route off — only an empty config directory turns the route off.
    head      the live head equals --expected-head
    review    the review gate is met: GitHub's reviewDecision is APPROVED, or an
              approving review stands and none requests changes. --admin
              bypasses this on the merge, so the route re-checks it here.
    checks    no conflict, zero actionable unresolved threads, status checks
              configured, and every required context on the base branch's
              rulesets and classic protection present and green on this head.
              --admin bypasses the required-context gate on the merge, so the
              route enumerates those contexts and re-checks each one here.
    base      the head contains the base branch's current head, read from
              GitHub's compare endpoint, so a merge cannot land a branch
              behind its base
  A queued or auto-merge-armed PR is then disarmed and dequeued in
  merge-pr-restack.md step 1's order, and the merge passes the full 40-character
  --match-head-commit SHA. The base head is re-read immediately before the
  merge and a base that advanced since the containment check refuses; the read
  to the merge call is the one window the route cannot close, as in the fast
  path.

  One record line goes to stdout on every outcome, naming the PR, the head and
  each precondition's verdict, for the caller's fleet log and the PR's
  `## Merge decision` section:
    admin-merge <merged|already-merged|enrolled|unconfirmed|refused> pr=<N>
      head=<SHA> route=<..> class=<..> head-match=<..> review=<..> checks=<..>
      base=<..> dequeue=<..> [reason=<..>]
  A field no condition reached prints `-`. Exit codes: 0 merged (or already
  merged), 75 enrolled (GitHub queued or armed the PR instead of merging it),
  1 refused or the merge outcome could not be confirmed (verdict unconfirmed).

Force rules:
  --force and --admin skip every check, including the thread gate. --admin also
  requests GitHub's branch-protection bypass. Both are immediate-only and
  conflict with --auto. A failed override remains BLOCKED unless the exact-head
  post-state is MERGED; pending merge state is not success.

--check JSON:
  stdout is one object with these fields:
    can_merge   boolean readiness result
    issues      blocking issue strings
    warnings    non-blocking issue strings
    mergeable   MERGEABLE, CONFLICTING, or UNKNOWN
    review      GitHub review decision
    transient   true only when every blocker can clear by waiting
    state       OPEN, MERGED, CLOSED, or UNKNOWN
    merged_at   merge timestamp, or an empty string
    head_runs   run IDs used for CI classification
    checks      raw check rollup read by the classification
    required_contexts
                base-branch contexts the classification may block on

  stderr carries mergeable, blocked, merged, or closed, followed by
  head-run: <ids> when CI runs were classified. can_merge=false with an empty
  issues array means the PR is terminal; inspect state instead of treating it
  as a blocker to repair.

  transient=true requires every issue prefix to be unknown:, ci_pending:,
  ci_unconfigured:, or ci_fetch_failed:. A ci_failed: issue is permanent, as
  are conflicts and changes_requested. Running checks use ci_pending: while
  failed or cancelled checks use ci_failed:.

  ci_pending: and ci_failed: name only contexts the base branch requires, read
  from its rulesets and classic protection. A red check outside that set is a
  ci_optional_failed: warning, which blocks nothing — GitHub merges over it. A
  required context that has registered no check on the head is ci_pending:
  "<context> (missing)", the state GitHub itself is in while it waits. A base
  that requires nothing, whose protection cannot be read, or whose ruleset
  carries a rule gating the merge on a check it does not name, counts every
  check as before.

  head_runs contains the authoritative workflow run plus runs referenced by
  custom commit statuses. checks is the same snapshot consumed by
  ci-classify-refusal <N>, so cause:, fail:, and superseded: lines cannot race
  a second fetch.

Examples:
  github.sh pr-merge 42 --check          # Check only, JSON output
  github.sh pr-merge 42                  # Check + merge if pass
  github.sh pr-merge 42 --auto           # Merge now or queue auto-merge
  github.sh pr-merge 42 --force          # Explicit local override (DANGEROUS)
  github.sh pr-merge 42 --admin          # Explicit admin override (DANGEROUS)
EOF
}

# One authoritative read of the PR's lifecycle state, published in
# PR_STATE_JSON. Also validates that the PR exists — a bare number does not.
# Every caller shares the single fetch; a failed read is not cached, so the
# next caller retries rather than inheriting an empty state.
#
# On failure PR_STATE_ERROR carries a prefixed issue string. Only GitHub's
# own "this PR does not exist" wording becomes `not_found:` — an auth, network,
# rate-limit, or API failure keeps its own diagnostic instead of being
# reported as a missing PR.
PR_STATE_JSON=""
PR_STATE_JSON_PR=""
PR_STATE_ERROR=""
load_pr_state_json() {
    local pr_num="$1"
    if [ -n "$PR_STATE_JSON_PR" ] && [ "$PR_STATE_JSON_PR" = "$pr_num" ]; then
        return 0
    fi

    local err_file state_json status=0
    if ! err_file=$(mktemp "${TMPDIR:-/tmp}/pr-merge-state.XXXXXX"); then
        PR_STATE_ERROR="gh_error: could not create a temporary file for the PR state lookup"
        return 1
    fi

    state_json=$(gh pr view "$pr_num" --json state,mergedAt 2>"$err_file") || status=$?
    local detail
    detail=$(grep -v '^[[:space:]]*$' "$err_file" | head -1)
    rm -f "$err_file"

    if [ "$status" -eq 0 ]; then
        PR_STATE_JSON="$state_json"
        PR_STATE_JSON_PR="$pr_num"
        PR_STATE_ERROR=""
        return 0
    fi

    case "$detail" in
    *"Could not resolve to a PullRequest"* | *"o pull requests found"*)
        PR_STATE_ERROR="not_found: PR #$pr_num not found"
        ;;
    "")
        PR_STATE_ERROR="gh_error: gh pr view exited $status with no diagnostic"
        ;;
    *)
        PR_STATE_ERROR="gh_error: $detail"
        ;;
    esac
    return 1
}

# Report a PR that has left OPEN and exit. Every mode routes its terminal
# states through here so the outcome lines and exit codes cannot diverge.
# Any other state returns and lets the caller continue.
exit_terminal_state() {
    local state="$1" pr_num="$2" merged_at="${3:-}"

    case "$state" in
    MERGED)
        if [ -n "$merged_at" ]; then
            echo "ALREADY MERGED PR #$pr_num $merged_at" >&2
        else
            echo "ALREADY MERGED PR #$pr_num" >&2
        fi
        exit 0
        ;;
    CLOSED)
        echo "CLOSED (not merged) PR #$pr_num" >&2
        echo "  No merge attempted, none queued. Reopen the PR or supersede it." >&2
        exit 1
        ;;
    esac
}

# The base branch's required status-check contexts as a JSON array: the
# ruleset and classic-protection endpoints merge_gate_gap already reads, read
# for their context names instead of their presence. GitHub merges a PR whose
# non-required checks are red, so these names are what the CI gate may block
# on. Any answer that is not positive evidence of the whole required set
# prints `[]`, which counts every check — a branch whose protection cannot be
# read must never merge over a red one.
#
# An empty classic list counts only when the branch answer actually carried a
# `protection` object. GitHub omits that key from the branch payload for a
# caller without push access, and a missing key parses cleanly and exits 0, so
# reading it as "nothing required" would narrow the set to the ruleset
# contexts alone under a read-only token.
#
# The ruleset read also refuses on a rule type it cannot account for. Only
# `required_status_checks` names its contexts; the types listed in the filter
# below gate the ref, its commits, its files or its reviews and put nothing in
# the check rollup. `pull_request` and `copilot_code_review` are the review
# gates among them: each demands a REVIEW, which arrives as a review and is
# already carried by this command's approval and review-thread gates, never as
# a check on the head. Every other type — `workflows`, `code_scanning`,
# `code_quality`, `code_coverage` and whatever GitHub adds next — gates the
# merge on a check result whose context the rule never names, so naming a
# required set beside one would drop that check's red to a warning. An
# unrecognized type therefore turns the narrowing OFF rather than merging over
# a check the read cannot see. Rule types: docs.github.com/en/rest/repos/rules
RULESET_CONTEXTS_JQ='
  [
    "branch_name_pattern", "commit_author_email_pattern",
    "commit_message_pattern", "committer_email_pattern",
    "copilot_code_review", "creation",
    "deletion", "file_extension_restriction", "file_path_restriction",
    "max_file_path_length", "max_file_size", "merge_queue",
    "non_fast_forward", "pull_request", "required_deployments",
    "required_linear_history", "required_signatures",
    "required_status_checks", "tag_name_pattern", "update"
  ] as $accounted
  | .[]
  | (.type // "") as $type
  | (select(($accounted | index($type)) == null) | "unnameable:" + $type)
  , (select($type == "required_status_checks")
     | .parameters.required_status_checks[]?
     | "ctx:" + (.context // ""))'
required_contexts() {
    local pr_num="$1" base="" rules="" classic="" branch_json=""
    if ! base=$(gh pr view "$pr_num" --json baseRefName --jq '.baseRefName' 2>/dev/null) || [ -z "$base" ] \
        || ! base=$(jq -nr --arg v "$base" '$v | @uri') \
        || ! rules=$(gh api "repos/{owner}/{repo}/rules/branches/$base" --paginate --jq "$RULESET_CONTEXTS_JQ" 2>/dev/null) \
        || ! branch_json=$(gh api "repos/{owner}/{repo}/branches/$base" 2>/dev/null) \
        || ! jq -e 'type == "object" and has("protection")' >/dev/null 2>&1 <<<"$branch_json" \
        || ! classic=$(jq -r '.protection.required_status_checks | (.contexts // []) + [(.checks // [])[] | .context] | .[] | "ctx:" + .' <<<"$branch_json" 2>/dev/null) \
        || grep -q '^unnameable:' <<<"$rules"; then
        echo '[]'
        return 0
    fi
    printf '%s\n%s\n' "$rules" "$classic" | jq -R -s -c 'split("\n") | map(select(startswith("ctx:")) | ltrimstr("ctx:")) | unique'
}

run_checks() {
    local pr_num="$1"
    local can_merge=true
    local issues=()
    local warnings=()
    local head_runs_json='[]' checks_json='[]' required_json='[]'

    local pr_state pr_merged_at
    if ! load_pr_state_json "$pr_num"; then
        jq -n --arg issue "$PR_STATE_ERROR" '{can_merge: false, issues: [$issue], warnings: [], mergeable: "UNKNOWN", review: "", transient: false, state: "UNKNOWN", merged_at: "", head_runs: [], checks: [], required_contexts: []}'
        return 0 # Return 0 so JSON is output, caller checks can_merge
    fi
    pr_state=$(jq -r '.state // "UNKNOWN"' <<<"$PR_STATE_JSON")
    pr_merged_at=$(jq -r '.mergedAt // ""' <<<"$PR_STATE_JSON")

    # A terminal PR is unmergeable for a reason no caller can act on, and its
    # check data is meaningless: `mergeable` is permanently UNKNOWN, post-merge
    # CI runs and bot comments are not blockers. Report the state, no issues.
    if [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ]; then
        jq -n --arg state "$pr_state" --arg merged_at "$pr_merged_at" '{can_merge: false, issues: [], warnings: [], mergeable: "UNKNOWN", review: "", transient: false, state: $state, merged_at: $merged_at, head_runs: [], checks: [], required_contexts: []}'
        return 0
    fi

    local mergeable
    mergeable=$(gh pr view "$pr_num" --json mergeable --jq '.mergeable' 2>/dev/null || echo "UNKNOWN")
    if [ "$mergeable" = "MERGEABLE" ]; then
        : # ok
    elif [ "$mergeable" = "CONFLICTING" ]; then
        can_merge=false
        issues+=("conflicts: PR has merge conflicts. Resolve by rebasing onto your default branch and force-pushing")
    else
        can_merge=false
        issues+=("unknown: GitHub still computing mergeable status, await-mergeable then retry")
    fi

    # 2. Check CI status. The fetch tolerance (gh exit 8 with usable JSON)
    # lives with the shared fetch_checks_rollup.
    local ci_json
    if ! ci_json=$(fetch_checks_rollup "$pr_num"); then
        can_merge=false
        issues+=("ci_fetch_failed: Failed to fetch CI checks from GitHub")
    else
        # Drop checks belonging to superseded workflow runs before classifying,
        # so a prior canceled run can't be reported as a current merge blocker.
        # Mirrors orch ci-wait's pre-classification scoping; the shared
        # classify_checks_rollup carries the scoping and name-sanitization
        # contract, including the required contexts that registered no check.
        local rollup pending failed optional_failed
        required_json=$(required_contexts "$pr_num")
        rollup=$(echo "$ci_json" | classify_checks_rollup "$required_json")
        checks_json=$(jq -c '.checks' <<<"$rollup")
        head_runs_json=$(jq -c '.head_runs' <<<"$rollup")
        pending=$(jq -r '.pending' <<<"$rollup")
        failed=$(jq -r '.failed' <<<"$rollup")
        optional_failed=$(jq -r '.optional_failed' <<<"$rollup")
        # An empty rollup is "no status checks configured" only where the base
        # requires none. With a required context outstanding the checks ARE
        # configured and none has reported yet, which the classification
        # already names in `pending`.
        if [ "$(jq 'length' <<<"$ci_json")" -eq 0 ] && [ -z "$pending" ]; then
            warnings+=("ci_unconfigured: No status checks configured")
        fi
        if [ -n "$pending" ]; then
            can_merge=false
            issues+=("ci_pending: $pending")
        fi
        if [ -n "$failed" ]; then
            can_merge=false
            issues+=("ci_failed: $failed")
        fi
        # A warning, not an issue: the base branch does not require these, so
        # GitHub merges over them and so must this gate.
        if [ -n "$optional_failed" ]; then
            warnings+=("ci_optional_failed: $optional_failed")
        fi
    fi

    # 3. Check actionable review threads. GitHub does not protect merges on
    # unresolved conversations by default, so this is a local hard gate rather
# than a warning. Outdated threads do not refer to the current diff and
    # are not actionable. A failed or malformed lookup also blocks: treating an
    # unknown review state as clean would recreate the unsafe merge path.
    local threads_json unresolved
    # Fetch the complete unfiltered list. Filtering unresolved threads inside
    # pr-threads would discard nodes whose isResolved value is missing, null,
    # or malformed before this trust-boundary validation can reject them.
    if ! threads_json=$("$SCRIPT_DIR/pr-threads.sh" "$pr_num" 2>/dev/null); then
        can_merge=false
        issues+=("review_threads_fetch_failed: Failed to fetch actionable review threads from GitHub")
    elif ! jq -e '
        (.threads | type == "array") and
        all(.threads[];
            (.is_resolved | type == "boolean") and
            (.is_outdated | type == "boolean"))
    ' >/dev/null 2>&1 <<<"$threads_json"; then
        can_merge=false
        issues+=("review_threads_fetch_failed: GitHub returned malformed review thread data")
    else
        unresolved=$(jq '[.threads[] | select(.is_resolved == false and .is_outdated == false)] | length' <<<"$threads_json")
        if [ "$unresolved" -gt 0 ]; then
            can_merge=false
            issues+=("unresolved_threads: $unresolved actionable thread(s) need attention")
        fi
    fi

    # reviewDecision requires branch protection; latestReviews covers both terminal review states.
    local review="" has_approved_review=false has_changes_requested=false
    local review_json
    if ! review_json=$(json_or_default '{}' object gh pr view "$pr_num" --json reviewDecision,latestReviews); then
        can_merge=false
        issues+=("review_fetch_failed: Failed to fetch review status from GitHub")
    else
        review=$(echo "$review_json" | jq -r '.reviewDecision // ""')
        has_approved_review=$(echo "$review_json" | jq '[.latestReviews[] | select(.state == "APPROVED")] | length > 0')
        has_changes_requested=$(echo "$review_json" | jq '[.latestReviews[] | select(.state == "CHANGES_REQUESTED")] | length > 0')

        if [ "$review" = "CHANGES_REQUESTED" ] || [ "$has_changes_requested" = "true" ]; then
            can_merge=false
            issues+=("changes_requested: Reviewer requested changes")
        elif [ "$review" != "APPROVED" ] && [ "$has_approved_review" != "true" ]; then
            warnings+=("not_approved: Review status is '$review'")
        fi
    fi

    local issues_json warnings_json
    issues_json=$(printf '%s\n' "${issues[@]:-}" | jq -R -s -c 'split("\n") | map(select(. != ""))')
    warnings_json=$(printf '%s\n' "${warnings[@]:-}" | jq -R -s -c 'split("\n") | map(select(. != ""))')

    # Classify whether the blocking issues are entirely transient. A transient
    # block can be retried after `await-mergeable`; a permanent block needs
    # human action (fix conflicts, push CI fix, dismiss review).
    local transient
    transient=$(echo "$issues_json" | jq --arg p "^($TRANSIENT_PREFIXES)" '
        (length > 0) and (all(. | test($p)))
    ')

    jq -n \
        --argjson can_merge "$can_merge" \
        --argjson issues "$issues_json" \
        --argjson warnings "$warnings_json" \
        --arg mergeable "$mergeable" \
        --arg review "$review" \
        --argjson transient "$transient" \
        --arg state "$pr_state" \
        --arg merged_at "$pr_merged_at" \
        --argjson head_runs "$head_runs_json" \
        --argjson checks "$checks_json" \
        --argjson required_contexts "$required_json" \
        '{can_merge: $can_merge, issues: $issues, warnings: $warnings, mergeable: $mergeable, review: $review, transient: $transient, state: $state, merged_at: $merged_at, head_runs: $head_runs, checks: $checks, required_contexts: $required_contexts}'
}

print_blocked() {
    local check_result="$1"
    local pr_num="$2"
    local transient
    transient=$(echo "$check_result" | jq -r '.transient')

    echo "BLOCKED PR #$pr_num — no merge attempted, none queued" >&2
    if [ "$transient" = "true" ]; then
        echo "  (transient — GitHub still computing or CI pending)" >&2
    else
        echo "  (permanent — needs fix or review action)" >&2
    fi
    echo "$check_result" | jq -r '.issues[]' | sed 's/^/  ✗ /' >&2
    echo "$check_result" | jq -r '.warnings[]' | sed 's/^/  ⚠ /' >&2
    echo "" >&2
    if [ "$transient" = "true" ]; then
        echo "Hint: github.sh await-mergeable $pr_num && retry" >&2
    fi
    if echo "$check_result" | jq -e '[.issues[] | select(test("^(unresolved_threads|review_threads_fetch_failed):"))] | length > 0' >/dev/null 2>&1; then
        echo "Resolve the review-thread gate and retry. Use --force or --admin only after an explicit decision to override it." >&2
    else
        echo "Use --auto to queue for auto-merge, or --force after an explicit decision to override safety checks." >&2
    fi
}

# Run gh with the same effective identity used for the merge mutation. Keep the
# token scoped to the subprocess so the caller's environment is never changed.
gh_with_token() {
    local auth_token="${1:-}"
    shift

    if [ -n "$auth_token" ]; then
        GH_TOKEN="$auth_token" gh "$@"
    else
        gh "$@"
    fi
}

# Print what `gh pr merge --auto` would lack to wait on, or nothing. With
# auto-merge off, or no required check or review rule on the base branch,
# GitHub merges an armed PR at once. A failed read prints `unverified`.
merge_gate_gap() {
    local pr_num="$1" token="$2" allow="" base="" rules="" classic=""
    allow=$(gh_with_token "$token" api 'repos/{owner}/{repo}' --jq '.allow_auto_merge' 2>/dev/null) || allow=""
    case "$allow" in
        true) ;;
        false) echo allow_auto_merge; return 0 ;;
        *) echo unverified; return 0 ;;
    esac
    if ! base=$(gh_with_token "$token" pr view "$pr_num" --json baseRefName --jq '.baseRefName' 2>/dev/null) || [ -z "$base" ] \
        || ! base=$(jq -nr --arg v "$base" '$v | @uri') \
        || ! rules=$(gh_with_token "$token" api "repos/{owner}/{repo}/rules/branches/$base" --paginate --jq '.[] | select(.type == "required_status_checks" or .type == "pull_request") | .type' 2>/dev/null) \
        || ! classic=$(gh_with_token "$token" api "repos/{owner}/{repo}/branches/$base" --jq '.protection.required_status_checks | (.contexts // []) + (.checks // []) | length' 2>/dev/null); then
        echo unverified; return 0
    fi
    case "$classic" in '' | *[!0-9]*) echo unverified; return 0 ;; esac
    [ -n "$rules" ] || [ "$classic" -gt 0 ] || echo required_check
}

volatile_note() {
    local pr_num="$1" repo="${GH_REPO:-}" remote resolved reducer
    # pr-watch.sh requires GH_REPO; print the reducer with the repository it
    # will need. Resolved LOCALLY (env, else the origin remote) — no network
    # request may stand between a queued/armed PR and its exit 75. When
    # nothing local names it the placeholder keeps the shape and says so.
    local remote_name="origin"
    if [ -z "$repo" ]; then
        # gh's configured default (`gh repo set-default`) is stored as
        # remote.<name>.gh-resolved: an OWNER/REPO value names the repository
        # gh operates on when the checkout is a fork; "base" means that
        # remote's own repository — resolve that remote's URL, not origin's.
        resolved="$(git config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null | awk 'NF == 2 { print $1, $2; exit }' || true)"
        if [ -n "$resolved" ]; then
            if [ "${resolved##* }" = "base" ]; then
                remote_name="${resolved% *}"
                remote_name="${remote_name#remote.}"
                remote_name="${remote_name%.gh-resolved}"
            else
                repo="${resolved##* }"
            fi
        fi
    fi
    if [ -z "$repo" ]; then
        remote="$(git config --get "remote.$remote_name.url" 2>/dev/null || true)"
        case "$remote" in
            *github.com[:/]*/*)
                repo="${remote##*github.com[:/]}"
                repo="${repo%.git}"
                repo="${repo%/}"
                ;;
        esac
    fi
    # Only an OWNER/REPO-shaped value (one slash, plain segments) is printed
    # into a pasteable command.
    case "$repo" in
        */*/* | */ | /* | "" | *[!A-Za-z0-9._/-]*) repo="" ;;
        */*) ;;
        *) repo="" ;;
    esac
    echo "  NOTE: queue/auto-merge state is VOLATILE — an ejection or a failed protection check disarms it silently; follow orch merge-pr.md § 5 for PR #$pr_num" >&2
    local reducer="GH_REPO=$repo .agents/skills/review-gate/scripts/pr-watch.sh (disarmed lines)"
    [ -n "$repo" ] || reducer=".agents/skills/review-gate/scripts/pr-watch.sh with GH_REPO set to the repository (not resolvable locally here)"
    echo "  Block on .agents/skills/orch/scripts/queue-wait $pr_num --json once, with a poll interval and budget sized as orch merge-pr.md § 5 step 1 does; route its verdict by that same step, and never re-arm an unrecognized verdict. The fleet reducer is $reducer; repair what the cause names before re-arming with .agents/skills/github/scripts/github.sh pr-merge $pr_num --auto" >&2
}

post_merge_snapshot() {
    local pr_num="$1"
    local auth_token="$2"
    local snapshot=""

    if snapshot=$(gh_with_token "$auth_token" api graphql \
        -f query='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $number) { state headRefOid headRefName mergeCommit { oid } autoMergeRequest { enabledAt } isInMergeQueue mergeQueueEntry { state } } } }' \
        -F owner='{owner}' -F repo='{repo}' -F number="$pr_num" 2>/dev/null) && \
        jq -e '.data.repository.pullRequest != null' >/dev/null 2>&1 <<<"$snapshot"; then
        jq -c '
            .data.repository.pullRequest
            | {
                state: (.state // "UNKNOWN"),
                head: (.headRefOid // ""),
                head_branch: (.headRefName // ""),
                merge_commit: (.mergeCommit.oid // ""),
                auto_merge: (.autoMergeRequest != null),
                in_merge_queue: (.isInMergeQueue == true),
                merge_queue_entry: (.mergeQueueEntry != null),
                queue_state: (.mergeQueueEntry.state // ""),
                source: "graphql"
            }
        ' <<<"$snapshot"
        return 0
    fi

    if snapshot=$(gh_with_token "$auth_token" pr view "$pr_num" \
        --json state,headRefOid,headRefName,mergeCommit,autoMergeRequest 2>/dev/null) && \
        jq -e 'type == "object"' >/dev/null 2>&1 <<<"$snapshot"; then
        jq -c '
            {
                state: (.state // "UNKNOWN"),
                head: (.headRefOid // ""),
                head_branch: (.headRefName // ""),
                merge_commit: (.mergeCommit.oid // ""),
                auto_merge: (.autoMergeRequest != null),
                in_merge_queue: false,
                merge_queue_entry: false,
                queue_state: "",
                source: "pr-view-fallback"
            }
        ' <<<"$snapshot"
        return 0
    fi

    jq -cn '{state:"UNKNOWN",head:"",head_branch:"",merge_commit:"",auto_merge:false,in_merge_queue:false,merge_queue_entry:false,queue_state:"",source:"unavailable"}'
}

# --- the admin-credential route ----------------------------------------------
# The overseer's gated merge under the control host's owner credential. Each
# precondition writes its own verdict field, so the one record line the caller
# puts in the fleet log and in the PR's `## Merge decision` section says which
# condition decided the outcome. A field no condition reached stays `-`.
ADMIN_MERGE_DONE=false
ADMIN_PR=""
ADMIN_HEAD=""
ADMIN_ROUTE="-"
ADMIN_CLASS="-"
ADMIN_HEAD_MATCH="-"
ADMIN_REVIEW="-"
ADMIN_CHECKS="-"
ADMIN_BASE="-"
ADMIN_DEQUEUE="-"
ADMIN_REASON=""
ADMIN_CHECK_JSON=""
# The base head the containment check proved the PR contains, re-read just
# before the merge so a base that advanced in the dequeue-to-merge window is
# caught rather than merged behind.
ADMIN_BASE_SHA=""
# True once the merge itself has been issued, so an exit that cannot read the
# post-merge state records `unconfirmed` rather than a clean refusal. A dequeue
# or disarm that changed state is carried by ADMIN_DEQUEUE and ADMIN_CHANGED.
ADMIN_MUTATED=false
# Names what a mutation already changed when a later step fails, so a
# post-mutation refusal does not print the pre-mutation reassurance below.
ADMIN_CHANGED=""
# The post-merge snapshot's source, so an outcome that could not be read
# (`unavailable`) is recorded distinctly from a confirmed non-merge.
ADMIN_POST_SOURCE=""

admin_refuse() {
    ADMIN_REASON="$1"
    shift
    echo "REFUSED PR #$ADMIN_PR — $*" >&2
    if [ -n "$ADMIN_CHANGED" ]; then
        echo "  $ADMIN_CHANGED" >&2
    else
        echo "  Nothing dequeued, nothing merged." >&2
    fi
}

# Emitted from the EXIT trap, so every path out of the route — a refusal, a
# terminal state, a failed or unconfirmed mutation, a queue enrollment — leaves
# exactly one record. The verdict word carries the outcome the exit code alone
# cannot: `unconfirmed` where a merge ran but its result could not be read, and
# `enrolled` where GitHub queued or armed the PR instead of merging it.
admin_emit_record() {
    local status="$1" verdict reason="$ADMIN_REASON"
    case "$status" in
    0)
        if [ "$ADMIN_MERGE_DONE" = true ]; then verdict=merged; else verdict=already-merged; fi
        reason=""
        ;;
    75)
        verdict=enrolled
        reason=""
        ;;
    *)
        if [ "$ADMIN_MUTATED" = true ] && [ "$ADMIN_MERGE_DONE" != true ] \
            && [ "$ADMIN_POST_SOURCE" = unavailable ]; then
            verdict=unconfirmed
            [ -n "$reason" ] || reason=merge-outcome-unconfirmed
        else
            verdict=refused
            [ -n "$reason" ] || reason=blocked
        fi
        ;;
    esac
    printf 'admin-merge %s pr=%s head=%s route=%s class=%s head-match=%s review=%s checks=%s base=%s dequeue=%s%s\n' \
        "$verdict" "$ADMIN_PR" "$ADMIN_HEAD" "$ADMIN_ROUTE" "$ADMIN_CLASS" \
        "$ADMIN_HEAD_MATCH" "$ADMIN_REVIEW" "$ADMIN_CHECKS" "$ADMIN_BASE" "$ADMIN_DEQUEUE" \
        "${reason:+ reason=$reason}"
}

# The change class, from the classifier and from nothing else. A flag, a label,
# a branch name and a PR title are writable by the pull request's author, so a
# class read from one fails open on exactly the diffs that most want to pass.
admin_change_class() {
    local base_sha="$1" head_sha="$2" classifier="$SCRIPT_DIR/../../../harness-ci/scripts/change-class"
    if [ ! -x "$classifier" ]; then
        classifier=$(command -v change-class 2>/dev/null) || classifier=""
    fi
    [ -n "$classifier" ] || return 1
    # Drop the owner credential's gh config directory for the child: the
    # classifier may call gh, and the route promises the credential is never
    # passed on. Every other gh call in the route still runs under it.
    env -u GH_CONFIG_DIR "$classifier" --base "$base_sha" --head "$head_sha" 2>/dev/null
}

# The PR's node id beside the two merge-state facts a dequeue acts on.
admin_queue_snapshot() {
    local pr_num="$1" resp
    resp=$(gh api graphql \
        -f query='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $number) { id isInMergeQueue autoMergeRequest { enabledAt } } } }' \
        -F owner='{owner}' -F repo='{repo}' -F number="$pr_num" 2>/dev/null) || return 1
    jq -e -c '.data.repository.pullRequest | select(. != null)
        | {id: (.id // ""), in_queue: (.isInMergeQueue == true), auto: (.autoMergeRequest != null)}' <<<"$resp"
}

# Disarm before dequeuing, in merge-pr-restack.md step 1's order: an armed PR
# re-enters the queue the moment its requirements go green, so a bare dequeue
# can be raced straight back in. Once the disarm lands, a later failure records
# `disarmed` (not `failed`) and its refusal names that half as done, so the
# caller does not read a partially-changed PR as untouched.
admin_dequeue() {
    local pr_num="$1" snap node_id in_queue auto disarmed=false
    if ! snap=$(admin_queue_snapshot "$pr_num"); then
        ADMIN_DEQUEUE=unreadable
        admin_refuse queue-unreadable "the PR's merge-queue state could not be read"
        return 1
    fi
    if ! node_id=$(jq -r '.id' <<<"$snap") \
        || ! in_queue=$(jq -r '.in_queue' <<<"$snap") \
        || ! auto=$(jq -r '.auto' <<<"$snap"); then
        ADMIN_DEQUEUE=unreadable
        admin_refuse queue-unreadable "the merge-queue snapshot could not be parsed"
        return 1
    fi

    if [ "$in_queue" != true ] && [ "$auto" != true ]; then
        ADMIN_DEQUEUE=none
        return 0
    fi
    if [ -z "$node_id" ]; then
        ADMIN_DEQUEUE=failed
        admin_refuse dequeue-failed "the PR is queued or armed and GitHub returned no node id to dequeue it by"
        return 1
    fi
    if [ "$auto" = true ]; then
        if ! kendex_merge_queue_mutation disablePullRequestAutoMerge "$node_id" >/dev/null; then
            ADMIN_DEQUEUE=failed
            admin_refuse dequeue-failed "disablePullRequestAutoMerge failed"
            return 1
        fi
        disarmed=true
        ADMIN_CHANGED="Auto-merge was disarmed, but the PR was not dequeued and not merged."
    fi
    if [ "$in_queue" = true ]; then
        if ! kendex_merge_queue_mutation dequeuePullRequest "$node_id" >/dev/null; then
            [ "$disarmed" = true ] && ADMIN_DEQUEUE=disarmed || ADMIN_DEQUEUE=failed
            admin_refuse dequeue-failed "dequeuePullRequest failed"
            return 1
        fi
    fi
    if ! snap=$(admin_queue_snapshot "$pr_num"); then
        [ "$disarmed" = true ] && ADMIN_DEQUEUE=disarmed || ADMIN_DEQUEUE=failed
        admin_refuse dequeue-failed "the merge-queue state could not be re-read after the dequeue"
        return 1
    fi
    if [ "$(jq -r '.in_queue' <<<"$snap")" = true ] || [ "$(jq -r '.auto' <<<"$snap")" = true ]; then
        [ "$disarmed" = true ] && ADMIN_DEQUEUE=disarmed || ADMIN_DEQUEUE=failed
        admin_refuse dequeue-failed "the PR is still queued or armed after the dequeue"
        return 1
    fi
    ADMIN_DEQUEUE=done
    # The dequeue landed; a later refusal (a base that moved before the merge)
    # must name that change rather than the pre-mutation reassurance.
    ADMIN_CHANGED="The PR was dequeued but not merged."
}

# The base branch's required status-check contexts, from the same ruleset and
# classic-protection reads merge_gate_gap performs. A read failure returns
# nonzero, so the route refuses rather than treating a missing list as empty:
# --admin would otherwise bypass a protection this route never proved. Emits a
# JSON array of context names.
admin_required_contexts() {
    local base_branch="$1" base_enc rule_ctx classic_ctx
    base_enc=$(jq -nr --arg v "$base_branch" '$v | @uri') || return 1
    rule_ctx=$(gh api "repos/{owner}/{repo}/rules/branches/$base_enc" --paginate \
        --jq '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context' 2>/dev/null) || return 1
    classic_ctx=$(gh api "repos/{owner}/{repo}/branches/$base_enc" \
        --jq '.protection.required_status_checks | ((.contexts // []) + ((.checks // []) | map(.context))) | .[]' 2>/dev/null) || return 1
    printf '%s\n%s\n' "$rule_ctx" "$classic_ctx" | jq -R -s -c 'split("\n") | map(select(. != "")) | unique'
}

# The route's own precondition, answered before any GitHub call: a refused
# route reads nothing, and a live one reads everything as the owner credential.
admin_open_route() {
    local config_dir="${ORCH_ADMIN_MERGE_GH_CONFIG_DIR:-}"
    if [ -z "$config_dir" ]; then
        ADMIN_ROUTE=off
        admin_refuse route-off "the admin-credential route is off: ORCH_ADMIN_MERGE_GH_CONFIG_DIR is empty"
        return 1
    fi
    if [ ! -d "$config_dir" ]; then
        ADMIN_ROUTE=off
        admin_refuse no-config-dir "ORCH_ADMIN_MERGE_GH_CONFIG_DIR is not a directory here, so this is not the control host"
        return 1
    fi
    ADMIN_ROUTE=on
    # Every call from here, and the merge itself, acts as the owner credential
    # in that directory. A token inherited from a lane would otherwise win.
    export GH_CONFIG_DIR="$config_dir"
    unset GH_TOKEN GITHUB_TOKEN
}

# Every condition on the exact head, before any mutation. A refusal here leaves
# the PR exactly as it was.
admin_preflight() {
    local pr_num="$1" expected="$2"
    local classes="${ORCH_ADMIN_MERGE_CLASSES:-}"

    # GitHub returns the head and the base from one request, so the head-match
    # condition is evaluated from that payload before the base fields are read
    # out of it.
    local pr_json current_head base_branch base_sha
    if ! pr_json=$(gh pr view "$pr_num" --json headRefOid,baseRefName,baseRefOid 2>/dev/null) \
        || ! current_head=$(jq -r '.headRefOid // ""' <<<"$pr_json") || [ -z "$current_head" ]; then
        ADMIN_HEAD_MATCH=unreadable
        admin_refuse head-unreadable "the live head SHA could not be resolved"
        return 1
    fi
    if [ "$current_head" != "$expected" ]; then
        ADMIN_HEAD_MATCH=moved
        admin_refuse head-moved "the head moved (expected=$expected, actual=$current_head)"
        return 1
    fi
    ADMIN_HEAD_MATCH=ok

    if ! base_sha=$(jq -r '.baseRefOid // ""' <<<"$pr_json") || [ -z "$base_sha" ]; then
        ADMIN_BASE=unreadable
        admin_refuse base-unreadable "the base branch head could not be resolved"
        return 1
    fi
    base_branch=$(jq -r '.baseRefName // ""' <<<"$pr_json")

    if [ -z "$classes" ]; then
        ADMIN_CLASS=any
    else
        local class=""
        if ! class=$(admin_change_class "$base_sha" "$expected") || [ -z "$class" ]; then
            ADMIN_CLASS=unreadable
            admin_refuse class-unreadable "ORCH_ADMIN_MERGE_CLASSES is set and no change classifier answered"
            return 1
        fi
        ADMIN_CLASS="$class"
        case ",$(printf '%s' "$classes" | tr ' ' ',')," in
        *",$class,"*) ;;
        *)
            admin_refuse class-not-allowed "class $class is outside ORCH_ADMIN_MERGE_CLASSES=$classes"
            return 1
            ;;
        esac
    fi

    local issues state
    ADMIN_CHECK_JSON=$(run_checks "$pr_num")
    if [ "$(jq -r '.can_merge' <<<"$ADMIN_CHECK_JSON")" != true ]; then
        if ! ADMIN_CHECKS=$(jq -r '[.issues[] | split(":")[0]] | join(",")' <<<"$ADMIN_CHECK_JSON") \
            || ! issues=$(jq -r '.issues | join("; ")' <<<"$ADMIN_CHECK_JSON") \
            || ! state=$(jq -r '.state' <<<"$ADMIN_CHECK_JSON"); then
            ADMIN_CHECKS=unreadable
            admin_refuse checks-unreadable "the readiness check result could not be parsed"
            return 1
        fi
        # An empty issue list with can_merge false means the PR left OPEN
        # between the state lookup above and this read.
        if [ -z "$ADMIN_CHECKS" ]; then
            ADMIN_CHECKS="state=$state"
            issues="the PR is no longer open (state=$state)"
        fi
        admin_refuse checks-unmet "the readiness check does not pass: $issues"
        return 1
    fi
    ADMIN_CHECKS=ok

    # The route merges with `--admin`, which bypasses branch protection, so it
    # re-checks server-side readiness itself: the two gates run_checks leaves as
    # warnings, and every required context green on this exact head. A required
    # context that never reported is neither pending nor failed above, so the
    # rollup's silence is not readiness.
    local warn_keys
    warn_keys=$(jq -r '[.warnings[]? | split(":")[0]] | join(" ")' <<<"$ADMIN_CHECK_JSON") || warn_keys=""
    case " $warn_keys " in
    *" not_approved "*)
        ADMIN_REVIEW=required
        admin_refuse review-required "the review gate is not met: $(jq -r '[.warnings[] | select(startswith("not_approved:"))] | join("; ")' <<<"$ADMIN_CHECK_JSON")"
        return 1
        ;;
    esac
    ADMIN_REVIEW=ok
    case " $warn_keys " in
    *" ci_unconfigured "*)
        ADMIN_CHECKS=ci_unconfigured
        admin_refuse checks-unmet "no status checks are configured, so no required context can be proven green"
        return 1
        ;;
    esac

    local required checks_rollup missing
    if ! required=$(admin_required_contexts "$base_branch"); then
        ADMIN_CHECKS=contexts-unreadable
        admin_refuse checks-unreadable "the base branch's required contexts could not be read"
        return 1
    fi
    checks_rollup=$(jq -c '.checks' <<<"$ADMIN_CHECK_JSON")
    if ! missing=$(jq -rn --argjson req "$required" --argjson checks "$checks_rollup" '
        [ $req[] | select( . as $n | ([$checks[]? | select(.name == $n and (.bucket == "pass" or .bucket == "skipping"))] | length) == 0 ) ] | join(", ")
    '); then
        ADMIN_CHECKS=contexts-unreadable
        admin_refuse checks-unreadable "the base branch's required contexts could not be evaluated against this head"
        return 1
    fi
    if [ -n "$missing" ]; then
        ADMIN_CHECKS=missing-context
        admin_refuse checks-unmet "required context(s) not green on this head: $missing"
        return 1
    fi

    # `--match-head-commit` pins the PR head alone, and GitHub's `mergeable`
    # field never reports a branch behind its base, so base containment is its
    # own read: the compare endpoint answers it for a head this host has no
    # checkout of.
    local behind
    if ! behind=$(gh api "repos/{owner}/{repo}/compare/$base_sha...$expected" --jq '.behind_by' 2>/dev/null); then
        ADMIN_BASE=unreadable
        admin_refuse base-unreadable "the compare endpoint did not answer, so base containment is unproven"
        return 1
    fi
    case "$behind" in
    '' | *[!0-9]*)
        ADMIN_BASE=unreadable
        admin_refuse base-unreadable "the compare endpoint answered '$behind', not a commit count"
        return 1
        ;;
    esac
    if [ "$behind" -gt 0 ]; then
        ADMIN_BASE="behind=$behind"
        admin_refuse base-stale "the head is $behind commit(s) behind $base_branch"
        return 1
    fi
    ADMIN_BASE=fresh
    ADMIN_BASE_SHA="$base_sha"

    admin_dequeue "$pr_num"
}

main() {
    local pr_num="" method="--squash" delete_branch=true
    local check_only=false force=false admin=false dry_run=false auto=false supplied_head=""
    local admin_credential=false

    while [ $# -gt 0 ]; do
        case "$1" in
        --squash)
            method="--squash"
            shift
            ;;
        --merge)
            method="--merge"
            shift
            ;;
        --rebase)
            method="--rebase"
            shift
            ;;
        --delete-branch)
            delete_branch=true
            shift
            ;;
        --keep-branch)
            delete_branch=false
            shift
            ;;
        --check)
            check_only=true
            shift
            ;;
        --force) force=true; shift ;;
        --admin) admin=true; force=true; shift ;;
        --admin-credential) admin_credential=true; shift ;;
        --auto)
            auto=true
            shift
            ;;
        --expected-head) supplied_head="${2:-}"; shift 2 ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        --help | -h)
            show_help
            exit 0
            ;;
        [0-9]*)
            pr_num="$1"
            shift
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            exit 1
            ;;
        esac
    done

    if [ "$force" = true ] && [ "$auto" = true ]; then
        echo "Error: --force/--admin and --auto cannot be combined; overrides are immediate-only" >&2
        exit 1
    fi

    if [ -z "$pr_num" ]; then
        echo '{"error": "PR number required"}' >&2
        exit 1
    fi
    [ "$admin" = false ] || unset GH_TOKEN GITHUB_TOKEN
    if [ -n "$supplied_head" ] && ! [[ "$supplied_head" =~ ^[0-9a-fA-F]{40}$ ]]; then
        echo "Error: --expected-head must be a 40-character commit SHA" >&2; exit 1
    fi

    if [ "$admin_credential" = true ]; then
        if [ "$check_only" = true ] || [ "$auto" = true ] || [ "$force" = true ] || [ "$dry_run" = true ]; then
            echo "Error: --admin-credential checks every merge condition and merges immediately; it cannot be combined with --check, --auto, --force, --admin or --dry-run" >&2
            exit 1
        fi
        if [ -z "$supplied_head" ]; then
            echo "Error: --admin-credential requires --expected-head" >&2
            exit 1
        fi
        ADMIN_PR="$pr_num"
        ADMIN_HEAD="$supplied_head"
        trap 'admin_emit_record "$?"' EXIT
        admin_open_route || exit 1
    fi

    if [ "$check_only" = true ]; then
        local check_json
        check_json=$(run_checks "$pr_num")
        printf '%s\n' "$check_json"
        check_verdict_lines <<<"$check_json" >&2
        exit 0
    fi

    if load_pr_state_json "$pr_num"; then
        # A merged PR keeps its head SHA, so the admin route compares it here
        # rather than record already-merged with head-match unread.
        if [ "$admin_credential" = true ] && [ "$(jq -r '.state // ""' <<<"$PR_STATE_JSON")" = "MERGED" ]; then
            local merged_head
            if merged_head=$(gh pr view "$pr_num" --json headRefOid --jq '.headRefOid' 2>/dev/null) && [ -n "$merged_head" ]; then
                [ "$merged_head" = "$supplied_head" ] && ADMIN_HEAD_MATCH=ok || ADMIN_HEAD_MATCH=moved
            fi
        fi
        exit_terminal_state \
            "$(jq -r '.state // ""' <<<"$PR_STATE_JSON")" \
            "$pr_num" \
            "$(jq -r '.mergedAt // ""' <<<"$PR_STATE_JSON")"
    fi

    # The admin-credential route acts as the owner credential in its own gh
    # config directory, so it loads no bot token and promotes none.
    local selection=""
    [ "$admin" = true ] || [ "$admin_credential" = true ] || selection=$(load_bot_token)
    local token="${selection#*=}" token_source="${selection%%=*}"

    if [ "$admin_credential" = true ]; then
        admin_preflight "$pr_num" "$supplied_head" || exit 1
    fi

    local check_result=""
    if [ "$force" = false ]; then
        local can_merge checked_state checked_merged_at
        if [ -n "$ADMIN_CHECK_JSON" ]; then
            check_result="$ADMIN_CHECK_JSON"
        else
            check_result=$(run_checks "$pr_num")
        fi

        # The checks re-read a state the up-front lookup could not resolve, so
        # a PR that is terminal by now must be reported here too. Otherwise
        # `--auto`, which defers every non-thread blocker, arms a merge on a PR
        # that has already left OPEN.
        checked_state=$(echo "$check_result" | jq -r '.state // ""')
        checked_merged_at=$(echo "$check_result" | jq -r '.merged_at // ""')
        exit_terminal_state "$checked_state" "$pr_num" "$checked_merged_at"

        can_merge=$(echo "$check_result" | jq -r '.can_merge')

        if [ "$can_merge" != "true" ]; then
            # `--auto` may defer GitHub-enforced blockers, but it must never
            # bypass local review-thread safety. GitHub can otherwise accept
            # and immediately merge a PR whose conversations remain open.
            local has_review_thread_gate
            has_review_thread_gate=$(echo "$check_result" | jq '[.issues[] | select(test("^(unresolved_threads|review_threads_fetch_failed):"))] | length > 0')

            if [ "$auto" != true ] || [ "$has_review_thread_gate" = "true" ]; then
                print_blocked "$check_result" "$pr_num"
                exit 1
            fi
        fi

        # Before any other stderr: callers route on this refusal's first line.
        local gate_gap slug
        [ "$auto" = false ] || [ "$dry_run" = true ] || gate_gap=$(merge_gate_gap "$pr_num" "$token")
        if [ -n "${gate_gap:-}" ]; then
            slug=$(kendex_github_resolve_gh_repo "${PROJECT_ROOT:-$PWD}" 2>/dev/null) || slug=unresolved
            echo "arm: no-merge-gate=$gate_gap repo=$slug" >&2
            echo "  Nothing mutated. Enable auto-merge and a required status check or review rule on the base branch, or merge through orch merge-pr with the explicit consumer-only answer under submit-pr.md § 6.2." >&2
            exit 1
        fi

        local warnings
        warnings=$(echo "$check_result" | jq -r '.warnings | length')
        if [ "$warnings" -gt 0 ]; then
            echo "Warnings:" >&2
            echo "$check_result" | jq -r '.warnings[]' | sed 's/^/  ⚠ /' >&2
        fi
    else
        if [ "$admin" = true ]; then echo "⚠ current-user admin mode: Skipping safety checks" >&2; else echo "⚠ override: Skipping safety checks" >&2; fi
    fi

    if [ "$dry_run" = true ]; then
        local token_status="not configured"
        [ -n "$token" ] && token_status="configured"
        [ "$admin" = false ] || token_status="current-user admin mode"
        local mode="immediate"
        [ "$auto" = true ] && mode="auto-merge fallback"
        echo "Would merge PR #$pr_num ($method, mode=$mode, delete_branch=$delete_branch, token=$token_status)"
        exit 0
    fi

    # Resolve and guard the exact head before mutating merge state. This prevents
    # a review/CI race from queuing or merging a newer, unverified commit.
    local expected_head current_head
    if ! current_head=$(gh_with_token "$token" pr view "$pr_num" --json headRefOid --jq '.headRefOid' 2>/dev/null) || [ -z "$current_head" ]; then
        echo "BLOCKED PR #$pr_num — could not resolve exact head SHA for guarded merge" >&2
        exit 1
    fi
    expected_head="${supplied_head:-$current_head}"
    if [ "$current_head" != "$expected_head" ]; then
        echo "BLOCKED PR #$pr_num — prepared head changed before merge attempt (expected=$expected_head, actual=$current_head)" >&2; exit 1
    fi

    # The admin route dequeued and bypasses the queue, so a concurrent admin or
    # queue merge can advance the base between the containment check and here.
    # --match-head-commit pins the head, not the base, so re-read the base head
    # right before the merge and refuse a base that moved since the check.
    if [ "$admin_credential" = true ]; then
        local live_base_json live_base
        if ! live_base_json=$(gh pr view "$pr_num" --json baseRefName,baseRefOid 2>/dev/null) \
            || ! live_base=$(jq -r '.baseRefOid // ""' <<<"$live_base_json") || [ -z "$live_base" ]; then
            ADMIN_BASE=unreadable
            admin_refuse base-unreadable "the base head could not be re-read before the merge"
            exit 1
        fi
        if [ "$live_base" != "$ADMIN_BASE_SHA" ]; then
            ADMIN_BASE=moved
            admin_refuse base-moved "the base advanced after the containment check (checked=$ADMIN_BASE_SHA, now=$live_base)"
            exit 1
        fi
    fi

    local -a cmd=(pr merge "$pr_num" "$method" --match-head-commit "$expected_head")
    [ "$auto" = true ] && cmd+=(--auto)
    { [ "$admin" = true ] || [ "$admin_credential" = true ]; } && cmd+=(--admin)

    # From here the merge is issued: a later admin refusal must not claim the PR
    # was untouched, and an unreadable post-state must record `unconfirmed`.
    ADMIN_MUTATED=true
    local merge_output merge_exit=0
    if [ -n "$token" ]; then
        local identity
        identity=$(kendex_github_token_identity "$token")
        echo "Using $token_source as $identity" >&2
        merge_output=$(gh_with_token "$token" "${cmd[@]}" 2>&1) || merge_exit=$?
    else
        [ "$admin" = true ] || [ "$admin_credential" = true ] || echo "Warning: GH_BOT_TOKEN not configured, using current user" >&2
        merge_output=$(gh_with_token "" "${cmd[@]}" 2>&1) || merge_exit=$?
    fi

    # The post-call snapshot decides queue enrollment. gh can exit either way,
    # and its already-queued stderr is version-dependent.
    local post_snapshot post_state post_auto post_head post_in_queue post_queue_entry post_queue_state
    post_snapshot=$(post_merge_snapshot "$pr_num" "$token")
    ADMIN_POST_SOURCE=$(jq -r '.source // ""' <<<"$post_snapshot")
    post_state=$(jq -r '.state' <<<"$post_snapshot")
    post_auto=$(jq -r '.auto_merge' <<<"$post_snapshot")
    post_head=$(jq -r '.head' <<<"$post_snapshot")
    post_in_queue=$(jq -r '.in_merge_queue' <<<"$post_snapshot")
    post_queue_entry=$(jq -r '.merge_queue_entry' <<<"$post_snapshot")
    post_queue_state=$(jq -r '.queue_state' <<<"$post_snapshot")

    # The mutation itself was match-head guarded. Also reject a post-call
    # snapshot that belongs to a different head instead of crediting its queue
    # or auto-merge state to the commit we attempted.
    if [ -n "$post_head" ] && [ "$post_head" != "$expected_head" ]; then
        echo "BLOCKED PR #$pr_num — head changed during merge attempt (expected=$expected_head, actual=$post_head)" >&2
        exit 1
    fi

    # A NONZERO `gh pr merge` exit is only benign outside `--force` when the
    # authoritative snapshot proves a real success state: an already-enrolled
    # merge queue entry, classic auto-merge already enabled, or an
    # already merged PR. Anything else — conflicts, auth failure, CI, no
    # enrollment — leaves no such proof and stays BLOCKED with the raw gh
    # output. When the snapshot does prove success, fall through to the shared
    # classification below so the outcome (MERGED / QUEUED / AUTO-MERGE) is
    # reported once.
    # `--force` promises an immediate mutation, so pre-existing pending state
    # must never convert its failed mutation into success. An
    # exact-head MERGED snapshot remains authoritative even if the CLI returned
    # nonzero after the server completed the merge.
    if [ "$merge_exit" -ne 0 ] \
        && [ "$post_state" != "MERGED" ] \
        && { [ "$force" = true ] \
            || { [ "$post_in_queue" != "true" ] \
                && [ "$post_queue_entry" != "true" ] \
                && [ "$post_auto" != "true" ]; }; }; then
        echo "BLOCKED PR #$pr_num — gh pr merge failed" >&2
        printf '%s\n' "$merge_output" | sed 's/^/  /' >&2
        exit 1
    fi

    if [ "$post_state" = "MERGED" ]; then
        ADMIN_MERGE_DONE=true
        echo "MERGED PR #$pr_num" >&2
        # Delete remote branch via API (avoids gh's local git checkout, which
        # fails inside worktrees). Best-effort — branch may already be gone.
        if [ "$delete_branch" = true ]; then
            local branch
            branch=$(jq -r '.head_branch' <<<"$post_snapshot")
            if [ -n "$branch" ]; then
                gh_with_token "$token" api -X DELETE "repos/{owner}/{repo}/git/refs/heads/$branch" 2>/dev/null || true
            fi
        fi
        exit 0
    fi

    if [ "$post_in_queue" = "true" ] || [ "$post_queue_entry" = "true" ]; then
        echo "QUEUED IN MERGE QUEUE PR #$pr_num — queueState=${post_queue_state:-active}" >&2
        volatile_note "$pr_num"
        exit 75
    fi

    if [ "$post_auto" = "true" ]; then
        echo "AUTO-MERGE ENABLED PR #$pr_num — will fire when CI + branch protection clear" >&2
        volatile_note "$pr_num"
        exit 75
    fi

    # gh exited 0 but PR isn't merged and isn't queued. Treat as BLOCKED so
    # callers don't assume success based on exit code alone.
    echo "BLOCKED PR #$pr_num — gh reported success but state=$post_state, autoMerge=$post_auto, mergeQueue=false" >&2
    printf '%s\n' "$merge_output" | sed 's/^/  /' >&2
    exit 1
}

main "$@"
