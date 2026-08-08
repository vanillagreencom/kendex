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
ACTIVE_CONTEXTS="$(rg_setting REVIEW_GATE_TRUSTED_STATUS_CONTEXTS "")" || exit 1
ACTIVE_SKIPS="$(rg_setting REVIEW_GATE_CHECKRUN_SKIP_PATTERNS "rate limited;skipped;queued")" || exit 1
ACTIVE_REVIEWERS="$(rg_setting REVIEW_GATE_COMMENT_REVIEWERS "")" || exit 1
ACTIVE_FLOOR="$(rg_setting REVIEW_GATE_SHA_PREFIX_FLOOR "7")" || exit 1
# Mirrors the predicate's own resolution (v2 key wins over the legacy name):
# a repo that follows the shipped example and sets only
# REVIEW_GATE_OVERRIDE_CONTEXT must have its OWN override context tested, not
# the legacy default.
ACTIVE_OUTAGE="$(rg_setting REVIEW_GATE_OVERRIDE_CONTEXT "__unset__")" || exit 1
if [ "$ACTIVE_OUTAGE" = "__unset__" ]; then
  ACTIVE_OUTAGE="$(rg_setting REVIEW_GATE_OUTAGE_CONTEXT "vstack-reviewer-outage")" || exit 1
fi
ACTIVE_PUBLISHER_REJECT="$(rg_setting REVIEW_GATE_STATUS_PUBLISHER_REJECT "")" || exit 1
ACTIVE_TRUSTED_LOGINS="$(rg_setting REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS "")" || exit 1
ACTIVE_MIN_STATE="$(rg_setting REVIEW_GATE_REVIEW_OBJECT_MIN_STATE "any")" || exit 1
ACTIVE_GATE_CONTEXT="$(rg_setting REVIEW_GATE_CONTEXT "Review gate")" || exit 1
ACTIVE_THREADS="$(rg_setting REVIEW_GATE_THREADS "enforce")" || exit 1
ACTIVE_API_ATTEMPTS="$(rg_setting REVIEW_GATE_API_ATTEMPTS "1")" || exit 1
ACTIVE_API_DELAY="$(rg_setting REVIEW_GATE_API_RETRY_DELAY_SECONDS "2")" || exit 1
ACTIVE_CARRY="$(rg_setting REVIEW_GATE_CARRY_FORWARD "")" || exit 1

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

HEAD='a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'
OTHER='ffffffffffffffffffffffffffffffffffffffff'
AUTHOR='author-under-test'

fixtures="$work/fixtures"
shim="$work/bin"
mkdir -p "$fixtures" "$shim"

# The shim: dispatch on the request, honour --jq, and obey a failure switch so
# the fail-loud path is testable too. Extras the retry/pagination cases need:
#   GH_SHIM_FAIL_TIMES=N   with GH_SHIM_FAIL: fail only the first N calls for
#                          that endpoint (counter file), then serve — drives
#                          the bounded in-predicate retries
#   GH_SHIM_EMPTY=name     exit 0 with ZERO output bytes for that endpoint —
#                          the broken-producer shape the zero-byte guard
#                          refuses
#   <name>.page2.json      with --paginate: served CONCATENATED after the
#                          first page, exactly gh's multi-page output shape,
#                          so the `jq -s` page merges are actually driven
# Every request URL is appended to .urls.log so cases can pin read shapes
# (per_page, endpoints skipped).
cat >"$shim/gh" <<'SHIM'
#!/usr/bin/env bash
set -u
url=""; filter=""; paginate=0
while [ $# -gt 0 ]; do
  case "$1" in
    api|--slurp) ;;
    --paginate) paginate=1 ;;
    -f|-F) shift ;;
    --jq) shift; filter="$1" ;;
    graphql) url="graphql" ;;
    *) [ -z "$url" ] && url="$1" ;;
  esac
  shift
done
case "$url" in
  *"/check-runs"*) name=checkruns ;;
  *"/compare/"*) name=compare ;;
  *"/reviews"*)  name=reviews ;;
  *"/statuses"*) name=statuses ;;
  *"/status"*)   name=status ;;
  *"/issues/"*"/comments"*) name=comments ;;
  graphql)       name=graphql ;;
  *"/pulls/"*)   name=pull ;;
  *) echo "shim: unexpected request: $url" >&2; exit 90 ;;
esac
echo "$url" >>"$GH_SHIM_FIXTURES/.urls.log"
if [ -n "${GH_SHIM_FAIL:-}" ] && [ "$GH_SHIM_FAIL" = "$name" ]; then
  if [ -n "${GH_SHIM_FAIL_TIMES:-}" ]; then
    count=0
    counter="$GH_SHIM_FIXTURES/.failcount.$name"
    [ -f "$counter" ] && count="$(cat "$counter")"
    if [ "$count" -lt "$GH_SHIM_FAIL_TIMES" ]; then
      echo $((count + 1)) >"$counter"
      echo "shim: simulated API failure for $name ($((count + 1))/$GH_SHIM_FAIL_TIMES)" >&2
      exit 1
    fi
  else
    echo "shim: simulated API failure for $name" >&2
    exit 1
  fi
fi
if [ -n "${GH_SHIM_EMPTY:-}" ] && [ "$GH_SHIM_EMPTY" = "$name" ]; then
  exit 0
fi
file="$GH_SHIM_FIXTURES/$name.json"
[ -f "$file" ] || { echo "shim: no fixture $file" >&2; exit 91; }
if [ -n "$filter" ]; then jq -r "$filter" <"$file"; else cat "$file"; fi
if [ "$paginate" = "1" ] && [ -f "$GH_SHIM_FIXTURES/$name.page2.json" ] && [ -z "$filter" ]; then
  cat "$GH_SHIM_FIXTURES/$name.page2.json"
