#!/usr/bin/env bash
# Behavioral tests for the SHIPPED skills/review-gate/scripts/review-writer.sh
# — the single writer, whose entire job is to converge the gate commit
# status to the predicate's verdict. Stubbed GitHub API, every leg driven
# offline.
#
# The writer no longer polices CI (that is branch protection's job — see the
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
# Write discipline (VST-65 ordering guard, success posts only):
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
# Workflow pins (tpl:*): grep-pins on the workflow YAML for expressions
#   offline runs cannot execute (job if:, permissions, triggers, refs).
# Relay step (relay:*): the request-converge step's SCRIPT, extracted from the
#   YAML and EXECUTED against a gh stub — not a pin, the real shell (VST-210).
# BOTH run against BOTH copies: the shipped template AND this repo's
#   self-adoption .github/workflows/ copy, which is what actually gates every
#   vstack PR and is hand-maintained. Template-only assertions would prove the
#   behavior of a file CI never runs. The second path is skipped when absent so
#   a consumer install (vendored skill, no such workflow) still passes.
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

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        must not contain: %s\n' "$name" "$needle"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
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
# cases). STUB_PREDICATE_ENV_LOG records the outage-context env the writer
# hands down (the OVERRIDE_CONTEXT alias cases).
if [[ -n "${STUB_PREDICATE_ENV_LOG:-}" ]]; then
  printf 'OUTAGE=%s\n' "${REVIEW_GATE_OUTAGE_CONTEXT-<unset>}" >> "$STUB_PREDICATE_ENV_LOG"
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
    # The VST-65 guard's re-read — distinguishable from the projection read
    # by its explicit per_page, so the two can fail independently.
    # STUB_GUARD_HISTORY_PAGE2 emits a second page (gh --paginate emits one
    # array per page, concatenated) so first-page-only merges are catchable.
    guard="${STUB_GUARD_HISTORY:-${STUB_GATE_HISTORY:-[]}}"
    if [[ "$guard" == "fail" ]]; then
      echo "HTTP 500" >&2
      exit 1
    fi
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

# run_writer [ENV=val ...] — runs the writer under the stubs in the
# single-head recursive contract (PR_NUMBER + HEAD_SHA set) with fresh
# POST/rerun logs; prints stdout+stderr, returns its exit code. EVENT_NAME
# defaults to pull_request_target; only merge_group changes behavior.
# Settings resolve from /dev/null (built-in defaults) unless a case
# overrides REVIEW_GATE_SETTINGS_FILE.
POST_LOG="$TMP_ROOT/post.log"
RERUN_LOG="$TMP_ROOT/rerun.log"
ATTEMPT_LOG="$TMP_ROOT/rerun-attempts.log"
run_writer() {
  : > "$POST_LOG"
  : > "$RERUN_LOG"
  : > "$ATTEMPT_LOG"
  env PATH="$TMP_ROOT/bin:$PATH" \
    GH_REPO=acme/widgets PR_NUMBER=7 HEAD_SHA=headsha PR_AUTHOR=pr-author \
    EVENT_NAME=pull_request_target \
    REVIEW_GATE_SETTINGS_FILE=/dev/null \
    STUB_POST_LOG="$POST_LOG" STUB_RERUN_LOG="$RERUN_LOG" \
    STUB_RERUN_ATTEMPT_LOG="$ATTEMPT_LOG" \
    "$@" bash "$TMP_ROOT/scripts/review-writer.sh" 2>&1
}

AWAITING="verdict=awaiting detail=awaiting a non-author review for headsha"
APPROVED="verdict=approved detail=reviewed at head with no unresolved threads"
CR="verdict=changes-requested detail=standing review changes requested (persists across pushes until re-approval or dismissal)"
THREADS="verdict=threads-open detail=2 unresolved review thread(s)"

# created_at anchors: OLD predates every stub run's start (RUN_START =
# 2020-06-01) and every evaluation instant; LATE lands after RUN_START but
# before now; FUTURE postdates every evaluation instant.
OLD="2020-01-01T00:00:00Z"
# RECENT is five minutes ago: inside the stall bound (so markers dated with
# it exercise the WAITING path) but strictly BEFORE this run's evaluation
# instant, so it does not also trip the VST-65 ordering guard. Markers dated
# OLD are past the bound and exercise the self-heal path.
RECENT="$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
LATE="2020-12-31T00:00:00Z"
FUTURE="2999-01-01T00:00:00Z"

echo "=== downward transitions are direct posts, idempotent, never deferred ==="

rc=0; out=$(run_writer STUB_VERDICT_LINE="$AWAITING" STUB_GATE_HISTORY='[]') || rc=$?
assert_eq "$rc" "0" "w1: awaiting exits 0"
assert_contains "$(cat "$POST_LOG")" "state=pending" "w1: awaiting posts pending"
assert_contains "$(cat "$POST_LOG")" "context=Review gate" "w1: post carries the default gate context"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "w1: no rerun on a downward transition"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$AWAITING" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"pending","description":"awaiting a non-author review for headsha","created_at":"'"$OLD"'"}]') || rc=$?
assert_eq "$rc" "0" "w2: the idempotent no-op exits 0"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w2: second evaluation of an unchanged state posts nothing (one entry total)"
assert_contains "$out" "nothing to do" "w2: reports the no-op"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$CR" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success","description":"ok","created_at":"'"$FUTURE"'"}]') || rc=$?
assert_eq "$rc" "0" "w3: changes-requested exits 0"
assert_contains "$(cat "$POST_LOG")" "state=failure" "w3: posts failure over a newer success — downward posts never defer"
assert_not_contains "$out" "deferring" "w3: no deferral on the downward path"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "w3: no rerun on changes-requested"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$THREADS" STUB_GATE_HISTORY='[]') || rc=$?
assert_eq "$rc" "0" "w4: threads-open exits 0"
assert_contains "$(cat "$POST_LOG")" "state=pending" "w4: threads-open posts pending"

echo "=== approved converges to success ==="

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"success","description":"reviewed at head with no unresolved threads","created_at":"'"$OLD"'"}]') || rc=$?
assert_eq "$rc" "0" "w5: approved with the same success entry exits 0"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w5: unchanged success posts nothing (idempotent)"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"pending","description":"awaiting a non-author review for headsha","created_at":"'"$OLD"'"}]') || rc=$?
assert_eq "$rc" "0" "w6: approved over pending exits 0"
assert_contains "$(cat "$POST_LOG")" "state=success" "w6: a reviewed head opens the gate"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "w6: the writer never re-runs CI (branch protection owns that)"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"failure","description":"standing review changes requested","created_at":"'"$OLD"'"}]') || rc=$?
assert_contains "$(cat "$POST_LOG")" "state=success" "w7: a dismissed objection reopens the gate"

echo "=== VST-65 ordering guard (success posts only) ==="

