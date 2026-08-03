#!/usr/bin/env bash
# Selftest for review-predicate.sh — pins the gate's decision table without
# touching the network. This is the engine's portable proof: every consumer's
# CI runs it in a deliberately UNGATED job (a broken predicate approves
# nothing, so a selftest behind the gate could never run when it matters).
#
# Why this exists: the predicate is the single thing standing between
# "reviewed" and "merged", it is only ever exercised in production, and every
# widening of its evidence sources is a place the gate could be made to say
# "approved" when nothing reviewed anything. The dangerous direction is not a
# false `awaiting` — that is visible and annoying — it is a false `approved`,
# which is silent. So every case below that ends in `approved` is paired with
# a near-miss that must NOT.
#
# TWO LAYERS:
#   1. Mechanism layer — env-forced configurations pin every engine behavior
#      with known values: the evidence sources, the trust model near-misses,
#      the skip-pattern (pass-without-analysis) filter, review-object trust,
#      approval non-supersession, fail-loud reads, and config validation.
#   2. Configured layer — the same approve/near-miss discipline re-derived
#      from THIS repo's resolved REVIEW_GATE_* settings (env >
#      vstack.settings.toml > defaults), so a repo trusting a different bot
#      tests its OWN trust list, not someone else's defaults.
#
# Mechanism: a `gh` shim earlier on PATH answers from fixtures and applies any
# `--jq` filter with real jq, so the predicate runs unmodified. Run:
#
#   .agents/skills/review-gate/scripts/review-predicate-selftest.sh
#
# Exit 0 = all cases pass. Any failure prints the case, the expectation and
# what the predicate actually said.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
predicate="$here/review-predicate.sh"
[ -x "$predicate" ] || { echo "not executable: $predicate" >&2; exit 1; }
. "$here/lib/settings.sh"

# ------------------------------------------------------------ active config ---
# Resolved exactly as the predicate resolves it, from the invoking repo's
# environment/settings. The configured layer generates its cases from these.
# `|| exit 1`: rg_setting fails loud on an unparseable assignment; the
# selftest must not generate cases from a silently-emptied config.
ACTIVE_CONTEXTS="$(rg_setting REVIEW_GATE_TRUSTED_STATUS_CONTEXTS "Devin Review")" || exit 1
ACTIVE_SKIPS="$(rg_setting REVIEW_GATE_CHECKRUN_SKIP_PATTERNS "rate limited;skipped;queued")" || exit 1
ACTIVE_REVIEWERS="$(rg_setting REVIEW_GATE_COMMENT_REVIEWERS "")" || exit 1
ACTIVE_FLOOR="$(rg_setting REVIEW_GATE_SHA_PREFIX_FLOOR "7")" || exit 1
ACTIVE_OUTAGE="$(rg_setting REVIEW_GATE_OUTAGE_CONTEXT "vstack-reviewer-outage")" || exit 1
ACTIVE_TRUSTED_LOGINS="$(rg_setting REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS "")" || exit 1
ACTIVE_MIN_STATE="$(rg_setting REVIEW_GATE_REVIEW_OBJECT_MIN_STATE "any")" || exit 1
ACTIVE_GATE_CONTEXT="$(rg_setting REVIEW_GATE_CONTEXT "Review gate")" || exit 1

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

HEAD='a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'
OTHER='ffffffffffffffffffffffffffffffffffffffff'
AUTHOR='author-under-test'

fixtures="$work/fixtures"
shim="$work/bin"
mkdir -p "$fixtures" "$shim"

# The shim: dispatch on the request, honour --jq, and obey a failure switch so
# the fail-loud path is testable too.
cat >"$shim/gh" <<'SHIM'
#!/usr/bin/env bash
set -u
url=""; filter=""
while [ $# -gt 0 ]; do
  case "$1" in
    api|--paginate|--slurp) ;;
    -f|-F) shift ;;
    --jq) shift; filter="$1" ;;
    graphql) url="graphql" ;;
    *) [ -z "$url" ] && url="$1" ;;
  esac
  shift
