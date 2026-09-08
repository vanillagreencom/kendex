#!/usr/bin/env bash
# Behavioral tests for the SHIPPED skills/review-gate/scripts/review-writer.sh
# — the single writer, whose entire job is to converge the gate commit
# status to the predicate's verdict. Stubbed GitHub API, every leg driven
# offline.
#
# The writer does not police CI (that is branch protection's job; see the
# script header's adoption precondition), so there is no proof chain here to
# test: no rerun, no provenance marker, no attempt floor, no evidence
# ordering, no stall recovery. What remains is the decision table, the write
# discipline, and leg routing.
#
# Verdict -> status:
#   w1.  awaiting, no gate status            -> posts pending
#   w2.  awaiting, already pending w/ same   -> no-op: two evaluations leave
#        description                            ONE entry (idempotence)
#   w3.  changes-requested over a NEWER      -> posts failure directly —
#        success entry                          downward posts never defer
#   w4.  threads-open                        -> posts pending
#   w5.  approved, already success           -> no-op
#   w6.  approved, currently pending         -> posts success
#   w7.  approved, currently failure         -> posts success (a dismissed
#                                               objection reopens the gate)
#   w8.  unreasoned-decline                  -> posts failure, remedy in the
#                                               description
#   w8b. unreasoned-decline over a NEWER     -> posts failure directly
#        success entry
#   w9.  untracked-claim                     -> posts failure, remedy in the
#                                               description
#   w9b. untracked-claim over a NEWER        -> posts failure directly
#        success entry
# Write discipline (ordering guard, success posts only):
#   w10. guard re-read shows a non-success   -> defers (exit 0, no POST)
#        entry at/after evaluated_at
#   w10b. same-second non-success write      -> still defers (>=, not >)
#   w10c. newer SUCCESS entry                -> ALSO defers: the description
#                                               carries the audit detail
#                                               (override reason), so a stale
#                                               run must not overwrite it
#   w11. guard re-read FAILS                 -> defers (fail-safe side)
#   w12. downward posts never consult it     -> failure posts over a newer
#                                               entry without deferring
# Fail loud, act never:
#   w21. predicate read failure              -> exit 1, NO POST
#   w22. status-history read failure         -> exit 1, NO POST
#   w23. PR_NUMBER without HEAD_SHA          -> exit 1 (recursive contract)
#   w24. unknown verdict                     -> exit 1, NO POST
# Leg routing (converge-all):
#   w25. WRITER_READ_ONLY=1 (fork            -> exit 0, posts nothing, never
#        pull_request_review no-op)             consults the predicate (a
#                                               broken predicate proves it)
#   w26. merge_group leg                     -> unconditional success post,
#                                               predicate never consulted
#   w27. schedule pass, two open PRs         -> converges BOTH heads
#   w28. one PR failing                      -> exit 1, other PR converged
#   w29. EVENT leg with no identifiers       -> ALSO enumerates every open
#                                               PR, so an evicted pending
#                                               run strands nothing
#   w30. zero open PRs / ghost author        -> clean pass
#   wp1-wp3. pagination merges               -> page-two PRs enumerate; a
#                                               page-two guard entry defers
# The WORKFLOW YAML is asserted in its own suite,
# review-writer-template.test.sh — the relay step extracted and EXECUTED
# against a gh stub over both copies. This file is the review-writer.sh
# engine suite: one instrument class, one subject.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$TEST_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