PENDING_OLD='[{"context":"Review gate","state":"pending","description":"awaiting a non-author review for headsha","created_at":"'"$OLD"'"}]'

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY="$PENDING_OLD" \
  STUB_GUARD_HISTORY='[{"context":"Review gate","state":"pending","description":"newer writer run","created_at":"'"$FUTURE"'"}]') || rc=$?
assert_eq "$rc" "0" "w10: stale success defers with exit 0"
assert_contains "$out" "deferring the success post" "w10: names the deferral"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w10: deferred success posts nothing"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY="$PENDING_OLD" \
  STUB_DATE_FIXED="2026-06-15T12:00:00Z" \
  STUB_GUARD_HISTORY='[{"context":"Review gate","state":"pending","description":"same-second write","created_at":"2026-06-15T12:00:00Z"}]') || rc=$?
assert_eq "$rc" "0" "w10b: same-second non-success write exits 0"
assert_contains "$out" "deferring the success post" "w10b: equality defers (one-second resolution)"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w10b: no post on the equal-second boundary"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY="$PENDING_OLD" \
  STUB_GUARD_HISTORY='[{"context":"Review gate","state":"success","description":"operator override (ctx) : real reason","created_at":"'"$FUTURE"'"}]') || rc=$?
assert_eq "$rc" "0" "w10c: a newer SUCCESS entry also defers (exit 0)"
assert_contains "$out" "deferring the success post" "w10c: names the deferral"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w10c: the stale run must not overwrite the newer success's description"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY="$PENDING_OLD" \
  STUB_GUARD_HISTORY=fail) || rc=$?
assert_eq "$rc" "0" "w11: failed guard re-read defers with exit 0 (fail-safe side)"
assert_contains "$out" "deferring the success post" "w11: names the deferral"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w11: no post on an unreadable re-read"

# A MALFORMED re-read must land on the same fail-safe side as a failed one:
# a whitespace-only success slurps to [] and an error-object page collapses
# through `add` — both would report newer=0 and permit exactly the stale
# success the guard exists to block.
rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY="$PENDING_OLD" \
  STUB_GUARD_HISTORY=$' \n  \n') || rc=$?
assert_eq "$rc" "0" "w11b: whitespace-only guard re-read defers with exit 0"
assert_contains "$out" "deferring the success post" "w11b: names the deferral"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w11b: no post past a vacuous guard re-read"

# EMPTY object, deliberately: `{"message":...}` would have deferred under
# the OLD filter too (`.[]` yields the string, `.context` on a string is a
# jq error → guard_newer="" → defer), proving nothing. `{}` collapses
# through the old `add // [] | .[]` to zero rows → newer=0 → stale success
# POSTS under the old code; only the all-arrays validation defers it.
rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY="$PENDING_OLD" \
  STUB_GUARD_HISTORY='{}') || rc=$?
assert_eq "$rc" "0" "w11c: empty-object guard re-read defers with exit 0 (the old filter posted through it)"
assert_contains "$out" "deferring the success post" "w11c: names the deferral"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w11c: no post past a malformed guard re-read"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$CR" STUB_GATE_HISTORY="$PENDING_OLD" \
  STUB_GUARD_HISTORY='[{"context":"Review gate","state":"pending","description":"newer","created_at":"'"$FUTURE"'"}]') || rc=$?
assert_contains "$(cat "$POST_LOG")" "state=failure" "w12: downward posts never consult the guard"
assert_not_contains "$out" "deferring" "w12: and never defer"

echo "=== fail loud, act never ==="

set +e
out=$(run_writer STUB_PREDICATE_RC=2 STUB_GATE_HISTORY='[]')
rc=$?
set -e
assert_eq "$rc" "1" "w21: predicate failure exits 1"
assert_eq "$(( $(wc -l < "$POST_LOG") ))$(( $(wc -l < "$RERUN_LOG") ))" "00" "w21: no POST and no rerun on predicate failure"

set +e
out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY=fail)
rc=$?
set -e
assert_eq "$rc" "1" "w22: status-history read failure exits 1"
assert_eq "$(( $(wc -l < "$POST_LOG") ))$(( $(wc -l < "$RERUN_LOG") ))" "00" "w22: no action on history read failure"

# A SUCCESSFUL read that produced zero bytes is a broken read, not an empty
# page (`[]`) — slurped silently it would misread current state (here) or
# report a green zero-PR convergence (w22c below).
set +e
out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY=emptybytes)
rc=$?
set -e
assert_eq "$rc" "1" "w22b: zero-byte status-history read exits 1"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w22b: no POST past a zero-byte read"

set +e
out=$(env -u HEAD_SHA PATH="$TMP_ROOT/bin:$PATH" \
  GH_REPO=acme/widgets PR_NUMBER=7 EVENT_NAME=pull_request_target \
  REVIEW_GATE_SETTINGS_FILE=/dev/null \
  STUB_POST_LOG="$POST_LOG" STUB_RERUN_LOG="$RERUN_LOG" \
  STUB_VERDICT_LINE="$AWAITING" bash "$TMP_ROOT/scripts/review-writer.sh" 2>&1)
rc=$?
set -e
assert_eq "$rc" "1" "w23: PR_NUMBER without HEAD_SHA exits 1 (recursive contract)"

echo "=== leg routing: converge-all on every leg ==="

# A broken predicate (RC=2) proves these legs never consult it: if the
# guard regressed and the predicate ran, the exit code would flip to 1.
rc=0; out=$(run_writer STUB_PREDICATE_RC=2 WRITER_READ_ONLY=1) || rc=$?
assert_eq "$rc" "0" "w24: fork pull_request_review (read-only token) exits 0"
assert_contains "$out" "no-op" "w24: names the no-op"
assert_eq "$(( $(wc -l < "$POST_LOG") ))$(( $(wc -l < "$RERUN_LOG") ))" "00" "w24: read-only run posts and reruns nothing"

rc=0; out=$(run_writer STUB_PREDICATE_RC=2 EVENT_NAME=merge_group) || rc=$?
assert_eq "$rc" "0" "w25: merge_group leg exits 0"
assert_contains "$(cat "$POST_LOG")" "state=success" "w25: merge-group sha gets the unconditional success"
assert_contains "$(cat "$POST_LOG")" "merge-queue entry" "w25: post says why"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "w25: queue leg never reruns"

# Converge-all enumeration (binding F2: EVERY leg, not just
# schedule/dispatch). `env -u` scrubs the single-PR identifiers so the
# top-level invocation enumerates.
run_writer_all() {
  : > "$POST_LOG"
  : > "$RERUN_LOG"
  : > "$ATTEMPT_LOG"
  local event="$1"; shift
  local -a runner=()
  command -v timeout >/dev/null 2>&1 && runner=(timeout 90)
  env -u PR_NUMBER -u HEAD_SHA -u PR_AUTHOR \
    PATH="$TMP_ROOT/bin:$PATH" \
    GH_REPO=acme/widgets EVENT_NAME="$event" \
    REVIEW_GATE_SETTINGS_FILE=/dev/null \
    STUB_POST_LOG="$POST_LOG" STUB_RERUN_LOG="$RERUN_LOG" \
    STUB_RERUN_ATTEMPT_LOG="$ATTEMPT_LOG" \
    "$@" "${runner[@]+"${runner[@]}"}" bash "$TMP_ROOT/scripts/review-writer.sh" 2>&1
}