done
case "$url" in
  *"/check-runs"*) name=checkruns ;;
  *"/reviews"*)  name=reviews ;;
  *"/statuses"*) name=statuses ;;
  *"/status"*)   name=status ;;
  *"/issues/"*"/comments"*) name=comments ;;
  graphql)       name=graphql ;;
  *"/pulls/"*)   name=pull ;;
  *) echo "shim: unexpected request: $url" >&2; exit 90 ;;
esac
if [ -n "${GH_SHIM_FAIL:-}" ] && [ "$GH_SHIM_FAIL" = "$name" ]; then
  echo "shim: simulated API failure for $name" >&2
  exit 1
fi
file="$GH_SHIM_FIXTURES/$name.json"
[ -f "$file" ] || { echo "shim: no fixture $file" >&2; exit 91; }
if [ -n "$filter" ]; then jq -r "$filter" <"$file"; else cat "$file"; fi
SHIM
chmod +x "$shim/gh"

# ------------------------------------------------------------------ helpers ---
list_items() { # ';'-separated string -> one trimmed non-empty item per line
  printf '%s' "$1" | tr ';' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true
}
first_item() { list_items "$1" | head -n 1; }

comment() { # login, body
  jq -n --arg login "$1" --arg body "$2" '[{user:{login:$login},body:$body}]'
}
threads() { # isResolved values as args
  local nodes="[]"
  for r in "$@"; do nodes="$(jq -c --argjson r "$r" '. + [{isResolved:$r}]' <<<"$nodes")"; done
  jq -n --argjson nodes "$nodes" \
    '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false},nodes:$nodes}}}}}'
}
review() { # login, state, submitted_at -> one review row (append with reviews_add)
  jq -n --arg sha "$HEAD" --arg login "$1" --arg state "$2" --arg at "${3:-2026-01-01T00:00:00Z}" \
    '{commit_id:$sha,state:$state,submitted_at:$at,user:{login:$login}}'
}
reviews_set() { # rows... -> reviews.json
  local rows="[]" row
  for row in "$@"; do rows="$(jq -c --argjson r "$row" '. + [$r]' <<<"$rows")"; done
  printf '%s\n' "$rows" >"$fixtures/reviews.json"
}
checkrun() { # name, conclusion, summary -> checkruns.json
  jq -n --arg name "$1" --arg conclusion "$2" --arg summary "${3:-}" \
    '{check_runs:[{name:$name,conclusion:$conclusion,output:{title:null,summary:$summary}}]}' \
    >"$fixtures/checkruns.json"
}
status_ctx() { # context, state, description -> status.json
  jq -n --arg ctx "$1" --arg state "$2" --arg desc "${3:-}" \
    '{statuses:[{context:$ctx,state:$state,description:$desc}]}' >"$fixtures/status.json"
}