# Sandbox: the real writer + its real settings lib, next to a stubbed
# predicate.
mkdir -p "$TMP_ROOT/scripts/lib" "$TMP_ROOT/bin"
cp "$SKILL_ROOT/scripts/review-writer.sh" "$TMP_ROOT/scripts/"
cp "$SKILL_ROOT/scripts/lib/settings.sh" "$TMP_ROOT/scripts/lib/"
cat > "$TMP_ROOT/scripts/review-predicate.sh" <<'EOF'
#!/usr/bin/env bash
# Predicate stub: STUB_PREDICATE_RC != 0 simulates an evidence-read failure
# (no verdict); otherwise STUB_VERDICT_LINE is the authoritative verdict and
# STUB_EVIDENCE_AT is written to the REVIEW_GATE_EVIDENCE_AT_FILE seam.
# STUB_PREDICATE_FAIL_PR fails only that PR's evaluation (containment
# cases). STUB_PREDICATE_ENV_LOG records the override-context env the writer
# hands down (the override-context cases).
if [[ -n "${STUB_PREDICATE_ENV_LOG:-}" ]]; then
  printf 'OVERRIDE=%s\n' "${REVIEW_GATE_OVERRIDE_CONTEXT-<unset>}" >> "$STUB_PREDICATE_ENV_LOG"
  printf 'AUTHOR=%s\n' "${PR_AUTHOR-<unset>}" >> "$STUB_PREDICATE_ENV_LOG"
fi
if [[ "${STUB_PREDICATE_RC:-0}" != "0" ]]; then
  echo "::error::stubbed predicate failure" >&2
  exit "${STUB_PREDICATE_RC}"
fi
if [[ -n "${STUB_PREDICATE_FAIL_PR:-}" && "${STUB_PREDICATE_FAIL_PR}" == "${PR_NUMBER:-}" ]]; then
  echo "::error::stubbed predicate failure for PR ${PR_NUMBER}" >&2
  exit 2
fi
printf '%s\n' "${STUB_VERDICT_LINE:?}"
if [[ -n "${REVIEW_GATE_EVIDENCE_AT_FILE:-}" ]]; then
  printf '%s\n' "${STUB_EVIDENCE_AT:-}" > "$REVIEW_GATE_EVIDENCE_AT_FILE"
fi
EOF
chmod +x "$TMP_ROOT/scripts/review-predicate.sh" "$TMP_ROOT/scripts/review-writer.sh"

# Parametrized `gh` stub:
#   STUB_GATE_HISTORY   JSON array (newest first) answered for the
#                       projection read commits/<sha>/statuses; "fail" fails
#                       the read
#   STUB_GUARD_HISTORY  answered for the guard's RE-read (the per_page=100
#                       URL); defaults to STUB_GATE_HISTORY; "fail" fails
#                       only the re-read
#   STUB_OPEN_PRS       JSON array answered for pulls?state=open
#   STUB_POST_LOG       file collecting every status POST's args
#   (No runs/jobs/rerun stubs: the writer never touches those APIs.)
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
[[ "${1:-}" == "api" ]] || { echo "unexpected gh command: $*" >&2; exit 1; }
shift
args="$*"
case "$args" in
  "-X POST "*"/statuses/"*)
    echo "post:$args" >> "${STUB_POST_LOG:?}"
    ;;
  *"/commits/"*"/statuses?per_page=100"*)
    # The ordering guard's re-read — distinguishable from the projection read
    # by its explicit per_page, so the two can fail independently.
    # STUB_GUARD_HISTORY_PAGE2 emits a second page (gh --paginate emits one
    # array per page, concatenated) so first-page-only merges are catchable.
    guard="${STUB_GUARD_HISTORY:-${STUB_GATE_HISTORY:-[]}}"
    if [[ "$guard" == "fail" ]]; then
      echo "HTTP 500" >&2
      exit 1
    fi
    if [[ "$guard" == "whitespace" ]]; then printf '   \n'; exit 0; fi
    printf '%s\n' "$guard"
    if [[ -n "${STUB_GUARD_HISTORY_PAGE2:-}" ]]; then printf '%s\n' "$STUB_GUARD_HISTORY_PAGE2"; fi
    ;;
  *"/commits/"*"/statuses"*)
    if [[ "${STUB_GATE_HISTORY:-[]}" == "fail" ]]; then
      echo "HTTP 500" >&2
      exit 1
    fi
    # "emptybytes": a SUCCESSFUL call producing zero bytes — the broken-read
    # shape the writer must fail loud on, distinct from the empty page `[]`.
    if [[ "${STUB_GATE_HISTORY:-[]}" == "emptybytes" ]]; then exit 0; fi
    if [[ "${STUB_GATE_HISTORY:-[]}" == "whitespace" ]]; then printf '   \n'; exit 0; fi
    printf '%s\n' "${STUB_GATE_HISTORY:-[]}"
    if [[ -n "${STUB_GATE_HISTORY_PAGE2:-}" ]]; then printf '%s\n' "$STUB_GATE_HISTORY_PAGE2"; fi
    ;;
  *"pulls?state=open"*)
    if [[ "${STUB_OPEN_PRS:-[]}" == "fail" ]]; then
      echo "HTTP 500" >&2
      exit 1
    fi
    if [[ "${STUB_OPEN_PRS:-[]}" == "emptybytes" ]]; then exit 0; fi
    if [[ "${STUB_OPEN_PRS:-[]}" == "whitespace" ]]; then printf '   \n'; exit 0; fi
    printf '%s\n' "${STUB_OPEN_PRS:-[]}"
    if [[ -n "${STUB_OPEN_PRS_PAGE2:-}" ]]; then printf '%s\n' "$STUB_OPEN_PRS_PAGE2"; fi
    ;;
  *)
    echo "unexpected gh api call: $args" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/gh"

