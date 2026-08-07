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
# AND no STANDING changes-requested (each reviewer's latest decisive review
# across the WHOLE PR — GitHub keeps an objection standing across pushes
# until re-approval or dismissal, so the reduction must not be scoped to the
# head; positive evidence stays exact-head) AND zero unresolved review
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
#   REVIEW_GATE_STATUS_PUBLISHER_REJECT       (b,d) commit-status creator logins whose
#                                             statuses are never evidence, ';'-separated;
#                                             empty disables (opt-in per repo)
#   REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS  (a) trust list; empty = any non-author
#   REVIEW_GATE_REVIEW_OBJECT_MIN_STATE       (a) "any" (any review row) or "approved"
#                                             (an APPROVED row not withdrawn by a later
#                                             CHANGES_REQUESTED from the same login)
#   REVIEW_GATE_THREADS                       "enforce" (default) or "off": "off" skips
#                                             the reviewThreads GraphQL read entirely and
#                                             never emits threads-open — for repos whose
#                                             thread hygiene is a server-side zero-bypass
#                                             ruleset (the CI-side term is a latency
#                                             optimization there, not the enforcement
#                                             point of record)
#   REVIEW_GATE_API_ATTEMPTS                  bounded in-predicate retries for every
#                                             evidence read (default 1 = single attempt);
#                                             a read failing through the retries is still
#                                             exit 2 — the fail-loud contract is unchanged
#   REVIEW_GATE_API_RETRY_DELAY_SECONDS       delay between retry attempts (default 2)
#   REVIEW_GATE_CARRY_FORWARD                 carry-safe delta classes ("docs", "comments",
#                                             ';' or '|' separated; empty = off, today's
#                                             behavior): when NO evidence exists at head,
#                                             a qualifying review object at an ancestor
#                                             commit N still satisfies the evidence term
#                                             if the N→head diff classifies ENTIRELY into
#                                             the enabled classes (or is an identical
#                                             tree). Never a waiver: real evidence must
#                                             exist, and only EXTENDS across a delta
#                                             review would not re-examine; code changes
#                                             always require fresh evidence, and
#                                             changes-requested / unresolved threads
#                                             still fail closed.
#
# Env (required): GH_TOKEN (or ambient gh auth), GH_REPO, PR_NUMBER, HEAD_SHA
# Env (optional): PR_AUTHOR — resolved from the PR when empty.
# Env (optional): REVIEW_GATE_STATUS_SNAPSHOT_FILE — path to a combined-status
#   snapshot (JSON object with a `statuses` array and a top-level `sha` equal
#   to HEAD_SHA) supplied by the CALLER; when set, the predicate evaluates
#   trusted-context and outage evidence against it instead of fetching the
#   combined status itself. A converge-style caller that already read the
#   combined status for its own projection hands it in here and the duplicate
#   per-head read disappears — the API response carries the head sha at top
#   level, so a SINGLE-PAGE response satisfies the binding as-is. The
#   snapshot must contain the COMPLETE status set for the head: a caller
#   that paginated (heads with >100 statuses) merges every page's statuses
#   into one array under one top-level sha before handing it in — a
#   first-page-only snapshot would silently drop later-page evidence. Per-invocation env
#   seam (like REVIEW_GATE_SETTINGS_FILE), never a settings key: the snapshot
#   is bound to one head at one moment, and the `sha` requirement enforces
#   that binding. An unreadable/malformed/wrong-head snapshot is exit 2.
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
TRUSTED_CONTEXTS="$(rg_setting REVIEW_GATE_TRUSTED_STATUS_CONTEXTS "")" || exit 2
SKIP_PATTERNS="$(rg_setting REVIEW_GATE_CHECKRUN_SKIP_PATTERNS "rate limited;skipped;queued")" || exit 2
COMMENT_REVIEWERS="$(rg_setting REVIEW_GATE_COMMENT_REVIEWERS "")" || exit 2
SHA_FLOOR="$(rg_setting REVIEW_GATE_SHA_PREFIX_FLOOR "7")" || exit 2
# Operator override context, v2 name, resolved HERE (not only in the writer):
# every live gate read — the writer, consumers' heavy-job gate jobs, the
# selftest — goes through this predicate, so an adopter who sets only the v2
# key must not silently lose their override. Presence is detected with a
# sentinel default: a key set nowhere leaves the legacy resolution untouched;
# a key set anywhere (even to the empty string, which disables the source)
# wins over the legacy name.
override_sentinel="__review-gate-override-unset__"
OUTAGE_CONTEXT="$(rg_setting REVIEW_GATE_OVERRIDE_CONTEXT "$override_sentinel")" || exit 2
if [ "$OUTAGE_CONTEXT" = "$override_sentinel" ]; then
  OUTAGE_CONTEXT="$(rg_setting REVIEW_GATE_OUTAGE_CONTEXT "vstack-reviewer-outage")" || exit 2