cases=0
failures=0
run() { # case-name, expected-verdict, expected-exit
  local name="$1" want="$2" want_exit="${3:-0}" line rc verdict
  cases=$((cases + 1))
  line="$(PATH="$shim:$PATH" GH_SHIM_FIXTURES="$fixtures" \
    REVIEW_GATE_SETTINGS_FILE=/dev/null \
    REVIEW_GATE_TRUSTED_STATUS_CONTEXTS="$CFG_CONTEXTS" \
    REVIEW_GATE_CHECKRUN_SKIP_PATTERNS="$CFG_SKIPS" \
    REVIEW_GATE_COMMENT_REVIEWERS="$CFG_REVIEWERS" \
    REVIEW_GATE_SHA_PREFIX_FLOOR="$CFG_FLOOR" \
    REVIEW_GATE_OUTAGE_CONTEXT="$CFG_OUTAGE" \
    REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS="$CFG_TRUSTED_LOGINS" \
    REVIEW_GATE_REVIEW_OBJECT_MIN_STATE="$CFG_MIN_STATE" \
    REVIEW_GATE_CONTEXT="$CFG_GATE_CONTEXT" \
    GH_REPO="owner/repo" PR_NUMBER=1 HEAD_SHA="$HEAD" PR_AUTHOR="$AUTHOR" \
    "$predicate" 2>/dev/null)"
  rc=$?
  verdict="${line#verdict=}"; verdict="${verdict%% *}"
  if [ "$rc" != "$want_exit" ]; then
    echo "FAIL  $name: exit $rc, wanted $want_exit" >&2
    failures=$((failures + 1))
    return
  fi
  if [ "$want_exit" = "0" ] && [ "$verdict" != "$want" ]; then
    echo "FAIL  $name: verdict=$verdict, wanted $want" >&2
    failures=$((failures + 1))
    return
  fi
  echo "ok    $name ($want)"
}
reset() {
  printf '[]\n' >"$fixtures/reviews.json"
  printf '[]\n' >"$fixtures/comments.json"
  printf '{"check_runs":[]}\n' >"$fixtures/checkruns.json"
  printf '{"statuses":[]}\n' >"$fixtures/status.json"
  threads >"$fixtures/graphql.json"
  jq -n --arg a "$AUTHOR" '{user:{login:$a}}' >"$fixtures/pull.json"
  unset GH_SHIM_FAIL || true
  CFG_CONTEXTS="$ACTIVE_CONTEXTS"
  CFG_SKIPS="$ACTIVE_SKIPS"
  CFG_REVIEWERS="$ACTIVE_REVIEWERS"
  CFG_FLOOR="$ACTIVE_FLOOR"
  CFG_OUTAGE="$ACTIVE_OUTAGE"
  CFG_TRUSTED_LOGINS="$ACTIVE_TRUSTED_LOGINS"
  CFG_MIN_STATE="$ACTIVE_MIN_STATE"
  CFG_GATE_CONTEXT="$ACTIVE_GATE_CONTEXT"
}

# A review login that the ACTIVE config accepts as review-object evidence.
trusted_reviewer() {
  if [ -n "$ACTIVE_TRUSTED_LOGINS" ]; then first_item "$ACTIVE_TRUSTED_LOGINS"; else echo "reviewer"; fi
}

# The full comment-form battery for one 'login:pattern' pair. Every approving
# case is paired with the near-misses that decide whether the carve-out is a
# trust model or a grep.
comment_battery() { # login, pattern, floor
  local login="$1" pattern="$2" floor="$3" prefix short
  prefix="$(printf '%.*s' "$floor" "$HEAD")"

  reset
  CFG_REVIEWERS="$login:$pattern"; CFG_FLOOR="$floor"
  comment "$login" "$pattern \`$prefix\`" >"$fixtures/comments.json"
  run "[$login] comment, backtick-quoted floor-length sha at head" approved

  reset
  CFG_REVIEWERS="$login:$pattern"; CFG_FLOOR="$floor"
  comment "$login" "$pattern $HEAD" >"$fixtures/comments.json"
  run "[$login] comment, full 40-char sha at head" approved

  # Markdown decoration between the binding pattern and the sha (bold label,
  # backticks) — the real shipped shape of at least one live bot.
  reset
  CFG_REVIEWERS="$login:$pattern"; CFG_FLOOR="$floor"
  comment "$login" "**Clean pass.** **$pattern** \`$prefix\`" >"$fixtures/comments.json"
  run "[$login] comment with markdown-decorated binding line" approved

  # Trust keys on the AUTHOR, so the same words from anyone else are not
  # evidence: a PR author could otherwise approve their own PR by typing a
  # sentence.
  reset
  CFG_REVIEWERS="$login:$pattern"; CFG_FLOOR="$floor"
  comment "mallory" "$pattern \`$prefix\`" >"$fixtures/comments.json"
  run "[$login] SAME BODY, wrong author" awaiting

  reset
  CFG_REVIEWERS="$login:$pattern"; CFG_FLOOR="$floor"
  comment "$AUTHOR" "$pattern \`$prefix\`" >"$fixtures/comments.json"
  run "[$login] same body, posted by the PR AUTHOR" awaiting

  # The body binds the evidence to a commit, so a comment about an earlier
  # push must not vouch for what was pushed after it.
  reset
  CFG_REVIEWERS="$login:$pattern"; CFG_FLOOR="$floor"
  comment "$login" "$pattern \`$(printf '%.*s' "$floor" "$OTHER")\`" >"$fixtures/comments.json"
  run "[$login] comment naming a DIFFERENT sha" awaiting

  reset
  CFG_REVIEWERS="$login:$pattern"; CFG_FLOOR="$floor"
  comment "$login" "Clean pass, no binding line here." >"$fixtures/comments.json"
  run "[$login] comment with no binding line" awaiting

  # A degenerate prefix must not match every head (the floor).
  short="$(printf '%.*s' "$((floor - 1))" "$HEAD")"
  reset
  CFG_REVIEWERS="$login:$pattern"; CFG_FLOOR="$floor"
  comment "$login" "$pattern \`$short\`" >"$fixtures/comments.json"
  run "[$login] comment with a sub-floor sha prefix" awaiting

  # Evidence-present is not evidence-approves-everything: the carve-out
  # substitutes for MISSING evidence only.
  reset
  CFG_REVIEWERS="$login:$pattern"; CFG_FLOOR="$floor"
  comment "$login" "$pattern \`$prefix\`" >"$fixtures/comments.json"
  threads false >"$fixtures/graphql.json"
  run "[$login] clean comment + an unresolved thread" threads-open

  reset
  CFG_REVIEWERS="$login:$pattern"; CFG_FLOOR="$floor"
  comment "$login" "$pattern \`$prefix\`" >"$fixtures/comments.json"
  reviews_set "$(review "reviewer" CHANGES_REQUESTED)"
  run "[$login] clean comment + changes-requested at head" changes-requested

  # A transient read failure must reach NO verdict (exit 2), never
  # "awaiting": acting on an API hiccup could flip a healthy PR's merge
  # state.
  reset
  CFG_REVIEWERS="$login:$pattern"; CFG_FLOOR="$floor"
  export GH_SHIM_FAIL=comments
  run "[$login] comment read failure" "" 2
  unset GH_SHIM_FAIL
}

