#!/usr/bin/env bash
# Review-gate predicate — the single source of truth for "is this PR head
# reviewed?". Shipped by the vstack review-gate skill and vendored into
# consumers at .agents/skills/review-gate/scripts/. Callers: the repo's CI
# gate job (posts the merge-blocking commit status from the verdict) and
# approval-refire.sh (converges the status when review state changes).
#
# Predicate: review evidence present for the CURRENT head — any of
#   (a) a review OBJECT at the exact head from a non-author, non-dismissed,
#       trusted login (trust list empty = any non-author);
#   (b) a trusted clean-analysis CHECK-RUN or legacy COMMIT STATUS succeeding
#       on this head, whose title/summary/description carries no
#       skip-pattern marker (a "pass" that says the analysis was rate
#       limited, skipped or queued proves nothing ran — it is silence, not
#       approval, and routes to NOT-EVIDENCE, never to failure);
#   (c) a trusted comment-form clean pass: an issue comment by a trusted bot
#       login whose body binds the evidence to this head's sha;
#   (d) the trusted reviewer-outage attestation status — substitutes for
#       MISSING evidence only;
# AND no changes-requested against the head AND zero unresolved review
# threads. Changes-requested and unresolved threads always fail closed, even
# with evidence present.
#
# APPROVAL IS NEVER SUPERSEDED BY A LATER COMMENT. The evidence reduction is
# "an accepted review row exists at head" — never "the latest review per
# reviewer" — so a reviewer that posts APPROVED and then a trailing COMMENTED
# on the same commit still counts as approval. Only a LATER
# CHANGES_REQUESTED from the same login withdraws it (and the separate
# changes-requested term fails the gate then anyway). The selftest pins this.
#
# TRUST MODEL: trust keys on NAMES ONLY GITHUB CONTROLS — the author login of
# a review or comment (exact match on the app's bot login) or the exact
# context/name of a check/status on repos where every publisher is trusted. A
# comment BODY is never trusted to establish trust; it is read only to BIND
# the evidence to a specific commit, so a stale comment cannot vouch for a
# later push.
#
# Per-repo trust configuration comes from REVIEW_GATE_* settings — explicit
# environment first, then the repo's vstack.settings.toml, then built-in
# defaults (lib/settings.sh). Keys read here:
#   REVIEW_GATE_TRUSTED_STATUS_CONTEXTS       (b) check/status names, ';'-separated
#   REVIEW_GATE_CHECKRUN_SKIP_PATTERNS        (b) pass-without-analysis markers, ';'-separated,
#                                             case-insensitive substrings; empty disables
#   REVIEW_GATE_COMMENT_REVIEWERS             (c) 'login:binding-pattern' pairs, ';'-separated
#                                             (first ':' splits; pattern is a literal prefix)
#   REVIEW_GATE_SHA_PREFIX_FLOOR              (c) shortest sha prefix a comment may bind
#   REVIEW_GATE_OUTAGE_CONTEXT                (d) attestation status context; empty disables
#   REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS  (a) trust list; empty = any non-author
#   REVIEW_GATE_REVIEW_OBJECT_MIN_STATE       (a) "any" (any review row) or "approved"
#                                             (an APPROVED row not withdrawn by a later
#                                             CHANGES_REQUESTED from the same login)
#
# Env (required): GH_TOKEN (or ambient gh auth), GH_REPO, PR_NUMBER, HEAD_SHA
# Env (optional): PR_AUTHOR — resolved from the PR when empty.
#
# Output: one machine-readable line on stdout:
#   verdict=approved|awaiting|threads-open|changes-requested detail=<human text>
# (diagnostic detail also echoed for logs). Exit codes:
#   0 — evaluated (verdict line is authoritative)
#   2 — an evidence read failed or the configuration is invalid; NO verdict
#       was reached. Callers must treat this as "take no action", never as
#       awaiting: acting on a transient API failure could flip a healthy PR's
#       merge state.
set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/lib/settings.sh"

# `|| exit 2`: rg_setting fails on a present-but-unparseable assignment, and
# that is a configuration error (no verdict), never an empty value.
TRUSTED_CONTEXTS="$(rg_setting REVIEW_GATE_TRUSTED_STATUS_CONTEXTS "Devin Review")" || exit 2
SKIP_PATTERNS="$(rg_setting REVIEW_GATE_CHECKRUN_SKIP_PATTERNS "rate limited;skipped;queued")" || exit 2
COMMENT_REVIEWERS="$(rg_setting REVIEW_GATE_COMMENT_REVIEWERS "")" || exit 2
SHA_FLOOR="$(rg_setting REVIEW_GATE_SHA_PREFIX_FLOOR "7")" || exit 2
OUTAGE_CONTEXT="$(rg_setting REVIEW_GATE_OUTAGE_CONTEXT "vstack-reviewer-outage")" || exit 2
TRUSTED_LOGINS="$(rg_setting REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS "")" || exit 2
MIN_STATE="$(rg_setting REVIEW_GATE_REVIEW_OBJECT_MIN_STATE "any")" || exit 2