fi
PUBLISHER_REJECT="$(rg_setting REVIEW_GATE_STATUS_PUBLISHER_REJECT "")" || exit 2
TRUSTED_LOGINS="$(rg_setting REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS "")" || exit 2
MIN_STATE="$(rg_setting REVIEW_GATE_REVIEW_OBJECT_MIN_STATE "any")" || exit 2
THREADS_MODE="$(rg_setting REVIEW_GATE_THREADS "enforce")" || exit 2
API_ATTEMPTS="$(rg_setting REVIEW_GATE_API_ATTEMPTS "1")" || exit 2
API_RETRY_DELAY="$(rg_setting REVIEW_GATE_API_RETRY_DELAY_SECONDS "2")" || exit 2
CARRY_FORWARD="$(rg_setting REVIEW_GATE_CARRY_FORWARD "")" || exit 2

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
case "$THREADS_MODE" in
  enforce|off) ;;
  *)
    echo "::error::review-predicate: REVIEW_GATE_THREADS must be 'enforce' or 'off', got '$THREADS_MODE'" >&2
    exit 2
    ;;
esac
case "$API_ATTEMPTS" in
  ''|*[!0-9]*|0)
    echo "::error::review-predicate: REVIEW_GATE_API_ATTEMPTS must be an integer >= 1, got '$API_ATTEMPTS'" >&2
    exit 2
    ;;
esac
case "$API_RETRY_DELAY" in
  ''|*[!0-9]*)
    echo "::error::review-predicate: REVIEW_GATE_API_RETRY_DELAY_SECONDS must be a non-negative integer, got '$API_RETRY_DELAY'" >&2
    exit 2
    ;;
esac
# Carry-forward classes: ';' (engine list convention) or '|' (the shape the
# ask was filed with) both split. An unknown class is a config error — a typo
# must never silently widen or narrow what carries.
while IFS= read -r cls; do
  cls="$(printf '%s' "$cls" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$cls" ] && continue
  case "$cls" in
    docs|comments) ;;
    *)
      echo "::error::review-predicate: REVIEW_GATE_CARRY_FORWARD class must be 'docs' or 'comments', got '$cls'" >&2
      exit 2
      ;;
  esac
done <<EOF_CARRY_CFG
$(printf '%s' "$CARRY_FORWARD" | tr ';|' '\n\n')
EOF_CARRY_CFG

# Every evidence read goes through here: up to REVIEW_GATE_API_ATTEMPTS tries
# with REVIEW_GATE_API_RETRY_DELAY_SECONDS between them, so a single transient
# 5xx can survive in-process instead of deferring the verdict to the caller's
# next pass. The default (1 attempt) is exactly today's single try, and a read
# that fails through every attempt still returns nonzero — callers keep the
# fail-loud exit-2 contract unchanged.
gh_read() {
  gh_read_attempt=1
  while :; do
    if gh_read_out="$(gh api "$@")"; then
      printf '%s' "$gh_read_out"
      return 0
    fi
    if [ "$gh_read_attempt" -ge "$API_ATTEMPTS" ]; then
      return 1
    fi
    gh_read_attempt=$((gh_read_attempt + 1))
    echo "::warning::review-predicate: read failed; retry $gh_read_attempt/$API_ATTEMPTS after ${API_RETRY_DELAY}s" >&2
    sleep "$API_RETRY_DELAY"
  done
}