# `date` shim: STUB_DATE_FIXED pins the writer's evaluated_at stamp so
# equal-second cases against a status entry's created_at are constructible;
# unset, the real date answers.
cat > "$TMP_ROOT/bin/date" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${STUB_DATE_FIXED:-}" ]]; then
  printf '%s\n' "$STUB_DATE_FIXED"
else
  exec /bin/date "$@"
fi
EOF
chmod +x "$TMP_ROOT/bin/date"

# The verdict lines the stubbed predicate answers with. The writer is
# idempotent on state+description, so the fixture histories below reuse the
# awaiting detail exactly.
AWAITING_DETAIL="no review evidence at headsha yet"
AWAITING="verdict=awaiting detail=$AWAITING_DETAIL"
APPROVED="verdict=approved detail=reviewed at head with no unresolved threads"
CR="verdict=changes-requested detail=standing review changes requested (persists across pushes until re-approval or dismissal)"
THREADS="verdict=threads-open detail=2 unresolved review thread(s)"
UNREASONED="verdict=unreasoned-decline detail=1 decline names no mechanism"
UNTRACKED="verdict=untracked-claim detail=1 tracking claim names no issue"

# created_at anchors: OLD predates every evaluation instant; FUTURE postdates
# every one; SAME is the instant a `date` shim pins the evaluation to.
OLD="2020-01-01T00:00:00Z"
FUTURE="2999-01-01T00:00:00Z"
SAME="2026-06-15T12:00:00Z"
entry() { # state, description, created_at -> one gate status row
  printf '{"context":"Review gate","state":"%s","description":"%s","created_at":"%s"}' "$1" "$2" "$3"
}
H_PENDING_OLD="[$(entry pending "$AWAITING_DETAIL" "$OLD")]"
H_PENDING_OLD_X="[$(entry pending x "$OLD")]"
H_SUCCESS_OLD="[$(entry success "reviewed at head with no unresolved threads" "$OLD")]"
H_PENDING_REVIEWED_OLD="[$(entry pending "reviewed at head with no unresolved threads" "$OLD")]"
# The commit-status API caps a description at 140 characters; the writer
# truncates there and compares the truncated form when it decides a no-op.
LONG_DETAIL="1 decline names no mechanism: give a passing state or a false premise it disproves, a label alone is not a reason, and the gate will not clear until then"
LONG_DETAIL_140="${LONG_DETAIL:0:140}"
LONG_UNREASONED="verdict=unreasoned-decline detail=$LONG_DETAIL"
H_FAILURE_LONG_OLD="[$(entry failure "$LONG_DETAIL_140" "$OLD")]"
H_FAILURE_OLD="[$(entry failure "standing review changes requested" "$OLD")]"
H_SUCCESS_FUTURE="[$(entry success ok "$FUTURE")]"
G_PENDING_FUTURE="[$(entry pending "newer writer run" "$FUTURE")]"
G_PENDING_SAME="[$(entry pending "same-second write" "$SAME")]"
G_SUCCESS_FUTURE="[$(entry success "operator override (ctx) : real reason" "$FUTURE")]"
G_FAILURE_FUTURE="[$(entry failure newer "$FUTURE")]"
OPEN2='[{"number":7,"head":{"sha":"sha7"},"user":{"login":"alice"}},{"number":8,"head":{"sha":"sha8"},"user":{"login":"bob"}}]'
OPEN7='[{"number":7,"head":{"sha":"sha7"},"user":{"login":"alice"}}]'
OPEN8='[{"number":8,"head":{"sha":"sha8"},"user":{"login":"bob"}}]'
OPEN_GHOST='[{"number":9,"head":{"sha":"sha9"},"user":null}]'
ERROR_PAGE='{"message":"Server Error"}'

