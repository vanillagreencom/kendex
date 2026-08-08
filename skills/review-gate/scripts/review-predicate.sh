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
# Env (optional): REVIEW_GATE_STATUS_SNAPSHOT_FILE — path to a status snapshot
#   (JSON object with a `statuses` array and a top-level `sha` equal to
#   HEAD_SHA) supplied by the CALLER; when set, the predicate evaluates
#   trusted-context and outage evidence against it instead of fetching the
#   statuses itself. LIST-ENDPOINT ROWS ONLY: the rows must come from the
#   per-commit statuses LIST endpoint (/commits/<sha>/statuses), the same
#   endpoint the fetch path below uses — full per-context HISTORY, real
#   `creator.login` on every row. The combined endpoint
#   (/commits/<sha>/status) is NOT a valid source: it projects
#   latest-per-context (masking newer-row supersession) and serializes
#   `creator` as null for App-posted rows, which the
#   REVIEW_GATE_STATUS_PUBLISHER_REJECT anomaly rule would then silently
#   drop as not-evidence. While the reject list is configured, a row without
#   a creator login is refused AT THE SEAM (exit 2) rather than silently
#   erased downstream. The snapshot must contain the COMPLETE status set for
#   the head: a caller that paginated (heads with >100 rows) merges every
#   page's rows into one array under one top-level `sha` before handing it
#   in — a first-page-only snapshot would silently drop later-page
#   evidence. Per-invocation env seam (like REVIEW_GATE_SETTINGS_FILE),
#   never a settings key: the snapshot is bound to one head at one moment,
#   and the `sha` requirement enforces that binding. An
#   unreadable/malformed/wrong-head snapshot is exit 2.
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
# is a NON-EMPTY `[]` body, so only a bytes-empty producer is refused — and
# the merge validates page SHAPE, not just parse success: a whitespace-only
# body passes the zero-byte check yet slurps to [] (vacuously "no reviews"),
# and an error-object page would collapse through `add` — both erase a
# standing CHANGES_REQUESTED. A broken read is exit 2, never empty evidence.
raw_reviews="$(gh_read "repos/$GH_REPO/pulls/$PR_NUMBER/reviews?per_page=100" --paginate)" || {
  echo "::error::could not read reviews for PR #$PR_NUMBER" >&2
  exit 2
}
if [ -z "$raw_reviews" ]; then
  echo "::error::reviews read for PR #$PR_NUMBER produced zero bytes (broken read, not an empty page set)" >&2
  exit 2
fi
reviews="$(jq -s 'if (length > 0) and all(type == "array")
                  then add
                  else error("review pages are not arrays") end' <<<"$raw_reviews" 2>/dev/null)" || {
  echo "::error::reviews read for PR #$PR_NUMBER returned non-array pages or a vacuous body (broken read)" >&2
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
# The statuses LIST endpoint paginates (100 rows per page here), so fetch
# EVERY page (fail loud) and merge them into one snapshot — each trusted
# context and the outage attestation below evaluate against it. Fetch and
# merge are SEPARATE steps for the same reason as the check-runs read: a
# pipe would replace gh's exit status with jq's and turn a read failure
# into an empty-success (fail-open). A caller that already holds the
# LIST-endpoint rows (a converge-style sweep projecting required statuses
# per head) hands them in via REVIEW_GATE_STATUS_SNAPSHOT_FILE instead
# (wrapped {sha, statuses} per the header contract), and this read is
# skipped entirely.
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
  #
  # LIST-endpoint rows only (see the env contract in the header): while the
  # publisher reject list is configured, every row must carry a real
  # creator login — on the LIST endpoint every real publisher has one, and
  # the downstream anomaly rule drops login-less rows as not-evidence. A
  # combined-endpoint snapshot (null creators on App rows) under a
  # configured reject list would therefore silently erase real evidence;
  # refusing it here turns that erasure into a loud contract error. With
  # the reject list empty (the shipped default) the filter is off and no
  # creator requirement applies.
  status_resp="$(jq -s --arg sha "$HEAD_SHA" --arg reject "$PUBLISHER_REJECT" '
                     ($reject | split(";") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $rj
                     | if (length == 1) and (.[0]
                        | (type == "object") and ((.statuses | type) == "array")
                          and (.sha == $sha)
                          and (($rj | length) == 0
                               or (.statuses | all(
                                    ((.creator | type) == "object")
                                    and ((.creator.login | type) == "string")
                                    and ((.creator.login | length) > 0)))))
                     then {statuses: .[0].statuses}
                     else error("not a single list-endpoint status snapshot for this head") end' \
                    "$REVIEW_GATE_STATUS_SNAPSHOT_FILE" 2>/dev/null)" || {
    echo "::error::REVIEW_GATE_STATUS_SNAPSHOT_FILE '$REVIEW_GATE_STATUS_SNAPSHOT_FILE' is not a readable list-endpoint status snapshot bound to $HEAD_SHA (exactly one JSON object with a statuses array and top-level sha == HEAD_SHA; with REVIEW_GATE_STATUS_PUBLISHER_REJECT configured every row must carry a creator login — combined-endpoint snapshots null App creators and are not a valid source)" >&2
    exit 2
  }