# The gate's own posted status must never be review evidence: with
# REVIEW_GATE_CONTEXT listed as a trusted status context (or naming the
# outage attestation), a previously posted gate success would satisfy the
# predicate by itself — once green, the gate could never close again even
# after the real review evidence is withdrawn. Fail configuration instead.
GATE_CONTEXT_SELF="$(rg_setting REVIEW_GATE_CONTEXT "Review gate")" || exit 2
# Unlike the disable-able evidence sources, the gate context has no empty
# form: it names the required status the CI wiring posts, so "" would make
# that post malformed and leave the gate absent. Same refusal as the refire.
if [ -z "$GATE_CONTEXT_SELF" ]; then
  echo "::error::review-predicate: REVIEW_GATE_CONTEXT must not be empty" >&2
  exit 2
fi
if [ "$OUTAGE_CONTEXT" = "$GATE_CONTEXT_SELF" ]; then
  echo "::error::review-predicate: REVIEW_GATE_OUTAGE_CONTEXT equals REVIEW_GATE_CONTEXT ('$GATE_CONTEXT_SELF') — the gate's own status cannot attest a reviewer outage to itself" >&2
  exit 2
fi
while IFS= read -r ctx; do
  ctx="$(printf '%s' "$ctx" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$ctx" ] && continue
  if [ "$ctx" = "$GATE_CONTEXT_SELF" ]; then
    echo "::error::review-predicate: REVIEW_GATE_TRUSTED_STATUS_CONTEXTS includes REVIEW_GATE_CONTEXT ('$GATE_CONTEXT_SELF') — the gate's own status cannot be its own review evidence" >&2
    exit 2
  fi
done <<EOF_GATE_CTX
$(printf '%s' "$TRUSTED_CONTEXTS" | tr ';' '\n')
EOF_GATE_CTX

for required in GH_REPO PR_NUMBER HEAD_SHA; do
  if [ -z "$(eval "echo \${$required:-}")" ]; then
    echo "::error::review-predicate: $required is required" >&2
    exit 2
  fi
done

if [ -z "${PR_AUTHOR:-}" ]; then
  PR_AUTHOR="$(gh_read "repos/$GH_REPO/pulls/$PR_NUMBER" --jq .user.login)" || {
    echo "::error::could not resolve PR #$PR_NUMBER author" >&2
    exit 2
  }
  if [ -z "$PR_AUTHOR" ]; then
    echo "::error::PR #$PR_NUMBER author resolved to an empty login" >&2
    exit 2
  fi
fi

# Two steps, not a pipe: `--paginate` emits ONE ARRAY PER PAGE, which the
# count filters below would evaluate per-array (multi-line counts that can
# never equal "0" past 100 reviews), and a mid-pipe gh failure must fail
# loudly rather than hand jq a truncated page set. ZERO BYTES from a
# successful producer is a broken read too (truncated stream, empty response
# body): `jq -s 'add // []'` would silently turn it into [], and for the
# reviews read specifically an empty result can erase a standing
# CHANGES_REQUESTED while other evidence still satisfies the positive side —
# a false approved. An intentionally empty page set from a real API response
# is a NON-EMPTY `[]` body, so only a bytes-empty producer is refused.
raw_reviews="$(gh_read "repos/$GH_REPO/pulls/$PR_NUMBER/reviews?per_page=100" --paginate)" || {
  echo "::error::could not read reviews for PR #$PR_NUMBER" >&2
  exit 2
}
if [ -z "$raw_reviews" ]; then
  echo "::error::reviews read for PR #$PR_NUMBER produced zero bytes (broken read, not an empty page set)" >&2
  exit 2
