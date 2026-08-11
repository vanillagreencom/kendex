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
ACTIVE_CARRY_EXCLUDE="$(rg_setting REVIEW_GATE_CARRY_FORWARD_EXCLUDE "")" || exit 1
ACTIVE_CARRY_EXCLUDE_PROPHYLACTIC="$(rg_setting REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC "")" || exit 1
# The repo's ACTIVE mode is validated here but NEVER copied into behavior
# cases (reset() pins enforce — under a committed "off" every awaiting/
# objection case would answer approved and red the required selftest job).
# This standalone check is what catches a committed typo pre-merge: the
# predicate would exit 2 on every live evaluation, but only at runtime.
ACTIVE_GATE_MODE_CHECK="$(rg_setting REVIEW_GATE_MODE "enforce")" || exit 1
case "$ACTIVE_GATE_MODE_CHECK" in
  enforce|off) ;;
  *)
    echo "review-predicate selftest: FAIL — committed REVIEW_GATE_MODE is '$ACTIVE_GATE_MODE_CHECK' (must be 'enforce' or 'off'); the live predicate will exit 2 on every evaluation" >&2
    exit 1
    ;;
esac

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
url=""; filter=""; paginate=0; graphql_page2=0; graphql_after=""
while [ $# -gt 0 ]; do
  case "$1" in
    api|--slurp) ;;
    --paginate) paginate=1 ;;
    -f|-F)
      shift
      # A cursor variable marks a follow-up thread page: serve the page-2
      # fixture (when present) so pagination is exercised for real. The
      # cursor VALUE is kept so cursor-keyed fixtures
      # (graphql.cursor-<value>.json) can drive an arbitrarily deep walk —
      # the page-budget bound cannot be proven with a single follow-up page.
      case "$1" in
        after=*)
          graphql_page2=1
          graphql_after="${1#after=}"
          # Cursor-keyed fixtures embed the cursor in a pathname, so the
          # namespace is enforced, not assumed: every cursor this suite
          # authors is [A-Za-z0-9_-]. Anything else would silently fall
          # back to the page-2/default fixture and a case could claim a
          # deep walk it never drove — refuse loudly instead.
          # Empty is refused with the same teeth: an empty after= cannot
          # select a cursor fixture and would silently fall through to the
          # page-2/default fixture — the false coverage this guard exists
          # to prevent.
          case "$graphql_after" in
            '' | *[!A-Za-z0-9_-]*)
              echo "shim: cursor value unusable as a fixture key (allowed: non-empty A-Za-z0-9_-): $graphql_after" >&2
              exit 92
              ;;
          esac
          ;;
      esac
      ;;
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
if [ "$name" = "graphql" ] && [ -n "$graphql_after" ] && [ -f "$GH_SHIM_FIXTURES/graphql.cursor-$graphql_after.json" ]; then
  # Cursor-keyed page: the fixture named by the requested cursor wins, so a
  # case can lay out a distinct advancing page per cursor and walk the full
  # page budget. Falls through to the single page-2 fixture when absent —
  # the two-page pattern's shape.
  file="$GH_SHIM_FIXTURES/graphql.cursor-$graphql_after.json"
elif [ "$name" = "graphql" ] && [ "$graphql_page2" = "1" ] && [ -f "$GH_SHIM_FIXTURES/graphql.page2.json" ]; then
  file="$GH_SHIM_FIXTURES/graphql.page2.json"
elif [ "$name" = "graphql" ] && [ -n "$graphql_after" ]; then
  # A follow-up request with NEITHER a cursor-keyed fixture NOR a page-2
  # fixture would silently re-serve page one — a deep-walk case missing one
  # of its files (a valid-looking cursor with a fixture gap) must refuse,
  # not fabricate coverage.
  echo "shim: follow-up page requested (after=$graphql_after) but no graphql.cursor-$graphql_after.json or graphql.page2.json fixture exists" >&2
  exit 93
fi
[ -f "$file" ] || { echo "shim: no fixture $file" >&2; exit 91; }
if [ -n "$filter" ]; then jq -r "$filter" <"$file"; else cat "$file"; fi
if [ "$paginate" = "1" ] && [ -f "$GH_SHIM_FIXTURES/$name.page2.json" ] && [ -z "$filter" ]; then
  cat "$GH_SHIM_FIXTURES/$name.page2.json"
fi
SHIM
chmod +x "$shim/gh"