else
  # THE STATUSES LIST, NOT THE COMBINED STATUS — this is a security
  # requirement, not a style choice. The combined endpoint
  # (/commits/<sha>/status) serializes `creator` as NULL for every
  # App-posted status, and GITHUB_TOKEN in any PR workflow IS the GitHub
  # Actions app. Reading it made REVIEW_GATE_STATUS_PUBLISHER_REJECT
  # inert: PR-controlled code could mint a trusted context (or the operator
  # override) and no login entry could ever match it. The LIST endpoint
  # (/commits/<sha>/statuses) reports the real creator login, so the
  # reject-list works as documented. Caught live by sandbox scenario 6.
  status_pages="$(gh_read "repos/$GH_REPO/commits/$HEAD_SHA/statuses?per_page=100" --paginate)" || {
    echo "::error::could not read commit statuses for $HEAD_SHA" >&2
    exit 2
  }
  if [ -z "$status_pages" ]; then
    echo "::error::commit-statuses read for $HEAD_SHA produced zero bytes (broken read)" >&2
    exit 2
  fi
  # Validate every page BEFORE merging: a nonempty non-array page (an error
  # object, a truncated body) would survive the zero-byte guard and then
  # collapse to an empty status list, letting the predicate reach a verdict
  # on broken evidence. A broken read is exit 2, never an empty-evidence
  # verdict. `length > 0` guards the vacuous case: a whitespace-only
  # response passes the -z check yet slurps to [], where all(...) is
  # trivially true (vstack#1086).
  status_resp="$(jq -s 'if (length > 0) and all(type == "array")
                        then {statuses: (add // [])}
                        else error("not a statuses page") end' \
                    <<<"$status_pages" 2>/dev/null)" || {
    echo "::error::could not merge the commit-status pages for $HEAD_SHA (each page must be a JSON array)" >&2
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
  # Page-shape validation, same reasoning as the reviews read: a
  # whitespace-only body slurps to [] and a non-object page (or one with no
  # check_runs array) would collapse to an empty run set — silence built
  # from a broken read. Exit 2 instead.
  checkruns_resp="$(jq -s 'if (length > 0) and all((type == "object") and ((.check_runs | type) == "array"))
                           then {check_runs: (map(.check_runs) | add)}
                           else error("check-run pages are malformed") end' <<<"$checkruns_pages" 2>/dev/null)" || {
    echo "::error::'$ctx' check-run pages are malformed or vacuous (broken read)" >&2
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
  # Commit statuses carry no app slug to reject on, but the LIST endpoint
  # carries a real creator login (the combined endpoint does not — see the
  # read above). On repos whose PR-triggered workflows hold statuses:write,
  # PR content can mint a status under ANY context through
  # github-actions[bot] — the one publisher identity PR code can wield. The
  # OPT-IN REVIEW_GATE_STATUS_PUBLISHER_REJECT list is the status-side
  # mirror of the check-run app rejection above: a status whose creator
  # login is listed is never evidence.
  #
  # A status with NO creator login is not evidence either WHEN THE LIST IS
  # CONFIGURED: on this endpoint every real publisher has a login, so a
  # missing one is an anomaly, and treating anomalies as trusted is the
  # fail-open direction this engine exists to avoid. With the list empty
  # (the shipped default) the filter is off entirely and behavior is
  # unchanged.
  # NEWEST ROW DECIDES, per context. The LIST endpoint returns the full
  # status HISTORY, not the combined endpoint's latest-per-context
  # projection — filtering for "any success" would let an old success
  # outlive a NEWER pending/failure on the same context and open the gate
  # on stale evidence (a reviewer starting a fresh round posts pending over
  # its own earlier success). Publisher-rejected rows are dropped BEFORE
  # choosing the newest — a rejected creator is "not evidence either way",
  # and letting a minted row mask real rows would hand PR content a
  # close-the-gate lever it should not have (only toward closed, but still
  # not its call). Login-less ANOMALY rows are the opposite: they are NOT
  # dropped from the sequence — dropped-before-newest they would revive an
  # OLDER success (stale approval from malformed current evidence); kept,
  # an anomalous NEWEST row reads as silence. Safe against the minting
  # lever because PR content cannot produce a login-less row (its statuses
  # carry github-actions[bot], which is what the reject list names), and a
  # GitHub-side anomaly (a ghost/deleted creator) masks toward CLOSED, and
  # only until a real row supersedes it. The newest ACCEPTED row must then
  # itself be a clean success: a newest row that is pending/failure, a
  # skip-filtered success ("rate limited"), or — while the reject list is
  # configured — a login-less anomaly, is silence — exactly what the
  # combined endpoint's projection used to yield.
  check_status="$(jq --arg ctx "$ctx" --arg skips "$SKIP_PATTERNS" --arg reject "$PUBLISHER_REJECT" '
      ($skips | split(";") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | map(ascii_downcase)) as $sk
      | ($reject | split(";") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $rj
      | [ .statuses[]
          | select(.context == $ctx)
          # Bind the login BEFORE index(): inside index(...) the dot rebinds
          # to $rj, so `.creator` would index the reject ARRAY, not the
          # status. Same rebinding trap the comment-form matcher documents.
          # Only LISTED creators are dropped; login-less rows stay in the
          # sequence (see the anomaly rationale above).
          | (.creator.login // "") as $cl
          | select(($rj | length) == 0 or ($cl == "") or (($cl | type) != "string") or (($rj | index($cl)) == null))
        ]
      # FIRST accepted row, not sort_by(created_at)|last: the API lists
      # statuses newest-first (the writer and driver already rely on it),
      # and created_at has one-second precision — jq sort is stable, so two
      # rows tied within a second would sort with the OLDER one last and
      # reintroduce exactly the stale-evidence read this projection closes.
      | first
      | if . == null then 0
        elif ($rj | length) > 0
             and (((.creator | type) != "object")
                  or ((.creator.login | type) != "string")
                  or ((.creator.login | length) == 0))
        then 0
        elif .state == "success"
             and ((((.description // "") | ascii_downcase) as $text
                   | [ $sk[] | . as $p | select($text | contains($p)) ] | length) == 0)
        then 1 else 0 end' <<<"$status_resp")" || {
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
  # Same page-shape validation as the reviews read: whitespace slurps to
  # [] and an error-object page collapses through `add` — either would
  # vaporize comment-form evidence (wrong direction: strands at awaiting)
  # on a broken read that should be exit 2.
  comments="$(jq -s 'if (length > 0) and all(type == "array")
                     then add
                     else error("comment pages are not arrays") end' <<<"$raw_comments" 2>/dev/null)" || {
    echo "::error::issue-comments read for PR #$PR_NUMBER returned non-array pages or a vacuous body (broken read)" >&2
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
  # read above: on the LIST endpoint every real publisher (Apps included)
  # carries a creator login, so while the reject list is configured a
  # status with NO login is an anomaly and is not evidence — trusting
  # anomalies is the fail-open direction. And same SEQUENCE semantics:
  # anomaly rows stay in the newest-row selection (an anomalous newest row
  # is silence, never a hole an older success shines through), only listed
  # creators are dropped before it. List empty (the default) = filter
  # off = unchanged behavior.
  # The REASON is mandatory (plan Change 2, finding 9, carried from the
  # outage semantics): an override with an empty description is not an
  # attestation, it is an unexplained relaxation — and it is the
  # highest-value status in the system to forge. Enforced here, not merely
  # documented. The reason rides out in the verdict detail below, flattened
  # at the source because it is API text travelling through a one-line
  # contract and a one-line status description.
  # Same newest-accepted-row semantics as the trusted-context read above
  # (the LIST endpoint is a history): an operator withdrawing an override
  # by posting pending/failure on the same context must actually withdraw
  # it — an older success may not outlive the newer row.
  outageok_out="$(jq -r --arg ctx "$OUTAGE_CONTEXT" --arg reject "$PUBLISHER_REJECT" '
    ($reject | split(";") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $rj
    | [ .statuses[]
        | select(.context == $ctx)
        | (.creator.login // "") as $cl
        | select(($rj | length) == 0 or ($cl == "") or (($cl | type) != "string") or (($rj | index($cl)) == null))
      ]
    # FIRST accepted row — same newest-first API-order reliance and
    # second-precision tie rationale as the trusted-context read above.
    | first
    | if . == null then "0\t"
      elif ($rj | length) > 0
           and (((.creator | type) != "object")
                or ((.creator.login | type) != "string")
                or ((.creator.login | length) == 0))
      then "0\t"
      elif .state == "success"
           and (((.description // "") | gsub("^\\s+|\\s+$"; "") | length) > 0)
      then "1\t\((.description // "") | gsub("[\n\r\t]"; " "))"
      else "0\t" end' <<<"$status_resp")" || {
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
    # THE FILES LIST RIDES PAGE ONE ONLY: compare pagination paginates the
    # COMMITS array — later pages are healthy objects that carry no files
    # (demanding one there, as the first vstack#1097 fix did, made every
    # multi-page compare exit 2 and hard-failed the predicate). So: page
    # one must be an object WITH a files array (a page-one without it is a
    # malformed or truncated response — defaulting to [] would carry an
    # approval from a broken read), later pages need only be objects, and
    # the classification reads files from page one alone. The 300-entry
    # API cap still refuses carry below (completeness unprovable at the
    # cap). Same exit-2 contract as every other evidence read.
    cmp="$(jq -s 'if (length > 0) and all(type == "object") and ((.[0].files | type) == "array")
                  then {status: (.[0].status // ""), files: .[0].files}
                  else error("malformed compare page") end' \
              <<<"$cmp_pages" 2>/dev/null)" || {
      echo "::error::could not merge the comparison pages for $base...$HEAD_SHA (non-object page, or page one without a files array)" >&2
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