fi
reviews="$(jq -s 'add // []' <<<"$raw_reviews")" || {
  echo "::error::could not parse reviews for PR #$PR_NUMBER" >&2
  exit 2
}
# Changes-requested reduces each reviewer over their DECISIVE states only
# (APPROVED / CHANGES_REQUESTED, ordered by submitted_at) across the WHOLE
# PR — never scoped to the head: GitHub keeps an objection standing when the
# author pushes new commits, so a head-scoped reduction would let any
# evidence source on the fresh head open the gate past a standing human
# objection. A later APPROVED from the same reviewer (on any commit) clears
# it, so a superseded CR can't pin the PR red forever — but a trailing
# COMMENTED row never withdraws one (GitHub itself keeps requested changes
# standing until re-approval or dismissal), the mirror of the header's
# approval-is-never-superseded-by-a-comment rule. Deliberately unfiltered by
# the trust list: anyone's standing objection fails the gate closed. PENDING
# rows (unsubmitted drafts, visible when the token authored them) are
# excluded EVERYWHERE: a draft is not a review event — it must neither clear
# a standing CR here nor count as evidence below.
cr="$(jq '[.[] | select(.state != "DISMISSED" and .state != "PENDING") | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")] | group_by(.user.login) | map(sort_by(.submitted_at // "") | .[-1]) | map(select(.state == "CHANGES_REQUESTED")) | length' <<<"$reviews")" || {
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
      | select(.commit_id == $sha and .state != "DISMISSED" and .state != "PENDING" and .user.login != $author)
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
# read failure into an empty-success (fail-open). A caller that already holds
# the combined status (a converge-style sweep projecting required statuses
# per head) hands it in via REVIEW_GATE_STATUS_SNAPSHOT_FILE instead, and
# this read is skipped entirely.
if [ -n "${REVIEW_GATE_STATUS_SNAPSHOT_FILE:-}" ]; then
  # The snapshot substitutes for a READ, so it gets the read contract: not a
  # file, zero bytes, unparseable, missing the statuses array, or not bound
  # to THIS head (top-level sha != HEAD_SHA — a snapshot for another head
  # would pass shape validation and evaluate stale evidence) is exit 2 —
  # never an empty-evidence verdict. A single-page API response carries the
  # head sha at top level and satisfies the binding as-is; paginating
  # callers must merge all pages' statuses into the one array first (a
  # first-page-only snapshot silently drops later-page evidence).
  #
  # Slurped, requiring exactly ONE value: a caller that hands over
  # concatenated page responses would otherwise yield one normalized object
  # per value, and every downstream per-value jq read would emit multi-line
  # counts ("0\n0") that fail the string comparisons in the verdict logic —
  # with no trusted contexts configured that fell through to an approval
  # with zero evidence (vstack#1086). Slurping also makes a zero-value
  # (empty or whitespace-only) file hit the error branch instead of jq's
  # silent empty-output success.
  status_resp="$(jq -s --arg sha "$HEAD_SHA" '
                     if (length == 1) and (.[0]
                        | (type == "object") and ((.statuses | type) == "array")
                          and (.sha == $sha))
                     then {statuses: .[0].statuses}
                     else error("not a single combined-status snapshot for this head") end' \
                    "$REVIEW_GATE_STATUS_SNAPSHOT_FILE" 2>/dev/null)" || {
    echo "::error::REVIEW_GATE_STATUS_SNAPSHOT_FILE '$REVIEW_GATE_STATUS_SNAPSHOT_FILE' is not a readable combined-status snapshot bound to $HEAD_SHA (exactly one JSON object with a statuses array and top-level sha == HEAD_SHA)" >&2
    exit 2
  }
else
  status_pages="$(gh_read "repos/$GH_REPO/commits/$HEAD_SHA/status?per_page=100" --paginate)" || {
    echo "::error::could not read the combined commit status for $HEAD_SHA" >&2
    exit 2
  }
  if [ -z "$status_pages" ]; then
    echo "::error::combined-status read for $HEAD_SHA produced zero bytes (broken read)" >&2
    exit 2
  fi
  # Validate every page BEFORE merging: a nonempty non-status page (an error
  # object, `{}`, a truncated body) would survive the zero-byte guard, then
  # `map(.statuses) | add // []` collapses its null into an empty status list
  # and the predicate reaches a verdict on broken evidence. A broken read is
  # exit 2, never an empty-evidence verdict. `length > 0` guards the vacuous
  # case: a whitespace-only response passes the -z check yet slurps to [],
  # where all(...) is trivially true (vstack#1086).
  status_resp="$(jq -s 'if (length > 0) and all(type == "object" and ((.statuses | type) == "array"))
                        then {statuses: (map(.statuses) | add // [])}
                        else error("not a combined-status page") end' \
                    <<<"$status_pages" 2>/dev/null)" || {
    echo "::error::could not merge the combined commit status pages for $HEAD_SHA (each page must be an object with a statuses array)" >&2
    exit 2
  }
fi
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
  checkruns_pages="$(gh_read "repos/$GH_REPO/commits/$HEAD_SHA/check-runs?check_name=$ctx_uri&per_page=100" --paginate)" || {
    echo "::error::could not read '$ctx' check-runs" >&2
    exit 2
  }
  if [ -z "$checkruns_pages" ]; then
    echo "::error::'$ctx' check-runs read produced zero bytes (broken read)" >&2
    exit 2
  fi
  checkruns_resp="$(jq -s '{check_runs: (map(.check_runs) | add // [])}' <<<"$checkruns_pages")" || {
    echo "::error::could not merge '$ctx' check-run pages" >&2
    exit 2
  }
  # Bind each skip pattern to a variable BEFORE testing containment: inside
  # `select($text | contains(.))` the dot would rebind to $text itself, so
  # every clean pass would "match" and be filtered to not-evidence. Same
  # rebinding trap as the comment-sha binding below; the selftest's
  # genuine-clean-pass case is what catches it.
  # Check-runs are matched by NAME, but names are not reserved: any PR
  # workflow with `checks: write` can publish a check run under ANY name
  # through the shared `github-actions` app — trusted reviewer bots publish
  # under their own app slug. A github-actions-published name-match is
  # therefore never clean-analysis evidence (VST-19); rejecting it here is
  # the mechanical half of the settings doc's "only names produced by
  # trusted bots" precondition.
  check_runs="$(jq --arg ctx "$ctx" --arg skips "$SKIP_PATTERNS" '
      ($skips | split(";") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | map(ascii_downcase)) as $sk
      | [ .check_runs[]
          | select(.name == $ctx and .conclusion == "success")
          | select(((.app.slug // "") != "") and ((.app.slug // "") != "github-actions"))
          | (((.output.title // "") + " " + (.output.summary // "")) | ascii_downcase) as $text
          | select(([ $sk[] | . as $p | select($text | contains($p)) ] | length) == 0)
        ] | length' <<<"$checkruns_resp")" || {
    echo "::error::could not evaluate '$ctx' check-runs" >&2
    exit 2
  }
  # Legacy commit statuses carry no app slug to reject on, but they do carry
  # a creator: on repos whose PR-triggered workflows hold statuses:write, PR
  # content can mint a status under ANY context through github-actions[bot] —
  # the one publisher identity PR code can wield. The OPT-IN
  # REVIEW_GATE_STATUS_PUBLISHER_REJECT list is the status-side mirror of the
  # check-run app rejection above: a status whose creator login is listed is
  # never evidence. It is a reject-list for the forgeable identity, NOT a
  # provenance requirement — GitHub App statuses serialize creator as null,
  # and null is not the forgeable identity, so a login entry never rejects
  # it (deliberately unlike the no-app-slug check-run case, which fails
  # closed). Empty (the shipped default) disables the filter: legitimate
  # outage attestation is Actions-posted on some repos, so rejection is a
  # per-repo choice.
  check_status="$(jq --arg ctx "$ctx" --arg skips "$SKIP_PATTERNS" --arg reject "$PUBLISHER_REJECT" '
      ($skips | split(";") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | map(ascii_downcase)) as $sk
      | ($reject | split(";") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $rj
      | [ .statuses[]
          | select(.context == $ctx and .state == "success")
          | select((.creator.login // "") as $l | ($rj | index($l)) == null)
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
# LOGIN (exact match; only GitHub can set it) — and the PR author is
# excluded even when configured as a comment reviewer, or a bot could
# self-approve its own update PR; the body is read ONLY to bind the
# evidence to a commit. The bound sha may be the full sha or a short prefix
# (bare or backtick-quoted — decoration between the binding pattern and the
# sha is ignored as non-hex): the match is "HEAD_SHA starts with the bound
# sha", case-insensitively, with a floor so a degenerate prefix cannot
# match every head. The trust anchor is the author login plus the LITERAL
# binding pattern immediately preceding the sha slot, not the quoting.
comment_hits=0
if [ -n "$COMMENT_REVIEWERS" ]; then
  # Two steps, not a pipe — same pagination/fail-loud/zero-byte reasons as
  # the reviews read above.
  raw_comments="$(gh_read "repos/$GH_REPO/issues/$PR_NUMBER/comments?per_page=100" --paginate)" || {
    echo "::error::could not read issue comments for PR #$PR_NUMBER" >&2
    exit 2
  }
  if [ -z "$raw_comments" ]; then
    echo "::error::issue-comments read for PR #$PR_NUMBER produced zero bytes (broken read, not an empty page set)" >&2
    exit 2
  fi
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
    hits="$(jq --arg sha "$HEAD_SHA" --arg bot "$login" --arg author "$PR_AUTHOR" \
               --arg pat "$pattern" --arg floor "$SHA_FLOOR" '
      def requote: gsub("(?<c>[.^$|?*+()\\[\\]{}\\\\-])"; "\\" + .c);
      (($pat | requote) + "[^0-9a-fA-F]*([0-9a-fA-F]{" + $floor + ",40})") as $re
      | [ .[]
          | select(.user.login == $bot and .user.login != $author)
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
outage_reason=""
if [ -n "$OUTAGE_CONTEXT" ]; then
  # The publisher reject-list applies here too — the outage relaxation is
  # the highest-value status to forge, so a listed creator (typically
  # github-actions[bot] where PR workflows hold statuses:write) must not be
  # able to mint it. Same null-creator semantics as the trusted-context
  # read above: App-posted statuses are never rejected by a login entry.
  # The REASON is mandatory (plan Change 2, finding 9, carried from the
  # outage semantics): an override with an empty description is not an
  # attestation, it is an unexplained relaxation — and it is the
  # highest-value status in the system to forge. Enforced here, not merely
  # documented. The reason rides out in the verdict detail below, flattened
  # at the source because it is API text travelling through a one-line
  # contract and a one-line status description.
  outageok_out="$(jq -r --arg ctx "$OUTAGE_CONTEXT" --arg reject "$PUBLISHER_REJECT" '
    ($reject | split(";") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $rj
    | [ .statuses[]
        | select(.context == $ctx and .state == "success")
        | select((.creator.login // "") as $l | ($rj | index($l)) == null)
        | select(((.description // "") | gsub("^\\s+|\\s+$"; "") | length) > 0)
      ]
    | [ length,
        (if length == 0 then ""
         else (sort_by(.created_at // "") | last | (.description // "") | gsub("[\n\r\t]"; " ")) end) ]
    | "\(.[0])\t\(.[1])"' <<<"$status_resp")" || {
    echo "::error::could not evaluate the operator-override status" >&2
    exit 2
  }
  outageok_out="$(head -n 1 <<<"$outageok_out")"
  outageok="$(cut -f1 <<<"$outageok_out")"
  outage_reason="$(cut -f2- <<<"$outageok_out")"
fi

# Evidence carry-forward across carry-safe deltas (VST-57). Evidence is
# review at the EXACT head, so every push — including one that changes no
# executable behavior (review-servicing prose, comment rewording) — discards
# existing evidence and restarts the full bot-review wait. When NO evidence
# exists at head and REVIEW_GATE_CARRY_FORWARD enables it, a qualifying
# review OBJECT at an ancestor commit N still satisfies the evidence term if
# the N→head diff classifies ENTIRELY into the enabled carry-safe classes:
#   docs      every changed file is documentation BY EXTENSION
#             (*.md/*.markdown; a docs/-directory rule would carry
#             executable files like docs/conf.py)
#   comments  every changed file is a MODIFIED code file whose patch touches
#             only full-line comments (per a conservative per-extension
#             comment-token table; unknown extensions refuse)
# and an IDENTICAL tree (rebase residue, empty commits — the VST-58 shape)
# always carries once any class is enabled. This is NOT the retired
# docs-only waiver: real evidence must exist, and only EXTENDS across a
# delta review would not re-examine — code changes always require fresh
# evidence, and the changes-requested and thread terms below still fail
# closed with carried evidence exactly as with head evidence. Only the
# NEWEST ancestor candidate decides: an older candidate's delta is a
# superset, so walking further back can only widen what carries.
carried=0
carry_base=""
carry_kind=""
if [ -n "$CARRY_FORWARD" ] && [ "$got" = "0" ] && [ "$check" = "0" ] \
   && [ "$comment_hits" = "0" ] && [ "$outageok" = "0" ]; then
  # Candidate commits: accepted review rows (same trust filters as head
  # evidence; min_state=approved accepts only APPROVED rows — a later
  # withdrawal by the same login is a standing CR and fails the gate before
  # carry could matter), newest-first, distinct, never the head itself,
  # bounded so a force-push-heavy PR cannot turn the walk into an API storm.
  carry_candidates="$(jq -r --arg sha "$HEAD_SHA" --arg author "$PR_AUTHOR" \
      --arg trusted "$TRUSTED_LOGINS" --arg minstate "$MIN_STATE" '
    ($trusted | split("[;,\n]+"; "") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $t
    | [ .[]
        | select(.state != "DISMISSED" and .state != "PENDING" and .user.login != $author)
        | select(($t | length) == 0 or (.user.login as $l | ($t | index($l)) != null))
        | select($minstate != "approved" or .state == "APPROVED")
        | select((.commit_id // "") != "" and .commit_id != $sha)
      ]
    | sort_by(.submitted_at // "") | reverse | map(.commit_id)
    | reduce .[] as $c ([]; if (index($c) != null) then . else . + [$c] end)
    | .[0:10] | .[]' <<<"$reviews")" || {
    echo "::error::could not derive carry-forward candidates for PR #$PR_NUMBER" >&2
    exit 2
  }
  while IFS= read -r base; do
    [ -z "$base" ] && continue
    # The compare read is the ancestry check AND the delta: status "ahead"
    # means base is an ancestor of head; "identical" is the empty diff;
    # "behind"/"diverged" (superseded pre-force-push shas) are skipped. A
    # failed or zero-byte read is exit 2 like every other evidence read —
    # deciding carry from a truncated file list is the fail-open this
    # predicate exists to prevent.
    cmp_pages="$(gh_read "repos/$GH_REPO/compare/$base...$HEAD_SHA?per_page=100" --paginate)" || {
      echo "::error::could not read the comparison $base...$HEAD_SHA" >&2
      exit 2
    }
    if [ -z "$cmp_pages" ]; then
      echo "::error::comparison $base...$HEAD_SHA produced zero bytes (broken read)" >&2
      exit 2
    fi
    # EVERY page of a healthy compare response carries a files array
    # (possibly empty); any page without one is a malformed or truncated
    # response, and defaulting it to [] would hide that page's files from
    # classification — a carried approval from a broken read (vstack#1097
    # closed the later-page half of this; page 1 was always checked). Same
    # exit-2 contract as every other evidence read.
    cmp="$(jq -s 'if (length > 0) and all(type == "object" and ((.files | type) == "array"))
                  then {status: (.[0].status // ""), files: (map(.files) | add)}
                  else error("malformed compare page") end' \
              <<<"$cmp_pages" 2>/dev/null)" || {
      echo "::error::could not merge the comparison pages for $base...$HEAD_SHA (missing or malformed files array)" >&2
      exit 2
    }
    cmp_status="$(jq -r .status <<<"$cmp")"
    case "$cmp_status" in
      identical)
        carried=1; carry_base="$base"; carry_kind="identical tree"
        break
        ;;
      ahead) ;;
      *) continue ;;
    esac
    cmp_file_count="$(jq '.files | length' <<<"$cmp")"
    if [ "$cmp_file_count" = "0" ]; then
      # Ahead by commits that change no file: the trees are equal.
      carried=1; carry_base="$base"; carry_kind="identical tree"
      break
    fi
    # The compare API caps the returned file list at 300 entries, so a list
    # AT the cap cannot prove the delta is complete — an omitted 301st file
    # could be code, and classifying only what was returned would be the
    # fail-open this predicate exists to prevent. The read itself is
    # healthy, so this refuses the carry (fresh review required) rather
    # than exit 2; older candidates' deltas are supersets, so stop walking.
    if [ "$cmp_file_count" -ge 300 ]; then
      echo "::warning::compare $base...$HEAD_SHA returned $cmp_file_count files (the API caps the list at 300): the delta cannot be proven complete; refusing carry-forward" >&2
      break
    fi
    # Classify every changed file into an ENABLED class; anything else —
    # code lines, added/removed/renamed files under "comments", binary or
    # patch-less files, unknown extensions — refuses the whole carry.
    carry_ok="$(jq -r --arg classes "$CARRY_FORWARD" '
      ($classes | split("[;|]"; "") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $cl
      | def comment_token:
          if test("\\.(sh|bash|py|rb|toml|yml|yaml)$") then "#"
          elif test("\\.(js|mjs|cjs|ts|tsx|jsx|rs|go|c|h|cc|cpp|hpp|java|kt|swift)$") then "//"
          else null end;
      [ .files[]
        | . as $f
        | (.filename // "") as $fn
        | if (($cl | index("docs")) != null)
             and ($f.status != "renamed")
             and (($f.previous_filename // "") == "")
             and ($fn | test("\\.(md|markdown)$"))
          then "docs"
          elif (($cl | index("comments")) != null)
               and ($f.status == "modified")
               and (($f.patch // "") != "")
               and (($fn | comment_token) != null)
          then ( ($fn | comment_token) as $tok
                 | ($f.patch | split("\n")
                    | map(select(test("^[+-]")))
                    | map(sub("^[+-][[:space:]]*"; ""))
                    | map(select(length > 0))) as $chg
                 | if ($chg | all(startswith($tok) and (startswith("#!") | not)))
                   then "comments" else "refuse" end )
          else "refuse" end
      ] | all(. != "refuse")' <<<"$cmp")" || {
      echo "::error::could not classify the $base...$HEAD_SHA delta" >&2
      exit 2
    }
    if [ "$carry_ok" = "true" ]; then
      carried=1; carry_base="$base"; carry_kind="carry-safe delta ($CARRY_FORWARD)"
    fi
    break
  done <<EOF_CARRY
$carry_candidates
EOF_CARRY
fi

# A genuine GraphQL failure must NOT fall through as unresolved threads — fail
# loudly instead. `pageInfo.hasNextPage` (>100 threads) is a SUCCESSFUL read
# we cannot fully verify, so it reports "overflow" and fails closed to
# threads-open. Same posture for a thread node whose isResolved is not a
# boolean ("malformed"): null/missing nodes must never count as resolved —
# that direction is a false approval on a merge gate.
#
# REVIEW_GATE_THREADS=off skips this read ENTIRELY and the predicate never
# emits threads-open: on repos whose thread hygiene is a server-side
# zero-bypass ruleset (required_review_thread_resolution), the CI-side term
# is a latency optimization that costs a GraphQL read per evaluation for a
# verdict the merge-time gate already enforces — and forces every caller to
# reinterpret threads-open in its own adapter. The narrowing is bounded:
# only the thread term is disabled; evidence and changes-requested still
# fail closed exactly as before.
unresolved=0
if [ "$THREADS_MODE" = "enforce" ]; then
unresolved="$(gh_read graphql \
  -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviewThreads(first:100){pageInfo{hasNextPage} nodes{isResolved}}}}}' \
  -F owner="${GH_REPO%/*}" -F repo="${GH_REPO#*/}" -F number="$PR_NUMBER" \
  --jq 'if .data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage then "overflow"
        elif ([.data.repository.pullRequest.reviewThreads.nodes[] | select((.isResolved | type) != "boolean")] | length) > 0 then "malformed"
        else ([.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length) end')" || {
  echo "::error::could not read review threads" >&2
  exit 2
}
fi

echo "PR #$PR_NUMBER head $HEAD_SHA: reviews=$got clean-analysis=$check comment-form=$comment_hits outage-marker=$outageok carried=$carried changes-requested=$cr unresolved-threads=$unresolved (threads=$THREADS_MODE)" >&2

if [ "$cr" != "0" ]; then
  echo "verdict=changes-requested detail=standing review changes requested (persists across pushes until re-approval or dismissal)"
elif [ "$got" = "0" ] && [ "$check" = "0" ] && [ "$comment_hits" = "0" ] && [ "$outageok" = "0" ] && [ "$carried" = "0" ]; then
  echo "verdict=awaiting detail=awaiting a non-author review for $HEAD_SHA"
elif [ "$unresolved" != "0" ]; then
  echo "verdict=threads-open detail=$unresolved unresolved review thread(s)"
elif [ "$carried" = "1" ]; then
  echo "verdict=approved detail=review evidence at $carry_base carried to head across a $carry_kind"
elif [ "$outageok" != "0" ] && [ "$got" = "0" ] && [ "$check" = "0" ] && [ "$comment_hits" = "0" ]; then
  # The override is SUBSTITUTING for missing evidence (its only sanctioned
  # use), so the attested reason is the verdict — it belongs in the gate
  # status, where a reader sees why this PR merged without a review.
  echo "verdict=approved detail=operator override ($OUTAGE_CONTEXT): $outage_reason"
else
  echo "verdict=approved detail=reviewed at head with no unresolved threads"
fi