# Shim refusal self-check, red-first: the three fixture-integrity refusals
# must fire before any case relies on them — deleting a refusal arm fails
# the whole run HERE, instead of leaving a case green against a fixture it
# never drove. Each exit code is pinned exactly.
# The scratch dir is removed BEFORE the assertions so a failed exit-code
# check cannot leak it — the recorded rcs carry the evidence. mktemp is
# checked: an empty dir var would aim GH_SHIM_FIXTURES at '/' and turn
# every probe into a misattributed failure.
_shimcheck_dir="$(mktemp -d)" || { echo "FATAL: cannot create shim self-check scratch dir (mktemp -d failed)" >&2; exit 1; }
[ -n "$_shimcheck_dir" ] || { echo "FATAL: mktemp -d returned an empty path for the shim self-check" >&2; exit 1; }
GH_SHIM_FIXTURES="$_shimcheck_dir" "$shim/gh" api graphql -f query=q -f after=bad/value >/dev/null 2>&1
_shimcheck_ns=$?
GH_SHIM_FIXTURES="$_shimcheck_dir" "$shim/gh" api graphql -f query=q -f after= >/dev/null 2>&1
_shimcheck_empty=$?
GH_SHIM_FIXTURES="$_shimcheck_dir" "$shim/gh" api graphql -f query=q -f after=C9 >/dev/null 2>&1
_shimcheck_gap=$?
rm -rf "$_shimcheck_dir"
[ "$_shimcheck_ns" -eq 92 ] || { echo "FATAL: shim did not refuse an out-of-namespace cursor (want exit 92, got $_shimcheck_ns)" >&2; exit 1; }
[ "$_shimcheck_empty" -eq 92 ] || { echo "FATAL: shim did not refuse an EMPTY cursor (want exit 92, got $_shimcheck_empty)" >&2; exit 1; }
[ "$_shimcheck_gap" -eq 93 ] || { echo "FATAL: shim did not refuse a fixture-less follow-up page (want exit 93, got $_shimcheck_gap)" >&2; exit 1; }

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
  # Every real row also carries a run id — the predicate validates it, so
  # the fixture models the real shape.
  jq -n --arg name "$1" --arg conclusion "$2" --arg summary "${3:-}" --arg app "${4:-trusted-reviewer-app}" \
    '{check_runs:[{id:1,name:$name,conclusion:$conclusion,app:{slug:$app},output:{title:null,summary:$summary}}]}' \
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
    REVIEW_GATE_CARRY_FORWARD_EXCLUDE="$CFG_CARRY_EXCLUDE" \
    REVIEW_GATE_MODE="$CFG_GATE_MODE" \
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
  rm -f "$fixtures"/*.page2.json "$fixtures"/graphql.cursor-*.json "$fixtures"/.failcount.* "$fixtures"/.urls.log
  unset GH_SHIM_FAIL GH_SHIM_FAIL_TIMES GH_SHIM_EMPTY || true
  CFG_THREADS="$ACTIVE_THREADS"
  CFG_API_ATTEMPTS="$ACTIVE_API_ATTEMPTS"
  CFG_API_DELAY="$ACTIVE_API_DELAY"
  CFG_CARRY="$ACTIVE_CARRY"
  CFG_CARRY_EXCLUDE="$ACTIVE_CARRY_EXCLUDE"
  # PINNED to enforce, never the repo's ACTIVE value: mode "off" is a bypass
  # switch, not a trust surface — under it every behavior case would answer
  # approved and the suite would fail, turning a deliberately disabled gate
  # into a red required CI job. The off/invalid arms are exercised by their
  # own explicit cases below.
  CFG_GATE_MODE="enforce"
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
jq -n '{check_runs:[{id:1,name:"mech-ctx",conclusion:"success",output:{title:null,summary:"analysis complete"}}]}' >"$fixtures/checkruns.json"
run "check-run with no app slug (unprovable provenance) is not evidence" awaiting

# NEWEST RUN DECIDES per name (vstack#1110), ordered by run id — the
# check-run mirror of the status surface's newest-row projection. A
# reviewer starting a fresh analysis round must withdraw its own older
# clean success on the same head; counting "any clean success" would open
# the gate on stale evidence. Every multi-row fixture lists the NEWER run
# (higher id) FIRST — the API's usual newest-first shape — so an
# implementation that skipped the id sort and took the last array row
# would fail these cases instead of passing by row order.
reset
CFG_CONTEXTS="mech-ctx"
jq -n '{check_runs:[
  {id:2,name:"mech-ctx",conclusion:null,status:"in_progress",app:{slug:"trusted-reviewer-app"},output:{title:null,summary:null}},
  {id:1,name:"mech-ctx",conclusion:"success",app:{slug:"trusted-reviewer-app"},output:{title:null,summary:"analysis complete"}}
]}' >"$fixtures/checkruns.json"
run "newer in-progress run masks its older clean success (newest run decides)" awaiting

# The skip marker comes from the ACTIVE pattern list, not a literal, so the
# configured layer (which replaces the default patterns) still exercises it.
# Guarded on a non-empty list: empty REVIEW_GATE_CHECKRUN_SKIP_PATTERNS
# legitimately disables the filter, and this case would then assert the
# wrong verdict — the masking property it proves is already covered for
# that shape by the in-progress case above.
first_skip="$(list_items "$ACTIVE_SKIPS" | head -1)"
if [ -n "$first_skip" ]; then
  reset
  CFG_CONTEXTS="mech-ctx"
  jq -n --arg skip "Review $first_skip. 0 files reviewed." '{check_runs:[
    {id:2,name:"mech-ctx",conclusion:"success",app:{slug:"trusted-reviewer-app"},output:{title:null,summary:$skip}},
    {id:1,name:"mech-ctx",conclusion:"success",app:{slug:"trusted-reviewer-app"},output:{title:null,summary:"analysis complete"}}
  ]}' >"$fixtures/checkruns.json"
  run "newer skip-marked 'pass' masks its older clean success" awaiting
fi

reset
CFG_CONTEXTS="mech-ctx"
jq -n '{check_runs:[
  {id:2,name:"mech-ctx",conclusion:"success",app:{slug:"trusted-reviewer-app"},output:{title:null,summary:"analysis complete"}},
  {id:1,name:"mech-ctx",conclusion:"failure",app:{slug:"trusted-reviewer-app"},output:{title:null,summary:"findings posted"}}
]}' >"$fixtures/checkruns.json"
run "newest clean success over an older failed run is evidence" approved

# The minting lever stays closed under the projection: a github-actions-
# published row is dropped BEFORE choosing the newest, so PR content cannot
# post a newer run under the trusted name to mask the reviewer's real
# success — closing the gate is not its call either (the status branch
# documents the same rule for its reject list).
reset
CFG_CONTEXTS="mech-ctx"
jq -n '{check_runs:[
  {id:2,name:"mech-ctx",conclusion:null,status:"queued",app:{slug:"github-actions"},output:{title:null,summary:null}},
  {id:1,name:"mech-ctx",conclusion:"success",app:{slug:"trusted-reviewer-app"},output:{title:null,summary:"analysis complete"}}
]}' >"$fixtures/checkruns.json"
run "github-actions-published newer run cannot mask the reviewer's clean success" approved

# The ordering key is validated, never defaulted: a retained row without a
# positive numeric id is a broken read (exit 2) — sorting it as 0 would let
# a malformed NEWEST row revive the older success it should mask. Rows
# dropped for the github-actions slug are excluded before validation.
reset
CFG_CONTEXTS="mech-ctx"
jq -n '{check_runs:[
  {name:"mech-ctx",conclusion:null,status:"in_progress",app:{slug:"trusted-reviewer-app"},output:{title:null,summary:null}},
  {id:1,name:"mech-ctx",conclusion:"success",app:{slug:"trusted-reviewer-app"},output:{title:null,summary:"analysis complete"}}
]}' >"$fixtures/checkruns.json"
run "a retained check-run row with NO id is exit 2, never sorted oldest" "" 2

reset
CFG_CONTEXTS="mech-ctx"
jq -n '{check_runs:[
  {id:"2",name:"mech-ctx",conclusion:null,status:"in_progress",app:{slug:"trusted-reviewer-app"},output:{title:null,summary:null}},
  {id:1,name:"mech-ctx",conclusion:"success",app:{slug:"trusted-reviewer-app"},output:{title:null,summary:"analysis complete"}}
]}' >"$fixtures/checkruns.json"
run "a string-typed run id is exit 2 (validated, not coerced)" "" 2

reset
CFG_CONTEXTS="mech-ctx"
jq -n '{check_runs:[
  {name:"mech-ctx",conclusion:null,status:"queued",app:{slug:"github-actions"},output:{title:null,summary:null}},
  {id:1,name:"mech-ctx",conclusion:"success",app:{slug:"trusted-reviewer-app"},output:{title:null,summary:"analysis complete"}}
]}' >"$fixtures/checkruns.json"
run "an id-less github-actions row is dropped before validation (cannot fail the read)" approved

# Slugless ANOMALY rows are the opposite of the minting lever: kept in the
# sequence, so an anomalous NEWEST row masks toward closed rather than
# reviving an older success from malformed current evidence.
reset
CFG_CONTEXTS="mech-ctx"
jq -n '{check_runs:[
  {id:2,name:"mech-ctx",conclusion:"success",output:{title:null,summary:"analysis complete"}},
  {id:1,name:"mech-ctx",conclusion:"success",app:{slug:"trusted-reviewer-app"},output:{title:null,summary:"analysis complete"}}
]}' >"$fixtures/checkruns.json"
run "slugless anomaly as the newest run masks toward closed (never revives the older success)" awaiting

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

# Anomaly rows MASK, they never REVIVE: a login-less row is not-evidence,
# but dropping it from the sequence before newest-row selection would let
# an OLDER success on the same context decide — stale approval built from
# malformed current evidence. The anomalous newest row must read as
# SILENCE. (Rejected-creator rows keep the opposite, deliberate semantics:
# they are dropped before selection so a minted row can never mask real
# rows — PR content cannot produce a login-less row, so no such lever
# exists here.)
reset
CFG_CONTEXTS="mech-ctx"; CFG_PUBLISHER_REJECT="github-actions[bot]"
jq -n '[{context:"mech-ctx",state:"success",description:"analysis complete",created_at:"2026-01-02T00:00:00Z",creator:null},
        {context:"mech-ctx",state:"success",description:"analysis complete",created_at:"2026-01-01T00:00:00Z",creator:{login:"trusted-publisher"}}]' >"$fixtures/statuses.json"
run "publisher filter set: a login-less NEWEST row is silence — the older success does not revive" awaiting

reset
CFG_CONTEXTS=""
CFG_OUTAGE="mech-outage"; CFG_PUBLISHER_REJECT="github-actions[bot]"
jq -n '[{context:"mech-outage",state:"success",description:"reviewer down",created_at:"2026-01-02T00:00:00Z",creator:null},
        {context:"mech-outage",state:"success",description:"reviewer down",created_at:"2026-01-01T00:00:00Z",creator:{login:"operator"}}]' >"$fixtures/statuses.json"
run "publisher filter set: a login-less newest OVERRIDE row is silence — the older attestation does not revive" awaiting

reset
CFG_CONTEXTS="mech-ctx"; CFG_PUBLISHER_REJECT=""
jq -n '[{context:"mech-ctx",state:"success",description:"analysis complete",created_at:"2026-01-02T00:00:00Z",creator:null},
        {context:"mech-ctx",state:"success",description:"analysis complete",created_at:"2026-01-01T00:00:00Z",creator:{login:"trusted-publisher"}}]' >"$fixtures/statuses.json"
run "publisher filter unset: the login-less newest row itself counts (filter off, default unchanged)" approved

reset
CFG_CONTEXTS="mech-ctx"; CFG_PUBLISHER_REJECT=""
status_ctx "mech-ctx" success "analysis complete" "github-actions[bot]"
run "publisher filter unset: github-actions-minted status counts (default unchanged)" approved

# A truthy hasNextPage whose cursor cannot advance is a read we cannot fully
# verify: fail closed to threads-open, never open the gate. (The old
# first-page ">100 threads" overflow is gone — pages are walked and summed
# up to a 20-page/2000-thread bound, where the same posture applies.)
reset
CFG_CONTEXTS="mech-ctx"; CFG_THREADS="enforce"
status_ctx "mech-ctx" success "analysis complete"
jq -n '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:true},nodes:[]}}}}}' \
  >"$fixtures/graphql.json"
run "thread pagination without an advancing cursor fails closed" threads-open

# Resolved history spanning pages must APPROVE: page one advances by cursor
# to page two, whose resolved remainder ends the walk — pagination sums,
# never truncates at the first page.
reset
CFG_CONTEXTS="mech-ctx"; CFG_THREADS="enforce"
status_ctx "mech-ctx" success "analysis complete"
jq -n '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:true,endCursor:"P2"},nodes:[{isResolved:true},{isResolved:true}]}}}}}' \
  >"$fixtures/graphql.json"
jq -n '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false},nodes:[{isResolved:true}]}}}}}' \
  >"$fixtures/graphql.page2.json"
run "resolved threads across pages approve" approved

# An unresolved thread on a LATER page must still fail closed — proves the
# walk actually counts follow-up pages instead of trusting page one.
reset
CFG_CONTEXTS="mech-ctx"; CFG_THREADS="enforce"
status_ctx "mech-ctx" success "analysis complete"
jq -n '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:true,endCursor:"P2"},nodes:[{isResolved:true},{isResolved:true}]}}}}}' \
  >"$fixtures/graphql.json"
jq -n '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false},nodes:[{isResolved:false}]}}}}}' \
  >"$fixtures/graphql.page2.json"
run "unresolved thread on a later page fails closed" threads-open

# The 20-page budget itself, red-first: 21 distinct ADVANCING pages (every
# node resolved) must fail closed as overflow — page 21 is never read. The
# terminal fixture past the budget is deliberately resolved+final: were the
# `t_pages > 20` guard removed or loosened, the walk would complete cleanly
# and answer approved, so this case can actually fail. Cursor-keyed fixtures
# (graphql.cursor-<value>.json) drive the walk; the single-page-2 shim shape
# cannot reach the bound (its second read never advances).
reset
CFG_CONTEXTS="mech-ctx"; CFG_THREADS="enforce"
status_ctx "mech-ctx" success "analysis complete"
jq -n '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:true,endCursor:"C2"},nodes:[{isResolved:true}]}}}}}' \
  >"$fixtures/graphql.json"
i=2
while [ "$i" -le 20 ]; do
  jq -n --arg c "C$((i + 1))" '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:true,endCursor:$c},nodes:[{isResolved:true}]}}}}}' \
    >"$fixtures/graphql.cursor-C$i.json"
  i=$((i + 1))
done
jq -n '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false},nodes:[{isResolved:true}]}}}}}' \
  >"$fixtures/graphql.cursor-C21.json"
run "advancing walk past the 20-page budget fails closed (overflow)" threads-open

# The budget's inclusive edge: EXACTLY 20 advancing pages, all resolved,
# terminal on page 20 — must approve. Pins the bound as >20, so an off-by-one
# tightening (rejecting a legal 20-page history) fails here while the case
# above catches the loosening direction.
reset
CFG_CONTEXTS="mech-ctx"; CFG_THREADS="enforce"
status_ctx "mech-ctx" success "analysis complete"
jq -n '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:true,endCursor:"C2"},nodes:[{isResolved:true}]}}}}}' \
  >"$fixtures/graphql.json"
i=2
while [ "$i" -le 19 ]; do
  jq -n --arg c "C$((i + 1))" '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:true,endCursor:$c},nodes:[{isResolved:true}]}}}}}' \
    >"$fixtures/graphql.cursor-C$i.json"
  i=$((i + 1))
done
jq -n '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false},nodes:[{isResolved:true}]}}}}}' \
  >"$fixtures/graphql.cursor-C20.json"
run "exactly 20 advancing resolved pages approve (bound is >20)" approved

# The shim's cursor-namespace refusal, red-first: a page-1 endCursor outside
# [A-Za-z0-9_-] must abort the walk as a loud read failure (the shim exits
# 92, the gh read fails, the predicate exits 2). With the refusal deleted,
# the slash cursor keys no fixture, the shim silently falls back to page 1,
# and the non-advancing guard answers threads-open instead — so this case
# distinguishes the guard's presence, not just "something failed".
reset
CFG_CONTEXTS="mech-ctx"; CFG_THREADS="enforce"
# Single attempt, no delay: the refusal is deterministic, and under a
# configured retry budget every re-attempt would just re-refuse after a
# sleep — pure suite-runtime inflation.
CFG_API_ATTEMPTS="1"; CFG_API_DELAY="0"
status_ctx "mech-ctx" success "analysis complete"
jq -n '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:true,endCursor:"bad/value"},nodes:[{isResolved:true}]}}}}}' \
  >"$fixtures/graphql.json"
run "cursor outside the fixture-key namespace is a loud read failure" "" 2

# Zero bytes from the thread read is a BROKEN READ (VST-46 family), never an
# authoritative verdict in either direction — pr-watch parity.
reset
CFG_CONTEXTS="mech-ctx"; CFG_THREADS="enforce"
status_ctx "mech-ctx" success "analysis complete"
export GH_SHIM_EMPTY=graphql
run "zero-byte thread-page producer is a failed read (exit 2)" "" 2
unset GH_SHIM_EMPTY

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
printf '{"check_runs":[{"id":1,"name":"mech-ctx","conclusion":"success","app":{"slug":"trusted-reviewer-app"},"output":{"title":"mech-ctx","summary":"Review rate limited. 0 files reviewed."}}]}\n' \
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
jq -n '{check_runs:[{id:1,name:"mech-ctx",conclusion:"success",app:{slug:"trusted-reviewer-app"},output:{title:null,summary:"analysis complete"}}]}' >"$fixtures/checkruns.page2.json"
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

# Vacuous and non-array pages (the whitespace shape passes the zero-byte
# guard yet slurps to nothing): the reviews case is the dangerous one — []
# built from a broken read erases a standing CHANGES_REQUESTED while other
# evidence satisfies the positive side. Check-run and comment pages get the
# same contract; wrong-shaped pages are exit 2, never empty evidence.
reset
printf '\n   \n' >"$fixtures/reviews.json"
run "whitespace-only reviews response is exit 2, not an empty review set" "" 2

reset
printf '{"message":"Server Error"}\n' >"$fixtures/reviews.json"
run "error-object reviews page is exit 2, not an empty review set" "" 2

reset
CFG_CONTEXTS="mech-ctx"
printf '\n   \n' >"$fixtures/checkruns.json"
run "whitespace-only check-runs response is exit 2, not silence" "" 2

# OBJECT without check_runs, deliberately: an array fixture failed under
# the OLD merger too (`.check_runs` on an array is a jq error), proving
# nothing. `{}` collapsed through the old `map(.check_runs) | add // []`
# to an EMPTY run set — silence built from a broken read; only the new
# shape guard turns it into exit 2.
reset
CFG_CONTEXTS="mech-ctx"
printf '{}\n' >"$fixtures/checkruns.json"
run "check-runs page without a check_runs array is exit 2 (the old merger read it as silence)" "" 2

reset
CFG_REVIEWERS="mech-bot[bot]:Reviewed commit:"
printf '\n   \n' >"$fixtures/comments.json"
run "whitespace-only comments response is exit 2, not absent evidence" "" 2

# Status-snapshot seam (VST-35): a caller that already holds the head's
# LIST-endpoint status rows hands them in (wrapped {sha, statuses}); the
# predicate must evaluate against them WITHOUT its own statuses read
# (proven by failing that endpoint), and an unreadable or malformed
# snapshot gets the read contract: exit 2. The snapshot must be BOUND to
# this head (top-level sha == HEAD_SHA, VST-71): a snapshot for another
# head passing shape validation would evaluate stale evidence.
reset
CFG_CONTEXTS="mech-ctx"
jq -n --arg sha "$HEAD" '{sha:$sha,statuses:[{context:"mech-ctx",state:"success",description:"analysis complete",created_at:"2026-01-01T00:00:00Z",creator:{login:"trusted-publisher"}}]}' >"$fixtures/snapshot.json"
CFG_SNAPSHOT="$fixtures/snapshot.json"
export GH_SHIM_FAIL=statuses
run "snapshot seam: caller-supplied list-endpoint snapshot (sha-bound) is evaluated, duplicate read skipped" approved
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

# LIST-shape at the seam: while the publisher reject list is configured, the
# downstream anomaly rule drops login-less rows as not-evidence — so a
# combined-endpoint snapshot (null creators on App rows) would silently
# erase real evidence. The seam refuses it loudly instead. With the list
# empty (shipped default) the filter is off and null creators still pass.
reset
CFG_CONTEXTS="mech-ctx"; CFG_PUBLISHER_REJECT="github-actions[bot]"
jq -n --arg sha "$HEAD" '{sha:$sha,statuses:[{context:"mech-ctx",state:"success",description:"analysis complete",created_at:"2026-01-01T00:00:00Z",creator:null}]}' >"$fixtures/nullcreator-snapshot.json"
CFG_SNAPSHOT="$fixtures/nullcreator-snapshot.json"
run "snapshot seam: null-creator row under a configured reject list is exit 2, not silent erasure" "" 2

reset
CFG_CONTEXTS="mech-ctx"; CFG_PUBLISHER_REJECT=""
CFG_SNAPSHOT="$fixtures/nullcreator-snapshot.json"
export GH_SHIM_FAIL=statuses
run "snapshot seam: null-creator row with the reject list EMPTY still evaluates (filter off)" approved
unset GH_SHIM_FAIL

reset
CFG_CONTEXTS="mech-ctx"; CFG_PUBLISHER_REJECT="github-actions[bot]"
jq -n --arg sha "$HEAD" '{sha:$sha,statuses:[{context:"mech-ctx",state:"success",description:"analysis complete",created_at:"2026-01-01T00:00:00Z",creator:{login:{}}}]}' >"$fixtures/objlogin-snapshot.json"
CFG_SNAPSHOT="$fixtures/objlogin-snapshot.json"
run "snapshot seam: NON-STRING creator login under a configured reject list is exit 2 (// \"\" would let an object through)" "" 2

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

# REVIEW_GATE_MODE (the one-switch gate disable, owner decision 2026-08-08):
# "off" answers approved before ANY evidence read — the urls.log pin proves
# zero API traffic, so a disabled gate can never leak reads or block on a
# broken API. The detail is an attestation ("disabled by settings"), never
# a review claim. An unknown value is exit 2: a typo cannot disable a gate.
reset
CFG_GATE_MODE="off"
run "mode off: approved without evaluating anything" approved
# The detail is the attestation CONTRACT, not decoration: statuses converged
# from this verdict must say the gate is disabled, never imply a review
# happened — pin the exact line.
off_line="$(PATH="$shim:$PATH" GH_SHIM_FIXTURES="$fixtures" \
  REVIEW_GATE_SETTINGS_FILE=/dev/null REVIEW_GATE_MODE=off \
  GH_REPO="owner/repo" PR_NUMBER=1 HEAD_SHA="$HEAD" PR_AUTHOR="$AUTHOR" \
  "$predicate" 2>/dev/null)"
cases=$((cases + 1))
if [ "$off_line" = "verdict=approved detail=review gate disabled by settings (REVIEW_GATE_MODE=off)" ]; then
  echo "ok    mode off: the attestation detail is exact (statuses never imply a review)"
else
  echo "FAIL  mode off attestation detail drifted: '$off_line'" >&2
  failures=$((failures + 1))
fi
if [ -f "$fixtures/.urls.log" ] && [ -s "$fixtures/.urls.log" ]; then
  echo "FAIL  mode off must make ZERO API reads (urls.log: $(tr '\n' ' ' <"$fixtures/.urls.log"))" >&2
  failures=$((failures + 1))
else
  echo "ok    mode off makes zero API reads (urls.log empty)"
fi
cases=$((cases + 1))

reset
CFG_GATE_MODE="off"
reviews_set "$(review "objector" CHANGES_REQUESTED "2026-01-02T00:00:00Z")"
threads false >"$fixtures/graphql.json"
run "mode off: even standing objections and open threads are not read" approved

reset
CFG_GATE_MODE="offf"
run "mode: an unknown value is a loud config error, never a disabled gate" "" 2

# The newest-run projection must actually SORT: every other multi-run
# fixture lists the newer run first (the API's usual shape), so an
# implementation that dropped the id sort and took the FIRST row would
# still pass them. This fixture lists the OLDER run first.
reset
CFG_CONTEXTS="mech-ctx"
jq -n '{check_runs:[
  {id:1,name:"mech-ctx",conclusion:"failure",app:{slug:"trusted-reviewer-app"},output:{title:null,summary:"findings posted"}},
  {id:2,name:"mech-ctx",conclusion:"success",app:{slug:"trusted-reviewer-app"},output:{title:null,summary:"analysis complete"}}
]}' >"$fixtures/checkruns.json"
run "newest run decides with the OLDER row listed first (the sort is real)" approved

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

# Files ride page one ONLY (the real API shape — compare pagination
# paginates commits, never files), so a files array on a later page is
# deliberately ignored, not merged: this pins that a later-page "files"
# entry cannot smuggle rows into the classification. The fixture plants a
# CODE file there — if a regression ever merged later pages, the docs-only
# carry below would flip to awaiting and this case would catch it.
reset
carry_candidate
CFG_CARRY="docs"
compare_fix ahead "[$DOCS_DELTA]"
jq -n '{status:"ahead",files:[{filename:"src/smuggled.sh",status:"modified",patch:"@@ -1 +1 @@\n-a\n+b"}]}' >"$fixtures/compare.page2.json"
run "carry: a later-page files array is ignored, never merged (files ride page one only)" approved

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

# Path exclusions (vstack#1115): policy-bearing markdown classifies "docs"
# by extension, so REVIEW_GATE_CARRY_FORWARD_EXCLUDE globs disqualify any
# carry whose delta touches an excluded path — surgical (non-matching deltas
# still carry), '*' crosses '/', and inert for identical trees (no delta).
AGENTS_DELTA="$(delta_file "AGENTS.md" modified '@@ -1 +1 @@
-old instruction
+new instruction')"
NESTED_AGENTS_DELTA="$(delta_file "skills/foo/AGENTS.md" modified '@@ -1 +1 @@
-old instruction
+new instruction')"

reset
carry_candidate
CFG_CARRY="docs"; CFG_CARRY_EXCLUDE=""
compare_fix ahead "[$AGENTS_DELTA]"
run "carry-exclude unset (default): policy markdown still carries as docs" approved

reset
carry_candidate
CFG_CARRY="docs"; CFG_CARRY_EXCLUDE="*AGENTS.md"
compare_fix ahead "[$AGENTS_DELTA]"
run "carry-exclude: an excluded path in the delta refuses the carry" awaiting

reset
carry_candidate
CFG_CARRY="docs"; CFG_CARRY_EXCLUDE="*AGENTS.md"
compare_fix ahead "[$NESTED_AGENTS_DELTA]"
run "carry-exclude: '*' crosses '/' — a nested AGENTS.md is excluded too" awaiting

reset
carry_candidate
CFG_CARRY="docs"; CFG_CARRY_EXCLUDE="*AGENTS.md"
compare_fix ahead "[$DOCS_DELTA]"
run "carry-exclude: a non-matching docs delta still carries (surgical)" approved

reset
carry_candidate
CFG_CARRY="docs"; CFG_CARRY_EXCLUDE=".github/*; *AGENTS.md"
compare_fix ahead "[$DOCS_DELTA,$AGENTS_DELTA]"
run "carry-exclude: one excluded file refuses the WHOLE delta (2nd glob, spaces trimmed)" awaiting

reset
carry_candidate
CFG_CARRY="docs"; CFG_CARRY_EXCLUDE=".github/*"
compare_fix ahead "[$(delta_file ".github/copilot-instructions.md" modified '@@ -1 +1 @@
-a
+b')]"
run "carry-exclude: a directory glob catches instruction files under .github/" awaiting

reset
carry_candidate
CFG_CARRY="docs"; CFG_CARRY_EXCLUDE="*AGENTS.md"
compare_fix identical
run "carry-exclude: identical tree still carries (no delta to exclude)" approved

reset
carry_candidate
CFG_CARRY="comments"; CFG_CARRY_EXCLUDE="src/thing.sh"
compare_fix ahead "[$COMMENT_DELTA]"
run "carry-exclude: applies to the comments class too (literal path)" awaiting

# A git filename may embed a newline; split across lines it could dodge a
# compound glob (skills/*.md misses 'skills/foo\nbar.md' tested as two
# records) while the intact name still classifies docs. Exclusion matching
# demands provable record boundaries: control characters refuse the carry.
NEWLINE_NAME_DELTA="$(delta_file "$(printf 'skills/foo\nbar.md')" modified '@@ -1 +1 @@
-a
+b')"
reset
carry_candidate
CFG_CARRY="docs"; CFG_CARRY_EXCLUDE="skills/*.md"
compare_fix ahead "[$NEWLINE_NAME_DELTA]"
run "carry-exclude: a newline-embedding filename refuses (record boundaries unprovable)" awaiting

reset
carry_candidate
CFG_CARRY="docs"; CFG_CARRY_EXCLUDE=""
compare_fix ahead "[$NEWLINE_NAME_DELTA]"
run "carry-exclude: the control-character refusal is scoped to configured exclusions" approved

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

# Carry-exclude probes (vstack#1174). Both use the predicate's matcher shape
# — an unquoted pattern in a bash `case` — so the probes pin the real glob
# semantics ('*' crosses '/', whole-path anchoring, ';' separators) against
# the repo's COMMITTED exclude list, not a hardcoded example.
carry_class_has() { # is this class among the repo's enabled carry classes?
  printf '%s' "$ACTIVE_CARRY" | tr ';|' '\n\n' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -qx "$1"
}
glob_matches() { # path, glob — the predicate's exact `case` matcher
  case "$1" in $2) return 0 ;; esac
  return 1
}
# The invoking repo's tracked tree, when this script lives inside one:
# probes derived from REAL tracked paths prove a committed glob matches the
# repository, not merely the string the probe itself manufactured from that
# same glob (a typo'd `skils/*` matches `skils/probe.md` forever). Empty in
# hermetic harnesses — the manufactured fallback keeps those deterministic.
# Resolved from the INVOKING directory's repository — the settings under
# test belong to that repo, so its tracked tree is the evidence base. Empty
# when the selftest runs outside a repository (hermetic harnesses): only
# there do manufactured probe paths apply. Loaded LAZILY at the exclude
# battery (the only consumer), not at script start, and via -z so quoted
# unusual pathnames round-trip instead of mis-probing globs.
EXCLUDE_TRACKED=""
EXCLUDE_TRACKED_ERROR=""
EXCLUDE_TRACKED_ROOT=""
EXCLUDE_TRACKED_MODE=""
exclude_tracked_loaded=""
load_exclude_tracked() {
  [ -n "$exclude_tracked_loaded" ] && return 0
  exclude_tracked_loaded=1
  # A real repository whose ls-files FAILS must not silently degrade into
  # hermetic synthetic probing — that would shrink coverage exactly when
  # git is broken. Only a genuinely-not-a-repo cwd is hermetic.
  # The evidence ANCHOR is the repository containing the RESOLVED settings
  # file: the committed exclude list under test belongs to that repo, and
  # REVIEW_GATE_SETTINGS_FILE legitimately points a run at another
  # checkout — deriving the root from the invoking cwd would judge B's
  # globs against A's tree. /dev/null (force-defaults) and the plain
  # relative default both anchor at the invoking directory.
  _elt_anchor="."
  case "${REVIEW_GATE_SETTINGS_FILE:-}" in
    '' | /dev/null) : ;;
    *)
      # Only an EXISTING override moves the anchor: when the named file is
      # absent, rg_setting falls back to built-in defaults, and anchoring
      # evidence at a nonexistent path's directory would judge defaults
      # against the wrong tree (or silently force hermetic mode).
      if [ -f "$REVIEW_GATE_SETTINGS_FILE" ]; then
        # Resolve a SYMLINK override to its target first: installs routinely
        # symlink settings files, and the evidence repository is the one
        # CONTAINING the real file — anchoring at the symlink's directory
        # judges the wrong tree, or (outside any repo) silently demotes a
        # tracked run to hermetic probing where a dead glob can manufacture
        # its own match. Bounded walk; a walk that CANNOT finish (readlink
        # failure, hop budget exhausted) is an unusable anchor and carries a
        # resolution error — continuing from the unresolved link's directory
        # would be exactly the silent demotion above.
        _elt_settings="$REVIEW_GATE_SETTINGS_FILE"
        _elt_hops=0
        while [ -L "$_elt_settings" ] && [ "$_elt_hops" -lt 40 ]; do
          # An option-looking path (dash-leading, no slash — a cwd-relative
          # `-settings`, or a bare dash-leading link target) would parse as
          # a readlink OPTION and fail the walk, stranding the anchor at
          # the wrong checkout: normalize with ./ first.
          case "$_elt_settings" in -*) _elt_settings="./$_elt_settings" ;; esac
          if ! _elt_link="$(readlink "$_elt_settings")"; then
            EXCLUDE_TRACKED_ERROR="could not resolve the symlinked settings override (readlink failed at '$_elt_settings') — the evidence anchor is unusable"
            break
          fi
          case "$_elt_link" in
            /*) _elt_settings="$_elt_link" ;;
            *)
              case "$_elt_settings" in
                */*) _elt_settings="${_elt_settings%/*}/$_elt_link" ;;
                *) _elt_settings="$_elt_link" ;;
              esac
              ;;
          esac
          _elt_hops=$((_elt_hops + 1))
        done
        if [ -z "$EXCLUDE_TRACKED_ERROR" ] && [ -L "$_elt_settings" ]; then
          EXCLUDE_TRACKED_ERROR="could not resolve the symlinked settings override (chain longer than 40 hops or cyclic) — the evidence anchor is unusable"
        fi
        [ -n "$EXCLUDE_TRACKED_ERROR" ] && return 0
        # Containing directory via parameter expansion, not dirname: BSD
        # dirname can reject `--`, and without `--` an option-looking path
        # would be misparsed — the expansion has no dialect to disagree with.
        case "$_elt_settings" in
          */*) _elt_anchor="${_elt_settings%/*}" ;;
          *) _elt_anchor="." ;;
        esac
        [ -n "$_elt_anchor" ] || _elt_anchor="/"
      fi
      ;;
  esac
  # A genuine NON-REPOSITORY is the only hermetic ticket. The probe's
  # verdict is read from its output, not its bare exit status: a broken
  # git failing this probe inside a real checkout used to read as "not a
  # repository" and silently demoted the run to hermetic synthetic
  # probing — the same fail-open every other branch here refuses. Only
  # git's own "not a git repository" diagnosis selects hermetic mode;
  # every other failure (or a "false" verdict — a git dir with no work
  # tree) leaves the evidence base unusable.
  _elt_probe_out="$(git -C "$_elt_anchor" rev-parse --is-inside-work-tree 2>&1)"
  _elt_probe_rc=$?
  if [ "$_elt_probe_rc" -ne 0 ] || [ "$_elt_probe_out" != "true" ]; then
    case "$_elt_probe_out" in
      *"not a git repository"*) : ;;
      *) EXCLUDE_TRACKED_ERROR="repository probe failed (git rev-parse --is-inside-work-tree exit $_elt_probe_rc: ${_elt_probe_out:-no output}) — cannot tell a non-repository from a broken git" ;;
    esac
    return 0
  fi
  # Anchor verified: a real work tree. Resolve its root, read the list.
    # ROOT-relative, never cwd-relative: `git ls-files` is subtree-scoped,
    # so a run from a subdirectory compared every committed glob against a
    # partial file list — each glob quietly downgraded to its no-match
    # note while the run stayed green. The evidence base is the repository
    # root, resolved explicitly; failing to resolve it is as unusable as a
    # failed read.
    # git's OWN status must decide the error, not the pipeline tail's: a
    # `git | tr` assignment reports tr's status, so a failed ls-files with
    # a happy tr would silently degrade into hermetic synthetic probing —
    # the exact fail-open this error flag exists to prevent. Stage the -z
    # output in a file (NUL bytes cannot ride a shell variable) and check
    # the producer's exit alone.
    # mktemp checked too: with no staging file the tracked read cannot be
    # VERIFIED, and unverifiable takes the same refuse-to-degrade branch as
    # failed — never a silent slide into hermetic probing.
    # The flag carries the CAUSE: its one consumer prints it, and telling
    # an operator to fix git when mktemp failed sends them at the wrong
    # subsystem.
    # Both checks are load-bearing: the exit status is git's own verdict
    # (a failing rev-parse that still printed something must not smuggle a
    # root past the guard), and the empty-output guard catches a success
    # that produced nothing usable.
    if ! EXCLUDE_TRACKED_ROOT="$(git -C "$_elt_anchor" rev-parse --show-toplevel 2>/dev/null)" \
      || [ -z "$EXCLUDE_TRACKED_ROOT" ]; then
      EXCLUDE_TRACKED_ERROR="could not resolve the repository root (git rev-parse --show-toplevel failed inside a work tree)"
    elif _elt_tmp="$(mktemp)"; then
      if git -C "$EXCLUDE_TRACKED_ROOT" ls-files -z >"$_elt_tmp" 2>/dev/null; then
        # STATED LIMITATION: the NUL-delimited read is converted to a
        # newline-delimited list for the probe loops, so a tracked
        # filename CONTAINING a newline splits into fragments — a glob
        # matching such a file can false-FAIL as no-match. The failure
        # direction is loud (never a silent pass), and newline filenames
        # in a reviewed repository are their own defect.
        EXCLUDE_TRACKED="$(tr '\0' '\n' <"$_elt_tmp")"
        # Mode is a SEPARATE flag: a successful read in a zero-tracked-file
        # repository leaves the payload empty, and payload-emptiness must
        # not demote a tracked run to hermetic synthetic probing.
        EXCLUDE_TRACKED_MODE="tracked"
      else
        EXCLUDE_TRACKED_ERROR="'git ls-files' failed (fix git, or run the harness outside a repository)"
      fi
      rm -f "$_elt_tmp"
    else
      EXCLUDE_TRACKED_ERROR="staging file creation failed (mktemp) — the tracked read cannot be verified"
    fi
}
exclude_glob_probe() { # glob, ext... -> a carry-class path this glob matches
  # Tracked mode (a real repository): ONLY real tracked matches count — a
  # synthetic filler manufactured from the glob under test would let a
  # typo'd `skils/*` verify itself against its own fabrication. No tracked
  # match returns 2 so the caller can say so out loud. Hermetic mode (no
  # repository): the '*'-filler fallback keeps harness runs deterministic,
  # and the concrete path is still re-proven against its source glob.
  local pat="$1" ext candidate any_tracked_match=""
  shift
  if [ "$EXCLUDE_TRACKED_MODE" = "tracked" ]; then
    while IFS= read -r candidate; do
      [ -z "$candidate" ] && continue
      glob_matches "$candidate" "$pat" || continue
      any_tracked_match=1
      for ext in "$@"; do
        case "$candidate" in *"$ext")
          printf '%s\n' "$candidate"
          return 0 ;;
        esac
      done
    done <<EOF_TRACKED_PROBE
$EXCLUDE_TRACKED
EOF_TRACKED_PROBE
    # 2 and 3 are DIFFERENT verdicts: matching nothing tracked at all is
    # the typo/dead-config shape, while matching tracked paths that just
    # sit outside the enabled carry classes proves the glob names real
    # paths — inert today, not dead, and never a candidate for the
    # prophylactic declaration (whose contract is "no tracked match").
    [ -n "$any_tracked_match" ] && return 3
    return 2
  fi
  case "$pat" in *'?'*|*'['*|*'\'*) return 1 ;; esac
  for ext in "$@"; do
    case "$pat" in
      *"$ext") candidate="${pat//\*/probe}" ;;
      *'*')    candidate="${pat//\*/probe}$ext" ;;
      *)       continue ;;
    esac
    glob_matches "$candidate" "$pat" || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}