fi
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
review() { # login, state, submitted_at, [commit sha; default HEAD] -> one review row
  jq -n --arg sha "${4:-$HEAD}" --arg login "$1" --arg state "$2" --arg at "${3:-2026-01-01T00:00:00Z}" \
    '{commit_id:$sha,state:$state,submitted_at:$at,user:{login:$login}}'
}
reviews_set() { # rows... -> reviews.json
  local rows="[]" row
  for row in "$@"; do rows="$(jq -c --argjson r "$row" '. + [$r]' <<<"$rows")"; done
  printf '%s\n' "$rows" >"$fixtures/reviews.json"
}
checkrun() { # name, conclusion, summary, [app slug] -> checkruns.json
  # Real check runs always carry a publishing app; the default models a
  # trusted reviewer's own app. Pass "github-actions" for the near-miss:
  # a PR workflow can publish under ANY NAME through that shared app.
  jq -n --arg name "$1" --arg conclusion "$2" --arg summary "${3:-}" --arg app "${4:-trusted-reviewer-app}" \
    '{check_runs:[{name:$name,conclusion:$conclusion,app:{slug:$app},output:{title:null,summary:$summary}}]}' \
    >"$fixtures/checkruns.json"
}
compare_fix() { # status, [files JSON array] -> compare.json (the N...head delta)
  jq -n --arg status "$1" --argjson files "${2:-[]}" '{status:$status,files:$files}' \
    >"$fixtures/compare.json"
}
delta_file() { # filename, status, patch -> one compare files[] entry
  jq -n --arg fn "$1" --arg status "$2" --arg patch "$3" \
    '{filename:$fn,status:$status,patch:$patch}'
}
status_ctx() { # context, state, description, [creator login] -> statuses.json
  # The predicate reads the STATUSES LIST endpoint, which returns a bare
  # array and — unlike the combined endpoint — carries the real creator
  # login. The default models a normal publisher; pass "" explicitly for the
  # anomalous no-login case the reject-list must not trust. `${4-...}` and
  # NOT `${4:-...}`: the colon form would substitute the default for an
  # explicitly-empty argument, silently turning that case into its opposite.
  jq -n --arg ctx "$1" --arg state "$2" --arg desc "${3:-}" --arg creator "${4-trusted-publisher}" \
    '[{context:$ctx,state:$state,description:$desc,created_at:"2026-01-01T00:00:00Z",
      creator:(if $creator == "" then null else {login:$creator} end)}]' >"$fixtures/statuses.json"
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
    REVIEW_GATE_STATUS_PUBLISHER_REJECT="$CFG_PUBLISHER_REJECT" \
    REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS="$CFG_TRUSTED_LOGINS" \
    REVIEW_GATE_REVIEW_OBJECT_MIN_STATE="$CFG_MIN_STATE" \
    REVIEW_GATE_CONTEXT="$CFG_GATE_CONTEXT" \
    REVIEW_GATE_THREADS="$CFG_THREADS" \
    REVIEW_GATE_API_ATTEMPTS="$CFG_API_ATTEMPTS" \
    REVIEW_GATE_API_RETRY_DELAY_SECONDS="$CFG_API_DELAY" \
    REVIEW_GATE_STATUS_SNAPSHOT_FILE="$CFG_SNAPSHOT" \
    REVIEW_GATE_CARRY_FORWARD="$CFG_CARRY" \
    GH_REPO="owner/repo" PR_NUMBER=1 HEAD_SHA="$HEAD" PR_AUTHOR="$CFG_PR_AUTHOR" \
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
  printf '[]\n' >"$fixtures/statuses.json"
  threads >"$fixtures/graphql.json"
  jq -n --arg a "$AUTHOR" '{user:{login:$a}}' >"$fixtures/pull.json"
  rm -f "$fixtures"/*.page2.json "$fixtures"/.failcount.* "$fixtures"/.urls.log
  unset GH_SHIM_FAIL GH_SHIM_FAIL_TIMES GH_SHIM_EMPTY || true
  CFG_THREADS="$ACTIVE_THREADS"
  CFG_API_ATTEMPTS="$ACTIVE_API_ATTEMPTS"
  CFG_API_DELAY="$ACTIVE_API_DELAY"
  CFG_CARRY="$ACTIVE_CARRY"
  CFG_SNAPSHOT=""
  rm -f "$fixtures/compare.json"
  CFG_PR_AUTHOR="$AUTHOR"
  CFG_CONTEXTS="$ACTIVE_CONTEXTS"
  CFG_SKIPS="$ACTIVE_SKIPS"
  CFG_REVIEWERS="$ACTIVE_REVIEWERS"
  CFG_FLOOR="$ACTIVE_FLOOR"
  CFG_OUTAGE="$ACTIVE_OUTAGE"
  CFG_PUBLISHER_REJECT="$ACTIVE_PUBLISHER_REJECT"
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
  # substitutes for MISSING evidence only. On a repo that disables the CI
  # thread term (REVIEW_GATE_THREADS=off, server-side ruleset is the
  # enforcement point) the same fixture must read approved instead.
  reset
  CFG_REVIEWERS="$login:$pattern"; CFG_FLOOR="$floor"
  comment "$login" "$pattern \`$prefix\`" >"$fixtures/comments.json"
  threads false >"$fixtures/graphql.json"
  if [ "$CFG_THREADS" = "off" ]; then
    run "[$login] clean comment + an unresolved thread (threads=off)" approved
  else
    run "[$login] clean comment + an unresolved thread" threads-open
  fi

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

  # A repo that opts into the publisher reject-list tests its OWN list: the
  # first rejected login must not be able to mint this trusted context.
  if [ -n "$ACTIVE_PUBLISHER_REJECT" ]; then
    reset
    status_ctx "$ctx" success "analysis complete" "$(first_item "$ACTIVE_PUBLISHER_REJECT")"
    run "[$ctx] status minted by a rejected publisher is not evidence" awaiting
  fi

  reset
  status_ctx "$ctx" pending "still running"
  run "[$ctx] non-success status" awaiting

  # THE NEWEST ROW DECIDES. The statuses LIST endpoint returns the full
  # history NEWEST-FIRST (fixtures model that order — the predicate takes
  # the first accepted row, because created_at ties at one-second
  # precision and a sort would be stable the wrong way): an older success
  # must never outlive a newer non-success on the same context (a reviewer
  # opening a fresh round posts pending over its own earlier success), and
  # the reverse order must still count.
  reset
  jq -n --arg ctx "$ctx" '[
    {context:$ctx,state:"failure",description:"issues found",created_at:"2026-01-02T00:00:00Z",creator:{login:"trusted-publisher"}},
    {context:$ctx,state:"success",description:"analysis complete",created_at:"2026-01-01T00:00:00Z",creator:{login:"trusted-publisher"}}
  ]' >"$fixtures/statuses.json"
  run "[$ctx] older success under a NEWER failure (stale history is not evidence)" awaiting

  reset
  jq -n --arg ctx "$ctx" '[
    {context:$ctx,state:"success",description:"analysis complete",created_at:"2026-01-02T00:00:00Z",creator:{login:"trusted-publisher"}},
    {context:$ctx,state:"failure",description:"issues found",created_at:"2026-01-01T00:00:00Z",creator:{login:"trusted-publisher"}}
  ]' >"$fixtures/statuses.json"
  run "[$ctx] newest success over an older failure still counts" approved

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
export GH_SHIM_FAIL=statuses
run "commit-statuses read failure" "" 2
unset GH_SHIM_FAIL

reset
# The check-runs read only happens for a configured trusted context (the
# shipped default is empty = source disabled), so force one.
CFG_CONTEXTS="mech-ctx"
export GH_SHIM_FAIL=checkruns
run "check-run read failure" "" 2
unset GH_SHIM_FAIL

reset
status_ctx "mech-ctx" success "analysis complete"
CFG_CONTEXTS="mech-ctx"; CFG_THREADS="enforce"
export GH_SHIM_FAIL=graphql
run "thread read failure (with evidence present)" "" 2
unset GH_SHIM_FAIL

# Check-run names are not reserved: any PR workflow with checks:write can
# publish under ANY name through the shared github-actions app, while real
# reviewer bots publish under their own app slug. A github-actions-published
# name-match must stay not-evidence (VST-19) — the paired trusted-app case
# proves the rejection is what separates them.
reset
CFG_CONTEXTS="mech-ctx"
checkrun "mech-ctx" success "analysis complete"
run "trusted-app check-run success is evidence" approved

reset
CFG_CONTEXTS="mech-ctx"
checkrun "mech-ctx" success "analysis complete" "github-actions"
run "github-actions-published check-run under a trusted name is not evidence" awaiting

# Fail closed on provenance too: a check run with NO app slug at all has
# unprovable provenance and is not evidence either.
reset
CFG_CONTEXTS="mech-ctx"
jq -n '{check_runs:[{name:"mech-ctx",conclusion:"success",output:{title:null,summary:"analysis complete"}}]}' >"$fixtures/checkruns.json"
run "check-run with no app slug (unprovable provenance) is not evidence" awaiting

# Legacy commit STATUSES carry no app slug, only a creator — and on repos
# whose PR workflows hold statuses:write, PR content can mint one under any
# context through github-actions[bot]. The OPT-IN publisher reject-list
# (REVIEW_GATE_STATUS_PUBLISHER_REJECT) must drop a listed creator's status
# while an unlisted login stays evidence. A status with NO creator login is
# ALSO dropped while the list is configured: the predicate reads the statuses
# LIST endpoint, where every real publisher carries a login, so a missing one
# is an anomaly and trusting anomalies is the fail-open direction. (The
# COMBINED endpoint nulls every App-posted creator, which made this filter
# inert — vstack#1099, caught live by sandbox scenario 6.) The shipped
# default (empty list) must change nothing.
reset
CFG_CONTEXTS="mech-ctx"; CFG_PUBLISHER_REJECT="github-actions[bot]"
status_ctx "mech-ctx" success "analysis complete" "github-actions[bot]"
run "publisher filter set: github-actions-minted trusted status is not evidence" awaiting

reset
CFG_CONTEXTS="mech-ctx"; CFG_PUBLISHER_REJECT="github-actions[bot]"
status_ctx "mech-ctx" success "analysis complete" "trusted-status-bot"
run "publisher filter set: unlisted creator login is still evidence" approved

reset
CFG_CONTEXTS="mech-ctx"; CFG_PUBLISHER_REJECT="github-actions[bot]"
status_ctx "mech-ctx" success "analysis complete" ""
run "publisher filter set: a status with NO creator login is not evidence" awaiting

reset
CFG_CONTEXTS="mech-ctx"; CFG_PUBLISHER_REJECT=""
status_ctx "mech-ctx" success "analysis complete" "github-actions[bot]"
run "publisher filter unset: github-actions-minted status counts (default unchanged)" approved

# >100 threads is a SUCCESSFUL read we cannot fully verify: fail closed to
# threads-open, never open the gate.
reset
CFG_CONTEXTS="mech-ctx"; CFG_THREADS="enforce"
status_ctx "mech-ctx" success "analysis complete"
jq -n '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:true},nodes:[]}}}}}' \
  >"$fixtures/graphql.json"
run "thread overflow (>100) fails closed" threads-open

# A thread node whose isResolved is not a boolean (null/missing) must never
# count as resolved — that direction is a false approval on a merge gate.
reset
CFG_CONTEXTS="mech-ctx"; CFG_THREADS="enforce"
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

# An objection persists ACROSS PUSHES: GitHub does not clear a
# changes-requested when the author pushes a new head, so evidence on the
# fresh head must not open the gate past it...
reset
CFG_TRUSTED_LOGINS=""; CFG_MIN_STATE="any"
reviews_set "$(review "objector" CHANGES_REQUESTED "2026-08-02T18:00:00Z" "$OTHER")" \
            "$(review "reviewer" APPROVED "2026-08-02T19:00:00Z")"
run "CR on a previous commit still blocks a freshly-approved head" changes-requested

# ...and a later APPROVED from the same reviewer (at the new head) clears it.
reset
CFG_TRUSTED_LOGINS=""; CFG_MIN_STATE="any"
reviews_set "$(review "objector" CHANGES_REQUESTED "2026-08-02T18:00:00Z" "$OTHER")" \
            "$(review "objector" APPROVED "2026-08-02T19:00:00Z")"
run "the objector re-approving at the new head clears their old-commit CR" approved

# An objection is never withdrawn by a later COMMENT — the mirror of the
# approval-is-never-superseded rule. GitHub keeps requested changes standing
# until re-approval or dismissal, and so does the reduction.
reset
reviews_set "$(review "reviewer" CHANGES_REQUESTED "2026-08-02T18:00:00Z")" \
            "$(review "reviewer" COMMENTED "2026-08-02T19:00:00Z")" \
            "$(review "other-reviewer" APPROVED "2026-08-02T19:30:00Z")"
run "trailing COMMENTED does not withdraw a standing CR" changes-requested

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
# limited" and zero analysis performed. The fixture carries a trusted app
# slug: without one, the provenance rejection would reach "awaiting" first
# and this case would stop exercising the skip-pattern text at all.
reset
CFG_CONTEXTS="mech-ctx"; CFG_SKIPS="rate limited"
printf '{"check_runs":[{"name":"mech-ctx","conclusion":"success","app":{"slug":"trusted-reviewer-app"},"output":{"title":"mech-ctx","summary":"Review rate limited. 0 files reviewed."}}]}\n' \
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

# Withdrawal must work: an operator posting pending over their own earlier
# override retracts it — the newest row (listed first; API order) decides.
reset
CFG_OUTAGE="mech-outage"
jq -n '[
  {context:"mech-outage",state:"pending",description:"withdrawn",created_at:"2026-01-02T00:00:00Z",creator:{login:"trusted-publisher"}},
  {context:"mech-outage",state:"success",description:"outage attested",created_at:"2026-01-01T00:00:00Z",creator:{login:"trusted-publisher"}}
]' >"$fixtures/statuses.json"
run "override withdrawn by a newer non-success row is not evidence" awaiting

reset
CFG_OUTAGE="mech-outage"; CFG_THREADS="enforce"
status_ctx "mech-outage" success "reviewer outage attested"
threads false >"$fixtures/graphql.json"
run "outage attestation + unresolved thread stays closed" threads-open

reset
CFG_OUTAGE=""
status_ctx "vstack-reviewer-outage" success "reviewer outage attested"
run "empty outage context disables the source" awaiting

# The publisher reject-list guards the outage read too: the sanctioned
# relaxation is the highest-value status to forge, so a listed creator must
# not be able to mint it — while an unlisted publisher's attestation stays
# accepted.
reset
CFG_OUTAGE="mech-outage"; CFG_PUBLISHER_REJECT="github-actions[bot]"
status_ctx "mech-outage" success "reviewer outage attested" "github-actions[bot]"
run "publisher filter set: github-actions-minted outage attestation is not evidence" awaiting

reset
CFG_OUTAGE="mech-outage"; CFG_PUBLISHER_REJECT="github-actions[bot]"
status_ctx "mech-outage" success "reviewer outage attested" "trusted-orchestrator"
run "publisher filter set: unlisted-login outage attestation still counts" approved

# The outage read is a separate jq implementation, so its null/default
# semantics need their own pins: a creator-less attestation is not evidence
# while the list is configured, and the empty default stays publisher-blind
# even for github-actions — Actions-posted attestation is legitimate on some
# repos (vstack's own sweep/refire included).
reset
CFG_OUTAGE="mech-outage"; CFG_PUBLISHER_REJECT="github-actions[bot]"
status_ctx "mech-outage" success "reviewer outage attested" ""
run "publisher filter set: an outage attestation with NO creator login is not evidence" awaiting

reset
CFG_OUTAGE="mech-outage"; CFG_PUBLISHER_REJECT=""
status_ctx "mech-outage" success "reviewer outage attested" "github-actions[bot]"
run "publisher filter unset: github-actions-minted outage attestation counts (default unchanged)" approved

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

# DISMISSED rows, both directions (VST-35): a dismissed review at head must
# not count as evidence, and a dismissed CHANGES_REQUESTED must not stand —
# GitHub rewrites a dismissed row's state to DISMISSED, and both filters
# must actually be able to fail.
reset
CFG_TRUSTED_LOGINS=""
reviews_set "$(review "reviewer" DISMISSED)"
run "a DISMISSED review at head is not evidence" awaiting

reset
CFG_TRUSTED_LOGINS=""
reviews_set "$(review "objector" DISMISSED "2026-08-02T18:00:00Z")" \
            "$(review "reviewer" APPROVED "2026-08-02T19:00:00Z")"
run "a dismissed CHANGES_REQUESTED does not stand (reduction skips DISMISSED)" approved

# Thread-term configurability (REVIEW_GATE_THREADS, VST-35): `off` never
# emits threads-open AND skips the GraphQL read entirely — proven by making
# the endpoint fail, which must not matter when the read is skipped.
reset
CFG_CONTEXTS="mech-ctx"; CFG_THREADS="off"
status_ctx "mech-ctx" success "analysis complete"
threads false >"$fixtures/graphql.json"
run "threads=off: unresolved thread does not close the gate" approved

reset
CFG_CONTEXTS="mech-ctx"; CFG_THREADS="off"
status_ctx "mech-ctx" success "analysis complete"
export GH_SHIM_FAIL=graphql
run "threads=off: the reviewThreads read is skipped entirely (failing endpoint cannot matter)" approved
unset GH_SHIM_FAIL
cases=$((cases + 1))
# Fail-closed on the instrument itself: a missing/empty url log proves
# nothing about the read being skipped (vstack#1097) — the run above made
# other API reads, so the log must exist and be non-empty.
if [ ! -s "$fixtures/.urls.log" ]; then
  echo "FAIL  threads=off url log missing or empty - cannot prove the read was skipped" >&2
  failures=$((failures + 1))
elif grep -q '^graphql$' "$fixtures/.urls.log"; then
  echo "FAIL  threads=off issued a reviewThreads read anyway" >&2
  failures=$((failures + 1))
else
  echo "ok    threads=off issues no reviewThreads read (url log)"
fi

reset
CFG_CONTEXTS="mech-ctx"; CFG_THREADS="enforce"
status_ctx "mech-ctx" success "analysis complete"
threads false >"$fixtures/graphql.json"
run "threads=enforce (the default): unresolved thread still fails closed" threads-open

reset
CFG_THREADS="sometimes"
run "unknown REVIEW_GATE_THREADS value is a config error" "" 2

# Bounded evidence-read retries (REVIEW_GATE_API_ATTEMPTS /
# REVIEW_GATE_API_RETRY_DELAY_SECONDS, VST-35): a transient failure within
# the budget still reaches a verdict; the default single attempt does not
# retry; failing through every attempt keeps the exit-2 contract.
reset
CFG_API_ATTEMPTS=3; CFG_API_DELAY=0; CFG_TRUSTED_LOGINS=""
reviews_set "$(review "reviewer" APPROVED)"
export GH_SHIM_FAIL=reviews GH_SHIM_FAIL_TIMES=2
run "retries: a read succeeding on attempt 3 of 3 reaches a verdict" approved
unset GH_SHIM_FAIL GH_SHIM_FAIL_TIMES

reset
CFG_API_ATTEMPTS=1; CFG_API_DELAY=0; CFG_TRUSTED_LOGINS=""
reviews_set "$(review "reviewer" APPROVED)"
export GH_SHIM_FAIL=reviews GH_SHIM_FAIL_TIMES=1
run "retries: the default single attempt does not retry (today's behavior)" "" 2
unset GH_SHIM_FAIL GH_SHIM_FAIL_TIMES

reset
CFG_API_ATTEMPTS=2; CFG_API_DELAY=0
export GH_SHIM_FAIL=reviews
run "retries: failing through every attempt is still exit 2 (no verdict)" "" 2
unset GH_SHIM_FAIL

reset
CFG_API_ATTEMPTS=0
run "zero API attempts is a config error" "" 2

reset
CFG_API_ATTEMPTS="lots"
run "non-numeric API attempts is a config error" "" 2

reset
CFG_API_DELAY="-1"
run "negative retry delay is a config error" "" 2

# Multi-page pagination merges (VST-35): the shim serves <name>.page2.json
# concatenated after page 1 under --paginate, so the `jq -s` page merges are
# driven with real multi-page shapes — evidence beyond page 1 must count and
# a standing CR beyond page 1 must still block.
reset
CFG_TRUSTED_LOGINS=""
jq -n --argjson r "$(review "reviewer" COMMENTED "2026-01-01T00:00:00Z" "$OTHER")" '[$r]' >"$fixtures/reviews.json"
jq -n --argjson r "$(review "reviewer" APPROVED "2026-01-02T00:00:00Z")" '[$r]' >"$fixtures/reviews.page2.json"
run "pagination: review evidence on page 2 counts (page merge)" approved

reset
CFG_TRUSTED_LOGINS=""
jq -n --argjson r "$(review "reviewer" APPROVED)" '[$r]' >"$fixtures/reviews.json"
jq -n --argjson r "$(review "objector" CHANGES_REQUESTED)" '[$r]' >"$fixtures/reviews.page2.json"
run "pagination: a standing CR on page 2 still fails closed" changes-requested

reset
CFG_REVIEWERS="mech-bot[bot]:Reviewed commit:"; CFG_FLOOR=7
comment "mech-bot[bot]" "no binding line on page 1" >"$fixtures/comments.json"
comment "mech-bot[bot]" "Reviewed commit: \`${HEAD:0:7}\`" >"$fixtures/comments.page2.json"
run "pagination: comment-form evidence on page 2 counts" approved

reset
CFG_CONTEXTS="mech-ctx"
status_ctx "unrelated-ctx" success "someone else's status"
jq -n '[{context:"mech-ctx",state:"success",description:"analysis complete",created_at:"2026-01-01T00:00:00Z",creator:{login:"trusted-publisher"}}]' >"$fixtures/statuses.page2.json"
run "pagination: trusted status on statuses page 2 counts" approved

reset
CFG_CONTEXTS="mech-ctx"
jq -n '{check_runs:[{name:"mech-ctx",conclusion:"success",app:{slug:"trusted-reviewer-app"},output:{title:null,summary:"analysis complete"}}]}' >"$fixtures/checkruns.page2.json"
run "pagination: trusted check-run on page 2 counts" approved

# PR_AUTHOR resolution (VST-35): every other case passes PR_AUTHOR
# explicitly; an EMPTY PR_AUTHOR must resolve from pulls/N (.user.login) —
# and the resolved author is excluded like an explicit one; a failed
# resolution read is exit 2.
reset
CFG_PR_AUTHOR=""
reviews_set "$(review "$AUTHOR" APPROVED)"
run "empty PR_AUTHOR: author resolves from pulls/N — own review is not evidence" awaiting

reset
CFG_PR_AUTHOR=""; CFG_TRUSTED_LOGINS=""
reviews_set "$(review "reviewer" APPROVED)"
run "empty PR_AUTHOR: non-author review still counts after resolution" approved

reset
CFG_PR_AUTHOR=""
export GH_SHIM_FAIL=pull
run "empty PR_AUTHOR: author-resolution read failure is exit 2" "" 2
unset GH_SHIM_FAIL

# Zero-byte producers (VST-46): a paginated read whose producer exits 0 with
# ZERO output bytes is a broken read, never an empty page set — the reviews
# case is the dangerous one (an erased standing CR while other evidence
# satisfies the positive side would be a false approved). A real empty page
# set is a non-empty `[]` body and stays valid (pinned by every reset case).
reset
export GH_SHIM_EMPTY=reviews
run "zero-byte reviews producer is a failed read (exit 2), not empty evidence" "" 2
unset GH_SHIM_EMPTY

reset
export GH_SHIM_EMPTY=statuses
run "zero-byte commit-statuses producer is a failed read" "" 2
unset GH_SHIM_EMPTY

reset
CFG_CONTEXTS="mech-ctx"
export GH_SHIM_EMPTY=checkruns
run "zero-byte check-runs producer is a failed read" "" 2
unset GH_SHIM_EMPTY

reset
CFG_REVIEWERS="mech-bot[bot]:Reviewed commit:"
export GH_SHIM_EMPTY=comments
run "zero-byte comments producer is a failed read" "" 2
unset GH_SHIM_EMPTY

# Status-snapshot seam (VST-35): a caller that already holds the combined
# status hands it in; the predicate must evaluate against it WITHOUT its own
# combined-status read (proven by failing that endpoint), and an unreadable
# or malformed snapshot gets the read contract: exit 2. The snapshot must be
# BOUND to this head (top-level sha == HEAD_SHA, VST-71): a snapshot for
# another head passing shape validation would evaluate stale evidence.
reset
CFG_CONTEXTS="mech-ctx"
jq -n --arg sha "$HEAD" '{sha:$sha,statuses:[{context:"mech-ctx",state:"success",description:"analysis complete",created_at:"2026-01-01T00:00:00Z",creator:{login:"trusted-publisher"}}]}' >"$fixtures/snapshot.json"
CFG_SNAPSHOT="$fixtures/snapshot.json"
export GH_SHIM_FAIL=statuses
run "snapshot seam: caller-supplied combined status (sha-bound) is evaluated, duplicate read skipped" approved
unset GH_SHIM_FAIL

reset
CFG_SNAPSHOT="$fixtures/no-such-snapshot.json"
run "snapshot seam: unreadable snapshot file is exit 2" "" 2

reset
printf 'not json\n' >"$fixtures/bad-snapshot.json"
CFG_SNAPSHOT="$fixtures/bad-snapshot.json"
run "snapshot seam: malformed snapshot is exit 2" "" 2

reset
printf '[]\n' >"$fixtures/array-snapshot.json"
CFG_SNAPSHOT="$fixtures/array-snapshot.json"
run "snapshot seam: snapshot without a statuses array is exit 2" "" 2

reset
: >"$fixtures/empty-snapshot.json"
CFG_SNAPSHOT="$fixtures/empty-snapshot.json"
run "snapshot seam: EMPTY snapshot file is exit 2 (jq emits nothing yet exits 0)" "" 2

reset
CFG_CONTEXTS="mech-ctx"
jq -n --arg sha "$OTHER" '{sha:$sha,statuses:[{context:"mech-ctx",state:"success",description:"analysis complete",creator:null}]}' >"$fixtures/stale-snapshot.json"
CFG_SNAPSHOT="$fixtures/stale-snapshot.json"
run "snapshot seam: snapshot bound to a DIFFERENT head is exit 2 (never stale evidence)" "" 2

reset
CFG_CONTEXTS="mech-ctx"
jq -n '{statuses:[{context:"mech-ctx",state:"success",description:"analysis complete",creator:null}]}' >"$fixtures/unbound-snapshot.json"
CFG_SNAPSHOT="$fixtures/unbound-snapshot.json"
run "snapshot seam: snapshot with NO top-level sha is exit 2 (binding required)" "" 2

# Multi-value snapshots (vstack#1086): a caller that concatenates page
# responses instead of merging their statuses used to yield one normalized
# object per value; downstream per-value jq reads then emitted multi-line
# counts ("0\n0") that dodge every string comparison — with no trusted
# contexts that fell through to verdict=approved on zero evidence. The
# snapshot contract is exactly ONE head-bound object; anything else is a
# broken caller handoff.
reset
CFG_CONTEXTS="mech-ctx"
{ jq -n --arg sha "$HEAD" '{sha:$sha,statuses:[{context:"mech-ctx",state:"success",description:"analysis complete",creator:null}]}'
  jq -n --arg sha "$HEAD" '{sha:$sha,statuses:[]}'; } >"$fixtures/multi-snapshot.json"
CFG_SNAPSHOT="$fixtures/multi-snapshot.json"
run "snapshot seam: multi-value snapshot (concatenated pages) is exit 2" "" 2

reset
CFG_CONTEXTS=""
CFG_OUTAGE="mech-outage"
printf '{"sha":"%s","statuses":[]}\n{"sha":"%s","statuses":[]}\n' "$HEAD" "$HEAD" >"$fixtures/multi-snapshot.json"
CFG_SNAPSHOT="$fixtures/multi-snapshot.json"
run "snapshot seam: multi-value snapshot with NO trusted contexts is exit 2 (was approved on zero evidence)" "" 2

# Statuses-page validation (VST-71): a nonempty NON-ARRAY page (`{}`, an
# error object) survives the zero-byte guard, and a lax merge would collapse
# it into an empty list — a verdict from broken evidence. Every page must be
# a JSON array; anything else is a broken read: exit 2, never an
# empty-evidence verdict.
reset
printf '{}\n' >"$fixtures/statuses.json"
run "statuses page that is not an array is exit 2, not empty evidence" "" 2

reset
printf '{"statuses":[]}\n' >"$fixtures/statuses.json"
run "combined-status SHAPE served to the list read is exit 2 (wrong endpoint shape)" "" 2

reset
printf '\n   \n' >"$fixtures/statuses.json"
run "whitespace-only statuses response is exit 2, not a vacuous empty status set (vstack#1086)" "" 2

reset
CFG_CONTEXTS="mech-ctx"
jq -n --arg sha "$HEAD" '{sha:$sha,statuses:{}}' >"$fixtures/objstat-snapshot.json"
CFG_SNAPSHOT="$fixtures/objstat-snapshot.json"
run "snapshot seam: snapshot with non-array statuses is exit 2" "" 2

reset
CFG_CONTEXTS="mech-ctx"
status_ctx "mech-ctx" success "analysis complete"
printf '{}\n' >"$fixtures/statuses.page2.json"
run "malformed statuses page 2 poisons the merge: exit 2" "" 2

# Read shapes (VST-35): the reviews and comments endpoints must request
# per_page=100 — the 30-item default paginates long PRs into pure overhead.
reset
CFG_REVIEWERS="mech-bot[bot]:Reviewed commit:"; CFG_FLOOR=7
comment "mech-bot[bot]" "Reviewed commit: \`${HEAD:0:7}\`" >"$fixtures/comments.json"
run "read-shape pin: evidence still evaluates (per_page probe)" approved
cases=$((cases + 1))
if grep -q 'reviews?per_page=100' "$fixtures/.urls.log" 2>/dev/null \
   && grep -q 'comments?per_page=100' "$fixtures/.urls.log" 2>/dev/null; then
  echo "ok    reviews and comments reads carry per_page=100 (url log)"
else
  echo "FAIL  reviews/comments reads must carry per_page=100" >&2
  failures=$((failures + 1))
fi

# Evidence carry-forward across carry-safe deltas (VST-57): evidence at an
# ancestor N extends to head ONLY when carry-forward is enabled AND the
# N→head delta classifies entirely into the enabled classes (or the trees
# are identical). Never a waiver: code deltas refuse, changes-requested and
# unresolved threads still fail closed, and the off default keeps today's
# exact-head behavior.
DOCS_DELTA="$(delta_file "README.md" modified '@@ -1 +1 @@
-old prose
+new prose')"
CODE_DELTA="$(delta_file "src/thing.sh" modified '@@ -1 +1 @@
-do_the_thing
+do_the_other_thing')"
COMMENT_DELTA="$(delta_file "src/thing.sh" modified '@@ -1,2 +1,2 @@
-# old comment
+# newer comment
   untouched_code_line')"
carry_candidate() { # an accepted review object at the OTHER (ancestor) sha
  CFG_TRUSTED_LOGINS=""
  reviews_set "$(review "reviewer" APPROVED "2026-01-01T00:00:00Z" "$OTHER")"
}

reset
carry_candidate
CFG_CARRY="docs"
compare_fix ahead "[$DOCS_DELTA]"
run "carry: docs-only delta from a reviewed ancestor carries" approved

reset
carry_candidate
CFG_CARRY=""
compare_fix ahead "[$DOCS_DELTA]"
run "carry off (default): the same docs delta does NOT carry" awaiting

reset
carry_candidate
CFG_CARRY="docs"
compare_fix ahead "[$CODE_DELTA]"
run "carry: a code delta refuses (fresh evidence required)" awaiting

reset
carry_candidate
CFG_CARRY="docs"
compare_fix ahead "[$DOCS_DELTA,$CODE_DELTA]"
run "carry: one non-carry-safe file refuses the whole delta" awaiting

# The docs class is extension-based, never directory-based: docs/conf.py is
# executable code living under docs/ and must refuse.
DOCS_DIR_CODE_DELTA="$(delta_file "docs/conf.py" modified '@@ -1 +1 @@
-extensions = []
+extensions = ["evil"]')"
reset
carry_candidate
CFG_CARRY="docs"
compare_fix ahead "[$DOCS_DIR_CODE_DELTA]"
run "carry: a code file under docs/ refuses (extension rule, not directory)" awaiting

reset
carry_candidate
CFG_CARRY="comments"
compare_fix ahead "[$COMMENT_DELTA]"
run "carry: comment-only change to a code file carries under 'comments'" approved

reset
carry_candidate
CFG_CARRY="docs"
compare_fix ahead "[$COMMENT_DELTA]"
run "carry: comment-only delta does NOT carry when only 'docs' is enabled" awaiting

reset
carry_candidate
CFG_CARRY="docs|comments"
compare_fix ahead "[$DOCS_DELTA,$COMMENT_DELTA]"
run "carry: '|' separator — mixed docs+comment delta carries with both classes" approved

reset
carry_candidate
CFG_CARRY="comments"
compare_fix ahead "[$(delta_file "src/thing.unknownext" modified '@@ -1 +1 @@
-# a
+# b')]"
run "carry: unknown extension refuses even a comment-looking delta" awaiting

reset
carry_candidate
CFG_CARRY="comments"
compare_fix ahead "[$(delta_file "src/new.sh" added '@@ -0,0 +1 @@
+# new file of comments')]"
run "carry: an ADDED file refuses under 'comments' (modified-only)" awaiting

# vstack#1097 negative controls: shebang lines, renames into .md, and
# malformed later compare pages must all refuse or fail loud.
reset
carry_candidate
CFG_CARRY="comments"
compare_fix ahead "[$(delta_file "src/thing.sh" modified '@@ -1 +1 @@
-#!/usr/bin/env bash
+#!/usr/bin/env dash')]"
run "carry: a changed shebang line is an interpreter change, not a comment" awaiting

reset
carry_candidate
CFG_CARRY="docs"
compare_fix ahead "[$(jq -n '{filename:"notes.md",previous_filename:"src/thing.sh",status:"renamed",patch:"@@ -1 +1 @@\n-do_the_thing\n+do_the_thing"}')]"
run "carry: a code file RENAMED to a .md name refuses under 'docs'" awaiting

# Real API shape (compare pagination paginates COMMITS): a later page is a
# healthy OBJECT with no files array — files ride page one only. Carry must
# still work across it, and a non-object later page must fail loud.
reset
carry_candidate
CFG_CARRY="docs"
compare_fix ahead "[$DOCS_DELTA]"
printf '{"commits": []}\n' >"$fixtures/compare.page2.json"
run "carry: a fileless later compare page (real pagination shape) still carries" approved

reset
carry_candidate
CFG_CARRY="docs"
compare_fix ahead "[$DOCS_DELTA]"
printf '[]\n' >"$fixtures/compare.page2.json"
run "carry: a non-object later compare page is exit 2, never a partial classification" "" 2

reset
carry_candidate
CFG_CARRY="docs"
compare_fix ahead "[$DOCS_DELTA]"
jq -n --argjson f "[$DOCS_DELTA]" '{status:"ahead",files:$f}' >"$fixtures/compare.page2.json"
run "carry: a healthy later compare page merges into the classification" approved

reset
carry_candidate
CFG_CARRY="docs"
compare_fix identical
run "carry: identical tree (rebase residue) carries once any class is enabled" approved

reset
carry_candidate
CFG_CARRY="docs"
compare_fix ahead
run "carry: ahead with zero changed files is an identical tree — carries" approved

reset
carry_candidate
CFG_CARRY="docs"
compare_fix diverged "[$DOCS_DELTA]"
run "carry: a non-ancestor candidate (diverged) never carries" awaiting

reset
carry_candidate
CFG_CARRY="docs"
compare_fix ahead "[$DOCS_DELTA]"
reviews_set "$(review "reviewer" APPROVED "2026-01-01T00:00:00Z" "$OTHER")" \
            "$(review "objector" CHANGES_REQUESTED "2026-01-02T00:00:00Z" "$OTHER")"
run "carry never waives a standing changes-requested" changes-requested

reset
carry_candidate
CFG_CARRY="docs"; CFG_THREADS="enforce"
compare_fix ahead "[$DOCS_DELTA]"
threads false >"$fixtures/graphql.json"
run "carry never waives an unresolved thread" threads-open

reset
CFG_CARRY="docs"; CFG_TRUSTED_LOGINS=""
reviews_set "$(review "reviewer" DISMISSED "2026-01-01T00:00:00Z" "$OTHER")"
run "carry: a DISMISSED ancestor review is not a carry candidate" awaiting

reset
CFG_CARRY="docs"; CFG_TRUSTED_LOGINS=""
reviews_set "$(review "$AUTHOR" APPROVED "2026-01-01T00:00:00Z" "$OTHER")"
run "carry: the author's own ancestor review is not a carry candidate" awaiting

reset
CFG_CARRY="docs"; CFG_TRUSTED_LOGINS=""; CFG_MIN_STATE="approved"
reviews_set "$(review "reviewer" COMMENTED "2026-01-01T00:00:00Z" "$OTHER")"
run "carry: min_state=approved refuses a COMMENTED-only ancestor candidate" awaiting

reset
carry_candidate
CFG_CARRY="docs"
export GH_SHIM_FAIL=compare
run "carry: a failed compare read is exit 2, never a guessed carry" "" 2
unset GH_SHIM_FAIL

reset
carry_candidate
CFG_CARRY="docs"
export GH_SHIM_EMPTY=compare
run "carry: a zero-byte compare producer is exit 2" "" 2
unset GH_SHIM_EMPTY

# A healthy compare response ALWAYS carries a files array; a parseable
# response without one is malformed/truncated, and defaulting it to []
# would carry as an "identical tree" — a broken read must never approve.
reset
carry_candidate
CFG_CARRY="docs"
jq -n '{status:"ahead"}' >"$fixtures/compare.json"
run "carry: an ahead compare with NO files array is exit 2, never an identical-tree guess" "" 2

# The compare API caps its file list at 300 entries: AT the cap the list
# cannot prove the delta is complete (an omitted file could be code), so
# the carry refuses; one below the cap is a complete list and carries.
reset
carry_candidate
CFG_CARRY="docs"
compare_fix ahead "$(jq -n '[range(300) | {filename:("docs/f\(.).md"),status:"modified",patch:"@@ -1 +1 @@\n-a\n+b"}]')"
run "carry: a file list AT the 300-entry compare cap refuses (completeness unprovable)" awaiting

reset
carry_candidate
CFG_CARRY="docs"
compare_fix ahead "$(jq -n '[range(299) | {filename:("docs/f\(.).md"),status:"modified",patch:"@@ -1 +1 @@\n-a\n+b"}]')"
run "carry: 299 docs-only files (below the cap) still carries" approved

reset
CFG_CARRY="everything"
run "carry: an unknown carry class is a config error" "" 2

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

# The repo's thread-term posture: enforce keeps the fail-closed thread term;
# off must never emit threads-open (server-side ruleset is the enforcement
# point of record there).
reset
reviews_set "$(review "$(trusted_reviewer)" APPROVED)"
threads false >"$fixtures/graphql.json"
if [ "$ACTIVE_THREADS" = "off" ]; then
  run "configured: threads=off — unresolved thread does not close the gate" approved
else
  run "configured: unresolved thread fails closed (threads=enforce)" threads-open
fi

# The repo's carry-forward posture: with classes enabled, an identical tree
# must carry and a code delta must still refuse (the conservative floor no
# class configuration may widen).
if [ -n "$ACTIVE_CARRY" ]; then
  reset
  CFG_TRUSTED_LOGINS="$ACTIVE_TRUSTED_LOGINS"
  reviews_set "$(review "$(trusted_reviewer)" APPROVED "2026-01-01T00:00:00Z" "$OTHER")"
  compare_fix identical
  run "configured: carry-forward ($ACTIVE_CARRY) — identical tree carries" approved

  reset
  CFG_TRUSTED_LOGINS="$ACTIVE_TRUSTED_LOGINS"
  reviews_set "$(review "$(trusted_reviewer)" APPROVED "2026-01-01T00:00:00Z" "$OTHER")"
  compare_fix ahead "[$CODE_DELTA]"
  run "configured: carry-forward — a code delta still refuses" awaiting
fi

# The repo's retry budget: a read failing (attempts - 1) times must still
# reach a verdict. Delay is forced to 0 — the budget, not the pause, is the
# behavior under test.
if [ "$ACTIVE_API_ATTEMPTS" -gt 1 ] 2>/dev/null; then
  reset
  CFG_API_DELAY=0
  reviews_set "$(review "$(trusted_reviewer)" APPROVED)"
  export GH_SHIM_FAIL=reviews GH_SHIM_FAIL_TIMES=$((ACTIVE_API_ATTEMPTS - 1))
  run "configured: a transient read failure survives the repo's retry budget ($ACTIVE_API_ATTEMPTS attempts)" approved
  unset GH_SHIM_FAIL GH_SHIM_FAIL_TIMES
fi

if [ -n "$ACTIVE_OUTAGE" ]; then
  reset
  status_ctx "$ACTIVE_OUTAGE" success "reviewer outage attested"
  run "configured: outage attestation ($ACTIVE_OUTAGE)" approved

  # The REASON is enforced, not merely documented: an override with an empty
  # (or whitespace-only) description is an unexplained relaxation of the one
  # manual escape hatch the engine keeps.
  reset
  status_ctx "$ACTIVE_OUTAGE" success ""
  run "configured: override with an EMPTY reason is not evidence" awaiting

  reset
  status_ctx "$ACTIVE_OUTAGE" success "   "
  run "configured: override with a whitespace-only reason is not evidence" awaiting

  # And the attested reason rides out in the verdict detail, so the gate
  # status says why this PR merged without a review.
  reset
  status_ctx "$ACTIVE_OUTAGE" success "internal review loop clean (attested by the operator)"
  cases=$((cases + 1))
  detail_rc=0
  detail_line="$(PATH="$shim:$PATH" GH_SHIM_FIXTURES="$fixtures" \
    REVIEW_GATE_SETTINGS_FILE=/dev/null \
    REVIEW_GATE_TRUSTED_STATUS_CONTEXTS="$CFG_CONTEXTS" \
    REVIEW_GATE_COMMENT_REVIEWERS="$CFG_REVIEWERS" \
    REVIEW_GATE_OUTAGE_CONTEXT="$CFG_OUTAGE" \
    REVIEW_GATE_STATUS_PUBLISHER_REJECT="$CFG_PUBLISHER_REJECT" \
    REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS="$CFG_TRUSTED_LOGINS" \
    REVIEW_GATE_CONTEXT="$CFG_GATE_CONTEXT" REVIEW_GATE_THREADS="$CFG_THREADS" \
    REVIEW_GATE_CARRY_FORWARD="$CFG_CARRY" \
    GH_REPO="owner/repo" PR_NUMBER=1 HEAD_SHA="$HEAD" PR_AUTHOR="$CFG_PR_AUTHOR" \
    "$predicate" 2>/dev/null)" || detail_rc=$?
  detail_line="$(head -n 1 <<<"$detail_line")"
  case "$detail_line" in
    *"operator override"*"internal review loop clean"*)
      if [ "${detail_rc:-0}" -ne 0 ]; then
        echo "FAIL  configured: the override-detail case exited ${detail_rc} despite the expected line" >&2
        failures=$((failures + 1))
      else
        echo "ok    configured: the override reason rides out in the verdict detail (approved)"
      fi ;;
    *)
      echo "FAIL  configured: override reason missing from the detail: $detail_line" >&2
      failures=$((failures + 1)) ;;
  esac
  detail_rc=0

  # The v2 key name is resolved by the PREDICATE (every live gate read
  # honors it), not only by the writer — an adopter setting just the v2 key
  # must not silently lose their override.
  reset
  CFG_OUTAGE="legacy-name"
  status_ctx "v2-override-name" success "attested via the v2 key"
  cases=$((cases + 1))
  alias_rc=0
  alias_line="$(PATH="$shim:$PATH" GH_SHIM_FIXTURES="$fixtures" \
    REVIEW_GATE_SETTINGS_FILE=/dev/null \
    REVIEW_GATE_TRUSTED_STATUS_CONTEXTS="" REVIEW_GATE_COMMENT_REVIEWERS="" \
    REVIEW_GATE_OUTAGE_CONTEXT="legacy-name" \
    REVIEW_GATE_OVERRIDE_CONTEXT="v2-override-name" \
    REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS="" REVIEW_GATE_CONTEXT="$CFG_GATE_CONTEXT" \
    REVIEW_GATE_THREADS="$CFG_THREADS" REVIEW_GATE_CARRY_FORWARD="" \
    GH_REPO="owner/repo" PR_NUMBER=1 HEAD_SHA="$HEAD" PR_AUTHOR="$CFG_PR_AUTHOR" \
    "$predicate" 2>/dev/null)" || alias_rc=$?
  alias_line="$(head -n 1 <<<"$alias_line")"
  case "$alias_line" in
    verdict=approved*)
      if [ "${alias_rc:-0}" -ne 0 ]; then
        echo "FAIL  configured: the override-alias case exited ${alias_rc} despite the expected line" >&2
        failures=$((failures + 1))
      else
        echo "ok    configured: REVIEW_GATE_OVERRIDE_CONTEXT wins over the legacy key in the predicate itself (approved)"
      fi ;;
    *) echo "FAIL  configured: the v2 override key was not honored by the predicate: $alias_line" >&2
       failures=$((failures + 1)) ;;
  esac
  alias_rc=0
  CFG_OUTAGE="$ACTIVE_OUTAGE"

  if [ -n "$ACTIVE_PUBLISHER_REJECT" ]; then
    reset
    status_ctx "$ACTIVE_OUTAGE" success "reviewer outage attested" "$(first_item "$ACTIVE_PUBLISHER_REJECT")"
    run "configured: outage attestation from a rejected publisher is not evidence" awaiting
  fi
fi

if [ "$failures" -ne 0 ]; then
  echo "review-predicate selftest: $failures of $cases case(s) FAILED" >&2
  exit 1
fi
echo "review-predicate selftest: $cases case(s), all pass"