# Configuration errors are exit 2 (no verdict), same contract as a failed
# evidence read: a typo in trust config must never quietly widen or narrow
# the gate.
case "$SHA_FLOOR" in
  ''|*[!0-9]*)
    echo "::error::review-predicate: REVIEW_GATE_SHA_PREFIX_FLOOR must be an integer, got '$SHA_FLOOR'" >&2
    exit 2
    ;;
esac
if [ "$SHA_FLOOR" -lt 4 ] || [ "$SHA_FLOOR" -gt 40 ]; then
  echo "::error::review-predicate: REVIEW_GATE_SHA_PREFIX_FLOOR must be 4..40, got '$SHA_FLOOR'" >&2
  exit 2
fi
case "$MIN_STATE" in
  any|approved) ;;
  *)
    echo "::error::review-predicate: REVIEW_GATE_REVIEW_OBJECT_MIN_STATE must be 'any' or 'approved', got '$MIN_STATE'" >&2
    exit 2
    ;;
esac

for required in GH_REPO PR_NUMBER HEAD_SHA; do
  if [ -z "$(eval "echo \${$required:-}")" ]; then
    echo "::error::review-predicate: $required is required" >&2
    exit 2
  fi
done

if [ -z "${PR_AUTHOR:-}" ]; then
  PR_AUTHOR="$(gh api "repos/$GH_REPO/pulls/$PR_NUMBER" --jq .user.login)" || {
    echo "::error::could not resolve PR #$PR_NUMBER author" >&2
    exit 2
  }
fi