exclude_free_path() { # ext... -> a path NO committed glob matches
  # Tracked mode: a REAL tracked carry-class file outside every glob is the
  # positive proof (a committed `carry-probe*` exclusion must not read as
  # "nothing can carry" while README.md still carries). Hermetic mode:
  # synthetic candidates per extension.
  local ext candidate pat hit
  if [ "$EXCLUDE_TRACKED_MODE" = "tracked" ]; then
    while IFS= read -r candidate; do
      [ -z "$candidate" ] && continue
      hit=""
      for ext in "$@"; do
        case "$candidate" in *"$ext") hit=ext-ok ;; esac
      done
      [ "$hit" = "ext-ok" ] || continue
      hit=""
      while IFS= read -r pat; do
        [ -z "$pat" ] && continue
        if glob_matches "$candidate" "$pat"; then hit=1; break; fi
      done <<EOF_FREE_TRACKED
$(list_items "$ACTIVE_CARRY_EXCLUDE")
EOF_FREE_TRACKED
      if [ -z "$hit" ]; then printf '%s\n' "$candidate"; return 0; fi
    done <<EOF_TRACKED_FREE
$EXCLUDE_TRACKED
EOF_TRACKED_FREE
    return 1
  fi
  # The two synthetic candidates deliberately share NO filename prefix: when
  # both lived under `carry-probe*`, a committed glob matching that harness
  # namespace (non-universal in any real tree — README.md still carries)
  # matched every candidate and false-FAILed the over-broad guard. Distinct
  # shapes mean only a genuinely class-universal exclusion set can exhaust
  # them; finite probes still cannot PROVE universality — stated limitation.
  for ext in "$@"; do
    for candidate in "carry-probe/unrelated$ext" "unexcluded-sample$ext"; do
      hit=""
      while IFS= read -r pat; do
        [ -z "$pat" ] && continue
        if glob_matches "$candidate" "$pat"; then hit=1; break; fi
      done <<EOF_FREE_PROBE