OPEN2='[{"number":7,"head":{"sha":"sha7"},"user":{"login":"alice"}},{"number":8,"head":{"sha":"sha8"},"user":{"login":"bob"}}]'

rc=0; out=$(run_writer_all schedule STUB_VERDICT_LINE="$AWAITING" STUB_OPEN_PRS="$OPEN2" \
  STUB_GATE_HISTORY='[]') || rc=$?
assert_eq "$rc" "0" "w26: all-PRs pass over two PRs exits 0"
assert_contains "$out" "converging 2 open PR(s)" "w26: reports the enumeration"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "2" "w26: one post per open PR"
assert_contains "$(cat "$POST_LOG")" "statuses/sha7" "w26: converged PR #7's head"
assert_contains "$(cat "$POST_LOG")" "statuses/sha8" "w26: converged PR #8's head"

rc=0; out=$(run_writer_all schedule STUB_VERDICT_LINE="$APPROVED" STUB_OPEN_PRS="$OPEN2" \
  STUB_GATE_HISTORY='[]') || rc=$?
assert_eq "$rc" "0" "w27b: all-PRs approved pass exits 0"
assert_eq "$(grep -c 'state=success' "$POST_LOG")" "2" "w27b: both approved heads open"
assert_eq "$(( $(wc -l < "$RERUN_LOG") ))" "0" "w27b: and the writer re-runs nothing"

set +e
out=$(run_writer_all schedule STUB_VERDICT_LINE="$AWAITING" STUB_OPEN_PRS="$OPEN2" \
  STUB_GATE_HISTORY='[]' STUB_PREDICATE_FAIL_PR=7)
rc=$?
set -e
assert_eq "$rc" "1" "w27: one failing PR fails the pass"
assert_contains "$out" "convergence failed for PR #7" "w27: names the failing PR"
assert_contains "$(cat "$POST_LOG")" "statuses/sha8" "w27: the other PR is still converged"

# Binding F2's teeth: an EVENT leg (here workflow_run) also enumerates every
# open PR — the payload sha is deliberately unused, so a pending run evicted
# by a burst strands nothing (whichever run survives converges everyone).
rc=0; out=$(run_writer_all workflow_run STUB_VERDICT_LINE="$AWAITING" STUB_OPEN_PRS="$OPEN2" \
  STUB_GATE_HISTORY='[]') || rc=$?
assert_eq "$rc" "0" "w28: event leg exits 0"
assert_contains "$out" "converging 2 open PR(s)" "w28: event legs converge ALL open PRs, not the payload head"
assert_contains "$(cat "$POST_LOG")" "statuses/sha7" "w28: converged PR #7"
assert_contains "$(cat "$POST_LOG")" "statuses/sha8" "w28: converged PR #8"

rc=0; out=$(run_writer_all workflow_run STUB_VERDICT_LINE="$APPROVED" STUB_OPEN_PRS='[]') || rc=$?
assert_eq "$rc" "0" "w29: zero open PRs exits 0"
assert_contains "$out" "converging 0 open PR(s)" "w29: names the empty pass"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w29: posts nothing (a superseded sha's completion converges nothing, naturally)"

# w22c: the empty-page case above is exactly why zero BYTES must fail loud —
# the two are adjacent shapes with opposite meanings (`[]` = truly no open
# PRs; nothing at all = a broken read that would strand every gate green).
rc=0; out=$(run_writer_all workflow_run STUB_VERDICT_LINE="$APPROVED" STUB_OPEN_PRS=emptybytes 2>&1) || rc=$?
assert_eq "$rc" "1" "w22c: zero-byte open-PR listing exits 1"
assert_contains "$out" "zero bytes" "w22c: names the broken read"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w22c: posts nothing on a broken listing"

# The two adjacent shapes the -z guard cannot see: whitespace-only slurps to
# [] and an error-object page to {} — both used to read as "zero open PRs"
# and exit green.
rc=0; out=$(run_writer_all workflow_run STUB_VERDICT_LINE="$APPROVED" STUB_OPEN_PRS=whitespace 2>&1) || rc=$?
assert_eq "$rc" "1" "w22d: whitespace-only open-PR listing exits 1"
assert_contains "$out" "not arrays" "w22d: names the shape violation"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w22d: posts nothing"

rc=0; out=$(run_writer_all workflow_run STUB_VERDICT_LINE="$APPROVED" STUB_OPEN_PRS='{"message":"Server Error"}' 2>&1) || rc=$?
assert_eq "$rc" "1" "w22e: an error-object page exits 1"
assert_contains "$out" "not arrays" "w22e: names the shape violation"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w22e: posts nothing"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY='{"message":"Server Error"}' 2>&1) || rc=$?
assert_eq "$rc" "1" "w22f: an error-object status page exits 1"
assert_contains "$out" "not arrays" "w22f: names the shape violation (a red for another reason is not this guard)"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w22f: no post past a malformed status page"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" STUB_GATE_HISTORY=$' \n  \n' 2>&1) || rc=$?
assert_eq "$rc" "1" "w22g: a whitespace-only status-history read exits 1 (slurps to [], not an empty status set)"
assert_contains "$out" "not arrays" "w22g: names the shape violation"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "w22g: posts nothing"

# A ghost-authored PR (user serialized null) enumerates with an empty
# author; the predicate resolves the real author itself downstream.
rc=0; out=$(run_writer_all schedule STUB_VERDICT_LINE="$AWAITING" \
  STUB_OPEN_PRS='[{"number":9,"head":{"sha":"sha9"},"user":null}]' \
  STUB_GATE_HISTORY='[]') || rc=$?
assert_eq "$rc" "0" "w26c: ghost-authored PR exits 0"
assert_contains "$(cat "$POST_LOG")" "statuses/sha9" "w26c: ghost-authored PR still converges (empty PR_AUTHOR handed down)"

echo "=== pagination merges (one array per page; page limits strand state) ==="

rc=0; out=$(run_writer_all schedule STUB_VERDICT_LINE="$AWAITING" \
  STUB_OPEN_PRS='[{"number":7,"head":{"sha":"sha7"},"user":{"login":"alice"}}]' \
  STUB_OPEN_PRS_PAGE2='[{"number":8,"head":{"sha":"sha8"},"user":{"login":"bob"}}]' \
  STUB_GATE_HISTORY='[]') || rc=$?