# Approve/near-miss battery for one trusted check/status context, including
# the pass-without-analysis (skip-pattern) filter.
context_battery() { # context
  local ctx="$1" pat

  reset
  status_ctx "$ctx" success "analysis complete"
  run "[$ctx] clean commit status at head" approved

  reset
  status_ctx "$ctx (untrusted twin)" success "analysis complete"
  run "[$ctx] status under a DIFFERENT context name" awaiting

  reset
  status_ctx "$ctx" pending "still running"
  run "[$ctx] non-success status" awaiting

  reset
  checkrun "$ctx" success "0 findings"
  run "[$ctx] clean check-run at head" approved

  reset
  checkrun "$ctx (untrusted twin)" success "0 findings"
  run "[$ctx] check-run under a DIFFERENT name" awaiting

  reset
  checkrun "$ctx" neutral "analysis skipped"
  run "[$ctx] non-success check-run" awaiting

  # A trusted "pass" must prove analysis RAN: a success whose output matches
  # a skip pattern performed no review, so it is NOT-EVIDENCE (awaiting, the
  # silence path) — never a failure.
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    reset
    checkrun "$ctx" success "Review $pat"
    run "[$ctx] success check-run but output says '$pat' (not evidence)" awaiting
    reset
    status_ctx "$ctx" success "Review $pat"
    run "[$ctx] success status but description says '$pat' (not evidence)" awaiting
  done <<EOF
$(list_items "$CFG_SKIPS")
EOF
}

# ================================================================ mechanism ===
# Env-forced configurations: these pin every engine behavior regardless of the
# invoking repo's own trust settings.
echo "--- mechanism layer (forced configuration)"

# Guards the whole suite: if this ever says `approved`, some evidence source
# has become unconditionally true and every case below is meaningless.
reset
run "no evidence at all" awaiting

reset
export GH_SHIM_FAIL=reviews
run "review read failure" "" 2
unset GH_SHIM_FAIL

reset
export GH_SHIM_FAIL=status
run "combined-status read failure" "" 2
unset GH_SHIM_FAIL

reset
export GH_SHIM_FAIL=checkruns
run "check-run read failure" "" 2
unset GH_SHIM_FAIL

reset
status_ctx "mech-ctx" success "analysis complete"
CFG_CONTEXTS="mech-ctx"
export GH_SHIM_FAIL=graphql
run "thread read failure (with evidence present)" "" 2
unset GH_SHIM_FAIL