# run_writer MODE ENV — runs the writer under the stubs. MODE is `single`
# (the single-head recursive contract: PR_NUMBER and HEAD_SHA set), `nohead`
# (PR_NUMBER without HEAD_SHA), or `all:<event>` (the identifiers scrubbed
# so the top-level invocation enumerates every open PR). ENV is a
# semicolon-separated list of `env` arguments, applied after the defaults so
# a row may override any of them. Every run gets its own post log and
# predicate-environment log under $RUN. OUT is stdout and stderr together;
# RC the exit status. Settings resolve from /dev/null (built-in defaults)
# unless a row overrides REVIEW_GATE_SETTINGS_FILE.
RUN_SEQ=0
run_writer() {
  local mode="$1" env_list="$2" env_args=() unset=() ids=() runner=()
  [[ -z "$env_list" ]] || IFS=';' read -ra env_args <<<"$env_list"
  RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"
  mkdir -p "$RUN"
  : > "$RUN/post.log"
  : > "$RUN/predicate-env.log"
  case "$mode" in
    single) ids=(PR_NUMBER=7 HEAD_SHA=headsha PR_AUTHOR=pr-author) ;;
    nohead) unset=(-u HEAD_SHA); ids=(PR_NUMBER=7) ;;
    all:*)  unset=(-u PR_NUMBER -u HEAD_SHA -u PR_AUTHOR); ids=("EVENT_NAME=${mode#all:}")
            # A converge-all pass forks the writer once per PR; the bound is
            # what turns a hang there into a red rather than a stuck shard.
            command -v timeout >/dev/null 2>&1 && runner=(timeout 90) ;;
    *) printf 'run_writer: unknown mode %s\n' "$mode" >&2; exit 1 ;;
  esac
  set +e
  OUT=$(env ${unset[@]+"${unset[@]}"} PATH="$TMP_ROOT/bin:$PATH" GH_REPO=acme/widgets \
    EVENT_NAME=pull_request_target REVIEW_GATE_SETTINGS_FILE=/dev/null \
    STUB_POST_LOG="$RUN/post.log" STUB_PREDICATE_ENV_LOG="$RUN/predicate-env.log" \
    "${ids[@]}" ${env_args[@]+"${env_args[@]}"} \
    ${runner[@]+"${runner[@]}"} bash "$TMP_ROOT/scripts/review-writer.sh" 2>&1)
  RC=$?
  set -e
}