assert_eq "$rc" "0" "wp1: paginated enumeration exits 0"
assert_contains "$out" "converging 2 open PR(s)" "wp1: PRs beyond page one are enumerated (never stranded)"
assert_contains "$(cat "$POST_LOG")" "statuses/sha8" "wp1: the page-two PR is converged"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"pending","description":"x","created_at":"'"$OLD"'"}]' \
  STUB_GATE_HISTORY_PAGE2='[{"context":"Review gate","state":"success","description":"ok","created_at":"'"$OLD"'"}]') || rc=$?
assert_eq "$rc" "0" "wp2: paginated projection exits 0"
assert_contains "$(cat "$POST_LOG")" "state=success" "wp2: the projection merges every page before deciding"

rc=0; out=$(run_writer STUB_VERDICT_LINE="$APPROVED" \
  STUB_GATE_HISTORY='[{"context":"Review gate","state":"pending","description":"awaiting a non-author review for headsha","created_at":"'"$OLD"'"}]' \
  STUB_GUARD_HISTORY='[]' \
  STUB_GUARD_HISTORY_PAGE2='[{"context":"Review gate","state":"failure","description":"newer","created_at":"'"$FUTURE"'"}]') || rc=$?
assert_eq "$rc" "0" "wp3: paginated guard re-read exits 0"
assert_contains "$out" "deferring the success post" "wp3: a newer non-success entry on page two still defers (no first-page-only fail-open)"
assert_eq "$(( $(wc -l < "$POST_LOG") ))" "0" "wp3: no post past the paginated guard"

echo "=== settings: the writer never rewrites the override context ==="

# The OVERRIDE_CONTEXT alias lives in review-predicate.sh (so EVERY live gate
# read honors it, not just this writer — pre-PR review finding 4); the
# writer must not export a competing REVIEW_GATE_OUTAGE_CONTEXT on top of it.
ENV_LOG="$TMP_ROOT/predicate-env.log"
cat > "$TMP_ROOT/override-settings.toml" <<'EOF'
REVIEW_GATE_OVERRIDE_CONTEXT = "ops-override"
EOF
: > "$ENV_LOG"
rc=0; out=$(run_writer STUB_VERDICT_LINE="$AWAITING" STUB_GATE_HISTORY='[]' \
  REVIEW_GATE_SETTINGS_FILE="$TMP_ROOT/override-settings.toml" \
  STUB_PREDICATE_ENV_LOG="$ENV_LOG") || rc=$?
assert_eq "$rc" "0" "w30: override-context settings file exits 0"
assert_contains "$(cat "$ENV_LOG")" "OUTAGE=<unset>" "w30: the writer leaves the override alias entirely to the predicate (one mechanism, honored by every reader)"

: > "$ENV_LOG"
rc=0; out=$(run_writer STUB_VERDICT_LINE="$AWAITING" STUB_GATE_HISTORY='[]' \
  STUB_PREDICATE_ENV_LOG="$ENV_LOG") || rc=$?
assert_eq "$rc" "0" "w30b: absent override key exits 0"
assert_contains "$(cat "$ENV_LOG")" "OUTAGE=<unset>" "w30b: absent key leaves the predicate's own resolution untouched"

# ------------------------------------------------------------- the copies ---

TEMPLATE="$SKILL_ROOT/templates/review-gate-writer.yml"
# Walk up to the enclosing repo rather than assuming a fixed depth: this skill
# sits at skills/review-gate/ in the catalog but at .agents/skills/review-gate/
# in a consumer, so a hardcoded ../../ resolves to different places and would
# silently report "no copy here" in one of them.
SELF_ADOPTION=""
_dir="$SKILL_ROOT"
while [[ "$_dir" != "/" ]]; do
  if [[ -e "$_dir/.git" || -d "$_dir/.github" ]]; then
    SELF_ADOPTION="$_dir/.github/workflows/review-gate-writer.yml"
    break
  fi
  _dir="$(dirname "$_dir")"
done

WORKFLOWS=()
WORKFLOW_LABELS=()
if [[ -f "$TEMPLATE" ]]; then
  WORKFLOWS+=("$TEMPLATE"); WORKFLOW_LABELS+=("template")
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "the shipped template is missing at $TEMPLATE"
fi
if [[ -n "$SELF_ADOPTION" && -f "$SELF_ADOPTION" ]]; then
  WORKFLOWS+=("$SELF_ADOPTION"); WORKFLOW_LABELS+=("self-adoption copy")
else
  printf '  note  %s\n' "no adopted workflow found at ${SELF_ADOPTION:-<no enclosing repo root>} — asserting the template only"
fi

# ------------------------------------------------------------------ pins ----