$(list_items "$ACTIVE_CARRY_EXCLUDE")
EOF_FREE_PROBE
      if [ -z "$hit" ]; then printf '%s\n' "$candidate"; return 0; fi
    done
  done
  return 1
}

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

  # The repo's exclude list must be shown to MATCH (vstack#1174): a typo'd
  # or wrongly-anchored committed glob leaves the exclusion dead while every
  # case above stays green in both directions. So: a carry-class path a
  # committed glob matches must refuse the carry, and a sibling path outside
  # every committed glob must still carry (the exclusion neither dead nor
  # over-broad).
  if [ -n "$ACTIVE_CARRY_EXCLUDE" ]; then
    load_exclude_tracked
    if [ -n "$EXCLUDE_TRACKED_ERROR" ]; then
      cases=$((cases + 1))
      echo "FAIL  configured: carry-exclude — the tracked-evidence base is unusable: $EXCLUDE_TRACKED_ERROR; refusing to degrade to synthetic probes" >&2
      failures=$((failures + 1))
    fi
    # The evidence MODE is printed, not inferred: a degraded run and a full
    # one used to be distinguishable only by the case total, which moves on
    # every re-vendor for unrelated reasons. One line makes it readable.
    if [ "$EXCLUDE_TRACKED_MODE" = "tracked" ]; then
      echo "info  carry-exclude evidence mode: tracked (root: $EXCLUDE_TRACKED_ROOT, $(printf '%s\n' "$EXCLUDE_TRACKED" | grep -c .) tracked paths)"
    elif [ -z "$EXCLUDE_TRACKED_ERROR" ]; then
      echo "info  carry-exclude evidence mode: hermetic-synthetic (not inside a repository)"
    fi
    # Probe extensions span EVERY enabled class — docs alone must not leave
    # a comments-class exclusion (`src/*.sh`) untested, and an exclusion set
    # covering all Markdown is not "carry disabled" while comment-only
    # changes still carry.
    probe_exts=""
    carry_class_has docs && probe_exts=".md .markdown"
    # Every extension the predicate's comment-token table classifies —
    # both the '#' and the '//' families — so an exclusion like
    # cli/src/*.rs is exercised, not skipped as "no probe".
    carry_class_has comments && probe_exts="${probe_exts:+$probe_exts }.sh .bash .py .rb .toml .yml .yaml .js .mjs .cjs .ts .tsx .jsx .rs .go .c .h .cc .cpp .hpp .java .kt .swift"
    [ -n "$probe_exts" ] || probe_exts=".md .markdown"
    # Per-extension patches: a docs probe changes prose, a comments probe
    # changes a comment line, so the delta classifies into its class and the
    # refusal below is attributable to the exclusion alone.
    probe_patch_for() {
      case "$1" in
      *.js | *.mjs | *.cjs | *.ts | *.tsx | *.jsx | *.rs | *.go | *.c | *.h | *.cc | *.cpp | *.hpp | *.java | *.kt | *.swift)
        printf '%s' '@@ -1 +1 @@