# observe EXPECT — prints the run's value of every `name=` field EXPECT names,
# in EXPECT's order, so a row fails on the field it names:
#   rc         exit status
#   posts      every status POST in order as `<state>@<sha>`, or none
#   context    the distinct gate contexts posted, `+` for a space
#   desc       the last post's description, `+` for a space
#   desc~<t>   whether the last post's description carries <t>
#   says~<t>   whether the output carries <t>, `+` read as a space
#   override   the REVIEW_GATE_OVERRIDE_CONTEXT the predicate saw: unset, its
#              value, or none when the predicate never ran
#   author     the PR_AUTHOR values the predicate saw, `-` for an empty one
observe() {
  local got="" token name value line needle
  for token in $1; do
    name="${token%%=*}"
    case "$name" in
      rc) value="$RC" ;;
      posts)
        value=""
        while IFS= read -r line; do
          [[ -n "$line" ]] || continue
          line="${line#post:-X POST repos/acme/widgets/statuses/}"
          value="$value,${line#* -f state=}"
          value="${value%% -f *}@${line%% -f *}"
        done <"$RUN/post.log"
        value="${value#,}"; value="${value:-none}" ;;
      context)
        value="$(sed -n 's/.* -f context=\(.*\) -f description=.*/\1/p' "$RUN/post.log" | sort -u | paste -sd, - | tr ' ' '+')"
        value="${value:-none}" ;;
      desc)
        value="$(sed -n '$s/.* -f description=\(.*\) -f target_url=.*/\1/p; $s/.* -f description=\(.*\)$/\1/p' "$RUN/post.log" | tr ' ' '+')"
        value="${value:-none}" ;;
      desc~*)
        needle="${name#desc~}"; needle="${needle//+/ }"
        line="$(sed -n '$p' "$RUN/post.log")"
        value="$(grep -qF -- "-f description=${needle}" <<<"$line" || grep -qF -- "$needle" <<<"${line#* -f description=}" && echo true || echo false)" ;;
      says~*)
        needle="${name#says~}"; needle="${needle//+/ }"
        value="$(grep -qF -- "$needle" <<<"$OUT" && echo true || echo false)" ;;
      override)
        value="$(sed -n 's/^OVERRIDE=//p' "$RUN/predicate-env.log" | sort -u | paste -sd, -)"
        value="${value//</}"; value="${value//>/}"; value="${value:-none}" ;;
      author)
        value="$(sed -n 's/^AUTHOR=//p; s/^AUTHOR=$/-/p' "$RUN/predicate-env.log" | sed 's/^$/-/' | paste -sd, -)"
        value="${value//</}"; value="${value//>/}"; value="${value:-none}" ;;
      *) value=UNKNOWN_FIELD ;;
    esac
    got="$got $name=$value"
  done
  printf '%s' "${got# }"
}

# table ROW... — one run and one assertion per row: `label|mode|env|expect`.
table() {
  local row label mode env expect before=$((PASS + FAIL))
  for row in "$@"; do
    IFS='|' read -r label mode env expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    run_writer "$mode" "$env"
    assert_eq "$(observe "$expect")" "$expect" "$label"
  done
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "table: no row was asserted" >&2; exit 2; }
}

echo "=== downward transitions are direct posts, idempotent, never deferred ==="
# A decline naming no mechanism and a tracking claim naming no issue are
# failures, not pendings: the gate goes red rather than waiting for something
# to converge. Both are driven through the writer because the mapping line
# alone reads the same whether the verdict is spelled right or not, and an
# unmapped verdict exits 1 on "unknown verdict" instead of posting.
table \
  "w1: awaiting with no gate status posts pending under the default gate context|single|STUB_VERDICT_LINE=$AWAITING;STUB_GATE_HISTORY=[]|rc=0 posts=pending@headsha context=Review+gate" \
  "w2: a second evaluation of an unchanged state posts nothing and reports the no-op|single|STUB_VERDICT_LINE=$AWAITING;STUB_GATE_HISTORY=$H_PENDING_OLD|rc=0 posts=none says~nothing+to+do=true" \
  "w2b: the same state under a different description is re-posted|single|STUB_VERDICT_LINE=$AWAITING;STUB_GATE_HISTORY=$H_PENDING_OLD_X|rc=0 posts=pending@headsha desc=no+review+evidence+at+headsha+yet" \
  "w3: changes-requested posts failure over a newer success without deferring|single|STUB_VERDICT_LINE=$CR;STUB_GATE_HISTORY=$H_SUCCESS_FUTURE|rc=0 posts=failure@headsha says~deferring=false" \
  "w4: threads-open posts pending|single|STUB_VERDICT_LINE=$THREADS;STUB_GATE_HISTORY=[]|rc=0 posts=pending@headsha" \
  "w8: unreasoned-decline posts failure with the remedy in the description|single|STUB_VERDICT_LINE=$UNREASONED;STUB_GATE_HISTORY=[]|rc=0 posts=failure@headsha desc=1+decline+names+no+mechanism" \
  "w8b: unreasoned-decline over a newer success posts failure without deferring|single|STUB_VERDICT_LINE=$UNREASONED;STUB_GATE_HISTORY=$H_SUCCESS_FUTURE|rc=0 posts=failure@headsha says~deferring=false" \
  "w9: untracked-claim posts failure with the remedy in the description|single|STUB_VERDICT_LINE=$UNTRACKED;STUB_GATE_HISTORY=[]|rc=0 posts=failure@headsha desc=1+tracking+claim+names+no+issue" \
  "w9c: a detail past the API's 140 characters is posted truncated there|single|STUB_VERDICT_LINE=$LONG_UNREASONED;STUB_GATE_HISTORY=[]|rc=0 posts=failure@headsha desc=${LONG_DETAIL_140// /+}" \
  "w9d: the no-op check compares the truncated form, so a long detail already posted is not re-posted|single|STUB_VERDICT_LINE=$LONG_UNREASONED;STUB_GATE_HISTORY=$H_FAILURE_LONG_OLD|rc=0 posts=none says~nothing+to+do=true" \
  "w9b: untracked-claim over a newer success posts failure without deferring|single|STUB_VERDICT_LINE=$UNTRACKED;STUB_GATE_HISTORY=$H_SUCCESS_FUTURE|rc=0 posts=failure@headsha says~deferring=false"