pin_workflows() { # file, label
  local wf="$1" tag="$2"
  local write_block relay_block rc count

  pin() { # needle, name
    if grep -qF -- "$1" "$wf"; then
      PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "$2"
    else
      FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n        missing: %s\n' "$tag" "$2" "$1"
    fi
  }
  # The write job is the file's last job; the relay sits between the
  # merge-group job and it.
  write_block="$(sed -n '/^  write:/,$p' "$wf")"
  relay_block="$(sed -n '/^  request-converge:/,/^  write:/p' "$wf")"
  if [[ -z "$write_block" || -z "$relay_block" ]]; then
    FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "could not slice the relay and write job blocks (job renamed or reordered?)"
    return
  fi

  # --- leg routing -----------------------------------------------------
  if grep -qF -- "    if: github.event_name == 'workflow_dispatch' || github.event_name == 'schedule'" <<<"$write_block"; then
    PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: the write job's if: is exactly the two converge legs (VST-210: no PR-attached leg holds the evictable group)"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the write job's if: is exactly the two converge legs (VST-210: no PR-attached leg holds the evictable group)"
  fi
  if grep -qF -- "    if: github.event_name != 'merge_group' && github.event_name != 'workflow_dispatch' && github.event_name != 'schedule'" <<<"$relay_block"; then
    PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: the relay's if: is the NEGATIVE list (a newly added PR-attached trigger relays by default, and the dispatch target is excluded so no loop exists)"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay's if: is the NEGATIVE list (a newly added PR-attached trigger relays by default, and the dispatch target is excluded so no loop exists)"
  fi

  # EVERY status STATE converges (no state filter of ANY spelling): under
  # newest-row evidence semantics a success→pending/failure transition is a
  # withdrawal and must close the gate event-fast. Grep's exit code is
  # branched explicitly — 1 is the passing absence; anything else (2 = read
  # error) fails rather than laundering into a pass.
  rc=0; grep -qF -- "github.event.state" "$wf" || rc=$?
  case "$rc" in
    1) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: no status state filter of any spelling" ;;
    0) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: a status state filter returned — withdrawals would wait for the cron floor" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the workflow could not be read (grep error)" ;;
  esac

  # --- the triggers the split made load-bearing ------------------------
  # workflow_dispatch stopped being a manual convenience at VST-210: it is
  # the relay's dispatch target. A consumer pruning it as "we never kick it
  # by hand" silently strips every event-fast path down to the cron floor,
  # and every relay run burns its retry against a 422.
  pin "  workflow_dispatch: {}" "tpl: workflow_dispatch stays in on: — it is the relay's DISPATCH TARGET, not a manual kick"
  pin "    - cron:" "tpl: the schedule floor survives — with the PR-attached legs relaying, it is the write job's only non-dispatch leg"

  # --- concurrency -----------------------------------------------------
  pin "cancel-in-progress: false" "tpl: pending writer runs are never cancelled mid-write"
  pin "group: review-gate-writer" "tpl: single writer concurrency group"
  # The whole point of VST-210: the relay is the job PR-attached runs
  # execute, so it must hold NO concurrency group — an evictable relay would
  # put the CANCELLED check straight back into the PR's rollup.
  rc=0; grep -q '^    concurrency:' <<<"$relay_block" || rc=$?
  case "$rc" in
    1) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: the relay holds NO concurrency group (it can never be evicted, so it can never leave a cancelled check on a PR)" ;;
    0) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay grew a concurrency group — PR-attached runs are evictable again (VST-210 regression)" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay block could not be read (grep error)" ;;
  esac

  # --- the relay executes nothing ---------------------------------------
  # The relay is the job every PR-attached leg reaches, pull_request_target
  # included. Its stated design is "no checkout, no engine, no PR code".
  # The persist-credentials pin below is satisfied anywhere in the file, so
  # a checkout added HERE would otherwise keep the suite green.
  rc=0; grep -q 'uses: actions/checkout' <<<"$relay_block" || rc=$?
  case "$rc" in
    1) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: the relay checks nothing out — the pull_request_target leg's job holds no repository content at all" ;;
    0) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay grew a checkout — it is the pull_request_target job and must execute no repository code" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay block could not be read (grep error)" ;;
  esac

  # --- permissions ------------------------------------------------------
  rc=0; grep -qF -- "actions: write" <<<"$write_block" || rc=$?
  case "$rc" in
    1) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: the WRITE job holds no actions:write — the writer never re-runs CI" ;;
    0) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the write job requested actions:write (the writer never re-runs CI)" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the write block could not be read (grep error)" ;;
  esac
  count="$(grep -cF -- "actions: write" "$wf" || true)"
  if [[ "$count" == "1" ]] && grep -qF -- "actions: write" <<<"$relay_block"; then
    PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: exactly ONE actions:write in the workflow, and it is the relay's dispatch scope"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n        actions:write occurrences: %s (expected exactly 1, on the relay job)\n' "$tag" "tpl: exactly ONE actions:write in the workflow, and it is the relay's dispatch scope" "$count"
  fi

  # --- the dispatch ref: which ENGINE the indirection executes ----------
  # The single expression that decides that. github.ref_name here would be
  # the PR's BASE branch on the pull_request_target leg, so the relay would
  # dispatch whatever engine lives on a non-default branch — silently
  # breaking the default-branch-defined-writer guarantee the design rests
  # on. Two teeth: the exact literal is present on the relay, and no OTHER
  # DISPATCH_REF value can exist anywhere.
  if grep -qF -- "DISPATCH_REF: \${{ github.event.repository.default_branch || 'main' }}" <<<"$relay_block"; then
    PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: the relay dispatches onto the DEFAULT branch with the empty-expression fallback"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay's DISPATCH_REF is not the default-branch expression — the converge pass would run a non-default-branch engine"
  fi
  count="$(grep -cF -- "DISPATCH_REF:" "$wf" || true)"
  assert_eq "$count" "1" "[$tag] tpl: exactly ONE DISPATCH_REF binding (a second could not be reached by the literal pin above)"

  # --- the budget pair: backoff cap vs the job's timeout ----------------
  # Both halves were reconciled by hand in round 1 and only one was pinned.
  # Assert the RELATION, not the literals, so a deliberate coordinated retune
  # still passes and an uncoordinated one lands on a test that explains why.
  local tmo cap_s worst
  tmo="$(grep -oE '^    timeout-minutes: [0-9]+' <<<"$relay_block" | head -n 1 | awk '{print $2}')"
  cap_s="$(grep -oE '^          cap=[0-9]+' <<<"$relay_block" | head -n 1 | cut -d= -f2)"
  if [[ -z "$tmo" || -z "$cap_s" ]]; then
    FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n        timeout-minutes=%s cap=%s\n' "$tag" "tpl: could not read the relay's timeout-minutes and backoff cap — the budget pair is unpinned" "$tmo" "$cap_s"
  else
    # Worst case the step can produce: two bounded dispatch attempts plus the
    # capped wait between them.
    worst=$(( 60 + cap_s + 60 ))
    if (( tmo * 60 > worst )); then
      PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: the relay's timeout budget (${tmo}m) still outlasts its worst case (60s + ${cap_s}s cap + 60s = ${worst}s) — a retry can finish instead of being CANCELLED on the PR head"
    else
      FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay's timeout budget (${tmo}m) is NOT above its worst case (${worst}s) — a rate-limit retry would be killed by the timeout, leaving a cancelled check on the PR head"
    fi
  fi

  # --- no unbounded or unchecked calls in the relay ---------------------
  assert_contains "$relay_block" "timeout 60 gh api" "[$tag] tpl: each dispatch attempt is time-bounded — an unresponsive API would otherwise hang to timeout-minutes and be CANCELLED on the PR head"
  # Comment lines stripped first: the block explains WHY it allocates no temp
  # file, and a needle that its own rationale satisfies is not a check.
  rc=0; grep -v '^ *#' <<<"$relay_block" | grep -q 'mktemp' || rc=$?
  case "$rc" in
    1) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: the relay allocates no temp file — an unchecked mktemp is an undeclared failure path (empty name, ambiguous redirect) on a job that must never red" ;;
    0) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay grew an mktemp — check it or drop it; the response belongs in a variable" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay block could not be read (grep error)" ;;
  esac
  # The no-match guard inside header(): without it a pipefail shell kills the
  # step on the ordinary path where the API simply sent no such header.
  # STRUCTURAL, not a single needle: EVERY grep in the relay's script must
  # tolerate a no-match. A bare one exits 1 on the ordinary path where the
  # API simply sent no such header, and under a pipefail shell that status
  # propagates out of the command substitution and `set -e` reds the PR.
  local bare_greps
  bare_greps="$(grep -v '^ *#' <<<"$relay_block" | grep -c 'grep ' || true)"
  local guarded_greps
  guarded_greps="$(grep -v '^ *#' <<<"$relay_block" | grep 'grep ' | grep -c '|| true' || true)"
  if [[ "$bare_greps" == "$guarded_greps" && "$bare_greps" != "0" ]]; then
    PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: all $bare_greps grep(s) in the relay step tolerate a no-match (a bare one reds the PR under pipefail on the ORDINARY path)"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n        %s grep(s) in the relay step, only %s guarded with || true\n' "$tag" "tpl: every grep in the relay step must tolerate a no-match under pipefail" "$bare_greps" "$guarded_greps"
  fi

  # --- the loop breaker's second tooth ---------------------------------
  # The job if: is the first breaker and the line adoption.md tells
  # consumers to hand-edit; the step's own EVENT_NAME guard survives that
  # mis-edit. Nothing throttles a self-dispatch loop once started — the
  # relay holds no concurrency group by design.
  rc=0; grep -q '^      EVENT_NAME: \${{ github\.event_name }}$' <<<"$relay_block" || rc=$?
  case "$rc" in
    0) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: the RELAY binds EVENT_NAME (its step's independent loop breaker reads it)" ;;
    1) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay lost its EVENT_NAME binding — the step's loop breaker reads an unset var (the write job's identical binding does NOT cover this)" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay block could not be read (grep error)" ;;
  esac
  assert_contains "$relay_block" "workflow_dispatch|schedule)" "[$tag] tpl: the relay step refuses to dispatch when it ran on a converge leg"

  # --- the relay's scope is dispatch and nothing else -------------------
  # Its dispatch failure exits GREEN by decision (a red relay recreates the
  # UNSTABLE pin) and it carries NO escalation — sustained failure surfaces
  # as gate staleness via the cron floor and pr-watch --heal. So issues:write
  # must not appear here: the rolling incident stays on the write job, and a
  # relay that grew the scope would mean the decision was reversed silently.
  rc=0; grep -q '^      issues: write$' <<<"$relay_block" || rc=$?
  case "$rc" in
    1) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: the relay holds NO issues:write — dispatch is its whole scope; sustained failure is detected as gate staleness, not by this job" ;;
    0) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay grew issues:write — the no-escalation decision was reversed without updating the docs that state it" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the relay block could not be read (grep error)" ;;
  esac

  # --- checkouts --------------------------------------------------------
  pin "if: failure() || cancelled()" "tpl: VST-36 escalation covers timeout-cancelled jobs"
  pin "persist-credentials: false" "tpl: checkouts drop credentials"
  pin "github.event.pull_request.head.repo.full_name != github.repository" "tpl: fork pull_request_review read-only flag"
  # BOTH engine checkouts are counted: a one-match pin would stay green if
  # either job regressed to the bare expression.
  count="$(grep -cF -- "ref: \${{ github.event.repository.default_branch || 'main' }}" "$wf" || true)"
  assert_eq "$count" "2" "[$tag] tpl: BOTH checkouts pin the default branch with the empty-expression fallback"
  rc=0; grep -qF -- 'ref: ${{ github.event.repository.default_branch }}' "$wf" || rc=$?
  case "$rc" in
    1) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "tpl: no checkout uses the bare default_branch expression" ;;
    0) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: a checkout regressed to the bare default_branch expression (empty resolution would reach actions/checkout's own fallback)" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "tpl: the workflow could not be read (grep error)" ;;
  esac
}