# >100 threads is a SUCCESSFUL read we cannot fully verify: fail closed to
# threads-open, never open the gate.
reset
CFG_CONTEXTS="mech-ctx"
status_ctx "mech-ctx" success "analysis complete"
jq -n '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:true},nodes:[]}}}}}' \
  >"$fixtures/graphql.json"
run "thread overflow (>100) fails closed" threads-open

# A thread node whose isResolved is not a boolean (null/missing) must never
# count as resolved — that direction is a false approval on a merge gate.
reset
CFG_CONTEXTS="mech-ctx"
status_ctx "mech-ctx" success "analysis complete"
jq -n '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false},nodes:[{isResolved:null},{isResolved:true}]}}}}}' \
  >"$fixtures/graphql.json"
run "malformed thread node (isResolved null) fails closed" threads-open

# Review-object trust list: empty trusts any non-author (adoption-compatible
# default); non-empty restricts evidence to the listed logins. An untrusted
# login's review must NOT count — this is the boundary where any read-access
# collaborator's drive-by review would otherwise satisfy the gate.
reset
CFG_TRUSTED_LOGINS=""
reviews_set "$(review "rando" APPROVED)"
run "empty trust list: any non-author review counts" approved

reset
CFG_TRUSTED_LOGINS="trusted-bot;other-bot"
reviews_set "$(review "rando" APPROVED)"
run "trust list set: UNTRUSTED login's review is not evidence" awaiting

reset
CFG_TRUSTED_LOGINS="trusted-bot;other-bot"
reviews_set "$(review "trusted-bot" APPROVED)"
run "trust list set: trusted login's review counts" approved

reset
CFG_TRUSTED_LOGINS="trusted-bot"
reviews_set "$(review "$AUTHOR" APPROVED)"
CFG_TRUSTED_LOGINS="trusted-bot;$AUTHOR"
run "trust list set: the PR author is never evidence, even when listed" awaiting

# min_state=approved: a body-only COMMENTED review stops satisfying the gate.
reset
CFG_TRUSTED_LOGINS=""; CFG_MIN_STATE="approved"
reviews_set "$(review "reviewer" COMMENTED)"
run "min_state=approved: COMMENTED-only review is not evidence" awaiting

reset
CFG_TRUSTED_LOGINS=""; CFG_MIN_STATE="approved"
reviews_set "$(review "reviewer" APPROVED)"
run "min_state=approved: APPROVED review counts" approved

reset
CFG_TRUSTED_LOGINS=""; CFG_MIN_STATE="any"
reviews_set "$(review "reviewer" COMMENTED)"
run "min_state=any: COMMENTED review counts (compatible default)" approved

# NON-SUPERSESSION: a trailing COMMENTED from the same reviewer at the same
# head must not mask its earlier APPROVED (observed live: APPROVED at
# :47, COMMENTED at :50 on the same commit — a latest-review-per-reviewer
# reduction reads that as "no approval").
reset
CFG_TRUSTED_LOGINS=""; CFG_MIN_STATE="approved"
reviews_set "$(review "reviewer" APPROVED "2026-08-02T18:28:47Z")" \
            "$(review "reviewer" COMMENTED "2026-08-02T18:28:50Z")"
run "approval NOT superseded by a later COMMENTED (min_state=approved)" approved

reset
CFG_TRUSTED_LOGINS=""; CFG_MIN_STATE="any"
reviews_set "$(review "reviewer" APPROVED "2026-08-02T18:28:47Z")" \
            "$(review "reviewer" COMMENTED "2026-08-02T18:28:50Z")"
run "approval NOT superseded by a later COMMENTED (min_state=any)" approved

# PENDING rows are unsubmitted drafts, not review events: one must neither
# clear a standing changes-requested nor count as evidence.
reset
reviews_set "$(review "reviewer" CHANGES_REQUESTED "2026-08-02T18:00:00Z")" \
            "$(review "reviewer" PENDING "2026-08-02T18:30:00Z")"
run "a PENDING draft after CHANGES_REQUESTED does not clear the objection" changes-requested