echo "=== approved converges to success ==="
table \
  "w5: approved with the same success entry posts nothing|single|STUB_VERDICT_LINE=$APPROVED;STUB_GATE_HISTORY=$H_SUCCESS_OLD|rc=0 posts=none says~nothing+to+do=true" \
  "w5b: the same description under a different state is re-posted|single|STUB_VERDICT_LINE=$APPROVED;STUB_GATE_HISTORY=$H_PENDING_REVIEWED_OLD|rc=0 posts=success@headsha" \
  "w6: a reviewed head over pending opens the gate|single|STUB_VERDICT_LINE=$APPROVED;STUB_GATE_HISTORY=$H_PENDING_OLD|rc=0 posts=success@headsha" \
  "w7: a dismissed objection reopens the gate|single|STUB_VERDICT_LINE=$APPROVED;STUB_GATE_HISTORY=$H_FAILURE_OLD|rc=0 posts=success@headsha"

echo "=== the ordering guard (success posts only) ==="
# The guard re-reads before a success post and defers, exit 0 and no POST,
# to any entry at or after this run's evaluation instant: a newer
# non-success, a same-second write (>=, one-second resolution), and a newer
# SUCCESS too, whose description carries the audit detail a stale run must
# not overwrite. A re-read that fails or is malformed lands on the same
# fail-safe side: a whitespace-only page slurps to [] and an empty object
# collapses through `add`, and both would report newer=0 and permit exactly
# the stale success the guard exists to block. Downward posts never consult
# it.
table \
  "w10: a newer non-success entry defers the success post|single|STUB_VERDICT_LINE=$APPROVED;STUB_GATE_HISTORY=$H_PENDING_OLD;STUB_GUARD_HISTORY=$G_PENDING_FUTURE|rc=0 posts=none says~deferring+the+success+post=true" \
  "w10b: a same-second non-success write still defers|single|STUB_VERDICT_LINE=$APPROVED;STUB_GATE_HISTORY=$H_PENDING_OLD;STUB_DATE_FIXED=$SAME;STUB_GUARD_HISTORY=$G_PENDING_SAME|rc=0 posts=none says~deferring+the+success+post=true" \
  "w10c: a newer SUCCESS entry also defers|single|STUB_VERDICT_LINE=$APPROVED;STUB_GATE_HISTORY=$H_PENDING_OLD;STUB_GUARD_HISTORY=$G_SUCCESS_FUTURE|rc=0 posts=none says~deferring+the+success+post=true" \
  "w11: a failed guard re-read defers|single|STUB_VERDICT_LINE=$APPROVED;STUB_GATE_HISTORY=$H_PENDING_OLD;STUB_GUARD_HISTORY=fail|rc=0 posts=none says~deferring+the+success+post=true" \
  "w11b: a whitespace-only guard re-read defers|single|STUB_VERDICT_LINE=$APPROVED;STUB_GATE_HISTORY=$H_PENDING_OLD;STUB_GUARD_HISTORY=whitespace|rc=0 posts=none says~deferring+the+success+post=true" \
  "w11c: an empty-object guard re-read defers|single|STUB_VERDICT_LINE=$APPROVED;STUB_GATE_HISTORY=$H_PENDING_OLD;STUB_GUARD_HISTORY={}|rc=0 posts=none says~deferring+the+success+post=true" \
  "w12: a downward post never consults the guard and never defers|single|STUB_VERDICT_LINE=$CR;STUB_GATE_HISTORY=$H_PENDING_OLD;STUB_GUARD_HISTORY=$G_PENDING_FUTURE|rc=0 posts=failure@headsha says~deferring=false"