-// old comment
+// new comment' ;;
      *.sh | *.bash | *.py | *.rb | *.toml | *.yml | *.yaml)
        printf '%s' '@@ -1 +1 @@
-# old comment
+# new comment' ;;
      *) printf '%s' '@@ -1 +1 @@
-old prose
+new prose' ;;
      esac
    }
    # shellcheck disable=SC2086 # probe_exts is a controlled word list
    probe_free="$(exclude_free_path $probe_exts)" || probe_free=""

    # NEGATIVE CONTROL (tracked mode): the no-match verdict the dead-glob
    # FAIL below rides on must be demonstrably reachable in THIS run — a
    # probe that lost the ability to say "no match" would silently green
    # every dead glob. A planted glob that cannot correspond to a tracked
    # path must probe as rc=2.
    if [ "$EXCLUDE_TRACKED_MODE" = "tracked" ]; then
      # shellcheck disable=SC2086 # probe_exts is a controlled word list
      negctl_out="$(exclude_glob_probe 'zz-selftest-planted-negative-control/*' $probe_exts)"
      negctl_rc=$?
      if [ "$negctl_rc" -ne 2 ] || [ -n "$negctl_out" ]; then
        cases=$((cases + 1))
        echo "FAIL  configured: carry-exclude — the planted no-match control probed rc=$negctl_rc ('$negctl_out'): the dead-glob verdict is unreachable and every dead glob below would silently pass" >&2
        failures=$((failures + 1))
      fi
    fi

    # EVERY committed glob is exercised, not just the first usable one: a
    # later typo'd or wrongly-anchored addition must not hide behind an
    # earlier glob's green. Compare filenames are repository-relative, so a
    # leading-'/' glob can never match any real delta — structurally dead,
    # and a FAIL rather than a skip.
    while IFS= read -r probe_pat; do
      [ -z "$probe_pat" ] && continue
      case "$probe_pat" in
      /*)
        cases=$((cases + 1))
        echo "FAIL  configured: carry-exclude glob '$probe_pat' is anchored with a leading '/' — compare filenames are repository-relative, so this exclusion can never match and is dead" >&2
        failures=$((failures + 1))
        continue
        ;;
      esac
      # shellcheck disable=SC2086 # probe_exts is a controlled word list
      probe_match="$(exclude_glob_probe "$probe_pat" $probe_exts)"
      probe_rc=$?
      if [ "$probe_rc" -eq 0 ] && [ -n "$probe_match" ]; then
        reset
        CFG_TRUSTED_LOGINS="$ACTIVE_TRUSTED_LOGINS"
        reviews_set "$(review "$(trusted_reviewer)" APPROVED "2026-01-01T00:00:00Z" "$OTHER")"
        compare_fix ahead "[$(delta_file "$probe_match" modified "$(probe_patch_for "$probe_match")")]"
        run "configured: carry-exclude — '$probe_pat' matches '$probe_match', refusing the carry" awaiting
      elif [ "$probe_rc" -eq 2 ]; then
        # A no-match glob is dead in the same way a leading-'/' anchor is —
        # and used to exit 0 with a note textually identical to a
        # deliberate prophylactic entry's, training operators to scroll
        # past real typos. Posture symmetry: an UNDECLARED no-match glob
        # FAILs; a glob listed in
        # REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC notes as declared.
        probe_declared=""
        while IFS= read -r probe_proph; do
          [ -z "$probe_proph" ] && continue
          [ "$probe_proph" = "$probe_pat" ] && probe_declared=1
        done <<EOF_PROPHYLACTIC
$(list_items "$ACTIVE_CARRY_EXCLUDE_PROPHYLACTIC")
EOF_PROPHYLACTIC
        if [ -n "$probe_declared" ]; then
          echo "note  configured: carry-exclude — '$probe_pat' matches NO tracked carry-class ($probe_exts) path and is DECLARED prophylactic; not exercised here"
        else
          cases=$((cases + 1))
          echo "FAIL  configured: carry-exclude — '$probe_pat' matches NO tracked carry-class ($probe_exts) path in this repository: a typo or wrong anchor is dead config (declare it in REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC if it deliberately guards paths that do not exist yet)" >&2
          failures=$((failures + 1))
        fi
      elif [ "$probe_rc" -eq 3 ]; then
        # Matching tracked paths OUTSIDE the enabled carry classes is not
        # a typo — the glob provably names real paths — and steering it
        # into the prophylactic declaration would make that declaration
        # false (its contract: no tracked match today). Inert for today's
        # classes, legitimately kept for other or future ones: loud note.
        echo "note  configured: carry-exclude — '$probe_pat' matches tracked paths but none in the enabled carry classes ($probe_exts): inert for today's carry classes (kept for other or future classes); not exercised here"
      else
        echo "note  configured: carry-exclude — '$probe_pat' derives no carry-class ($probe_exts) probe: it guards paths the enabled carry class never carries, or uses ?/[/\\ metacharacters; not exercised here"
      fi
    done <<EOF_EXCLUDE_BATTERY
$(list_items "$ACTIVE_CARRY_EXCLUDE")
EOF_EXCLUDE_BATTERY

    # The prophylactic ledger is validated in BOTH directions (tracked
    # mode): each declared entry must be an exact member of the active
    # exclusion list AND still match nothing tracked. The loop above only
    # consults the ledger on a no-match glob, so without this pass a
    # declaration whose glob was renamed away, or whose guarded path has
    # since been committed, would sit silently false — a waiver that
    # outlives its subject masks nothing and trains operators to trust a
    # lying ledger.
    if [ "$EXCLUDE_TRACKED_MODE" = "tracked" ] && [ -n "$ACTIVE_CARRY_EXCLUDE_PROPHYLACTIC" ]; then
      while IFS= read -r proph_pat; do
        [ -z "$proph_pat" ] && continue
        proph_member=""
        while IFS= read -r proph_x; do
          [ "$proph_x" = "$proph_pat" ] && proph_member=1
        done <<EOF_PROPH_MEMBER
$(list_items "$ACTIVE_CARRY_EXCLUDE")
EOF_PROPH_MEMBER
        if [ -z "$proph_member" ]; then
          cases=$((cases + 1))
          echo "FAIL  configured: carry-exclude — prophylactic declaration '$proph_pat' is not an active REVIEW_GATE_CARRY_FORWARD_EXCLUDE entry: a waiver without its glob is stale config (remove the declaration, or restore the exclusion it waives)" >&2
          failures=$((failures + 1))
          continue
        fi
        # shellcheck disable=SC2086 # probe_exts is a controlled word list
        proph_match="$(exclude_glob_probe "$proph_pat" $probe_exts)"
        proph_rc=$?
        if [ "$proph_rc" -ne 2 ]; then
          cases=$((cases + 1))
          echo "FAIL  configured: carry-exclude — prophylactic declaration '$proph_pat' no longer holds: the glob now matches ${proph_match:-tracked paths} (the declaration asserts NO tracked match today; remove it so the live exclusion is exercised)" >&2
          failures=$((failures + 1))
        fi
      done <<EOF_PROPH_VALIDATE
$(list_items "$ACTIVE_CARRY_EXCLUDE_PROPHYLACTIC")
EOF_PROPH_VALIDATE
    fi

    if [ -n "$probe_free" ]; then
      reset
      CFG_TRUSTED_LOGINS="$ACTIVE_TRUSTED_LOGINS"
      reviews_set "$(review "$(trusted_reviewer)" APPROVED "2026-01-01T00:00:00Z" "$OTHER")"
      compare_fix ahead "[$(delta_file "$probe_free" modified "$(probe_patch_for "$probe_free")")]"
      run "configured: carry-exclude — '$probe_free' is outside every committed glob and still carries" approved
    else
      # No carry-free probe in EITHER mode. A STRUCTURALLY universal entry
      # is a FAIL regardless of mode — with one committed, no path today
      # or ever can carry, so "future files still carry" is false and the
      # tracked-mode note below would understate a dead config.
      # Structurally universal under the predicate's bash-case matcher: an
      # entry built ONLY of '*'/'?' wildcards, with at least one '*' and
      # AT MOST one '?' — '*', '***', '?*', '*?' match every non-empty
      # path by construction, while two or more '?'s impose a minimum
      # length that one-character paths escape, and '?'-only entries pin
      # an exact length; neither is universal.
      #
      # PER-ENTRY only, deliberately: a SET of globs can be jointly
      # universal ('?;??*' by length split, 'a*;[!a]*' by first-character
      # partition), and detecting that in general is glob-coverage
      # analysis with no bounded implementation. Such sets take the notes
      # below — loud and fail-safe, never a silent green — and tracked
      # mode judges them against real paths with no heuristic at all.
      probe_universal=""
      while IFS= read -r probe_pat_u; do
        [ -z "$probe_pat_u" ] && continue
        case "$probe_pat_u" in
          *[!*?]*) : ;;
          *'*'*)
            probe_pat_u_qs="${probe_pat_u//\*/}"
            case "$probe_pat_u_qs" in
              '' | '?') probe_universal="$probe_pat_u" ;;
            esac
            ;;
        esac
      done <<EOF_UNIVERSAL