reset
reviews_set "$(review "reviewer" PENDING)"
run "a lone PENDING draft is not review evidence" awaiting

# ...but a LATER CHANGES_REQUESTED from the same login does supersede, and
# fails the whole gate closed.
reset
CFG_TRUSTED_LOGINS=""; CFG_MIN_STATE="approved"
reviews_set "$(review "reviewer" APPROVED "2026-08-02T18:28:47Z")" \
            "$(review "reviewer" CHANGES_REQUESTED "2026-08-02T18:30:00Z")"
run "APPROVED then later CHANGES_REQUESTED fails closed" changes-requested

# Recency is decided by submitted_at, never by array position: the same
# cleared objection fed in REVERSED order must still read as cleared.
reset
CFG_TRUSTED_LOGINS=""; CFG_MIN_STATE="approved"
reviews_set "$(review "reviewer" APPROVED "2026-08-02T19:00:00Z")" \
            "$(review "reviewer" CHANGES_REQUESTED "2026-08-02T18:00:00Z")"
run "cleared CR fed in reversed array order stays cleared" approved

# ...and an APPROVED that POST-dates the CR clears it again.
reset
CFG_TRUSTED_LOGINS=""; CFG_MIN_STATE="approved"
reviews_set "$(review "reviewer" CHANGES_REQUESTED "2026-08-02T18:28:47Z")" \
            "$(review "reviewer" APPROVED "2026-08-02T18:30:00Z")"
run "CHANGES_REQUESTED then later APPROVED re-opens" approved

# Changes-requested fails closed regardless of the trust list: anyone's
# standing objection blocks.
reset
CFG_TRUSTED_LOGINS="trusted-bot"
reviews_set "$(review "trusted-bot" APPROVED)" "$(review "rando" CHANGES_REQUESTED)"
run "trusted approval + untrusted changes-requested fails closed" changes-requested

# The pass-without-analysis filter, pinned against the live fixture shape: a
# rate-limited reviewer posted its own check as PASS with "Review rate
# limited" and zero analysis performed.
reset
CFG_CONTEXTS="mech-ctx"; CFG_SKIPS="rate limited"
printf '{"check_runs":[{"name":"mech-ctx","conclusion":"success","output":{"title":"mech-ctx","summary":"Review rate limited. 0 files reviewed."}}]}\n' \
  >"$fixtures/checkruns.json"
run "rate-limited 'pass' check-run is NOT evidence (live fixture)" awaiting

reset
CFG_CONTEXTS="mech-ctx"; CFG_SKIPS="rate limited"
checkrun "mech-ctx" success "Reviewed 12 files, 0 findings"
run "genuine clean pass still counts with skip patterns set" approved

reset
CFG_CONTEXTS="mech-ctx"; CFG_SKIPS=""
checkrun "mech-ctx" success "Review rate limited. 0 files reviewed."
run "empty skip patterns disable the filter (explicit repo choice)" approved

# Skip-pattern matching is case-insensitive.
reset
CFG_CONTEXTS="mech-ctx"; CFG_SKIPS="rate limited"
checkrun "mech-ctx" success "Review RATE LIMITED"
run "skip patterns match case-insensitively" awaiting

# Comment-form mechanism with a forced pair, including a regex-metacharacter
# binding pattern: the pattern is a LITERAL, so metacharacters must not widen
# the match.
comment_battery "mech-bot[bot]" "Analysis (clean) for commit:" 7

reset
CFG_REVIEWERS=""
comment "some-bot[bot]" "Reviewed commit: \`${HEAD:0:7}\`" >"$fixtures/comments.json"
run "no comment reviewers configured: perfect binding line is not evidence" awaiting

reset
CFG_REVIEWERS="mech-bot[bot]:Reviewed commit:"
comment "other-bot[bot]" "Reviewed commit: \`${HEAD:0:7}\`" >"$fixtures/comments.json"
run "comment from a DIFFERENT bot than configured is not evidence" awaiting

# The PR author is excluded even when CONFIGURED as the comment reviewer —
# a bot opening its own update PR must not self-approve it.
reset
CFG_REVIEWERS="$AUTHOR:Reviewed commit:"
comment "$AUTHOR" "Reviewed commit: \`${HEAD:0:7}\`" >"$fixtures/comments.json"
run "configured comment reviewer that IS the PR author cannot self-approve" awaiting