echo "=== fail loud, act never ==="
# A read the writer cannot trust is exit 1 and no POST: a failed predicate, a
# failed or zero-byte status read (a SUCCESSFUL call producing zero bytes is
# a broken read, not the empty page `[]`), a status page that is not an
# array (an error object, or whitespace that slurps to []), and the
# recursive contract's missing HEAD_SHA. The gh stub answers any endpoint the
# writer is not meant to touch with exit 1, so a rerun or run read would
# surface here as a red too.
table \
  "w21: a predicate failure exits 1 and posts nothing|single|STUB_PREDICATE_RC=2;STUB_GATE_HISTORY=[]|rc=1 posts=none" \
  "w22: a failed status-history read exits 1 and posts nothing|single|STUB_VERDICT_LINE=$APPROVED;STUB_GATE_HISTORY=fail|rc=1 posts=none" \
  "w22b: a zero-byte status-history read exits 1 and posts nothing|single|STUB_VERDICT_LINE=$APPROVED;STUB_GATE_HISTORY=emptybytes|rc=1 posts=none says~zero+bytes=true" \
  "w22f: an error-object status page exits 1 naming the shape violation|single|STUB_VERDICT_LINE=$APPROVED;STUB_GATE_HISTORY=$ERROR_PAGE|rc=1 posts=none says~not+arrays=true" \
  "w22g: a whitespace-only status-history read exits 1 naming the shape violation|single|STUB_VERDICT_LINE=$APPROVED;STUB_GATE_HISTORY=whitespace|rc=1 posts=none says~not+arrays=true" \
  "w23: PR_NUMBER without HEAD_SHA exits 1 (recursive contract)|nohead|STUB_VERDICT_LINE=$AWAITING|rc=1 posts=none"