echo "=== workflow pins ==="
for i in "${!WORKFLOWS[@]}"; do
  pin_workflows "${WORKFLOWS[$i]}" "${WORKFLOW_LABELS[$i]}"
done

# ---------------------------------------------------- relay step behavior ---

# The relay's step is an ordinary shell script, so it is EXECUTED rather than
# pinned: extracted verbatim and run against a gh stub whose exit codes and
# response headers are scripted per attempt. Extraction failure is fatal on
# its own — a renamed step that silently yielded an empty script would make
# every case below pass against nothing.
RELAY_BIN="$TMP_ROOT/relay-bin"
mkdir -p "$RELAY_BIN"
# Records each invocation to a file (NOT stdout: the step redirects gh's
# stdout into its response capture), replays the scripted header fixture as
# the response, and exits with the Nth code of GH_CODES.
cat > "$RELAY_BIN/gh" <<'RELAY_GH'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
n=$(grep -c . "$GH_LOG")
[ -n "${GH_HEADERS:-}" ] && printf '%s\n' "$GH_HEADERS"
set -- $GH_CODES
eval "code=\${$n:-0}"
exit "$code"
RELAY_GH
chmod +x "$RELAY_BIN/gh"
# The step's backoff is a real >=60s sleep. Stubbing it keeps the offline
# suite fast AND makes the wait itself assertable — the argument is recorded.
cat > "$RELAY_BIN/sleep" <<'RELAY_SLEEP'
#!/usr/bin/env bash
echo "$1" >> "$SLEEP_LOG"
exit 0
RELAY_SLEEP
chmod +x "$RELAY_BIN/sleep"

RELAY_LOG="$TMP_ROOT/relay-gh.log"
SLEEP_LOG="$TMP_ROOT/relay-sleep.log"

# THE SHELLS THE RUNNER ACTUALLY USES. A `run:` block with no `shell:` key
# gets `bash -e {0}`; an explicit `shell: bash` gets
# `bash --noprofile --norc -eo pipefail {0}`. Running the extracted step under
# plain `bash` — as this harness first did — models NEITHER, and that gap hid
# real reds: under `-e` an underivable workflow_ref exited 1, and under
# pipefail a no-match `grep` inside the header helper killed the step on the
# ORDINARY retry path. Every case runs under both, and the two must agree.
RELAY_SHELLS=("-e" "-eo pipefail")

_relay_once() { # shell-flags, step-path, read_only, ref, codes, event, headers
  : > "$RELAY_LOG"; : > "$SLEEP_LOG"
  set +e
  RELAY_OUT="$(GH_LOG="$RELAY_LOG" SLEEP_LOG="$SLEEP_LOG" GH_CODES="$5" GH_HEADERS="${7:-}" \
    PATH="$RELAY_BIN:$PATH" \
    WRITER_READ_ONLY="$3" WORKFLOW_REF="$4" EVENT_NAME="${6:-pull_request_target}" \
    GH_REPO="o/r" DISPATCH_REF="main" \
    bash $1 "$2" 2>&1)"
  RELAY_RC=$?
  set -e
  RELAY_CALLS="$(cat "$RELAY_LOG")"
  RELAY_SLEEPS="$(cat "$SLEEP_LOG")"
}