# Floor mechanism at a non-default value.
reset
CFG_REVIEWERS="mech-bot[bot]:Reviewed commit:"; CFG_FLOOR="10"
comment "mech-bot[bot]" "Reviewed commit: \`${HEAD:0:7}\`" >"$fixtures/comments.json"
run "floor=10: 7-char prefix is not evidence" awaiting

reset
CFG_REVIEWERS="mech-bot[bot]:Reviewed commit:"; CFG_FLOOR="10"
comment "mech-bot[bot]" "Reviewed commit: \`${HEAD:0:10}\`" >"$fixtures/comments.json"
run "floor=10: 10-char prefix counts" approved

# Outage attestation substitutes for MISSING evidence only.
reset
CFG_OUTAGE="mech-outage"
status_ctx "mech-outage" success "reviewer outage attested"
run "outage attestation counts as evidence" approved

reset
CFG_OUTAGE="mech-outage"
status_ctx "mech-outage" pending "attempting"
run "non-success outage status is not evidence" awaiting

reset
CFG_OUTAGE="mech-outage"
status_ctx "mech-outage" success "reviewer outage attested"
threads false >"$fixtures/graphql.json"
run "outage attestation + unresolved thread stays closed" threads-open

reset
CFG_OUTAGE=""
status_ctx "vstack-reviewer-outage" success "reviewer outage attested"
run "empty outage context disables the source" awaiting

# Invalid configuration must reach NO verdict (exit 2) — a typo in trust
# config must never quietly widen or narrow the gate.
reset
CFG_FLOOR="abc"
run "non-numeric sha floor is a config error" "" 2

reset
CFG_FLOOR="3"
run "sha floor below 4 is a config error" "" 2

reset
CFG_TRUSTED_LOGINS=""; CFG_MIN_STATE="bogus"
run "unknown min_state is a config error" "" 2

reset
CFG_REVIEWERS="just-a-login-no-pattern"
run "comment reviewer entry without a pattern is a config error" "" 2

# The gate's own context must never be an evidence source: a posted gate
# success counting as review evidence would keep the gate green forever.
reset
CFG_CONTEXTS="Devin Review;Gate X"; CFG_GATE_CONTEXT="Gate X"
run "gate context listed as a trusted status context is a config error" "" 2

reset
CFG_OUTAGE="Gate X"; CFG_GATE_CONTEXT="Gate X"
run "gate context equal to the outage context is a config error" "" 2

reset
CFG_GATE_CONTEXT=""
run "explicitly empty gate context is a config error" "" 2

# ================================================================ configured ===
# The same discipline against THIS repo's resolved trust settings.
echo "--- configured layer (this repo's REVIEW_GATE_* settings)"

reset
reviews_set "$(review "$(trusted_reviewer)" APPROVED)"
run "configured: accepted non-author review object" approved

if [ -n "$ACTIVE_TRUSTED_LOGINS" ]; then
  reset
  reviews_set "$(review "not-on-the-trust-list" APPROVED)"
  run "configured: login outside the repo trust list is not evidence" awaiting
fi

while IFS= read -r ctx; do
  [ -z "$ctx" ] && continue
  context_battery "$ctx"
done <<EOF
$(list_items "$ACTIVE_CONTEXTS")
EOF

while IFS= read -r pair; do
  [ -z "$pair" ] && continue
  comment_battery "${pair%%:*}" "${pair#*:}" "$ACTIVE_FLOOR"
done <<EOF
$(list_items "$ACTIVE_REVIEWERS")
EOF

if [ -n "$ACTIVE_OUTAGE" ]; then
  reset
  status_ctx "$ACTIVE_OUTAGE" success "reviewer outage attested"
  run "configured: outage attestation ($ACTIVE_OUTAGE)" approved
fi

if [ "$failures" -ne 0 ]; then
  echo "review-predicate selftest: $failures of $cases case(s) FAILED" >&2
  exit 1
fi
echo "review-predicate selftest: $cases case(s), all pass"