echo "=== leg routing: converge-all on every leg ==="
# A broken predicate (exit 2) proves the read-only and merge-group legs never
# consult it: if the guard regressed and the predicate ran, the exit would
# flip to 1. Every other leg enumerates every open PR — the payload sha is
# deliberately unused, so a pending run evicted by a burst strands nothing —
# and one failing PR fails the pass while the others still converge. Zero
# bytes, whitespace and an error object are the three shapes adjacent to
# `[]` (truly no open PRs) that must fail loud rather than strand every gate
# green; a ghost-authored PR enumerates with an empty author.
table \
  "w24: a read-only token (fork pull_request_review) is a no-op that posts nothing and never consults the predicate|single|STUB_PREDICATE_RC=2;WRITER_READ_ONLY=1|rc=0 posts=none says~no-op=true" \
  "w25: the merge_group leg posts an unconditional success saying why, never consulting the predicate|single|STUB_PREDICATE_RC=2;EVENT_NAME=merge_group|rc=0 posts=success@headsha desc~merge-queue+entry=true" \
  "w26: a schedule pass over two open PRs converges both heads, each under its own author|all:schedule|STUB_VERDICT_LINE=$AWAITING;STUB_OPEN_PRS=$OPEN2;STUB_GATE_HISTORY=[]|rc=0 posts=pending@sha7,pending@sha8 author=alice,bob says~converging+2+open+PR(s)=true" \
  "w27b: an approved schedule pass opens both heads|all:schedule|STUB_VERDICT_LINE=$APPROVED;STUB_OPEN_PRS=$OPEN2;STUB_GATE_HISTORY=[]|rc=0 posts=success@sha7,success@sha8" \
  "w27: one failing PR fails the pass, is named, and the other PR still converges|all:schedule|STUB_VERDICT_LINE=$AWAITING;STUB_OPEN_PRS=$OPEN2;STUB_GATE_HISTORY=[];STUB_PREDICATE_FAIL_PR=7|rc=1 posts=pending@sha8 says~convergence+failed+for+PR+#7=true" \
  "w28: an event leg converges ALL open PRs, not the payload head|all:workflow_run|STUB_VERDICT_LINE=$AWAITING;STUB_OPEN_PRS=$OPEN2;STUB_GATE_HISTORY=[]|rc=0 posts=pending@sha7,pending@sha8 says~converging+2+open+PR(s)=true" \
  "w29: zero open PRs is a named empty pass that posts nothing|all:workflow_run|STUB_VERDICT_LINE=$APPROVED;STUB_OPEN_PRS=[]|rc=0 posts=none says~converging+0+open+PR(s)=true" \
  "w22c: a zero-byte open-PR listing exits 1 naming the broken read|all:workflow_run|STUB_VERDICT_LINE=$APPROVED;STUB_OPEN_PRS=emptybytes|rc=1 posts=none says~zero+bytes=true" \
  "w22d: a whitespace-only open-PR listing exits 1 naming the shape violation|all:workflow_run|STUB_VERDICT_LINE=$APPROVED;STUB_OPEN_PRS=whitespace|rc=1 posts=none says~not+arrays=true" \
  "w22e: an error-object open-PR page exits 1 naming the shape violation|all:workflow_run|STUB_VERDICT_LINE=$APPROVED;STUB_OPEN_PRS=$ERROR_PAGE|rc=1 posts=none says~not+arrays=true" \
  "w26c: a ghost-authored PR still converges, with an empty PR_AUTHOR handed down|all:schedule|STUB_VERDICT_LINE=$AWAITING;STUB_OPEN_PRS=$OPEN_GHOST;STUB_GATE_HISTORY=[]|rc=0 posts=pending@sha9 author=-"

echo "=== pagination merges (one array per page; page limits strand state) ==="
table \
  "wp1: a PR beyond page one is enumerated and converged|all:schedule|STUB_VERDICT_LINE=$AWAITING;STUB_OPEN_PRS=$OPEN7;STUB_OPEN_PRS_PAGE2=$OPEN8;STUB_GATE_HISTORY=[]|rc=0 posts=pending@sha7,pending@sha8 says~converging+2+open+PR(s)=true" \
  "wp2: the projection merges every page before deciding: a success on page two alone is already converged|single|STUB_VERDICT_LINE=$APPROVED;STUB_GATE_HISTORY=[];STUB_GATE_HISTORY_PAGE2=$H_SUCCESS_OLD|rc=0 posts=none says~nothing+to+do=true" \
  "wp3: a newer non-success entry on the guard's page two still defers|single|STUB_VERDICT_LINE=$APPROVED;STUB_GATE_HISTORY=$H_PENDING_OLD;STUB_GUARD_HISTORY=[];STUB_GUARD_HISTORY_PAGE2=$G_FAILURE_FUTURE|rc=0 posts=none says~deferring+the+success+post=true"

echo "=== settings: the writer never rewrites the override context ==="
# REVIEW_GATE_OVERRIDE_CONTEXT is resolved in review-predicate.sh, so every
# live gate read honors it; the writer must not export its own resolution on
# top of that, with or without a settings file naming one.
printf 'REVIEW_GATE_OVERRIDE_CONTEXT = "ops-override"\n' >"$TMP_ROOT/override-settings.toml"
table \
  "w30: a settings file naming an override context leaves it to the predicate|single|STUB_VERDICT_LINE=$AWAITING;STUB_GATE_HISTORY=[];REVIEW_GATE_SETTINGS_FILE=$TMP_ROOT/override-settings.toml|rc=0 override=unset" \
  "w30b: an absent override key leaves the predicate's own resolution untouched|single|STUB_VERDICT_LINE=$AWAITING;STUB_GATE_HISTORY=[]|rc=0 override=unset"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