relay_run() { # step-path, read_only, workflow_ref, gh_codes, event_name, headers
  local first_rc="" first_calls="" first_sleeps="" flags
  for flags in "${RELAY_SHELLS[@]}"; do
    _relay_once "$flags" "$@"
    # THE INVARIANT, asserted on every case rather than per-case so a future
    # case cannot forget it: the relay never reds. It runs on PR-attached
    # legs, so a non-zero exit is a failed check on the PR head and pins
    # mergeStateStatus at UNSTABLE — the defect VST-210 removes. Nothing this
    # step can hit justifies that, because it holds no statuses scope and can
    # only ever leave the gate stale, which the cron floor owns.
    if [[ "$RELAY_RC" != "0" ]]; then
      FAIL=$((FAIL + 1))
      printf '  FAIL  %s\n        exit %s under [bash %s]\n        output: %s\n' \
        "relay INVARIANT: the relay never reds a PR head (case: ro=$2 ref='$3' codes='$4' event='${5:-pull_request_target}')" \
        "$RELAY_RC" "$flags" "$RELAY_OUT"
    else
      PASS=$((PASS + 1))
    fi
    if [[ -z "$first_rc" ]]; then
      first_rc="$RELAY_RC"; first_calls="$RELAY_CALLS"; first_sleeps="$RELAY_SLEEPS"
    elif [[ "$RELAY_RC" != "$first_rc" || "$RELAY_CALLS" != "$first_calls" || "$RELAY_SLEEPS" != "$first_sleeps" ]]; then
      FAIL=$((FAIL + 1))
      printf '  FAIL  %s\n        [bash %s] rc=%s vs rc=%s under [bash %s]\n' \
        "relay INVARIANT: behavior is identical under both runner shells (a pipefail-only difference is a latent red)" \
        "$flags" "$RELAY_RC" "$first_rc" "${RELAY_SHELLS[0]}"
    else
      PASS=$((PASS + 1))
    fi
  done
}

RELAY_STEPS=()
relay_battery() { # file, label
  local wf="$1" tag="$2" step="$TMP_ROOT/relay-step-${#RELAY_STEPS[@]}.sh"
  local ref="o/r/.github/workflows/review-gate-writer.yml@refs/heads/main"
  awk '
    /^      - name: Request a converge pass$/ { found = 1; next }
    found && !inblock && /^        run: \|$/ { inblock = 1; next }
    inblock {
      if ($0 ~ /^          / || $0 == "") { sub(/^          /, ""); print; next }
      exit
    }
  ' "$wf" > "$step"
  if [[ -s "$step" ]] && grep -qF -- "/dispatches" "$step"; then
    RELAY_STEPS+=("$step")
    PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "relay: the step script extracted from the workflow (non-empty, dispatches)"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "relay: could NOT extract the step script — every case below would prove nothing"
    return
  fi

  relay_run "$step" 0 "$ref" "0"
  assert_eq "$RELAY_RC" "0" "[$tag] relay1: an ordinary PR-attached leg exits 0"
  assert_eq "$RELAY_CALLS" \
    "gh api -i -X POST repos/o/r/actions/workflows/review-gate-writer.yml/dispatches -f ref=main" \
    "[$tag] relay1: dispatches THIS workflow's file on the default branch, exactly once"

  # Control for the derivation: a repo that renamed its copy must dispatch
  # the renamed file. Without this, relay1 would also pass against a
  # hardcoded name.
  relay_run "$step" 0 "o/r/.github/workflows/gate.yml@refs/heads/trunk" "0"
  assert_eq "$RELAY_CALLS" \
    "gh api -i -X POST repos/o/r/actions/workflows/gate.yml/dispatches -f ref=main" \
    "[$tag] relay2: a RENAMED consumer copy dispatches its own file (github.workflow_ref is read, not a hardcoded name — no ADAPT line)"

  relay_run "$step" 1 "$ref" "0"
  assert_eq "$RELAY_RC" "0" "[$tag] relay3: fork pull_request_review (read-only token) is a GREEN no-op, never a red run"
  assert_eq "$RELAY_CALLS" "" "[$tag] relay3: the read-only leg dispatches NOTHING — the cron floor converges fork review evidence"

  relay_run "$step" 0 "" "0"
  assert_eq "$RELAY_CALLS" "" "[$tag] relay4: an underivable workflow_ref dispatches NOTHING — never a garbage path (fail-closed)"
  assert_contains "$RELAY_OUT" "::warning::could not derive this workflow's file name" "[$tag] relay4: and warns instead of reddening — this is a PERMANENT condition, so a red here would pin every open PR at UNSTABLE forever while the cron floor keeps converging them anyway"

  relay_run "$step" 0 "$ref" "1 0"
  assert_eq "$RELAY_RC" "0" "[$tag] relay5: a transient dispatch failure is retried once and succeeds"
  assert_eq "$(grep -c . <<<"$RELAY_CALLS")" "2" "[$tag] relay5: exactly two attempts — one bounded retry, not a loop"

  # GREEN on double failure, deliberately: the relay holds no statuses
  # scope, so it cannot make the gate look converged — only leave it stale,
  # which the cron floor owns. A red here would pin the PR at UNSTABLE, the
  # exact defect the split removes.
  relay_run "$step" 0 "$ref" "1 1"
  assert_eq "$RELAY_RC" "0" "[$tag] relay6: two failed dispatches exit GREEN — reddening would recreate the UNSTABLE pin for a fault the cron floor recovers from"
  assert_eq "$(grep -c . <<<"$RELAY_CALLS")" "2" "[$tag] relay6: the double-failure path still stops after two attempts"
  assert_contains "$RELAY_OUT" "::warning::could not request a converge pass after two attempts" "[$tag] relay6: the double failure is announced as a WARNING — the annotation is the per-run trace, gate staleness is the detector of record"
  rc=0; grep -qF -- "::error::" <<<"$RELAY_OUT" || rc=$?
  case "$rc" in
    1) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "relay6: and NOT as an error — an error annotation on a green job is the shape a future 'restore fail-loud' edit leaves behind" ;;
    0) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "relay6: the double-failure path emitted ::error:: — decide one way: green+warning (current) or red, not a mixed signal" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$tag" "relay6: the relay output could not be read (grep error)" ;;
  esac

  # --- the loop breaker, independent of the job if: --------------------
  relay_run "$step" 0 "$ref" "0" workflow_dispatch
  assert_eq "$RELAY_RC" "0" "[$tag] relay7: a relay that ran on the workflow_dispatch leg exits 0"
  assert_eq "$RELAY_CALLS" "" "[$tag] relay7: and dispatches NOTHING — the step's own guard breaks a self-dispatch loop even if the job if: was mis-edited"
  assert_contains "$RELAY_OUT" "::warning::" "[$tag] relay7: the mis-edit is announced, not silently absorbed"
  relay_run "$step" 0 "$ref" "0" schedule
  assert_eq "$RELAY_CALLS" "" "[$tag] relay8: the schedule converge leg is refused by the same guard"

  # --- backoff: the retry must be able to outlast the limit it retries --
  # No response at all — a transport failure, not an HTTP rate-limit answer.
  # The minute-long floor is for the secondary limit (relay15); spending it
  # on a connection blip is a paid runner hold for nothing.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target
  assert_eq "$RELAY_SLEEPS" "5" "[$tag] relay9: a failure with NO response at all retries quickly — the 60s floor belongs to the rate-limit shapes, not to every failure"

  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