$(list_items "$ACTIVE_CARRY_EXCLUDE")
EOF_UNIVERSAL
      if [ -n "$probe_universal" ]; then
        cases=$((cases + 1))
        echo "FAIL  configured: carry-exclude — '$probe_universal' matches every path; the enabled carry class can never apply to any DELTA (identical-tree/rebase-residue carries alone would remain, which exclusions never touch). Overwhelmingly a misconfiguration: narrow the exclusions to the real policy surfaces, or disable REVIEW_GATE_CARRY_FORWARD instead of excluding everything" >&2
        failures=$((failures + 1))
      elif [ "$EXCLUDE_TRACKED_MODE" != "tracked" ]; then
        # Hermetic mode: finite synthetic probes cannot PROVE universality
        # — a glob set that merely spans both harness namespaces exhausts
        # the candidates while ordinary paths still carry.
        echo "note  configured: carry-exclude — every synthetic carry-class ($probe_exts) probe is excluded but no committed glob is structurally universal: universality is UNPROVEN by synthetic probes (run inside the repository for tracked-path evidence); positive carry case not exercised here"
      else
        # Tracked mode: the CURRENT tree has no carry-free carry-class
        # file, but future files outside the globs can still carry (a repo
        # whose only Markdown is an intentionally excluded README is
        # legitimate). Loud note, not a FAIL — the current tree cannot
        # prove universality.
        echo "note  configured: carry-exclude — no TRACKED carry-class ($probe_exts) file escapes the committed exclusions today; the positive carry case is unproven against this tree (future non-excluded files still carry)"
      fi
    fi
  fi
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
    REVIEW_GATE_CARRY_FORWARD_EXCLUDE="$CFG_CARRY_EXCLUDE" \
    REVIEW_GATE_MODE="$CFG_GATE_MODE" \
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