# Two steps, not a pipe: `--paginate` emits ONE ARRAY PER PAGE, which the
# count filters below would evaluate per-array (multi-line counts that can
# never equal "0" past 100 reviews), and a mid-pipe gh failure must fail
# loudly rather than hand jq a truncated page set.
raw_reviews="$(gh api "repos/$GH_REPO/pulls/$PR_NUMBER/reviews" --paginate)" || {
  echo "::error::could not read reviews for PR #$PR_NUMBER" >&2
  exit 2
}
reviews="$(jq -s 'add // []' <<<"$raw_reviews")" || {
  echo "::error::could not parse reviews for PR #$PR_NUMBER" >&2
  exit 2
}
# Changes-requested counts only each reviewer's LATEST non-dismissed review on
# the head, so a superseded CR that the same reviewer later cleared can't pin
# the PR red forever. Deliberately unfiltered by the trust list: anyone's
# standing objection fails the gate closed.
cr="$(jq --arg sha "$HEAD_SHA" '[.[] | select(.commit_id == $sha and .state != "DISMISSED")] | group_by(.user.login) | map(.[-1]) | map(select(.state == "CHANGES_REQUESTED")) | length' <<<"$reviews")" || {
  echo "::error::could not evaluate changes-requested reviews for PR #$PR_NUMBER" >&2
  exit 2
}
# Review-object evidence. NOT a latest-review-per-reviewer reduction (see the
# header): in "any" mode every accepted row counts; in "approved" mode a
# login contributes evidence when its newest APPROVED at head is not followed
# by a newer CHANGES_REQUESTED from that same login — a trailing COMMENTED
# never withdraws an approval.
got="$(jq --arg sha "$HEAD_SHA" --arg author "$PR_AUTHOR" \
        --arg trusted "$TRUSTED_LOGINS" --arg minstate "$MIN_STATE" '
  ($trusted | split("[;,\n]+"; "") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $t
  | [ .[]
      | select(.commit_id == $sha and .state != "DISMISSED" and .user.login != $author)
      | select(($t | length) == 0 or (.user.login as $l | ($t | index($l)) != null))
    ]
  | if $minstate == "approved" then
      group_by(.user.login)
      | map(sort_by(.submitted_at // ""))
      | map(select(
          ([.[] | select(.state == "APPROVED")] | length) > 0
          and (
            ([.[] | select(.state == "CHANGES_REQUESTED")] | length) == 0
            or (([.[] | select(.state == "APPROVED")] | last | .submitted_at // "") >
                ([.[] | select(.state == "CHANGES_REQUESTED")] | last | .submitted_at // ""))
          )
        ))
      | length
    else
      length
    end' <<<"$reviews")" || {
  echo "::error::could not evaluate review-object evidence for PR #$PR_NUMBER" >&2
  exit 2
}

# Clean-analysis evidence: bots that submit a review OBJECT only when they
# have findings pass their trusted check on a clean re-analysis and post no
# review, so "review at head" would be forever unsatisfiable after a push
# that fixes everything. Accept the trusted check-run OR legacy commit status
# succeeding on THIS head (evidence lives in EITHER API depending on the
# bot/repo; query both, either counts) — but only when the pass PROVES
# ANALYSIS RAN: a success whose title/summary/description matches a skip
# pattern (e.g. "Review rate limited") performed no review, so it is filtered
# to not-evidence — the same as absent, never a failure. A read FAILURE here
# must fail LOUDLY: treating it as absent evidence could flip a healthy PR's
# merge state on a transient API hiccup.
# The combined-status endpoint paginates its statuses array (default 30
# contexts per page), so fetch EVERY page (fail loud) and merge them into one
# snapshot — each trusted context and the outage attestation below evaluate
# against it. Fetch and merge are SEPARATE steps for the same reason as the
# check-runs read: a pipe would replace gh's exit status with jq's and turn a
# read failure into an empty-success (fail-open).
status_pages="$(gh api "repos/$GH_REPO/commits/$HEAD_SHA/status?per_page=100" --paginate)" || {
  echo "::error::could not read the combined commit status for $HEAD_SHA" >&2
  exit 2
}
status_resp="$(jq -s '{statuses: (map(.statuses) | add // [])}' <<<"$status_pages")" || {
  echo "::error::could not merge the combined commit status pages for $HEAD_SHA" >&2
  exit 2
}
check=0
while IFS= read -r ctx; do
  ctx="$(printf '%s' "$ctx" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$ctx" ] && continue
  ctx_uri="$(jq -rn --arg s "$ctx" '$s|@uri')"
  # --paginate emits one OBJECT per page for this endpoint; jq -s merges the
  # pages' check_runs arrays so a success beyond the first page still counts
  # (a missed run strands the gate at awaiting — wrong direction to lose).
  # Fetch and merge are SEPARATE steps: a pipe would replace gh's exit status
  # with jq's and turn a read failure into an empty-success (fail-open).
  checkruns_pages="$(gh api "repos/$GH_REPO/commits/$HEAD_SHA/check-runs?check_name=$ctx_uri&per_page=100" --paginate)" || {
    echo "::error::could not read '$ctx' check-runs" >&2
    exit 2
  }
  checkruns_resp="$(jq -s '{check_runs: (map(.check_runs) | add // [])}' <<<"$checkruns_pages")" || {
    echo "::error::could not merge '$ctx' check-run pages" >&2
    exit 2
  }
  # Bind each skip pattern to a variable BEFORE testing containment: inside
  # `select($text | contains(.))` the dot would rebind to $text itself, so
  # every clean pass would "match" and be filtered to not-evidence. Same
  # rebinding trap as the comment-sha binding below; the selftest's
  # genuine-clean-pass case is what catches it.
  check_runs="$(jq --arg ctx "$ctx" --arg skips "$SKIP_PATTERNS" '
      ($skips | split(";") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | map(ascii_downcase)) as $sk
      | [ .check_runs[]
          | select(.name == $ctx and .conclusion == "success")
          | (((.output.title // "") + " " + (.output.summary // "")) | ascii_downcase) as $text
          | select(([ $sk[] | . as $p | select($text | contains($p)) ] | length) == 0)
        ] | length' <<<"$checkruns_resp")" || {
    echo "::error::could not evaluate '$ctx' check-runs" >&2
    exit 2
  }
  check_status="$(jq --arg ctx "$ctx" --arg skips "$SKIP_PATTERNS" '
      ($skips | split(";") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | map(ascii_downcase)) as $sk
      | [ .statuses[]
          | select(.context == $ctx and .state == "success")
          | ((.description // "") | ascii_downcase) as $text
          | select(([ $sk[] | . as $p | select($text | contains($p)) ] | length) == 0)
        ] | length' <<<"$status_resp")" || {
    echo "::error::could not evaluate '$ctx' commit status" >&2
    exit 2
  }
  check=$((check + check_runs + check_status))
done <<EOF
$(printf '%s' "$TRUSTED_CONTEXTS" | tr ';' '\n')
EOF

# Comment-form clean-pass evidence: some reviewers post NEITHER a review
# object NOR a check/status on a clean pass — only an issue comment on the PR
# conversation ("... Reviewed commit: `<sha>`"). Trust keys on the AUTHOR
# LOGIN (exact match; only GitHub can set it); the body is read ONLY to bind
# the evidence to a commit. The bound sha may be full or a backtick-quoted
# short prefix: the match is "HEAD_SHA starts with the quoted sha",
# case-insensitively, with a floor so a degenerate prefix cannot match every
# head.
comment_hits=0
if [ -n "$COMMENT_REVIEWERS" ]; then
  # Two steps, not a pipe — same pagination/fail-loud reason as the reviews
  # read above.
  raw_comments="$(gh api "repos/$GH_REPO/issues/$PR_NUMBER/comments" --paginate)" || {
    echo "::error::could not read issue comments for PR #$PR_NUMBER" >&2
    exit 2
  }
  comments="$(jq -s 'add // []' <<<"$raw_comments")" || {
    echo "::error::could not parse issue comments for PR #$PR_NUMBER" >&2
    exit 2
  }
  while IFS= read -r pair; do
    pair="$(printf '%s' "$pair" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$pair" ] && continue
    login="${pair%%:*}"
    pattern="${pair#*:}"
    if [ -z "$login" ] || [ -z "$pattern" ] || [ "$login" = "$pair" ]; then
      echo "::error::review-predicate: malformed REVIEW_GATE_COMMENT_REVIEWERS entry '$pair' (need 'login:binding-pattern')" >&2
      exit 2
    fi
    # The binding pattern is a LITERAL prefix (regex-quoted here), not a
    # regex: trust config must not be able to smuggle in a permissive match.
    hits="$(jq --arg sha "$HEAD_SHA" --arg bot "$login" \
               --arg pat "$pattern" --arg floor "$SHA_FLOOR" '
      def requote: gsub("(?<c>[.^$|?*+()\\[\\]{}\\\\-])"; "\\" + .c);
      (($pat | requote) + "[^0-9a-fA-F]*([0-9a-fA-F]{" + $floor + ",40})") as $re
      | [ .[]
          | select(.user.login == $bot)
          | (.body // "")
          | scan($re)
          # Bind the claimed sha BEFORE comparing. Piping the head into
          # startswith and referring to the scanned value as dot rebinds dot
          # to the head inside that pipe, so every comment matches itself and
          # ANY sha is accepted. That is a false approved, the only direction
          # of this gate that fails silently; the different-sha case in the
          # selftest is what caught it.
          | (.[0] | ascii_downcase) as $claimed
          | select(($sha | ascii_downcase) | startswith($claimed))
        ] | length' <<<"$comments")" || {
      echo "::error::could not evaluate '$login' review comments for PR #$PR_NUMBER" >&2
      exit 2
    }
    comment_hits=$((comment_hits + hits))
  done <<EOF
$(printf '%s' "$COMMENT_REVIEWERS" | tr ';' '\n')
EOF
fi

# Reviewer-outage attestation: a trusted orchestrator posts this context on
# the head ONLY on genuine total reviewer silence (zero unresolved threads,
# no review/check/status engagement, head re-confirmed at emit). It
# substitutes for MISSING review evidence only — changes-requested and
# unresolved threads still fail closed. SECURITY: deliberate, bounded
# relaxation; trusted-publisher model identical to the trusted status
# contexts above. See orch DEVELOPMENT.md "Reviewer-outage recognition".
outageok=0
if [ -n "$OUTAGE_CONTEXT" ]; then
  outageok="$(jq --arg ctx "$OUTAGE_CONTEXT" \
    '[.statuses[] | select(.context == $ctx and .state == "success")] | length' <<<"$status_resp")" || {
    echo "::error::could not evaluate the reviewer-outage status" >&2
    exit 2
  }
fi

# A genuine GraphQL failure must NOT fall through as unresolved threads — fail
# loudly instead. `pageInfo.hasNextPage` (>100 threads) is a SUCCESSFUL read
# we cannot fully verify, so it reports "overflow" and fails closed to
# threads-open. Same posture for a thread node whose isResolved is not a
# boolean ("malformed"): null/missing nodes must never count as resolved —
# that direction is a false approval on a merge gate.
unresolved="$(gh api graphql \
  -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviewThreads(first:100){pageInfo{hasNextPage} nodes{isResolved}}}}}' \
  -F owner="${GH_REPO%/*}" -F repo="${GH_REPO#*/}" -F number="$PR_NUMBER" \
  --jq 'if .data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage then "overflow"
        elif ([.data.repository.pullRequest.reviewThreads.nodes[] | select((.isResolved | type) != "boolean")] | length) > 0 then "malformed"
        else ([.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length) end')" || {
  echo "::error::could not read review threads" >&2
  exit 2
}

echo "PR #$PR_NUMBER head $HEAD_SHA: reviews=$got clean-analysis=$check comment-form=$comment_hits outage-marker=$outageok changes-requested=$cr unresolved-threads=$unresolved" >&2

if [ "$cr" != "0" ]; then
  echo "verdict=changes-requested detail=review changes requested on the current head"
elif [ "$got" = "0" ] && [ "$check" = "0" ] && [ "$comment_hits" = "0" ] && [ "$outageok" = "0" ]; then
  echo "verdict=awaiting detail=awaiting a non-author review for $HEAD_SHA"
elif [ "$unresolved" != "0" ]; then
  echo "verdict=threads-open detail=$unresolved unresolved review thread(s)"
else
  echo "verdict=approved detail=reviewed at head with no unresolved threads"
fi