retry-after: 77
content-type: application/json"
  assert_eq "$RELAY_SLEEPS" "77" "[$tag] relay10: a retry-after header is honored over the floor"

  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
retry-after: 4000
content-type: application/json"
  assert_eq "$RELAY_SLEEPS" "" "[$tag] relay11: a wait beyond the job's budget is NOT slept — retrying inside the window we were told to stay out of is a guaranteed failure bought with a paid runner hold"
  assert_eq "$(grep -c . <<<"$RELAY_CALLS")" "1" "[$tag] relay11: and the second attempt is skipped entirely"
  assert_contains "$RELAY_OUT" "beyond this job's budget" "[$tag] relay11: the deferral names its reason"

  # --- the PRIMARY-limit shape: reset epoch, no retry-after ---------------
  # Computed from now so the case is not time-brittle.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
x-ratelimit-remaining: 0
x-ratelimit-reset: $(( $(date +%s) + 90 ))"
  case "$RELAY_SLEEPS" in
    88|89|90) PASS=$((PASS + 1)); printf '  ok    [%s] %s\n' "$tag" "relay12: x-ratelimit-reset is honored (primary-limit shape: reset epoch, no retry-after) — slept ${RELAY_SLEEPS}s" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n        expected ~90, got: %s\n' "$tag" "relay12: x-ratelimit-reset is honored (primary-limit shape)" "$RELAY_SLEEPS" ;;
  esac

  # A reset already in the past must not produce a negative sleep.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
x-ratelimit-reset: 1000000000"
  assert_eq "$RELAY_SLEEPS" "60" "[$tag] relay13: a reset epoch in the PAST falls to the floor, never a negative sleep"

  # The clamp direction relay10 cannot reach: a server value UNDER a minute
  # still lands inside the secondary-limit window it is retrying.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
retry-after: 3"
  assert_eq "$RELAY_SLEEPS" "60" "[$tag] relay14: a sub-minute retry-after is raised to GitHub's 60s floor — obeying 3s verbatim retries back inside the limit"

  # No server guidance: the minute is for being rate limited, not for a blip.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
content-type: application/json"
  assert_eq "$RELAY_SLEEPS" "60" "[$tag] relay15: a 403 with no headers is treated as the secondary limit — the floor applies"
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 502 Bad Gateway
content-type: application/json"
  assert_eq "$RELAY_SLEEPS" "5" "[$tag] relay16: a 5xx blip retries QUICKLY — a minute of paid runner hold buys nothing against a transient"

  # PERMANENT failures buy nothing by waiting: no sleep, no second attempt.
  # 404 is the shape a renamed/deleted workflow file produces, and 422 the
  # shape a bad ref produces — both settled answers.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 404 Not Found"
  assert_eq "$RELAY_SLEEPS" "" "[$tag] relay19: a 404 is not slept on — a missing workflow file is a settled answer, and this job holds a runner on a PR head"
  assert_eq "$(grep -c . <<<"$RELAY_CALLS")" "1" "[$tag] relay19: and the second attempt is skipped"
  assert_contains "$RELAY_OUT" "failed permanently (HTTP 404)" "[$tag] relay19: the deferral names the permanent status"
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 422 Unprocessable Entity"
  assert_eq "$RELAY_SLEEPS" "" "[$tag] relay20: a 422 (bad ref) is not slept on either"

  # Sanitizers: neither a non-numeric nor an out-of-range value may reach sleep.
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 502 Bad Gateway
retry-after: soon"
  assert_eq "$RELAY_SLEEPS" "5" "[$tag] relay17: a non-numeric retry-after is discarded, not passed to sleep"
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 403 Forbidden
retry-after: soon"
  assert_eq "$RELAY_SLEEPS" "60" "[$tag] relay17b: a non-numeric retry-after on a RATE-LIMIT response falls to the floor, not to the transient's quick retry"
  relay_run "$step" 0 "$ref" "1 0" pull_request_target "HTTP/2.0 502 Bad Gateway
retry-after: 999999999"
  assert_eq "$RELAY_SLEEPS" "5" "[$tag] relay18: an out-of-range retry-after is discarded before it can overflow the arithmetic or reach sleep"
}

echo "=== relay step behavior (request-converge, VST-210) ==="
for i in "${!WORKFLOWS[@]}"; do
  relay_battery "${WORKFLOWS[$i]}" "${WORKFLOW_LABELS[$i]}"
done

# The battery above proves each copy's step behaves; this proves they are the
# SAME step. Behavior equivalence under the cases we thought to write is
# weaker than byte-identity for a script that exists in two hand-maintained
# places — a divergence the cases do not happen to probe would otherwise ship.
# The step is pure logic with no vendored paths in it, so unlike the rest of
# the file it has no legitimate ADAPT reason to differ.
# WHOLE-FILE drift, not just the relay step. This round found a stale claim
# surviving in the adopted copy because the only cross-copy tooth covered the
# extracted step. Comments are compared out because ADAPT deliberately rewords
# them (vendored paths, default-branch notes) — prose drift between the copies
# is therefore NOT machine-checkable here and stays a review concern; what IS
# checked is that every line of CODE matches once the vendored script path is
# normalized, which is the class that changes behavior.
if [[ "${#WORKFLOWS[@]}" -eq 2 ]]; then
  _norm() { # strip comments and blank lines, normalize the vendored path
    grep -v '^ *#' "$1" | grep -v '^ *$' | sed 's#\.agents/skills/review-gate/#skills/review-gate/#g'
  }
  if diff -q <(_norm "${WORKFLOWS[0]}") <(_norm "${WORKFLOWS[1]}") >/dev/null 2>&1; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "drift: the template and the adopted copy are identical in CODE once the vendored path is normalized"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "drift: the template and the adopted copy DIVERGED in code — a template edit was not mirrored"
    diff <(_norm "${WORKFLOWS[0]}") <(_norm "${WORKFLOWS[1]}") | head -20
  fi
fi

if [[ "${#RELAY_STEPS[@]}" -eq 2 ]]; then
  # diff exits 0 identical, 1 differing, >1 could-not-read. A missing input
  # must never be reported as drift, nor drift as a read failure.
  # rc captured, not read from a bare command: under this file's `set -e` a
  # differing diff would abort the suite before reaching the verdict below —
  # real drift would then look like a silent early finish rather than a FAIL.
  rc=0; diff -q "${RELAY_STEPS[0]}" "${RELAY_STEPS[1]}" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) PASS=$((PASS + 1)); printf '  ok    %s\n' "relay: the template's and the adopted copy's relay steps are byte-identical (the step carries no ADAPT, so any drift is unintended)" ;;
    1) FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "relay: the two copies' relay steps DIVERGED — a template edit was not mirrored into the adopted workflow"
       diff "${RELAY_STEPS[0]}" "${RELAY_STEPS[1]}" | head -20 ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "relay: the extracted relay steps could not be compared (diff read error) — drift is unproven, not disproven" ;;
  esac
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
